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

    @discardableResult
    func saveCaptureShortcut(
        _ shortcut: CaptureKeyboardShortcut,
        afterRegistering register: () -> Bool = { true }
    ) -> Bool {
        guard shortcut.isValid else {
            return false
        }
        guard let data = try? JSONEncoder().encode(shortcut) else {
            return false
        }
        guard register() else {
            return false
        }
        defaults.set(data, forKey: storageKey)
        captureShortcut = shortcut
        return true
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
