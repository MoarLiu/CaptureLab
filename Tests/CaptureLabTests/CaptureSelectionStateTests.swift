import AppKit
import XCTest
@testable import CaptureLab

@MainActor
final class CaptureSelectionStateTests: XCTestCase {
    func testDeletingSelectedAnnotationClearsModelSelectionWithoutCanvasFeedback() throws {
        let fixture = try SelectionStateFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let annotation = CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4))
        model.addAnnotation(annotation)
        model.selectAnnotation(annotation.id)
        XCTAssertEqual(model.selectedAnnotationID, annotation.id)

        model.clearAnnotations()

        XCTAssertNil(model.selectedAnnotationID)
        XCTAssertTrue(model.annotations.isEmpty)
    }

    func testSwitchingToolsKeepsOnlyEditableSelectionAndCropAlwaysDeselects() throws {
        let fixture = try SelectionStateFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let annotation = CaptureAnnotation(kind: .rectangle, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4))
        model.addAnnotation(annotation)
        model.selectAnnotation(annotation.id)
        model.selectedTool = .rectangle
        XCTAssertEqual(model.selectedAnnotationID, annotation.id)
        model.selectedTool = .select
        XCTAssertEqual(model.selectedAnnotationID, annotation.id)

        model.selectedTool = .arrow
        XCTAssertNil(model.selectedAnnotationID)
        model.selectedTool = .select
        model.selectAnnotation(annotation.id)
        model.selectedTool = .crop
        XCTAssertNil(model.selectedAnnotationID)
    }
}

@MainActor
private struct SelectionStateFixture {
    let home: URL
    let model: CaptureLabViewModel
    let pasteboard: NSPasteboard

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("SelectionStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = ["HOME": home.path]
        pasteboard = NSPasteboard(name: .init("SelectionStateTests.\(UUID().uuidString)"))
        model = CaptureLabViewModel(
            r2SettingsStore: CloudflareR2SettingsStore(environment: environment, secretStore: SelectionStateSecretStore()),
            historyStore: CaptureHistoryStore(environment: environment),
            failurePresentationOperation: { _, message in XCTFail(message) },
            pasteboard: pasteboard
        )
    }

    func remove() {
        pasteboard.clearContents()
        try? FileManager.default.removeItem(at: home)
    }
}

private struct SelectionStateSecretStore: CloudflareR2SecretStoring {
    func secret(for accessKeyID: String) throws -> String? { nil }
    func setSecret(_ secret: String, for accessKeyID: String) throws {}
    func deleteSecret(for accessKeyID: String) throws {}
}
