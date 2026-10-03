import AppKit
import ImageIO

struct CaptureRGBAColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .white
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var isValid: Bool { [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    static let white = Self(red: 1, green: 1, blue: 1)
    static let black = Self(red: 0, green: 0, blue: 0)
    static let blue = Self(red: 0.20, green: 0.36, blue: 0.88)
    static let purple = Self(red: 0.63, green: 0.27, blue: 0.83)
}

enum CaptureBackgroundKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case transparent, solid, gradient, builtIn, image
    var id: String { rawValue }
    var title: String {
        switch self {
        case .transparent: return L10n.text(en: "Transparent", zh: "透明")
        case .solid: return L10n.text(en: "Solid color", zh: "纯色")
        case .gradient: return L10n.text(en: "Gradient", zh: "渐变")
        case .builtIn: return L10n.text(en: "Built-in background", zh: "内置背景")
        case .image: return L10n.text(en: "Custom image", zh: "自定义图片")
        }
    }
}

enum CaptureBuiltInBackground: String, Codable, CaseIterable, Identifiable, Sendable {
    case aurora, sunset, ocean, graphite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .aurora: return L10n.text(en: "Aurora", zh: "极光")
        case .sunset: return L10n.text(en: "Sunset", zh: "日落")
        case .ocean: return L10n.text(en: "Ocean", zh: "海洋")
        case .graphite: return L10n.text(en: "Graphite", zh: "石墨")
        }
    }
    var colors: [CaptureRGBAColor] {
        switch self {
        case .aurora: return [.init(red: 0.09, green: 0.15, blue: 0.35), .init(red: 0.35, green: 0.21, blue: 0.68), .init(red: 0.18, green: 0.76, blue: 0.66)]
        case .sunset: return [.init(red: 0.32, green: 0.16, blue: 0.50), .init(red: 0.94, green: 0.39, blue: 0.43), .init(red: 1, green: 0.75, blue: 0.43)]
        case .ocean: return [.init(red: 0.05, green: 0.21, blue: 0.42), .init(red: 0.05, green: 0.53, blue: 0.72), .init(red: 0.36, green: 0.86, blue: 0.82)]
        case .graphite: return [.init(red: 0.09, green: 0.10, blue: 0.13), .init(red: 0.27, green: 0.29, blue: 0.34), .init(red: 0.48, green: 0.51, blue: 0.58)]
        }
    }
}

enum CapturePresentationAspect: String, Codable, CaseIterable, Identifiable, Sendable {
    case natural, square, fourThree, sixteenNine, nineSixteen, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .natural: return L10n.text(en: "Fit content", zh: "适应内容")
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16"
        case .custom: return L10n.text(en: "Custom ratio", zh: "自定义比例")
        }
    }
}

enum CapturePresentationAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeading, top, topTrailing, leading, center, trailing, bottomLeading, bottom, bottomTrailing
    var id: String { rawValue }
    var horizontal: Double {
        switch self {
        case .topLeading, .leading, .bottomLeading: return 0
        case .topTrailing, .trailing, .bottomTrailing: return 1
        default: return 0.5
        }
    }
    var vertical: Double {
        switch self {
        case .topLeading, .top, .topTrailing: return 0
        case .bottomLeading, .bottom, .bottomTrailing: return 1
        default: return 0.5
        }
    }
    var title: String {
        switch self {
        case .topLeading: return L10n.text(en: "Top left", zh: "左上")
        case .top: return L10n.text(en: "Top", zh: "上方")
        case .topTrailing: return L10n.text(en: "Top right", zh: "右上")
        case .leading: return L10n.text(en: "Left", zh: "左侧")
        case .center: return L10n.text(en: "Center", zh: "居中")
        case .trailing: return L10n.text(en: "Right", zh: "右侧")
        case .bottomLeading: return L10n.text(en: "Bottom left", zh: "左下")
        case .bottom: return L10n.text(en: "Bottom", zh: "下方")
        case .bottomTrailing: return L10n.text(en: "Bottom right", zh: "右下")
        }
    }
}

