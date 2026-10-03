import AppKit
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureScrollingWorkflowTests: XCTestCase {
    func testSelectionAndSessionCancellationRestoreWindowsAndPreserveEditing() async throws {
        for cancellation: Error in [CaptureLabError.captureCancelled, CancellationError()] {
            let fixture = try ScrollingWorkflowFixture()
            defer { fixture.cleanUp() }
            let model = fixture.model
            XCTAssertTrue(model.importImageData(fixture.png))
            model.annotations = [.text(normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.3), text: "Keep editing")]
            let documentID = model.document?.id
            let before = model.annotations
            fixture.pasteboard.setString("keep clipboard", forType: .string)

            model.captureScrolling(.vertical) { _ in throw cancellation }
            await waitForCapture(model)

            XCTAssertEqual(model.statusMessage, L10n.captureCancelled)
            XCTAssertTrue(fixture.failures.isEmpty)
            XCTAssertEqual(model.document?.id, documentID)
            XCTAssertEqual(model.annotations, before)
            XCTAssertTrue(model.canUndoAnnotation)
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), "keep clipboard")
            XCTAssertEqual(fixture.visibility.restores, 1)
            XCTAssertFalse(model.overlayController.isCapturing)
        }
    }

    func testScrollingFailureAllowsNextCaptureAndRestoresEditableHistory() async throws {
        let fixture = try ScrollingWorkflowFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.captureScrolling(.horizontal) { _ in throw ScrollingCaptureIssue.dimensionsChanged }
        await waitForCapture(model)
        XCTAssertEqual(fixture.failures.count, 1)
        XCTAssertFalse(model.hasImage)

        var editorPresentations = 0
        model.presentEditor = { editorPresentations += 1 }
        model.captureScrolling(.horizontal) { direction in
            XCTAssertEqual(direction, .horizontal)
            return fixture.image
        }
        await waitForCapture(model)
        XCTAssertEqual(editorPresentations, 1)
        XCTAssertEqual(model.document?.sourcePixelSize, fixture.image.captureLabPixelSize)
        XCTAssertEqual(NSImage(pasteboard: fixture.pasteboard)?.captureLabPixelSize, fixture.image.captureLabPixelSize)
        let item = try XCTUnwrap(model.historyItems.first)
        XCTAssertNotNil(item.projectFileName)
        model.clearDocument()
        model.openHistoryItem(item)
        XCTAssertEqual(model.document?.sourcePixelSize, fixture.image.captureLabPixelSize)
        XCTAssertEqual(fixture.visibility.restores, 2)
        XCTAssertEqual(fixture.failures.count, 1)
    }

    func testScrollingCopyOnlyPreservesCurrentCompositionAndProducesSnapshot() async throws {
        let fixture = try ScrollingWorkflowFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        XCTAssertTrue(model.importImageData(fixture.png))
        model.annotations = [.text(normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.3), text: "Retained")]
        let documentID = model.document?.id
        let annotations = model.annotations
        model.workflowSettings.options.afterCapture = .copyOnly
        model.captureScrolling(.vertical) { _ in fixture.image }
        await waitForCapture(model)
        XCTAssertEqual(model.document?.id, documentID)
        XCTAssertEqual(model.annotations, annotations)
        XCTAssertTrue(model.canUndoAnnotation)
        XCTAssertEqual(model.latestCapture?.image?.captureLabPixelSize, fixture.image.captureLabPixelSize)
        XCTAssertEqual(model.historyItems.count, 1)
        XCTAssertTrue(fixture.failures.isEmpty)
    }

    private func waitForCapture(_ model: CaptureLabViewModel) async {
        for _ in 0..<100 where model.isCapturing { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isCapturing)
    }
}

@MainActor
private final class ScrollingWorkflowFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureScrollingWorkflowTests-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: .init("CaptureScrollingWorkflowTests.\(UUID().uuidString)"))
    let visibility = ScrollingWorkflowVisibility()
    let image: NSImage
    let png: Data
    var failures: [String] = []
    lazy var model = CaptureLabViewModel(
        r2SettingsStore: CloudflareR2SettingsStore(environment: ["HOME": root.path], secretStore: ScrollingWorkflowSecrets()),
        historyStore: CaptureHistoryStore(environment: ["HOME": root.path]),
        failurePresentationOperation: { [weak self] _, message in self?.failures.append(message) },
        pasteboard: pasteboard, windowVisibilityCoordinator: visibility,
        workflowSettings: CaptureWorkflowSettings(defaults: nil))

    init() throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 480, bitsPerComponent: 8,
            bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 480))
        image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 120, height: 480))
        png = try XCTUnwrap(image.captureLabPNGData())
    }

    func cleanUp() {
        pasteboard.clearContents()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class ScrollingWorkflowVisibility: CaptureWindowVisibilityCoordinating, CaptureWindowRestoring {
    var restores = 0
    func hideVisibleWindowsForCapture() -> any CaptureWindowRestoring { self }
    func waitUntilWindowsAreHidden() async {}
    func restore() { restores += 1 }
}

private struct ScrollingWorkflowSecrets: CloudflareR2SecretStoring {
    func secret(for accessKeyID: String) throws -> String? { nil }
    func setSecret(_ secret: String, for accessKeyID: String) throws {}
    func deleteSecret(for accessKeyID: String) throws {}
}
