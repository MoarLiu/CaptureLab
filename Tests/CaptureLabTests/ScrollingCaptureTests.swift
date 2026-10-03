import AppKit
import XCTest
@testable import CaptureLab

final class ScrollingCaptureTests: XCTestCase {
    private func fixture(offset: Int, direction: ScrollingCaptureDirection = .vertical,
                         length: Int = 160, breadth: Int = 120,
                         leading: Int = 0, trailing: Int = 0, repeated: Bool = false) throws -> ScrollingCapturePixels {
        let width = direction == .vertical ? breadth : length
        let height = direction == .vertical ? length : breadth
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for major in 0..<length {
            for minor in 0..<breadth {
                let global: Int
                if major < leading { global = -1000 + major }
                else if major >= length - trailing { global = -2000 + major - (length - trailing) }
                else { global = major - leading + offset }
                let value = repeated ? ((global % 12) * 13 + minor % 5) : pixelHash(global, minor)
                let i = direction == .vertical ? (major * width + minor) * 4 : (minor * width + major) * 4
                bytes[i] = UInt8(truncatingIfNeeded: value)
                bytes[i + 1] = UInt8(truncatingIfNeeded: value >> 8)
                bytes[i + 2] = UInt8(truncatingIfNeeded: value >> 16)
            }
        }
        return try .init(width: width, height: height, bytes: bytes)
    }

    private func pixelHash(_ row: Int, _ column: Int) -> Int {
        var n = UInt32(truncatingIfNeeded: row &* 198_491_317 &+ column &* 65_537 &+ 17)
        n ^= n >> 13; n &*= 1_274_126_177; n ^= n >> 16
        return Int(n)
    }

    func testVerticalAndHorizontalStitchMatchEveryKnownSourcePixel() throws {
        for direction in ScrollingCaptureDirection.allCases {
            let first = try fixture(offset: 0, direction: direction)
            var stitcher = try ScrollingCaptureStitcher(first: first, direction: direction)
            XCTAssertEqual(try stitcher.append(fixture(offset: 43, direction: direction)), .accepted(addedPixels: 43))
            XCTAssertEqual(try stitcher.append(fixture(offset: 81, direction: direction)), .accepted(addedPixels: 38))
            let result = try ScrollingCapturePixels(image: stitcher.render())
            XCTAssertEqual(result, try fixture(offset: 0, direction: direction, length: 241), "No missing, repeated, or inverted rows/columns")
        }
    }

    func testFixedLeadingAndTrailingBandsAppearOnceForBothDirections() throws {
        for direction in ScrollingCaptureDirection.allCases {
            let first = try fixture(offset: 0, direction: direction, leading: 17, trailing: 13)
            var stitcher = try ScrollingCaptureStitcher(first: first, direction: direction, bands: .init(leading: 17, trailing: 13))
            XCTAssertEqual(try stitcher.append(fixture(offset: 37, direction: direction, leading: 17, trailing: 13)), .accepted(addedPixels: 37))
            XCTAssertEqual(try ScrollingCapturePixels(image: stitcher.render()),
                           try fixture(offset: 0, direction: direction, length: 197, leading: 17, trailing: 13))
        }
    }

    func testDuplicateDoesNotGrowImageOrRetainFrame() throws {
        let first = try fixture(offset: 0)
        var stitcher = try ScrollingCaptureStitcher(first: first, direction: .vertical)
        XCTAssertEqual(try stitcher.append(first), .duplicate)
        XCTAssertEqual(stitcher.outputLength, 160)
        XCTAssertEqual(stitcher.segments.count, 1)
        XCTAssertNil(stitcher.pending)
    }

    func testReverseTooFastRefreshAndChangedSizeAreRejected() throws {
        let first = try fixture(offset: 50)
        for (next, expected) in [
            (try fixture(offset: 0), ScrollingCaptureIssue.reverse),
            (try fixture(offset: 240), .noOverlap),
            (try fixture(offset: 3_999), .noOverlap),
            (try fixture(offset: 80, length: 170), .dimensionsChanged)
        ] {
            var stitcher = try ScrollingCaptureStitcher(first: first, direction: .vertical)
            XCTAssertEqual(try stitcher.append(next), .rejected(expected))
            XCTAssertEqual(stitcher.outputLength, 160)
            XCTAssertEqual(stitcher.segments.count, 1)
        }
    }

