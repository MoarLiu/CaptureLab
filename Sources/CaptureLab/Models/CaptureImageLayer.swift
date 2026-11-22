import AppKit
import ImageIO

/// An immutable encoded resource with an independently editable placement.
/// Coordinates use the same top-left source space as annotations. Positive
/// rotation is clockwise; the pivot is the image's center in source pixels.
struct CaptureImageLayer: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    let pngData: Data
    var normalizedRect: CGRect
    var rotationDegrees: Double = 0
    var zIndex: Int = 0

    var isValid: Bool {
        hasValidPlacement && pixelSize != nil
    }

    var hasValidPlacement: Bool {
        let r = normalizedRect
        return !name.isEmpty && name.utf8.count <= 1_024 &&
            [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite) &&
            r.width > 0 && r.height > 0 && r.minX >= 0 && r.minY >= 0 &&
            r.maxX <= 1.000001 && r.maxY <= 1.000001 && rotationDegrees.isFinite &&
            abs(rotationDegrees) <= 360_000
    }

    /// Reads dimensions without decoding the bitmap, including when validating
    /// untrusted project files before allocating any layered composition.
    /// Repeated reads reuse the first result; `pngData` is immutable.
    var pixelSize: CGSize? {
        CaptureLayerBitmapCache.shared.pixelSize(id: id, data: pngData)
    }

    func corners(in sourceSize: CGSize) -> [CGPoint] {
        let r = CGRect(x: normalizedRect.minX * sourceSize.width, y: normalizedRect.minY * sourceSize.height,
                       width: normalizedRect.width * sourceSize.width, height: normalizedRect.height * sourceSize.height)
        let angle = rotationDegrees * .pi / 180
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map { p in
            let dx = p.x - r.midX, dy = p.y - r.midY
            return CGPoint(x: r.midX + dx * cos(angle) - dy * sin(angle),
                           y: r.midY + dx * sin(angle) + dy * cos(angle))
        }
    }

    func contains(_ normalizedPoint: CGPoint, sourceSize: CGSize) -> Bool {
        let center = CGPoint(x: normalizedRect.midX * sourceSize.width, y: normalizedRect.midY * sourceSize.height)
        let dx = normalizedPoint.x * sourceSize.width - center.x
        let dy = normalizedPoint.y * sourceSize.height - center.y
        let angle = -rotationDegrees * .pi / 180
        return abs(dx * cos(angle) - dy * sin(angle)) <= normalizedRect.width * sourceSize.width / 2 &&
            abs(dx * sin(angle) + dy * cos(angle)) <= normalizedRect.height * sourceSize.height / 2
    }
}

enum CaptureObjectID: Hashable {
    case image(UUID)
    case annotation(UUID)
}

enum CaptureLayerError: LocalizedError {
    case resourceBudget
    case invalidImage
    var errorDescription: String? {
        switch self {
        case .resourceBudget:
            return L10n.text(en: "This canvas supports up to 32 added images, 128 MB of image data and 100 million added image pixels. Reduce the number or size of the images.",
                             zh: "每个画布最多添加 32 张图片，图片数据合计不超过 128 MB、总像素不超过 1 亿。请减少图片数量或尺寸。")
        case .invalidImage:
            return L10n.text(en: "One of the images could not be loaded. The current canvas has been preserved.",
                             zh: "其中一张图片无法载入，当前画布已保留。")
        }
    }
}

enum CaptureLayerImport {
    static let maximumCount = 32
    static let maximumBytes = 128 * 1_024 * 1_024
    static let maximumPixels: CGFloat = 100_000_000

    static func validate(_ layers: [CaptureImageLayer]) throws {
        try validateBudget(layers)
        // A PNG header can expose valid dimensions even when its pixels are
        // missing. Decode each resource once and reuse that bitmap for composition.
        for layer in layers where CaptureLayerBitmapCache.shared.image(id: layer.id, data: layer.pngData) == nil {
            throw CaptureLayerError.invalidImage
        }
    }

