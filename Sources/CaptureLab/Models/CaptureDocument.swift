import AppKit
import Foundation

struct CaptureDocument {
    var image: NSImage
    var sourceURL: URL?
    var createdAt: Date

    var pixelSize: CGSize {
        image.captureLabPixelSize
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

struct OCRResult: Equatable {
    var text: String
    var lineCount: Int
    var createdAt: Date
}
