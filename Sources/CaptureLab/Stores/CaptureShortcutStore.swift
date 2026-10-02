import Foundation

@MainActor
final class CaptureShortcutStore: ObservableObject {
    @Published private(set) var captureShortcut: CaptureKeyboardShortcut
    @Published private(set) var shortcuts: [CaptureAction: CaptureKeyboardShortcut] = [:]

    func shortcut(for action: CaptureAction) -> CaptureKeyboardShortcut? { shortcuts[action] }

    func conflict(for shortcut: CaptureKeyboardShortcut, action: CaptureAction) -> CaptureAction? {
        CaptureAction.allCases.first { $0 != action && shortcuts[$0]?.conflicts(with: shortcut) == true }
    }

    @discardableResult
    func save(_ shortcut: CaptureKeyboardShortcut?, for action: CaptureAction, afterRegistering register: () -> Bool) -> Bool {
        if let shortcut {
            guard shortcut.isValid, conflict(for: shortcut, action: action) == nil else { return false }
        } else if action == .region { return false }
        guard register() else { return false }
        shortcuts[action] = shortcut
        if action == .region, let shortcut {
            captureShortcut = shortcut
            defaults.set(try? JSONEncoder().encode(shortcut), forKey: storageKey)
        }
        let values = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        defaults.set(try? JSONEncoder().encode(values), forKey: "captureActionShortcuts.v1")
        return true
    }

    private let defaults: UserDefaults
    private let storageKey = "captureShortcut"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.captureShortcut = Self.loadCaptureShortcut(from: defaults, key: storageKey)
        shortcuts[.region] = captureShortcut
        if let data = defaults.data(forKey: "captureActionShortcuts.v1"),
           let saved = try? JSONDecoder().decode([String: CaptureKeyboardShortcut].self, from: data) {
            for action in CaptureAction.allCases {
                if let value = saved[action.rawValue], value.isValid, conflict(for: value, action: action) == nil {
                    shortcuts[action] = value
                }
            }
            captureShortcut = shortcuts[.region] ?? captureShortcut
        }
    }

    @discardableResult
    func saveCaptureShortcut(
        _ shortcut: CaptureKeyboardShortcut,
        afterRegistering register: () -> Bool = { true }
    ) -> Bool {
        save(shortcut, for: .region, afterRegistering: register)
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
