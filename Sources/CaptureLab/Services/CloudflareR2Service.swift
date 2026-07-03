import Combine
import CryptoKit
import Foundation

struct CloudflareR2Settings: Codable, Equatable {
    var endpoint: String
    var bucket: String
    var pathPrefix: String
    var publicBaseURL: String
    var accessKeyID: String
    var secretAccessKey: String

    var isComplete: Bool {
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !pathPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func normalized() throws -> CloudflareR2Settings {
        let endpoint = try Self.normalizedEndpoint(endpoint)
        let publicBaseURL = try Self.normalizedPublicBaseURL(publicBaseURL)
        let bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathPrefix = pathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let accessKeyID = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretAccessKey = secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !bucket.isEmpty, !bucket.contains("/") else {
            throw CloudflareR2Error.incompleteSettings(L10n.r2Bucket)
        }
        guard !pathPrefix.isEmpty,
              pathPrefix.split(separator: "/").allSatisfy({ CloudflareR2UploadService.isSafeObjectKeySegment(String($0)) })
        else {
            throw CloudflareR2Error.incompleteSettings(L10n.r2PathPrefix)
        }
        guard !accessKeyID.isEmpty else {
            throw CloudflareR2Error.incompleteSettings(L10n.r2AccessKeyID)
        }
        guard !secretAccessKey.isEmpty else {
            throw CloudflareR2Error.incompleteSettings(L10n.r2SecretAccessKey)
        }

        return CloudflareR2Settings(
            endpoint: endpoint,
            bucket: bucket,
            pathPrefix: pathPrefix,
            publicBaseURL: publicBaseURL,
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey
        )
    }

    private static func normalizedEndpoint(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: normalized),
              let scheme = components.scheme,
              components.host != nil,
              components.path.isEmpty || components.path == "/"
        else {
            throw CloudflareR2Error.invalidURL(L10n.r2Endpoint)
        }
        var output = components
        output.scheme = scheme.lowercased()
        output.path = ""
        guard let value = output.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            throw CloudflareR2Error.invalidURL(L10n.r2Endpoint)
        }
        return value
    }

    private static func normalizedPublicBaseURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme != nil,
              components.host != nil
        else {
            throw CloudflareR2Error.invalidURL(L10n.r2PublicBaseURL)
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

struct CloudflareR2SettingsInput: Equatable {
    var endpoint: String
    var bucket: String
    var pathPrefix: String
    var publicBaseURL: String
    var accessKeyID: String
    var secretAccessKey: String
}

@MainActor
final class CloudflareR2SettingsStore: ObservableObject {
    static let fileName = "cloudflare-r2-settings.json"

    @Published private(set) var settings: CloudflareR2Settings?
    @Published private(set) var loadError: CloudflareR2Error?

    private struct Document: Codable, Equatable {
        var schemaVersion: Int
        var settings: CloudflareR2Settings
    }

    private let environment: [String: String]
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            settings = try load()
            loadError = nil
        } catch CloudflareR2Error.settingsNotConfigured {
            settings = nil
            loadError = nil
        } catch {
            settings = nil
            loadError = .settingsLoadFailed(error.localizedDescription)
        }
    }

    var url: URL {
        CaptureLabDataRoot.supportDirectory(environment: environment)
            .appendingPathComponent(Self.fileName)
    }

    func save(_ input: CloudflareR2SettingsInput) throws {
        let secretAccessKey: String
        if input.secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let existing = settings,
           existing.accessKeyID == input.accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.secretAccessKey.isEmpty {
            secretAccessKey = existing.secretAccessKey
        } else {
            secretAccessKey = input.secretAccessKey
        }

        let normalized = try CloudflareR2Settings(
            endpoint: input.endpoint,
            bucket: input.bucket,
            pathPrefix: input.pathPrefix,
            publicBaseURL: input.publicBaseURL,
            accessKeyID: input.accessKeyID,
            secretAccessKey: secretAccessKey
        ).normalized()

        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let document = Document(schemaVersion: 1, settings: normalized)
        try encoder.encode(document).write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        settings = normalized
        loadError = nil
    }

    func requiredSettings() throws -> CloudflareR2Settings {
        if let settings {
            return settings
        }
        if let loadError {
            throw loadError
        }
        throw CloudflareR2Error.settingsNotConfigured
    }

    private func load() throws -> CloudflareR2Settings {
        guard fileManager.fileExists(atPath: url.path) else {
            throw CloudflareR2Error.settingsNotConfigured
        }
        let document = try decoder.decode(Document.self, from: Data(contentsOf: url))
        return try document.settings.normalized()
    }
}

