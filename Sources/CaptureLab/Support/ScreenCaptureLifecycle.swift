import Darwin
import Foundation

enum ScreenCaptureLifecycleError: LocalizedError {
    case terminating
    case invalidWorkspaceName

    var errorDescription: String? {
        switch self {
        case .terminating:
            return "CaptureLab is terminating and cannot start another screenshot."
        case .invalidWorkspaceName:
            return "The screenshot workspace name is invalid."
        }
    }
}

final class ScreenCaptureProcessRegistry: @unchecked Sendable {
    typealias SignalOperation = @Sendable (pid_t, Int32) -> Int32

    static let shared = ScreenCaptureProcessRegistry()

    private let condition = NSCondition()
    private let signalOperation: SignalOperation
    private var processes: [ObjectIdentifier: Process] = [:]
    private var pendingLaunchCount = 0
    private var isTerminating = false

    init(signalOperation: @escaping SignalOperation = { Darwin.kill($0, $1) }) {
        self.signalOperation = signalOperation
    }

    func beginLaunch() throws {
        condition.lock()
        defer { condition.unlock() }
        guard !isTerminating else {
            throw ScreenCaptureLifecycleError.terminating
        }
        pendingLaunchCount += 1
    }

    func launchFailed() {
        condition.lock()
        pendingLaunchCount = max(0, pendingLaunchCount - 1)
        condition.broadcast()
        condition.unlock()
    }

    /// Returns false when shutdown won the race with `Process.run()`. The
    /// caller must then terminate this just-launched child itself.
    func registerLaunchedProcess(_ process: Process) -> Bool {
        condition.lock()
        pendingLaunchCount = max(0, pendingLaunchCount - 1)
        let accepted = !isTerminating
        // Track even a launch that lost the shutdown race. Its caller will
        // terminate it immediately, while shutdown can still wait for it.
        processes[ObjectIdentifier(process)] = process
        condition.broadcast()
        condition.unlock()
        return accepted
    }

    func unregister(_ process: Process) {
        condition.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        condition.broadcast()
        condition.unlock()
    }

    func terminateRejectedLaunch(
        _ process: Process,
        gracePeriod: TimeInterval = 0.2,
        killWait: TimeInterval = 0.5
    ) {
        signal([process], signal: SIGTERM)
        guard !waitForProcessesToStop([process], timeout: gracePeriod) else {
            return
        }
        signal([process], signal: SIGKILL)
        _ = waitForProcessesToStop([process], timeout: killWait)
    }

    func terminateAll(
        gracePeriod: TimeInterval = 0.75,
        killWait: TimeInterval = 0.5
    ) {
        condition.lock()
        isTerminating = true
        let initialProcesses = Array(processes.values)
        condition.broadcast()
        condition.unlock()

        signal(initialProcesses, signal: SIGTERM)
        guard !waitForRegistryToStop(timeout: gracePeriod) else {
            return
        }

        let remaining = runningProcessesSnapshot()
        signal(remaining, signal: SIGKILL)
        _ = waitForRegistryToStop(timeout: killWait)
    }

