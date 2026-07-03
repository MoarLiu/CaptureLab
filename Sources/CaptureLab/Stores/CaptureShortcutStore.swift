import Foundation

@MainActor
final class CaptureShortcutStore: ObservableObject {
    @Published private(set) var captureShortcut: CaptureKeyboardShortcut

    private let defaults: UserDefaults
    private let storageKey = "captureShortcut"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.captureShortcut = Self.loadCaptureShortcut(from: defaults, key: storageKey)
    }

    func saveCaptureShortcut(_ shortcut: CaptureKeyboardShortcut) {
        guard shortcut.isValid else {
            return
        }

        captureShortcut = shortcut

        if let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func loadCaptureShortcut(from defaults: UserDefaults, key: String) -> CaptureKeyboardShortcut {
        guard let data = defaults.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(CaptureKeyboardShortcut.self, from: data),
              shortcut.isValid
        else {
            return .defaultCapture
        }
        return shortcut
    }
}
