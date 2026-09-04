import Darwin
import Foundation
import UsageButlerCore
import UsageButlerDomain

/// A shell-free, one-request-per-process implementation of `ChildProcessClient`.
///
/// The actor owns only processes it launches. A termination observer is installed before launch,
/// and every terminal path awaits that observation before the request completes, so a completed
/// request has reaped its child.
public actor OneShotChildProcessClient: ChildProcessClient {
    private var acceptsNewChildren = true
    private var activeExecutions: [UUID: ManagedProcessExecution] = [:]
    private let terminationGracePeriod: Duration

    public init(terminationGracePeriod: Duration = .milliseconds(150)) {
        self.terminationGracePeriod = min(max(terminationGracePeriod, .zero), .seconds(1))
    }

    public func run(
        _ request: ChildProcessRequest
    ) async -> Result<ChildProcessOutput, ProviderFailure> {
        guard acceptsNewChildren else {
            return .failure(ProcessFailure.shutdown())
        }
        if let failure = ProcessRequestValidator.validate(request) {
            return .failure(failure)
        }

        let executionID = UUID()
        let execution = ManagedProcessExecution(
            request: request,
            terminationGracePeriod: terminationGracePeriod
        )
        activeExecutions[executionID] = execution

        let result = await withTaskCancellationHandler {
            await execution.execute()
        } onCancel: {
            execution.cancelFromAnyContext()
        }

        activeExecutions.removeValue(forKey: executionID)
        return result
    }

    public func shutdown() async {
        acceptsNewChildren = false
        let snapshot = activeExecutions

        await withTaskGroup(of: Void.self) { group in
            for execution in snapshot.values {
                group.addTask {
                    await execution.stopAndWait(reason: .shutdown)
                }
            }
        }

        for executionID in snapshot.keys {
            activeExecutions.removeValue(forKey: executionID)
        }
    }

    // Internal observability is intentionally PID-only and test-only. No arguments,
    // environment values, stdin, stdout, or stderr are exposed through this surface.
    func activeProcessCountForTesting() -> Int {
        activeExecutions.count
    }

    func activeProcessIDsForTesting() async -> [pid_t] {
        var processIDs: [pid_t] = []
        for execution in activeExecutions.values {
            if let processID = await execution.currentProcessID() {
                processIDs.append(processID)
            }
        }
        return processIDs.sorted()
    }
}

