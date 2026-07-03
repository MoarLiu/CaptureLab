import AppKit
import Foundation

enum CaptureHistoryError: LocalizedError {
    case imageDataUnavailable
    case imageNotFound
    case metadataLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .imageDataUnavailable:
            return L10n.historyImageDataUnavailable
        case .imageNotFound:
            return L10n.historyImageNotFound
        case .metadataLoadFailed(let message):
            return L10n.historyMetadataLoadFailed(message)
        }
    }
}

@MainActor
final class CaptureHistoryStore: ObservableObject {
    static let maxItemCount = 30

    @Published private(set) var items: [CaptureHistoryItem]
    @Published private(set) var loadError: CaptureHistoryError?

    private struct MetadataDocument: Codable, Equatable {
        var schemaVersion: Int
        var items: [CaptureHistoryItem]
    }

    private let environment: [String: String]
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            self.items = try Self.loadItems(
                metadataURL: Self.metadataURL(environment: environment),
                fileManager: fileManager,
                decoder: decoder
            )
            self.loadError = nil
        } catch {
            self.items = Self.recoverItemsFromDirectory(
                historyDirectory: Self.historyDirectory(environment: environment),
                fileManager: fileManager
            )
            self.loadError = .metadataLoadFailed(error.localizedDescription)
            try? persist()
        }
    }

    var historyDirectory: URL {
        Self.historyDirectory(environment: environment)
    }

    var metadataURL: URL {
        Self.metadataURL(environment: environment)
    }

    func record(data: Data, pixelSize: CGSize, createdAt: Date = Date()) throws -> CaptureHistoryItem {
        guard !data.isEmpty else {
            throw CaptureHistoryError.imageDataUnavailable
        }

        try fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let id = UUID()
        let fileName = "capture-\(Self.fileTimestampFormatter.string(from: createdAt))-\(id.uuidString).png"
        let fileURL = historyDirectory.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)

        let item = CaptureHistoryItem(
            id: id,
            createdAt: createdAt,
            fileName: fileName,
            pixelWidth: Int(pixelSize.width),
            pixelHeight: Int(pixelSize.height)
        )
        items.insert(item, at: 0)
        try trimAndPersist()
        return item
    }

    func url(for item: CaptureHistoryItem) -> URL {
        historyDirectory.appendingPathComponent(item.fileName)
    }

    func data(for item: CaptureHistoryItem) throws -> Data {
        let fileURL = url(for: item)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw CaptureHistoryError.imageNotFound
        }
        return try Data(contentsOf: fileURL)
    }

    private func trimAndPersist() throws {
        let overflow = Array(items.dropFirst(Self.maxItemCount))
        items = Array(items.prefix(Self.maxItemCount))
        for item in overflow {
            try? fileManager.removeItem(at: url(for: item))
        }
        try persist()
    }

    private func persist() throws {
        try fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let document = MetadataDocument(schemaVersion: 1, items: items)
        try encoder.encode(document).write(to: metadataURL, options: .atomic)
    }

    private static func loadItems(
        metadataURL: URL,
        fileManager: FileManager,
        decoder: JSONDecoder
    ) throws -> [CaptureHistoryItem] {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return []
        }
        let document = try decoder.decode(MetadataDocument.self, from: Data(contentsOf: metadataURL))
        return document.items.filter { item in
            fileManager.fileExists(atPath: metadataURL.deletingLastPathComponent().appendingPathComponent(item.fileName).path)
        }
    }

    private static func recoverItemsFromDirectory(
        historyDirectory: URL,
        fileManager: FileManager
    ) -> [CaptureHistoryItem] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: historyDirectory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension.lowercased() == "png" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let createdAt = values?.creationDate ?? values?.contentModificationDate ?? Date.distantPast
                let image = NSImage(contentsOf: url)
                let pixelSize = image?.captureLabPixelSize ?? .zero
                return CaptureHistoryItem(
                    id: Self.recoveredID(from: url.lastPathComponent) ?? UUID(),
                    createdAt: createdAt,
                    fileName: url.lastPathComponent,
                    pixelWidth: Int(pixelSize.width),
                    pixelHeight: Int(pixelSize.height)
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(Self.maxItemCount)
            .map { $0 }
    }

    private static func recoveredID(from fileName: String) -> UUID? {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        guard stem.count >= 36 else {
            return nil
        }
        return UUID(uuidString: String(stem.suffix(36)))
    }

    private static func historyDirectory(environment: [String: String]) -> URL {
        CaptureLabDataRoot.supportDirectory(environment: environment)
            .appendingPathComponent("History", isDirectory: true)
    }

    private static func metadataURL(environment: [String: String]) -> URL {
        historyDirectory(environment: environment)
            .appendingPathComponent("history.json")
    }

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
