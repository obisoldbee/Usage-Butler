import Darwin
import UsageButlerDomain

enum ProviderQuotaCacheFailure {
    static func corrupt(_ diagnosticCode: String) -> ProviderFailure {
        ProviderFailure(
            code: .cacheCorrupt,
            retryClass: .never,
            userMessageKey: "provider.failure.cache-corrupt",
            diagnosticCode: diagnosticCode,
            recovery: nil
        )
    }

    static func unsupportedSchema(_ diagnosticCode: String) -> ProviderFailure {
        ProviderFailure(
            code: .schemaMismatch,
            retryClass: .never,
            userMessageKey: "provider.failure.cache-schema",
            diagnosticCode: diagnosticCode,
            recovery: nil
        )
    }

    static func identityMismatch(_ diagnosticCode: String) -> ProviderFailure {
        ProviderFailure(
            code: .identityMismatch,
            retryClass: .never,
            userMessageKey: "provider.failure.identity-mismatch",
            diagnosticCode: diagnosticCode,
            recovery: nil
        )
    }

    static func permission(_ diagnosticCode: String) -> ProviderFailure {
        ProviderFailure(
            code: .permissionDenied,
            retryClass: .afterRecovery,
            userMessageKey: "provider.failure.cache-permission",
            diagnosticCode: diagnosticCode,
            recovery: nil
        )
    }

    static func unavailable(_ diagnosticCode: String) -> ProviderFailure {
        ProviderFailure(
            code: .cacheUnavailable,
            retryClass: .backoff,
            userMessageKey: "provider.failure.cache-unavailable",
            diagnosticCode: diagnosticCode,
            recovery: .retry
        )
    }

    static func rejected(_ diagnosticCode: String) -> ProviderFailure {
        ProviderFailure(
            code: .cacheUnavailable,
            retryClass: .never,
            userMessageKey: "provider.failure.cache-unavailable",
            diagnosticCode: diagnosticCode,
            recovery: nil
        )
    }

    static func shutdown() -> ProviderFailure {
        ProviderFailure(
            code: .shutdown,
            retryClass: .never,
            userMessageKey: "provider.failure.shutdown",
            diagnosticCode: "cache.client.shutdown",
            recovery: nil
        )
    }

    static func io(operation: String, errorNumber: Int32 = errno) -> ProviderFailure {
        if errorNumber == EACCES || errorNumber == EPERM {
            return permission("cache.\(operation).permission_denied")
        }
        return unavailable("cache.\(operation).io_\(errorNumber)")
    }
}