private actor ManagedProcessExecution {
    private let request: ChildProcessRequest
    private let terminationGracePeriod: Duration
    private let completionSignal = ProcessExecutionCompletionSignal()

    private var processBox: SendableProcessBox?
    private var processID: pid_t?
    private var terminationTask: Task<ProcessTerminationSnapshot, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var forceKillTask: Task<Void, Never>?
    private var ioCancellation: ProcessIOCancellation?
    private var requestedStop: ProcessStopReason?
    private var wasReaped = false

    init(request: ChildProcessRequest, terminationGracePeriod: Duration) {
        self.request = request
        self.terminationGracePeriod = terminationGracePeriod
    }

    nonisolated func cancelFromAnyContext() {
        Task {
            await requestStop(.cancelled)
        }
    }

    func currentProcessID() -> pid_t? {
        guard !wasReaped else { return nil }
        return processID
    }

    func execute() async -> Result<ChildProcessOutput, ProviderFailure> {
        defer { completionSignal.signal() }
        if let requestedStop {
            return .failure(ProcessFailure.forStopReason(requestedStop))
        }

        let process = Process()
        let processBox = SendableProcessBox(process)
        let terminationLatch = ProcessTerminationLatch()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        let standardInputPipe = request.standardInput == nil ? nil : Pipe()
        ioCancellation = ProcessIOCancellation(
            handles: [
                standardOutputPipe.fileHandleForReading,
                standardErrorPipe.fileHandleForReading,
                standardInputPipe?.fileHandleForWriting
            ].compactMap { $0 }
        )

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        // Assignment replaces Foundation's inherited environment. No parent values are merged.
        process.environment = request.environment
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        if let standardInputPipe {
            process.standardInput = standardInputPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.terminationHandler = { terminatedProcess in
            let snapshot = ProcessTerminationSnapshot(terminatedProcess)
            Task {
                await terminationLatch.signal(snapshot)
            }
        }

        let outputCollector = BoundedProcessOutputCollector(
            byteLimit: request.limits.standardOutputByteLimit,
            lineLimit: request.limits.lineLimit,
            stream: .standardOutput,
            onViolation: limitCallback()
        )
        let errorCollector = BoundedRedactedStandardErrorCollector(
            byteLimit: request.limits.standardErrorByteLimit,
            lineLimit: request.limits.lineLimit,
            homePaths: [
                request.environment["HOME"],
                FileManager.default.homeDirectoryForCurrentUser.path
            ].compactMap { $0 },
            onViolation: limitCallback()
        )

        let outputReader = Task.detached(priority: .utility) {
            ProcessIO.drain(
                SendableFileHandleBox(standardOutputPipe.fileHandleForReading),
                consume: outputCollector.accept,
                finish: outputCollector.finish
            )
        }
        let errorReader = Task.detached(priority: .utility) {
            ProcessIO.drain(
                SendableFileHandleBox(standardErrorPipe.fileHandleForReading),
                consume: errorCollector.accept,
                finish: errorCollector.finish
            )
        }

        do {
            try process.run()
        } catch {
            ProcessIO.closeQuietly(standardOutputPipe.fileHandleForWriting)
            ProcessIO.closeQuietly(standardErrorPipe.fileHandleForWriting)
            if let standardInputPipe {
                ProcessIO.closeQuietly(standardInputPipe.fileHandleForReading)
                ProcessIO.closeQuietly(standardInputPipe.fileHandleForWriting)
            }
            _ = await outputReader.value
            _ = await errorReader.value
            return .failure(ProcessFailure.launch(error))
        }

        self.processBox = processBox
        processID = process.processIdentifier

        // The child inherited duplicates during spawn; closing the parent's unused ends is
        // necessary for EOF and for a blocked stdin writer to unblock after child termination.
        ProcessIO.closeQuietly(standardOutputPipe.fileHandleForWriting)
        ProcessIO.closeQuietly(standardErrorPipe.fileHandleForWriting)
        if let standardInputPipe {
            ProcessIO.closeQuietly(standardInputPipe.fileHandleForReading)
        }

        let terminationTask = Task {
            await terminationLatch.wait()
        }
        self.terminationTask = terminationTask

        let inputWriter: Task<ProcessIOResult, Never>?
        if let standardInput = request.standardInput, let standardInputPipe {
            inputWriter = Task.detached(priority: .utility) {
                ProcessIO.write(
                    standardInput,
                    to: SendableFileHandleBox(standardInputPipe.fileHandleForWriting)
                )
            }
        } else {
            inputWriter = nil
        }

        let timeout = request.limits.timeout
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.requestStop(.timedOut)
        }
        self.timeoutTask = timeoutTask

        let termination = await terminationTask.value
        wasReaped = true
        forceKillTask?.cancel()

        let outputReadResult = await outputReader.value
        let errorReadResult = await errorReader.value
        let inputWriteResult = await inputWriter?.value
        timeoutTask.cancel()
        ioCancellation = nil

        if let requestedStop {
            return .failure(ProcessFailure.forStopReason(requestedStop))
        }
        if Task.isCancelled {
            return .failure(ProcessFailure.cancelled())
        }
        if let violation = outputCollector.violation ?? errorCollector.violation {
            return .failure(ProcessFailure.outputLimit(violation))
        }
        if outputReadResult == .failed {
            return .failure(ProcessFailure.io("process.stdout.read_failed"))
        }
        if errorReadResult == .failed {
            return .failure(ProcessFailure.io("process.stderr.read_failed"))
        }
        if inputWriteResult == .failed {
            return .failure(ProcessFailure.io("process.stdin.write_failed"))
        }

        switch termination {
        case let .exited(code) where code == 0:
            return .success(
                ChildProcessOutput(
                    termination: .exited(code: code),
                    standardOutput: outputCollector.output,
                    redactedStandardError: errorCollector.output
                )
            )
        case let .exited(code):
            if request.nonZeroExitPolicy == .returnBoundedOutput {
                return .success(
                    ChildProcessOutput(
                        termination: .exited(code: code),
                        standardOutput: outputCollector.output,
                        redactedStandardError: errorCollector.output
                    )
                )
            }
            return .failure(ProcessFailure.nonZeroExit(code))
        case let .signalled(signal):
            return .failure(ProcessFailure.unexpectedSignal(signal))
        case let .unknown(status):
            return .failure(ProcessFailure.unknownTermination(status))
        }
    }

    func stopAndWait(reason: ProcessStopReason) async {
        requestStop(reason)
        await completionSignal.wait()
    }

    private func limitCallback() -> @Sendable (ProcessOutputLimitViolation) -> Void {
        { [weak self] violation in
            Task {
                await self?.requestStop(.outputLimit(violation))
            }
        }
    }

    private func requestStop(_ reason: ProcessStopReason) {
        guard requestedStop == nil else { return }
        requestedStop = reason
        ioCancellation?.cancel()

        guard
            let processBox,
            let processID,
            processBox.process.isRunning
        else {
            return
        }

        processBox.process.terminate()
        let grace = terminationGracePeriod
        forceKillTask = Task { [weak self] in
            do {
                try await Task.sleep(for: grace)
            } catch {
                return
            }
            await self?.forceKillIfStillOwnedAndRunning(processID)
        }
    }

    private func forceKillIfStillOwnedAndRunning(_ candidateProcessID: pid_t) {
        guard
            processID == candidateProcessID,
            let processBox,
            processBox.process.isRunning
        else {
            return
        }
        _ = Darwin.kill(candidateProcessID, SIGKILL)
    }
}

