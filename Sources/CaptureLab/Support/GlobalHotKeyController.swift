import Carbon
import Foundation

@MainActor
final class GlobalHotKeyController: ObservableObject {
    typealias RegisterOperation = (
        UInt32,
        UInt32,
        EventHotKeyID,
        inout EventHotKeyRef?
    ) -> OSStatus
    typealias UnregisterOperation = (EventHotKeyRef) -> OSStatus

    @Published private(set) var registrationError: String?
    private(set) var registeredShortcut: CaptureKeyboardShortcut?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var action: (() -> Void)?
    private var nextHotKeyID: UInt32 = 1
    private let registerOperation: RegisterOperation
    private let unregisterOperation: UnregisterOperation
    private let installEventHandlerOverride: (() -> OSStatus)?

    init(
        registerOperation: @escaping RegisterOperation = { keyCode, modifiers, hotKeyID, hotKeyRef in
            RegisterEventHotKey(
                keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
        },
        unregisterOperation: @escaping UnregisterOperation = { UnregisterEventHotKey($0) },
        installEventHandlerOverride: (() -> OSStatus)? = nil
    ) {
        self.registerOperation = registerOperation
        self.unregisterOperation = unregisterOperation
        self.installEventHandlerOverride = installEventHandlerOverride
    }

    @discardableResult
    func configure(shortcut: CaptureKeyboardShortcut, action: @escaping () -> Void) -> Bool {
        if shortcut == registeredShortcut, hotKeyRef != nil {
            self.action = action
            registrationError = nil
            return true
        }

        guard shortcut.isValid, let keyCode = shortcut.carbonKeyCode else {
            registrationError = L10n.globalShortcutUnsupported(shortcut.displayTitle)
            return false
        }

        let handlerStatus = installEventHandlerIfNeeded()
        guard handlerStatus == noErr else {
            registrationError = L10n.globalShortcutHandlerInstallFailed
            return false
        }

        let hotKeyID = EventHotKeyID(
            signature: GlobalHotKeyController.hotKeySignature,
            id: nextHotKeyID
        )
        var newHotKeyRef: EventHotKeyRef?
        let status = registerOperation(
            keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            &newHotKeyRef
        )

        guard status == noErr, let newHotKeyRef else {
            if let newHotKeyRef {
                _ = unregisterOperation(newHotKeyRef)
            }
            registrationError = L10n.globalShortcutRegistrationFailed(shortcut.displayTitle)
            return false
        }

        // Keep the old hot key alive until the replacement is known to be
        // registered. A conflicting/unsupported replacement therefore cannot
        // leave the app without its previous working shortcut.
        if let oldHotKeyRef = hotKeyRef {
            guard unregisterOperation(oldHotKeyRef) == noErr else {
                _ = unregisterOperation(newHotKeyRef)
                registrationError = L10n.globalShortcutRegistrationFailed(shortcut.displayTitle)
                return false
            }
        }
        hotKeyRef = newHotKeyRef
        registeredShortcut = shortcut
        self.action = action
        nextHotKeyID &+= 1
        registrationError = nil
        return true
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
            _ = unregisterOperation(hotKeyRef)
            self.hotKeyRef = nil
            registeredShortcut = nil
        }
    }

    private func installEventHandlerIfNeeded() -> OSStatus {
        guard eventHandlerRef == nil else {
            return noErr
        }

        if let installEventHandlerOverride {
            return installEventHandlerOverride()
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
