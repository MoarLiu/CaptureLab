import CoreGraphics
import Foundation

enum CaptureZoomLevel: String, CaseIterable, Identifiable {
    case fit
    case half
    case actual
    case double

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit:
            return L10n.zoomFit
        case .half:
            return "50%"
        case .actual:
            return "100%"
        case .double:
            return "200%"
        }
    }

    var scale: CGFloat? {
        switch self {
        case .fit:
            return nil
        case .half:
            return 0.5
        case .actual:
            return 1
        case .double:
            return 2
        }
    }
}

