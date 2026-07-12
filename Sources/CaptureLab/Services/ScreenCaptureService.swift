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
    struct ProcessResult: Equatable, Sendable {
        var terminationStatus: Int32
        var standardError: String
    }

    typealias ProcessRunner = (URL, [String]) throws -> ProcessResult

    private let executableURL: URL
    private let temporaryDirectory: URL?
    private let fileManager: FileManager
    private let processRunner: ProcessRunner

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/sbin/screencapture"),
        temporaryDirectory: URL? = nil,
        fileManager: FileManager = .default,
        processRunner: @escaping ProcessRunner = ScreenCaptureService.runProcess
    ) {
        self.executableURL = executableURL
        self.temporaryDirectory = temporaryDirectory
        self.fileManager = fileManager
        self.processRunner = processRunner
    }

    func captureFile(mode: CaptureMode) throws -> URL {
        let url = try temporaryCaptureURL()
        do {
            try runScreencapture(
                mode: mode,
                arguments: arguments(for: mode, outputURL: url),
                outputURL: url
            )
            return url
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
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
        let directory: URL
        if let temporaryDirectory {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            directory = temporaryDirectory
        } else {
            directory = try ScreenCaptureLifecycle.shared.captureDirectory()
        }
        return directory.appendingPathComponent("capture-\(UUID().uuidString).png")
    }

    private func runScreencapture(mode: CaptureMode, arguments: [String], outputURL url: URL) throws {
        let result: ProcessResult
        do {
            result = try processRunner(executableURL, arguments)
        } catch {
            throw CaptureLabError.captureFailed(error.localizedDescription)
        }

        let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.terminationStatus == 0 else {
            if result.terminationStatus == 1,
               mode.isInteractive,
               stderr.isEmpty,
               !fileManager.fileExists(atPath: url.path) {
                throw CaptureLabError.captureCancelled
            }
            let message = stderr.isEmpty
                ? "screencapture exited with status \(result.terminationStatus)."
                : stderr
            throw CaptureLabError.captureFailed(message)
        }

        guard fileManager.fileExists(atPath: url.path) else {
            if stderr.isEmpty {
                throw CaptureLabError.captureFailed(L10n.noCaptureFileCreated)
            }
            throw CaptureLabError.captureFailed(stderr)
        }

        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            throw CaptureLabError.captureFailed(L10n.noCaptureFileCreated)
        }
    }

    static func runProcess(executableURL: URL, arguments: [String]) throws -> ProcessResult {
        try runProcess(
            executableURL: executableURL,
            arguments: arguments,
            registry: ScreenCaptureLifecycle.shared.processRegistry
        )
    }

    static func runProcess(
        executableURL: URL,
        arguments: [String],
        registry: ScreenCaptureProcessRegistry
    ) throws -> ProcessResult {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardError = standardError
        process.standardOutput = FileHandle.nullDevice

        try registry.beginLaunch()
        do {
            try process.run()
        } catch {
            registry.launchFailed()
            throw error
        }

        let wasRegistered = registry.registerLaunchedProcess(process)
        if !wasRegistered {
            registry.terminateRejectedLaunch(process)
        }
        defer { registry.unregister(process) }

        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            terminationStatus: process.terminationStatus,
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}

private extension CaptureMode {
    var isInteractive: Bool {
        switch self {
        case .region, .window, .delayedRegion:
            return true
        case .fullScreen:
            return false
        }
    }
}
