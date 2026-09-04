import Foundation
import XCTest
@testable import UsageButlerInfrastructure

final class MinimalChildEnvironmentBuilderTests: XCTestCase {
    func testBuildUsesOnlyDeterministicAllowlistWithoutParentSecrets() throws {
        let proxySecret = "http://proxy-user:proxy-password@127.0.0.1:7897"
        let result = try MinimalChildEnvironmentBuilder().build(
            pathEntries: [
                "",
                "relative/bin",
                "/first/bin",
                "/first/./bin/",
                "/cannot:encode",
                "/second/bin"
            ],
            homeDirectoryURL: URL(fileURLWithPath: "/safe/home/../home", isDirectory: true),
            locale: CLILocaleEnvironment(
                lang: "en_US.UTF-8",
                lcAll: "C",
                lcCType: "UTF-8"
            ),
            explicitProxyEnvironment: [
                "HTTPS_PROXY": proxySecret,
                "no_proxy": "127.0.0.1,localhost"
            ]
        )

        XCTAssertEqual(result.variables["PATH"], "/first/bin:/second/bin")
        XCTAssertEqual(result.variables["HOME"], "/safe/home")
        XCTAssertEqual(result.variables["LANG"], "en_US.UTF-8")
        XCTAssertEqual(result.variables["LC_ALL"], "C")
        XCTAssertEqual(result.variables["LC_CTYPE"], "UTF-8")
        XCTAssertEqual(result.variables["HTTPS_PROXY"], proxySecret)
        XCTAssertEqual(result.variables["no_proxy"], "127.0.0.1,localhost")
        XCTAssertEqual(Set(result.variables.keys), [
            "PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "HTTPS_PROXY", "no_proxy"
        ])
        XCTAssertNil(result.variables["OPENAI_API_KEY"])
        XCTAssertNil(result.variables["SSH_AUTH_SOCK"])
        XCTAssertFalse(String(describing: result).contains(proxySecret))
        XCTAssertFalse(String(reflecting: result).contains(proxySecret))
        XCTAssertTrue(String(describing: result).contains("HTTPS_PROXY"))
        var diagnosticDump = ""
        dump(result, to: &diagnosticDump)
        XCTAssertFalse(diagnosticDump.contains(proxySecret))
        XCTAssertTrue(diagnosticDump.contains("HTTPS_PROXY"))
    }

    func testNoSafePATHAndNoHOMEProduceLocaleOnlyEnvironment() throws {
        let result = try MinimalChildEnvironmentBuilder().build(
            pathEntries: ["", "relative/bin", "/invalid:entry"],
            homeDirectoryURL: nil
        )

        XCTAssertEqual(result.variables, [
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "UTF-8"
        ])
    }

    func testRelativeHOMEIsTypedFailureWithoutValueDisclosure() throws {
        let relativeHome = try XCTUnwrap(URL(string: "file:Users/private-home"))

        XCTAssertThrowsError(
            try MinimalChildEnvironmentBuilder().build(
                pathEntries: ["/usr/bin"],
                homeDirectoryURL: relativeHome
            )
        ) { error in
            XCTAssertEqual(
                error as? MinimalChildEnvironmentError,
                .homeDirectoryMustBeAbsoluteLocalFileURL
            )
            XCTAssertFalse(String(describing: error).contains("private-home"))
            XCTAssertFalse(String(reflecting: error).contains("private-home"))
        }
    }

    func testNonAllowlistedProxyKeyIsRejectedRatherThanCopied() {
        let secret = "must-never-reach-child"

        XCTAssertThrowsError(
            try MinimalChildEnvironmentBuilder().build(
                pathEntries: ["/usr/bin"],
                homeDirectoryURL: nil,
                explicitProxyEnvironment: ["PROVIDER_API_TOKEN": secret]
            )
        ) { error in
            XCTAssertEqual(
                error as? MinimalChildEnvironmentError,
                .proxyEnvironmentNotAllowlisted
            )
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertFalse(String(reflecting: error).contains(secret))
        }
    }

    func testInvalidLocaleAndProxyValuesReturnValueFreeTypedErrors() {
        XCTAssertThrowsError(
            try MinimalChildEnvironmentBuilder().build(
                pathEntries: [],
                homeDirectoryURL: nil,
                locale: CLILocaleEnvironment(lang: "bad\0locale", lcAll: nil, lcCType: nil)
            )
        ) { error in
            XCTAssertEqual(error as? MinimalChildEnvironmentError, .invalidLocaleValue)
            XCTAssertFalse(String(describing: error).contains("bad\0locale"))
        }

        XCTAssertThrowsError(
            try MinimalChildEnvironmentBuilder().build(
                pathEntries: [],
                homeDirectoryURL: nil,
                explicitProxyEnvironment: ["HTTP_PROXY": "secret\0value"]
            )
        ) { error in
            XCTAssertEqual(error as? MinimalChildEnvironmentError, .invalidProxyValue)
            XCTAssertFalse(String(describing: error).contains("secret"))
        }
    }

    func testAllAndOnlyExplicitProxyKeyCasingsAreAccepted() throws {
        let proxies = Dictionary(
            uniqueKeysWithValues: MinimalChildEnvironmentBuilder.allowedProxyKeys.map {
                ($0, "fixture-\($0)")
            }
        )
        let result = try MinimalChildEnvironmentBuilder().build(
            pathEntries: [],
            homeDirectoryURL: nil,
            locale: CLILocaleEnvironment(lang: nil, lcAll: nil, lcCType: nil),
            explicitProxyEnvironment: proxies
        )

        XCTAssertEqual(result.variables, proxies)
    }
}
