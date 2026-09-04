import Foundation
import UsageButlerDomain

protocol OpenAITransportSleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousOpenAITransportSleeper: OpenAITransportSleeper, Sendable {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

enum OpenAIAppServerRequestPhase: String, Equatable, Sendable {
    case startup
    case accountRead = "account"
    case rateLimitsRead = "rate_limits"
}

private enum OpenAIAppServerRequestKind: Sendable {
    case initialize
    case accountRead
    case rateLimitsRead

    var method: String {
        switch self {
        case .initialize: "initialize"
        case .accountRead: "account/read"
        case .rateLimitsRead: "account/rateLimits/read"
        }
    }
}

private enum OpenAIParsedRPCEnvelope: Sendable {
    case notification
    case result(id: Int64, payload: Data)
    case error(id: Int64, code: Int)
}

enum OpenAIRPCEnvelopeError: Error, Equatable, Sendable {
    case invalidJSON
    case invalidEnvelope
    case invalidResponseID
    case invalidResult
}

actor OpenAIAppServerRPCSession {
    private let process: any OpenAIAppServerProcess
    private let sleeper: any OpenAITransportSleeper

    private var nextRequestID: Int64 = 1
    private var pendingRequestIDs: [Int64: OpenAIAppServerRequestPhase] = [:]
    private var activeTimeout: (token: UUID, task: Task<Void, Never>)?
    private var initialized = false
    private var terminalFailure: ProviderFailure?

    init(
        process: any OpenAIAppServerProcess,
        sleeper: any OpenAITransportSleeper
    ) {
        self.process = process
        self.sleeper = sleeper
    }

    func startAndInitialize(timeout: Duration) async -> Result<Void, ProviderFailure> {
        await withTaskCancellationHandler {
            guard terminalFailure == nil else {
                return .failure(terminalFailure ?? OpenAITransportFailure.protocolFailure(
                    diagnosticCode: "openai.transport.startup.terminal"
                ))
            }
            guard !initialized else { return .success(()) }

            beginTimeout(for: .startup, duration: timeout)
            switch await process.start() {
            case let .failure(error):
                let failure = OpenAITransportFailure.process(error, phase: .startup)
                await invalidate(with: failure)
                return .failure(failure)
            case .success:
                break
            }

            let initializeResult = await sendAndAwaitResponse(
                kind: .initialize,
                phase: .startup
            )
            switch initializeResult {
            case let .failure(failure):
                if terminalFailure == nil { await invalidate(with: failure) }
                return .failure(failure)
            case .success:
                break
            }

            let notification: Data
            do {
                notification = try Self.encodeInitializedNotification()
            } catch {
                let failure = OpenAITransportFailure.protocolFailure(
                    diagnosticCode: "openai.transport.startup.notification_encoding"
                )
                await invalidate(with: failure)
                return .failure(failure)
            }

            switch await process.writeLine(notification) {
            case let .failure(error):
                let failure = OpenAITransportFailure.process(error, phase: .startup)
                await invalidate(with: failure)
                return .failure(failure)
            case .success:
                initialized = true
                endTimeout()
                return .success(())
            }
        } onCancel: { [weak self] in
            Task { await self?.cancelActiveOperation() }
        }
    }

    func readAccount(timeout: Duration) async -> Result<Data, ProviderFailure> {
        await performRead(kind: .accountRead, phase: .accountRead, timeout: timeout)
    }

    func readRateLimits(timeout: Duration) async -> Result<Data, ProviderFailure> {
        await performRead(kind: .rateLimitsRead, phase: .rateLimitsRead, timeout: timeout)
    }

    func isUsable() -> Bool {
        initialized && terminalFailure == nil
    }

    func pendingRequestIDsForTesting() -> [Int64] {
        pendingRequestIDs.keys.sorted()
    }

    func shutdown() async {
        guard terminalFailure?.code != .shutdown else { return }
        await invalidate(with: OpenAITransportFailure.shutdown())
    }

    private func performRead(
        kind: OpenAIAppServerRequestKind,
        phase: OpenAIAppServerRequestPhase,
        timeout: Duration
    ) async -> Result<Data, ProviderFailure> {
        await withTaskCancellationHandler {
            guard initialized else {
                return .failure(terminalFailure ?? OpenAITransportFailure.protocolFailure(
                    diagnosticCode: "openai.transport.\(phase.rawValue).not_initialized"
                ))
            }
            guard terminalFailure == nil else {
                return .failure(terminalFailure ?? OpenAITransportFailure.protocolFailure(
                    diagnosticCode: "openai.transport.\(phase.rawValue).terminal"
                ))
            }

            beginTimeout(for: phase, duration: timeout)
            let result = await sendAndAwaitResponse(kind: kind, phase: phase)
            if terminalFailure == nil { endTimeout() }
            return result
        } onCancel: { [weak self] in
            Task { await self?.cancelActiveOperation() }
        }
    }

    private func sendAndAwaitResponse(
        kind: OpenAIAppServerRequestKind,
        phase: OpenAIAppServerRequestPhase
    ) async -> Result<Data, ProviderFailure> {
        let requestID: Int64
        do {
            requestID = try allocateRequestID()
        } catch {
            let failure = OpenAITransportFailure.protocolFailure(
                diagnosticCode: "openai.transport.request_id.exhausted"
            )
            await invalidate(with: failure)
            return .failure(failure)
        }

        let request: Data
        do {
            request = try Self.encodeRequest(id: requestID, kind: kind)
        } catch {
            let failure = OpenAITransportFailure.protocolFailure(
                diagnosticCode: "openai.transport.\(phase.rawValue).request_encoding"
            )
            await invalidate(with: failure)
            return .failure(failure)
        }

        pendingRequestIDs[requestID] = phase
        switch await process.writeLine(request) {
        case let .failure(error):
            pendingRequestIDs.removeValue(forKey: requestID)
            let failure = terminalFailure ?? OpenAITransportFailure.process(error, phase: phase)
            if terminalFailure == nil { await invalidate(with: failure) }
            return .failure(failure)
        case .success:
            break
        }

        while true {
            let lineResult = await process.nextLine()
            guard terminalFailure == nil else {
                pendingRequestIDs.removeValue(forKey: requestID)
                return .failure(terminalFailure ?? OpenAITransportFailure.protocolFailure(
                    diagnosticCode: "openai.transport.\(phase.rawValue).terminal"
                ))
            }

            let line: Data
            switch lineResult {
            case let .success(value):
                line = value
            case let .failure(error):
                pendingRequestIDs.removeValue(forKey: requestID)
                let failure = OpenAITransportFailure.process(error, phase: phase)
                await invalidate(with: failure)
                return .failure(failure)
            }

            let envelope: OpenAIParsedRPCEnvelope
            do {
                envelope = try Self.parseEnvelope(line)
            } catch let error as OpenAIRPCEnvelopeError {
                pendingRequestIDs.removeValue(forKey: requestID)
                let failure = OpenAITransportFailure.envelope(error, phase: phase)
                await invalidate(with: failure)
                return .failure(failure)
            } catch {
                pendingRequestIDs.removeValue(forKey: requestID)
                let failure = OpenAITransportFailure.protocolFailure(
                    diagnosticCode: "openai.transport.\(phase.rawValue).invalid_json"
                )
                await invalidate(with: failure)
                return .failure(failure)
            }

            switch envelope {
            case .notification:
                continue
            case let .result(responseID, payload):
                guard pendingRequestIDs[responseID] != nil, responseID == requestID else {
                    let failure = OpenAITransportFailure.protocolFailure(
                        diagnosticCode: "openai.transport.\(phase.rawValue).unknown_response_id"
                    )
                    await invalidate(with: failure)
                    return .failure(failure)
                }
                pendingRequestIDs.removeValue(forKey: responseID)
                return .success(payload)
            case let .error(responseID, code):
                guard pendingRequestIDs[responseID] != nil, responseID == requestID else {
                    let failure = OpenAITransportFailure.protocolFailure(
                        diagnosticCode: "openai.transport.\(phase.rawValue).unknown_response_id"
                    )
                    await invalidate(with: failure)
                    return .failure(failure)
                }
                pendingRequestIDs.removeValue(forKey: responseID)
                return .failure(OpenAITransportFailure.rpc(code: code, phase: phase))
            }
        }
    }

    private func allocateRequestID() throws -> Int64 {
        guard nextRequestID > 0, nextRequestID < .max else {
            throw OpenAIRPCEnvelopeError.invalidResponseID
        }
        let allocated = nextRequestID
        nextRequestID += 1
        return allocated
    }

    private func beginTimeout(for phase: OpenAIAppServerRequestPhase, duration: Duration) {
        endTimeout()
        let token = UUID()
        let sleeper = self.sleeper
        let task = Task { [weak self] in
            do {
                try await sleeper.sleep(for: duration)
            } catch {
                return
            }
            await self?.timeoutDidFire(token: token, phase: phase)
        }
        activeTimeout = (token, task)
    }

    private func endTimeout() {
        activeTimeout?.task.cancel()
        activeTimeout = nil
    }

    private func timeoutDidFire(token: UUID, phase: OpenAIAppServerRequestPhase) async {
        guard activeTimeout?.token == token, terminalFailure == nil else { return }
        await invalidate(with: OpenAITransportFailure.timeout(phase: phase))
    }

    private func cancelActiveOperation() async {
        guard terminalFailure == nil else { return }
        await invalidate(with: OpenAITransportFailure.cancelled())
    }

    private func invalidate(with failure: ProviderFailure) async {
        guard terminalFailure == nil else { return }
        terminalFailure = failure
        initialized = false
        pendingRequestIDs.removeAll()
        endTimeout()
        await process.close()
    }

    private static func encodeRequest(
        id: Int64,
        kind: OpenAIAppServerRequestKind
    ) throws -> Data {
        var object: [String: Any] = [
            "id": id,
            "method": kind.method
        ]
        switch kind {
        case .initialize:
            object["params"] = [
                "clientInfo": [
                    "name": "usage_butler",
                    "title": "Usage-Butler",
                    "version": "0.1.0"
                ]
            ]
        case .accountRead:
            object["params"] = ["refreshToken": false]
        case .rateLimitsRead:
            break
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func encodeInitializedNotification() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "method": "initialized",
                "params": [:]
            ],
            options: [.sortedKeys]
        )
    }

