import Foundation
import XCTest
@testable import UsageButlerProviders

final class ArkSessionExpiryReaderTests: XCTestCase {
    func testReadsRefreshExpiryNotShortIDTokenOrExpiresIn() throws {
        let home = try makeHome(expiration: 1_788_055_145)
        defer { try? FileManager.default.removeItem(at: home) }
        let actual = try ArkSessionExpiryReader(homeDirectory: home).read(
            accountID: "123", ownerTRN: "test-owner"
        )
        XCTAssertEqual(actual, Date(timeIntervalSince1970: 1_788_055_145))
    }

    func testReadsReplacementTokenInsteadOfCachingOldExpiration() throws {
        let home = try makeHome(expiration: 1_788_055_145)
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = ArkSessionExpiryReader(homeDirectory: home)
        let first = try reader.read(accountID: "123", ownerTRN: "test-owner")
        try tokenData(expiration: 1_788_141_545).write(to: tokenURL(home), options: .atomic)
        let second = try reader.read(accountID: "123", ownerTRN: "test-owner")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.timeIntervalSince1970, 1_788_141_545)
    }

    func testRejectsAnotherIdentityAndPathTraversal() throws {
        let home = try makeHome(expiration: 1_788_055_145)
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = ArkSessionExpiryReader(homeDirectory: home)
        XCTAssertThrowsError(try reader.read(accountID: "123", ownerTRN: "another-owner"))
        XCTAssertThrowsError(try reader.read(accountID: "../123", ownerTRN: "test-owner"))
    }

    func testRejectsTokenFileSymlink() throws {
        let home = try makeHome(expiration: 1_788_055_145)
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("other.json")
        try FileManager.default.moveItem(at: tokenURL(home), to: target)
        try FileManager.default.createSymbolicLink(at: tokenURL(home), withDestinationURL: target)
        XCTAssertThrowsError(try ArkSessionExpiryReader(homeDirectory: home).read(
            accountID: "123", ownerTRN: "test-owner"
        ))
    }

    func testRejectsIdentityDirectorySymlink() throws {
        let home = try makeHome(expiration: 1_788_055_145)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = tokenURL(home).deletingLastPathComponent()
        let target = home.appendingPathComponent("elsewhere")
        try FileManager.default.moveItem(at: directory, to: target)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
        XCTAssertThrowsError(try ArkSessionExpiryReader(homeDirectory: home).read(
            accountID: "123", ownerTRN: "test-owner"
        ))
    }

    func testRejectsOversizedAndMissingTokenFiles() throws {
        let home = try makeHome(expiration: 1_788_055_145)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(repeating: 32, count: 131_073).write(to: tokenURL(home))
        let reader = ArkSessionExpiryReader(homeDirectory: home)
        XCTAssertThrowsError(try reader.read(accountID: "123", ownerTRN: "test-owner"))
        try FileManager.default.removeItem(at: tokenURL(home))
        XCTAssertThrowsError(try reader.read(accountID: "123", ownerTRN: "test-owner"))
    }

    func testMissingMalformedOrImpossibleClaimsDoNotInventExpiry() throws {
        for claims in ["{}", #"{"exp":"tomorrow"}"#, #"{"exp":-1}"#,
                       #"{"exp":100,"iat":200}"#, #"{"exp":1e100}"#] {
            let payload = Data(claims.utf8).base64EncodedString()
            let bytes = try JSONSerialization.data(withJSONObject: ["refresh_token": "e30.\(payload).signature"])
            XCTAssertThrowsError(try ArkSessionExpiryReader.parseExpiration(bytes))
        }
        XCTAssertThrowsError(try ArkSessionExpiryReader.parseExpiration(Data(#"{"refresh_token":"opaque"}"#.utf8)))
    }

    private func makeHome(expiration: TimeInterval) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = tokenURL(home).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"trn":"test-owner","source":"arkcli"}"#.utf8)
            .write(to: directory.appendingPathComponent("metadata.json"))
        try tokenData(expiration: expiration).write(to: tokenURL(home))
        return home
    }

    private func tokenURL(_ home: URL) -> URL {
        home.appendingPathComponent(".arkcli/identities/volc-123/token.json")
    }

    private func tokenData(expiration: TimeInterval) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: ["exp": expiration])
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return try JSONSerialization.data(withJSONObject: [
            "refresh_token": "e30.\(payload).signature", "id_token": "ignored", "expires_in": 900
        ])
    }
}
