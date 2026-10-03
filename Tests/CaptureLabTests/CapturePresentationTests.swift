import AppKit
import ImageIO
import XCTest
@testable import CaptureLab

final class CapturePresentationTests: XCTestCase {
    func testDefaultPresentationPreservesSourcePixelsAndSize() throws {
        let source = try makeImage(width: 30, height: 20)
        let presentation = CapturePresentation()
        let rendered = try XCTUnwrap(presentation.render(source))
        XCTAssertTrue(rendered === source)
        XCTAssertEqual(presentation.outputSize(for: CGSize(width: 30, height: 20)), CGSize(width: 30, height: 20))
    }

    func testAspectExpansionAndAlignmentNeverScaleOrCropContent() throws {
        let sourceSize = CGSize(width: 80, height: 40)
        var presentation = CapturePresentation()
        presentation.padding = 10
        presentation.aspect = .square
        XCTAssertEqual(presentation.outputSize(for: sourceSize), CGSize(width: 100, height: 100))
        XCTAssertEqual(presentation.contentRect(for: sourceSize), CGRect(x: 10, y: 30, width: 80, height: 40))
        presentation.alignment = .top
        XCTAssertEqual(presentation.contentRect(for: sourceSize)?.minY, 10)
        presentation.alignment = .bottom
        XCTAssertEqual(presentation.contentRect(for: sourceSize)?.minY, 50)
        for aspect in CapturePresentationAspect.allCases {
            presentation.aspect = aspect
            let size = try XCTUnwrap(presentation.outputSize(for: sourceSize))
            let rect = try XCTUnwrap(presentation.contentRect(for: sourceSize))
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rect))
            XCTAssertEqual(rect.size, sourceSize)
            if let ratio = presentation.ratio { XCTAssertEqual(size.width / size.height, ratio, accuracy: 0.03) }
        }
    }

    func testTopAlignedPresentationKeepsAsymmetricContentOrientation() throws {
        let context = try XCTUnwrap(CapturePresentation.context(size: CGSize(width: 40, height: 20)))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 10))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 10, width: 40, height: 10))
        let source = try XCTUnwrap(context.makeImage())
        let original = NSBitmapImageRep(cgImage: source)
        var presentation = CapturePresentation()
        presentation.padding = 10; presentation.aspect = .square; presentation.alignment = .top
        let output = NSBitmapImageRep(cgImage: try XCTUnwrap(presentation.render(source)))
        for row in [0, 5, 15, 19] {
            let expected = try XCTUnwrap(original.colorAt(x: 20, y: row))
            let actual = try XCTUnwrap(output.colorAt(x: 30, y: 10 + row))
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.01)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.01)
        }
        XCTAssertEqual(try XCTUnwrap(output.colorAt(x: 30, y: 31)).alphaComponent, 0)
    }

    func testSolidBackgroundAndRoundedContentPreservePNGAlpha() throws {
        let source = try makeImage(width: 40, height: 40)
        var presentation = CapturePresentation()
        presentation.padding = 10
        presentation.cornerRadius = 15
        let transparent = NSBitmapImageRep(cgImage: try XCTUnwrap(presentation.render(source)))
        XCTAssertEqual(try XCTUnwrap(transparent.colorAt(x: 0, y: 0)).alphaComponent, 0)
        XCTAssertEqual(try XCTUnwrap(transparent.colorAt(x: 10, y: 10)).alphaComponent, 0, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(transparent.colorAt(x: 30, y: 30)).redComponent, 1, accuracy: 0.01)
        presentation.background = .solid
        presentation.color = CaptureRGBAColor(red: 0, green: 0, blue: 1)
        let solid = NSBitmapImageRep(cgImage: try XCTUnwrap(presentation.render(source)))
        XCTAssertEqual(try XCTUnwrap(solid.colorAt(x: 0, y: 0)).blueComponent, 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(solid.colorAt(x: 10, y: 10)).blueComponent, 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(solid.colorAt(x: 30, y: 30)).redComponent, 1, accuracy: 0.01)
    }

    func testShadowAddsAlphaOutsideContentWithoutFillingTransparentSource() throws {
        let source = try makeImage(width: 20, height: 20)
        var presentation = CapturePresentation()
        presentation.padding = 20
        presentation.shadowOpacity = 0.8
        presentation.shadowBlur = 8
        presentation.shadowOffset = 4
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(presentation.render(source)))
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 30, y: 42)).alphaComponent, 0)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 30, y: 30)).redComponent, 1, accuracy: 0.02)
        let emptySource = try makeImage(width: 20, height: 20, transparent: true)
        let empty = NSBitmapImageRep(cgImage: try XCTUnwrap(presentation.render(emptySource)))
        XCTAssertEqual(try XCTUnwrap(empty.colorAt(x: 30, y: 30)).alphaComponent, 0)
    }

    func testGradientAndBuiltInBackgroundsRenderDifferentEndpoints() throws {
        let source = try makeImage(width: 10, height: 10)
        var presentation = CapturePresentation()
        presentation.padding = 20
        presentation.background = .gradient
        presentation.color = .white; presentation.secondaryColor = .black
        presentation.gradientAngle = 0
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(presentation.render(source)))
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).redComponent,
                             try XCTUnwrap(bitmap.colorAt(x: 49, y: 0)).redComponent)
        for style in CaptureBuiltInBackground.allCases {
            presentation.background = .builtIn; presentation.builtIn = style
            XCTAssertNotNil(presentation.render(source))
        }
    }

    func testEmbeddedBackgroundRoundTripAndMissingImageFailsClosed() throws {
        let source = try makeImage(width: 10, height: 10)
        var presentation = CapturePresentation()
        presentation.background = .image; presentation.padding = 10
        XCTAssertThrowsError(try presentation.validate())
        XCTAssertNil(presentation.render(source))
        presentation.customBackgroundData = Data([1, 2, 3])
        XCTAssertNil(presentation.render(source))
        presentation.customBackgroundData = try XCTUnwrap(NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:]))
        let restored = try JSONDecoder().decode(CapturePresentation.self, from: JSONEncoder().encode(presentation))
        XCTAssertEqual(restored, presentation)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(restored.render(source)))
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).redComponent, 1, accuracy: 0.01)
    }

    func testInactiveBackgroundResourcesAndPrivatePathsAreRejected() throws {
        var presentation = CapturePresentation()
        presentation.background = .solid
        presentation.customBackgroundData = Data([1, 2, 3])
        XCTAssertThrowsError(try presentation.validate())
        presentation.customBackgroundData = nil
        for name in ["/Users/private/background.png", "folder/background.png", "C:\\private\\background.png", "..", "broken\nname.png"] {
            presentation.customBackgroundName = name
            XCTAssertThrowsError(try presentation.validate())
        }
        presentation.customBackgroundName = "background.png"
        XCTAssertNoThrow(try presentation.validate())
    }

    func testCustomBackgroundWithOnlyAValidPNGHeaderIsRejected() throws {
        let source = try makeImage(width: 10, height: 10)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:]))
        let header = Data(png.prefix(33))
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(header as CFData, nil))
        XCTAssertNotNil(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil))
        var presentation = CapturePresentation()
        presentation.background = .image; presentation.customBackgroundData = header
        XCTAssertThrowsError(try presentation.validate()) { error in
            guard case CapturePresentationError.missingBackground = error else {
                return XCTFail("Expected a repairable missing-background error, got \(error)")
            }
        }
        XCTAssertNil(presentation.render(source))
    }

    func testInvalidAndOversizeLayoutFailsBeforeAllocation() {
        var presentation = CapturePresentation()
        presentation.padding = .nan
        XCTAssertNil(presentation.outputSize(for: CGSize(width: 20, height: 20)))
        presentation.padding = 4096
        XCTAssertNil(presentation.outputSize(for: CGSize(width: 32_000, height: 2)))
        presentation.padding = 10; presentation.aspect = .custom; presentation.customAspectHeight = 0
        XCTAssertThrowsError(try presentation.validate())
    }

    func testAutomaticBalanceUsesContentDimensionsAndCentersExtraSpace() throws {
        var presentation = CapturePresentation()
        presentation.alignment = .bottomTrailing; presentation.aspect = .square
        let size = CGSize(width: 1000, height: 500)
        presentation.balancePadding(for: size)
        XCTAssertEqual(presentation.padding, 40)
        XCTAssertEqual(presentation.alignment, .center)
        let output = try XCTUnwrap(presentation.outputSize(for: size))
        let rect = try XCTUnwrap(presentation.contentRect(for: size))
        XCTAssertEqual(rect.minX, output.width - rect.maxX)
        XCTAssertEqual(rect.minY, output.height - rect.maxY)
    }

    private func makeImage(width: Int, height: Int, transparent: Bool = false) throws -> CGImage {
        let context = try XCTUnwrap(CapturePresentation.context(size: CGSize(width: width, height: height)))
        if !transparent {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(context.makeImage())
    }
}

