import XCTest
@testable import CaptureLab

final class ScreenCaptureServiceTests: XCTestCase {
    func testRegionCaptureArguments() {
        let service = ScreenCaptureService()
        let url = URL(fileURLWithPath: "/tmp/capture.png")

        XCTAssertEqual(service.arguments(for: .region, outputURL: url), ["-i", "-x", "/tmp/capture.png"])
    }

    func testFullScreenCaptureArguments() {
        let service = ScreenCaptureService()
        let url = URL(fileURLWithPath: "/tmp/capture.png")

        XCTAssertEqual(service.arguments(for: .fullScreen, outputURL: url), ["-x", "/tmp/capture.png"])
    }

    func testWindowCaptureArguments() {
        let service = ScreenCaptureService()
        let url = URL(fileURLWithPath: "/tmp/capture.png")

        XCTAssertEqual(service.arguments(for: .window, outputURL: url), ["-i", "-w", "-x", "/tmp/capture.png"])
    }

    func testDelayedRegionCaptureArguments() {
        let service = ScreenCaptureService()
        let url = URL(fileURLWithPath: "/tmp/capture.png")

        XCTAssertEqual(
            service.arguments(for: .delayedRegion(seconds: 5), outputURL: url),
            ["-T", "5", "-i", "-x", "/tmp/capture.png"]
        )
    }
}

