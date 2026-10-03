import AppKit
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureImageLayerTests: XCTestCase {
    func testLayerResourcesAndPlacementsRoundTripWithoutFlattening() throws {
        let image = try solid(.red, width: 20, height: 10)
        let data = try XCTUnwrap(image.captureLabPNGData())
        var layer = try CaptureLayerImport.layer(data: data, name: "red.png", canvasSize: CGSize(width: 100, height: 80), existing: [])
        layer.rotationDegrees = 37
        layer.zIndex = 4
        let result = try JSONDecoder().decode(CaptureImageLayer.self, from: JSONEncoder().encode(layer))
        XCTAssertEqual(result, layer)
        XCTAssertEqual(result.pngData, data)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.pixelSize, CGSize(width: 20, height: 10))
    }

    func testCompositionUsesStableLayerOrderThenRedaction() throws {
        let source = try solid(.white, width: 100, height: 80)
        let red = try layer(.red, rect: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6), z: 1)
        var blue = try layer(.blue, rect: CGRect(x: 0.4, y: 0.3, width: 0.5, height: 0.5), z: 1)
        let composed = try XCTUnwrap(CaptureLayerComposition.render(source: source, layers: [red, blue]))
        assertColor(try pixel(composed, 15, 15), .red)
        assertColor(try pixel(composed, 50, 40), .blue)
        blue.zIndex = 0
        let reordered = try XCTUnwrap(CaptureLayerComposition.render(source: source, layers: [red, blue]))
        assertColor(try pixel(reordered, 50, 40), .red)
        let mosaic = CaptureAnnotation(kind: .mosaic, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.7))
        let rendered = try XCTUnwrap(composed.renderedWithCaptureLabAnnotations([mosaic]))
        XCTAssertNotEqual(rendered.captureLabPNGData(), composed.captureLabPNGData())
        // No malformed resource can become a successful base-only export.
        var broken = blue
        broken.normalizedRect = CGRect(x: 0, y: 0, width: -1, height: 1)
        XCTAssertNil(CaptureLayerComposition.render(source: source, layers: [broken]))
    }

    func testRotationUsesPixelCenterAndTopLeftHitTestingOnNonsquareCanvas() throws {
        var image = try layer(.red, rect: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.2))
        image.rotationDegrees = 90
        let size = CGSize(width: 200, height: 100)
        let corners = image.corners(in: size)
        XCTAssertEqual(corners[0].x, 110, accuracy: 0.00001)
        XCTAssertEqual(corners[0].y, 0, accuracy: 0.00001)
        XCTAssertTrue(image.contains(CGPoint(x: 0.5, y: 0.7), sourceSize: size))
        XCTAssertFalse(image.contains(CGPoint(x: 0.3, y: 0.4), sourceSize: size))
        let source = try solid(.white, width: 200, height: 100)
        let output = try XCTUnwrap(CaptureLayerComposition.render(source: source, layers: [image]))
        assertColor(try pixel(output, 100, 70), .red)
        assertColor(try pixel(output, 60, 40), .white)
    }

    func testGroupMoveUsesOneClampedDeltaAndPreservesSpacingAcrossKinds() throws {
        let image = try layer(.red, rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.3))
        let annotation = CaptureAnnotation.arrow(start: CGPoint(x: 0.6, y: 0.4), end: CGPoint(x: 0.8, y: 0.6))
        let selection: Set<CaptureObjectID> = [.image(image.id), .annotation(annotation.id)]
        let result = CaptureObjectOperations.translated(layers: [image], annotations: [annotation], selection: selection, dx: 0.5, dy: -0.5)
        XCTAssertEqual(result.layers[0].normalizedRect.minX, 0.3, accuracy: 0.00001)
        XCTAssertEqual(result.annotations[0].normalizedBounds.minX, 0.8, accuracy: 0.00001)
        XCTAssertEqual(result.layers[0].normalizedRect.minY, 0, accuracy: 0.00001)
        XCTAssertEqual(result.annotations[0].normalizedBounds.minY, 0.2, accuracy: 0.00001)
        XCTAssertEqual(result.layers[0].pngData, image.pngData)
    }

    func testDuplicateDeleteAndReorderKeepIndependentIDsAndImageData() throws {
        let a = try layer(.red, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), z: 99)
        let b = try layer(.blue, rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), z: 100)
        let annotation = CaptureAnnotation.text(normalizedRect: CGRect(x: 0.2, y: 0.5, width: 0.3, height: 0.1), text: "Fixture")
        let result = try CaptureObjectOperations.duplicated(layers: [a, b], annotations: [annotation], selection: [.image(a.id), .annotation(annotation.id)])
        XCTAssertEqual(result.layers.count, 3)
        XCTAssertEqual(result.annotations.count, 2)
        XCTAssertNotEqual(result.layers.last?.id, a.id)
        XCTAssertEqual(result.layers.last?.pngData, a.pngData)
        XCTAssertEqual(result.annotations.last?.text, "Fixture")
        XCTAssertEqual(result.selection.count, 2)
        let back = CaptureObjectOperations.deleted(layers: result.layers, annotations: result.annotations, selection: result.selection)
        XCTAssertEqual(back.layers.map(\.id), [a.id, b.id])
        XCTAssertEqual(back.annotations, [annotation])
        let reordered = CaptureObjectOperations.reorder([a, b], selection: [.image(a.id)], bringForward: true)
        XCTAssertEqual(reordered.map(\.id), [b.id, a.id])
        XCTAssertEqual(reordered.map(\.zIndex), [0, 1])
    }

    func testEqualGapAndHorizontalArrangeAreDeterministicAcrossMixedObjects() throws {
        let a = try layer(.red, rect: CGRect(x: 0.1, y: 0.3, width: 0.1, height: 0.1))
        let b = try layer(.blue, rect: CGRect(x: 0.8, y: 0.6, width: 0.1, height: 0.1))
        let annotation = CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.3, y: 0.1, width: 0.2, height: 0.2))
        let selection: Set<CaptureObjectID> = [.image(a.id), .image(b.id), .annotation(annotation.id)]
        let result = CaptureObjectOperations.arranged(.distributeHorizontal, layers: [a, b], annotations: [annotation], selection: selection)
        let gap1 = result.annotations[0].normalizedRect.minX - result.layers[0].normalizedRect.maxX
        let gap2 = result.layers[1].normalizedRect.minX - result.annotations[0].normalizedRect.maxX
        XCTAssertEqual(gap1, gap2, accuracy: 0.00001)
        let arranged = CaptureObjectOperations.arranged(.horizontal, layers: [a, b], annotations: [annotation], selection: selection)
        XCTAssertEqual(arranged.layers[0].normalizedRect.midY, arranged.annotations[0].normalizedRect.midY, accuracy: 0.00001)
        XCTAssertEqual(arranged.layers[1].normalizedRect.midY, arranged.annotations[0].normalizedRect.midY, accuracy: 0.00001)
    }

    func testDuplicatingImageGroupPreservesItsVisibleStackingOrder() throws {
        let front = try layer(.red, rect: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4), z: 10)
        let back = try layer(.blue, rect: front.normalizedRect, z: -3)
        let result = try CaptureObjectOperations.duplicated(layers: [front, back], annotations: [],
                                                           selection: [.image(front.id), .image(back.id)])
        let copies = CaptureLayerComposition.ordered(result.layers).filter { result.selection.contains(.image($0.id)) }
        XCTAssertEqual(copies.map(\.pngData), [back.pngData, front.pngData])
        let source = try solid(.white, width: 100, height: 100)
        let output = try XCTUnwrap(CaptureLayerComposition.render(source: source, layers: result.layers))
        assertColor(try pixel(output, 40, 40), .red)
    }

    func testResourceBudgetsAndInvalidPayloadsRejectWithoutMutatingExistingArray() throws {
        let original = try layer(.red, rect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2))
        var many: [CaptureImageLayer] = []
        for _ in 0..<33 { var copy = original; copy.id = UUID(); many.append(copy) }
        XCTAssertThrowsError(try CaptureLayerImport.validate(many))
        XCTAssertThrowsError(try CaptureLayerImport.validate([original, original]))
        let invalid = CaptureImageLayer(name: "bad", pngData: Data("garbage".utf8), normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertFalse(invalid.isValid)
        XCTAssertThrowsError(try CaptureLayerImport.layer(data: invalid.pngData, name: "bad", canvasSize: CGSize(width: 100, height: 100), existing: [original]))
        XCTAssertEqual(original.rotationDegrees, 0)
    }

    func testPasteboardImportsAllFileItemsAtomically() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = [dir.appendingPathComponent("a.png"), dir.appendingPathComponent("b.png")]
        try XCTUnwrap(solid(.red).captureLabPNGData()).write(to: urls[0])
        try XCTUnwrap(solid(.blue).captureLabPNGData()).write(to: urls[1])
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects(urls.map { $0 as NSURL }))
        let imported = try CaptureLayerImport.layers(from: pasteboard, canvasSize: CGSize(width: 100, height: 100), existing: [])
        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(imported.map(\.name), ["a.png", "b.png"])
        try Data("corrupt".utf8).write(to: urls[1])
        XCTAssertThrowsError(try CaptureLayerImport.layers(from: pasteboard, canvasSize: CGSize(width: 100, height: 100), existing: imported))
        XCTAssertEqual(imported.count, 2)
    }

    func testNativeCanvasMixedDragCommitsOneUndoUnitAndCoordinatesFollowRotation() throws {
        let source = try solid(.white, width: 100, height: 80)
        var document = CaptureDocument(image: source, sourceURL: nil, createdAt: Date())
        let image = try layer(.red, rect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.2))
        document.imageLayers = [image]
        document = document.adjusting(.rotateClockwise)
        let annotation = CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.5, y: 0.3, width: 0.2, height: 0.2))
        let canvas = CaptureLayersNSCanvasView(frame: CGRect(x: 0, y: 0, width: 600, height: 480))
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.synchronize(document: document, annotations: [annotation], selection: [.image(image.id), .annotation(annotation.id)], zoom: .fit)
        var commits = 0
        canvas.onCommit = { _, _ in commits += 1 }
        let start = canvas.viewPoint(for: CGPoint(x: 0.2, y: 0.3))
        let finish = canvas.viewPoint(for: CGPoint(x: 0.3, y: 0.4))
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: start, canvas: canvas, window: window))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: finish, canvas: canvas, window: window))
        XCTAssertEqual(commits, 0)
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: finish, canvas: canvas, window: window))
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(canvas.layers[0].normalizedRect.minX, 0.2, accuracy: 0.00001)
        XCTAssertEqual(canvas.annotations[0].normalizedRect.minX, 0.6, accuracy: 0.00001)
        XCTAssertEqual(canvas.layers[0].normalizedRect.minY, 0.3, accuracy: 0.00001)
        XCTAssertEqual(canvas.annotations[0].normalizedRect.minY, 0.4, accuracy: 0.00001)
        window.orderOut(nil)
    }

    func testNativeCanvasEscapeCancelsGestureWithoutPublishingAndKeyboardUsesVisibleDirections() throws {
        var document = CaptureDocument(image: try solid(.white, width: 100, height: 80), sourceURL: nil, createdAt: Date())
        let image = try layer(.red, rect: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
        document.imageLayers = [image]
        document = document.adjusting(.rotateClockwise)
        let canvas = CaptureLayersNSCanvasView(frame: CGRect(x: 0, y: 0, width: 600, height: 480))
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.synchronize(document: document, annotations: [], selection: [.image(image.id)], zoom: .fit)
        var commits = 0; canvas.onCommit = { _, _ in commits += 1 }
        let start = canvas.viewPoint(for: CGPoint(x: 0.3, y: 0.3))
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: start, canvas: canvas, window: window))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: canvas.viewPoint(for: CGPoint(x: 0.5, y: 0.5)), canvas: canvas, window: window))
        canvas.keyDown(with: try key(code: 53, window: window))
        XCTAssertEqual(canvas.layers, [image]); XCTAssertEqual(commits, 0)
        canvas.keyDown(with: try key(code: 124, window: window))
        let moved = canvas.viewPoint(for: CGPoint(x: canvas.layers[0].normalizedRect.midX, y: canvas.layers[0].normalizedRect.midY))
        XCTAssertEqual(canvas.layers[0].normalizedRect.minX, 0.2, accuracy: 0.00001)
        XCTAssertEqual(moved.x - start.x, 1, accuracy: 0.00001)
        XCTAssertEqual(moved.y - start.y, 0, accuracy: 0.00001)
        XCTAssertEqual(commits, 1)
        window.orderOut(nil)
    }

    func testNativeCanvasResizeAndRotationPreserveCenterAndCommitOnlyAtMouseUp() throws {
        var document = CaptureDocument(image: try solid(.white, width: 100, height: 100), sourceURL: nil, createdAt: Date())
        let image = try layer(.red, rect: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
        document.imageLayers = [image]
        let canvas = CaptureLayersNSCanvasView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.synchronize(document: document, annotations: [], selection: [.image(image.id)], zoom: .fit)
        var commits = 0; canvas.onCommit = { _, _ in commits += 1 }
        let corner = canvas.viewPoint(for: CGPoint(x: 0.4, y: 0.4))
        let enlarged = canvas.viewPoint(for: CGPoint(x: 0.45, y: 0.45))
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: corner, canvas: canvas, window: window))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: enlarged, canvas: canvas, window: window))
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(canvas.layers[0].normalizedRect.width, 0.3, accuracy: 0.00001)
        XCTAssertEqual(canvas.layers[0].normalizedRect.midX, 0.3, accuracy: 0.00001)
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: enlarged, canvas: canvas, window: window))
        XCTAssertEqual(commits, 1)
        let top = canvas.viewPoint(for: CGPoint(x: 0.3, y: 0.15))
        let handle = CGPoint(x: top.x, y: top.y - 22)
        let center = canvas.viewPoint(for: CGPoint(x: 0.3, y: 0.3))
        let rotated = CGPoint(x: center.x + center.y - handle.y, y: center.y)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: handle, canvas: canvas, window: window))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: rotated, canvas: canvas, window: window))
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(canvas.layers[0].rotationDegrees, 90, accuracy: 0.00001)
        XCTAssertEqual(canvas.layers[0].normalizedRect.midX, 0.3, accuracy: 0.00001)
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: rotated, canvas: canvas, window: window))
        XCTAssertEqual(commits, 2)
        window.orderOut(nil)
    }

    func testNativeCanvasCropRotateAndOutputScaleUseTheSamePointerCoordinates() throws {
        var document = CaptureDocument(image: try solid(.white, width: 100, height: 80), sourceURL: nil, createdAt: Date())
        let image = try layer(.red, rect: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2))
        document.imageLayers = [image]
        document = try XCTUnwrap(document.adjusting(.rotateClockwise).cropping(to: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)))
        document.geometry.outputSize = CGSize(width: 80, height: 120)
        let canvas = CaptureLayersNSCanvasView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.synchronize(document: document, annotations: [], selection: [], zoom: .fit)
        let start = canvas.viewPoint(for: CGPoint(x: 0.4, y: 0.4))
        let finish = canvas.viewPoint(for: CGPoint(x: 0.5, y: 0.45))
        XCTAssertTrue(canvas.outputDisplayRect.contains(start))
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: start, canvas: canvas, window: window))
        XCTAssertEqual(canvas.selection, [.image(image.id)])
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: finish, canvas: canvas, window: window))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: finish, canvas: canvas, window: window))
        XCTAssertEqual(canvas.layers[0].normalizedRect.minX, 0.4, accuracy: 0.00001)
        XCTAssertEqual(canvas.layers[0].normalizedRect.minY, 0.35, accuracy: 0.00001)
        window.orderOut(nil)
    }

    func testNativeCanvasRotationHandleOutsideImageRemainsUsable() throws {
        var document = CaptureDocument(image: try solid(.white, width: 100, height: 100), sourceURL: nil, createdAt: Date())
        let image = try layer(.red, rect: CGRect(x: 0.2, y: 0, width: 0.2, height: 0.2))
        document.imageLayers = [image]
        let canvas = CaptureLayersNSCanvasView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.synchronize(document: document, annotations: [], selection: [.image(image.id)], zoom: .fit)
        var commits = 0; canvas.onCommit = { _, _ in commits += 1 }
        let top = canvas.viewPoint(for: CGPoint(x: 0.3, y: 0))
        let handle = CGPoint(x: top.x, y: top.y - 22)
        let center = canvas.viewPoint(for: CGPoint(x: 0.3, y: 0.1))
        let radius = center.y - handle.y
        let angle: CGFloat = .pi / 6
        let rotated = CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
        XCTAssertFalse(canvas.outputDisplayRect.contains(handle))
        XCTAssertFalse(canvas.outputDisplayRect.contains(rotated))
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: handle, canvas: canvas, window: window))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: rotated, canvas: canvas, window: window))
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(canvas.layers[0].rotationDegrees, 30, accuracy: 0.00001)
        XCTAssertEqual(canvas.layers[0].normalizedRect, image.normalizedRect)
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: rotated, canvas: canvas, window: window))
        XCTAssertEqual(commits, 1)
        window.orderOut(nil)
    }

    private func layer(_ color: NSColor, rect: CGRect, z: Int = 0) throws -> CaptureImageLayer {
        CaptureImageLayer(name: "fixture", pngData: try XCTUnwrap(solid(color).captureLabPNGData()), normalizedRect: rect, zIndex: z)
    }
    private func solid(_ color: NSColor, width: Int = 10, height: Int = 10) throws -> NSImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let rgb = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
        context.setFillColor(rgb.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: width, height: height))
    }
    private func pixel(_ image: NSImage, _ x: Int, _ y: Int) throws -> NSColor {
        try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(image.captureLabCGImage())).colorAt(x: x, y: y))
    }
    private func assertColor(_ color: NSColor, _ expected: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        guard let a = color.usingColorSpace(.deviceRGB), let b = expected.usingColorSpace(.deviceRGB) else { return XCTFail("Color conversion failed", file: file, line: line) }
        XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.02, file: file, line: line)
    }
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, canvas: NSView, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    private func key(code: UInt16, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
}
