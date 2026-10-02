import AppKit
import SwiftUI

struct CaptureKeyboardShortcut: Codable, Equatable {
    var key: String
    var modifiersRawValue: Int
    var physicalKeyCode: UInt16?

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
        let supportedModifiers: EventModifiers = [.command, .shift, .option, .control]
        guard key.count == 1,
              let scalar = key.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              carbonKeyCode != nil,
              (physicalKeyCode.map { Self.isRecordableKeyCode($0) } ?? true),
              modifiers.isSubset(of: supportedModifiers)
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
        var shortcut = CaptureKeyboardShortcut(
            key: key,
            modifiers: eventModifiers(from: event.modifierFlags)
        )
        shortcut.physicalKeyCode = event.keyCode
        return shortcut.isValid ? shortcut : nil
    }

    static func isRecordableKeyCode(_ code: UInt16) -> Bool {
        (code <= 50 && ![36, 48, 49].contains(code)) || [93, 94, 95, 102].contains(code)
    }

    func conflicts(with other: Self) -> Bool {
        carbonKeyCode == other.carbonKeyCode && carbonModifiers == other.carbonModifiers
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
