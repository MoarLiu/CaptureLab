import CoreGraphics
import Foundation

enum ScrollingCaptureDirection: String, CaseIterable, Sendable {
    case vertical, horizontal

    var title: String {
        self == .vertical
            ? L10n.text(en: "Vertical Scrolling Capture", zh: "纵向滚动截图")
            : L10n.text(en: "Horizontal Scrolling Capture", zh: "横向滚动截图")
    }
}

enum ScrollingCaptureIssue: Error, Equatable, LocalizedError, Sendable {
    case invalidFrame, dimensionsChanged, ambiguous, reverse, noOverlap, resourceLimit, invalidSeam

    var errorDescription: String? {
        switch self {
        case .invalidFrame:
            return L10n.text(en: "Select a region at least 96 pixels wide and high, up to 12 megapixels.", zh: "请选择宽高至少 96 像素、最多 1200 万像素的区域。")
        case .dimensionsChanged:
            return L10n.text(en: "The captured size changed. Finish this capture and select the region again.", zh: "捕获尺寸发生变化。请结束本次截图并重新框选。")
        case .ambiguous:
            return L10n.text(en: "Repeated or blank content makes this seam uncertain. Review the pending frame and set the added pixels manually, or scroll back.", zh: "重复或空白内容使接缝无法确定。请查看待拼接画面、手动设置新增像素，或向回滚动。")
        case .reverse:
            return L10n.text(en: "Reverse scrolling detected. Scroll forward to the last accepted position, then resume.", zh: "检测到反向滚动。请向前滚动至最后已接收的位置，再继续。")
        case .noOverlap:
            return L10n.text(en: "No reliable overlap: scrolling may be too fast, or the content changed. Scroll back and use smaller steps, or finish the accepted image.", zh: "无法找到可靠重叠：可能滚动过快或内容已变化。请回滚并减小步幅，或结束并保留已接收图像。")
        case .resourceLimit:
            return L10n.text(en: "Capture reached its limit (32,768 pixels per side, 40 MP, or a 384 MiB image budget). Finish or discard the last segment.", zh: "已达到截图限制（单边 32768 像素、4000 万像素或 384 MiB 图像预算）。请结束或丢弃最后一段。")
        case .invalidSeam:
            return L10n.text(en: "Added pixels must leave at least 25% overlap in the scrolling content.", zh: "新增像素必须为滚动内容保留至少 25% 的重叠。")
        }
    }
}

/// Immutable CGImage is safe to share between the capture and stitching executors.
struct ScrollingCaptureImage: @unchecked Sendable {
    let image: CGImage
}

/// RGBA rows use CGImage's top-to-bottom pixel order. No AppKit objects cross executors.
struct ScrollingCapturePixels: Sendable, Equatable {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) throws {
        guard width >= 1, height >= 1, width <= 32_768, height <= 32_768,
              width * height <= 40_000_000, bytes.count == width * height * 4 else {
            throw ScrollingCaptureIssue.invalidFrame
        }
        self.width = width; self.height = height; self.bytes = bytes
    }

    init(image: CGImage) throws {
        guard image.width >= 96, image.height >= 96, image.width * image.height <= 12_000_000 else {
            throw ScrollingCaptureIssue.invalidFrame
        }
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = data.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard success else { throw ScrollingCaptureIssue.invalidFrame }
        try self.init(width: image.width, height: image.height, bytes: data)
    }

    func image() throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ScrollingCaptureIssue.invalidFrame
        }
        return image
    }

    func length(_ direction: ScrollingCaptureDirection) -> Int { direction == .vertical ? height : width }
    func breadth(_ direction: ScrollingCaptureDirection) -> Int { direction == .vertical ? width : height }
    func index(major: Int, minor: Int, direction: ScrollingCaptureDirection) -> Int {
        direction == .vertical ? (major * width + minor) * 4 : (minor * width + major) * 4
    }
}

struct ScrollingCaptureBands: Equatable, Sendable {
    var leading = 0
    var trailing = 0

    func valid(for length: Int) -> Bool {
        leading >= 0 && trailing >= 0 && leading <= length && trailing <= length && length - leading - trailing >= 64
    }
}

