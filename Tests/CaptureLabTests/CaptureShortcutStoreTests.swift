import SwiftUI
import XCTest
@testable import CaptureLab

@MainActor
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

    func testLoadsDefaultShortcutWhenNoStoredValueExists() {
        let store = CaptureShortcutStore(defaults: defaults)

        XCTAssertEqual(store.captureShortcut, .defaultCapture)
        XCTAssertEqual(store.captureShortcut.displayTitle, "⇧⌘N")
    }

    func testSavesAndReloadsShortcut() {
        let shortcut = CaptureKeyboardShortcut(key: "s", modifiers: [.command, .option])
        let store = CaptureShortcutStore(defaults: defaults)

        store.saveCaptureShortcut(shortcut)
        let reloaded = CaptureShortcutStore(defaults: defaults)

        XCTAssertEqual(reloaded.captureShortcut, shortcut)
        XCTAssertEqual(reloaded.captureShortcut.displayTitle, "⌥⌘S")
    }

    func testIgnoresInvalidShortcut() {
        let store = CaptureShortcutStore(defaults: defaults)
        let invalid = CaptureKeyboardShortcut(key: "x", modifiers: [.shift])

        store.saveCaptureShortcut(invalid)

        XCTAssertEqual(store.captureShortcut, .defaultCapture)
    }
}
