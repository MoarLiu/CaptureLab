import CoreGraphics
import Foundation

struct CaptureHistoryItem: Codable, Equatable, Identifiable {
    var id: UUID
    var createdAt: Date
    var fileName: String
    var pixelWidth: Int
    var pixelHeight: Int

    var pixelSize: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }

    var displayTitle: String {
        Self.displayFormatter.string(from: createdAt)
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}

