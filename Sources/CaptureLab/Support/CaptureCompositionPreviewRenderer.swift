import AppKit
import ImageIO

/// Display-only rendering. Export/OCR/history continue to use exact pixels.
/// All AppKit work stays on MainActor; bitmap and decoded-resource budgets are
/// independent of compressed PNG size. No intermediate image is PNG encoded.
@MainActor
final class CaptureCompositionPreviewRenderer {
    static let maximumPixels: CGFloat = 4_194_304
    private let cacheByteLimit: Int
    private enum Key: Hashable { case layer(UUID), background }
    private struct Resource {
        let data: Data
        let size: CGSize
        var image: CGImage?
        var dimension = 0
        var lastUse: UInt64 = 0
        var bytes: Int { image.map { $0.bytesPerRow * $0.height } ?? 0 }
    }
    private var resources: [Key: Resource] = [:]
    private var baseCache: (source: NSImage, width: Int, height: Int, image: CGImage)?
    private var clock: UInt64 = 0
    private(set) var decodeCount = 0
    var cachedBytes: Int { resources.values.reduce(0) { $0 + $1.bytes } }

    init(cacheByteLimit: Int = 64 * 1_024 * 1_024) { self.cacheByteLimit = max(1, cacheByteLimit) }

    func removeAll() {
        resources.removeAll()
        baseCache = nil
    }

    func render(document: CaptureDocument, layers: [CaptureImageLayer], annotations: [CaptureAnnotation],
                maximumDimension: Int, includesPresentation: Bool = false) -> NSImage? {
        let original = document.sourcePixelSize
        let final = includesPresentation ? document.renderedPixelSize : document.pixelSize
        guard CaptureDocumentGeometry.validSize(original), document.geometry.isValid(sourceSize: original),
              maximumDimension > 0 else { return nil }
        let longest = max(original.width, original.height, final.width, final.height)
        let area = max(original.width * original.height, final.width * final.height)
        let scale = min(1, CGFloat(maximumDimension) / longest, sqrt(Self.maximumPixels / area))
        if scale < 1, annotations.contains(where: { $0.kind == .mosaic }) {
            removeAll()
            // Preserve effect-before-scaling and every preceding layer/effect.
            // A coarser preview-only block size could overstate export masking.
            return autoreleasepool {
                exactMosaicPreview(document: document, layers: layers, annotations: annotations,
                                   scale: scale, includesPresentation: includesPresentation)
            }
        }
        guard prepare(layers: layers) else { return nil }
        let width = max(1, Int((original.width * scale).rounded(.down)))
        let height = max(1, Int((original.height * scale).rounded(.down)))
        guard let base = baseImage(document.image, width: width, height: height) else { return nil }
        // Even 32 images can remain cached without allowing their decoded
        // bitmaps to exceed the budget. Placement changes never invalidate them.
        let resourceDimension = min(maximumDimension,
            max(1, Int(sqrt(Double(cacheByteLimit) / Double(max(1, layers.count + 1)) / 4))))
        guard let composed = CaptureLayerComposition.render(source: base, layers: layers, image: { layer in
            self.image(for: .layer(layer.id), maximumDimension: resourceDimension)
        }), let annotated = NSImage(cgImage: composed, size: document.image.size)
            .renderedCaptureLabPreviewAnnotations(annotations, originalPixelSize: original),
              let content = geometry(document: document, rendered: annotated, scale: scale) else { return nil }
        guard includesPresentation else { return content }
        var draft = document.presentation
        let contentPixels = content.captureLabPixelSize
        let layoutScale = min(contentPixels.width / document.pixelSize.width, contentPixels.height / document.pixelSize.height)
        draft.padding *= layoutScale
        draft.cornerRadius *= layoutScale
        draft.shadowBlur *= layoutScale
        draft.shadowOffset *= layoutScale
        var background: CGImage?
        if draft.background == .image {
            guard let data = draft.customBackgroundData,
                  prepare(key: .background, data: data, requiresPNG: false) != nil,
                  let decoded = image(for: .background, maximumDimension: resourceDimension) else { return nil }
            background = decoded
        } else { resources.removeValue(forKey: .background) }
        guard let input = content.captureLabCGImage(), let output = draft.render(input, backgroundImage: background) else { return nil }
        let logicalScale = document.image.size.width / original.width
        return NSImage(cgImage: output, size: CGSize(width: final.width * logicalScale, height: final.height * logicalScale))
    }