enum ScrollingCaptureMatch: Equatable, Sendable {
    case duplicate
    case accepted(addedPixels: Int)
    case rejected(ScrollingCaptureIssue)
}

enum ScrollingCaptureMatcher {
    static func match(_ previous: ScrollingCapturePixels, _ next: ScrollingCapturePixels,
                      direction: ScrollingCaptureDirection, bands: ScrollingCaptureBands) throws -> ScrollingCaptureMatch {
        guard previous.width == next.width, previous.height == next.height else { return .rejected(.dimensionsChanged) }
        let length = previous.length(direction), breadth = previous.breadth(direction)
        guard bands.valid(for: length) else { throw ScrollingCaptureIssue.invalidFrame }
        if previous.bytes == next.bytes { return .duplicate }
        let body = length - bands.leading - bands.trailing
        let maximumShift = body - max(24, body / 4)
        var scores: [(shift: Int, error: Double)] = []
        scores.reserveCapacity(maximumShift * 2 + 1)
        for shift in -maximumShift...maximumShift {
            if shift % 64 == 0 { try Task.checkCancellation() }
            let error = score(previous, next, direction: direction, bands: bands, shift: shift,
                              majorSamples: 36, minorSamples: 32)
            scores.append((shift, error))
        }
        scores.sort { $0.error < $1.error }
        guard let best = scores.first else { return .rejected(.noOverlap) }
        // A dense second pass prevents sparse samples from accepting content refreshes or animations.
        let verified = score(previous, next, direction: direction, bands: bands, shift: best.shift,
                             majorSamples: min(body, 320), minorSamples: min(breadth, 160))
        guard best.error <= 5, verified <= 5 else { return .rejected(.noOverlap) }
        if best.shift == 0, verified <= 0.8 { return .duplicate }
        let alternative = scores.first { abs($0.shift - best.shift) > 2 }?.error ?? .infinity
        guard alternative - best.error >= 1.2 else { return .rejected(.ambiguous) }
        guard best.shift > 0 else { return .rejected(best.shift < 0 ? .reverse : .noOverlap) }
        return .accepted(addedPixels: best.shift)
    }

    private static func score(_ a: ScrollingCapturePixels, _ b: ScrollingCapturePixels,
                              direction: ScrollingCaptureDirection, bands: ScrollingCaptureBands,
                              shift: Int, majorSamples: Int, minorSamples: Int) -> Double {
        let length = a.length(direction), breadth = a.breadth(direction)
        let overlap = length - bands.leading - bands.trailing - abs(shift)
        var total = 0, count = 0
        // Ignore at most three edge pixels, where scrollbar borders commonly appear.
        for offset in stride(from: 0, to: overlap, by: max(1, overlap / majorSamples)) {
            let ai = bands.leading + offset + max(shift, 0)
            let bi = bands.leading + offset + max(-shift, 0)
            for minor in stride(from: 3, to: breadth - 3, by: max(1, (breadth - 6) / minorSamples)) {
                let ap = a.index(major: ai, minor: minor, direction: direction)
                let bp = b.index(major: bi, minor: minor, direction: direction)
                for c in 0..<3 { total += abs(Int(a.bytes[ap + c]) - Int(b.bytes[bp + c])); count += 1 }
            }
        }
        return count == 0 ? .infinity : Double(total) / Double(count)
    }
}

/// Full source frames provide lossless seam edits and repeated undo. The budget includes those frames,
/// a pending frame, conversion scratch space, and the final output; previews never assemble a full image.
struct ScrollingCaptureStitcher: Sendable {
    struct Segment: Sendable { let frame: ScrollingCapturePixels; var addedPixels: Int }
    let direction: ScrollingCaptureDirection
    private(set) var bands: ScrollingCaptureBands
    private(set) var segments: [Segment]
    private(set) var pending: ScrollingCapturePixels?
    let memoryBudget: Int
    let maximumPixels: Int
    let maximumDimension: Int

