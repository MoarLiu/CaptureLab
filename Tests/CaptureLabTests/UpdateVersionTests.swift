import Foundation
import XCTest
@testable import CaptureLab

final class UpdateVersionTests: XCTestCase {
    func testSwiftAndInstallerUseTheSameReleaseOrdering() throws {
        let cases: [(String, String, Int)] = [
            ("0.5.0-rc.1", "0.5.0", -1),
            ("0.5.0", "0.5.0-rc.1", 1),
            ("1.0.0-alpha", "1.0.0-alpha.1", -1),
            ("1.0.0-alpha.1", "1.0.0-alpha.beta", -1),
            ("1.0.0-beta.2", "1.0.0-beta.11", -1),
            ("1.0.0-2", "1.0.0-beta", -1),
            ("1.0.0-BETA", "1.0.0-beta", -1),
            ("1.0.0-rc.1+build.9", "1.0.0-rc.1+build.10", 0),
            ("1.0.0+build-with-hyphen", "1.0.0", 0),
            ("1.0.0-rc.1+build.99", "1.0.0", -1),
            ("1.0.0-beta-test.2", "1.0.0-beta-test.11", -1),
            ("1.0", "1.0.0", 0),
            ("01.00.0", "1", 0),
            ("1.0.0-rc.001", "1.0.0-rc.1", 0),
            ("999999999999999999999999999999.0", "2.0", 1),
            ("1.0.0-999999999999999999999999999999", "1.0.0-2", 1)
        ]
        for (left, right, expected) in cases {
            let lhs = try XCTUnwrap(UpdateVersion(left))
            let rhs = try XCTUnwrap(UpdateVersion(right))
            XCTAssertEqual(lhs < rhs ? -1 : (lhs > rhs ? 1 : 0), expected, "\(left) vs \(right)")
            XCTAssertEqual(lhs == rhs, expected == 0)
            let result = try shell("capturelab_compare_versions \"$1\" \"$2\"", arguments: [left, right])
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertEqual(result.output, String(expected), "\(left) vs \(right)")
        }
    }

    func testMalformedVersionsAreRejectedByCheckerAndInstaller() throws {
        for value in ["", "1..0", "1.0.", "1.0-", "1.0-rc..1", "1.0+", "1.0+build..1", "1.0+build+2", "v1.0", "1.0\n", "1.0/evil", "1.0_rc"] {
            XCTAssertNil(UpdateVersion(value), value)
            let result = try shell("capturelab_version_is_valid \"$1\"", arguments: [value])
            XCTAssertNotEqual(result.status, 0, value)
            XCTAssertThrowsError(try UpdateInstallService.packageMetadata(from: URL(fileURLWithPath: "CaptureLab-\(value)-macos-arm64.dmg")))
        }
        XCTAssertEqual(
            try UpdateInstallService.packageMetadata(from: URL(fileURLWithPath: "CaptureLab-1.0.0-rc.1+build.2-macos-arm64.dmg")).version,
            "1.0.0-rc.1+build.2"
        )
    }

    private func shell(_ command: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "export LC_ALL=C\n" + UpdateInstallService.updateDecisionShellFunctions + "\n" + command, "version-test"] + arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
