import AppKit
import XCTest
@testable import CaptureLab

/// Opt-in live WindowServer tests. Only the test's own borderless fixture window is ever captured.
/// CAPTURELAB_SCROLLING_WINDOW_SMOKE=1 enables these; optional *_OUTPUT names a synthetic-artifact directory.
@MainActor
final class ScrollingCaptureWindowSmokeTests: XCTestCase {
    private static let fixtureVersion = 1

    func testNativeVerticalScrollMatchesWindowServerReference() throws { try exercise(direction: .vertical) }
    func testNativeHorizontalScrollMatchesWindowServerReference() throws { try exercise(direction: .horizontal) }

    private func exercise(direction: ScrollingCaptureDirection) throws {
        guard ProcessInfo.processInfo.environment["CAPTURELAB_SCROLLING_WINDOW_SMOKE"] == "1" else {
            throw XCTSkip("Set CAPTURELAB_SCROLLING_WINDOW_SMOKE=1 for a fixture-only WindowServer capture.")
        }
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { throw XCTSkip("No WindowServer display is available.") }
        let viewport = CGSize(width: 340, height: 260)
        let step: CGFloat = 83
        let origin = CGPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40)
        let window = NSWindow(contentRect: CGRect(origin: origin, size: viewport), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isOpaque = true
        window.backgroundColor = .white
        window.colorSpace = .sRGB
        window.hasShadow = false
        let scroll = NSScrollView(frame: CGRect(origin: .zero, size: viewport))
        // Match the reference's layer-backed compositing path from the start.
        scroll.wantsLayer = true
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true; scroll.backgroundColor = .white
        scroll.contentInsets = .init(); scroll.automaticallyAdjustsContentInsets = false
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = ScrollingWindowFixtureView(frame: CGRect(x: 0, y: 0, width: 1_200, height: 1_200))
        window.contentView = scroll
        defer { window.orderOut(nil); window.close() }
        window.orderFrontRegardless()

        func position(_ point: CGPoint) {
            scroll.contentView.scroll(to: point)
            scroll.reflectScrolledClipView(scroll.contentView)
            scroll.documentView?.needsDisplay = true
            window.display()
            // RunLoop.run can return immediately when a source is handled.
            // Use an actual deadline so WindowServer has a compositing turn
            // even while compilation or unrelated desktop events are busy.
            let deadline = Date(timeIntervalSinceNow: 0.2)
            repeat {
                _ = RunLoop.main.run(mode: .default, before: min(deadline, Date(timeIntervalSinceNow: 0.01)))
            } while Date() < deadline
            window.displayIfNeeded()
            XCTAssertEqual(scroll.contentView.bounds.origin.x, point.x, accuracy: 0.01)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, point.y, accuracy: 0.01)
        }

        // AppKit lazily sets up its scrolling surface on the first scroll. Warm up both axes,
        // then reset, so the first capture and resized reference use identical rasterization.
        // Without this, native text can change by 1–3 channel values while its geometry is exact.
        position(CGPoint(x: step, y: step))
        position(.zero)
        let firstImage = try snapshot(window)
        let scale = CGFloat(firstImage.width) / viewport.width
        position(direction == .vertical ? CGPoint(x: 0, y: step) : CGPoint(x: step, y: 0))
        let secondImage = try snapshot(window)
        let first = try ScrollingCapturePixels(image: firstImage)
        let second = try ScrollingCapturePixels(image: secondImage)
        var stitcher = try ScrollingCaptureStitcher(first: first, direction: direction)
        let result = try stitcher.append(second)
        XCTAssertEqual(result, .accepted(addedPixels: Int((step * scale).rounded())))
        let stitched = try stitcher.render()

        let referenceSize = direction == .vertical
            ? CGSize(width: viewport.width, height: viewport.height + step)
            : CGSize(width: viewport.width + step, height: viewport.height)
        window.setContentSize(referenceSize)
        position(.zero)
        let reference = try snapshot(window)
        let actualPixels = try ScrollingCapturePixels(image: stitched)
        let expectedPixels = try ScrollingCapturePixels(image: reference)
        XCTAssertEqual(actualPixels.width, expectedPixels.width)
        XCTAssertEqual(actualPixels.height, expectedPixels.height)
        // Compare all channels, including antialiased native text and the exact seam.
        XCTAssertTrue(actualPixels.bytes == expectedPixels.bytes, "Native scroll and merged WindowServer reference must match pixel-for-pixel.")
        print("WindowServer scrolling fixture v\(Self.fixtureVersion): \(ProcessInfo.processInfo.operatingSystemVersionString), AppKit \(NSAppKitVersion.current.rawValue), screen \(Int(screen.frame.width))×\(Int(screen.frame.height)) pt, backing scale \(scale), \(direction.rawValue), \(firstImage.width)×\(firstImage.height), shift \(Int(step * scale)) px, result \(stitched.width)×\(stitched.height), pixel equality \(actualPixels == expectedPixels)")
        if let folder = ProcessInfo.processInfo.environment["CAPTURELAB_SCROLLING_WINDOW_OUTPUT"] {
            let directory = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, image) in [("first", firstImage), ("second", secondImage), ("stitched", stitched), ("reference", reference)] {
                let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                let url = directory.appendingPathComponent("native-\(direction.rawValue)-\(name).png")
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }

    private func snapshot(_ window: NSWindow) throws -> CGImage {
        typealias Operation = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            throw XCTSkip("The fixture-only WindowServer capture symbol is unavailable.")
        }
        let operation = unsafeBitCast(symbol, to: Operation.self)
        guard let image = operation(.null, CGWindowListOption.optionIncludingWindow.rawValue,
            CGWindowID(window.windowNumber), CGWindowImageOption.boundsIgnoreFraming.union(.bestResolution).rawValue)?.takeRetainedValue() else {
            throw XCTSkip("Fixture WindowServer capture failed; screen-capture preflight = \(CGPreflightScreenCaptureAccess()). No permission was requested.")
        }
        return image
    }
}

private final class ScrollingWindowFixtureView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        for row in 0..<60 {
            for column in 0..<8 {
                let x = CGFloat(column * 150), y = CGFloat(row * 20)
                let code = (row * 97 + column * 61 + 7) % 251
                NSColor(srgbRed: CGFloat(220 + code % 30) / 255,
                        green: CGFloat(221 + (code * 7) % 29) / 255,
                        blue: CGFloat(220 + (code * 3) % 31) / 255, alpha: 1).setFill()
                CGRect(x: x, y: y, width: 147, height: 19).fill()
                let text = "\(row):\(column) \(String(code * 12_347 + row, radix: 16))"
                text.draw(at: CGPoint(x: x + 4, y: y + 2), withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.black
                ])
            }
        }
    }
}