@MainActor
final class CapturePresentationPersistenceTests: XCTestCase {
    func testPresetSaveReloadDeleteWithEmbeddedBackgroundAndFilePermissions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("presets.json")
        let store = CapturePresentationStore(url: url)
        var presentation = CapturePresentation(); presentation.padding = 40; presentation.background = .builtIn
        let preset = try store.save(name: "  Presentation  ", presentation: presentation)
        XCTAssertEqual(preset.name, "Presentation")
        let reopened = CapturePresentationStore(url: url)
        XCTAssertEqual(reopened.presets, [preset])
        XCTAssertNil(reopened.errorMessage)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try reopened.delete(preset.id)
        XCTAssertTrue(CapturePresentationStore(url: url).presets.isEmpty)
        XCTAssertThrowsError(try store.save(name: "  ", presentation: presentation))
    }

    func testPresetWriteFailureKeepsExistingInMemoryState() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let backup = folder.appendingPathExtension("backup")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: backup)
        }
        let store = CapturePresentationStore(url: folder.appendingPathComponent("presets.json"))
        let original = try store.save(name: "Keep this preset", presentation: CapturePresentation())
        try FileManager.default.moveItem(at: folder, to: backup)
        try Data().write(to: folder)
        XCTAssertThrowsError(try store.save(name: "Failed write", presentation: CapturePresentation()))
        XCTAssertEqual(store.presets, [original])
        XCTAssertEqual(CapturePresentationStore(url: backup.appendingPathComponent("presets.json")).presets, [original])
    }

    func testLastExportSettingsRoundTripAndCorruptionFallback() throws {
        let name = "CaptureExportSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CaptureExportSettingsStore(defaults: defaults)
        var settings = CaptureExportSettings(); settings.format = .jpeg; settings.quality = 0.65
        settings.width = 640; settings.height = 480; settings.matte = .purple
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
        defaults.set(Data([0, 1]), forKey: CaptureExportSettingsStore.key)
        XCTAssertEqual(store.load(), CaptureExportSettings())
        settings.width = -1; store.save(settings)
        XCTAssertEqual(store.load(), CaptureExportSettings())
    }
}
