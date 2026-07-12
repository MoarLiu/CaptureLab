import Darwin
import Foundation

enum CaptureLabUpdateSwap {
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 3 else {
            writeError("usage: CaptureLabUpdateSwap <first-directory> <second-directory>")
            return EX_USAGE
        }

        let firstPath = URL(fileURLWithPath: arguments[1]).standardizedFileURL.path
        let secondPath = URL(fileURLWithPath: arguments[2]).standardizedFileURL.path
        guard firstPath != secondPath else {
            writeError("CaptureLabUpdateSwap requires two distinct directory paths.")
            return EX_USAGE
        }
        guard isRegularDirectory(at: firstPath) else {
            writeError("CaptureLabUpdateSwap expected a regular directory at: \(firstPath)")
            return EX_NOINPUT
        }
        guard isRegularDirectory(at: secondPath) else {
            writeError("CaptureLabUpdateSwap expected a regular directory at: \(secondPath)")
            return EX_NOINPUT
        }

        let result = firstPath.withCString { firstCString in
            secondPath.withCString { secondCString in
                renameatx_np(
                    AT_FDCWD,
                    firstCString,
                    AT_FDCWD,
                    secondCString,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            let failure = errno
            writeError(
                "CaptureLabUpdateSwap could not atomically exchange the directories: "
                    + String(cString: strerror(failure))
                    + " (errno \(failure))."
            )
            return EX_OSERR
        }
        return EX_OK
    }

    private static func isRegularDirectory(at path: String) -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0 else { return false }
        return status.st_mode & S_IFMT == S_IFDIR
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

exit(CaptureLabUpdateSwap.run(arguments: CommandLine.arguments))
