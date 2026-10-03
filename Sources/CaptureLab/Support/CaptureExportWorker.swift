import CoreGraphics
import Foundation

/// Serial encoding keeps rapid control changes from allocating multiple full
/// export bitmaps at once. Cancelled requests never publish stale byte counts.
actor CaptureExportWorker {
    static let shared = CaptureExportWorker()
    func encode(_ image: CaptureExportImage, settings: CaptureExportSettings) throws -> Data {
        try Task.checkCancellation()
        let result = try settings.encode(image.image)
        try Task.checkCancellation()
        return result
    }
    func render(_ image: CaptureExportImage, presentation: CapturePresentation) throws -> CaptureExportImage {
        try Task.checkCancellation()
        // Preserve the actionable missing-background error for the layout sheet.
        try presentation.validate()
        let sourceSize = CGSize(width: image.image.width, height: image.image.height)
        guard let outputSize = presentation.outputSize(for: sourceSize) else { throw CapturePresentationError.invalidLayout }
        let scale = min(1, 900 / max(outputSize.width, outputSize.height))
        var draft = presentation
        var source = image.image
        if scale < 1 {
            let size = CGSize(width: max(1, (sourceSize.width * scale).rounded()), height: max(1, (sourceSize.height * scale).rounded()))
            guard let context = CapturePresentation.context(size: size) else { throw CapturePresentationError.encodingFailed }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(origin: .zero, size: size))
            guard let reduced = context.makeImage() else { throw CapturePresentationError.encodingFailed }
            source = reduced
            draft.padding *= scale; draft.cornerRadius *= scale
            draft.shadowBlur *= scale; draft.shadowOffset *= scale
        }
        guard let output = draft.render(source) else { throw CapturePresentationError.encodingFailed }
        try Task.checkCancellation()
        return CaptureExportImage(image: output)
    }
}
