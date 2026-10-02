import Foundation

enum CaptureAction: String, CaseIterable, Identifiable, Codable {
    case region, fullScreen, window, delayedRegion, lastRegion, launcher, text, qrCode
    var id: String { rawValue }
    var title: String {
        switch self {
        case .region: return L10n.captureRegion
        case .fullScreen: return L10n.captureFullScreen
        case .window: return L10n.captureWindow
        case .delayedRegion: return L10n.captureDelayedRegion(3)
        case .lastRegion: return L10n.lastRegion
        case .launcher: return L10n.captureLauncher
        case .text: return L10n.directText
        case .qrCode: return L10n.directQRCode
        }
    }
    var mode: CaptureMode? {
        switch self {
        case .region, .text, .qrCode: return .region
        case .fullScreen: return .fullScreen
        case .window: return .window
        case .delayedRegion: return .delayedRegion(seconds: 3)
        case .lastRegion: return .lastRegion
        case .launcher: return nil
        }
    }
}

extension L10n {
    static var lastRegion: String { text(en: "Capture Last Region", zh: "重截上次区域") }
    static var frozenRegion: String { text(en: "Freeze and Select", zh: "冻结画面后框选") }
    static var captureLauncher: String { text(en: "Capture Launcher", zh: "统一截图入口") }
    static var directText: String { text(en: "Select Text and Copy", zh: "框选识字并复制") }
    static var directQRCode: String { text(en: "Recognize QR Codes", zh: "框选识别二维码") }
    static var invalidLastRegion: String {
        text(en: "The last region is unavailable or its displays have changed. Select a new region.",
             zh: "上次区域不可用或屏幕配置已变化，请重新框选区域。")
    }
    static var recognitionLanguages: String { text(en: "Recognition Languages", zh: "识别语言") }
}
