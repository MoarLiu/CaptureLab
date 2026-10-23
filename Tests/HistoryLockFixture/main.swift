import Darwin
import Foundation

guard CommandLine.arguments.count == 3 else { exit(64) }
let descriptor = CommandLine.arguments[1].withCString {
    Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
}
guard descriptor >= 0 else { exit(74) }
var lock = Darwin.flock()
lock.l_type = Int16(F_WRLCK)
lock.l_whence = Int16(SEEK_SET)
guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else { exit(75) }
if CommandLine.arguments[2] != "--probe" {
    try Data().write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    // The parent controls release, so tests never rely on a fixed sleep racing
    // compilation, disk I/O or CI scheduling.
    var byte: UInt8 = 0
    _ = Darwin.read(STDIN_FILENO, &byte, 1)
}
Darwin.close(descriptor)
