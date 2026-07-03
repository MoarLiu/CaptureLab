import Foundation

enum CaptureMode: Hashable, Identifiable {
    case region
    case fullScreen
    case window
    case delayedRegion(seconds: Int)

    var id: String {
        switch self {
        case .region:
            return "region"
        case .fullScreen:
            return "fullScreen"
        case .window:
            return "window"
        case .delayedRegion(let seconds):
            return "delayedRegion-\(seconds)"
        }
    }

    var title: String {
        switch self {
        case .region:
            return L10n.captureRegion
        case .fullScreen:
            return L10n.captureFullScreen
        case .window:
            return L10n.captureWindow
        case .delayedRegion(let seconds):
            return L10n.captureDelayedRegion(seconds)
        }
    }

    var promptTitle: String {
        switch self {
        case .region:
            return L10n.selectRegionPrompt
        case .fullScreen:
            return L10n.capturingFullScreen
        case .window:
            return L10n.selectWindowPrompt
        case .delayedRegion(let seconds):
            return L10n.selectDelayedRegionPrompt(seconds)
        }
    }

    var completedTitle: String {
        switch self {
        case .region:
            return L10n.capturedRegion
        case .fullScreen:
            return L10n.capturedFullScreen
        case .window:
            return L10n.capturedWindow
        case .delayedRegion(let seconds):
            return L10n.capturedDelayedRegion(seconds)
        }
    }

    var completedAndCopiedTitle: String {
        switch self {
        case .region:
            return L10n.capturedRegionAndCopied
        case .fullScreen:
            return L10n.capturedFullScreenAndCopied
        case .window:
            return L10n.capturedWindowAndCopied
        case .delayedRegion(let seconds):
            return L10n.capturedDelayedRegionAndCopied(seconds)
        }
    }
}
