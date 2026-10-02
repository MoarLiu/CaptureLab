import Foundation

enum CaptureAfterAction: String, Codable, CaseIterable {
    case editor, overlay, copyOnly
    var title: String {
        switch self {
        case .editor: return L10n.text(en: "Open editor", zh: "直接编辑")
        case .overlay: return L10n.text(en: "Quick access overlay", zh: "快捷浮层")
        case .copyOnly: return L10n.text(en: "Copy only", zh: "仅复制")
        }
    }
}

enum CaptureOverlayCorner: String, Codable, CaseIterable {
    case bottomRight, bottomLeft, topRight, topLeft
    var title: String {
        switch self {
        case .bottomRight: return L10n.text(en: "Bottom right", zh: "右下角")
        case .bottomLeft: return L10n.text(en: "Bottom left", zh: "左下角")
        case .topRight: return L10n.text(en: "Top right", zh: "右上角")
        case .topLeft: return L10n.text(en: "Top left", zh: "左上角")
        }
    }
}

struct CaptureWorkflowOptions: Codable, Equatable {
    var afterCapture: CaptureAfterAction = .editor
    var corner: CaptureOverlayCorner = .bottomRight
    var overlayWidth: Int = 320
    var autoCloseSeconds: Int = 15
    var followsCaptureScreen = true

    var validated: Self {
        var result = self
        if ![280, 320, 400].contains(result.overlayWidth) { result.overlayWidth = 320 }
        if ![0, 5, 15, 30, 60].contains(result.autoCloseSeconds) { result.autoCloseSeconds = 15 }
        return result
    }
}

@MainActor
final class CaptureWorkflowSettings: ObservableObject {
    @Published var options: CaptureWorkflowOptions {
        didSet {
            if let data = try? JSONEncoder().encode(options.validated) {
                defaults?.set(data, forKey: Self.key)
            }
        }
    }
    private let defaults: UserDefaults?
    private static let key = "captureWorkflow.v1"

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        options = defaults?.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(CaptureWorkflowOptions.self, from: $0) }?
            .validated ?? CaptureWorkflowOptions()
    }
}

struct CaptureHistoryRetention: Codable, Equatable {
    var maximumCount = 30
    var maximumAgeDays: Int? = nil
    static let `default` = Self()

    var validated: Self {
        Self(maximumCount: [30, 100, 300].contains(maximumCount) ? maximumCount : 30,
             maximumAgeDays: [1, 7, 30].contains(maximumAgeDays ?? 0) ? maximumAgeDays : nil)
    }

    func retaining(_ items: [CaptureHistoryItem], now: Date) -> [CaptureHistoryItem] {
        let policy = validated
        let cutoff = policy.maximumAgeDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
        return Array(items.filter { cutoff == nil || ($0.modifiedAt ?? $0.createdAt) >= cutoff! }.prefix(policy.maximumCount))
    }
}
