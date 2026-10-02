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
    @Published private(set) var actionErrors: [CaptureAction: String] = [:]
    var registeredShortcut: CaptureKeyboardShortcut? { registrations[.region]?.shortcut }
    func registeredShortcut(for action: CaptureAction) -> CaptureKeyboardShortcut? { registrations[action]?.shortcut }
    private struct Registration {
        let reference: EventHotKeyRef
        let shortcut: CaptureKeyboardShortcut
        let id: UInt32
        var perform: () -> Void
    }
    private var registrations: [CaptureAction: Registration] = [:]
    private var eventHandlerRef: EventHandlerRef?
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
        configure(action: .region, shortcut: shortcut, perform: action)
    }

    @discardableResult
    func configure(action: CaptureAction, shortcut: CaptureKeyboardShortcut?, perform: @escaping () -> Void) -> Bool {
        func fail(_ message: String) -> Bool {
            actionErrors[action] = message
            registrationError = message
            return false
        }
        guard let shortcut else {
            if let old = registrations[action] {
                let status = unregisterOperation(old.reference)
                guard status == noErr else { return fail("OSStatus: \(status)") }
                registrations[action] = nil
            }
            actionErrors[action] = nil
            registrationError = actionErrors.values.sorted().first
            return true
        }
        if let old = registrations[action], shortcut == old.shortcut {
            registrations[action]?.perform = perform
            actionErrors[action] = nil
            registrationError = actionErrors.values.sorted().first
            return true
        }
        guard shortcut.isValid, let keyCode = shortcut.carbonKeyCode else {
            return fail(L10n.globalShortcutUnsupported(shortcut.displayTitle))
        }
        if let conflict = registrations.first(where: { $0.key != action && $0.value.shortcut.conflicts(with: shortcut) }) {
            return fail(L10n.text(en: "Already assigned to \(conflict.key.title).", zh: "已用于“\(conflict.key.title)”。"))
        }
        // A layout can change the label while the physical binding stays identical.
        if let old = registrations[action], old.shortcut.conflicts(with: shortcut) {
            registrations[action] = Registration(reference: old.reference, shortcut: shortcut, id: old.id, perform: perform)
            actionErrors[action] = nil
            registrationError = actionErrors.values.sorted().first
            return true
        }
        let handlerStatus = installEventHandlerIfNeeded()
        guard handlerStatus == noErr else {
            return fail(L10n.globalShortcutHandlerInstallFailed + " (OSStatus: \(handlerStatus))")
        }
        let id = nextHotKeyID
        nextHotKeyID &+= 1
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: id)
        var newRef: EventHotKeyRef?
        let status = registerOperation(keyCode, shortcut.carbonModifiers, hotKeyID, &newRef)
        guard status == noErr, let newRef else {
            if let newRef { _ = unregisterOperation(newRef) }
            return fail(L10n.globalShortcutRegistrationFailed(shortcut.displayTitle) + " (OSStatus: \(status))")
        }
        if let old = registrations[action] {
            let oldStatus = unregisterOperation(old.reference)
            guard oldStatus == noErr else {
                _ = unregisterOperation(newRef)
                return fail(L10n.globalShortcutRegistrationFailed(shortcut.displayTitle) + " (OSStatus: \(oldStatus))")
            }
        }
        registrations[action] = Registration(reference: newRef, shortcut: shortcut, id: id, perform: perform)
        actionErrors[action] = nil
        registrationError = actionErrors.values.sorted().first
        return true
    }

    func shutdown() {
        for registration in registrations.values { _ = unregisterOperation(registration.reference) }
        registrations.removeAll()
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef); self.eventHandlerRef = nil }
    }

    func handleHotKey(id: UInt32) {
        registrations.values.first { $0.id == id }?.perform()
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
            controller.handleHotKey(id: hotKeyID.id)
        }
        return noErr
    }
}

extension CaptureKeyboardShortcut {
    var carbonKeyCode: UInt32? {
        physicalKeyCode.map(UInt32.init) ?? Self.carbonKeyCodes[key].map(UInt32.init)
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
