import SwiftUI
import XCTest
@testable import CaptureLab

final class CaptureShortcutStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "CaptureShortcutStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    @MainActor
    func testLoadsDefaultShortcutWhenNoStoredValueExists() {
        let store = CaptureShortcutStore(defaults: defaults)

        XCTAssertEqual(store.captureShortcut, .defaultCapture)
        XCTAssertEqual(store.captureShortcut.displayTitle, "⇧⌘N")
    }

    @MainActor
    func testSavesAndReloadsShortcut() {
        let shortcut = CaptureKeyboardShortcut(key: "s", modifiers: [.command, .option])
        let store = CaptureShortcutStore(defaults: defaults)

        store.saveCaptureShortcut(shortcut)
        let reloaded = CaptureShortcutStore(defaults: defaults)

        XCTAssertEqual(reloaded.captureShortcut, shortcut)
        XCTAssertEqual(reloaded.captureShortcut.displayTitle, "⌥⌘S")
    }

    @MainActor
    func testIgnoresInvalidShortcut() {
        let store = CaptureShortcutStore(defaults: defaults)
        let invalid = CaptureKeyboardShortcut(key: "x", modifiers: [.shift])

        store.saveCaptureShortcut(invalid)

        XCTAssertEqual(store.captureShortcut, .defaultCapture)
    }

    @MainActor
    func testRegistrationFailurePreservesStoredShortcut() {
        let store = CaptureShortcutStore(defaults: defaults)
        let replacement = CaptureKeyboardShortcut(key: "s", modifiers: [.command, .option])
        var didAttemptRegistration = false

        let didSave = store.saveCaptureShortcut(
            replacement,
            afterRegistering: {
                didAttemptRegistration = true
                return false
            }
        )

        XCTAssertFalse(didSave)
        XCTAssertTrue(didAttemptRegistration)
        XCTAssertEqual(store.captureShortcut, .defaultCapture)
        XCTAssertEqual(CaptureShortcutStore(defaults: defaults).captureShortcut, .defaultCapture)
    }

    @MainActor
    func testUnsupportedCarbonKeyIsInvalidAndNeverAttemptsRegistration() {
        let store = CaptureShortcutStore(defaults: defaults)
        let unsupported = CaptureKeyboardShortcut(key: "中", modifiers: [.command])
        var didAttemptRegistration = false

        let didSave = store.saveCaptureShortcut(
            unsupported,
            afterRegistering: {
                didAttemptRegistration = true
                return true
            }
        )

        XCTAssertFalse(unsupported.isValid)
        XCTAssertFalse(didSave)
        XCTAssertFalse(didAttemptRegistration)
        XCTAssertEqual(store.captureShortcut, .defaultCapture)
    }
}
