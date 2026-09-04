import Foundation
@testable import UsageButlerCore
@testable import UsageButlerDomain

actor TestClock: ClockPort {
    private struct Sleeper {
        let deadline: MonotonicInstant
        let continuation: CheckedContinuation<Void, Error>
    }

    private var current: ClockReading
    private var shouldBlockReading = false
    private var readingContinuation: CheckedContinuation<ClockReading, Never>?
    private var readingBlockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var sleepers: [UUID: Sleeper] = [:]
    private var sleepRegistrationWaiters: [
        MonotonicInstant: [CheckedContinuation<Void, Never>]
    ] = [:]

    init(
        wallTime: Date = Date(timeIntervalSince1970: 1_786_300_000),
        monotonicNanoseconds: UInt64 = 0
    ) {
        current = ClockReading(
            wallTime: wallTime,
            monotonicTime: MonotonicInstant(nanoseconds: monotonicNanoseconds)
        )
    }

    func reading() async -> ClockReading {
        if shouldBlockReading {
            shouldBlockReading = false
            return await withCheckedContinuation { continuation in
                readingContinuation = continuation
                let waiters = readingBlockedWaiters
                readingBlockedWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        return current
    }

    func blockNextReading() {
        shouldBlockReading = true
    }

    func waitUntilReadingIsBlocked() async {
        guard readingContinuation == nil else { return }
        await withCheckedContinuation { readingBlockedWaiters.append($0) }
    }

    func resumeReading() {
        let continuation = readingContinuation
        readingContinuation = nil
        continuation?.resume(returning: current)
    }

    func sleep(until deadline: MonotonicInstant) async throws {
        try Task.checkCancellation()
        guard current.monotonicTime < deadline else { return }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if current.monotonicTime >= deadline {
                    continuation.resume()
                } else {
                    sleepers[id] = Sleeper(
                        deadline: deadline,
                        continuation: continuation
                    )
                    resumeSleepRegistrationWaiters(for: deadline)
                }
            }
        } onCancel: {
            Task {
                await self.cancelSleeper(id: id)
            }
        }
    }

    func advance(to monotonicNanoseconds: UInt64) {
        precondition(monotonicNanoseconds >= current.monotonicTime.nanoseconds)
        let delta = monotonicNanoseconds - current.monotonicTime.nanoseconds
        current = ClockReading(
            wallTime: current.wallTime.addingTimeInterval(Double(delta) / 1_000_000_000),
            monotonicTime: MonotonicInstant(nanoseconds: monotonicNanoseconds)
        )

        let ready = sleepers.filter { $0.value.deadline <= current.monotonicTime }
        for (id, sleeper) in ready {
            sleepers.removeValue(forKey: id)
            sleeper.continuation.resume()
        }
    }

    func advance(by duration: RefreshDuration) {
        let deadline = RefreshDecisionEngine.adding(duration, to: current.monotonicTime)
        advance(to: deadline.nanoseconds)
    }

    func pendingSleeperCount() -> Int {
        sleepers.count
    }

    func waitUntilSleepIsRegistered(until deadline: MonotonicInstant) async {
        if sleepers.values.contains(where: { $0.deadline == deadline }) {
            return
        }

        await withCheckedContinuation { continuation in
            sleepRegistrationWaiters[deadline, default: []].append(continuation)
        }
    }

    private func cancelSleeper(id: UUID) {
        guard let sleeper = sleepers.removeValue(forKey: id) else { return }
        sleeper.continuation.resume(throwing: CancellationError())
    }

    private func resumeSleepRegistrationWaiters(for deadline: MonotonicInstant) {
        let waiters = sleepRegistrationWaiters.removeValue(forKey: deadline) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }
}

actor TestCallRecorder {
    private var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func entries() -> [String] {
        values
    }
}