/// Presentation wraps the already composited and transformed document. All
/// coordinates are output pixels; contentRect uses the document's top-left origin.
/// The embedded image is independent of its original path and moves with projects.
struct CapturePresentation: Codable, Hashable, Sendable {
    var background: CaptureBackgroundKind = .transparent
    var color = CaptureRGBAColor.white
    var secondaryColor = CaptureRGBAColor.purple
    var gradientAngle: Double = 45
    var builtIn: CaptureBuiltInBackground = .aurora
    var customBackgroundData: Data?
    var customBackgroundName: String?
    var padding: Double = 0
    var cornerRadius: Double = 0
    var shadowOpacity: Double = 0
    var shadowBlur: Double = 24
    var shadowOffset: Double = 8
    var alignment: CapturePresentationAlignment = .center
    var aspect: CapturePresentationAspect = .natural
    var customAspectWidth: Double = 16
    var customAspectHeight: Double = 9

    var isIdentity: Bool { background == .transparent && padding == 0 && cornerRadius == 0 && shadowOpacity == 0 && aspect == .natural }
    var ratio: Double? {
        switch aspect {
        case .natural: return nil
        case .square: return 1
        case .fourThree: return 4 / 3
        case .sixteenNine: return 16 / 9
        case .nineSixteen: return 9 / 16
        case .custom: return customAspectWidth / customAspectHeight
        }
    }
    func validate() throws {
        guard color.isValid, secondaryColor.isValid,
              padding.isFinite, (0...4096).contains(padding),
              cornerRadius.isFinite, (0...4096).contains(cornerRadius),
              shadowOpacity.isFinite, (0...1).contains(shadowOpacity),
              shadowBlur.isFinite, (0...512).contains(shadowBlur),
              shadowOffset.isFinite, (-512...512).contains(shadowOffset),
              gradientAngle.isFinite, (-360...360).contains(gradientAngle),
              customAspectWidth.isFinite, (0.1...1000).contains(customAspectWidth),
              customAspectHeight.isFinite, (0.1...1000).contains(customAspectHeight)
        else { throw CapturePresentationError.invalidLayout }
        // Inactive resources still travel inside projects and personal presets.
        // Validate them too, before callers serialize or retain this value.
        if let data = customBackgroundData {
            guard data.count <= CaptureImageImport.maximumBytes,
                  Self.validImageSource(data) != nil else { throw CapturePresentationError.missingBackground }
        } else if background == .image {
            throw CapturePresentationError.missingBackground
        }
        if let name = customBackgroundName {
            guard !name.isEmpty, name.count <= 255, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\\"),
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw CapturePresentationError.invalidLayout }
        }
    }
    func outputSize(for inputSize: CGSize) -> CGSize? {
        guard (try? validate()) != nil, CaptureDocumentGeometry.validSize(inputSize) else { return nil }
        var size = CGSize(width: inputSize.width + padding * 2, height: inputSize.height + padding * 2)
        if let ratio {
            if size.width / size.height < ratio { size.width = size.height * ratio }
            else { size.height = size.width / ratio }
        }
        size = CGSize(width: ceil(size.width), height: ceil(size.height))
        return CaptureDocumentGeometry.validSize(size) ? size : nil
    }
    func contentRect(for inputSize: CGSize) -> CGRect? {
        guard let size = outputSize(for: inputSize) else { return nil }
        return CGRect(x: padding + (size.width - 2 * padding - inputSize.width) * alignment.horizontal,
                      y: padding + (size.height - 2 * padding - inputSize.height) * alignment.vertical,
                      width: inputSize.width, height: inputSize.height)
    }
    /// Equal minimum margins and centered content; a fixed aspect distributes
    /// remaining space equally without moving annotations within the content.
    mutating func balancePadding(for contentSize: CGSize) {
        padding = min(512, max(16, (min(contentSize.width, contentSize.height) * 0.08).rounded()))
        alignment = .center
    }
    func render(_ image: NSImage) -> NSImage? {
        guard let input = image.captureLabCGImage(), let output = render(input) else { return nil }
        let scale = image.size.width / max(CGFloat(input.width), 1)
        return NSImage(cgImage: output, size: CGSize(width: CGFloat(output.width) * scale, height: CGFloat(output.height) * scale))
    }
    func render(_ input: CGImage) -> CGImage? {
        let inputSize = CGSize(width: input.width, height: input.height)
        guard let size = outputSize(for: inputSize), let topRect = contentRect(for: inputSize) else { return nil }
        if isIdentity { return input }
        guard let context = Self.context(size: size) else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        switch background {
        case .transparent: break
        case .solid:
            context.setFillColor(color.cgColor); context.fill(bounds)
        case .gradient, .builtIn:
            let colors = background == .builtIn ? builtIn.colors : [color, secondaryColor]
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: nil) else { return nil }
            let angle = gradientAngle * .pi / 180
            let span = abs(cos(angle)) * size.width / 2 + abs(sin(angle)) * size.height / 2
            let delta = CGPoint(x: cos(angle) * span, y: sin(angle) * span)
            context.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX - delta.x, y: bounds.midY - delta.y), end: CGPoint(x: bounds.midX + delta.x, y: bounds.midY + delta.y), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .image:
            guard let data = customBackgroundData, let source = Self.validImageSource(data),
                  let backgroundImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
            let scale = max(size.width / CGFloat(backgroundImage.width), size.height / CGFloat(backgroundImage.height))
            let drawSize = CGSize(width: CGFloat(backgroundImage.width) * scale, height: CGFloat(backgroundImage.height) * scale)
            context.interpolationQuality = .high
            context.draw(backgroundImage, in: CGRect(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2, width: drawSize.width, height: drawSize.height))
        }
        let rect = CGRect(x: topRect.minX, y: size.height - topRect.maxY, width: topRect.width, height: topRect.height)
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if shadowOpacity > 0 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -shadowOffset), blur: shadowBlur,
                              color: CGColor(gray: 0, alpha: shadowOpacity))
            // A transparency layer casts the actual clipped content's silhouette,
            // preserving transparent PNG pixels instead of adding an opaque card.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.saveGState()
            context.addPath(path); context.clip()
            context.draw(input, in: rect)
            context.restoreGState()
            context.endTransparencyLayer()
            context.restoreGState()
        } else {
            context.saveGState(); context.addPath(path); context.clip()
            context.interpolationQuality = .high; context.draw(input, in: rect)
            context.restoreGState()
        }
        return context.makeImage()
    }
    static func validImageSource(_ data: Data) -> CGImageSource? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              CaptureDocumentGeometry.validSize(CGSize(width: width, height: height)),
              // A truncated header can report valid dimensions with no image.
              // Keep pixel caching deferred during frequent layout validation.
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else { return nil }
        return source
    }
    static func context(size: CGSize) -> CGContext? {
        guard CaptureDocumentGeometry.validSize(size) else { return nil }
        return CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

enum CapturePresentationError: LocalizedError {
    case invalidLayout, missingBackground, encodingFailed, invalidPresetName, presetLimit
    var errorDescription: String? {
        switch self {
        case .invalidLayout: return L10n.text(en: "Invalid layout or output dimensions. Maximum output is 32,768 pixels per side and 100 megapixels.", zh: "布局或输出尺寸无效。输出单边最多 32,768 像素，总计最多 1 亿像素。")
        case .missingBackground: return L10n.text(en: "The custom background is missing or damaged. Choose its image again before applying or exporting.", zh: "自定义背景缺失或损坏，请重新选择背景图片后再应用或导出。")
        case .encodingFailed: return L10n.text(en: "The image could not be rendered or encoded. Your edits have been kept.", zh: "图片无法渲染或编码，当前编辑内容已保留。")
        case .invalidPresetName: return L10n.text(en: "Enter a preset name with 1–80 characters.", zh: "请输入 1–80 字的预设名称。")
        case .presetLimit: return L10n.text(en: "Preset storage is full (50 presets or 128 MB). Delete unused presets and try again.", zh: "预设存储已满（最多 50 个或 128 MB），请删除不用的预设后重试。")
        }
    }
}
