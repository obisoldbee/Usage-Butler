import Foundation
import UsageButlerDomain

public struct OpenAIAppServerTransportConfiguration: Equatable, Sendable {
    public let executableURL: URL
    public let homeDirectoryURL: URL
    public let sourceIdentity: ProviderSourceIdentity
    public let explicitProxyEnvironment: [String: String]
    public let startupTimeout: Duration
    public let accountReadTimeout: Duration
    public let rateLimitsReadTimeout: Duration

    public init(
        executableURL: URL,
        homeDirectoryURL: URL,
        sourceIdentity: ProviderSourceIdentity,
        explicitProxyEnvironment: [String: String] = [:],
        startupTimeout: Duration = .seconds(15),
        accountReadTimeout: Duration = .seconds(15),
        rateLimitsReadTimeout: Duration = .seconds(30)
    ) {
        self.executableURL = executableURL
        self.homeDirectoryURL = homeDirectoryURL
        self.sourceIdentity = sourceIdentity
        self.explicitProxyEnvironment = explicitProxyEnvironment
        self.startupTimeout = startupTimeout
        self.accountReadTimeout = accountReadTimeout
        self.rateLimitsReadTimeout = rateLimitsReadTimeout
    }
}

public enum OpenAIProxyEnvironmentResolver {
    private static let allowlistedKeys: Set<String> = [
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "NO_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "no_proxy"
    ]

    public static func resolve(
        environment: [String: String]
    ) -> [String: String] {
        environment.reduce(into: [:]) { resolved, entry in
            guard isAllowlisted(entry.key) else { return }
            resolved[entry.key] = entry.value
        }
    }

    static func isAllowlisted(_ key: String) -> Bool {
        allowlistedKeys.contains(key)
    }
}

