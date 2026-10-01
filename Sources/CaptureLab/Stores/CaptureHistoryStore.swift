import AppKit
import Darwin
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
    typealias ImageWriter = (Data, URL) throws -> Void
    typealias MetadataWriter = (Data, URL) throws -> Void

    @Published private(set) var items: [CaptureHistoryItem]
    @Published private(set) var loadError: CaptureHistoryError?

    private struct MetadataDocument: Codable, Equatable {
        var schemaVersion: Int
        var items: [CaptureHistoryItem]
    }

    private let environment: [String: String]
    private let fileManager: FileManager
    private let imageWriter: ImageWriter
    private let metadataWriter: MetadataWriter
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        imageWriter: @escaping ImageWriter = { data, url in
            try data.write(to: url, options: .atomic)
        },
        metadataWriter: @escaping MetadataWriter = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.imageWriter = imageWriter
        self.metadataWriter = metadataWriter
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let historyEncoder = encoder
        let historyDecoder = decoder
        let historyDirectory = Self.historyDirectory(environment: environment)
        let metadataURL = Self.metadataURL(environment: environment)
        do {
            let result = try Self.withExclusiveHistoryLock(
                historyDirectory: historyDirectory,
                fileManager: fileManager
            ) { () -> (items: [CaptureHistoryItem], error: CaptureHistoryError?) in
                let metadataExists = fileManager.fileExists(atPath: metadataURL.path)
                do {
                    let loadedItems: [CaptureHistoryItem]
                    if metadataExists {
                        loadedItems = try Self.loadItems(
                            metadataURL: metadataURL,
                            fileManager: fileManager,
                            decoder: historyDecoder
                        )
                    } else {
                        loadedItems = Self.recoverItemsFromDirectory(
                            historyDirectory: historyDirectory,
                            fileManager: fileManager
                        )
                    }
                    if !metadataExists, !loadedItems.isEmpty {
                        let document = MetadataDocument(schemaVersion: 1, items: loadedItems)
                        try metadataWriter(historyEncoder.encode(document), metadataURL)
                    }
                    // A crash can leave a PNG behind after its atomic image write
                    // but before metadata is committed. Likewise, a previous
                    // best-effort overflow deletion may have failed. Once the
                    // metadata snapshot is known to be valid (or has just been
                    // rebuilt), it is the source of truth and those unreferenced
                    // screenshots can be reclaimed safely while the cross-process
                    // history lock is still held.
                    Self.removeUnreferencedPNGFiles(
                        retaining: loadedItems,
                        historyDirectory: historyDirectory,
                        fileManager: fileManager
                    )
                    return (loadedItems, nil)
                } catch {
                    let recoveredItems = Self.recoverItemsFromDirectory(
                        historyDirectory: historyDirectory,
                        fileManager: fileManager
                    )
                    let document = MetadataDocument(schemaVersion: 1, items: recoveredItems)
                    if let data = try? historyEncoder.encode(document) {
                        do {
                            try metadataWriter(data, metadataURL)
                            Self.removeUnreferencedPNGFiles(
                                retaining: recoveredItems,
                                historyDirectory: historyDirectory,
                                fileManager: fileManager
                            )
                        } catch {
                            // Preserve every recoverable PNG when the replacement
                            // metadata could not be committed. A later launch can
                            // retry without turning a metadata failure into data loss.
                        }
                    }
                    return (
                        recoveredItems,
                        .metadataLoadFailed(error.localizedDescription)
                    )
                }
            }
            self.items = result.items
            self.loadError = result.error
        } catch {
            self.items = Self.recoverItemsFromDirectory(
                historyDirectory: historyDirectory,
                fileManager: fileManager
            )
            self.loadError = .metadataLoadFailed(error.localizedDescription)
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

        return try withExclusiveHistoryLock {
            // Another CaptureLab process may have committed history after this
            // store was initialized. Always merge against the current on-disk
            // snapshot while holding the cross-process lock instead of letting
            // stale in-memory state overwrite it.
            let currentItems = latestItemsFromDisk()
            let id = UUID()
            let fileName = "capture-\(Self.fileTimestampFormatter.string(from: createdAt))-\(id.uuidString).png"
            let fileURL = historyDirectory.appendingPathComponent(fileName)
            try imageWriter(data, fileURL)

            let item = CaptureHistoryItem(
                id: id,
                createdAt: createdAt,
                fileName: fileName,
                pixelWidth: Int(pixelSize.width),
                pixelHeight: Int(pixelSize.height)
            )
            let allItems = [item] + currentItems.filter { $0.id != item.id }
            let retainedItems = Array(allItems.prefix(Self.maxItemCount))
            do {
                try persist(retainedItems)
            } catch {
                // A custom or failing writer can theoretically replace the
                // metadata file and then report an error. Never remove the new
                // PNG when the on-disk metadata already references it, or the
                // rollback itself would create a dangling history entry.
                if let committedItems = try? Self.loadItems(
                    metadataURL: metadataURL,
                    fileManager: fileManager,
                    decoder: decoder
                ), committedItems.contains(where: { $0.id == item.id }) {
                    items = committedItems
                } else {
                    try? fileManager.removeItem(at: fileURL)
                }
                throw error
            }

            items = retainedItems
            Self.removeUnreferencedPNGFiles(
                retaining: retainedItems,
                historyDirectory: historyDirectory,
                fileManager: fileManager
            )
            return item
        }
    }

    /// Reload the durable snapshot under the same lock used by mutations.
    /// Invalid metadata leaves the previous snapshot and every image intact.
    func refresh() throws {
        do {
            try withExclusiveHistoryLock {
                let refreshedItems: [CaptureHistoryItem]
                if fileManager.fileExists(atPath: metadataURL.path) {
                    refreshedItems = try Self.loadItems(
                        metadataURL: metadataURL,
                        fileManager: fileManager,
                        decoder: decoder
                    )
                } else {
                    refreshedItems = Self.recoverItemsFromDirectory(
                        historyDirectory: historyDirectory,
                        fileManager: fileManager
                    )
                    do {
                        try persist(refreshedItems)
                    } catch {
                        synchronizeAfterMetadataFailure(fallback: refreshedItems)
                        throw error
                    }
                }
                items = refreshedItems
                loadError = nil
                Self.removeUnreferencedPNGFiles(
                    retaining: refreshedItems,
                    historyDirectory: historyDirectory,
                    fileManager: fileManager
                )
            }
        } catch {
            let historyError = CaptureHistoryError.metadataLoadFailed(error.localizedDescription)
            loadError = historyError
            throw historyError
        }
    }

    /// Commit the removal before reclaiming the image. An unsuccessful metadata
    /// write cannot delete an image that is still part of the durable snapshot.
    func remove(_ item: CaptureHistoryItem) throws {
        try withExclusiveHistoryLock {
            let currentItems = latestItemsFromDisk()
            let retainedItems = currentItems.filter { $0.id != item.id }
            guard retainedItems.count != currentItems.count else {
                items = currentItems
                return
            }

            do {
                try persist(retainedItems)
            } catch {
                synchronizeAfterMetadataFailure(fallback: currentItems)
                throw error
            }
            items = retainedItems
            // Report a cleanup failure even though the metadata removal has
            // already committed. The caller can synchronize the visible list
            // while telling the user that the local PNG could not be removed.
            let retainedFileNames = Set(retainedItems.map(\.fileName))
            for removedItem in currentItems where removedItem.id == item.id {
                guard !retainedFileNames.contains(removedItem.fileName),
                      let fileURL = Self.historyFileURL(
                        fileName: removedItem.fileName,
                        historyDirectory: historyDirectory
                      ), Self.isRegularFile(fileURL) else { continue }
                try fileManager.removeItem(at: fileURL)
            }
        }
    }

    /// Same-size edits replace the existing PNG atomically. A crop first writes
    /// a new PNG, then commits its filename and dimensions together, so a failed
    /// metadata write leaves the previous image and dimensions usable.
    /// Return nil if retention has removed the item while its editor was open.
    func updateImage(
        data: Data,
        for item: CaptureHistoryItem,
        pixelSize: CGSize? = nil
    ) throws -> CaptureHistoryItem? {
        guard !data.isEmpty else {
            throw CaptureHistoryError.imageDataUnavailable
        }
        if let pixelSize {
            guard pixelSize.width.isFinite, pixelSize.height.isFinite,
                  pixelSize.width >= 1, pixelSize.height >= 1,
                  pixelSize.width < CGFloat(Int.max), pixelSize.height < CGFloat(Int.max) else {
                throw CaptureHistoryError.imageDataUnavailable
            }
        }

        return try withExclusiveHistoryLock {
            let currentItems = latestItemsFromDisk()
            guard let currentItem = currentItems.first(where: { $0.id == item.id }) else {
                items = currentItems
                return nil
            }
            items = currentItems

            let width = pixelSize.map { Int($0.width) } ?? currentItem.pixelWidth
            let height = pixelSize.map { Int($0.height) } ?? currentItem.pixelHeight
            if width == currentItem.pixelWidth, height == currentItem.pixelHeight {
                let temporaryURL = historyDirectory.appendingPathComponent(".image-update-\(UUID().uuidString).pending")
                defer { try? fileManager.removeItem(at: temporaryURL) }
                try imageWriter(data, temporaryURL)
                // rename replaces the destination in one operation on this
                // filesystem. A writer that partially writes or reports failure
                // has touched only the temporary file, never the original PNG.
                let destination = url(for: currentItem)
                let result = temporaryURL.path.withCString { source in
                    destination.path.withCString { Darwin.rename(source, $0) }
                }
                guard result == 0 else {
                    throw Self.posixError(code: errno, operation: "replace history image")
                }
                items = currentItems
                return currentItem
            }

            var updatedItem = currentItem
            updatedItem.fileName = "capture-\(Self.fileTimestampFormatter.string(from: currentItem.createdAt))-\(UUID().uuidString)-\(currentItem.id.uuidString).png"
            updatedItem.pixelWidth = width
            updatedItem.pixelHeight = height
            let updatedURL = url(for: updatedItem)
            do {
                try imageWriter(data, updatedURL)
            } catch {
                try? fileManager.removeItem(at: updatedURL)
                items = currentItems
                throw error
            }
            let updatedItems = currentItems.map { $0.id == currentItem.id ? updatedItem : $0 }
            do {
                try persist(updatedItems)
            } catch {
                synchronizeAfterMetadataFailure(fallback: currentItems)
                throw error
            }

            items = updatedItems
            Self.removeUnreferencedPNGFiles(
                retaining: updatedItems,
                historyDirectory: historyDirectory,
                fileManager: fileManager
            )
            return updatedItem
        }
    }

    func url(for item: CaptureHistoryItem) -> URL {
        Self.historyFileURL(fileName: item.fileName, historyDirectory: historyDirectory)
            ?? historyDirectory.appendingPathComponent(".invalid-history-item")
    }

    func data(for item: CaptureHistoryItem) throws -> Data {
        guard let fileURL = Self.historyFileURL(
            fileName: item.fileName,
            historyDirectory: historyDirectory
        ), Self.isRegularFile(fileURL) else {
            throw CaptureHistoryError.imageNotFound
        }
        return try Data(contentsOf: fileURL)
    }

    private func persist(_ items: [CaptureHistoryItem]) throws {
        try fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let document = MetadataDocument(schemaVersion: 1, items: items)
        try metadataWriter(encoder.encode(document), metadataURL)
    }

    private func synchronizeAfterMetadataFailure(fallback: [CaptureHistoryItem]) {
        // A writer may report failure after its atomic replacement committed.
        // Only a readable durable snapshot permits cleanup; otherwise preserve
        // all images for later recovery, including a possibly committed crop.
        guard let documentData = try? Data(contentsOf: metadataURL),
              let document = try? decoder.decode(MetadataDocument.self, from: documentData),
              let committedItems = try? Self.loadItems(
            metadataURL: metadataURL,
            fileManager: fileManager,
            decoder: decoder
        ) else {
            items = fallback
            return
        }
        items = committedItems
        Self.removeUnreferencedPNGFiles(
            // Keep every raw metadata reference during error recovery, even
            // when loadItems filtered a missing file, duplicate, or overflow.
            // Filtering must not be mistaken for a successfully committed
            // deletion or permit removing another referenced PNG.
            retaining: document.items,
            historyDirectory: historyDirectory,
            fileManager: fileManager
        )
    }

    private func latestItemsFromDisk() -> [CaptureHistoryItem] {
        if fileManager.fileExists(atPath: metadataURL.path),
           let persisted = try? Self.loadItems(
               metadataURL: metadataURL,
               fileManager: fileManager,
               decoder: decoder
           ) {
            return persisted
        }
        return Self.recoverItemsFromDirectory(
            historyDirectory: historyDirectory,
            fileManager: fileManager
        )
    }

    private func withExclusiveHistoryLock<T>(_ operation: () throws -> T) throws -> T {
        try Self.withExclusiveHistoryLock(
            historyDirectory: historyDirectory,
            fileManager: fileManager,
            operation: operation
        )
    }

    private static func withExclusiveHistoryLock<T>(
        historyDirectory: URL,
        fileManager: FileManager,
        operation: () throws -> T
    ) throws -> T {
        try fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let lockURL = historyDirectory.appendingPathComponent(".history.lock")
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw Self.posixError(code: errno, operation: "open history lock")
        }
        defer { Darwin.close(descriptor) }

        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        while Darwin.fcntl(descriptor, F_SETLKW, &lock) != 0 {
            let code = errno
            if code == EINTR {
                continue
            }
            throw Self.posixError(code: code, operation: "lock history")
        }
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
        }
        // Every image writer holds this same lock. Once it is acquired, no
        // other process can still be using an update's temporary file, so a
        // matching file is an abandoned replacement rather than a live edit.
        // Reclaim it even when metadata is unreadable; pending files can never
        // be valid PNG history references. Surface cleanup failures so a later
        // operation can retry without silently retaining a private screenshot.
        try removeAbandonedImageUpdates(
            historyDirectory: historyDirectory,
            fileManager: fileManager
        )
        return try operation()
    }

    private static func posixError(code: Int32, operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "Could not \(operation): \(String(cString: strerror(code)))"]
        )
    }

    private static func loadItems(
        metadataURL: URL,
        fileManager: FileManager,
        decoder: JSONDecoder
    ) throws -> [CaptureHistoryItem] {
        let document = try decoder.decode(MetadataDocument.self, from: Data(contentsOf: metadataURL))
        let historyDirectory = metadataURL.deletingLastPathComponent()
        var seenIDs = Set<UUID>()
        var seenFileNames = Set<String>()
        return document.items.compactMap { item in
            guard let fileURL = historyFileURL(
                      fileName: item.fileName,
                      historyDirectory: historyDirectory
                  ), isRegularFile(fileURL),
                  seenIDs.insert(item.id).inserted,
                  seenFileNames.insert(item.fileName).inserted else {
                return nil
            }
            return item
        }
        .prefix(maxItemCount)
        .map { $0 }
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
        var recoveredIDs = Set<UUID>()

        return urls
            .filter {
                $0.pathExtension.lowercased() == "png"
                    && Self.isRegularFile($0)
            }
            .compactMap { url -> (item: CaptureHistoryItem, modifiedAt: Date)? in
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let createdAt = values?.creationDate ?? values?.contentModificationDate ?? Date.distantPast
                let image = NSImage(contentsOf: url)
                let pixelSize = image?.captureLabPixelSize ?? .zero
                return (
                    item: CaptureHistoryItem(
                        id: Self.recoveredID(from: url.lastPathComponent) ?? UUID(),
                        createdAt: createdAt,
                        fileName: url.lastPathComponent,
                        pixelWidth: Int(pixelSize.width),
                        pixelHeight: Int(pixelSize.height)
                    ),
                    modifiedAt: values?.contentModificationDate ?? createdAt
                )
            }
            // A crop can leave both revisions after a crash or unreadable
            // metadata write. Their filenames retain the same capture ID;
            // choose the most recently written revision before sorting captures
            // by their recovered creation dates and enforcing retention.
            .sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                return $0.item.fileName > $1.item.fileName
            }
            .filter { recoveredIDs.insert($0.item.id).inserted }
            .map(\.item)
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(Self.maxItemCount)
            .map { $0 }
    }

    private static func removeUnreferencedPNGFiles(
        retaining items: [CaptureHistoryItem],
        historyDirectory: URL,
        fileManager: FileManager
    ) {
        let retainedFileNames = Set(items.map(\.fileName))
        guard let urls = try? fileManager.contentsOfDirectory(
            at: historyDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for url in urls where url.pathExtension.lowercased() == "png" {
            guard !retainedFileNames.contains(url.lastPathComponent),
                  isRegularFile(url) else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    private static func removeAbandonedImageUpdates(
        historyDirectory: URL,
        fileManager: FileManager
    ) throws {
        let urls = try fileManager.contentsOfDirectory(
            at: historyDirectory,
            includingPropertiesForKeys: nil
        )
        for url in urls {
            let fileName = url.lastPathComponent
            let prefix = ".image-update-"
            let suffix = ".pending"
            guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else { continue }
            let uuidText = String(fileName.dropFirst(prefix.count).dropLast(suffix.count))
            // UUID parsing alone accepts more spellings than the writer emits.
            // Require its exact canonical format to avoid claiming unknown files.
            guard let id = UUID(uuidString: uuidText), id.uuidString == uuidText,
                  isRegularFile(url) else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    private static func historyFileURL(fileName: String, historyDirectory: URL) -> URL? {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/"),
              !fileName.contains("\0"),
              URL(fileURLWithPath: fileName).pathExtension.lowercased() == "png" else {
            return nil
        }

        let standardizedDirectory = historyDirectory.standardizedFileURL
        let candidate = standardizedDirectory
            .appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == standardizedDirectory else {
            return nil
        }
        return candidate
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var fileStatus = stat()
        guard url.path.withCString({ Darwin.lstat($0, &fileStatus) }) == 0 else {
            return false
        }
        return (fileStatus.st_mode & S_IFMT) == S_IFREG
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
