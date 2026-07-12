import Foundation
import XCTest

final class PackagingGuidanceTests: XCTestCase {
    func testMissingLockedSigningKeyRequiresBackupRecovery() throws {
        let root = repositoryRoot
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingCaptureLabSigningKey-\(UUID().uuidString)", isDirectory: true)
        let missingKey = testRoot.appendingPathComponent("missing-private-key")
        let releaseDirectory = testRoot.appendingPathComponent("release", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        try FileManager.default.createDirectory(at: releaseDirectory, withIntermediateDirectories: true)

        let versionEnvironment = try String(
            contentsOf: root.appendingPathComponent("script/version.env"),
            encoding: .utf8
        )
        let versionLine = try XCTUnwrap(
            versionEnvironment.split(separator: "\n").first { $0.hasPrefix("CAPTURELAB_VERSION=") }
        )
        let version = String(versionLine.dropFirst("CAPTURELAB_VERSION=".count))
        let artifactBaseName = "CaptureLab-\(version)-macos-arm64.dmg"
        let staleArtifacts = [
            releaseDirectory.appendingPathComponent(artifactBaseName),
            releaseDirectory.appendingPathComponent("\(artifactBaseName).sha256"),
            releaseDirectory.appendingPathComponent("\(artifactBaseName).sig")
        ]
        for artifact in staleArtifacts {
            try Data("stale".utf8).write(to: artifact)
        }

        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("script/package_dmg.sh").path]
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CAPTURELAB_ARCH": "arm64",
            "CAPTURELAB_RELEASE_DIR": releaseDirectory.path,
            "CAPTURELAB_UPDATE_SIGNING_KEY": missingKey.path
        ]) { _, override in override }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        try process.run()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: errorData, as: UTF8.self)

        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(message.contains("already embeds a locked update-signing public key"))
        XCTAssertTrue(message.contains("Restore the matching private key from its encrypted backup"))
        XCTAssertTrue(message.contains("a replacement key will not work"))
        XCTAssertFalse(message.lowercased().contains("generate"))
        XCTAssertTrue(staleArtifacts.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testReadmeLimitsGenerateHelperToNewIdentitySetup() throws {
        let readme = try String(
            contentsOf: repositoryRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )

        XCTAssertTrue(readme.contains("Do not generate a new key as a recovery step"))
        XCTAssertTrue(readme.contains("only for establishing a brand-new"))
        XCTAssertTrue(readme.contains("swift script/update_signing.swift generate"))
        XCTAssertTrue(readme.contains("Key rotation is not recovery"))
    }

    func testSigningToolMissingKeyGuidanceRequiresBackupRecovery() throws {
        let tool = try String(
            contentsOf: repositoryRoot.appendingPathComponent("script/update_signing.swift"),
            encoding: .utf8
        )
        let missingKeyMessage = try XCTUnwrap(
            tool
                .components(separatedBy: "case .missingKey(let path):")
                .dropFirst()
                .first?
                .components(separatedBy: "case .insecurePermissions")
                .first
        )

        XCTAssertTrue(missingKeyMessage.contains("Restore the matching private key"))
        XCTAssertTrue(missingKeyMessage.contains("encrypted backup"))
        XCTAssertFalse(missingKeyMessage.lowercased().contains("generate"))
    }

    func testSigningToolCreatesNewPrivateKeysExclusively() throws {
        let tool = try String(
            contentsOf: repositoryRoot.appendingPathComponent("script/update_signing.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(tool.contains("O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW"))
        XCTAssertTrue(tool.contains("try writeNewPrivateKey(key.rawRepresentation, to: keyURL)"))
        XCTAssertFalse(tool.contains("guard !FileManager.default.fileExists(atPath: keyURL.path)"))
    }

    func testSigningToolGenerateIsExclusiveAndPreservesExistingKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureLab Signing Tool Tests \(UUID().uuidString)", isDirectory: true)
        let keyURL = root.appendingPathComponent("update signing private key")
        defer { try? FileManager.default.removeItem(at: root) }

        let first = makeSigningToolProcess(arguments: ["generate", keyURL.path])
        let second = makeSigningToolProcess(arguments: ["generate", keyURL.path])
        try first.process.run()
        try second.process.run()
        let results = [collect(first), collect(second)]

        let successes = results.filter { $0.status == 0 }
        let failures = results.filter { $0.status != 0 }
        XCTAssertEqual(successes.count, 1, results.map(\.description).joined(separator: "\n"))
        XCTAssertEqual(failures.count, 1, results.map(\.description).joined(separator: "\n"))
        XCTAssertTrue(failures[0].standardError.contains("Refusing to overwrite"))

        let originalKey = try Data(contentsOf: keyURL)
        XCTAssertEqual(originalKey.count, 32)
        let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(permissions, 0o600)

        let publicKeyResult = runSigningTool(arguments: ["public-key", keyURL.path])
        XCTAssertEqual(publicKeyResult.status, 0, publicKeyResult.description)
        XCTAssertEqual(publicKeyResult.standardOutput, successes[0].standardOutput)

        let overwriteResult = runSigningTool(arguments: ["generate", keyURL.path])
        XCTAssertNotEqual(overwriteResult.status, 0)
        XCTAssertTrue(overwriteResult.standardError.contains("Refusing to overwrite"))
        XCTAssertEqual(try Data(contentsOf: keyURL), originalKey)
    }

    func testSigningToolRejectsGroupReadableKeyWithAccurateGuidance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureLab Signing Permission Tests \(UUID().uuidString)", isDirectory: true)
        let keyURL = root.appendingPathComponent("update-signing-private-key")
        defer { try? FileManager.default.removeItem(at: root) }

        let generate = runSigningTool(arguments: ["generate", keyURL.path])
        XCTAssertEqual(generate.status, 0, generate.description)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: keyURL.path
        )

        let publicKey = runSigningTool(arguments: ["public-key", keyURL.path])
        XCTAssertNotEqual(publicKey.status, 0)
        XCTAssertTrue(publicKey.standardError.contains("must not be accessible by group or other users"))
        XCTAssertFalse(publicKey.standardError.contains("must have permissions 0600"))
    }

    func testBuildAndPackagingScriptsHaveValidShellSyntax() throws {
        for shell in ["/bin/bash", "/bin/zsh"] {
            for relativePath in ["script/build_and_run.sh", "script/package_dmg.sh"] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-n", repositoryRoot.appendingPathComponent(relativePath).path]
                try process.run()
                process.waitUntilExit()
                XCTAssertEqual(
                    process.terminationStatus,
                    0,
                    "\(relativePath) failed syntax validation with \(shell)"
                )
            }
        }
    }

    func testBuildScriptsEmbedStableSignedArchitectureMatchedUpdateSwapHelper() throws {
        let buildScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )
        let packageScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("script/package_dmg.sh"),
            encoding: .utf8
        )
        let versionEnvironment = try String(
            contentsOf: repositoryRoot.appendingPathComponent("script/version.env"),
            encoding: .utf8
        )

        for script in [buildScript, packageScript] {
            XCTAssertTrue(script.contains(#"SWAP_HELPER_NAME="CaptureLabUpdateSwap""#))
            XCTAssertTrue(script.contains(#"APP_HELPERS="$APP_CONTENTS/Helpers""#))
            XCTAssertTrue(script.contains(#"SWAP_HELPER_BUNDLE_ID="$BUNDLE_ID.UpdateSwap""#))
            XCTAssertTrue(script.contains(#"cp "$BUILD_SWAP_HELPER" "$SWAP_HELPER""#))
            XCTAssertTrue(script.contains(
                #"LOCAL_CODE_SIGNING_IDENTITY_SHA1="636F51D5E5F9240F862327A82C3863C2F5EE7DFF""#
            ))
            XCTAssertTrue(script.contains(
                #"LOCAL_CODE_SIGNING_CERTIFICATE_SHA1="636f51d5e5f9240f862327a82c3863c2f5ee7dff""#
            ))
            XCTAssertTrue(script.contains(#"codesign --verify --strict --verbose=2 "$SWAP_HELPER""#))
            XCTAssertTrue(script.contains(#"certificate root = H\"$LOCAL_CODE_SIGNING_CERTIFICATE_SHA1\""#))
            XCTAssertTrue(script.contains(#"identifier \"$SWAP_HELPER_BUNDLE_ID\" and certificate root"#))
            XCTAssertTrue(script.contains(#"identifier \"$BUNDLE_ID\" and certificate root"#))
        }
        XCTAssertTrue(buildScript.contains(#"CODE_SIGNING_IDENTITY="$LOCAL_CODE_SIGNING_IDENTITY_SHA1""#))
        XCTAssertTrue(buildScript.contains(#"CODE_SIGNING_IDENTITY="-""#))
        XCTAssertTrue(buildScript.contains("Using ad-hoc signing for this development build only"))
        XCTAssertTrue(buildScript.contains("Release packaging will refuse this fallback"))
        XCTAssertTrue(packageScript.contains(
            #"--identifier "$SWAP_HELPER_BUNDLE_ID""#
        ))
        XCTAssertTrue(packageScript.contains(
            #"--identifier "$BUNDLE_ID""#
        ))
        XCTAssertFalse(packageScript.contains("codesign --force --deep --sign"))
        XCTAssertFalse(packageScript.contains(#"codesign --force --sign -"#))
        XCTAssertTrue(packageScript.contains("does not permit an ad-hoc or alternate-identity fallback"))
        XCTAssertTrue(packageScript.contains("Restore the matching certificate and private key"))
        XCTAssertTrue(buildScript.contains(
            #"swift build --package-path "$ROOT_DIR" --product "$SWAP_HELPER_NAME""#
        ))
        XCTAssertTrue(packageScript.contains(
            #"swift build --package-path "$ROOT_DIR" --configuration release --triple "$SWIFT_TRIPLE" --product "$SWAP_HELPER_NAME""#
        ))
        XCTAssertTrue(packageScript.contains(#"SWIFT_TRIPLE="arm64-apple-macosx$MIN_SYSTEM_VERSION""#))
        XCTAssertTrue(packageScript.contains(#"SWIFT_TRIPLE="x86_64-apple-macosx$MIN_SYSTEM_VERSION""#))
        XCTAssertTrue(buildScript.contains(#"/usr/bin/lipo -archs "$SWAP_HELPER""#))
        XCTAssertTrue(buildScript.contains(#"*" $(uname -m) "*"#))
        XCTAssertTrue(packageScript.contains(#"/usr/bin/lipo -archs "$SWAP_HELPER""#))
        XCTAssertTrue(packageScript.contains(#"/usr/bin/lipo -archs "$APP_BINARY""#))
        XCTAssertTrue(packageScript.contains(#"RELEASE_WORK_DIR="$(/usr/bin/mktemp -d"#))
        XCTAssertTrue(packageScript.contains("trap cleanup_release_assets EXIT"))
        XCTAssertTrue(packageScript.contains(#"/bin/mv "$WORK_DMG_PATH" "$DMG_PATH""#))
        XCTAssertTrue(versionEnvironment.contains("CAPTURELAB_VERSION=0.4.2"))
    }

    func testReadmeDocumentsStableLocalSigningLimitsAndRecovery() throws {
        let readme = try String(
            contentsOf: repositoryRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )

        XCTAssertTrue(readme.contains("636F51D5E5F9240F862327A82C3863C2F5EE7DFF"))
        XCTAssertTrue(readme.contains("stable local self-signed identity"))
        XCTAssertTrue(readme.contains("never falls back to ad-hoc signing"))
        XCTAssertTrue(readme.contains("not a Developer ID certificate"))
        XCTAssertTrue(readme.contains("notarized."))
        XCTAssertTrue(readme.contains("encrypted offline backup"))
        XCTAssertTrue(readme.contains("Keychain-access transition"))
    }

    func testBuildVerificationRequiresTheFullUntruncatedBinaryPath() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains(#"ps -ww -p "$APP_PID" -o command="#))
        XCTAssertTrue(script.contains(#""$RUNNING_COMMAND" == "$APP_BINARY""#))
        XCTAssertFalse(script.contains(#"== *"$APP_BINARY"*"#))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeSigningToolProcess(arguments: [String]) -> (
        process: Process,
        standardOutput: Pipe,
        standardError: Pipe
    ) {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [repositoryRoot.appendingPathComponent("script/update_signing.swift").path] + arguments
        process.currentDirectoryURL = repositoryRoot
        process.standardOutput = standardOutput
        process.standardError = standardError
        return (process, standardOutput, standardError)
    }

    private func collect(_ invocation: (
        process: Process,
        standardOutput: Pipe,
        standardError: Pipe
    )) -> SigningToolResult {
        invocation.process.waitUntilExit()
        return SigningToolResult(
            status: invocation.process.terminationStatus,
            standardOutput: String(
                decoding: invocation.standardOutput.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines),
            standardError: String(
                decoding: invocation.standardError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func runSigningTool(arguments: [String]) -> SigningToolResult {
        let invocation = makeSigningToolProcess(arguments: arguments)
        do {
            try invocation.process.run()
        } catch {
            return SigningToolResult(status: -1, standardOutput: "", standardError: error.localizedDescription)
        }
        return collect(invocation)
    }
}

private struct SigningToolResult {
    var status: Int32
    var standardOutput: String
    var standardError: String

    var description: String {
        "status=\(status) stdout=\(standardOutput) stderr=\(standardError)"
    }
}
