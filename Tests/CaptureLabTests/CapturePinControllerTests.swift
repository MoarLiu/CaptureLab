import AppKit
import XCTest
@testable import CaptureLab

@MainActor
final class CapturePinControllerTests: XCTestCase {
    func testPinsFloatAcrossAppAndSpaceChangesAndPreserveImageProportions() throws {
        _ = NSApplication.shared
        let controller = CapturePinController()
        controller.pin(image: try fixtureImage(), title: "Fixture")
        let window = try XCTUnwrap(controller.windows.first)
        defer { window.close() }

        XCTAssertEqual(window.title, "Fixture")
        XCTAssertEqual(window.level, .floating)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        let imageView = try XCTUnwrap(window.contentView?.subviews.compactMap { $0 as? NSImageView }.first)
        XCTAssertEqual(imageView.imageScaling, .scaleProportionallyUpOrDown)
        XCTAssertEqual(imageView.image?.size, CGSize(width: 160, height: 96))

        window.setContentSize(CGSize(width: 540, height: 420))
        XCTAssertEqual(imageView.imageScaling, .scaleProportionallyUpOrDown)
        XCTAssertEqual(imageView.image?.size, CGSize(width: 160, height: 96))
    }

    func testOpacityAndCloseShortcutsAffectOnlyTheirPinAndReleaseClosedWindow() throws {
        _ = NSApplication.shared
        let controller = CapturePinController()
        controller.pin(image: try fixtureImage(), title: "First")
        defer { controller.windows.forEach { $0.close() } }
        let first = try XCTUnwrap(controller.windows.first)
        let releasedSecond = PinWeakReference<NSWindow>()

        let controls = try XCTUnwrap(first.contentView?.subviews.flatMap(\.subviews).compactMap { $0 as? NSStackView }.first)
        let slider = try XCTUnwrap(controls.arrangedSubviews.compactMap { $0 as? NSSlider }.first)
        try autoreleasepool {
            controller.pin(image: try fixtureImage(), title: "Second")
            XCTAssertEqual(controller.windows.count, 2)
            let second = try XCTUnwrap(controller.windows.last)
            releasedSecond.value = second
            slider.doubleValue = 0.55
            slider.sendAction(slider.action, to: slider.target)
            let firstImageView = try XCTUnwrap(first.contentView?.subviews.compactMap { $0 as? NSImageView }.first)
            let secondImageView = try XCTUnwrap(second.contentView?.subviews.compactMap { $0 as? NSImageView }.first)
            XCTAssertEqual(firstImageView.alphaValue, 0.55, accuracy: 0.001)
            XCTAssertEqual(secondImageView.alphaValue, 1)
            XCTAssertEqual(first.alphaValue, 1)
            XCTAssertEqual(second.alphaValue, 1)

            let escape = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: second.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
            ))
            second.keyDown(with: escape)
        }
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        XCTAssertEqual(controller.windows.count, 1)
        XCTAssertNil(releasedSecond.value)
        XCTAssertTrue(controller.windows.first === first)

        let closeShortcut = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: first.windowNumber, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13
        ))
        XCTAssertTrue(first.performKeyEquivalent(with: closeShortcut))
        XCTAssertTrue(controller.windows.isEmpty)
    }

    func testEscapeClosesPinWhenOpacitySliderHasFocus() throws {
        _ = NSApplication.shared
        let controller = CapturePinController()
        controller.pin(image: try fixtureImage(), title: "Focused controls")
        let window = try XCTUnwrap(controller.windows.first)
        defer { window.close() }
        let controls = try XCTUnwrap(window.contentView?.subviews.flatMap(\.subviews).compactMap { $0 as? NSStackView }.first)
        let slider = try XCTUnwrap(controls.arrangedSubviews.compactMap { $0 as? NSSlider }.first)
        window.makeFirstResponder(slider)
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        slider.keyDown(with: escape)
        XCTAssertTrue(controller.windows.isEmpty)
    }

    private func fixtureImage() throws -> NSImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 160, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 96))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 160, height: 96))
    }
}

private final class PinWeakReference<Value: AnyObject> {
    weak var value: Value?
}
