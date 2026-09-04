import Darwin
import Foundation

/// Reads only the declared expiry of the current CLI identity's refresh token.
/// Credentials never leave this reader, and are not used for authentication.
public struct ArkSessionExpiryReader: Sendable {
    public enum ReadError: Error, Equatable {
        case invalidIdentity
        case unavailable
        case unsafeFile
        case invalidExpiration
    }

    private struct IdentityMetadata: Decodable {
        let trn: String
        let source: String
    }

    private struct TokenEnvelope: Decodable {
        let refresh_token: String
    }

    private struct TimeClaims: Decodable {
        let exp: Double
        let iat: Double?
    }

    private let identitiesDirectory: URL
    private static let maximumBytes = 131_072

    public init(homeDirectory: URL) {
        identitiesDirectory = homeDirectory
            .appendingPathComponent(".arkcli", isDirectory: true)
            .appendingPathComponent("identities", isDirectory: true)
    }

    public func read(accountID: String, ownerTRN: String) throws -> Date {
        guard !accountID.isEmpty, !ownerTRN.isEmpty,
              accountID.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || $0 == 45 || $0 == 95
              }) else { throw ReadError.invalidIdentity }
        let directory = identitiesDirectory.appendingPathComponent("volc-" + accountID)
        // Do not traverse credential-store or identity-directory symlinks.
        for url in [identitiesDirectory.deletingLastPathComponent(), identitiesDirectory, directory] {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ReadError.unsafeFile
            }
        }
        let metadata = try JSONDecoder().decode(
            IdentityMetadata.self,
            from: readFile(directory.appendingPathComponent("metadata.json"))
        )
        guard metadata.trn == ownerTRN, metadata.source == "arkcli" else {
            throw ReadError.invalidIdentity
        }
        return try Self.parseExpiration(
            readFile(directory.appendingPathComponent("token.json"))
        )
    }

    static func parseExpiration(_ data: Data) throws -> Date {
        let envelope = try JSONDecoder().decode(TokenEnvelope.self, from: data)
        let parts = envelope.refresh_token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else {
            throw ReadError.invalidExpiration
        }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let bytes = Data(base64Encoded: payload) else { throw ReadError.invalidExpiration }
        let claims = try JSONDecoder().decode(TimeClaims.self, from: bytes)
        guard claims.exp.isFinite, claims.exp > 0, claims.exp <= 253_402_300_799,
              claims.iat.map({ $0.isFinite && $0 <= claims.exp }) ?? true else {
            throw ReadError.invalidExpiration
        }
        // This is a local declared deadline, not signature validation or a
        // promise that the server cannot revoke the session earlier.
        return Date(timeIntervalSince1970: claims.exp)
    }

    private func readFile(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ReadError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_size > 0, info.st_size <= Self.maximumBytes else {
            throw ReadError.unsafeFile
        }
        guard let data = try handle.read(upToCount: Self.maximumBytes + 1),
              data.count <= Self.maximumBytes else { throw ReadError.unsafeFile }
        return data
    }
}
