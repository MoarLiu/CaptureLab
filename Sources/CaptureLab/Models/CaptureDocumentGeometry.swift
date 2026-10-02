import AppKit

/// Source pixels and annotations share a top-left coordinate system. Geometry
/// changes only this small value; undo snapshots retain the same source image.
struct CaptureDocumentGeometry: Codable, Equatable {
    var canvasSize: CGSize?
    var outputSize: CGSize?
    private var matrix: [CGFloat] = [1, 0, 0, 1, 0, 0]

    var transform: CGAffineTransform {
        CGAffineTransform(a: matrix[0], b: matrix[1], c: matrix[2], d: matrix[3], tx: matrix[4], ty: matrix[5])
    }

    mutating func append(_ operation: CGAffineTransform, size: CGSize) {
        let next = transform.concatenating(operation)
        matrix = [next.a, next.b, next.c, next.d, next.tx, next.ty]
        canvasSize = size
        outputSize = nil
    }

    func isValid(sourceSize: CGSize) -> Bool {
        guard matrix.count == 6, matrix.allSatisfy(\.isFinite),
              Self.validSize(sourceSize), Self.validSize(canvasSize ?? sourceSize),
              outputSize.map(Self.validSize) ?? true else { return false }
        // v1 permits pixel-aligned right-angle rotations/reflections/translations.
        // Reject singular, skewed and scaling matrices before rendering/input.
        let t = transform
        guard [t.a, t.b, t.c, t.d].allSatisfy({ [-1, 0, 1].contains($0) }),
              abs(t.a * t.d - t.b * t.c) == 1,
              abs(t.a) + abs(t.c) == 1, abs(t.b) + abs(t.d) == 1,
              t.tx.rounded() == t.tx, t.ty.rounded() == t.ty else { return false }
        let mapped = CGRect(origin: .zero, size: sourceSize).applying(t)
        let canvas = CGRect(origin: .zero, size: canvasSize ?? sourceSize)
        return mapped.contains(canvas)
    }

    static func validSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width >= 1 && size.height >= 1
            && size.width.rounded() == size.width && size.height.rounded() == size.height
            && size.width <= 32_768 && size.height <= 32_768
            && size.width * size.height <= CGFloat(CaptureImageImport.maximumPixels)
    }
}

extension CaptureDocument {
    enum Adjustment { case rotateClockwise, flipHorizontal, flipVertical }

    func adjusting(_ adjustment: Adjustment) -> CaptureDocument {
        var result = self
        let size = canvasSize
        let transform: CGAffineTransform
        var newSize = size
        switch adjustment {
        case .rotateClockwise:
            transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
            newSize = CGSize(width: size.height, height: size.width)
        case .flipHorizontal:
            transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)
        case .flipVertical:
            transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        }
        result.id = UUID()
        result.geometry.append(transform, size: newSize)
        if let output = geometry.outputSize {
            result.geometry.outputSize = adjustment == .rotateClockwise
                ? CGSize(width: output.height, height: output.width) : output
        }
        return result
    }

    func cropping(to selection: CGRect) -> CaptureDocument? {
        guard let rect = CaptureImageCrop.pixelRect(selection, pixelSize: canvasSize) else { return nil }
        var result = self
        result.id = UUID()
        result.geometry.append(CGAffineTransform(translationX: -rect.minX, y: -rect.minY), size: rect.size)
        if let output = geometry.outputSize {
            result.geometry.outputSize = CGSize(width: max(1, (rect.width * output.width / canvasSize.width).rounded()),
                                                height: max(1, (rect.height * output.height / canvasSize.height).rounded()))
        }
        return result
    }

    /// Transform only an already composited image, so failure can never reveal
    /// an unredacted source. Used by every ordinary export destination.
    func applyingGeometry(to rendered: NSImage) -> NSImage? {
        guard geometry != CaptureDocumentGeometry() else { return rendered }
        guard geometry.isValid(sourceSize: sourcePixelSize), let source = rendered.captureLabCGImage(),
              let context = CGContext(data: nil, width: Int(pixelSize.width), height: Int(pixelSize.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Crop the composited resource before filtering. Clipping the drawing
        // context alone lets interpolation sample private pixels outside the crop.
        let sourceCrop = CGRect(origin: .zero, size: canvasSize).applying(geometry.transform.inverted())
        guard let cropped = source.cropping(to: sourceCrop) else { return nil }
        context.interpolationQuality = .high
        // Convert Core Graphics' bottom-left pixels to the document's top-left.
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: pixelSize.width / canvasSize.width, y: -pixelSize.height / canvasSize.height)
        context.concatenate(geometry.transform)
        context.translateBy(x: sourceCrop.minX, y: sourceCrop.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(cropped, in: CGRect(origin: .zero, size: sourceCrop.size))
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: displaySize)
    }
}
