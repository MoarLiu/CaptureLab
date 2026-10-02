import AppKit
import SwiftUI
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureProjectTests: XCTestCase {
    func testProjectRoundTripPreservesObjectsGeometryAndRetinaSourceWithoutPathsOrUndo() throws {
        let image = try ProjectFixture.image()
        var document = CaptureDocument(image: image, sourceURL: URL(fileURLWithPath: "/private/fixture/user/source.png"),
                                       createdAt: Date(timeIntervalSinceReferenceDate: 123))
        let annotations = ProjectFixture.annotations
        document = document.adjusting(.rotateClockwise).adjusting(.flipHorizontal)
        document = try XCTUnwrap(document.cropping(to: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.7)))
        document.geometry.outputSize = CGSize(width: 96, height: 112)
        let data = try CaptureProjectStore.encode(document: document, annotations: annotations)
        let restored = try CaptureProjectStore.decode(data)
        XCTAssertEqual(restored.annotations, annotations)
        XCTAssertEqual(restored.document.geometry, document.geometry)
        XCTAssertEqual(restored.document.createdAt, document.createdAt)
        XCTAssertEqual(restored.document.image.size, image.size)
        XCTAssertEqual(restored.document.sourcePixelSize, image.captureLabPixelSize)
        XCTAssertNil(restored.document.sourceURL)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("/private/fixture"))
        let expected = try XCTUnwrap(document.applyingGeometry(to: XCTUnwrap(image.renderedWithCaptureLabAnnotations(annotations))))
        let actual = try XCTUnwrap(restored.document.applyingGeometry(to: XCTUnwrap(restored.document.image.renderedWithCaptureLabAnnotations(restored.annotations))))
        XCTAssertEqual(try pixels(actual), try pixels(expected))
    }

    func testRightAngleOperationsMatchIndividualPixelCoordinatesAndFourRotationsRestore() throws {
        let source = try ProjectFixture.image()
        let original = CaptureDocument(image: source, sourceURL: nil, createdAt: Date())
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(source.captureLabCGImage()))
        for operation in [CaptureDocument.Adjustment.rotateClockwise, .flipHorizontal, .flipVertical] {
            let document = original.adjusting(operation)
            let result = try XCTUnwrap(document.applyingGeometry(to: source))
            let output = NSBitmapImageRep(cgImage: try XCTUnwrap(result.captureLabCGImage()))
            for (x, y) in [(5, 5), (65, 8), (8, 48), (67, 51)] {
                let target: (Int, Int)
                switch operation {
                case .rotateClockwise: target = (59 - y, x)
                case .flipHorizontal: target = (79 - x, y)
                case .flipVertical: target = (x, 59 - y)
                }
                assertColor(try XCTUnwrap(output.colorAt(x: target.0, y: target.1)),
                            equals: try XCTUnwrap(bitmap.colorAt(x: x, y: y)))
            }
        }
        var rotated = original
        for _ in 0..<4 { rotated = rotated.adjusting(.rotateClockwise) }
        XCTAssertTrue(rotated.image === original.image)
        XCTAssertEqual(try pixels(XCTUnwrap(rotated.applyingGeometry(to: source))), try pixels(source))
    }

    func testCropAfterRotationAndFlipUsesVisiblePixelCoordinates() throws {
        let source = try ProjectFixture.image()
        let document = CaptureDocument(image: source, sourceURL: nil, createdAt: Date()).adjusting(.rotateClockwise).adjusting(.flipVertical)
        let selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let cropped = try XCTUnwrap(document.cropping(to: selection))
        let expected = try XCTUnwrap(CaptureImageCrop.crop(XCTUnwrap(document.applyingGeometry(to: source)), selection: selection))
        XCTAssertEqual(try pixels(XCTUnwrap(cropped.applyingGeometry(to: source))), try pixels(expected))
        XCTAssertTrue(cropped.image === source)
    }

    func testDamagedUnknownAndUnsafeProjectsAreRejectedBeforeReplacement() throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        XCTAssertTrue(model.importImageData(try XCTUnwrap(ProjectFixture.image().captureLabPNGData())))
        model.annotations = ProjectFixture.annotations
        let id = model.document?.id
        let data = try CaptureProjectStore.encode(document: XCTUnwrap(model.document), annotations: model.annotations)
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var variants: [[String: Any]] = []
        var unknown = valid; unknown["version"] = 999; variants.append(unknown)
        var missing = valid; missing.removeValue(forKey: "sourcePNG"); variants.append(missing)
        var broken = valid; broken["sourcePNG"] = Data("not png".utf8).base64EncodedString(); variants.append(broken)
        var geometry = valid; geometry["geometry"] = ["matrix": [1]]; variants.append(geometry)
        var singular = valid; singular["geometry"] = ["matrix": [0, 0, 0, 0, 0, 0]]; variants.append(singular)
        var oversize = valid; oversize["sourceLogicalSize"] = [1e20, 1e20]; variants.append(oversize)
        for value in variants {
            let url = fixture.root.appendingPathComponent("damaged.capturelab")
            try JSONSerialization.data(withJSONObject: value).write(to: url)
            XCTAssertFalse(model.openProject(at: url))
            XCTAssertEqual(model.document?.id, id)
            XCTAssertEqual(model.annotations, ProjectFixture.annotations)
            XCTAssertTrue(model.canUndoAnnotation)
        }
    }

    func testAtomicProjectReplacementIsPrivateAndLeavesNoTemporaryFiles() throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanUp() }
        let document = CaptureDocument(image: try ProjectFixture.image(), sourceURL: nil, createdAt: Date())
        let url = fixture.root.appendingPathComponent("editable.capturelab")
        try CaptureProjectStore.write(try CaptureProjectStore.encode(document: document, annotations: []), to: url)
        try CaptureProjectStore.write(try CaptureProjectStore.encode(document: document, annotations: ProjectFixture.annotations), to: url)
        XCTAssertEqual(try CaptureProjectStore.read(url).annotations, ProjectFixture.annotations)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasSuffix(".pending") })
    }

    func testDoneRestartHistoryRestoresEditableAnnotationsAndNewUndo() throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        XCTAssertTrue(model.importImageData(try XCTUnwrap(ProjectFixture.image().captureLabPNGData())))
        let image = model.document?.image
        model.annotations = ProjectFixture.annotations
        model.adjustImage(.rotateClockwise)
        model.cropSelection = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        XCTAssertTrue(model.applyCrop())
        XCTAssertTrue(model.resizeOutput(to: CGSize(width: 192, height: 256)))
        XCTAssertTrue(model.document?.image === image)
        let expected = try XCTUnwrap(model.renderedSnapshot()?.image)
        XCTAssertTrue(model.finishEditing())
        let item = try XCTUnwrap(model.historyItems.first)
        XCTAssertNotNil(item.projectFileName)
        let restarted = fixture.model(store: CaptureHistoryStore(environment: fixture.environment))
        restarted.openHistoryItem(item)
        XCTAssertEqual(restarted.annotations, ProjectFixture.annotations)
        XCTAssertEqual(restarted.document?.pixelSize, CGSize(width: 192, height: 256))
        XCTAssertFalse(restarted.canUndoAnnotation)
        XCTAssertEqual(try pixels(XCTUnwrap(restarted.renderedSnapshot()?.image)), try pixels(expected))
        restarted.annotations[0].text = "New editable text"
        restarted.undoAnnotation()
        XCTAssertEqual(restarted.annotations, ProjectFixture.annotations)
        restarted.redoAnnotation()
        XCTAssertEqual(restarted.annotations[0].text, "New editable text")
    }

    func testFailedMetadataWriteKeepsOldPairAndAllowsRetry() throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanUp() }
        var fail = false
        let store = CaptureHistoryStore(environment: fixture.environment, metadataWriter: { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        let model = fixture.model(store: store)
        XCTAssertTrue(model.importImageData(try XCTUnwrap(ProjectFixture.image().captureLabPNGData())))
        model.annotations = ProjectFixture.annotations
        XCTAssertTrue(model.preserveDocumentBeforeReplacement())
        let old = try XCTUnwrap(model.historyItems.first)
        let oldState = try store.editableSnapshot(for: old)
        model.annotations[0].text = "unsaved change"
        let id = model.document?.id
        fail = true
        XCTAssertFalse(model.preserveDocumentBeforeReplacement())
        XCTAssertEqual(model.document?.id, id)
        XCTAssertEqual(model.annotations[0].text, "unsaved change")
        XCTAssertTrue(model.canUndoAnnotation)
        let preserved = try store.editableSnapshot(for: old)
        XCTAssertEqual(preserved.project, oldState.project)
        XCTAssertEqual(preserved.preview, oldState.preview)
        fail = false
        XCTAssertTrue(model.preserveDocumentBeforeReplacement())
        let saved = try store.editableSnapshot(for: old)
        XCTAssertEqual(try CaptureProjectStore.decode(XCTUnwrap(saved.project)).annotations[0].text, "unsaved change")
        let assets = try FileManager.default.contentsOfDirectory(atPath: store.historyDirectory.path)
        XCTAssertEqual(assets.filter { $0.hasSuffix(".capturelab") }.count, 1)
        XCTAssertEqual(assets.filter { $0.hasSuffix(".png") }.count, 1)
    }

    func testPostCommitErrorRetainsBothNewAssets() throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanUp() }
        var fail = false
        let store = CaptureHistoryStore(environment: fixture.environment, metadataWriter: { data, url in
            try data.write(to: url, options: .atomic)
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
        })
        let model = fixture.model(store: store)
        XCTAssertTrue(model.importImageData(try XCTUnwrap(ProjectFixture.image().captureLabPNGData())))
        model.annotations = ProjectFixture.annotations
        fail = true
        XCTAssertFalse(model.preserveDocumentBeforeReplacement())
        let restarted = CaptureHistoryStore(environment: fixture.environment)
        let item = try XCTUnwrap(restarted.items.first)
        let state = try restarted.editableSnapshot(for: item)
        XCTAssertFalse(state.preview.isEmpty)
        XCTAssertEqual(try CaptureProjectStore.decode(XCTUnwrap(state.project)).annotations, ProjectFixture.annotations)
        XCTAssertTrue(model.hasImage)
    }

    func testConcurrentEditorsKeepBothVersionsAndDeleteReclaimsBothResources() throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanUp() }
        let first = fixture.model()
        XCTAssertTrue(first.importImageData(try XCTUnwrap(ProjectFixture.image().captureLabPNGData())))
        first.annotations = ProjectFixture.annotations
        XCTAssertTrue(first.preserveDocumentBeforeReplacement())
        let original = try XCTUnwrap(first.historyItems.first)
        let second = fixture.model(store: CaptureHistoryStore(environment: fixture.environment))
        second.openHistoryItem(original)
        first.annotations[0].text = "Editor A"
        second.annotations[0].text = "Editor B"
        XCTAssertTrue(first.preserveDocumentBeforeReplacement())
        XCTAssertTrue(second.preserveDocumentBeforeReplacement())
        XCTAssertEqual(second.historyItems.count, 2)
        let texts = try second.historyItems.map {
            try CaptureProjectStore.decode(XCTUnwrap(second.historyStore.editableSnapshot(for: $0).project)).annotations[0].text
        }
        XCTAssertEqual(Set(texts), ["Editor A", "Editor B"])
        for item in second.historyItems { try second.historyStore.remove(item) }
        let files = try FileManager.default.contentsOfDirectory(atPath: second.historyStore.historyDirectory.path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".png") || $0.hasSuffix(".capturelab") })
    }

    func testCorruptIndexRecoveryRetainsProjectAndMissingResourceDoesNotFlattenSilently() throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        XCTAssertTrue(model.importImageData(try XCTUnwrap(ProjectFixture.image().captureLabPNGData())))
        model.annotations = ProjectFixture.annotations
        XCTAssertTrue(model.finishEditing())
        try Data("damaged index".utf8).write(to: fixture.store.metadataURL)
        let recovered = CaptureHistoryStore(environment: fixture.environment)
        let item = try XCTUnwrap(recovered.items.first)
        XCTAssertNotNil(item.projectFileName)
        let reopened = fixture.model(store: recovered)
        reopened.openHistoryItem(item)
        XCTAssertEqual(reopened.annotations, ProjectFixture.annotations)
        reopened.clearDocument()
        try FileManager.default.removeItem(at: recovered.historyDirectory.appendingPathComponent(XCTUnwrap(item.projectFileName)))
        reopened.openHistoryItem(item)
        XCTAssertFalse(reopened.hasImage)
        XCTAssertFalse(try recovered.data(for: item).isEmpty, "The safe preview must remain shareable")
    }

    func testCloseAndQuitGatesPreserveEditsOnFailureAndSucceedOnRetry() throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanUp() }
        var fail = true
        let store = CaptureHistoryStore(environment: fixture.environment, imageWriter: { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        let model = fixture.model(store: store)
        XCTAssertTrue(model.importImageData(try XCTUnwrap(ProjectFixture.image().captureLabPNGData())))
        model.annotations = ProjectFixture.annotations
        let guardDelegate = CaptureDocumentCloseGuard.Coordinator(model: model)
        let window = NSWindow()
        window.isReleasedWhenClosed = false
        XCTAssertFalse(guardDelegate.windowShouldClose(window))
        XCTAssertTrue(model.canUndoAnnotation)
        CaptureLabAppDelegate.documentModel = model
        defer { CaptureLabAppDelegate.documentModel = nil }
        XCTAssertEqual(CaptureLabAppDelegate().applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        fail = false
        XCTAssertTrue(guardDelegate.windowShouldClose(window))
        XCTAssertEqual(CaptureLabAppDelegate().applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertEqual(try CaptureProjectStore.decode(XCTUnwrap(store.editableSnapshot(for: XCTUnwrap(store.items.first)).project)).annotations,
                       ProjectFixture.annotations)
    }

    func testCropPresetsExactPixelRoundingAndEdgeSnap() throws {
        let size = CGSize(width: 403, height: 301)
        for preset in [CaptureCropPreset.square, .fourThree, .sixteenNine, .original] {
            let ratio = try XCTUnwrap(preset.ratio(in: size))
            let rect = CaptureCropGeometry.selection(anchor: CGPoint(x: 0.1, y: 0.2), current: CGPoint(x: 0.99, y: 0.99), size: size, ratio: ratio)
            XCTAssertEqual(rect.width * size.width / (rect.height * size.height), ratio, accuracy: 0.00001)
            XCTAssertLessThanOrEqual(rect.maxX, 1)
            XCTAssertLessThanOrEqual(rect.maxY, 1)
        }
        let exact = CGRect(x: 17 / size.width, y: 19 / size.height, width: 123 / size.width, height: 111 / size.height)
        XCTAssertEqual(CaptureImageCrop.pixelRect(exact, pixelSize: size), CGRect(x: 17, y: 19, width: 123, height: 111))
        let centered = CaptureCropGeometry.exactSelection(size: CGSize(width: 100, height: 100), canvasSize: size, center: CGPoint(x: 0.5, y: 0.5))
        let shifted = CaptureCropGeometry.moving(centered, dx: 0.0123, dy: -0.0137, snap: .zero, pixelSize: size)
        XCTAssertEqual(CaptureImageCrop.pixelRect(centered, pixelSize: size)?.size, CGSize(width: 100, height: 100))
        XCTAssertEqual(CaptureImageCrop.pixelRect(shifted, pixelSize: size)?.size, CGSize(width: 100, height: 100))
        let moved = CaptureCropGeometry.moving(CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.4), dx: -0.19, dy: 0.39, snap: CGSize(width: 0.02, height: 0.02))
        XCTAssertEqual(moved.minX, 0)
        XCTAssertEqual(moved.maxY, 1)
    }

    func testFreshEditOfExpiredCaptureSurvivesRetentionUntilNewExpiryAndReclaimsPair() throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanUp() }
        var now = Date(timeIntervalSinceReferenceDate: 10 * 86_400)
        let store = CaptureHistoryStore(environment: fixture.environment, now: { now })
        XCTAssertNil(try store.applyRetention(store.previewRetention(.init(maximumCount: 30, maximumAgeDays: 1))))
        let source = try ProjectFixture.image()
        let document = CaptureDocument(image: source, sourceURL: nil, createdAt: Date(timeIntervalSinceReferenceDate: 0))
        let item = try store.saveEditable(preview: XCTUnwrap(source.captureLabPNGData()),
            project: CaptureProjectStore.encode(document: document, annotations: ProjectFixture.annotations),
            for: nil, pixelSize: document.pixelSize, createdAt: document.createdAt)
        try store.refresh()
        XCTAssertEqual(store.items.map(\.id), [item.id])
        now = now.addingTimeInterval(2 * 86_400)
        try store.refresh()
        XCTAssertTrue(store.items.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.historyDirectory.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".png") || $0.hasSuffix(".capturelab") })
    }

    func testEveryShareDestinationUsesTheSameTransformedComposite() async throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanUp() }
        let settings = CloudflareR2SettingsStore(environment: fixture.environment, secretStore: ProjectSecretStore())
        try settings.save(CloudflareR2SettingsInput(endpoint: "https://account.r2.cloudflarestorage.com", bucket: "fixture",
            pathPrefix: "tests", publicBaseURL: "https://example.test", accessKeyID: "fixture-key", secretAccessKey: "fixture-secret"))
        var uploaded: Data?
        var pinned: NSImage?
        let finished = expectation(description: "Upload receives composite")
        let destination = fixture.root.appendingPathComponent("shared.png")
        let model = CaptureLabViewModel(r2SettingsStore: settings, historyStore: fixture.store,
            failurePresentationOperation: { _, message in XCTFail(message) }, pasteboard: fixture.pasteboard,
            uploadOperation: { request in
                uploaded = request.data
                return CloudflareR2UploadResult(url: "https://example.test/shared.png", objectKey: "shared.png", sizeBytes: request.data.count)
            }, saveDestinationOperation: { _ in destination }, pinOperation: { image, _ in pinned = image })
        XCTAssertTrue(model.importImageData(try XCTUnwrap(ProjectFixture.image().captureLabPNGData())))
        model.annotations = ProjectFixture.annotations
        model.adjustImage(.rotateClockwise)
        model.cropSelection = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        XCTAssertTrue(model.applyCrop())
        XCTAssertTrue(model.resizeOutput(to: CGSize(width: 120, height: 90)))
        let expected = try XCTUnwrap(model.renderedSnapshot()?.image)
        XCTAssertTrue(model.copyRenderedImage())
        XCTAssertEqual(try pixels(XCTUnwrap(NSImage(pasteboard: fixture.pasteboard))), try pixels(expected))
        model.pinCurrentCapture()
        XCTAssertEqual(try pixels(XCTUnwrap(pinned)), try pixels(expected))
        model.saveRenderedImage()
        XCTAssertEqual(try pixels(XCTUnwrap(NSImage(contentsOf: destination))), try pixels(expected))
        model.uploadRenderedImage { _ in finished.fulfill() }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(try pixels(XCTUnwrap(NSImage(data: XCTUnwrap(uploaded)))), try pixels(expected))
        XCTAssertTrue(model.finishEditing())
        XCTAssertEqual(try pixels(XCTUnwrap(NSImage(data: fixture.store.data(for: XCTUnwrap(fixture.store.items.first))))), try pixels(expected))
    }

    func testNativeWindowCloseActuallyRunsRecoveryGateAndForwardsDelegate() throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanUp() }
        var fail = true
        let history = CaptureHistoryStore(environment: fixture.environment, imageWriter: { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        let model = fixture.model(store: history)
        XCTAssertTrue(model.importImageData(try XCTUnwrap(ProjectFixture.image().captureLabPNGData())))
        model.annotations = ProjectFixture.annotations
        let originalDelegate = ProjectWindowDelegate()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = originalDelegate
        let host = NSHostingView(rootView: Color.clear.background(CaptureDocumentCloseGuard(model: model)))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<4 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        window.performClose(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(originalDelegate.closeCount, 0)
        XCTAssertTrue(model.canUndoAnnotation)
        fail = false
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(originalDelegate.closeCount, 1)
        let snapshot = try history.editableSnapshot(for: XCTUnwrap(history.items.first))
        XCTAssertEqual(try CaptureProjectStore.decode(XCTUnwrap(snapshot.project)).annotations, ProjectFixture.annotations)
    }

    func testProjectEncoderRejectsAStateItsDecoderCannotOpen() throws {
        let image = try ProjectFixture.image()
        image.size = CGSize(width: 40_000, height: 30_000)
        let document = CaptureDocument(image: image, sourceURL: nil, createdAt: Date())
        XCTAssertThrowsError(try CaptureProjectStore.encode(document: document, annotations: []))
    }

    func testOverwideImportDoesNotReplaceRecoverableDocument() throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        XCTAssertTrue(model.importImageData(try XCTUnwrap(ProjectFixture.image().captureLabPNGData())))
        let original = model.document?.id
        let context = try XCTUnwrap(CGContext(data: nil, width: 40_000, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let overwide = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 40_000, height: 1))
        XCTAssertFalse(model.importImageData(try XCTUnwrap(overwide.captureLabPNGData())))
        XCTAssertEqual(model.document?.id, original)
        XCTAssertTrue(model.preserveDocumentBeforeReplacement())
    }

    func testUpscaledCropDoesNotSamplePixelsOutsideItsBoundary() throws {
        let source = try ProjectFixture.image()
        var document = try XCTUnwrap(CaptureDocument(image: source, sourceURL: nil, createdAt: Date())
            .cropping(to: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        document.geometry.outputSize = CGSize(width: 400, height: 300)
        let output = NSBitmapImageRep(cgImage: try XCTUnwrap(document.applyingGeometry(to: source)?.captureLabCGImage()))
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        for (x, y) in [(0, 0), (399, 0), (399, 299), (200, 299)] {
            assertColor(try XCTUnwrap(output.colorAt(x: x, y: y)), equals: red)
        }
    }

    func testInvalidOutputSizesKeepDocumentAndUndoState() throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        XCTAssertTrue(model.importImageData(try XCTUnwrap(ProjectFixture.image().captureLabPNGData())))
        let id = model.document?.id
        for size in [CGSize.zero, CGSize(width: CGFloat.nan, height: 10), CGSize(width: 10.5, height: 10), CGSize(width: 32768, height: 32768)] {
            XCTAssertFalse(model.resizeOutput(to: size))
            XCTAssertEqual(model.document?.id, id)
            XCTAssertFalse(model.canUndoAnnotation)
        }
        XCTAssertTrue(model.resizeOutput(to: CGSize(width: 160, height: 120)))
        model.undoAnnotation()
        XCTAssertEqual(model.document?.id, id)
        model.redoAnnotation()
        XCTAssertEqual(model.renderedSnapshot()?.image?.captureLabPixelSize, CGSize(width: 160, height: 120))
    }

    private func assertColor(_ actual: NSColor, equals expected: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        let a = actual.usingColorSpace(.sRGB)!, b = expected.usingColorSpace(.sRGB)!
        XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.01, file: file, line: line)
    }
    private func pixels(_ image: NSImage) throws -> Data {
        let cg = try XCTUnwrap(image.captureLabCGImage())
        let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return Data(bytes: try XCTUnwrap(context.data), count: cg.width * cg.height * 4)
    }
}