    init(first: ScrollingCapturePixels, direction: ScrollingCaptureDirection,
         bands: ScrollingCaptureBands = .init(), memoryBudget: Int = 384 * 1024 * 1024,
         maximumPixels: Int = 40_000_000, maximumDimension: Int = 32_768) throws {
        guard first.width >= 96, first.height >= 96, first.width * first.height <= 12_000_000,
              bands.valid(for: first.length(direction)) else { throw ScrollingCaptureIssue.invalidFrame }
        self.direction = direction; self.bands = bands; self.memoryBudget = memoryBudget
        self.maximumPixels = maximumPixels; self.maximumDimension = maximumDimension
        segments = [Segment(frame: first, addedPixels: 0)]
        try checkBudget(additionalFrames: 0, additionalPixels: 0)
    }

    var outputLength: Int { segments[0].frame.length(direction) + segments.reduce(0) { $0 + $1.addedPixels } }
    var outputSize: CGSize {
        let breadth = segments[0].frame.breadth(direction)
        return direction == .vertical ? CGSize(width: breadth, height: outputLength) : CGSize(width: outputLength, height: breadth)
    }
    var maximumAddedPixels: Int {
        let body = segments[0].frame.length(direction) - bands.leading - bands.trailing
        return body - max(24, body / 4)
    }

    mutating func setBands(_ value: ScrollingCaptureBands) throws {
        guard segments.count == 1, value.valid(for: segments[0].frame.length(direction)) else {
            throw ScrollingCaptureIssue.invalidSeam
        }
        bands = value; pending = nil
    }

    mutating func append(_ frame: ScrollingCapturePixels) throws -> ScrollingCaptureMatch {
        pending = nil
        guard frame.width == segments[0].frame.width, frame.height == segments[0].frame.height else {
            return .rejected(.dimensionsChanged)
        }
        let result = try ScrollingCaptureMatcher.match(segments.last!.frame, frame, direction: direction, bands: bands)
        switch result {
        case .accepted(let shift):
            try checkBudget(additionalFrames: 1, additionalPixels: shift)
            segments.append(Segment(frame: frame, addedPixels: shift))
        case .rejected(let issue):
            if issue != .dimensionsChanged { pending = frame }
        case .duplicate: break
        }
        return result
    }

    mutating func applyManualSeam(addedPixels: Int) throws {
        guard addedPixels > 0, addedPixels <= maximumAddedPixels else { throw ScrollingCaptureIssue.invalidSeam }
        if let pending {
            try checkBudget(additionalFrames: 1, additionalPixels: addedPixels)
            segments.append(Segment(frame: pending, addedPixels: addedPixels)); self.pending = nil
        } else {
            guard segments.count > 1 else { throw ScrollingCaptureIssue.invalidSeam }
            try checkBudget(additionalFrames: 0, additionalPixels: addedPixels - segments.last!.addedPixels)
            segments[segments.count - 1].addedPixels = addedPixels
        }
    }

    mutating func discardLast() {
        pending = nil
        if segments.count > 1 { segments.removeLast() }
    }

    private func checkBudget(additionalFrames: Int, additionalPixels: Int) throws {
        let first = segments[0].frame
        let length = outputLength + additionalPixels, breadth = first.breadth(direction)
        // Four scratch frame equivalents cover decoding, WindowServer's image, and CGImage conversion.
        let retainedBytes = (segments.count + additionalFrames + 4) * first.bytes.count
        let outputBytes = length * breadth * 4
        guard length <= maximumDimension, breadth <= maximumDimension, length * breadth <= maximumPixels,
              retainedBytes + outputBytes * 2 <= memoryBudget else { throw ScrollingCaptureIssue.resourceLimit }
    }