    static func validateBudget(_ layers: [CaptureImageLayer]) throws {
        guard layers.count <= maximumCount else { throw CaptureLayerError.resourceBudget }
        guard Set(layers.map(\.id)).count == layers.count else { throw CaptureLayerError.invalidImage }
        var bytes = 0
        var pixels: CGFloat = 0
        for layer in layers {
            guard layer.isValid, let size = layer.pixelSize else { throw CaptureLayerError.invalidImage }
            bytes += layer.pngData.count
            pixels += size.width * size.height
            guard bytes <= maximumBytes, pixels <= maximumPixels else { throw CaptureLayerError.resourceBudget }
        }
    }

    @MainActor
    static func layers(from urls: [URL], canvasSize: CGSize, existing: [CaptureImageLayer],
                       visibleNormalizedRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> [CaptureImageLayer] {
        guard !urls.isEmpty else { throw CaptureLayerError.invalidImage }
        guard urls.count + existing.count <= maximumCount else { throw CaptureLayerError.resourceBudget }
        var result = existing
        for url in urls {
            let data: Data
            do {
                guard url.isFileURL, let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      bytes <= maximumBytes else { throw CaptureLayerError.invalidImage }
                let input = try Data(contentsOf: url, options: .mappedIfSafe)
                try preflight(input, existing: result)
                data = try CaptureImageImport.pngData(from: input)
            } catch let error as CaptureLayerError { throw error }
            catch { throw CaptureLayerError.invalidImage }
            result.append(try layer(data: data, name: url.lastPathComponent, canvasSize: canvasSize,
                                    existing: result, visibleNormalizedRect: visibleNormalizedRect))
        }
        return Array(result.dropFirst(existing.count))
    }

    @MainActor
    static func layers(from pasteboard: NSPasteboard, canvasSize: CGSize, existing: [CaptureImageLayer],
                       visibleNormalizedRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> [CaptureImageLayer] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return try layers(from: urls, canvasSize: canvasSize, existing: existing, visibleNormalizedRect: visibleNormalizedRect)
        }
        var result = existing
        for item in pasteboard.pasteboardItems ?? [] {
            guard let input = item.data(forType: .png) ?? item.data(forType: .tiff) else { continue }
            let data: Data
            do { try preflight(input, existing: result); data = try CaptureImageImport.pngData(from: input) }
            catch let error as CaptureLayerError { throw error }
            catch { throw CaptureLayerError.invalidImage }
            result.append(try layer(data: data, name: L10n.text(en: "Pasted image", zh: "粘贴的图片"),
                                    canvasSize: canvasSize, existing: result, visibleNormalizedRect: visibleNormalizedRect))
        }
        guard result.count > existing.count else { throw CaptureLayerError.invalidImage }
        return Array(result.dropFirst(existing.count))
    }

    static func preflight(_ data: Data, existing: [CaptureImageLayer]) throws {
        guard existing.count < maximumCount, data.count <= maximumBytes else { throw CaptureLayerError.resourceBudget }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = metadata[kCGImagePropertyPixelWidth] as? Int,
              let height = metadata[kCGImagePropertyPixelHeight] as? Int,
              CaptureDocumentGeometry.validSize(CGSize(width: width, height: height)) else { throw CaptureLayerError.invalidImage }
        let pixels = existing.compactMap(\.pixelSize).reduce(CGFloat(width) * CGFloat(height)) { $0 + $1.width * $1.height }
        guard pixels <= maximumPixels else { throw CaptureLayerError.resourceBudget }
    }