enum CaptureLabDataRoot {
    static func supportDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
            .standardizedFileURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CaptureLab", isDirectory: true)
    }
}

struct CloudflareR2UploadRequest: Equatable {
    var settings: CloudflareR2Settings
    var data: Data
    var fileName: String
    var contentType: String
}

struct CloudflareR2UploadResult: Equatable {
    var url: String
    var objectKey: String
    var sizeBytes: Int
}

enum CloudflareR2Error: LocalizedError {
    case settingsNotConfigured
    case settingsLoadFailed(String)
    case incompleteSettings(String)
    case invalidURL(String)
    case imageExportFailed
    case fileTooLarge(Int)
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .settingsNotConfigured:
            return L10n.r2SettingsNotConfigured
        case .settingsLoadFailed(let message):
            return L10n.r2SettingsLoadFailed(message)
        case .incompleteSettings(let field):
            return L10n.r2IncompleteField(field)
        case .invalidURL(let field):
            return L10n.r2InvalidURL(field)
        case .imageExportFailed:
            return L10n.imageExportFailed
        case .fileTooLarge(let limit):
            return L10n.r2FileTooLarge(limit)
        case .uploadFailed(let message):
            return message
        }
    }
}

final class CloudflareR2UploadService {
    typealias UploadTransport = (URLRequest, Data) async throws -> (Data, URLResponse)

    private let now: () -> Date
    private let uuid: () -> UUID
    private let transport: UploadTransport
    private let maxSizeBytes = 100 * 1024 * 1024

    init(
        now: @escaping () -> Date = Date.init,
        uuid: @escaping () -> UUID = UUID.init,
        transport: @escaping UploadTransport = { request, data in
            try await URLSession.shared.upload(for: request, from: data)
        }
    ) {
        self.now = now
        self.uuid = uuid
        self.transport = transport
    }

    func upload(_ request: CloudflareR2UploadRequest) async throws -> CloudflareR2UploadResult {
        let settings = try request.settings.normalized()
        guard request.data.count <= maxSizeBytes else {
            throw CloudflareR2Error.fileTooLarge(maxSizeBytes)
        }
        let uploadDate = now()
        let objectKey = objectKey(
            fileName: request.fileName,
            settings: settings,
            date: uploadDate,
            uuid: uuid()
        )
        let signedRequest = try signedPUTRequest(
            settings: settings,
            objectKey: objectKey,
            data: request.data,
            contentType: request.contentType,
            requestDate: uploadDate
        )
        _ = try await performUploadWithRetry(signedRequest, data: request.data)
        return CloudflareR2UploadResult(
            url: try Self.publicURL(for: objectKey, settings: settings),
            objectKey: objectKey,
            sizeBytes: request.data.count
        )
    }

