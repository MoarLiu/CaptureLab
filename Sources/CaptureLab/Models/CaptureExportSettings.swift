import AppKit
import ImageIO
import UniformTypeIdentifiers

enum CaptureExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case png, jpeg
    var id: String { rawValue }
    var title: String { self == .png ? "PNG" : "JPEG" }
    var fileExtension: String { self == .png ? "png" : "jpg" }
    var contentType: UTType { self == .png ? .png : .jpeg }
}

struct CaptureExportSettings: Codable, Hashable, Sendable {
    var format: CaptureExportFormat = .png
    var quality: Double = 0.9
    var width: Int?
    var height: Int?
    var matte = CaptureRGBAColor.white
    var keepAspectRatio = true

    /// Reusing a width from the previous export must follow this image's ratio.
    /// The edited dimension stays authoritative; zero marks an invalid partner
    /// so validation rejects the request instead of silently clamping its size.
    mutating func matchAspectRatio(to inputSize: CGSize, usingWidth: Bool = true) {
        guard keepAspectRatio, width != nil || height != nil else { return }
        let useWidth = usingWidth ? width != nil : height == nil
        let ratio = inputSize.width / inputSize.height
        let value = useWidth ? Double(width ?? 0) / ratio : Double(height ?? 0) * ratio
        let partner = value.isFinite && value >= 1 && value <= 32_768 ? Int(value.rounded()) : 0
        if useWidth { height = partner } else { width = partner }
    }

    func outputSize(for inputSize: CGSize) -> CGSize? {
        let result = CGSize(width: width.map(CGFloat.init) ?? inputSize.width,
                            height: height.map(CGFloat.init) ?? inputSize.height)
        return CaptureDocumentGeometry.validSize(result) ? result : nil
    }
    func encode(_ image: NSImage) throws -> Data {
        guard let input = image.captureLabCGImage() else { throw CapturePresentationError.encodingFailed }
        return try encode(input)
    }
    /// ImageIO operates on immutable CGImage snapshots, so preview encoding can
    /// leave the main actor without sharing mutable AppKit image representations.
    func encode(_ input: CGImage) throws -> Data {
        guard quality.isFinite, (0...1).contains(quality), matte.isValid,
              let size = outputSize(for: CGSize(width: input.width, height: input.height)),
              let context = CapturePresentation.context(size: size) else { throw CapturePresentationError.invalidLayout }
        let bounds = CGRect(origin: .zero, size: size)
        if format == .jpeg {
            var opaqueMatte = matte; opaqueMatte.alpha = 1
            context.setFillColor(opaqueMatte.cgColor); context.fill(bounds)
        }
        context.interpolationQuality = .high
        context.draw(input, in: bounds)
        guard let rendered = context.makeImage() else { throw CapturePresentationError.encodingFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, contentTypeIdentifier, 1, nil) else {
            throw CapturePresentationError.encodingFailed
        }
        let properties: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CapturePresentationError.encodingFailed }
        return data as Data
    }
    private var contentTypeIdentifier: CFString { format.contentType.identifier as CFString }
}

/// Core Graphics image storage is immutable. No mutable NSImage crosses actors.
struct CaptureExportImage: @unchecked Sendable {
    let image: CGImage
}
