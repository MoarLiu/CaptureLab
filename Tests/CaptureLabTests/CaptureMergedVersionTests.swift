import AppKit
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureMergedVersionTests: XCTestCase {
    func testV2RoundTripPreservesSourceLayersAdvancedAnnotationsGeometryAndPresentation() throws {
        let fixture = try MergedVersionFixture()
        defer { fixture.cleanUp() }
        var document = try fixture.document()
        document.sourceURL = fixture.root.appendingPathComponent("private-original.png")
        let annotations = MergedVersionFixture.annotations
        let expected = try composite(document, annotations: annotations)
        let encoded = try CaptureProjectStore.encode(document: document, annotations: annotations)
        let json = try object(encoded)
        XCTAssertEqual(json["version"] as? Int, 2)
        XCTAssertNotNil(json["imageLayers"])
        XCTAssertNotNil(json["presentation"])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(fixture.root.path))

        let restored = try CaptureProjectStore.decode(encoded)
        XCTAssertNil(restored.document.sourceURL)
        XCTAssertEqual(restored.document.createdAt, document.createdAt)
        XCTAssertEqual(restored.document.image.size, document.image.size)
        XCTAssertEqual(restored.document.sourcePixelSize, document.sourcePixelSize)
        XCTAssertEqual(try pixels(restored.document.image), try pixels(document.image))
        XCTAssertEqual(restored.document.imageLayers, document.imageLayers)
        XCTAssertEqual(restored.annotations, annotations)
        XCTAssertEqual(restored.document.geometry, document.geometry)
        XCTAssertEqual(restored.document.presentation, document.presentation)
        XCTAssertEqual(restored.document.renderedPixelSize, expected.captureLabPixelSize)
        XCTAssertEqual(try pixels(composite(restored.document, annotations: restored.annotations)), try pixels(expected))

        var withoutLayers = document
        withoutLayers.imageLayers = []
        XCTAssertNotEqual(try pixels(composite(withoutLayers, annotations: annotations)), try pixels(expected))
        XCTAssertNotEqual(try pixels(composite(document, annotations: [])), try pixels(expected))
    }

    func testLegacyV1ProjectWithoutNewFieldsKeepsEditableGeometryAndAppearance() throws {
        let fixture = try MergedVersionFixture()
        defer { fixture.cleanUp() }
        var document = try fixture.document()
        document.imageLayers = []
        document.presentation = CapturePresentation()
        let annotation = CaptureAnnotation(kind: .rectangle,
            normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.4),
            appearance: CaptureAnnotationAppearance(color: CaptureAnnotationColor(.white), lineWidth: 3, fontSize: 12))
        var legacy = try object(CaptureProjectStore.encode(document: document, annotations: [annotation]))
        legacy["version"] = 1
        legacy.removeValue(forKey: "imageLayers")
        legacy.removeValue(forKey: "presentation")
        // A real v1 appearance has only these original fields.
        var encodedAnnotations = try XCTUnwrap(legacy["annotations"] as? [[String: Any]])
        let appearance = try XCTUnwrap(encodedAnnotations[0]["appearance"] as? [String: Any])
        encodedAnnotations[0]["appearance"] = appearance.filter { ["color", "lineWidth", "fontSize"].contains($0.key) }
        legacy["annotations"] = encodedAnnotations
        let restored = try CaptureProjectStore.decode(JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(restored.document.imageLayers.isEmpty)
        XCTAssertTrue(restored.document.presentation.isIdentity)
        XCTAssertEqual(restored.document.geometry, document.geometry)
        XCTAssertEqual(restored.annotations, [annotation])
        XCTAssertEqual(try pixels(composite(restored.document, annotations: restored.annotations)),
                       try pixels(composite(document, annotations: [annotation])))
    }

    func testLegacyV1AppearanceAcceptsPreviouslySupportedFontAndStrokeRanges() throws {
        let fixture = try MergedVersionFixture()
        defer { fixture.cleanUp() }
        var document = try fixture.document()
        document.imageLayers = []
        document.presentation = CapturePresentation()
        let annotation = CaptureAnnotation(kind: .text,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), text: "Legacy text",
            appearance: CaptureAnnotationAppearance(lineWidth: 4, fontSize: 24))
        var legacy = try object(CaptureProjectStore.encode(document: document, annotations: [annotation]))
        legacy["version"] = 1
        legacy.removeValue(forKey: "imageLayers")
        legacy.removeValue(forKey: "presentation")
        var objects = try XCTUnwrap(legacy["annotations"] as? [[String: Any]])
        objects[0]["appearance"] = ["lineWidth": 1024, "fontSize": 1500]
        legacy["annotations"] = objects
        let restored = try CaptureProjectStore.decode(JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored.annotations.first?.appearance.lineWidth, 1024)
        XCTAssertEqual(restored.annotations.first?.appearance.fontSize, 1500)
        // Opening an old file must also leave a state that can be saved again.
        let migrated = try CaptureProjectStore.encode(document: restored.document, annotations: restored.annotations)
        XCTAssertEqual(try CaptureProjectStore.decode(migrated).annotations, restored.annotations)
    }

    func testResizeAndRotationRejectPresentationOverflowWithoutChangingUndoState() throws {
        let fixture = try MergedVersionFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        try fixture.installComposition(in: model)
        let before = try XCTUnwrap(model.document)
        let annotations = model.annotations
        XCTAssertTrue(CaptureDocumentGeometry.validSize(CGSize(width: 10_000, height: 10_000)))
        XCTAssertNil(before.presentation.outputSize(for: CGSize(width: 10_000, height: 10_000)))
        XCTAssertFalse(model.resizeOutput(to: CGSize(width: 10_000, height: 10_000)))
        XCTAssertEqual(model.document?.id, before.id)
        XCTAssertEqual(model.document?.geometry, before.geometry)
        XCTAssertEqual(model.document?.presentation, before.presentation)
        XCTAssertEqual(model.annotations, annotations)
        model.undoAnnotation()
        XCTAssertTrue(try XCTUnwrap(model.document).presentation.isIdentity,
                      "Rejected resize must not add an undo entry before the presentation edit")
        model.redoAnnotation()
        XCTAssertEqual(model.document?.presentation, before.presentation)

        // Use small embedded resources and change only geometry; no large bitmap
        // is rendered while testing this fixed-aspect rotation boundary.
        let rotated = fixture.model()
        XCTAssertTrue(rotated.importImageData(try MergedVersionFixture.png(red: 0.2, green: 0.3, blue: 0.4)))
        XCTAssertTrue(rotated.resizeOutput(to: CGSize(width: 100, height: 10_000)))
        var portrait = CapturePresentation()
        portrait.aspect = .nineSixteen
        rotated.applyPresentation(portrait)
        let portraitDocument = try XCTUnwrap(rotated.document)
        XCTAssertNotNil(portrait.outputSize(for: portraitDocument.pixelSize))
        XCTAssertNil(portrait.outputSize(for: CGSize(width: 10_000, height: 100)))
        rotated.adjustImage(.rotateClockwise)
        XCTAssertEqual(rotated.document?.id, portraitDocument.id)
        XCTAssertEqual(rotated.document?.geometry, portraitDocument.geometry)
        rotated.undoAnnotation()
        XCTAssertTrue(try XCTUnwrap(rotated.document).presentation.isIdentity)
    }

    func testMalformedV2ResourcesStylesAndPresentationCannotReplaceRecoverableDocument() throws {
        let fixture = try MergedVersionFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        try fixture.installComposition(in: model)
        let before = try XCTUnwrap(model.document)
        let annotations = model.annotations
        let valid = try object(CaptureProjectStore.encode(document: before, annotations: annotations))
        var variants: [(String, [String: Any])] = []
        var missingLayers = valid; missingLayers.removeValue(forKey: "imageLayers")
        variants.append(("missing layers", missingLayers))
        var missingPresentation = valid; missingPresentation.removeValue(forKey: "presentation")
        variants.append(("missing presentation", missingPresentation))
        var unknownVersion = valid; unknownVersion["version"] = 999
        variants.append(("unknown version", unknownVersion))
        let validLayers = try XCTUnwrap(valid["imageLayers"] as? [[String: Any]])
        var badResource = validLayers; badResource[0]["pngData"] = Data("broken image".utf8).base64EncodedString()
        var invalid = valid; invalid["imageLayers"] = badResource
        variants.append(("invalid embedded image", invalid))
        var truncatedResource = validLayers
        let resourcePNG = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(validLayers[0]["pngData"] as? String)))
        truncatedResource[0]["pngData"] = Data(resourcePNG.prefix(33)).base64EncodedString()
        invalid = valid; invalid["imageLayers"] = truncatedResource
        variants.append(("PNG header without image pixels", invalid))
        var duplicate = valid; duplicate["imageLayers"] = [validLayers[0], validLayers[0]]
        variants.append(("duplicate layer identity", duplicate))
        var badRotation = validLayers; badRotation[0]["rotationDegrees"] = 400_000
        invalid = valid; invalid["imageLayers"] = badRotation
        variants.append(("invalid rotation", invalid))
        let validAnnotations = try XCTUnwrap(valid["annotations"] as? [[String: Any]])
        for (field, value) in [("blurRadius", 0.0), ("spotlightOpacity", 1.5), ("brushSmoothing", -0.5)] {
            var objects = validAnnotations
            var appearance = try XCTUnwrap(objects[0]["appearance"] as? [String: Any])
            appearance[field] = value
            objects[0]["appearance"] = appearance
            invalid = valid; invalid["annotations"] = objects
            variants.append(("invalid \(field)", invalid))
        }
        var presentation = try XCTUnwrap(valid["presentation"] as? [String: Any])
        presentation["padding"] = -1
        invalid = valid; invalid["presentation"] = presentation
        variants.append(("negative padding", invalid))
        presentation = try XCTUnwrap(valid["presentation"] as? [String: Any])
        presentation["background"] = "image"
        presentation["customBackgroundData"] = Data("broken background".utf8).base64EncodedString()
        invalid = valid; invalid["presentation"] = presentation
        variants.append(("invalid embedded background", invalid))

        let url = fixture.root.appendingPathComponent("malformed.capturelab")
        for (name, value) in variants {
            let data = try JSONSerialization.data(withJSONObject: value)
            XCTAssertThrowsError(try CaptureProjectStore.decode(data), name)
            try data.write(to: url)
            XCTAssertFalse(model.openProject(at: url), name)
            XCTAssertEqual(model.document?.id, before.id, name)
            XCTAssertEqual(model.document?.imageLayers, before.imageLayers, name)
            XCTAssertEqual(model.document?.geometry, before.geometry, name)
            XCTAssertEqual(model.document?.presentation, before.presentation, name)
            XCTAssertEqual(model.annotations, annotations, name)
            XCTAssertTrue(model.canUndoAnnotation, name)
        }
    }

    func testMixedObjectGestureIsExactlyOneUndoRedoStep() throws {
        let fixture = try MergedVersionFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        XCTAssertTrue(model.importImageData(try MergedVersionFixture.png(red: 0.15, green: 0.2, blue: 0.3)))
        let layers = try fixture.layers()
        let annotations = MergedVersionFixture.annotations
        model.commitObjects(layers: layers, annotations: annotations)
        let source = try XCTUnwrap(model.document?.image)
        let selection: Set<CaptureObjectID> = [.image(layers[0].id), .annotation(annotations[0].id)]
        let moved = CaptureObjectOperations.translated(layers: layers, annotations: annotations,
                                                       selection: selection, dx: 0.05, dy: 0.04)
        XCTAssertNotEqual(moved.layers, layers)
        XCTAssertNotEqual(moved.annotations, annotations)
        model.commitObjects(layers: moved.layers, annotations: moved.annotations)
        model.undoAnnotation()
        XCTAssertEqual(model.document?.imageLayers, layers)
        XCTAssertEqual(model.annotations, annotations)
        XCTAssertTrue(model.document?.image === source)
        model.redoAnnotation()
        XCTAssertEqual(model.document?.imageLayers, moved.layers)
        XCTAssertEqual(model.annotations, moved.annotations)
        model.undoAnnotation()
        model.undoAnnotation()
        XCTAssertEqual(model.document?.imageLayers, [])
        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertFalse(model.canUndoAnnotation, "One insertion and one mixed gesture must create only two steps")
    }

    func testPresentationUndoPreservesLayersAndCropWithoutFlatteningSource() throws {
        let fixture = try MergedVersionFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        try fixture.installComposition(in: model, withPresentation: false)
        let before = try XCTUnwrap(model.document)
        let originalPixels = try pixels(XCTUnwrap(model.renderedSnapshot()?.image))
        let presentation = try fixture.presentation()
        model.applyPresentation(presentation)
        XCTAssertEqual(model.document?.presentation, presentation)
        XCTAssertNotEqual(model.document?.renderedPixelSize, before.renderedPixelSize)
        model.undoAnnotation()
        XCTAssertEqual(model.document?.geometry, before.geometry)
        XCTAssertEqual(model.document?.imageLayers, before.imageLayers)
        XCTAssertEqual(model.document?.presentation, before.presentation)
        XCTAssertEqual(try pixels(XCTUnwrap(model.renderedSnapshot()?.image)), originalPixels)
        model.redoAnnotation()
        XCTAssertEqual(model.document?.presentation, presentation)
        XCTAssertTrue(model.document?.image === before.image)
    }

    func testHistoryRestartKeepsAllEmbeddedResourcesAfterOriginalFilesAreRemoved() throws {
        let fixture = try MergedVersionFixture()
        defer { fixture.cleanUp() }
        let inputs = fixture.root.appendingPathComponent("original-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let document = try fixture.document()
        let sourceURL = inputs.appendingPathComponent("source.png")
        let layerURL = inputs.appendingPathComponent("layer.png")
        let backgroundURL = inputs.appendingPathComponent("background.png")
        try XCTUnwrap(document.image.captureLabPNGData()).write(to: sourceURL)
        try document.imageLayers[0].pngData.write(to: layerURL)
        try XCTUnwrap(document.presentation.customBackgroundData).write(to: backgroundURL)
        let model = fixture.model()
        XCTAssertTrue(model.importImageData(try Data(contentsOf: sourceURL)))
        XCTAssertTrue(model.addImageResources([(try Data(contentsOf: layerURL), "layer.png")]))
        model.commitObjects(layers: document.imageLayers, annotations: MergedVersionFixture.annotations)
        model.adjustImage(.rotateClockwise)
        model.cropSelection = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        XCTAssertTrue(model.applyCrop())
        var presentation = document.presentation
        presentation.customBackgroundData = try Data(contentsOf: backgroundURL)
        model.applyPresentation(presentation)
        let expectedDocument = try XCTUnwrap(model.document)
        let expectedAnnotations = model.annotations
        let expectedPixels = try pixels(XCTUnwrap(model.renderedSnapshot()?.image))
        XCTAssertTrue(model.finishEditing())
        let item = try XCTUnwrap(model.historyItems.first)
        XCTAssertEqual(item.pixelSize, expectedDocument.renderedPixelSize)
        XCTAssertNotNil(item.projectFileName)
        try FileManager.default.removeItem(at: inputs)

        let reopenedStore = CaptureHistoryStore(environment: fixture.environment)
        let restarted = fixture.model(store: reopenedStore)
        restarted.openHistoryItem(item)
        XCTAssertEqual(restarted.document?.imageLayers, expectedDocument.imageLayers)
        XCTAssertEqual(restarted.document?.geometry, expectedDocument.geometry)
        XCTAssertEqual(restarted.document?.presentation, expectedDocument.presentation)
        XCTAssertEqual(restarted.annotations, expectedAnnotations)
        XCTAssertFalse(restarted.canUndoAnnotation)
        XCTAssertEqual(try pixels(XCTUnwrap(restarted.renderedSnapshot()?.image)), expectedPixels)
        XCTAssertEqual(try pixels(XCTUnwrap(NSImage(data: reopenedStore.data(for: item)))), expectedPixels)
        var editedLayers = try XCTUnwrap(restarted.document?.imageLayers)
        editedLayers[0].rotationDegrees += 10
        var editedAnnotations = restarted.annotations
        editedAnnotations[0].appearance.lineWidth = 5
        restarted.commitObjects(layers: editedLayers, annotations: editedAnnotations)
        restarted.undoAnnotation()
        XCTAssertEqual(restarted.document?.imageLayers, expectedDocument.imageLayers)
        XCTAssertEqual(restarted.annotations, expectedAnnotations)
        restarted.redoAnnotation()
        XCTAssertEqual(restarted.document?.imageLayers, editedLayers)
        XCTAssertEqual(restarted.annotations, editedAnnotations)
    }

    func testPNGExportSaveCopyAndPinUseIdenticalLayerAnnotationCropAndPresentationPixels() throws {
        let fixture = try MergedVersionFixture()
        defer { fixture.cleanUp() }
        let destination = fixture.root.appendingPathComponent("shared.png")
        var pinned: NSImage?
        let model = fixture.model(destination: destination, pin: { image, _ in pinned = image })
        try fixture.installComposition(in: model)
        let expected = try XCTUnwrap(model.renderedSnapshot()?.image)
        let expectedPixels = try pixels(expected)
        XCTAssertEqual(expected.captureLabPixelSize, model.document?.renderedPixelSize)
        model.prepareExport()
        let exportImage = try XCTUnwrap(model.exportRequest?.image)
        XCTAssertEqual(try pixels(exportImage), expectedPixels)
        let encoded = try CaptureExportSettings().encode(exportImage)
        XCTAssertEqual(try pixels(XCTUnwrap(NSImage(data: encoded))), expectedPixels)
        XCTAssertTrue(model.copyRenderedImage())
        XCTAssertEqual(try pixels(XCTUnwrap(NSImage(pasteboard: fixture.pasteboard))), expectedPixels)
        model.pinCurrentCapture()
        XCTAssertEqual(try pixels(XCTUnwrap(pinned)), expectedPixels)
        model.saveRenderedImage()
        XCTAssertEqual(try pixels(XCTUnwrap(NSImage(contentsOf: destination))), expectedPixels)
    }

    func testMultiResourceImportIsAtomicForExistingAndEmptyDocuments() throws {
        let fixture = try MergedVersionFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        try fixture.installComposition(in: model)
        model.undoAnnotation() // Keep a redo step and prove failed imports do not clear it.
        let before = try XCTUnwrap(model.document)
        let annotations = model.annotations
        let expectedPixels = try pixels(XCTUnwrap(model.renderedSnapshot()?.image))
        let resources: [(data: Data, name: String)] = [
            (try MergedVersionFixture.png(red: 1, green: 0.5, blue: 0), "valid.png"),
            (Data("not an image".utf8), "invalid.png")
        ]
        XCTAssertFalse(model.addImageResources(resources))
        XCTAssertEqual(model.document?.id, before.id)
        XCTAssertEqual(model.document?.imageLayers, before.imageLayers)
        XCTAssertEqual(model.document?.geometry, before.geometry)
        XCTAssertEqual(model.document?.presentation, before.presentation)
        XCTAssertEqual(model.annotations, annotations)
        XCTAssertEqual(try pixels(XCTUnwrap(model.renderedSnapshot()?.image)), expectedPixels)
        XCTAssertTrue(model.canRedoAnnotation)
        model.redoAnnotation()
        XCTAssertFalse(try XCTUnwrap(model.document).presentation.isIdentity)

        let empty = fixture.model()
        XCTAssertFalse(empty.addImageResources(resources))
        XCTAssertFalse(empty.hasImage)
        XCTAssertTrue(empty.annotations.isEmpty)
        XCTAssertFalse(empty.canUndoAnnotation)
        XCTAssertTrue(empty.addImageResources([resources[0], resources[0]]))
        XCTAssertTrue(empty.hasImage)
        XCTAssertEqual(empty.document?.imageLayers.count, 1)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func composite(_ document: CaptureDocument, annotations: [CaptureAnnotation]) throws -> NSImage {
        let layers = try XCTUnwrap(CaptureLayerComposition.render(source: document.image, layers: document.imageLayers))
        let annotated = try XCTUnwrap(layers.renderedWithCaptureLabAnnotations(annotations))
        let transformed = try XCTUnwrap(document.applyingGeometry(to: annotated))
        return try XCTUnwrap(document.presentation.render(transformed))
    }

    private func pixels(_ image: NSImage) throws -> Data {
        let cg = try XCTUnwrap(image.captureLabCGImage())
        let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return Data(bytes: try XCTUnwrap(context.data), count: cg.width * cg.height * 4)
    }
}

@MainActor
private final class MergedVersionFixture {
    let root: URL
    let environment: [String: String]
    let store: CaptureHistoryStore
    let pasteboard = NSPasteboard(name: .init("CaptureMergedVersionTests.\(UUID().uuidString)"))

    init() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureMergedVersionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        environment = ["HOME": root.path]
        store = CaptureHistoryStore(environment: environment)
    }

    func model(store: CaptureHistoryStore? = nil, destination: URL? = nil,
               pin: @escaping CaptureLabViewModel.PinOperation = { _, _ in }) -> CaptureLabViewModel {
        CaptureLabViewModel(
            r2SettingsStore: CloudflareR2SettingsStore(environment: environment, secretStore: MergedVersionSecretStore()),
            historyStore: store ?? self.store, failurePresentationOperation: { _, _ in }, pasteboard: pasteboard,
            saveDestinationOperation: { _ in destination }, pinOperation: pin,
            workflowSettings: CaptureWorkflowSettings(defaults: nil))
    }

    func cleanUp() {
        pasteboard.clearContents()
        try? FileManager.default.removeItem(at: root)
    }

    func layers() throws -> [CaptureImageLayer] {
        [CaptureImageLayer(name: "cyan.png", pngData: try Self.png(red: 0, green: 0.8, blue: 1),
            normalizedRect: CGRect(x: 0.1, y: 0.12, width: 0.45, height: 0.5), rotationDegrees: 12, zIndex: 0),
         CaptureImageLayer(name: "magenta.png", pngData: try Self.png(red: 0.9, green: 0.1, blue: 0.7),
            normalizedRect: CGRect(x: 0.4, y: 0.35, width: 0.4, height: 0.4), rotationDegrees: -8, zIndex: 1)]
    }

    func presentation() throws -> CapturePresentation {
        var value = CapturePresentation()
        value.background = .image
        value.customBackgroundData = try Self.png(red: 0.8, green: 0.7, blue: 0.2)
        value.customBackgroundName = "background.png"
        value.padding = 9
        value.cornerRadius = 5
        value.shadowOpacity = 0.35
        value.shadowBlur = 3
        value.shadowOffset = 2
        value.aspect = .square
        value.alignment = .bottomTrailing
        return value
    }

    func document() throws -> CaptureDocument {
        let image = try XCTUnwrap(NSImage(data: Self.png(red: 0.15, green: 0.2, blue: 0.3)))
        image.size = CGSize(width: 40, height: 30)
        var document = CaptureDocument(image: image, sourceURL: nil, createdAt: Date(timeIntervalSinceReferenceDate: 123))
        document.imageLayers = try layers()
        document = document.adjusting(.rotateClockwise).adjusting(.flipHorizontal)
        document = try XCTUnwrap(document.cropping(to: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)))
        document.geometry.outputSize = CGSize(width: 72, height: 96)
        document.presentation = try presentation()
        return document
    }

    func installComposition(in model: CaptureLabViewModel, withPresentation: Bool = true) throws {
        XCTAssertTrue(model.importImageData(try Self.png(red: 0.15, green: 0.2, blue: 0.3)))
        model.commitObjects(layers: try layers(), annotations: Self.annotations)
        model.adjustImage(.rotateClockwise)
        model.adjustImage(.flipHorizontal)
        model.cropSelection = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        XCTAssertTrue(model.applyCrop())
        XCTAssertTrue(model.resizeOutput(to: CGSize(width: 72, height: 96)))
        if withPresentation { model.applyPresentation(try presentation()) }
    }

    static var annotations: [CaptureAnnotation] {
        var arrow = CaptureAnnotation.curvedArrow(start: CGPoint(x: 0.15, y: 0.2),
            end: CGPoint(x: 0.7, y: 0.65), control: CGPoint(x: 0.6, y: 0.15))
        arrow.id = UUID(uuidString: "00000000-0000-0000-0000-000000000091")!
        arrow.appearance = CaptureAnnotationAppearance(color: CaptureAnnotationColor(.white), lineWidth: 2,
                                                       arrowStyle: .doubleEnded)
        let ellipse = CaptureAnnotation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000092")!, kind: .ellipse,
            normalizedRect: CGRect(x: 0.25, y: 0.4, width: 0.35, height: 0.3),
            appearance: CaptureAnnotationAppearance(color: CaptureAnnotationColor(.white), lineWidth: 2,
                shapeFill: .strokeAndFill, fillColor: CaptureAnnotationColor(.systemOrange)))
        let text = CaptureAnnotation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000093")!, kind: .text,
            normalizedRect: CGRect(x: 0.1, y: 0.75, width: 0.65, height: 0.15), text: "Editable",
            appearance: CaptureAnnotationAppearance(color: CaptureAnnotationColor(.white), lineWidth: 1, fontSize: 7,
                fontFamily: "Helvetica", fontWeight: .bold, textAlignment: .left,
                textBackgroundColor: CaptureAnnotationColor(.black), textBorderColor: CaptureAnnotationColor(.white)))
        return [arrow, ellipse, text]
    }

    static func png(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8,
            bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 80, height: 60))
        return try XCTUnwrap(image.captureLabPNGData())
    }
}

private final class MergedVersionSecretStore: CloudflareR2SecretStoring {
    private var secrets: [String: String] = [:]
    func secret(for accessKeyID: String) throws -> String? { secrets[accessKeyID] }
    func setSecret(_ secret: String, for accessKeyID: String) throws { secrets[accessKeyID] = secret }
    func deleteSecret(for accessKeyID: String) throws { secrets.removeValue(forKey: accessKeyID) }
}