    private func exactMosaicPreview(document: CaptureDocument, layers: [CaptureImageLayer], annotations: [CaptureAnnotation],
                                    scale: CGFloat, includesPresentation: Bool) -> NSImage? {
        guard let composition = CaptureLayerComposition.render(source: document.image, layers: layers),
              let annotated = composition.renderedWithCaptureLabAnnotations(annotations),
              let transformed = document.applyingGeometry(to: annotated),
              let rendered = includesPresentation ? document.presentation.render(transformed) : transformed,
              let image = rendered.captureLabCGImage() else { return nil }
        let width = max(1, Int((CGFloat(image.width) * scale).rounded(.down)))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded(.down)))
        guard let context = context(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let reduced = context.makeImage() else { return nil }
        return NSImage(cgImage: reduced, size: rendered.size)
    }

    private func prepare(layers: [CaptureImageLayer]) -> Bool {
        guard layers.count <= CaptureLayerImport.maximumCount, Set(layers.map(\.id)).count == layers.count else { return false }
        let active = Set(layers.map { Key.layer($0.id) } + [.background])
        resources = resources.filter { active.contains($0.key) }
        var bytes = 0
        var pixels: CGFloat = 0
        for layer in layers {
            guard layer.hasValidPlacement,
                  let size = prepare(key: .layer(layer.id), data: layer.pngData, requiresPNG: true) else { return false }
            bytes += layer.pngData.count
            pixels += size.width * size.height
            guard bytes <= CaptureLayerImport.maximumBytes, pixels <= CaptureLayerImport.maximumPixels else { return false }
        }
        return true
    }

    private func prepare(key: Key, data: Data, requiresPNG: Bool) -> CGSize? {
        if let cached = resources[key], cached.data == data { return cached.size }
        resources.removeValue(forKey: key)
        guard !data.isEmpty, data.count <= CaptureLayerImport.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              !requiresPNG || CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let size = CGSize(width: width, height: height)
        guard CaptureDocumentGeometry.validSize(size) else { return nil }
        resources[key] = Resource(data: data, size: size)
        return size
    }

    private func image(for key: Key, maximumDimension: Int) -> CGImage? {
        guard var resource = resources[key] else { return nil }
        clock &+= 1
        resource.lastUse = clock
        if let image = resource.image, resource.dimension >= maximumDimension {
            resources[key] = resource
            return image
        }
        guard let source = CGImageSourceCreateWithData(resource.data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        decodeCount += 1
        // Drop the older size before considering the replacement's cost.
        resource.image = nil
        resources[key] = resource
        let cost = image.bytesPerRow * image.height
        while cachedBytes + cost > cacheByteLimit,
              let oldest = resources.filter({ $0.value.image != nil }).min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            resources[oldest]?.image = nil
        }
        if cost <= cacheByteLimit {
            resource.image = image
            resource.dimension = maximumDimension
            resources[key] = resource
        }
        return image
    }

    private func baseImage(_ source: NSImage, width: Int, height: Int) -> CGImage? {
        if let cache = baseCache, cache.source === source, cache.width == width, cache.height == height { return cache.image }
        baseCache = nil
        guard let image = source.captureLabCGImage() else { return nil }
        let output: CGImage
        if image.width == width, image.height == height { output = image }
        else {
            guard let context = context(width: width, height: height) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let reduced = context.makeImage() else { return nil }
            output = reduced
        }
        baseCache = (source, width, height, output)
        return output
    }

    private func geometry(document: CaptureDocument, rendered: NSImage, scale: CGFloat) -> NSImage? {
        guard document.geometry != CaptureDocumentGeometry() else { return rendered }
        guard let image = rendered.captureLabCGImage() else { return nil }
        let size = document.pixelSize
        let width = max(1, Int((size.width * scale).rounded(.down)))
        let height = max(1, Int((size.height * scale).rounded(.down)))
        guard let context = context(width: width, height: height) else { return nil }
        let sx = CGFloat(image.width) / document.sourcePixelSize.width
        let sy = CGFloat(image.height) / document.sourcePixelSize.height
        let crop = CGRect(origin: .zero, size: document.canvasSize).applying(document.geometry.transform.inverted())
            .applying(CGAffineTransform(scaleX: sx, y: sy)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let cropped = image.cropping(to: crop) else { return nil }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / document.canvasSize.width, y: -CGFloat(height) / document.canvasSize.height)
        context.concatenate(document.geometry.transform)
        context.translateBy(x: crop.minX / sx, y: crop.maxY / sy)
        context.scaleBy(x: 1 / sx, y: -1 / sy)
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: document.displaySize)
    }

    private func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
