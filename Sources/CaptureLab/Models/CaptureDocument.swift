import AppKit
import Foundation

struct CaptureDocument {
    var id = UUID()
    var image: NSImage
    var sourceURL: URL?
    var createdAt: Date
    var geometry = CaptureDocumentGeometry()

    var pixelSize: CGSize {
        geometry.outputSize ?? canvasSize
    }

    var sourcePixelSize: CGSize { image.captureLabPixelSize }
    var canvasSize: CGSize { geometry.canvasSize ?? sourcePixelSize }
    var displaySize: CGSize {
        let scale = image.size.width / max(sourcePixelSize.width, 1)
        return CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    }

    var displayTitle: String {
        if let sourceURL {
            return sourceURL.lastPathComponent
        }
        return L10n.captureTitle(Self.timestampFormatter.string(from: createdAt))
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

struct OCRResult: Equatable, Sendable {
    var text: String
    var lineCount: Int
    var createdAt: Date
}
