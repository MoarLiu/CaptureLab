import AppKit
import SwiftUI
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureAnnotationCanvasTests: XCTestCase {
    func testArrowNudgeMovesOneVisiblePointAcrossZoomCropRotationAndFlip() throws {
        for zoom in [CaptureZoomLevel.fit, .half, .actual, .double] {
            for adjustment in [nil, CaptureDocument.Adjustment.rotateClockwise, .flipHorizontal, .flipVertical] {
                let harness = CanvasHarness(tool: .select)
                defer { harness.close() }
                let original = try XCTUnwrap(harness.view.document)
                var document = try XCTUnwrap(original.cropping(to: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)))
                if let adjustment { document = document.adjusting(adjustment) }
                harness.view.setDocument(document)
                harness.view.zoomLevel = zoom
                let annotation = CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1))
                harness.view.annotations = [annotation]
                harness.view.synchronizeSelection(annotation.id)
                let canvasPoint = CGPoint(x: 0.45 * document.sourcePixelSize.width, y: 0.45 * document.sourcePixelSize.height)
                    .applying(document.geometry.transform)
                let output = harness.view.outputDisplayRect
                let point = CGPoint(x: output.minX + canvasPoint.x * output.width / document.canvasSize.width,
                                    y: output.minY + canvasPoint.y * output.height / document.canvasSize.height)
                harness.keyDown(characters: "\u{F703}", keyCode: 124)
                harness.keyDown(characters: "\u{F701}", keyCode: 125, modifiers: .shift)
                let moved = try XCTUnwrap(harness.view.annotations.first)
                let movedCanvas = CGPoint(x: moved.normalizedRect.midX * document.sourcePixelSize.width,
                                          y: moved.normalizedRect.midY * document.sourcePixelSize.height)
                    .applying(document.geometry.transform)
                let movedPoint = CGPoint(x: output.minX + movedCanvas.x * output.width / document.canvasSize.width,
                                         y: output.minY + movedCanvas.y * output.height / document.canvasSize.height)
                XCTAssertEqual(movedPoint.x - point.x, 1, accuracy: 0.001)
                XCTAssertEqual(movedPoint.y - point.y, 10, accuracy: 0.001)
            }
        }
    }

    func testMovingVectorAboveRedactionReusesCompositionButChangesBelowItInvalidateCache() throws {
        let harness = CanvasHarness(tool: .select)
        defer { harness.close() }
        let below = CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let mask = CaptureAnnotation(kind: .mosaic, normalizedRect: CGRect(x: 0.05, y: 0.05, width: 0.4, height: 0.4))
        let above = CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2))
        harness.view.annotations = [below, mask, above]
        let bitmap = try XCTUnwrap(harness.view.bitmapImageRepForCachingDisplay(in: harness.view.bounds))
        harness.view.cacheDisplay(in: harness.view.bounds, to: bitmap)
        let count = harness.view.compositionRenderCount
        XCTAssertEqual(count, 1)
        harness.view.annotations = [below, mask, above.translatedBy(dx: 0.01, dy: 0)]
        harness.view.cacheDisplay(in: harness.view.bounds, to: bitmap)
        XCTAssertEqual(harness.view.compositionRenderCount, count)
        harness.view.annotations = [below.translatedBy(dx: 0.01, dy: 0), mask, above]
        harness.view.cacheDisplay(in: harness.view.bounds, to: bitmap)
        XCTAssertEqual(harness.view.compositionRenderCount, count + 1)
    }

    func testCropDragSelectsPixelsWithoutCreatingAnAnnotationAndEscapeCancels() throws {
        let harness = CanvasHarness(tool: .crop)
        defer { harness.close() }
        var selection: CGRect?
        var didCancel = false
        harness.view.onCropSelectionChanged = { selection = $0 }
        harness.view.onCancelCrop = { didCancel = true }
        harness.drag(from: CGPoint(x: 160, y: 120), to: CGPoint(x: 360, y: 260))
        let rect = try XCTUnwrap(selection)
        XCTAssertEqual(rect.minX, 0.125, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0.125, accuracy: 0.001)
        XCTAssertEqual(rect.width, 0.3125, accuracy: 0.001)
        XCTAssertTrue(harness.view.annotations.isEmpty)
        harness.keyDown(characters: "\u{1B}", keyCode: 53)
        XCTAssertNil(selection)
        XCTAssertTrue(didCancel)
    }

    func testRotatedCanvasHitAndMoveUseVisibleCoordinates() throws {
        let harness = CanvasHarness(tool: .select)
        defer { harness.close() }
        let original = try XCTUnwrap(harness.view.document)
        harness.view.setDocument(original.adjusting(.rotateClockwise))
        let annotation = CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.2, y: 0.25, width: 0.2, height: 0.3))
        harness.view.annotations = [annotation]
        let rect = harness.view.outputDisplayRect
        let center = CGPoint(x: rect.minX + rect.width * 0.6, y: rect.minY + rect.height * 0.3)
        harness.drag(from: center, to: CGPoint(x: center.x + rect.width * 0.1, y: center.y))
        let moved = try XCTUnwrap(harness.view.annotations.first)
        XCTAssertEqual(moved.id, annotation.id)
        XCTAssertEqual(moved.normalizedRect.minX, 0.2, accuracy: 0.001)
        XCTAssertEqual(moved.normalizedRect.minY, 0.15, accuracy: 0.001)
    }

    func testCroppedFlippedCanvasCreatesArrowAtVisibleLocation() throws {
        let harness = CanvasHarness(tool: .arrow)
        defer { harness.close() }
        let original = try XCTUnwrap(harness.view.document)
        let cropped = try XCTUnwrap(original.cropping(to: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
        harness.view.setDocument(cropped.adjusting(.flipHorizontal))
        let rect = harness.view.outputDisplayRect
        harness.drag(from: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.2),
                     to: CGPoint(x: rect.minX + rect.width * 0.8, y: rect.minY + rect.height * 0.8))
        let arrow = try XCTUnwrap(harness.view.annotations.first)
        XCTAssertEqual(arrow.normalizedPoints[0].x, 0.65, accuracy: 0.001)
        XCTAssertEqual(arrow.normalizedPoints[0].y, 0.35, accuracy: 0.001)
        XCTAssertEqual(arrow.normalizedPoints[1].x, 0.35, accuracy: 0.001)
        XCTAssertEqual(arrow.normalizedPoints[1].y, 0.65, accuracy: 0.001)
    }

    func testCropSelectionMovesSnapsAndResizesWithPresetAfterRotation() throws {
        let harness = CanvasHarness(tool: .crop)
        defer { harness.close() }
        let original = try XCTUnwrap(harness.view.document)
        harness.view.setDocument(original.adjusting(.rotateClockwise))
        harness.view.cropSelection = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let rect = harness.view.outputDisplayRect
        harness.drag(from: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.4),
                     to: CGPoint(x: rect.minX + rect.width * 0.205, y: rect.minY + rect.height * 0.4))
        let moved = try XCTUnwrap(harness.view.cropSelection)
        XCTAssertEqual(moved.minX, 0, accuracy: 0.001)
        XCTAssertEqual(moved.width, 0.4, accuracy: 0.001)
        harness.view.cropPreset = .square
        harness.drag(from: CGPoint(x: rect.minX + rect.width * moved.maxX, y: rect.minY + rect.height * moved.maxY),
                     to: CGPoint(x: rect.minX + rect.width * 0.65, y: rect.minY + rect.height * 0.8))
        let resized = try XCTUnwrap(harness.view.cropSelection)
        let size = try XCTUnwrap(harness.view.document?.canvasSize)
        XCTAssertEqual(resized.width * size.width, resized.height * size.height, accuracy: 0.01)
        XCTAssertTrue(harness.view.annotations.isEmpty)
    }

    func testNewStyledAnnotationKeepsAppearanceAfterMoving() throws {
        let harness = CanvasHarness(tool: .rectangle)
        defer { harness.close() }
        let appearance = CaptureAnnotationAppearance(color: CaptureAnnotationColor(.systemBlue), lineWidth: 9, fontSize: 32)
        harness.view.annotationAppearance = appearance
        harness.drag(from: CGPoint(x: 160, y: 120), to: CGPoint(x: 360, y: 260))
        XCTAssertEqual(harness.view.annotations.first?.appearance, appearance)
        harness.drag(from: CGPoint(x: 250, y: 200), to: CGPoint(x: 280, y: 230))
        XCTAssertEqual(harness.view.annotations.first?.appearance, appearance)
    }

    func testExternalSelectionResetLetsTheSameAnnotationBeSelectedAgain() throws {
        let harness = CanvasHarness(tool: .rectangle)
        defer { harness.close() }
        var selections: [UUID?] = []
        harness.view.onSelectionChanged = { selections.append($0) }
        harness.drag(from: CGPoint(x: 160, y: 120), to: CGPoint(x: 360, y: 260))
        let id = try XCTUnwrap(harness.view.annotations.first?.id)
        XCTAssertEqual(selections, [id])
        harness.view.selectedTool = .select
        harness.view.synchronizeSelection(nil)
        XCTAssertEqual(selections, [id], "Downstream selection synchronization must not publish a second edit.")
        harness.click(at: CGPoint(x: 250, y: 200))
        XCTAssertEqual(selections, [id, id])
    }

    func testNestedModelSelectionSynchronizationPreservesScopeAndNativeEventsStillPublish() {
        let harness = CanvasHarness(tool: .select)
        defer { harness.close() }
        let annotation = CaptureAnnotation(kind: .rectangle,
            normalizedRect: CGRect(x: 0.125, y: 0.125, width: 0.3125, height: 0.2917))
        harness.view.annotations = [annotation]
        var selections: [UUID?] = []
        harness.view.onSelectionChanged = { selections.append($0) }

        harness.view.withModelSelectionSynchronization {
            harness.view.synchronizeSelection(annotation.id)
            // synchronizeSelection opens its own scope. Pruning afterwards
            // must remain suppressed by the enclosing model update scope.
            harness.view.annotations = []
        }
        XCTAssertTrue(selections.isEmpty)

        harness.view.annotations = [annotation]
        harness.click(at: CGPoint(x: 250, y: 200))
        XCTAssertEqual(selections, [annotation.id])
        harness.keyDown(characters: "\u{7F}", keyCode: 51)
        XCTAssertEqual(selections, [annotation.id, nil])
    }

    func testArrowCanBeCreatedAndEndpointDragged() {
        let harness = CanvasHarness(tool: .arrow)
        defer { harness.close() }

        harness.drag(from: CGPoint(x: 160, y: 120), to: CGPoint(x: 360, y: 260))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].kind, .arrow)
        XCTAssertEqual(harness.view.annotations[0].normalizedPoints[0].x, 0.125, accuracy: 0.01)
        XCTAssertEqual(harness.view.annotations[0].normalizedPoints[1].x, 0.438, accuracy: 0.01)

        harness.drag(from: CGPoint(x: 360, y: 260), to: CGPoint(x: 440, y: 320))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].normalizedPoints[1].x, 0.563, accuracy: 0.01)
        XCTAssertEqual(harness.view.annotations[0].normalizedPoints[1].y, 0.542, accuracy: 0.01)
    }

    func testLineCanBeCreatedAndEndpointDragged() {
        let harness = CanvasHarness(tool: .line)
        defer { harness.close() }

        harness.drag(from: CGPoint(x: 160, y: 120), to: CGPoint(x: 360, y: 260))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].kind, .line)
        XCTAssertEqual(harness.view.annotations[0].normalizedPoints[0].x, 0.125, accuracy: 0.01)
        XCTAssertEqual(harness.view.annotations[0].normalizedPoints[1].x, 0.438, accuracy: 0.01)

        harness.drag(from: CGPoint(x: 360, y: 260), to: CGPoint(x: 440, y: 320))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].normalizedPoints[1].x, 0.563, accuracy: 0.01)
        XCTAssertEqual(harness.view.annotations[0].normalizedPoints[1].y, 0.542, accuracy: 0.01)
    }

    func testCounterCanBeCreatedFromClicksAndAutoIncrements() {
        let harness = CanvasHarness(tool: .counter)
        defer { harness.close() }

        harness.click(at: CGPoint(x: 280, y: 200))
        harness.click(at: CGPoint(x: 320, y: 220))

        XCTAssertEqual(harness.view.annotations.count, 2)
        XCTAssertEqual(harness.view.annotations[0].kind, .counter)
        XCTAssertEqual(harness.view.annotations[0].text, "1")
        XCTAssertEqual(harness.view.annotations[1].kind, .counter)
        XCTAssertEqual(harness.view.annotations[1].text, "2")
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.width, 0.05, accuracy: 0.01)
    }

    func testMosaicCanBeCreatedAndResizedWithHandleDrag() {
        let harness = CanvasHarness(tool: .mosaic)
        defer { harness.close() }

        harness.drag(from: CGPoint(x: 160, y: 120), to: CGPoint(x: 360, y: 260))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].kind, .mosaic)
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.width, 0.313, accuracy: 0.01)

        harness.drag(from: CGPoint(x: 360, y: 260), to: CGPoint(x: 440, y: 320))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.width, 0.438, accuracy: 0.01)
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.height, 0.417, accuracy: 0.01)
    }

    func testTextHighlightCanBeCreatedAndResizedWithHandleDrag() {
        let harness = CanvasHarness(tool: .highlight)
        defer { harness.close() }

        harness.drag(from: CGPoint(x: 160, y: 120), to: CGPoint(x: 360, y: 260))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].kind, .highlight)
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.width, 0.313, accuracy: 0.01)

        harness.drag(from: CGPoint(x: 360, y: 260), to: CGPoint(x: 440, y: 320))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.width, 0.438, accuracy: 0.01)
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.height, 0.417, accuracy: 0.01)
    }

    func testTextCanBeCreatedAndMoved() {
        let harness = CanvasHarness(tool: .text)
        defer { harness.close() }

        harness.drag(from: CGPoint(x: 200, y: 160), to: CGPoint(x: 360, y: 240))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].kind, .text)
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.minX, 0.188, accuracy: 0.01)
        XCTAssertTrue(harness.view.subviews.contains { $0 is NSTextField })

        harness.view.selectedTool = .select

        harness.drag(from: CGPoint(x: 280, y: 200), to: CGPoint(x: 340, y: 230))

        XCTAssertEqual(harness.view.annotations[0].normalizedRect.minX, 0.281, accuracy: 0.01)
        XCTAssertEqual(harness.view.annotations[0].normalizedRect.minY, 0.271, accuracy: 0.01)
    }

    func testTextCanBeCreatedFromSingleClick() {
        let harness = CanvasHarness(tool: .text)
        defer { harness.close() }

        harness.click(at: CGPoint(x: 280, y: 200))

        XCTAssertEqual(harness.view.annotations.count, 1)
        XCTAssertEqual(harness.view.annotations[0].kind, .text)
        XCTAssertEqual(harness.view.annotations[0].text, L10n.defaultAnnotationText)
        XCTAssertTrue(harness.view.subviews.contains { $0 is NSTextField })
    }

    func testSelectedAnnotationCanBeDeletedWithKeyboard() {
        let harness = CanvasHarness(tool: .rectangle)
        defer { harness.close() }

        harness.drag(from: CGPoint(x: 160, y: 120), to: CGPoint(x: 360, y: 260))
        XCTAssertEqual(harness.view.annotations.count, 1)

        harness.keyDown(characters: "\u{7F}", keyCode: 51)

        XCTAssertTrue(harness.view.annotations.isEmpty)
    }

    func testEditingSessionSynchronouslyCommitsPendingTextBeforeFocusEnds() throws {
        let harness = CanvasHarness(tool: .text)
        defer { harness.close() }

        harness.click(at: CGPoint(x: 280, y: 200))
        let field = try XCTUnwrap(harness.view.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "Pending export text"
        XCTAssertNotEqual(harness.view.annotations[0].text, "Pending export text")

        CaptureEditingSession.commitPendingTextEdits()

        XCTAssertEqual(harness.view.annotations[0].text, "Pending export text")
        XCTAssertFalse(harness.view.subviews.contains { $0 is NSTextField })
    }

    func testDismantleCommitsPendingTextBeforeEditorReplacement() throws {
        let harness = CanvasHarness(tool: .text)
        defer { harness.close() }

        harness.click(at: CGPoint(x: 280, y: 200))
        let field = try XCTUnwrap(harness.view.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "Text preserved across zoom"
        XCTAssertNotEqual(harness.boundAnnotations[0].text, "Text preserved across zoom")

        harness.dismantle()

        XCTAssertEqual(harness.boundAnnotations[0].text, "Text preserved across zoom")
        XCTAssertFalse(harness.view.subviews.contains { $0 is NSTextField })

        // Reopening an editor builds a replacement canvas from committed bindings.
        let replacement = CaptureAnnotationNSCanvasView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        replacement.annotations = harness.boundAnnotations
        XCTAssertEqual(replacement.annotations[0].text, "Text preserved across zoom")
    }

    func testStaticMosaicReusesCachedImageAndReplacesResizedEntry() throws {
        let harness = CanvasHarness(tool: .mosaic)
        defer { harness.close() }
        harness.drag(from: CGPoint(x: 160, y: 120), to: CGPoint(x: 360, y: 260))

        let annotation = try XCTUnwrap(harness.view.annotations.first)
        let first = try XCTUnwrap(harness.view.cachedPixelatedImage(for: annotation))
        let second = try XCTUnwrap(harness.view.cachedPixelatedImage(for: annotation))

        XCTAssertTrue(first === second)
        XCTAssertEqual(harness.view.mosaicCacheEntryCount, 1)

        let resized = annotation.withNormalizedRect(
            CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.5)
        )
        harness.view.annotations = [resized]
        let replacement = try XCTUnwrap(harness.view.cachedPixelatedImage(for: resized))

        XCTAssertFalse(first === replacement)
        XCTAssertEqual(harness.view.mosaicCacheEntryCount, 1)
    }

    func testMosaicCacheGrowthIsBounded() throws {
        let harness = CanvasHarness(tool: .mosaic)
        defer { harness.close() }
        let annotations = (0..<40).map { index in
            CaptureAnnotation(
                kind: .mosaic,
                normalizedRect: CGRect(
                    x: CGFloat(index % 8) * 0.1,
                    y: CGFloat(index / 8) * 0.1,
                    width: 0.08,
                    height: 0.08
                )
            )
        }
        harness.view.annotations = annotations

        for annotation in annotations {
            _ = try XCTUnwrap(harness.view.cachedPixelatedImage(for: annotation))
        }

        XCTAssertLessThanOrEqual(harness.view.mosaicCacheEntryCount, 32)
        XCTAssertLessThanOrEqual(harness.view.mosaicCacheCostInPixels, 16_000_000)
    }

    func testSixKFullFrameMosaicPreviewRemainsCached() throws {
        let source = try CanvasHarness.sixKFixtureImage()
        let harness = CanvasHarness(tool: .mosaic, image: source)
        defer { harness.close() }
        let annotation = CaptureAnnotation(
            kind: .mosaic,
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        harness.view.annotations = [annotation]

        XCTAssertGreaterThan(6_144 * 3_456, 16_000_000)
        let first = try XCTUnwrap(harness.view.cachedPixelatedImage(for: annotation))
        let second = try XCTUnwrap(harness.view.cachedPixelatedImage(for: annotation))

        XCTAssertTrue(first === second)
        XCTAssertEqual(harness.view.mosaicCacheEntryCount, 1)
        XCTAssertLessThanOrEqual(harness.view.mosaicCacheCostInPixels, 4_000_000)
    }

    func testMultipleLargeMosaicRegionsSurviveRepeatedDrawOrder() throws {
        let source = try CanvasHarness.sixKFixtureImage()
        let harness = CanvasHarness(tool: .mosaic, image: source)
        defer { harness.close() }
        let annotations = (0..<3).map { index in
            CaptureAnnotation(
                kind: .mosaic,
                normalizedRect: CGRect(
                    x: CGFloat(index) / 3,
                    y: 0,
                    width: 1 / 3,
                    height: 1
                )
            )
        }
        harness.view.annotations = annotations

        // At source resolution these three regions exceed the old 16M-pixel
        // budget in aggregate and a sequential LRU scan evicted every entry.
        XCTAssertGreaterThan(6_144 * 3_456, 16_000_000)
        let firstPass = try annotations.map {
            try XCTUnwrap(harness.view.cachedPixelatedImage(for: $0))
        }
        let secondPass = try annotations.map {
            try XCTUnwrap(harness.view.cachedPixelatedImage(for: $0))
        }

        XCTAssertEqual(harness.view.mosaicCacheEntryCount, annotations.count)
        XCTAssertLessThanOrEqual(harness.view.mosaicCacheCostInPixels, 16_000_000)
        for index in annotations.indices {
            XCTAssertTrue(firstPass[index] === secondPass[index])
        }
    }
}

@MainActor
private final class CanvasHarness {
    let view: CaptureAnnotationNSCanvasView
    private let annotationBox = CanvasAnnotationBox()

    init(tool: CaptureTool, image: NSImage? = nil) {
        view = CaptureAnnotationNSCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.setDocument(CaptureDocument(
            image: image ?? Self.fixtureImage(),
            sourceURL: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        ))
        view.setEditingSession(.shared)
        view.selectedTool = tool
        view.onAnnotationsChanged = { [weak view, annotationBox] annotations in
            annotationBox.annotations = annotations
            view?.annotations = annotations
        }
    }

    var boundAnnotations: [CaptureAnnotation] {
        annotationBox.annotations
    }

    func close() {
        view.prepareForDismantle()
    }

    func dismantle() {
        let binding = Binding<[CaptureAnnotation]>(
            get: { self.annotationBox.annotations },
            set: { self.annotationBox.annotations = $0 }
        )
        CaptureAnnotationCanvasView.dismantleNSView(
            view,
            coordinator: CaptureAnnotationCanvasView.Coordinator(annotations: binding)
        )
    }

    func drag(from start: CGPoint, to end: CGPoint) {
        view.mouseDown(with: event(type: .leftMouseDown, location: start))
        view.mouseDragged(with: event(type: .leftMouseDragged, location: end))
        view.mouseUp(with: event(type: .leftMouseUp, location: end))
    }

    func click(at point: CGPoint) {
        view.mouseDown(with: event(type: .leftMouseDown, location: point))
        view.mouseUp(with: event(type: .leftMouseUp, location: point))
    }

    func keyDown(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        view.keyDown(with: NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!)
    }

    private func event(type: NSEvent.EventType, location: CGPoint) -> NSEvent {
        return NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
    }

    private static func fixtureImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 400, height: 300))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 300).fill()
        NSColor.black.setFill()
        NSRect(x: 80, y: 70, width: 240, height: 160).fill()
        image.unlockFocus()
        return image
    }

    static func sixKFixtureImage() throws -> NSImage {
        let width = 6_144
        let height = 3_456
        let bytesPerRow = (width + 7) / 8
        let provider = try XCTUnwrap(CGDataProvider(
            data: Data(repeating: 0b1010_1010, count: bytesPerRow * height) as CFData
        ))
        let source = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 1,
            bitsPerPixel: 1,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        return NSImage(cgImage: source, size: CGSize(width: width, height: height))
    }
}

@MainActor
private final class CanvasAnnotationBox {
    var annotations: [CaptureAnnotation] = []
}
