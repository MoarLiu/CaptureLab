import CryptoKit
import Foundation

struct UpdateCheckService: @unchecked Sendable {
    static let maximumDMGSizeBytes: Int64 = 512 * 1024 * 1024
    static let maximumMetadataSizeBytes: Int64 = 16 * 1024

    private let latestReleaseURL: URL
    private let releasesURL: URL
    private let session: URLSession
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let architecture: String
    private let signatureVerifier: UpdateSignatureVerifier
    private let maximumDMGSizeBytes: Int64

    init(
        latestReleaseURL: URL = URL(string: "https://api.github.com/repos/MoarLiu/CaptureLab/releases/latest")!,
        releasesURL: URL = URL(string: "https://github.com/MoarLiu/CaptureLab/releases")!,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        architecture: String = CaptureLabUpdateArchitecture.current,
        signaturePublicKey: Data = UpdateSigningIdentity.publicKeyRawRepresentation,
        maximumDMGSizeBytes: Int64 = UpdateCheckService.maximumDMGSizeBytes
    ) {
        self.latestReleaseURL = latestReleaseURL
        self.releasesURL = releasesURL
        self.session = session
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.architecture = architecture
        self.signatureVerifier = UpdateSignatureVerifier(publicKeyRawRepresentation: signaturePublicKey)
        self.maximumDMGSizeBytes = maximumDMGSizeBytes
    }

    func checkForUpdates(currentVersion: String) async throws -> UpdateCheckResult {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CaptureLab", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.requestFailed
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 404 {
                throw UpdateCheckError.repositoryUnavailable
            }
            throw UpdateCheckError.requestFailed
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let latestVersion = release.tagName.normalizedVersionString
        let current = currentVersion.normalizedVersionString

        if Version(latestVersion) > Version(current) {
            let package = try updatePackage(
                in: release,
                latestVersion: latestVersion,
                architecture: architecture
            )
            return .updateAvailable(
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                package: package
            )
        }

        return .upToDate(currentVersion: currentVersion, releasesURL: releasesURL)
    }