@MainActor
private final class ProjectFixture {
    let root: URL
    let environment: [String: String]
    let store: CaptureHistoryStore
    let pasteboard = NSPasteboard(name: .init("CaptureProjectTests.\(UUID().uuidString)"))
    init() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureProjectTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        environment = ["HOME": root.path]
        store = CaptureHistoryStore(environment: environment)
    }
    func model(store: CaptureHistoryStore? = nil) -> CaptureLabViewModel {
        CaptureLabViewModel(r2SettingsStore: CloudflareR2SettingsStore(environment: environment, secretStore: ProjectSecretStore()),
                            historyStore: store ?? self.store, failurePresentationOperation: { _, _ in }, pasteboard: pasteboard)
    }
    func cleanUp() { pasteboard.clearContents(); try? FileManager.default.removeItem(at: root) }
    static var annotations: [CaptureAnnotation] {
        // Stable IDs make equality across independently requested fixture arrays meaningful.
        [CaptureAnnotation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, kind: .text,
                           normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.2), text: "Editable",
                           appearance: CaptureAnnotationAppearance(color: CaptureAnnotationColor(.white), lineWidth: 3, fontSize: 8)),
         CaptureAnnotation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, kind: .mosaic,
                           normalizedRect: CGRect(x: 0.4, y: 0.4, width: 0.5, height: 0.5))]
    }
    static func image() throws -> NSImage {
        var bytes = [UInt8](repeating: 255, count: 80 * 60 * 4)
        for y in 0..<60 { for x in 0..<80 {
            let offset = (y * 80 + x) * 4
            let color: [UInt8] = y < 30 ? (x < 40 ? [255, 0, 0] : [0, 255, 0]) : (x < 40 ? [0, 0, 255] : [255, 255, 0])
            for channel in 0..<3 { bytes[offset + channel] = color[channel] }
        } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cg = try XCTUnwrap(CGImage(width: 80, height: 60, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 320,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return NSImage(cgImage: cg, size: CGSize(width: 40, height: 30))
    }
}

private final class ProjectSecretStore: CloudflareR2SecretStoring {
    var secrets: [String: String] = [:]
    func secret(for accessKeyID: String) throws -> String? { secrets[accessKeyID] }
    func setSecret(_ secret: String, for accessKeyID: String) throws { secrets[accessKeyID] = secret }
    func deleteSecret(for accessKeyID: String) throws { secrets.removeValue(forKey: accessKeyID) }
}

@MainActor
private final class ProjectWindowDelegate: NSObject, NSWindowDelegate {
    var closeCount = 0
    func windowWillClose(_ notification: Notification) { closeCount += 1 }
}