    private static func parseEnvelope(_ line: Data) throws -> OpenAIParsedRPCEnvelope {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: line)
        } catch {
            throw OpenAIRPCEnvelopeError.invalidJSON
        }
        guard let object = value as? [String: Any] else {
            throw OpenAIRPCEnvelopeError.invalidEnvelope
        }

        if object["id"] == nil {
            guard object["method"] is String else {
                throw OpenAIRPCEnvelopeError.invalidEnvelope
            }
            return .notification
        }

        guard let responseID = integer(from: object["id"]) else {
            throw OpenAIRPCEnvelopeError.invalidResponseID
        }
        let result = object["result"]
        let error = object["error"]
        guard (result == nil) != (error == nil) else {
            throw OpenAIRPCEnvelopeError.invalidEnvelope
        }

        if let result {
            guard result is [String: Any], JSONSerialization.isValidJSONObject(result) else {
                throw OpenAIRPCEnvelopeError.invalidResult
            }
            let payload = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            return .result(id: responseID, payload: payload)
        }

        guard let errorObject = error as? [String: Any],
              let errorCode = integer(from: errorObject["code"]),
              errorCode >= Int64(Int.min),
              errorCode <= Int64(Int.max) else {
            throw OpenAIRPCEnvelopeError.invalidEnvelope
        }
        return .error(id: responseID, code: Int(errorCode))
    }

    private static func integer(from value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "c" else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int64.min),
              double < Double(Int64.max) else {
            return nil
        }
        return number.int64Value
    }
}

