import Carbon
import Foundation

@MainActor
final class GlobalHotKeyController: ObservableObject {
    @Published private(set) var registrationError: String?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    func configure(shortcut: CaptureKeyboardShortcut, action: @escaping () -> Void) {
        self.action = action
        register(shortcut)
    }

    private func register(_ shortcut: CaptureKeyboardShortcut) {
        unregisterHotKey()

        guard let keyCode = shortcut.carbonKeyCode else {
            registrationError = L10n.globalShortcutUnsupported(shortcut.displayTitle)
            return
        }

        let handlerStatus = installEventHandlerIfNeeded()
        guard handlerStatus == noErr else {
            registrationError = L10n.globalShortcutHandlerInstallFailed
            return
        }

        let hotKeyID = EventHotKeyID(
            signature: GlobalHotKeyController.hotKeySignature,
            id: 1
        )
        var newHotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newHotKeyRef
        )

        guard status == noErr, let newHotKeyRef else {
            registrationError = L10n.globalShortcutRegistrationFailed(shortcut.displayTitle)
            return
        }

        hotKeyRef = newHotKeyRef
        registrationError = nil
    }

    private func unregister() {
        unregisterHotKey()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installEventHandlerIfNeeded() -> OSStatus {
        guard eventHandlerRef == nil else {
            return noErr
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        return InstallEventHandler(
            GetApplicationEventTarget(),
            GlobalHotKeyController.eventHandler,
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
    }

    private func handleHotKey() {
        action?()
    }

    private static let hotKeySignature: OSType = 0x434C484B // CLHK

    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event,
              let userData
        else {
            return noErr
        }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr,
              hotKeyID.signature == GlobalHotKeyController.hotKeySignature
        else {
            return noErr
        }

        let controller = Unmanaged<GlobalHotKeyController>
            .fromOpaque(userData)
            .takeUnretainedValue()
        Task { @MainActor in
            controller.handleHotKey()
        }
        return noErr
    }
}

extension CaptureKeyboardShortcut {
    var carbonKeyCode: UInt32? {
        Self.carbonKeyCodes[key].map(UInt32.init)
    }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) {
            value |= UInt32(cmdKey)
        }
        if modifiers.contains(.shift) {
            value |= UInt32(shiftKey)
        }
        if modifiers.contains(.option) {
            value |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            value |= UInt32(controlKey)
        }
        return value
    }

    private static let carbonKeyCodes: [String: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50
    ]
}
