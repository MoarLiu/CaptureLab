import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureEditorUITests: XCTestCase {
    func testEditorFitsMinimumWindowWidthAndEscapeCancelsCropWithoutClosingWindow() throws {
        _ = NSApplication.shared
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureEditorUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path]
        let history = CaptureHistoryStore(environment: environment)
        let image = try fixtureImage()
        let item = try history.record(data: XCTUnwrap(image.captureLabPNGData()), pixelSize: image.captureLabPixelSize)
        let model = CaptureLabViewModel(
            r2SettingsStore: CloudflareR2SettingsStore(environment: environment, secretStore: EditorUITestSecretStore()),
            historyStore: history,
            failurePresentationOperation: { _, message in XCTFail(message) },
            pasteboard: NSPasteboard(name: .init("CaptureEditorUITests.\(UUID().uuidString)"))
        )
        model.openHistoryItem(item)
        let defaultsName = "CaptureEditorUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let root = CaptureLabRootView(model: model, shortcutStore: CaptureShortcutStore(defaults: defaults), showHistory: {})
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_080, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        CaptureLabAppDelegate.allowNextMainWindowPresentation()
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        drainUI()
        hosting.layoutSubtreeIfNeeded()
        window.display()

        XCTAssertTrue(window.isVisible)
        XCTAssertLessThanOrEqual(hosting.fittingSize.width, 1_080, "The editor's content must fit its minimum supported width.")
        XCTAssertEqual(hosting.bounds.width, 1_080, accuracy: 1)
        let optionRow = CGRect(x: 0, y: 52, width: hosting.bounds.width, height: 46)
        let nativeControls = nativeDescendants(of: hosting).filter { $0 is NSColorWell || $0 is NSStepper }
        XCTAssertEqual(nativeControls.filter { $0 is NSColorWell }.count, 1)
        XCTAssertEqual(nativeControls.filter { $0 is NSStepper }.count, 2)
        for control in nativeControls {
            XCTAssertFalse(control.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(optionRow.contains(control.convert(control.bounds, to: hosting)), "Style controls must be visible inside the second toolbar row.")
        }
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.display()
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertGreaterThan(luminanceRange(in: optionRow, bitmap: bitmap, view: hosting), 0.15,
            "The second toolbar row must render controls and labels rather than a blank background.")
        if let outputPath = ProcessInfo.processInfo.environment["CAPTURELAB_UI_SMOKE_OUTPUT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: outputPath))
        }
        if let outputPath = ProcessInfo.processInfo.environment["CAPTURELAB_UI_SMOKE_WINDOW_OUTPUT"] {
            try saveFixtureWindowSnapshot(window, to: URL(fileURLWithPath: outputPath))
        }
        if ProcessInfo.processInfo.environment["CAPTURELAB_UI_SMOKE_INSPECT"] == "1" {
            inspectFixtureView(hosting)
        }

        model.selectedTool = .crop
        model.cropSelection = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        drainUI()
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        NSApp.postEvent(escape, atStart: true)
        if let event = NSApp.nextEvent(matching: .keyDown, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        drainUI()

        XCTAssertNil(model.cropSelection)
        XCTAssertEqual(model.selectedTool, .select)
        XCTAssertTrue(window.isVisible, "Esc during cropping must preserve the editor window.")
    }

    private func drainUI() {
        for _ in 0..<4 {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private func nativeDescendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + nativeDescendants(of: $0) }
    }

    private func luminanceRange(in rect: CGRect, bitmap: NSBitmapImageRep, view: NSView) -> CGFloat {
        let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        let top = view.isFlipped ? rect.minY : view.bounds.height - rect.maxY
        var minimum: CGFloat = 1
        var maximum: CGFloat = 0
        for y in stride(from: Int(top * scaleY) + 4, to: Int((top + rect.height) * scaleY) - 4, by: 4) {
            for x in stride(from: Int(rect.minX * scaleX) + 8, to: Int(rect.maxX * scaleX) - 8, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = color.redComponent * 0.21 + color.greenComponent * 0.72 + color.blueComponent * 0.07
                minimum = min(minimum, luminance)
                maximum = max(maximum, luminance)
            }
        }
        return maximum - minimum
    }

    private func saveFixtureWindowSnapshot(_ window: NSWindow, to url: URL) throws {
        // Resolve this legacy symbol only for an explicitly requested test
        // artifact: newer SDKs obsolete its source declaration. Including one
        // known fixture window never composites the user's other windows.
        typealias WindowImageOperation = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"))
        let operation = unsafeBitCast(symbol, to: WindowImageOperation.self)
        let image = try XCTUnwrap(operation(
            .null, CGWindowListOption.optionIncludingWindow.rawValue,
            CGWindowID(window.windowNumber), CGWindowImageOption.boundsIgnoreFraming.rawValue
        )?.takeRetainedValue(), "The fixture window snapshot could not be created.")
        let bitmap = NSBitmapImageRep(cgImage: image)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func inspectFixtureView(_ view: NSView, depth: Int = 0) {
        print("\(String(repeating: " ", count: depth))\(type(of: view)): \(view.frame)")
        view.subviews.forEach { inspectFixtureView($0, depth: depth + 1) }
    }

    private func fixtureImage() throws -> NSImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 640, height: 360))
    }
}

private struct EditorUITestSecretStore: CloudflareR2SecretStoring {
    func secret(for accessKeyID: String) throws -> String? { nil }
    func setSecret(_ secret: String, for accessKeyID: String) throws {}
    func deleteSecret(for accessKeyID: String) throws {}
}