    var registeredProcessCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return processes.count
    }

    private func runningProcessesSnapshot() -> [Process] {
        condition.lock()
        let snapshot = processes.values.filter(\.isRunning)
        condition.unlock()
        return Array(snapshot)
    }

    private func signal(_ processes: [Process], signal: Int32) {
        for process in processes where process.isRunning {
            _ = signalOperation(process.processIdentifier, signal)
        }
    }

    private func waitForRegistryToStop(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            condition.lock()
            let pending = pendingLaunchCount
            let snapshot = Array(processes.values)
            condition.unlock()
            if pending == 0, snapshot.allSatisfy({ !$0.isRunning }) {
                return true
            }
            if Date() >= deadline {
                return false
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while true
    }

    private func waitForProcessesToStop(_ processes: [Process], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            if processes.allSatisfy({ !$0.isRunning }) {
                return true
            }
            if Date() >= deadline {
                return false
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while true
    }
}

final class ScreenCaptureWorkspace: @unchecked Sendable {
    static let workspacePrefix = "workspace-"
    static let liveLockFileName = ".live.lock"

    let rootDirectory: URL
    let workspaceDirectory: URL
    private let workspaceName: String

    private enum State {
        case idle
        case prepared
        case closed
    }

    private let fileManager: FileManager
    private let stateLock = NSLock()
    private var state: State = .idle
    private var liveLockDescriptor: Int32?

    init(
        rootDirectory: URL,
        workspaceName: String = "workspace-\(getpid())-\(UUID().uuidString)",
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.workspaceName = workspaceName
        self.workspaceDirectory = rootDirectory.standardizedFileURL
            .appendingPathComponent(workspaceName, isDirectory: true)
        self.fileManager = fileManager
    }

    deinit {
        cleanup()
    }

    func prepare() throws -> URL {
        stateLock.lock()
        defer { stateLock.unlock() }

        switch state {
        case .prepared:
            return workspaceDirectory
        case .closed:
            throw ScreenCaptureLifecycleError.terminating
        case .idle:
            break
        }

        guard workspaceName.hasPrefix(Self.workspacePrefix),
              !workspaceName.contains("/"),
              workspaceName == workspaceDirectory.lastPathComponent,
              workspaceDirectory.deletingLastPathComponent().path == rootDirectory.path else {
            throw ScreenCaptureLifecycleError.invalidWorkspaceName
        }

        do {
            try withCoordinationLock {
                guard !fileManager.fileExists(atPath: workspaceDirectory.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try fileManager.createDirectory(
                    at: workspaceDirectory,
                    withIntermediateDirectories: false
                )
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: workspaceDirectory.path
                )

                let descriptor = try openLockFile(
                    workspaceDirectory.appendingPathComponent(Self.liveLockFileName),
                    create: true
                )
                do {
                    guard try acquireLock(descriptor, command: F_SETLK, waits: false) else {
                        throw Self.posixError(code: EAGAIN, operation: "lock screenshot workspace")
                    }
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
                liveLockDescriptor = descriptor
                reclaimStaleWorkspaces()
            }
            state = .prepared
            return workspaceDirectory
        } catch {
            if let descriptor = liveLockDescriptor {
                Darwin.close(descriptor)
                liveLockDescriptor = nil
            }
            try? fileManager.removeItem(at: workspaceDirectory)
            throw error
        }
    }

    func cleanup() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if case .closed = state { return }
        state = .closed

        guard let descriptor = liveLockDescriptor else { return }
        liveLockDescriptor = nil
        defer { Darwin.close(descriptor) }

        // If coordination itself fails, leave a locked-looking stale directory
        // behind. A later launch will safely reclaim it after this descriptor
        // closes; deleting without coordination could race another instance.
        try? withCoordinationLock {
            if fileManager.fileExists(atPath: workspaceDirectory.path) {
                try fileManager.removeItem(at: workspaceDirectory)
            }
        }
    }

    private func withCoordinationLock<T>(_ operation: () throws -> T) throws -> T {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootDirectory.path
        )
        let descriptor = try openLockFile(
            rootDirectory.appendingPathComponent(".workspace-coordination.lock"),
            create: true
        )
        defer { Darwin.close(descriptor) }

        _ = try acquireLock(descriptor, command: F_SETLKW, waits: true)
        defer { unlock(descriptor) }
        return try operation()
    }

    private func reclaimStaleWorkspaces() {
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for candidate in candidates where candidate.standardizedFileURL.path != workspaceDirectory.path {
            guard candidate.lastPathComponent.hasPrefix(Self.workspacePrefix),
                  Self.isDirectoryWithoutFollowingSymlinks(candidate) else {
                continue
            }

            let lockURL = candidate.appendingPathComponent(Self.liveLockFileName)
            let descriptor: Int32
            do {
                descriptor = try openLockFile(lockURL, create: false)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
                try? fileManager.removeItem(at: candidate)
                continue
            } catch {
                continue
            }

            guard (try? acquireLock(descriptor, command: F_SETLK, waits: false)) == true else {
                Darwin.close(descriptor)
                continue
            }
            try? fileManager.removeItem(at: candidate)
            unlock(descriptor)
            Darwin.close(descriptor)
        }
    }

    private func openLockFile(_ url: URL, create: Bool) throws -> Int32 {
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | (create ? O_CREAT : 0)
        let descriptor = url.path.withCString { Darwin.open($0, flags, mode_t(0o600)) }
        guard descriptor >= 0 else {
            throw Self.posixError(code: errno, operation: "open screenshot workspace lock")
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw Self.posixError(code: code, operation: "secure screenshot workspace lock")
        }
        return descriptor
    }

    private func acquireLock(_ descriptor: Int32, command: Int32, waits: Bool) throws -> Bool {
        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        while Darwin.fcntl(descriptor, command, &lock) != 0 {
            let code = errno
            if code == EINTR {
                continue
            }
            if !waits, code == EACCES || code == EAGAIN {
                return false
            }
            throw Self.posixError(code: code, operation: "lock screenshot workspace")
        }
        return true
    }

    private func unlock(_ descriptor: Int32) {
        var lock = Darwin.flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
    }

    private static func isDirectoryWithoutFollowingSymlinks(_ url: URL) -> Bool {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
            return false
        }
        return status.st_mode & S_IFMT == S_IFDIR
    }

    private static func posixError(code: Int32, operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "Could not \(operation): \(String(cString: strerror(code)))"
            ]
        )
    }
}

final class ScreenCaptureLifecycle: @unchecked Sendable {
    static let shared = ScreenCaptureLifecycle()

    let processRegistry: ScreenCaptureProcessRegistry
    private let workspace: ScreenCaptureWorkspace
    private let terminationGracePeriod: TimeInterval
    private let terminationKillWait: TimeInterval

    init(
        workspace: ScreenCaptureWorkspace = ScreenCaptureWorkspace(
            rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("CaptureLab", isDirectory: true)
                .appendingPathComponent("CaptureWorkspaces", isDirectory: true)
        ),
        processRegistry: ScreenCaptureProcessRegistry = .shared,
        terminationGracePeriod: TimeInterval = 0.75,
        terminationKillWait: TimeInterval = 0.5
    ) {
        self.workspace = workspace
        self.processRegistry = processRegistry
        self.terminationGracePeriod = terminationGracePeriod
        self.terminationKillWait = terminationKillWait
    }

    func prepareForLaunch() throws {
        _ = try workspace.prepare()
    }

    func captureDirectory() throws -> URL {
        try workspace.prepare()
    }

    func shutdown() {
        processRegistry.terminateAll(
            gracePeriod: terminationGracePeriod,
            killWait: terminationKillWait
        )
        workspace.cleanup()
    }
}
