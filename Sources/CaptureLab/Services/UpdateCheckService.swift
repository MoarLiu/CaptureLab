import CryptoKit
import Foundation

struct UpdateCheckService {
    private let latestReleaseURL: URL
    private let releasesURL: URL
    private let session: URLSession
    private let fileManager: FileManager
    private let architecture: String

    init(
        latestReleaseURL: URL = URL(string: "https://api.github.com/repos/MoarLiu/CaptureLab/releases/latest")!,
        releasesURL: URL = URL(string: "https://github.com/MoarLiu/CaptureLab/releases")!,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        architecture: String = CaptureLabUpdateArchitecture.current
    ) {
        self.latestReleaseURL = latestReleaseURL
        self.releasesURL = releasesURL
        self.session = session
        self.fileManager = fileManager
        self.architecture = architecture
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
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("CaptureLab", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
            .appendingPathComponent(latestVersion, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let dmgURL = directory.appendingPathComponent(package.dmg.name)
        let checksumURL = directory.appendingPathComponent(package.checksum.name)

        try await download(package.dmg, to: dmgURL)
        try await download(package.checksum, to: checksumURL)
        try verifyChecksum(for: dmgURL, checksumURL: checksumURL)

        return dmgURL
    }

    private func updatePackage(
        in release: GitHubRelease,
        latestVersion: String,
        architecture: String
    ) throws -> UpdatePackage {
        let dmgName = "CaptureLab-\(latestVersion)-macos-\(architecture).dmg"
        let checksumName = "\(dmgName).sha256"

        guard let dmg = release.assets.first(where: { $0.name == dmgName }),
              let checksum = release.assets.first(where: { $0.name == checksumName })
        else {
            throw UpdateCheckError.updateAssetUnavailable(architecture)
        }

        return UpdatePackage(
            dmg: UpdateAsset(name: dmg.name, downloadURL: dmg.downloadURL),
            checksum: UpdateAsset(name: checksum.name, downloadURL: checksum.downloadURL)
        )
    }

    private func download(_ asset: UpdateAsset, to destinationURL: URL) async throws {
        var request = URLRequest(url: asset.downloadURL)
        request.setValue("CaptureLab", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw UpdateCheckError.downloadFailed
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try data.write(to: destinationURL, options: .atomic)
    }

    private func verifyChecksum(for dmgURL: URL, checksumURL: URL) throws {
        let checksumText = try String(contentsOf: checksumURL, encoding: .utf8)
        guard let expected = checksumText
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .first
            .map({ String($0).lowercased() })
        else {
            throw UpdateCheckError.checksumMismatch
        }

        let digest = SHA256.hash(data: try Data(contentsOf: dmgURL))
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard expected == actual else {
            throw UpdateCheckError.checksumMismatch
        }
    }
}

enum UpdateCheckResult: Equatable {
    case updateAvailable(currentVersion: String, latestVersion: String, package: UpdatePackage)
    case upToDate(currentVersion: String, releasesURL: URL)
}

struct UpdatePackage: Equatable {
    var dmg: UpdateAsset
    var checksum: UpdateAsset
}

struct UpdateAsset: Equatable {
    var name: String
    var downloadURL: URL
}

enum UpdateCheckError: LocalizedError {
    case repositoryUnavailable
    case requestFailed
    case updateAssetUnavailable(String)
    case downloadFailed
    case checksumMismatch

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
        case .checksumMismatch:
            return L10n.updateChecksumMismatch
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