    func testRepeatedTextureNeedsManualDecisionAndCanBeAcceptedAtKnownSeam() throws {
        let first = try fixture(offset: 0, repeated: true)
        var stitcher = try ScrollingCaptureStitcher(first: first, direction: .vertical)
        XCTAssertEqual(try stitcher.append(fixture(offset: 37, repeated: true)), .rejected(.ambiguous))
        XCTAssertNotNil(stitcher.pending)
        try stitcher.applyManualSeam(addedPixels: 37)
        XCTAssertNil(stitcher.pending)
        XCTAssertEqual(stitcher.outputLength, 197)
        XCTAssertEqual(try ScrollingCapturePixels(image: stitcher.render()), try fixture(offset: 0, length: 197, repeated: true))
    }

    func testManualSeamChangesLastSegmentAndUndoRestoresMatchingReference() throws {
        var stitcher = try ScrollingCaptureStitcher(first: fixture(offset: 0), direction: .vertical)
        _ = try stitcher.append(fixture(offset: 43))
        _ = try stitcher.append(fixture(offset: 81))
        try stitcher.applyManualSeam(addedPixels: 39)
        XCTAssertEqual(stitcher.outputLength, 242)
        try stitcher.applyManualSeam(addedPixels: 38)
        XCTAssertEqual(try ScrollingCapturePixels(image: stitcher.render()), try fixture(offset: 0, length: 241))
        stitcher.discardLast()
        XCTAssertEqual(stitcher.outputLength, 203)
        XCTAssertEqual(try stitcher.append(fixture(offset: 81)), .accepted(addedPixels: 38))
        stitcher.discardLast(); stitcher.discardLast(); stitcher.discardLast()
        XCTAssertEqual(stitcher.segments.count, 1)
        XCTAssertEqual(try ScrollingCapturePixels(image: stitcher.render()), try fixture(offset: 0))
    }

    func testInvalidBandsAndSeamsCannotMutateAcceptedState() throws {
        var stitcher = try ScrollingCaptureStitcher(first: fixture(offset: 0), direction: .vertical)
        XCTAssertThrowsError(try stitcher.setBands(.init(leading: 100, trailing: 100)))
        XCTAssertThrowsError(try stitcher.setBands(.init(leading: -1, trailing: 0)))
        _ = try stitcher.append(fixture(offset: 43))
        XCTAssertThrowsError(try stitcher.setBands(.init(leading: 5, trailing: 0)))
        for shift in [0, -1, 121, Int.max] { XCTAssertThrowsError(try stitcher.applyManualSeam(addedPixels: shift)) }
        XCTAssertEqual(stitcher.outputLength, 203)
    }

    func testDimensionPixelAndResidentBudgetsAreEnforcedBeforeAppend() throws {
        let first = try fixture(offset: 0), next = try fixture(offset: 43)
        var dimensionLimited = try ScrollingCaptureStitcher(first: first, direction: .vertical, maximumDimension: 190)
        var pixelLimited = try ScrollingCaptureStitcher(first: first, direction: .vertical, maximumPixels: 23_000)
        var memoryLimited = try ScrollingCaptureStitcher(first: first, direction: .vertical, memoryBudget: 550_000)
        for i in 0..<3 {
            var value = [dimensionLimited, pixelLimited, memoryLimited][i]
            XCTAssertThrowsError(try value.append(next)) { XCTAssertEqual($0 as? ScrollingCaptureIssue, .resourceLimit) }
            XCTAssertEqual(value.segments.count, 1)
        }
        // Ensure temporary test copies cannot accidentally make a later test pass through mutation.
        dimensionLimited.discardLast(); pixelLimited.discardLast(); memoryLimited.discardLast()
    }

    func testPreviewUsesBoundedDimensionsWithoutChangingFullOutput() throws {
        var stitcher = try ScrollingCaptureStitcher(first: fixture(offset: 0), direction: .vertical)
        for offset in [60, 120, 180] { _ = try stitcher.append(fixture(offset: offset)) }
        let preview = try stitcher.render(maximumPreviewSide: 100)
        XCTAssertLessThanOrEqual(max(preview.width, preview.height), 100)
        XCTAssertEqual(stitcher.outputLength, 340)
        XCTAssertEqual(try ScrollingCapturePixels(image: stitcher.render()), try fixture(offset: 0, length: 340))
    }