actor FakeProviderAdapter: ProviderAdapter {
    nonisolated let id: ProviderID
    nonisolated let capabilities: ProviderCapabilities

    private let recorder: TestCallRecorder?
    private var discoveryResults: [DiscoveryResult]
    private var readResults: [ProviderReadResult]
    private var loginResults: [LoginResult]
    private var discoverContinuation: CheckedContinuation<DiscoveryResult, Never>?
    private var discoveryBlockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var readContinuation: CheckedContinuation<ProviderReadResult, Never>?
    private var readBlockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var loginContinuation: CheckedContinuation<LoginResult, Never>?
    private var loginBlockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var loginCancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var loginWasCancelled = false
    private var shutdownContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockDiscovery = false
    private var shouldBlockRead = false
    private var shouldBlockLogin = false
    private var shouldBlockShutdown = false
    private(set) var discoverCallCount = 0
    private(set) var readScopes: [ProviderScope] = []
    private(set) var loginMethods: [LoginMethod] = []
    private var readAuthentication: AuthenticationState?
    private(set) var authenticationCacheInvalidationCount = 0
    private(set) var shutdownCallCount = 0

    init(
        id: ProviderID,
        capabilities: ProviderCapabilities,
        recorder: TestCallRecorder? = nil,
        discoveryResults: [DiscoveryResult] = [],
        readResults: [ProviderReadResult] = [],
        loginResults: [LoginResult] = []
    ) {
        self.id = id
        self.capabilities = capabilities
        self.recorder = recorder
        self.discoveryResults = discoveryResults
        self.readResults = readResults
        self.loginResults = loginResults
    }

    func discover() async -> DiscoveryResult {
        discoverCallCount += 1
        await recorder?.record("adapter.discover")
        if shouldBlockDiscovery {
            shouldBlockDiscovery = false
            return await withCheckedContinuation { continuation in
                discoverContinuation = continuation
                let waiters = discoveryBlockedWaiters
                discoveryBlockedWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
        return discoveryResults.isEmpty
            ? .failure(ControllerFixture.failure(retryClass: .never))
            : discoveryResults.removeFirst()
    }

    func read(scope: ProviderScope) async -> ProviderReadResult {
        readScopes.append(scope)
        await recorder?.record("adapter.read")
        if shouldBlockRead {
            shouldBlockRead = false
            return await withCheckedContinuation { continuation in
                readContinuation = continuation
                let waiters = readBlockedWaiters
                readBlockedWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
        return readResults.isEmpty
            ? .failure(ControllerFixture.failure(retryClass: .never))
            : readResults.removeFirst()
    }

    func setReadAuthentication(_ authentication: AuthenticationState) {
        readAuthentication = authentication
    }

    func authenticationAfterRead() -> AuthenticationState? { readAuthentication }

    func invalidateAuthenticationCache() async {
        authenticationCacheInvalidationCount += 1
    }

    func login(method: LoginMethod) async -> LoginResult {
        loginMethods.append(method)
        await recorder?.record("adapter.login")
        if shouldBlockLogin {
            shouldBlockLogin = false
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    loginContinuation = continuation
                    let waiters = loginBlockedWaiters
                    loginBlockedWaiters.removeAll()
                    for waiter in waiters {
                        waiter.resume()
                    }
                }
            } onCancel: {
                Task { await self.recordLoginCancellation() }
            }
        }
        return loginResults.isEmpty ? .cancelled : loginResults.removeFirst()
    }

    func diagnosticSnapshot() async -> SafeProviderDiagnostic {
        SafeProviderDiagnostic(
            providerID: id,
            capturedAt: Date(timeIntervalSince1970: 1_786_300_000),
            diagnosticCode: "fake.diagnostic",
            safeFields: [:]
        )
    }

    func shutdown() async {
        shutdownCallCount += 1
        await recorder?.record("adapter.shutdown")
        if shouldBlockShutdown {
            await withCheckedContinuation { continuation in
                shutdownContinuation = continuation
            }
        }
    }

    func enqueueDiscovery(_ result: DiscoveryResult) {
        discoveryResults.append(result)
    }

    func enqueueRead(_ result: ProviderReadResult) {
        readResults.append(result)
    }

    func enqueueLogin(_ result: LoginResult) {
        loginResults.append(result)
    }

    func blockNextDiscovery() {
        shouldBlockDiscovery = true
    }

    func blockNextRead() {
        shouldBlockRead = true
    }

    func waitUntilDiscoveryIsBlocked() async {
        guard discoverContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            discoveryBlockedWaiters.append(continuation)
        }
    }

    func waitUntilReadIsBlocked() async {
        guard readContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            readBlockedWaiters.append(continuation)
        }
    }

    func blockNextLogin() {
        loginWasCancelled = false
        shouldBlockLogin = true
    }

    func waitUntilLoginIsCancelled() async {
        guard !loginWasCancelled else { return }
        await withCheckedContinuation { loginCancellationWaiters.append($0) }
    }

    private func recordLoginCancellation() {
        loginWasCancelled = true
        let waiters = loginCancellationWaiters
        loginCancellationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilLoginIsBlocked() async {
        guard loginContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            loginBlockedWaiters.append(continuation)
        }
    }

    func blockShutdown() {
        shouldBlockShutdown = true
    }

    func resumeDiscovery(with result: DiscoveryResult) {
        let continuation = discoverContinuation
        discoverContinuation = nil
        continuation?.resume(returning: result)
    }

    func resumeRead(with result: ProviderReadResult) {
        let continuation = readContinuation
        readContinuation = nil
        continuation?.resume(returning: result)
    }

    func resumeLogin(with result: LoginResult) {
        let continuation = loginContinuation
        loginContinuation = nil
        continuation?.resume(returning: result)
    }

    func resumeShutdown() {
        shouldBlockShutdown = false
        let continuation = shutdownContinuation
        shutdownContinuation = nil
        continuation?.resume()
    }
}