    func render(maximumPreviewSide: Int? = nil) throws -> CGImage {
        let original = outputSize
        let scale: CGFloat
        if let maximumPreviewSide {
            scale = min(1, CGFloat(max(1, maximumPreviewSide)) / max(original.width, original.height))
        } else { scale = 1 }
        let width = max(1, Int((original.width * scale).rounded(.up)))
        let height = max(1, Int((original.height * scale).rounded(.up)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ScrollingCaptureIssue.resourceLimit
        }
        context.scaleBy(x: CGFloat(width) / original.width, y: CGFloat(height) / original.height)
        context.interpolationQuality = maximumPreviewSide == nil ? .none : .medium
        let frameLength = segments[0].frame.length(direction)
        let breadth = segments[0].frame.breadth(direction)
        var destination = 0
        func draw(frame: ScrollingCapturePixels, start: Int, length: Int) throws {
            guard length > 0 else { return }
            let cropRect = direction == .vertical
                ? CGRect(x: 0, y: start, width: breadth, height: length)
                : CGRect(x: start, y: 0, width: length, height: breadth)
            guard let crop = try frame.image().cropping(to: cropRect) else { throw ScrollingCaptureIssue.invalidFrame }
            let rect = direction == .vertical
                ? CGRect(x: 0, y: outputLength - destination - length, width: breadth, height: length)
                : CGRect(x: destination, y: 0, width: length, height: breadth)
            context.draw(crop, in: rect)
            destination += length
        }
        try draw(frame: segments[0].frame, start: 0, length: frameLength - bands.trailing)
        for segment in segments.dropFirst() {
            try Task.checkCancellation()
            try draw(frame: segment.frame, start: frameLength - bands.trailing - segment.addedPixels, length: segment.addedPixels)
        }
        try draw(frame: segments.last!.frame, start: frameLength - bands.trailing, length: bands.trailing)
        guard let image = context.makeImage() else { throw ScrollingCaptureIssue.resourceLimit }
        return image
    }
}

struct ScrollingCaptureProgress: Sendable {
    let preview: ScrollingCaptureImage
    let pendingPreview: ScrollingCaptureImage?
    let size: CGSize
    let segmentCount: Int
    let lastAddedPixels: Int
    let maximumAddedPixels: Int
}

actor ScrollingCaptureWorker {
    private var stitcher: ScrollingCaptureStitcher?

    func begin(image: ScrollingCaptureImage, direction: ScrollingCaptureDirection) throws -> ScrollingCaptureProgress {
        stitcher = nil
        stitcher = try ScrollingCaptureStitcher(first: ScrollingCapturePixels(image: image.image), direction: direction)
        return try progress()
    }
    func append(image: ScrollingCaptureImage) throws -> (ScrollingCaptureMatch, ScrollingCaptureProgress?) {
        guard stitcher != nil else { throw CancellationError() }
        let result = try stitcher!.append(ScrollingCapturePixels(image: image.image))
        return (result, result == .duplicate ? nil : try progress())
    }
    func setBands(_ bands: ScrollingCaptureBands) throws -> ScrollingCaptureProgress {
        guard stitcher != nil else { throw CancellationError() }
        try stitcher!.setBands(bands); return try progress()
    }
    func adjust(addedPixels: Int) throws -> ScrollingCaptureProgress {
        guard stitcher != nil else { throw CancellationError() }
        try stitcher!.applyManualSeam(addedPixels: addedPixels); return try progress()
    }
    func discardLast() throws -> ScrollingCaptureProgress {
        guard stitcher != nil else { throw CancellationError() }
        stitcher!.discardLast(); return try progress()
    }
    func finish() throws -> ScrollingCaptureImage {
        guard let stitcher else { throw CancellationError() }
        return ScrollingCaptureImage(image: try stitcher.render())
    }
    func clear() { stitcher = nil }
    private func progress() throws -> ScrollingCaptureProgress {
        guard let stitcher else { throw CancellationError() }
        let pendingPreview = try stitcher.pending.map { frame -> ScrollingCaptureImage in
            let temporary = try ScrollingCaptureStitcher(first: frame, direction: stitcher.direction)
            return ScrollingCaptureImage(image: try temporary.render(maximumPreviewSide: 360))
        }
        return ScrollingCaptureProgress(preview: ScrollingCaptureImage(image: try stitcher.render(maximumPreviewSide: 900)),
            pendingPreview: pendingPreview, size: stitcher.outputSize, segmentCount: stitcher.segments.count,
            lastAddedPixels: stitcher.segments.last!.addedPixels, maximumAddedPixels: stitcher.maximumAddedPixels)
    }
}
