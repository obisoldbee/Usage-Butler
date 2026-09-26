import Foundation
import Security

/// Derives a requirement from code whose on-disk signature was verified first.
/// Ad-hoc requirements bind the actual local cdhash; no Team ID is invented.
public enum HistoryCodeIdentity {
    public static func requirement(for url: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw BackgroundCodeIdentityError.unverifiedSignature
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
            throw BackgroundCodeIdentityError.invalidRequirement
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            throw BackgroundCodeIdentityError.invalidRequirement
        }
        let string = text as String
        try validate(string); return string
    }
    public static func validate(_ value: String) throws {
        guard value.utf8.count <= 16_384 else { throw BackgroundCodeIdentityError.invalidRequirement }
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(value as CFString, [], &parsed) == errSecSuccess, parsed != nil else {
            throw BackgroundCodeIdentityError.invalidRequirement
        }
    }
    public enum BackgroundCodeIdentityError: Error { case unverifiedSignature, invalidRequirement }
}