actor FakeProviderQuotaCache: ProviderQuotaCache {
    private let recorder: TestCallRecorder?
    private var loadResult: ProviderQuotaCacheLoadResult
    private var saveResults: [ProviderQuotaCacheWriteResult]
    private var clearResults: [ProviderQuotaCacheClearResult]
    private var clearContinuation: CheckedContinuation<Void, Never>?
    private var clearBlockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var shouldBlockClear = false
    private var shutdownContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockShutdown = false
    private(set) var loadedProviderIDs: [ProviderID] = []
    private(set) var savedData: [ProviderQuotaData] = []
    private(set) var clearedProviderIDs: [ProviderID] = []
    private(set) var shutdownCallCount = 0

    init(
        recorder: TestCallRecorder? = nil,
        loadResult: ProviderQuotaCacheLoadResult = .miss,
        saveResults: [ProviderQuotaCacheWriteResult] = [],
        clearResults: [ProviderQuotaCacheClearResult] = []
    ) {
        self.recorder = recorder
        self.loadResult = loadResult
        self.saveResults = saveResults
        self.clearResults = clearResults
    }

    func load(providerID: ProviderID) async -> ProviderQuotaCacheLoadResult {
        loadedProviderIDs.append(providerID)
        await recorder?.record("cache.load")
        return loadResult
    }

    func save(_ data: ProviderQuotaData) async -> ProviderQuotaCacheWriteResult {
        await recorder?.record("cache.save")
        savedData.append(data)
        let waiters = saveWaiters.removeValue(forKey: savedData.count) ?? []
        for waiter in waiters { waiter.resume() }
        return saveResults.isEmpty
            ? .success(writtenAt: data.fetchedAt)
            : saveResults.removeFirst()
    }

    func clear(providerID: ProviderID) async -> ProviderQuotaCacheClearResult {
        clearedProviderIDs.append(providerID)
        await recorder?.record("cache.clear")
        if shouldBlockClear {
            await withCheckedContinuation { continuation in
                clearContinuation = continuation
                let waiters = clearBlockedWaiters
                clearBlockedWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        return clearResults.isEmpty
            ? .success(clearedAt: ControllerFixture.fixedDate, removedEntry: true)
            : clearResults.removeFirst()
    }

    func shutdown() async {
        shutdownCallCount += 1
        await recorder?.record("cache.shutdown")
        if shouldBlockShutdown {
            await withCheckedContinuation { continuation in
                shutdownContinuation = continuation
            }
        }
    }

    func blockShutdown() {
        shouldBlockShutdown = true
    }

    func blockClear() {
        shouldBlockClear = true
    }

    func waitUntilClearIsBlocked() async {
        guard clearContinuation == nil else { return }
        await withCheckedContinuation { clearBlockedWaiters.append($0) }
    }

    func waitUntilSaveCount(_ count: Int) async {
        guard savedData.count < count else { return }
        await withCheckedContinuation { saveWaiters[count, default: []].append($0) }
    }

    func resumeClear() {
        shouldBlockClear = false
        let continuation = clearContinuation
        clearContinuation = nil
        continuation?.resume()
    }

    func resumeShutdown() {
        shouldBlockShutdown = false
        let continuation = shutdownContinuation
        shutdownContinuation = nil
        continuation?.resume()
    }
}

enum ControllerFixture {
    static let providerID = ProviderID.ark
    static let fixedDate = Date(timeIntervalSince1970: 1_786_300_000)

    static var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            contractVersion: "provider-contract-v0.8",
            loginMethod: .sso,
            hasOfficialDocumentation: true,
            allowsExecutableSelection: true
        )
    }

    static func initialState(now: Date = fixedDate) -> ProviderState {
        ProviderBootstrap.initialState(
            id: providerID,
            capabilities: capabilities,
            now: now
        )
    }

    static func source() -> ProviderSourceIdentity {
        ProviderSourceIdentity(
            providerID: providerID,
            adapterID: "fake.adapter",
            executableIdentity: "fake-selected-v1",
            cliVersion: "1.0.0",
            schemaVersion: "fake-v1",
            contractVersion: "provider-contract-v0.8"
        )
    }

    static func quotaData(fetchedAt: Date = fixedDate) -> ProviderQuotaData {
        ProviderQuotaData(
            providerID: providerID,
            source: source(),
            fetchedAt: fetchedAt,
            products: [],
            balances: [],
            resetEntitlements: []
        )
    }

    static func discovery(
        observedAt: Date = fixedDate,
        connection: DiscoveredConnection = .connected
    ) -> SuccessfulProviderDiscovery {
        let evidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "fake.authenticated",
                contractVersion: "provider-contract-v0.8"
            ),
            observedAt: observedAt
        )
        return SuccessfulProviderDiscovery(
            providerID: providerID,
            authority: DiscoveryAuthority(
                source: source(),
                operationID: "fake.discovery.v1"
            ),
            observedAt: observedAt,
            connection: connection,
            authentication: .healthy(evidence),
            presence: .entitled
        )
    }

    static func failure(
        retryClass: RetryClass,
        code: FailureCode = .networkUnavailable,
        diagnosticCode: String = "fake.network"
    ) -> ProviderFailure {
        ProviderFailure(
            code: code,
            retryClass: retryClass,
            userMessageKey: "provider.failure.fake",
            diagnosticCode: diagnosticCode,
            recovery: retryClass == .afterRecovery ? .login(.sso) : .retry
        )
    }
}
