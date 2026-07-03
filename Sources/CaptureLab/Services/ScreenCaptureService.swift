import Foundation

enum CaptureLabError: LocalizedError {
    case captureCancelled
    case captureFailed(String)
    case imageLoadFailed
    case imageExportFailed
    case ocrImageUnavailable

    var errorDescription: String? {
        switch self {
        case .captureCancelled:
            return L10n.captureCancelled
        case .captureFailed(let message):
            return message
        case .imageLoadFailed:
            return L10n.imageLoadFailed
        case .imageExportFailed:
            return L10n.imageExportFailed
        case .ocrImageUnavailable:
            return L10n.ocrImageUnavailable
        }
    }
}

struct ScreenCaptureService {
    func captureFile(mode: CaptureMode) throws -> URL {
        let url = try temporaryCaptureURL()
        try runScreencapture(arguments: arguments(for: mode, outputURL: url), outputURL: url)
        return url
    }

    func captureInteractiveRegionFile() throws -> URL {
        try captureFile(mode: .region)
    }

    func arguments(for mode: CaptureMode, outputURL url: URL) -> [String] {
        switch mode {
        case .region:
            return ["-i", "-x", url.path]
        case .fullScreen:
            return ["-x", url.path]
        case .window:
            return ["-i", "-w", "-x", url.path]
        case .delayedRegion(let seconds):
            return ["-T", "\(max(0, seconds))", "-i", "-x", url.path]
        }
    }

    private func temporaryCaptureURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureLab", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return directory.appendingPathComponent("capture-\(UUID().uuidString).png")
    }

    private func runScreencapture(arguments: [String], outputURL url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CaptureLabError.captureFailed(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            if process.terminationStatus == 0 {
                throw CaptureLabError.captureFailed(L10n.noCaptureFileCreated)
            }
            throw CaptureLabError.captureCancelled
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw CaptureLabError.captureCancelled
        }

    }
}
