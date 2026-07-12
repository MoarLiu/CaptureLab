import Carbon
import SwiftUI
import XCTest
@testable import CaptureLab

@MainActor
final class GlobalHotKeyControllerTests: XCTestCase {
    func testDefaultShortcutMapsToCarbonKeyCode() {
        XCTAssertEqual(CaptureKeyboardShortcut.defaultCapture.carbonKeyCode, 45)
    }

    func testCarbonModifiersIncludeConfiguredModifiers() {
        let shortcut = CaptureKeyboardShortcut(key: "n", modifiers: [.command, .shift])

        XCTAssertEqual(shortcut.carbonModifiers, UInt32(cmdKey | shiftKey))
    }

    func testUnsupportedShortcutKeyHasNoCarbonKeyCode() {
        let shortcut = CaptureKeyboardShortcut(key: "中", modifiers: [.command])

        XCTAssertNil(shortcut.carbonKeyCode)
        XCTAssertFalse(shortcut.isValid)
    }

    func testShortcutRejectsModifiersThatCarbonRegistrationDoesNotPreserve() {
        let shortcut = CaptureKeyboardShortcut(key: "n", modifiers: [.command, .capsLock])

        XCTAssertFalse(shortcut.isValid)
    }

    func testFailedReplacementKeepsOldRegistrationAndCleansReturnedReference() {
        let firstRef = OpaquePointer(bitPattern: 1)!
        let failedRef = OpaquePointer(bitPattern: 2)!
        var registrationAttempt = 0
        var unregistered: [EventHotKeyRef] = []
        let controller = GlobalHotKeyController(
            registerOperation: { _, _, _, hotKeyRef in
                registrationAttempt += 1
                if registrationAttempt == 1 {
                    hotKeyRef = firstRef
                    return noErr
                }
                hotKeyRef = failedRef
                return OSStatus(eventHotKeyExistsErr)
            },
            unregisterOperation: {
                unregistered.append($0)
                return noErr
            },
            installEventHandlerOverride: { noErr }
        )
        let original = CaptureKeyboardShortcut.defaultCapture
        let replacement = CaptureKeyboardShortcut(key: "s", modifiers: [.command, .option])

        XCTAssertTrue(controller.configure(shortcut: original, action: {}))
        XCTAssertFalse(controller.configure(shortcut: replacement, action: {}))

        XCTAssertEqual(controller.registeredShortcut, original)
        XCTAssertEqual(unregistered, [failedRef])
        XCTAssertNotNil(controller.registrationError)
    }

    func testSuccessfulReplacementUnregistersOldOnlyAfterNewRegistrationSucceeds() {
        let firstRef = OpaquePointer(bitPattern: 11)!
        let secondRef = OpaquePointer(bitPattern: 12)!
        var events: [String] = []
        var references = [firstRef, secondRef]
        let controller = GlobalHotKeyController(
            registerOperation: { _, _, _, hotKeyRef in
                let reference = references.removeFirst()
                events.append("register-\(reference)")
                hotKeyRef = reference
                return noErr
            },
            unregisterOperation: {
                events.append("unregister-\($0)")
                return noErr
            },
            installEventHandlerOverride: { noErr }
        )
        let original = CaptureKeyboardShortcut.defaultCapture
        let replacement = CaptureKeyboardShortcut(key: "s", modifiers: [.command, .option])

        XCTAssertTrue(controller.configure(shortcut: original, action: {}))
        XCTAssertTrue(controller.configure(shortcut: replacement, action: {}))

        XCTAssertEqual(controller.registeredShortcut, replacement)
        XCTAssertEqual(events, [
            "register-\(firstRef)",
            "register-\(secondRef)",
            "unregister-\(firstRef)"
        ])
        XCTAssertNil(controller.registrationError)
    }

    func testOldUnregistrationFailureRollsBackNewRegistration() {
        let firstRef = OpaquePointer(bitPattern: 21)!
        let secondRef = OpaquePointer(bitPattern: 22)!
        var references = [firstRef, secondRef]
        var unregistered: [EventHotKeyRef] = []
        let controller = GlobalHotKeyController(
            registerOperation: { _, _, _, hotKeyRef in
                hotKeyRef = references.removeFirst()
                return noErr
            },
            unregisterOperation: { reference in
                unregistered.append(reference)
                return reference == firstRef ? OSStatus(paramErr) : noErr
            },
            installEventHandlerOverride: { noErr }
        )
        let original = CaptureKeyboardShortcut.defaultCapture
        let replacement = CaptureKeyboardShortcut(key: "s", modifiers: [.command, .option])

        XCTAssertTrue(controller.configure(shortcut: original, action: {}))
        XCTAssertFalse(controller.configure(shortcut: replacement, action: {}))

        XCTAssertEqual(controller.registeredShortcut, original)
        XCTAssertEqual(unregistered, [firstRef, secondRef])
        XCTAssertNotNil(controller.registrationError)
    }
}