private final class SendableProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

private final class SendableFileHandleBox: @unchecked Sendable {
    let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }
}

private final class ProcessIOCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [FileHandle]?

    init(handles: [FileHandle]) {
        self.handles = handles
    }

    func cancel() {
        lock.lock()
        let handles = handles
        self.handles = nil
        lock.unlock()

        for handle in handles ?? [] {
            ProcessIO.closeQuietly(handle)
        }
    }
}

private final class ProcessExecutionCompletionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isComplete = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        guard !isComplete else {
            lock.unlock()
            return
        }
        isComplete = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()

        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isComplete {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private enum ProcessTerminationSnapshot: Sendable {
    case exited(Int32)
    case signalled(Int32)
    case unknown(Int32)

    init(_ process: Process) {
        switch process.terminationReason {
        case .exit:
            self = .exited(process.terminationStatus)
        case .uncaughtSignal:
            self = .signalled(process.terminationStatus)
        @unknown default:
            self = .unknown(process.terminationStatus)
        }
    }
}

private actor ProcessTerminationLatch {
    private var result: ProcessTerminationSnapshot?
    private var waiters: [CheckedContinuation<ProcessTerminationSnapshot, Never>] = []

    func signal(_ result: ProcessTerminationSnapshot) {
        guard self.result == nil else { return }
        self.result = result
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume(returning: result)
        }
    }

    func wait() async -> ProcessTerminationSnapshot {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private enum ProcessStopReason: Sendable {
    case timedOut
    case cancelled
    case shutdown
    case outputLimit(ProcessOutputLimitViolation)
}

enum ProcessStream: String, Sendable {
    case standardOutput = "stdout"
    case standardError = "stderr"
}

enum ProcessLimitKind: String, Sendable {
    case bytes = "byte_limit"
    case lines = "line_limit"
}

struct ProcessOutputLimitViolation: Equatable, Sendable {
    let stream: ProcessStream
    let kind: ProcessLimitKind
}

private enum ProcessIOResult: Sendable {
    case succeeded
    case failed
}

private enum ProcessIO {
    static let chunkSize = 16 * 1024

    static func drain(
        _ fileHandleBox: SendableFileHandleBox,
        consume: @Sendable (Data) -> Void,
        finish: @Sendable () -> Void
    ) -> ProcessIOResult {
        defer {
            finish()
            closeQuietly(fileHandleBox.handle)
        }

        do {
            while let data = try fileHandleBox.handle.read(upToCount: chunkSize), !data.isEmpty {
                consume(data)
            }
            return .succeeded
        } catch {
            return .failed
        }
    }

    static func write(
        _ data: Data,
        to fileHandleBox: SendableFileHandleBox
    ) -> ProcessIOResult {
        defer { closeQuietly(fileHandleBox.handle) }
        do {
            if !data.isEmpty {
                try fileHandleBox.handle.write(contentsOf: data)
            }
            return .succeeded
        } catch {
            return .failed
        }
    }

    static func closeQuietly(_ handle: FileHandle) {
        try? handle.close()
    }
}

final class BoundedProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let byteLimit: Int
    private let lineLimit: Int
    private let stream: ProcessStream
    private let onViolation: @Sendable (ProcessOutputLimitViolation) -> Void

    private var storage = Data()
    private var completedLineCount = 0
    private var hasBytes = false
    private var endsInNewline = false
    private var storedViolation: ProcessOutputLimitViolation?

    init(
        byteLimit: Int,
        lineLimit: Int,
        stream: ProcessStream,
        onViolation: @escaping @Sendable (ProcessOutputLimitViolation) -> Void
    ) {
        self.byteLimit = byteLimit
        self.lineLimit = lineLimit
        self.stream = stream
        self.onViolation = onViolation
    }

    func accept(_ data: Data) {
        guard !data.isEmpty else { return }
        var violationToReport: ProcessOutputLimitViolation?

        lock.lock()
        if storedViolation == nil {
            if data.count > byteLimit - storage.count {
                violationToReport = recordViolationLocked(.bytes)
            } else {
                let newlines = data.reduce(into: 0) { count, byte in
                    if byte == 0x0A { count += 1 }
                }
                if newlines > lineLimit - min(completedLineCount, lineLimit) {
                    violationToReport = recordViolationLocked(.lines)
                } else {
                    storage.append(data)
                    completedLineCount += newlines
                    hasBytes = true
                    endsInNewline = data.last == 0x0A
                }
            }
        }
        lock.unlock()

        if let violationToReport {
            onViolation(violationToReport)
        }
    }

    func finish() {
        var violationToReport: ProcessOutputLimitViolation?
        lock.lock()
        if storedViolation == nil, hasBytes, !endsInNewline, completedLineCount >= lineLimit {
            violationToReport = recordViolationLocked(.lines)
        }
        lock.unlock()

        if let violationToReport {
            onViolation(violationToReport)
        }
    }

    var output: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var violation: ProcessOutputLimitViolation? {
        lock.lock()
        defer { lock.unlock() }
        return storedViolation
    }

    private func recordViolationLocked(_ kind: ProcessLimitKind) -> ProcessOutputLimitViolation {
        let violation = ProcessOutputLimitViolation(stream: stream, kind: kind)
        storedViolation = violation
        storage.removeAll(keepingCapacity: false)
        return violation
    }
}

/// Redacts stderr before it enters the diagnostic buffer. A small raw suffix is retained only
/// to recognize patterns split across read boundaries; an arbitrarily long logical line can no
/// longer accumulate raw provider text in memory.
final class BoundedRedactedStandardErrorCollector: @unchecked Sendable {
    private static let rawCarryByteLimit = 512

    private let lock = NSLock()
    private let byteLimit: Int
    private let lineLimit: Int
    private let redactor: ProcessDiagnosticRedactor
    private let onViolation: @Sendable (ProcessOutputLimitViolation) -> Void

    private var inputByteCount = 0
    private var completedLineCount = 0
    private var pendingLine = Data()
    private var redactedStorage = Data()
    private var storedViolation: ProcessOutputLimitViolation?
    private var discardingSensitiveLineRemainder = false
    private var maximumRawCarryByteCount = 0

    init(
        byteLimit: Int,
        lineLimit: Int,
        homePaths: [String],
        onViolation: @escaping @Sendable (ProcessOutputLimitViolation) -> Void
    ) {
        self.byteLimit = byteLimit
        self.lineLimit = lineLimit
        redactor = ProcessDiagnosticRedactor(homePaths: homePaths)
        self.onViolation = onViolation
    }

    func accept(_ data: Data) {
        guard !data.isEmpty else { return }
        var violationToReport: ProcessOutputLimitViolation?

        lock.lock()
        if storedViolation == nil {
            if data.count > byteLimit - inputByteCount {
                violationToReport = recordViolationLocked(.bytes)
            } else {
                inputByteCount += data.count
                pendingLine.append(data)
                violationToReport = processCompletedLinesLocked()
                if violationToReport == nil {
                    violationToReport = flushBoundedCarryLocked()
                }
                maximumRawCarryByteCount = max(maximumRawCarryByteCount, pendingLine.count)
            }
        }
        lock.unlock()

        if let violationToReport {
            onViolation(violationToReport)
        }
    }

    func finish() {
        var violationToReport: ProcessOutputLimitViolation?
        lock.lock()
        if storedViolation == nil, !pendingLine.isEmpty {
            if discardingSensitiveLineRemainder {
                pendingLine.removeAll(keepingCapacity: false)
                completedLineCount += 1
                discardingSensitiveLineRemainder = false
            } else {
                violationToReport = appendRedactedLineLocked(pendingLine)
            }
            pendingLine.removeAll(keepingCapacity: false)
        }
        lock.unlock()

        if let violationToReport {
            onViolation(violationToReport)
        }
    }

    var output: Data {
        lock.lock()
        defer { lock.unlock() }
        return redactedStorage
    }

    var violation: ProcessOutputLimitViolation? {
        lock.lock()
        defer { lock.unlock() }
        return storedViolation
    }

    var maximumRawCarryByteCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumRawCarryByteCount
    }

    func rawCarryContainsForTesting(_ sentinel: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingLine.range(of: sentinel) != nil
    }

    private func processCompletedLinesLocked() -> ProcessOutputLimitViolation? {
        while let newlineIndex = pendingLine.firstIndex(of: 0x0A) {
            let endIndex = pendingLine.index(after: newlineIndex)
            let line = Data(pendingLine[..<endIndex])
            pendingLine.removeSubrange(..<endIndex)
            if discardingSensitiveLineRemainder {
                discardingSensitiveLineRemainder = false
                completedLineCount += 1
            } else if let violation = appendRedactedLineLocked(line) {
                return violation
            }
        }
        return nil
    }

    private func flushBoundedCarryLocked() -> ProcessOutputLimitViolation? {
        guard pendingLine.count > Self.rawCarryByteLimit else { return nil }

        if discardingSensitiveLineRemainder {
            let retained = pendingLine.suffix(Self.rawCarryByteLimit)
            pendingLine = Data(retained)
            return nil
        }

        let proposedCount = pendingLine.count - Self.rawCarryByteLimit
        let flushCount = safeFlushCount(in: pendingLine, proposedCount: proposedCount)
        guard flushCount > 0 else { return nil }

        let rawPrefix = Data(pendingLine.prefix(flushCount))
        pendingLine.removeFirst(flushCount)
        let redactedPrefix = redactor.redact(rawPrefix)
        if redactedPrefix != rawPrefix {
            discardingSensitiveLineRemainder = true
        }
        return appendRedactedSegmentLocked(redactedPrefix)
    }

    private func safeFlushCount(in data: Data, proposedCount: Int) -> Int {
        guard proposedCount > 0 else { return 0 }
        let delimiters: Set<UInt8> = [0x20, 0x09, 0x2C, 0x3B, 0x26]
        let searchStart = max(0, proposedCount - 128)
        if proposedCount > searchStart {
            for offset in stride(from: proposedCount - 1, through: searchStart, by: -1) {
                if delimiters.contains(data[offset]) {
                    return offset + 1
                }
            }
        }
        return proposedCount
    }

    private func appendRedactedLineLocked(_ line: Data) -> ProcessOutputLimitViolation? {
        guard completedLineCount < lineLimit else {
            return recordViolationLocked(.lines)
        }

        let redacted = redactor.redact(line)
        if let violation = appendRedactedSegmentLocked(redacted) { return violation }
        completedLineCount += 1
        return nil
    }

    private func appendRedactedSegmentLocked(
        _ redacted: Data
    ) -> ProcessOutputLimitViolation? {
        guard redacted.count <= byteLimit - redactedStorage.count else {
            return recordViolationLocked(.bytes)
        }
        redactedStorage.append(redacted)
        return nil
    }

    private func recordViolationLocked(_ kind: ProcessLimitKind) -> ProcessOutputLimitViolation {
        let violation = ProcessOutputLimitViolation(stream: .standardError, kind: kind)
        storedViolation = violation
        pendingLine.removeAll(keepingCapacity: false)
        redactedStorage.removeAll(keepingCapacity: false)
        discardingSensitiveLineRemainder = false
        return violation
    }
}