enum OpenAITransportFailure {
    static func timeout(phase: OpenAIAppServerRequestPhase) -> ProviderFailure {
        ProviderFailure(
            code: .timedOut,
            retryClass: .backoff,
            userMessageKey: "provider.failure.timed_out",
            diagnosticCode: "openai.transport.\(phase.rawValue).timeout",
            recovery: .retry
        )
    }

    static func cancelled() -> ProviderFailure {
        ProviderFailure(
            code: .cancelled,
            retryClass: .never,
            userMessageKey: "provider.failure.cancelled",
            diagnosticCode: "openai.transport.cancelled",
            recovery: nil
        )
    }

    static func shutdown() -> ProviderFailure {
        ProviderFailure(
            code: .shutdown,
            retryClass: .never,
            userMessageKey: "provider.failure.shutdown",
            diagnosticCode: "openai.transport.shutdown",
            recovery: nil
        )
    }

    static func protocolFailure(diagnosticCode: String) -> ProviderFailure {
        ProviderFailure(
            code: .protocolViolation,
            retryClass: .backoff,
            userMessageKey: "provider.failure.protocol_violation",
            diagnosticCode: diagnosticCode,
            recovery: .retry
        )
    }

    static func envelope(
        _ error: OpenAIRPCEnvelopeError,
        phase: OpenAIAppServerRequestPhase
    ) -> ProviderFailure {
        let suffix = switch error {
        case .invalidJSON: "invalid_json"
        case .invalidEnvelope: "invalid_envelope"
        case .invalidResponseID: "invalid_response_id"
        case .invalidResult: "invalid_result"
        }
        return protocolFailure(
            diagnosticCode: "openai.transport.\(phase.rawValue).\(suffix)"
        )
    }

