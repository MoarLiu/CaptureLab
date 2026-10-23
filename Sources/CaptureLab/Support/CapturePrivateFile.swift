import Darwin
import Foundation

/// Private resources are created with their final permissions, including the
/// temporary inode used for an atomic replacement. Never change process umask.
enum CapturePrivateFile {
    static func ensureDirectory(_ url: URL, fileManager: FileManager = .default) throws {
        // Users may relocate application data through a directory symlink.
        // Resolve that routing first; file/lock opens still reject symlinks.
        let directory = url.resolvingSymlinksInPath()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let descriptor = directory.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, mode_t(0o700)) == 0 else { throw posixError() }
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".capturelab-\(UUID().uuidString).pending")
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        // A restrictive umask may remove owner bits; the new inode is still
        // private. Make its final permissions exactly 0600.
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else { throw posixError() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard temporary.path.withCString({ source in url.path.withCString { Darwin.rename(source, $0) } }) == 0 else {
            throw posixError()
        }
    }

    /// Only changes the opened regular inode, never a symlink's destination.
    static func secureExistingFile(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { throw posixError() }
        guard status.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else { throw posixError() }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