/// Persistent, read-only Codex app-server transport. App composition owns the
/// transport and must call `shutdown()` during application termination.
public actor OpenAIAppServerTransport: OpenAIAppServerReader {
    public nonisolated let sourceIdentity: ProviderSourceIdentity

    private let configuration: OpenAIAppServerTransportConfiguration
    private let launchConfiguration: Result<OpenAIAppServerLaunchConfiguration, ProviderFailure>
    private let processFactory: any OpenAIAppServerProcessFactory
    private let sleeper: any OpenAITransportSleeper

    private var session: OpenAIAppServerRPCSession?
    private var isShutdown = false
    private var operationIsRunning = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(configuration: OpenAIAppServerTransportConfiguration) {
        self.init(
            configuration: configuration,
            processFactory: FoundationOpenAIAppServerProcessFactory(),
            sleeper: ContinuousOpenAITransportSleeper()
        )
    }

    init(
        configuration: OpenAIAppServerTransportConfiguration,
        processFactory: any OpenAIAppServerProcessFactory,
        sleeper: any OpenAITransportSleeper
    ) {
        self.configuration = configuration
        sourceIdentity = configuration.sourceIdentity
        launchConfiguration = OpenAIAppServerEnvironmentBuilder.makeLaunchConfiguration(
            configuration
        )
        self.processFactory = processFactory
        self.sleeper = sleeper
    }

    public func readAccount() async -> Result<Data, ProviderFailure> {
        await performRead(.accountRead)
    }

    public func readRateLimits() async -> Result<Data, ProviderFailure> {
        await performRead(.rateLimitsRead)
    }

    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        let activeSession = session
        session = nil
        await activeSession?.shutdown()
    }

    private enum ReadKind {
        case accountRead
        case rateLimitsRead
    }

    private func performRead(_ kind: ReadKind) async -> Result<Data, ProviderFailure> {
        await acquireOperation()
        defer { releaseOperation() }

        guard !isShutdown else {
            return .failure(OpenAITransportFailure.shutdown())
        }
        guard !Task.isCancelled else {
            return .failure(OpenAITransportFailure.cancelled())
        }
        guard sourceIdentity.providerID == .openAI else {
            return .failure(Self.invalidIdentityFailure())
        }

        let activeSession: OpenAIAppServerRPCSession
        switch await ensureInitializedSession() {
        case let .failure(failure):
            return .failure(failure)
        case let .success(value):
            activeSession = value
        }

        let result: Result<Data, ProviderFailure>
        switch kind {
        case .accountRead:
            result = await activeSession.readAccount(timeout: configuration.accountReadTimeout)
        case .rateLimitsRead:
            result = await activeSession.readRateLimits(
                timeout: configuration.rateLimitsReadTimeout
            )
        }

        if !(await activeSession.isUsable()), session === activeSession {
            session = nil
        }
        return result
    }

    private func ensureInitializedSession() async -> Result<OpenAIAppServerRPCSession, ProviderFailure> {
        if let session, await session.isUsable() {
            return .success(session)
        }
        if let stale = session {
            session = nil
            await stale.shutdown()
        }

        guard case let .success(launchConfiguration) = launchConfiguration else {
            guard case let .failure(failure) = launchConfiguration else {
                return .failure(OpenAITransportFailure.protocolFailure(
                    diagnosticCode: "openai.transport.configuration.invalid"
                ))
            }
            return .failure(failure)
        }

        let process = processFactory.makeProcess(configuration: launchConfiguration)
        let candidate = OpenAIAppServerRPCSession(process: process, sleeper: sleeper)
        session = candidate

        let startup = await candidate.startAndInitialize(timeout: configuration.startupTimeout)
        switch startup {
        case .success:
            guard !isShutdown else {
                session = nil
                await candidate.shutdown()
                return .failure(OpenAITransportFailure.shutdown())
            }
            return .success(candidate)
        case let .failure(failure):
            if session === candidate { session = nil }
            return .failure(failure)
        }
    }

    private func acquireOperation() async {
        if !operationIsRunning {
            operationIsRunning = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty {
            operationIsRunning = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }

    private static func invalidIdentityFailure() -> ProviderFailure {
        ProviderFailure(
            code: .identityMismatch,
            retryClass: .never,
            userMessageKey: "provider.failure.identity-mismatch",
            diagnosticCode: "openai.transport.source_identity.invalid",
            recovery: nil
        )
    }
}

enum OpenAIAppServerEnvironmentBuilder {
    static func makeLaunchConfiguration(
        _ configuration: OpenAIAppServerTransportConfiguration
    ) -> Result<OpenAIAppServerLaunchConfiguration, ProviderFailure> {
        let executablePath = configuration.executableURL.path
        guard configuration.executableURL.isFileURL,
              !executablePath.isEmpty,
              (executablePath as NSString).isAbsolutePath else {
            return .failure(invalidExecutableFailure())
        }

        let homePath = configuration.homeDirectoryURL.path
        guard configuration.homeDirectoryURL.isFileURL,
              !homePath.isEmpty,
              (homePath as NSString).isAbsolutePath,
              !executablePath.utf8.contains(0),
              !homePath.utf8.contains(0),
              configuration.startupTimeout > .zero,
              configuration.accountReadTimeout > .zero,
              configuration.rateLimitsReadTimeout > .zero else {
            return .failure(invalidConfigurationFailure())
        }

        guard configuration.explicitProxyEnvironment.allSatisfy({ key, value in
            OpenAIProxyEnvironmentResolver.isAllowlisted(key)
                && !key.contains("=")
                && !key.utf8.contains(0)
                && !value.utf8.contains(0)
        }) else {
            return .failure(invalidEnvironmentFailure())
        }

        let executableDirectory = (executablePath as NSString).deletingLastPathComponent
        let fixedSearchDirectories = [
            executableDirectory,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        var seenDirectories: Set<String> = []
        let path = fixedSearchDirectories
            .filter { !$0.isEmpty && seenDirectories.insert($0).inserted }
            .joined(separator: ":")

        var environment: [String: String] = [
            "PATH": path,
            "HOME": configuration.homeDirectoryURL.standardizedFileURL.path,
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "UTF-8"
        ]
        for (key, value) in configuration.explicitProxyEnvironment {
            environment[key] = value
        }

        return .success(
            OpenAIAppServerLaunchConfiguration(
                executableURL: configuration.executableURL.standardizedFileURL,
                environment: environment
            )
        )
    }

    private static func invalidExecutableFailure() -> ProviderFailure {
        ProviderFailure(
            code: .missingExecutable,
            retryClass: .afterRecovery,
            userMessageKey: "provider.failure.missing_executable",
            diagnosticCode: "openai.transport.executable.absolute_file_url_required",
            recovery: .selectExecutable
        )
    }

    private static func invalidConfigurationFailure() -> ProviderFailure {
        ProviderFailure(
            code: .processFailed,
            retryClass: .never,
            userMessageKey: "provider.failure.invalid_process_request",
            diagnosticCode: "openai.transport.configuration.invalid",
            recovery: nil
        )
    }

    private static func invalidEnvironmentFailure() -> ProviderFailure {
        ProviderFailure(
            code: .processFailed,
            retryClass: .never,
            userMessageKey: "provider.failure.invalid_process_request",
            diagnosticCode: "openai.transport.environment.not_allowlisted",
            recovery: nil
        )
    }
}