    @MainActor
    func testAntialiasedTextPagePreservesExactSeamAndTextPixels() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 440, height: 700, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 440, height: 700))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for row in 0..<35 {
            let content = "\(row + 1). \(String(pixelHash(row, 11), radix: 16))  Example \(String(pixelHash(row, 51), radix: 16))"
            content.draw(at: CGPoint(x: 12, y: row * 20), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .foregroundColor: NSColor.black
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
        let page = try XCTUnwrap(context.makeImage())
        let first = try ScrollingCapturePixels(image: XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 440, height: 400))))
        let second = try ScrollingCapturePixels(image: XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 137, width: 440, height: 400))))
        var stitcher = try ScrollingCaptureStitcher(first: first, direction: .vertical)
        XCTAssertEqual(try stitcher.append(second), .accepted(addedPixels: 137))
        let expected = try ScrollingCapturePixels(image: XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 440, height: 537))))
        XCTAssertEqual(try ScrollingCapturePixels(image: stitcher.render()), expected)
    }

    func testWorkerCancellationAndResetDoNotLeakPreviousCapture() async throws {
        let worker = ScrollingCaptureWorker()
        let first = try ScrollingCaptureImage(image: fixture(offset: 0).image())
        _ = try await worker.begin(image: first, direction: .vertical)
        _ = try await worker.append(image: ScrollingCaptureImage(image: fixture(offset: 43).image()))
        await worker.clear()
        do { _ = try await worker.finish(); XCTFail("Cleared worker must not return an old image") }
        catch { XCTAssertTrue(error is CancellationError) }
        let progress = try await worker.begin(image: first, direction: .horizontal)
        XCTAssertEqual(progress.segmentCount, 1)
        XCTAssertEqual(progress.size, CGSize(width: 120, height: 160))
        let invalid = try ScrollingCaptureImage(image: ScrollingCapturePixels(width: 16, height: 16, bytes: [UInt8](repeating: 255, count: 16 * 16 * 4)).image())
        do { _ = try await worker.begin(image: invalid, direction: .vertical); XCTFail("Invalid new capture must fail") }
        catch { XCTAssertEqual(error as? ScrollingCaptureIssue, .invalidFrame) }
        do { _ = try await worker.finish(); XCTFail("A failed new capture must not return the previous session") }
        catch { XCTAssertTrue(error is CancellationError) }
        await worker.clear()
    }

    func testCancelledMatchingLeavesAcceptedFrameUnchanged() async throws {
        let worker = ScrollingCaptureWorker()
        let first = try fixture(offset: 0)
        _ = try await worker.begin(image: ScrollingCaptureImage(image: first.image()), direction: .vertical)
        let next = try ScrollingCaptureImage(image: fixture(offset: 43).image())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.append(image: next)
        }
        do { _ = try await task.value; XCTFail("Cancelled match must stop before acceptance") }
        catch { XCTAssertTrue(error is CancellationError) }
        let output = try await worker.finish()
        XCTAssertEqual(try ScrollingCapturePixels(image: output.image), first)
        await worker.clear()
    }

    func testWindowSelectionRejectsPartialCoverageAndForeignOverlaysButExcludesControls() throws {
        let region = CGRect(x: 20, y: 20, width: 120, height: 160)
        func window(_ id: Int, pid: Int = 2, layer: Int = 0, bounds: CGRect = CGRect(x: 0, y: 0, width: 400, height: 400)) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowNumber as String: NSNumber(value: id),
             kCGWindowLayer as String: NSNumber(value: layer), kCGWindowBounds as String: bounds.dictionaryRepresentation,
             kCGWindowAlpha as String: NSNumber(value: 1)]
        }
        let target = window(10)
        let baseline = try XCTUnwrap(ScrollingCaptureWindow.find(containing: region, windows: [target], excludingPID: 1))
        XCTAssertEqual(baseline.id, 10)
        XCTAssertEqual(ScrollingCaptureWindow.find(containing: region, windows: [window(20, pid: 1, layer: 3), target], excludingPID: 1), baseline)
        XCTAssertNil(ScrollingCaptureWindow.find(containing: region, windows: [window(20, layer: 3), target], excludingPID: 1))
        XCTAssertNil(ScrollingCaptureWindow.find(containing: region, windows: [window(20, bounds: CGRect(x: 30, y: 30, width: 50, height: 50)), target], excludingPID: 1))
        let moved = ScrollingCaptureWindow.find(containing: region, windows: [window(10, bounds: CGRect(x: 1, y: 1, width: 400, height: 400))], excludingPID: 1)
        XCTAssertNotEqual(moved, baseline)
    }
}
