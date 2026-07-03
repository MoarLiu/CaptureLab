import Carbon
import SwiftUI
import XCTest
@testable import CaptureLab

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
    }
}

