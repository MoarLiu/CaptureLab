import Foundation

struct UpdateCheckService {
    private let latestReleaseURL: URL
    private let releasesURL: URL
    private let session: URLSession

    init(
        latestReleaseURL: URL = URL(string: "https://api.github.com/repos/MoarLiu/CaptureLab/releases/latest")!,
        releasesURL: URL = URL(string: "https://github.com/MoarLiu/CaptureLab/releases")!,
        session: URLSession = .shared
    ) {
        self.latestReleaseURL = latestReleaseURL
        self.releasesURL = releasesURL
        self.session = session
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
        let releaseURL = URL(string: release.htmlURL) ?? releasesURL

        if Version(latestVersion) > Version(current) {
            return .updateAvailable(
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                releaseURL: releaseURL
            )
        }

        return .upToDate(currentVersion: currentVersion, releasesURL: releasesURL)
    }
}

enum UpdateCheckResult: Equatable {
    case updateAvailable(currentVersion: String, latestVersion: String, releaseURL: URL)
    case upToDate(currentVersion: String, releasesURL: URL)
}

enum UpdateCheckError: LocalizedError {
    case repositoryUnavailable
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .repositoryUnavailable:
            return L10n.updateRepositoryUnavailable
        case .requestFailed:
            return L10n.updateCheckFailedTitle
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
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