    static func layer(data: Data, name: String, canvasSize: CGSize, existing: [CaptureImageLayer],
                      visibleNormalizedRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> CaptureImageLayer {
        var layer = CaptureImageLayer(name: String(name.prefix(200)), pngData: data, normalizedRect: .zero,
                                      zIndex: min(existing.map(\.zIndex).max() ?? -1, Int.max - 1) + 1)
        guard let size = layer.pixelSize, CaptureDocumentGeometry.validSize(canvasSize) else { throw CaptureLayerError.invalidImage }
        let visible = visibleNormalizedRect.standardized.clampedToUnit()
        let scale = min(1, min(visible.width * canvasSize.width * 0.65 / size.width,
                               visible.height * canvasSize.height * 0.65 / size.height))
        let width = size.width * scale / canvasSize.width
        let height = size.height * scale / canvasSize.height
        let offset = CGFloat(existing.count % 5) * 0.025
        layer.normalizedRect = CGRect(x: min(visible.maxX - width, visible.midX - width / 2 + offset),
                                      y: min(visible.maxY - height, visible.midY - height / 2 + offset),
                                      width: width, height: height)
        // Budget-check the whole stack, but decode only the new resource.
        // Revalidating every previous bitmap made an N-image import decode O(N^2) times.
        try validateBudget(existing + [layer])
        guard CaptureLayerBitmapCache.shared.image(id: layer.id, data: layer.pngData) != nil else {
            throw CaptureLayerError.invalidImage
        }
        return layer
    }
}

/// Pixel size and decoded bitmaps for immutable layer resources. Size entries
/// stay small; bitmaps are cost-limited and shared by validation and composition.
final class CaptureLayerBitmapCache: @unchecked Sendable {
    static let shared = CaptureLayerBitmapCache()

    private struct ResourceKey: Hashable {
        var id: UUID
        var count: Int
        var head: UInt64
        var tail: UInt64
    }

    private final class ImageKey: NSObject {
        let key: ResourceKey
        init(_ key: ResourceKey) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? ImageKey)?.key == key }
    }

    private final class ImageBox: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private enum Measurement {
        case size(CGSize)
        case invalid
    }

    private let lock = NSLock()
    private var sizes: [ResourceKey: Measurement] = [:]
    private let images = NSCache<ImageKey, ImageBox>()

    init() {
        images.countLimit = 48
        images.totalCostLimit = 160 * 1_024 * 1_024
    }

    func pixelSize(id: UUID, data: Data) -> CGSize? {
        let key = Self.resourceKey(id: id, data: data)
        lock.lock()
        if let cached = sizes[key] {
            lock.unlock()
            switch cached {
            case .size(let size): return size
            case .invalid: return nil
            }
        }
        lock.unlock()
        let measured = Self.measure(data)
        lock.lock()
        if sizes[key] == nil {
            if sizes.count > 512 { sizes.removeAll(keepingCapacity: true) }
            sizes[key] = measured.map(Measurement.size) ?? .invalid
        }
        let resolved = sizes[key]
        lock.unlock()
        switch resolved {
        case .size(let size): return size
        case .invalid, nil: return measured
        }
    }

    func image(id: UUID, data: Data) -> CGImage? {
        let key = ImageKey(Self.resourceKey(id: id, data: data))
        if let cached = images.object(forKey: key)?.image { return cached }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        images.setObject(ImageBox(image), forKey: key, cost: max(1, image.width * image.height * 4))
        return image
    }

    private static func resourceKey(id: UUID, data: Data) -> ResourceKey {
        func word(at offset: Int) -> UInt64 {
            guard data.count >= offset + 8 else { return UInt64(data.count) }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
        }
        return ResourceKey(id: id, count: data.count, head: word(at: 0), tail: word(at: max(0, data.count - 8)))
    }

    private static func measure(_ data: Data) -> CGSize? {
        guard !data.isEmpty, data.count <= CaptureLayerImport.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = metadata[kCGImagePropertyPixelWidth] as? Int,
              let height = metadata[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let size = CGSize(width: width, height: height)
        return CaptureDocumentGeometry.validSize(size) ? size : nil
    }
}