    func downloadUpdate(_ package: UpdatePackage, latestVersion: String) async throws -> URL {
        let versionComponent = latestVersion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let directory = temporaryDirectory
            .appendingPathComponent("CaptureLab", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
            .appendingPathComponent(versionComponent, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let dmgURL = directory.appendingPathComponent(package.dmg.name)
        let checksumURL = directory.appendingPathComponent(package.checksum.name)
        let signatureURL = directory.appendingPathComponent(package.signature.name)

        do {
            try await download(package.dmg, to: dmgURL, maximumSizeBytes: maximumDMGSizeBytes)
            try await download(
                package.checksum,
                to: checksumURL,
                maximumSizeBytes: Self.maximumMetadataSizeBytes
            )
            try await download(
                package.signature,
                to: signatureURL,
                maximumSizeBytes: Self.maximumMetadataSizeBytes
            )
            let digest = try verifyChecksum(for: dmgURL, checksumURL: checksumURL)
            try signatureVerifier.verify(digest: digest, signatureURL: signatureURL)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        return dmgURL
    }

    private func updatePackage(
        in release: GitHubRelease,
        latestVersion: String,
        architecture: String
    ) throws -> UpdatePackage {
        let dmgName = "CaptureLab-\(latestVersion)-macos-\(architecture).dmg"
        let checksumName = "\(dmgName).sha256"
        let signatureName = "\(dmgName).sig"

        guard let dmg = release.assets.first(where: { $0.name == dmgName }),
              let checksum = release.assets.first(where: { $0.name == checksumName }),
              let signature = release.assets.first(where: { $0.name == signatureName })
        else {
            throw UpdateCheckError.updateAssetUnavailable(architecture)
        }

        return UpdatePackage(
            dmg: UpdateAsset(name: dmg.name, downloadURL: dmg.downloadURL),
            checksum: UpdateAsset(name: checksum.name, downloadURL: checksum.downloadURL),
            signature: UpdateAsset(name: signature.name, downloadURL: signature.downloadURL),
            architecture: architecture
        )
    }

    private func download(
        _ asset: UpdateAsset,
        to destinationURL: URL,
        maximumSizeBytes: Int64
    ) async throws {
        guard asset.name == destinationURL.lastPathComponent else {
            throw UpdateCheckError.downloadFailed
        }
        var request = URLRequest(url: asset.downloadURL)
        request.setValue("CaptureLab", forHTTPHeaderField: "User-Agent")

        let (temporaryURL, response) = try await session.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw UpdateCheckError.downloadFailed
        }

        if response.expectedContentLength > maximumSizeBytes {
            throw UpdateCheckError.downloadTooLarge(maximumSizeBytes)
        }
        let attributes = try fileManager.attributesOfItem(atPath: temporaryURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size >= 0, size <= maximumSizeBytes else {
            throw UpdateCheckError.downloadTooLarge(maximumSizeBytes)
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    @discardableResult
    private func verifyChecksum(for dmgURL: URL, checksumURL: URL) throws -> Data {
        let checksumText = try String(contentsOf: checksumURL, encoding: .utf8)
        guard let expected = checksumText
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .first
            .map({ String($0).lowercased() }),
              expected.count == 64,
              expected.allSatisfy({ $0.isHexDigit })
        else {
            throw UpdateCheckError.checksumMismatch
        }

        let digest = try Self.sha256Digest(of: dmgURL)
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard expected == actual else {
            throw UpdateCheckError.checksumMismatch
        }
        return digest
    }

    static func sha256Digest(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}

enum UpdateCheckResult: Equatable, Sendable {
    case updateAvailable(currentVersion: String, latestVersion: String, package: UpdatePackage)
    case upToDate(currentVersion: String, releasesURL: URL)
}

struct UpdatePackage: Equatable, Sendable {
    var dmg: UpdateAsset
    var checksum: UpdateAsset
    var signature: UpdateAsset
    var architecture: String
}

struct UpdateAsset: Equatable, Sendable {
    var name: String
    var downloadURL: URL
}

enum UpdateCheckError: LocalizedError {
    case repositoryUnavailable
    case requestFailed
    case updateAssetUnavailable(String)
    case downloadFailed
    case downloadTooLarge(Int64)
    case checksumMismatch
    case signatureMismatch

    var errorDescription: String? {
        switch self {
        case .repositoryUnavailable:
            return L10n.updateRepositoryUnavailable
        case .requestFailed:
            return L10n.updateCheckFailedTitle
        case .updateAssetUnavailable(let architecture):
            return L10n.updateAssetUnavailable(architecture)
        case .downloadFailed:
            return L10n.updateDownloadFailed
        case .downloadTooLarge(let maximumSizeBytes):
            return "The downloaded update exceeds the \(maximumSizeBytes)-byte safety limit."
        case .checksumMismatch:
            return L10n.updateChecksumMismatch
        case .signatureMismatch:
            return "The update signature is invalid. The update was not installed."
        }
    }
}

enum UpdateSigningIdentity {
    static let publicKeyBase64 = "jBXKIXZ5O9KxP1YiHixdKc2BzzxLpUoTdRWdM1fjMLE="

    static var publicKeyRawRepresentation: Data {
        guard let data = Data(base64Encoded: publicKeyBase64), data.count == 32 else {
            preconditionFailure("CaptureLab's embedded update signing public key is invalid.")
        }
        return data
    }
}

struct UpdateSignatureVerifier: Sendable {
    private let publicKeyRawRepresentation: Data

    init(publicKeyRawRepresentation: Data) {
        self.publicKeyRawRepresentation = publicKeyRawRepresentation
    }

    func verify(digest: Data, signatureURL: URL) throws {
        do {
            let publicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: publicKeyRawRepresentation
            )
            let signature = try Data(contentsOf: signatureURL, options: .mappedIfSafe)
            guard signature.count == 64,
                  publicKey.isValidSignature(signature, for: digest)
            else {
                throw UpdateCheckError.signatureMismatch
            }
        } catch let error as UpdateCheckError {
            throw error
        } catch {
            throw UpdateCheckError.signatureMismatch
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        assets = try container.decodeIfPresent([GitHubReleaseAsset].self, forKey: .assets) ?? []
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let downloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}

private enum CaptureLabUpdateArchitecture {
    static var current: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

private struct Version: Comparable {
    let parts: [Int]

    init(_ value: String) {
        parts = value
            .split(separator: ".")
            .map { component in
                let digits = component.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

private extension String {
    var normalizedVersionString: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("v")
            .trimmingPrefix("V")
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
