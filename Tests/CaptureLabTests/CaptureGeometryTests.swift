import CoreGraphics
import XCTest
@testable import CaptureLab

final class CaptureGeometryTests: XCTestCase {
    func testAspectFitRectCentersImage() {
        let rect = CaptureGeometry.aspectFitRect(
            imageSize: CGSize(width: 1600, height: 900),
            in: CGSize(width: 800, height: 800)
        )

        XCTAssertEqual(rect.width, 800, accuracy: 0.01)
        XCTAssertEqual(rect.height, 450, accuracy: 0.01)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 175, accuracy: 0.01)
    }

    func testNormalizedRectClampsToImageDisplayRect() {
        let imageRect = CGRect(x: 100, y: 50, width: 400, height: 200)
        let displayRect = CGRect(x: 50, y: 75, width: 250, height: 100)

        let normalized = CaptureGeometry.normalizedRect(from: displayRect, in: imageRect)

        XCTAssertEqual(normalized.minX, 0, accuracy: 0.01)
        XCTAssertEqual(normalized.minY, 0.125, accuracy: 0.01)
        XCTAssertEqual(normalized.width, 0.5, accuracy: 0.01)
        XCTAssertEqual(normalized.height, 0.5, accuracy: 0.01)
    }

    func testFixedZoomCanvasContentCanExceedViewport() {
        let contentSize = CaptureCanvasLayout.contentSize(
            imageSize: CGSize(width: 1_600, height: 1_200),
            viewportSize: CGSize(width: 800, height: 600),
            zoomLevel: .actual
        )

        XCTAssertEqual(contentSize.width, 1_760, accuracy: 0.01)
        XCTAssertEqual(contentSize.height, 1_320, accuracy: 0.01)
    }

    func testAnnotationTranslationKeepsRectInsideImageBounds() {
        let annotation = CaptureAnnotation(
            kind: .rectangle,
            normalizedRect: CGRect(x: 0.8, y: 0.7, width: 0.15, height: 0.2)
        )

        let moved = annotation.translatedBy(dx: 0.5, dy: 0.5)

        XCTAssertEqual(moved.normalizedRect.minX, 0.85, accuracy: 0.01)
        XCTAssertEqual(moved.normalizedRect.maxX, 1, accuracy: 0.01)
        XCTAssertEqual(moved.normalizedRect.minY, 0.8, accuracy: 0.01)
        XCTAssertEqual(moved.normalizedRect.maxY, 1, accuracy: 0.01)
    }

    func testArrowPointReplacementUpdatesBounds() {
        let annotation = CaptureAnnotation.arrow(
            start: CGPoint(x: 0.2, y: 0.2),
            end: CGPoint(x: 0.4, y: 0.4)
        )

        let updated = annotation.replacingPoint(at: 1, with: CGPoint(x: 0.8, y: 0.6))

        XCTAssertEqual(updated.normalizedPoints[1].x, 0.8, accuracy: 0.01)
        XCTAssertEqual(updated.normalizedPoints[1].y, 0.6, accuracy: 0.01)
        XCTAssertEqual(updated.normalizedRect.maxX, 0.8, accuracy: 0.01)
        XCTAssertEqual(updated.normalizedRect.maxY, 0.6, accuracy: 0.01)
    }

    func testBrushScalesPointsIntoTargetRect() {
        let annotation = CaptureAnnotation.brush(points: [
            CGPoint(x: 0.2, y: 0.2),
            CGPoint(x: 0.4, y: 0.4)
        ])

        let scaled = annotation.scaledToNormalizedRect(
            CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.2)
        )

        XCTAssertEqual(scaled.normalizedPoints[0].x, 0.1, accuracy: 0.01)
        XCTAssertEqual(scaled.normalizedPoints[0].y, 0.1, accuracy: 0.01)
        XCTAssertEqual(scaled.normalizedPoints[1].x, 0.5, accuracy: 0.01)
        XCTAssertEqual(scaled.normalizedPoints[1].y, 0.3, accuracy: 0.01)
    }
}