    static func rpc(code: Int, phase: OpenAIAppServerRequestPhase) -> ProviderFailure {
        ProviderFailure(
            code: .serviceUnavailable,
            retryClass: .backoff,
            userMessageKey: "provider.failure.service_unavailable",
            diagnosticCode: "openai.transport.\(phase.rawValue).rpc_error.\(code)",
            recovery: .retry
        )
    }

    static func process(
        _ error: OpenAIAppServerProcessError,
        phase: OpenAIAppServerRequestPhase
    ) -> ProviderFailure {
        switch error {
        case .missingExecutable:
            return ProviderFailure(
                code: .missingExecutable,
                retryClass: .afterRecovery,
                userMessageKey: "provider.failure.missing_executable",
                diagnosticCode: "openai.transport.startup.missing_executable",
                recovery: .selectExecutable
            )
        case .permissionDenied:
            return ProviderFailure(
                code: .permissionDenied,
                retryClass: .afterRecovery,
                userMessageKey: "provider.failure.permission_denied",
                diagnosticCode: "openai.transport.startup.permission_denied",
                recovery: .selectExecutable
            )
        case .endOfFile:
            return ProviderFailure(
                code: .sessionEOF,
                retryClass: .backoff,
                userMessageKey: "provider.failure.session_eof",
                diagnosticCode: "openai.transport.\(phase.rawValue).session_eof",
                recovery: .retry
            )
        case .standardOutputTruncatedLine:
            return protocolFailure(
                diagnosticCode: "openai.transport.\(phase.rawValue).truncated_json"
            )
        case .standardOutputLineTooLarge:
            return ProviderFailure(
                code: .processFailed,
                retryClass: .never,
                userMessageKey: "provider.failure.process_output_limit",
                diagnosticCode: "openai.transport.stdout.line_limit",
                recovery: nil
            )
        case .standardOutputQueueOverflow:
            return ProviderFailure(
                code: .processFailed,
                retryClass: .never,
                userMessageKey: "provider.failure.process_output_limit",
                diagnosticCode: "openai.transport.stdout.queue_limit",
                recovery: nil
            )
        case .standardErrorByteLimit:
            return ProviderFailure(
                code: .processFailed,
                retryClass: .never,
                userMessageKey: "provider.failure.process_output_limit",
                diagnosticCode: "openai.transport.stderr.byte_limit",
                recovery: nil
            )
        case .standardErrorLineLimit:
            return ProviderFailure(
                code: .processFailed,
                retryClass: .never,
                userMessageKey: "provider.failure.process_output_limit",
                diagnosticCode: "openai.transport.stderr.line_limit",
                recovery: nil
            )
        case .closed:
            return ProviderFailure(
                code: .sessionEOF,
                retryClass: .backoff,
                userMessageKey: "provider.failure.session_eof",
                diagnosticCode: "openai.transport.\(phase.rawValue).session_closed",
                recovery: .retry
            )
        case .notStarted, .launchFailed, .writeFailed, .standardOutputReadFailed,
             .standardErrorReadFailed:
            return ProviderFailure(
                code: .processFailed,
                retryClass: .backoff,
                userMessageKey: "provider.failure.process_failed",
                diagnosticCode: "openai.transport.\(phase.rawValue).process_failed",
                recovery: .retry
            )
        }
    }
}
