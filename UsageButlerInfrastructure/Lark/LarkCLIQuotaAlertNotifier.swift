import Foundation
import UsageButlerCore
import UsageButlerDomain

public enum LarkCLIQuotaAlertAvailability: Equatable, Sendable {
    case ready
    case needsSetup
    case unavailable
}

public enum LarkQuotaAlertConfiguration {
    public static func validatedChatID(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.utf8.count <= 256 else {
            return nil
        }

        let disallowedCharacters = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
        guard trimmed.rangeOfCharacter(from: disallowedCharacters) == nil else {
            return nil
        }
        return trimmed
    }
}

/// Performs the CLI's local, read-only auth-status check for the Bot identity
/// used by quota alerts. It never starts login and never sends a message.
public actor LarkCLIQuotaAlertStatusReader {
    private struct Envelope: Decodable {
        struct Identities: Decodable {
            struct Bot: Decodable {
                let status: String
                let available: Bool
            }

            let bot: Bot?
        }

        let ok: Bool?
        let identities: Identities?
    }

    private let processClient: any ChildProcessClient
    private let executableURL: URL
    private let environment: [String: String]
    private let isDestinationConfigured: Bool

    public init(
        processClient: any ChildProcessClient,
        executableURL: URL,
        baseEnvironment: [String: String],
        isDestinationConfigured: Bool
    ) {
        self.processClient = processClient
        self.executableURL = executableURL
        self.environment = larkQuotaAlertEnvironment(
            baseEnvironment: baseEnvironment
        )
        self.isDestinationConfigured = isDestinationConfigured
    }

    public func read() async -> LarkCLIQuotaAlertAvailability {
        let request = ChildProcessRequest(
            executableURL: executableURL,
            arguments: ["auth", "status", "--json"],
            environment: environment,
            standardInput: nil,
            limits: ChildProcessLimits(
                timeout: LarkCLIQuotaAlertNotifier.Contract.timeout,
                standardOutputByteLimit: LarkCLIQuotaAlertNotifier.Contract.standardOutputByteLimit,
                standardErrorByteLimit: LarkCLIQuotaAlertNotifier.Contract.standardErrorByteLimit,
                lineLimit: LarkCLIQuotaAlertNotifier.Contract.lineLimit
            )
        )

        guard case let .success(output) = await processClient.run(request),
              let envelope = try? JSONDecoder().decode(
                  Envelope.self,
                  from: output.standardOutput
              ) else {
            return .unavailable
        }
        if let bot = envelope.identities?.bot {
            guard bot.status == "ready" && bot.available else {
                return .needsSetup
            }
            return isDestinationConfigured ? .ready : .needsSetup
        }
        return envelope.ok == false ? .needsSetup : .unavailable
    }
}

/// Delivers quota-exhaustion alerts to a Feishu chat via the local
/// `lark-cli` executable.
///
/// Credentials never enter the app: the CLI authenticates from its own
/// login state under the user's home directory. The success contract is
/// exit status 0 (enforced by the process client) plus a stdout JSON
/// envelope with `ok == true`; anything else is a typed failure.
public actor LarkCLIQuotaAlertNotifier: QuotaAlertNotifier {
    public enum Contract {
        public static let timeout: Duration = .seconds(20)
        public static let standardOutputByteLimit = 64 * 1024
        public static let standardErrorByteLimit = 16 * 1024
        public static let lineLimit = 400

        /// Notification-suppression flags; they carry no credential value.
        public static let environmentFlags: [String: String] = [
            "LARKSUITE_CLI_NO_UPDATE_NOTIFIER": "1",
            "LARKSUITE_CLI_NO_SKILLS_NOTIFIER": "1"
        ]
    }

    private struct Envelope: Decodable {
        let ok: Bool
    }

    private let processClient: any ChildProcessClient
    private let executableURL: URL
    private let environment: [String: String]
    private let chatID: String

    public init?(
        processClient: any ChildProcessClient,
        executableURL: URL,
        baseEnvironment: [String: String],
        chatID: String
    ) {
        guard let chatID = LarkQuotaAlertConfiguration.validatedChatID(chatID) else {
            return nil
        }
        self.processClient = processClient
        self.executableURL = executableURL
        self.environment = larkQuotaAlertEnvironment(
            baseEnvironment: baseEnvironment
        )
        self.chatID = chatID
    }

    public func prepare() async {}

    public func send(_ payload: QuotaAlertPayload) async -> Result<Void, ProviderFailure> {
        let text = ([payload.title] + payload.bodyLines + ["-- 额度管家 Usage-Butler"])
            .joined(separator: "\n")
        let request = ChildProcessRequest(
            executableURL: executableURL,
            arguments: [
                "im", "+messages-send",
                "--as", "bot",
                "--chat-id", chatID,
                "--text", text,
                "--format", "json"
            ],
            environment: environment,
            standardInput: nil,
            limits: ChildProcessLimits(
                timeout: Contract.timeout,
                standardOutputByteLimit: Contract.standardOutputByteLimit,
                standardErrorByteLimit: Contract.standardErrorByteLimit,
                lineLimit: Contract.lineLimit
            )
        )

        switch await processClient.run(request) {
        case let .failure(failure):
            return .failure(failure)
        case let .success(output):
            guard let envelope = try? JSONDecoder().decode(
                Envelope.self,
                from: output.standardOutput
            ), envelope.ok else {
                return .failure(Self.rejected)
            }
            return .success(())
        }
    }

    private static let rejected = ProviderFailure(
        code: .processFailed,
        retryClass: .backoff,
        userMessageKey: "quota.alert.lark.delivery_rejected",
        diagnosticCode: "quotaAlert.lark.ok_false",
        recovery: .retry
    )
}

private func larkQuotaAlertEnvironment(
    baseEnvironment: [String: String]
) -> [String: String] {
    LarkCLIQuotaAlertNotifier.Contract.environmentFlags.merging(
        baseEnvironment
    ) { _, baseValue in baseValue }
}