    func signedPUTRequest(
        settings rawSettings: CloudflareR2Settings,
        objectKey: String,
        data: Data,
        contentType: String,
        requestDate: Date
    ) throws -> URLRequest {
        let settings = try rawSettings.normalized()
        let endpoint = try Self.s3Endpoint(from: settings.endpoint)
        let rawPath = "/\(settings.bucket)/\(objectKey)"
        let canonicalURI = Self.uriEncodePath(rawPath)
        let hostHeader = endpoint.port.map { "\(endpoint.host):\($0)" } ?? endpoint.host

        var components = URLComponents()
        components.scheme = endpoint.scheme
        components.host = endpoint.host
        components.port = endpoint.port
        components.percentEncodedPath = canonicalURI
        guard let url = components.url else {
            throw CloudflareR2Error.invalidURL(L10n.r2Endpoint)
        }

        let payloadHash = Self.sha256Hex(data)
        let amzDate = Self.s3DateTimeString(from: requestDate)
        let dateStamp = Self.s3DateString(from: requestDate)
        let scope = "\(dateStamp)/auto/s3/aws4_request"
        let canonicalHeaders = [
            "content-type:\(contentType)",
            "host:\(hostHeader)",
            "x-amz-content-sha256:\(payloadHash)",
            "x-amz-date:\(amzDate)"
        ].joined(separator: "\n") + "\n"
        let signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = [
            "PUT",
            canonicalURI,
            "",
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")
        let signature = Self.awsSignature(
            secretAccessKey: settings.secretAccessKey,
            dateStamp: dateStamp,
            region: "auto",
            stringToSign: stringToSign
        )

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(hostHeader, forHTTPHeaderField: "Host")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(settings.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    func objectKey(fileName: String, settings: CloudflareR2Settings, date: Date, uuid: UUID) -> String {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dayFormatter.dateFormat = "yyyy/MM/dd"
        let prefix = (try? settings.normalized().pathPrefix) ?? "captures"
        return "\(prefix)/\(dayFormatter.string(from: date))/\(uuid.uuidString)-\(Self.safeFileName(fileName))"
    }

    static func publicURL(for objectKey: String, settings rawSettings: CloudflareR2Settings) throws -> String {
        let settings = try rawSettings.normalized()
        let base = settings.publicBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(base)/\(uriEncodePath(objectKey))"
    }

    static func isSafeObjectKeySegment(_ segment: String) -> Bool {
        guard !segment.isEmpty, segment != ".", segment != ".." else {
            return false
        }
        return !segment.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func safeFileName(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return value.isEmpty ? "capture.png" : value
    }

    private func performUploadWithRetry(_ request: URLRequest, data: Data) async throws -> Data {
        let retryDelays: [UInt64] = [250_000_000, 750_000_000, 1_500_000_000]
        var attempt = 0
        while true {
            do {
                let (body, response) = try await transport(request, data)
                guard let http = response as? HTTPURLResponse else {
                    throw CloudflareR2Error.uploadFailed(L10n.r2UploadNoHTTPResponse)
                }
                if (200..<300).contains(http.statusCode) {
                    return body
                }
                if Self.isRetryable(statusCode: http.statusCode), attempt < retryDelays.count {
                    try await Task.sleep(nanoseconds: retryDelays[attempt])
                    attempt += 1
                    continue
                }
                throw CloudflareR2Error.uploadFailed(Self.userFacingHTTPError(statusCode: http.statusCode))
            } catch {
                if let r2Error = error as? CloudflareR2Error {
                    throw r2Error
                }
                if Self.isRetryable(networkError: error), attempt < retryDelays.count {
                    try await Task.sleep(nanoseconds: retryDelays[attempt])
                    attempt += 1
                    continue
                }
                throw CloudflareR2Error.uploadFailed(Self.userFacingNetworkError(error))
            }
        }
    }

    private static func isRetryable(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private static func isRetryable(networkError error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return false
        }
        let code = URLError.Code(rawValue: nsError.code)
        switch code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private static func userFacingHTTPError(statusCode: Int) -> String {
        switch statusCode {
        case 400:
            return L10n.r2UploadBadRequest
        case 401, 403:
            return L10n.r2UploadForbidden(statusCode)
        case 404:
            return L10n.r2UploadNotFound
        case 408, 425, 429:
            return L10n.r2UploadRateLimited(statusCode)
        case 413:
            return L10n.r2UploadTooLarge
        case 500...599:
            return L10n.r2UploadServerError(statusCode)
        default:
            return L10n.r2UploadHTTPError(statusCode)
        }
    }

    private static func userFacingNetworkError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .notConnectedToInternet:
                return L10n.r2UploadOffline
            case .timedOut:
                return L10n.r2UploadTimedOut
            case .cannotFindHost, .dnsLookupFailed:
                return L10n.r2UploadCannotResolveHost
            case .cannotConnectToHost, .networkConnectionLost:
                return L10n.r2UploadConnectionLost
            default:
                break
            }
        }
        return L10n.r2UploadNetworkError(error.localizedDescription)
    }

    private struct S3Endpoint {
        var scheme: String
        var host: String
        var port: Int?
    }

    private static func s3Endpoint(from raw: String) throws -> S3Endpoint {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: normalized),
              let scheme = components.scheme,
              let host = components.host,
              components.path.isEmpty || components.path == "/"
        else {
            throw CloudflareR2Error.invalidURL(L10n.r2Endpoint)
        }
        return S3Endpoint(scheme: scheme, host: host, port: components.port)
    }

    private static func uriEncodePath(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return raw.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    private static func s3DateTimeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func s3DateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacSHA256(key: Data, message: String) -> Data {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key)
        )
        return Data(code)
    }

    private static func awsSignature(
        secretAccessKey: String,
        dateStamp: String,
        region: String,
        stringToSign: String
    ) -> String {
        let dateKey = hmacSHA256(key: Data("AWS4\(secretAccessKey)".utf8), message: dateStamp)
        let regionKey = hmacSHA256(key: dateKey, message: region)
        let serviceKey = hmacSHA256(key: regionKey, message: "s3")
        let signingKey = hmacSHA256(key: serviceKey, message: "aws4_request")
        return hmacSHA256(key: signingKey, message: stringToSign)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
