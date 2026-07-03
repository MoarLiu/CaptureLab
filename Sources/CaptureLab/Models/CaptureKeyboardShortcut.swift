import AppKit
import SwiftUI

struct CaptureKeyboardShortcut: Codable, Equatable {
    var key: String
    var modifiersRawValue: Int

    init(key: String, modifiers: EventModifiers) {
        self.key = key.lowercased()
        self.modifiersRawValue = modifiers.rawValue
    }

    static let defaultCapture = CaptureKeyboardShortcut(
        key: "n",
        modifiers: [.command, .shift]
    )

    var modifiers: EventModifiers {
        EventModifiers(rawValue: modifiersRawValue)
    }

    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(Character(key))
    }

    var isValid: Bool {
        guard key.count == 1,
              let scalar = key.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar)
        else {
            return false
        }

        return modifiers.contains(.command)
            || modifiers.contains(.control)
            || modifiers.contains(.option)
    }

    var displayTitle: String {
        "\(modifierDisplayTitle)\(key.uppercased())"
    }

    private var modifierDisplayTitle: String {
        var title = ""
        if modifiers.contains(.control) {
            title += "⌃"
        }
        if modifiers.contains(.option) {
            title += "⌥"
        }
        if modifiers.contains(.shift) {
            title += "⇧"
        }
        if modifiers.contains(.command) {
            title += "⌘"
        }
        return title
    }

    static func from(event: NSEvent) -> CaptureKeyboardShortcut? {
        guard let key = normalizedKey(from: event) else {
            return nil
        }
        let shortcut = CaptureKeyboardShortcut(
            key: key,
            modifiers: eventModifiers(from: event.modifierFlags)
        )
        return shortcut.isValid ? shortcut : nil
    }

    private static func normalizedKey(from event: NSEvent) -> String? {
        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar)
        else {
            return nil
        }
        return String(scalar)
    }

    private static func eventModifiers(from flags: NSEvent.ModifierFlags) -> EventModifiers {
        var modifiers: EventModifiers = []
        if flags.contains(.command) {
            modifiers.insert(.command)
        }
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if flags.contains(.option) {
            modifiers.insert(.option)
        }
        if flags.contains(.control) {
            modifiers.insert(.control)
        }
        return modifiers
    }
}
