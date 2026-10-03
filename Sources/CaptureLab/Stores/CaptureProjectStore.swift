import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

extension UTType {
    static let captureLabProject = UTType(exportedAs: "com.crazyjal.CaptureLab.project", conformingTo: .data)
}

enum CaptureProjectError: LocalizedError {
    case invalid, unsupportedVersion(Int), tooLarge
    var errorDescription: String? {
        switch self {
        case .invalid: return L10n.text(en: "The project is damaged or a required image is missing.", zh: "项目已损坏或缺少必要的图片资源。")
        case .unsupportedVersion(let version): return L10n.text(en: "Project version \(version) is not supported. Update CaptureLab to open it.", zh: "不支持项目格式版本 \(version)，请更新 CaptureLab 后再打开。")
        case .tooLarge: return L10n.text(en: "The project exceeds the image or file size limit.", zh: "项目超出图片或文件大小限制。")
        }
    }
}

/// A single atomic file with embedded resources. No external paths or private
/// import URLs are serialized. Only the current state, not undo history, is saved.
@MainActor
enum CaptureProjectStore {
    nonisolated static let version = 2
    nonisolated static let maximumBytes = 192 * 1_024 * 1_024
    struct State {
        var document: CaptureDocument
        var annotations: [CaptureAnnotation]
    }
    private struct Header: Decodable { var format: String; var version: Int }
    private struct File: Codable {
        var format = "CaptureLab"
        var version = CaptureProjectStore.version
        var createdAt: Date
        var sourcePNG: Data
        var sourceLogicalSize: CGSize
        var geometry: CaptureDocumentGeometry
        var annotations: [CaptureAnnotation]
        var imageLayers: [CaptureImageLayer]?
        var presentation: CapturePresentation?
    }

    static func encode(document: CaptureDocument, annotations: [CaptureAnnotation]) throws -> Data {
        try CaptureLayerImport.validate(document.imageLayers)
        try document.presentation.validate()
        guard document.presentation.outputSize(for: document.pixelSize) != nil else { throw CaptureProjectError.tooLarge }
        guard document.geometry.isValid(sourceSize: document.sourcePixelSize),
              validLogicalSize(document.image.size), document.createdAt.timeIntervalSinceReferenceDate.isFinite,
              validAnnotations(annotations),
              let png = document.image.captureLabPNGData() else { throw CaptureProjectError.invalid }
        guard png.count <= CaptureImageImport.maximumBytes else { throw CaptureProjectError.tooLarge }
        let value = File(createdAt: document.createdAt, sourcePNG: png, sourceLogicalSize: document.image.size,
                         geometry: document.geometry, annotations: annotations,
                         imageLayers: document.imageLayers, presentation: document.presentation)
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw CaptureProjectError.tooLarge }
        return data
    }

    static func decode(_ data: Data, sourceURL: URL? = nil) throws -> State {
        guard data.count <= maximumBytes else { throw CaptureProjectError.tooLarge }
        let decoder = JSONDecoder()
        let header: Header
        do { header = try decoder.decode(Header.self, from: data) }
        catch { throw CaptureProjectError.invalid }
        guard header.format == "CaptureLab" else { throw CaptureProjectError.invalid }
        guard (1...version).contains(header.version) else { throw CaptureProjectError.unsupportedVersion(header.version) }
        let value: File
        do { value = try decoder.decode(File.self, from: data) }
        catch { throw CaptureProjectError.invalid }
        if header.version >= 2, value.imageLayers == nil || value.presentation == nil { throw CaptureProjectError.invalid }
        try CaptureLayerImport.validate(value.imageLayers ?? [])
        try (value.presentation ?? CapturePresentation()).validate()
        guard value.sourcePNG.count <= CaptureImageImport.maximumBytes,
              let source = CGImageSourceCreateWithData(value.sourcePNG as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              value.geometry.isValid(sourceSize: CGSize(width: width, height: height)),
              validLogicalSize(value.sourceLogicalSize),
              value.createdAt.timeIntervalSinceReferenceDate.isFinite,
              validAnnotations(value.annotations),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CaptureProjectError.invalid }
        let image = NSImage(cgImage: cgImage, size: value.sourceLogicalSize)
        var document = CaptureDocument(image: image, sourceURL: sourceURL, createdAt: value.createdAt)
        document.geometry = value.geometry
        document.imageLayers = value.imageLayers ?? []
        document.presentation = value.presentation ?? CapturePresentation()
        guard document.presentation.outputSize(for: document.pixelSize) != nil else { throw CaptureProjectError.tooLarge }
        return State(document: document, annotations: value.annotations)
    }

    static func read(_ url: URL) throws -> State {
        guard url.isFileURL, let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumBytes else { throw CaptureProjectError.tooLarge }
        return try decode(Data(contentsOf: url, options: .mappedIfSafe), sourceURL: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".capturelab-\(UUID().uuidString).pending")
        let descriptor = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600)) }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard temporary.path.withCString({ source in url.path.withCString { Darwin.rename(source, $0) } }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func validLogicalSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            && size.width <= 32_768 && size.height <= 32_768
    }

    private static func validAnnotations(_ annotations: [CaptureAnnotation]) -> Bool {
        guard annotations.count <= 10_000, Set(annotations.map(\.id)).count == annotations.count else { return false }
        var points = 0
        for annotation in annotations {
            let rect = annotation.normalizedRect
            guard [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite),
                  rect.width >= 0, rect.height >= 0, rect.minX >= 0, rect.minY >= 0,
                  rect.maxX <= 1, rect.maxY <= 1, annotation.text.utf8.count <= 100_000,
                  annotation.normalizedPoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return false }
            points += annotation.normalizedPoints.count
            guard points <= 1_000_000 else { return false }
            if [.arrow, .line].contains(annotation.kind), annotation.normalizedPoints.count != 2 { return false }
            if annotation.kind == .curvedArrow, annotation.normalizedPoints.count != 3 { return false }
            guard annotation.appearance.isValid else { return false }
            if annotation.kind == .brush, annotation.normalizedPoints.count < 2 { return false }
            if let color = annotation.appearance.color,
               ![color.red, color.green, color.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) { return false }
            if let width = annotation.appearance.lineWidth, !width.isFinite || !(0.1...1_024).contains(width) { return false }
            if let font = annotation.appearance.fontSize, !font.isFinite || !(1...4_096).contains(font) { return false }
        }
        return true
    }
}