struct ProcessDiagnosticRedactor {
    private struct Rule {
        let expression: NSRegularExpression
        let replacement: String
    }

    private let homePaths: [String]
    private let rules: [Rule]

    init(homePaths: [String]) {
        self.homePaths = Array(
            Set(homePaths.filter { $0.count > 1 })
        ).sorted { $0.count > $1.count }

        let definitions: [(String, String)] = [
            (#"(?i)(\b[a-z][a-z0-9+.-]*://)[^/\s:@]+:[^@\s/]+@"#, "$1<redacted>@"),
            (#"(?i)(\bauthorization\b[ \t]*[:=][ \t]*)([^\r\n]+)"#, "$1<redacted>"),
            (#"(?i)\bbearer[ \t]+[A-Za-z0-9._~+/=-]+"#, "Bearer <redacted>"),
            (#"(?i)([\"'](?:api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|token|secret|password|credential)[\"'][ \t]*:[ \t]*[\"'])([^\"']*)([\"'])"#, "$1<redacted>$3"),
            (#"(?i)(\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|token|secret|password|credential)\b[ \t]*[:=][ \t]*[\"']?)([^\"',;&\s]+)"#, "$1<redacted>"),
            (#"\b[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#, "<redacted-token>"),
            (#"(?i)\b(?:sk|pk|rk|ak)[-_][A-Za-z0-9._-]{8,}\b"#, "<redacted-key>"),
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "<email>"),
            (#"/(?:Users|home)/[^/\s\"'=:]+"#, "<home>")
        ]
        rules = definitions.compactMap { pattern, replacement in
            // The patterns are compile-time constants; a failure here is a
            // programmer error caught by the redaction tests, so it must fail
            // loudly in Debug instead of silently weakening redaction.
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                assertionFailure("Redaction pattern must compile: \(pattern)")
                return nil
            }
            return Rule(expression: expression, replacement: replacement)
        }
    }

    func redact(_ data: Data) -> Data {
        var text = String(decoding: data, as: UTF8.self)
        for homePath in homePaths {
            text = text.replacingOccurrences(of: homePath, with: "<home>")
        }
        for rule in rules {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = rule.expression.stringByReplacingMatches(
                in: text,
                range: range,
                withTemplate: rule.replacement
            )
        }
        return Data(text.utf8)
    }
}

private enum ProcessRequestValidator {
    // Environment construction belongs to the caller, but this boundary still rejects any
    // capability outside the process contract. The set is deliberately finite and contains no
    // credential-bearing provider variables.
    private static let allowedEnvironmentKeys: Set<String> = [
        "PATH",
        "HOME",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        // Notification-suppression flags for the Feishu CLI; they carry no credential value.
        "LARKSUITE_CLI_NO_UPDATE_NOTIFIER",
        "LARKSUITE_CLI_NO_SKILLS_NOTIFIER",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "NO_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "no_proxy"
    ]

    static func validate(_ request: ChildProcessRequest) -> ProviderFailure? {
        let path = request.executableURL.path
        guard
            request.executableURL.isFileURL,
            !path.isEmpty,
            (path as NSString).isAbsolutePath
        else {
            return ProcessFailure.invalidExecutableURL()
        }

        guard
            request.limits.timeout > .zero,
            request.limits.standardOutputByteLimit >= 0,
            request.limits.standardErrorByteLimit >= 0,
            request.limits.lineLimit >= 0
        else {
            return ProcessFailure.invalidLimits()
        }

        guard request.arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
            return ProcessFailure.invalidArguments()
        }
        guard request.environment.allSatisfy({ key, value in
            allowedEnvironmentKeys.contains(key)
                && !key.contains("=")
                && !key.utf8.contains(0)
                && !value.utf8.contains(0)
        }) else {
            return ProcessFailure.invalidEnvironment()
        }
        return nil
    }
}

private enum ProcessFailure {
    static func invalidExecutableURL() -> ProviderFailure {
        ProviderFailure(
            code: .missingExecutable,
            retryClass: .afterRecovery,
            userMessageKey: "provider.failure.missing_executable",
            diagnosticCode: "process.executable.absolute_file_url_required",
            recovery: .selectExecutable
        )
    }

    static func invalidLimits() -> ProviderFailure {
        invariant("process.request.invalid_limits")
    }

    static func invalidArguments() -> ProviderFailure {
        invariant("process.request.invalid_arguments")
    }

    static func invalidEnvironment() -> ProviderFailure {
        invariant("process.request.invalid_environment")
    }

    static func launch(_ error: Error) -> ProviderFailure {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return missingExecutable("process.launch.missing_executable")
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError {
            return missingExecutable("process.launch.missing_executable")
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return permissionDenied()
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return permissionDenied()
        }
        return ProviderFailure(
            code: .processFailed,
            retryClass: .backoff,
            userMessageKey: "provider.failure.process_failed",
            diagnosticCode: "process.launch.failed",
            recovery: .retry
        )
    }

    static func forStopReason(_ reason: ProcessStopReason) -> ProviderFailure {
        switch reason {
        case .timedOut:
            return timedOut()
        case .cancelled:
            return cancelled()
        case .shutdown:
            return shutdown()
        case let .outputLimit(violation):
            return outputLimit(violation)
        }
    }

    static func timedOut() -> ProviderFailure {
        ProviderFailure(
            code: .timedOut,
            retryClass: .backoff,
            userMessageKey: "provider.failure.timed_out",
            diagnosticCode: "process.timeout",
            recovery: .retry
        )
    }

    static func cancelled() -> ProviderFailure {
        ProviderFailure(
            code: .cancelled,
            retryClass: .never,
            userMessageKey: "provider.failure.cancelled",
            diagnosticCode: "process.cancelled",
            recovery: nil
        )
    }

    static func shutdown() -> ProviderFailure {
        ProviderFailure(
            code: .shutdown,
            retryClass: .never,
            userMessageKey: "provider.failure.shutdown",
            diagnosticCode: "process.client.shutdown",
            recovery: nil
        )
    }

    static func outputLimit(_ violation: ProcessOutputLimitViolation) -> ProviderFailure {
        ProviderFailure(
            code: .processFailed,
            retryClass: .never,
            userMessageKey: "provider.failure.process_output_limit",
            diagnosticCode: "process.\(violation.stream.rawValue).\(violation.kind.rawValue)",
            recovery: nil
        )
    }

    static func io(_ diagnosticCode: String) -> ProviderFailure {
        ProviderFailure(
            code: .processFailed,
            retryClass: .backoff,
            userMessageKey: "provider.failure.process_io",
            diagnosticCode: diagnosticCode,
            recovery: .retry
        )
    }

    static func nonZeroExit(_ code: Int32) -> ProviderFailure {
        ProviderFailure(
            code: .processFailed,
            retryClass: .backoff,
            userMessageKey: "provider.failure.process_failed",
            diagnosticCode: "process.exit.\(code)",
            recovery: .retry
        )
    }

    static func unexpectedSignal(_ signal: Int32) -> ProviderFailure {
        ProviderFailure(
            code: .processFailed,
            retryClass: .backoff,
            userMessageKey: "provider.failure.process_failed",
            diagnosticCode: "process.signal.\(signal)",
            recovery: .retry
        )
    }

    static func unknownTermination(_ status: Int32) -> ProviderFailure {
        ProviderFailure(
            code: .processFailed,
            retryClass: .backoff,
            userMessageKey: "provider.failure.process_failed",
            diagnosticCode: "process.termination.unknown.\(status)",
            recovery: .retry
        )
    }

    private static func invariant(_ diagnosticCode: String) -> ProviderFailure {
        ProviderFailure(
            code: .processFailed,
            retryClass: .never,
            userMessageKey: "provider.failure.invalid_process_request",
            diagnosticCode: diagnosticCode,
            recovery: nil
        )
    }

    private static func missingExecutable(_ diagnosticCode: String) -> ProviderFailure {
        ProviderFailure(
            code: .missingExecutable,
            retryClass: .afterRecovery,
            userMessageKey: "provider.failure.missing_executable",
            diagnosticCode: diagnosticCode,
            recovery: .selectExecutable
        )
    }

    private static func permissionDenied() -> ProviderFailure {
        ProviderFailure(
            code: .permissionDenied,
            retryClass: .afterRecovery,
            userMessageKey: "provider.failure.permission_denied",
            diagnosticCode: "process.launch.permission_denied",
            recovery: .selectExecutable
        )
    }
}
