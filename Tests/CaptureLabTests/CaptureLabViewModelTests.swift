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
}
