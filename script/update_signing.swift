#!/usr/bin/env swift

import CryptoKit
import Darwin
import Foundation

private enum SigningToolError: LocalizedError {
    case usage
    case keyAlreadyExists(String)
    case missingKey(String)
    case insecurePermissions(String)
    case publicKeyMismatch
    case invalidSignature

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: update_signing.swift generate <private-key-path> | public-key <private-key-path> | sign <private-key-path> <expected-public-key-base64> <input-file> <signature-file> | verify <public-key-base64> <input-file> <signature-file>"
        case .keyAlreadyExists(let path):
            return "Refusing to overwrite the existing update signing key at \(path)."
        case .missingKey(let path):
            return "The update signing key does not exist at \(path). Restore the matching private key from its encrypted backup; a replacement key will not match an already embedded public key."
        case .insecurePermissions(let path):
            return "The update signing key at \(path) must not be accessible by group or other users."
        case .publicKeyMismatch:
            return "The private update signing key does not match CaptureLab's embedded public key."
        case .invalidSignature:
            return "The generated update signature could not be verified."
        }
    }
}

private func privateKey(at url: URL) throws -> Curve25519.Signing.PrivateKey {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw SigningToolError.missingKey(url.path)
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    guard permissions & 0o077 == 0 else {
        throw SigningToolError.insecurePermissions(url.path)
    }

    return try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: url))
}

private func sha256Digest(of url: URL) throws -> Data {
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

private func writeAtomically(_ data: Data, to url: URL, permissions: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
}

private func removeCreatedFileIfUnchanged(at url: URL, descriptor: Int32) {
    var descriptorInfo = stat()
    guard Darwin.fstat(descriptor, &descriptorInfo) == 0 else { return }

    var pathInfo = stat()
    let pathStatus = url.path.withCString { Darwin.lstat($0, &pathInfo) }
    guard pathStatus == 0,
          descriptorInfo.st_dev == pathInfo.st_dev,
          descriptorInfo.st_ino == pathInfo.st_ino
    else {
        return
    }

    _ = url.path.withCString { Darwin.unlink($0) }
}

private func writeNewPrivateKey(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let descriptor = url.path.withCString {
        Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    }
    guard descriptor >= 0 else {
        if errno == EEXIST {
            throw SigningToolError.keyAlreadyExists(url.path)
        }
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "Could not create the update signing key at \(url.path): \(String(cString: strerror(errno)))"]
        )
    }
    var completed = false
    defer {
        if !completed {
            removeCreatedFileIfUnchanged(at: url, descriptor: descriptor)
        }
        _ = Darwin.close(descriptor)
    }

    try data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                buffer.count - offset
            )
            if written < 0 {
                if errno == EINTR { continue }
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "Could not write the update signing key at \(url.path): \(String(cString: strerror(errno)))"]
                )
            }
            guard written > 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EIO),
                    userInfo: [NSLocalizedDescriptionKey: "Could not finish writing the update signing key at \(url.path)."]
                )
            }
            offset += written
        }
    }

    guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
          Darwin.fsync(descriptor) == 0
    else {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "Could not secure the update signing key at \(url.path): \(String(cString: strerror(errno)))"]
        )
    }
    completed = true
}

_ = umask(0o077)

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { throw SigningToolError.usage }

    switch command {
    case "generate":
        guard arguments.count == 2 else { throw SigningToolError.usage }
        let keyURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let key = Curve25519.Signing.PrivateKey()
        try writeNewPrivateKey(key.rawRepresentation, to: keyURL)
        print(key.publicKey.rawRepresentation.base64EncodedString())

    case "public-key":
        guard arguments.count == 2 else { throw SigningToolError.usage }
        let key = try privateKey(at: URL(fileURLWithPath: arguments[1]).standardizedFileURL)
        print(key.publicKey.rawRepresentation.base64EncodedString())

    case "sign":
        guard arguments.count == 5 else { throw SigningToolError.usage }
        let key = try privateKey(at: URL(fileURLWithPath: arguments[1]).standardizedFileURL)
        guard key.publicKey.rawRepresentation.base64EncodedString() == arguments[2] else {
            throw SigningToolError.publicKeyMismatch
        }
        let inputURL = URL(fileURLWithPath: arguments[3]).standardizedFileURL
        let signatureURL = URL(fileURLWithPath: arguments[4]).standardizedFileURL
        let digest = try sha256Digest(of: inputURL)
        let signature = try key.signature(for: digest)
        guard key.publicKey.isValidSignature(signature, for: digest) else {
            throw SigningToolError.invalidSignature
        }
        try writeAtomically(signature, to: signatureURL, permissions: 0o644)

    case "verify":
        guard arguments.count == 4,
              let publicKeyData = Data(base64Encoded: arguments[1])
        else {
            throw SigningToolError.usage
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        let digest = try sha256Digest(of: URL(fileURLWithPath: arguments[2]).standardizedFileURL)
        let signature = try Data(contentsOf: URL(fileURLWithPath: arguments[3]).standardizedFileURL)
        guard publicKey.isValidSignature(signature, for: digest) else {
            throw SigningToolError.invalidSignature
        }

    default:
        throw SigningToolError.usage
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
