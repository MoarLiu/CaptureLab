import AppKit
import CoreGraphics
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureLabViewModelTests: XCTestCase {
    func testUndoRestoresPreviousAnnotationSnapshot() {
        let model = CaptureLabViewModel()
        let first = CaptureAnnotation(
            kind: .rectangle,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        )
        let second = CaptureAnnotation.arrow(
            start: CGPoint(x: 0.2, y: 0.2),
            end: CGPoint(x: 0.6, y: 0.6)
        )

        model.addAnnotation(first)
        model.addAnnotation(second)

        XCTAssertEqual(model.annotations.count, 2)
        XCTAssertTrue(model.canUndoAnnotation)

        model.undoAnnotation()

        XCTAssertEqual(model.annotations, [first])
        XCTAssertTrue(model.canUndoAnnotation)

        model.undoAnnotation()

        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertFalse(model.canUndoAnnotation)
    }

    func testClearAnnotationsCanBeUndone() {
        let model = CaptureLabViewModel()
        let annotation = CaptureAnnotation(
            kind: .mosaic,
            normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        )

        model.addAnnotation(annotation)
        model.clearAnnotations()

        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertTrue(model.canUndoAnnotation)

        model.undoAnnotation()

        XCTAssertEqual(model.annotations, [annotation])
        XCTAssertTrue(model.canUndoAnnotation)

        model.undoAnnotation()

        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertFalse(model.canUndoAnnotation)
    }

    func testResettingDocumentClearsUndoHistory() {
        let model = CaptureLabViewModel()
        let annotation = CaptureAnnotation(
            kind: .rectangle,
            normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        )

        model.addAnnotation(annotation)
        model.clearDocument()

        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertFalse(model.canUndoAnnotation)
    }

    func testFinishEditingCopiesAndClearsCurrentDocument() throws {
        let fixture = try HistoryFixture()
        let historyStore = CaptureHistoryStore(environment: fixture.environment)
        let imageData = try XCTUnwrap(Self.fixtureImage().captureLabPNGData())
        let item = try historyStore.record(
            data: imageData,
            pixelSize: CGSize(width: 64, height: 48),
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let model = CaptureLabViewModel(
            r2SettingsStore: CloudflareR2SettingsStore(environment: fixture.environment),
            historyStore: historyStore
        )
        let annotation = CaptureAnnotation(
            kind: .rectangle,
            normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        )

        model.openHistoryItem(item)
        model.addAnnotation(annotation)
        model.ocrText = "recognized text"

        XCTAssertTrue(model.finishEditing())

        XCTAssertFalse(model.hasImage)
        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertFalse(model.canUndoAnnotation)
        XCTAssertTrue(model.ocrText.isEmpty)
    }

    private static func fixtureImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 64, height: 48))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 48).fill()
        image.unlockFocus()
        return image
    }
}

private struct HistoryFixture {
    let home: URL
    let environment: [String: String]

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureLabViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = ["HOME": home.path]
    }
}
