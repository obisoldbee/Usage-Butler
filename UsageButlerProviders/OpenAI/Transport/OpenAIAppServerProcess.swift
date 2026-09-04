import Darwin
import Foundation

enum OpenAIAppServerProcessError: Error, Equatable, Sendable {
    case notStarted
    case closed
    case endOfFile
    case missingExecutable
    case permissionDenied
    case launchFailed
    case writeFailed
    case standardOutputReadFailed
    case standardOutputLineTooLarge
    case standardOutputQueueOverflow
    case standardOutputTruncatedLine
    case standardErrorReadFailed
    case standardErrorByteLimit
    case standardErrorLineLimit
}

struct OpenAIAppServerLaunchConfiguration: Equatable, Sendable {
    static let fixedArguments = ["app-server", "--stdio"]

    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]

    init(executableURL: URL, environment: [String: String]) {
        self.executableURL = executableURL
        arguments = Self.fixedArguments
        self.environment = environment
    }
}

protocol OpenAIAppServerProcess: Actor {
    func start() async -> Result<Void, OpenAIAppServerProcessError>
    func writeLine(_ line: Data) async -> Result<Void, OpenAIAppServerProcessError>
    func nextLine() async -> Result<Data, OpenAIAppServerProcessError>
    func safeStandardErrorSummary() async -> OpenAIStandardErrorSummary
    func close() async
}

protocol OpenAIAppServerProcessFactory: Sendable {
    func makeProcess(
        configuration: OpenAIAppServerLaunchConfiguration
    ) -> any OpenAIAppServerProcess
}

struct FoundationOpenAIAppServerProcessFactory: OpenAIAppServerProcessFactory, Sendable {
    private let terminationGracePeriod: Duration

    init(terminationGracePeriod: Duration = .milliseconds(150)) {
        self.terminationGracePeriod = min(max(terminationGracePeriod, .zero), .seconds(1))
    }

    func makeProcess(
        configuration: OpenAIAppServerLaunchConfiguration
    ) -> any OpenAIAppServerProcess {
        FoundationOpenAIAppServerProcess(
            configuration: configuration,
            terminationGracePeriod: terminationGracePeriod
        )
    }
}

private actor FoundationOpenAIAppServerProcess: OpenAIAppServerProcess {
    private enum State {
        case notStarted
        case running
        case closing
        case closed
    }

    private static let standardOutputLineByteLimit = 1_048_576
    private static let standardOutputQueueByteLimit = 1_048_576
    private static let standardOutputQueueCountLimit = 256
    private static let standardErrorByteLimit = 1_048_576
    private static let standardErrorLineLimit = 10_000

    private let configuration: OpenAIAppServerLaunchConfiguration
    private let terminationGracePeriod: Duration
    private let lineChannel: OpenAIJSONLLineChannel
    private let standardErrorCollector: OpenAIDiscardingStandardErrorCollector

    private var state: State = .notStarted
    private var processBox: OpenAISendableProcessBox?
    private var processID: pid_t?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var standardError: FileHandle?
    private var parentInputReadEnd: FileHandle?
    private var parentOutputWriteEnd: FileHandle?
    private var parentErrorWriteEnd: FileHandle?
    private var terminationSignal: OpenAIProcessTerminationSignal?
    private let standardOutputDrainCompletion = OpenAIProcessCompletionSignal()
    private let standardErrorDrainCompletion = OpenAIProcessCompletionSignal()
    private let closeCompletion = OpenAIProcessCompletionSignal()

    init(
        configuration: OpenAIAppServerLaunchConfiguration,
        terminationGracePeriod: Duration
    ) {
        self.configuration = configuration
        self.terminationGracePeriod = terminationGracePeriod
        lineChannel = OpenAIJSONLLineChannel(
            maximumLineBytes: Self.standardOutputLineByteLimit,
            maximumQueuedLineCount: Self.standardOutputQueueCountLimit,
            maximumQueuedBytes: Self.standardOutputQueueByteLimit
        )
        standardErrorCollector = OpenAIDiscardingStandardErrorCollector(
            byteLimit: Self.standardErrorByteLimit,
            lineLimit: Self.standardErrorLineLimit
        )
    }

    func start() async -> Result<Void, OpenAIAppServerProcessError> {
        switch state {
        case .running:
            return .success(())
        case .closing, .closed:
            return .failure(.closed)
        case .notStarted:
            break
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        // This is a replacement environment. No parent values are merged here.
        process.environment = configuration.environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let processBox = OpenAISendableProcessBox(process)
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        let lineChannel = self.lineChannel
        let standardErrorCollector = self.standardErrorCollector
        let terminationSignal = OpenAIProcessTerminationSignal()

        // Schedule the bounded drains before launch. These are dedicated GCD queues,
        // not Swift Tasks, so their synchronous pipe reads never occupy the Swift
        // cooperative executor.
        let standardOutputDrainCompletion = self.standardOutputDrainCompletion
        DispatchQueue(label: "usage-butler.openai.stdout", qos: .utility).async { [weak self] in
            let failure = OpenAIProcessIO.drainStandardOutput(
                outputHandle,
                channel: lineChannel
            )
            standardOutputDrainCompletion.signal()
            guard let failure else { return }
            Task { await self?.stopAfterStreamFailure(failure) }
        }
        let standardErrorDrainCompletion = self.standardErrorDrainCompletion
        DispatchQueue(label: "usage-butler.openai.stderr", qos: .utility).async { [weak self] in
            let failure = OpenAIProcessIO.drainStandardError(
                errorHandle,
                collector: standardErrorCollector
            )
            standardErrorDrainCompletion.signal()
            guard let failure else { return }
            Task { await self?.stopAfterStreamFailure(failure) }
        }
        process.terminationHandler = { _ in
            // Foundation has observed and reaped the child before invoking this hook.
            OpenAIProcessIO.closeQuietly(inputPipe.fileHandleForReading)
            OpenAIProcessIO.closeQuietly(outputPipe.fileHandleForWriting)
            OpenAIProcessIO.closeQuietly(errorPipe.fileHandleForWriting)
            terminationSignal.signal()
        }

        self.processBox = processBox
        standardInput = inputPipe.fileHandleForWriting
        standardOutput = outputHandle
        standardError = errorHandle
        parentInputReadEnd = inputPipe.fileHandleForReading
        parentOutputWriteEnd = outputPipe.fileHandleForWriting
        parentErrorWriteEnd = errorPipe.fileHandleForWriting
        self.terminationSignal = terminationSignal

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            OpenAIProcessIO.closeQuietly(inputPipe.fileHandleForReading)
            OpenAIProcessIO.closeQuietly(inputPipe.fileHandleForWriting)
            OpenAIProcessIO.closeQuietly(outputPipe.fileHandleForReading)
            OpenAIProcessIO.closeQuietly(outputPipe.fileHandleForWriting)
            OpenAIProcessIO.closeQuietly(errorPipe.fileHandleForReading)
            OpenAIProcessIO.closeQuietly(errorPipe.fileHandleForWriting)
            processBox.process.terminationHandler = nil
            self.processBox = nil
            standardInput = nil
            standardOutput = nil
            standardError = nil
            parentInputReadEnd = nil
            parentOutputWriteEnd = nil
            parentErrorWriteEnd = nil
            self.terminationSignal = nil
            state = .closed
            let mapped = Self.mapLaunchError(error)
            lineChannel.finish(mapped)
            _ = await standardOutputDrainCompletion.wait(for: .seconds(1))
            _ = await standardErrorDrainCompletion.wait(for: .seconds(1))
            closeCompletion.signal()
            return .failure(mapped)
        }

        // `Process.run()` has duplicated the child-side descriptors. The parent
        // must not retain its unused pipe ends, otherwise a child exit cannot
        // deliver EOF to the stdout/stderr drains without help from the
        // termination handler.
        OpenAIProcessIO.closeQuietly(inputPipe.fileHandleForReading)
        OpenAIProcessIO.closeQuietly(outputPipe.fileHandleForWriting)
        OpenAIProcessIO.closeQuietly(errorPipe.fileHandleForWriting)
        parentInputReadEnd = nil
        parentOutputWriteEnd = nil
        parentErrorWriteEnd = nil

        processID = process.processIdentifier
        state = .running

        return .success(())
    }

    func writeLine(_ line: Data) async -> Result<Void, OpenAIAppServerProcessError> {
        guard state == .running, let standardInput else {
            return .failure(state == .notStarted ? .notStarted : .closed)
        }
        guard !line.contains(0x0A), line.count <= Self.standardOutputLineByteLimit else {
            await stopAfterStreamFailure(.writeFailed)
            return .failure(.writeFailed)
        }

        var framed = line
        framed.append(0x0A)
        do {
            try standardInput.write(contentsOf: framed)
            return .success(())
        } catch {
            await stopAfterStreamFailure(.writeFailed)
            return .failure(.writeFailed)
        }
    }

    func nextLine() async -> Result<Data, OpenAIAppServerProcessError> {
        guard state != .notStarted else { return .failure(.notStarted) }
        return await lineChannel.nextLine()
    }

    func safeStandardErrorSummary() async -> OpenAIStandardErrorSummary {
        standardErrorCollector.summary
    }

    func close() async {
        switch state {
        case .closed:
            return
        case .closing:
            await closeCompletion.wait()
            return
        case .notStarted, .running:
            break
        }
        state = .closing
        lineChannel.finish(.closed)
        OpenAIProcessIO.closeQuietly(standardInput)
        standardInput = nil
        await terminateAndReapOwnedProcess()
        await finishStreamDrainsWithinBound()
        tearDownStreamHandlers()
        standardErrorCollector.finish()
        state = .closed
        closeCompletion.signal()
    }

    private func stopAfterStreamFailure(_ failure: OpenAIAppServerProcessError) async {
        switch state {
        case .closed:
            return
        case .closing:
            await closeCompletion.wait()
            return
        case .notStarted, .running:
            break
        }
        state = .closing
        lineChannel.finish(failure)
        OpenAIProcessIO.closeQuietly(standardInput)
        standardInput = nil
        await terminateAndReapOwnedProcess()
        await finishStreamDrainsWithinBound()
        tearDownStreamHandlers()
        standardErrorCollector.finish()
        state = .closed
        closeCompletion.signal()
    }

    private func terminateAndReapOwnedProcess() async {
        guard let processBox, let terminationSignal else { return }
        let ownedPID = processID

        if processBox.process.isRunning {
            processBox.process.terminate()
            let terminatedAfterTERM = await terminationSignal.wait(
                for: terminationGracePeriod
            )
            if !terminatedAfterTERM,
               let ownedPID,
               processID == ownedPID,
               processBox.process.isRunning {
                _ = Darwin.kill(ownedPID, SIGKILL)
            }
        }
        // The termination handler runs only after Foundation has observed and reaped
        // the owned child. Bound the post-KILL wait so shutdown cannot hang forever.
        let reaped = await terminationSignal.wait(for: .seconds(1))
        if !reaped {
            if let ownedPID,
               processID == ownedPID,
               processBox.process.isRunning {
                _ = Darwin.kill(ownedPID, SIGKILL)
            }
            forceCloseStreamEndpoints()
        }
        processID = nil
    }

    private func finishStreamDrainsWithinBound() async {
        guard standardOutput != nil || standardError != nil else { return }
        async let outputWait = standardOutputDrainCompletion.wait(for: .seconds(1))
        async let errorWait = standardErrorDrainCompletion.wait(for: .seconds(1))
        let (outputFinished, errorFinished) = await (outputWait, errorWait)
        guard !outputFinished || !errorFinished else { return }
        forceCloseStreamEndpoints()
        async let forcedOutputWait = standardOutputDrainCompletion.wait(for: .milliseconds(100))
        async let forcedErrorWait = standardErrorDrainCompletion.wait(for: .milliseconds(100))
        _ = await (forcedOutputWait, forcedErrorWait)
    }

    private func forceCloseStreamEndpoints() {
        OpenAIProcessIO.closeQuietly(parentInputReadEnd)
        OpenAIProcessIO.closeQuietly(parentOutputWriteEnd)
        OpenAIProcessIO.closeQuietly(parentErrorWriteEnd)
        OpenAIProcessIO.closeQuietly(standardOutput)
        OpenAIProcessIO.closeQuietly(standardError)
    }

    private func tearDownStreamHandlers() {
        forceCloseStreamEndpoints()
        standardOutput = nil
        standardError = nil
        parentInputReadEnd = nil
        parentOutputWriteEnd = nil
        parentErrorWriteEnd = nil
        processBox?.process.terminationHandler = nil
        terminationSignal = nil
        processBox = nil
    }

    private static func mapLaunchError(_ error: Error) -> OpenAIAppServerProcessError {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return .missingExecutable
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError {
            return .missingExecutable
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return .permissionDenied
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return .permissionDenied
        }
        return .launchFailed
    }
}

private final class OpenAISendableProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

private final class OpenAIProcessCompletionSignal: @unchecked Sendable {
    private struct TimedWaiter {
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var timedWaiters: [UUID: TimedWaiter] = [:]

    func signal() {
        let resumptions: [CheckedContinuation<Void, Never>]
        let timedResumptions: [CheckedContinuation<Bool, Never>]
        lock.lock()
        guard !isSignalled else {
            lock.unlock()
            return
        }
        isSignalled = true
        resumptions = waiters
        waiters.removeAll()
        timedResumptions = timedWaiters.values.map(\.continuation)
        timedWaiters.removeAll()
        lock.unlock()
        for continuation in resumptions {
            continuation.resume()
        }
        for continuation in timedResumptions {
            continuation.resume(returning: true)
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isSignalled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func wait(for duration: Duration) async -> Bool {
        guard duration > .zero else { return currentValue() }
        let token = UUID()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if isSignalled {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            timedWaiters[token] = TimedWaiter(continuation: continuation)
            lock.unlock()

            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + OpenAIProcessWaitDuration.dispatchInterval(for: duration)
            ) { [weak self] in
                self?.timeOut(token: token)
            }
        }
    }

    private func timeOut(token: UUID) {
        let continuation: CheckedContinuation<Bool, Never>?
        lock.lock()
        continuation = timedWaiters.removeValue(forKey: token)?.continuation
        lock.unlock()
        continuation?.resume(returning: false)
    }

    private func currentValue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isSignalled
    }
}

private final class OpenAIProcessTerminationSignal: @unchecked Sendable {
    private struct TimedWaiter {
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private var isSignalled = false
    private var waiters: [UUID: TimedWaiter] = [:]

    func signal() {
        let resumptions: [CheckedContinuation<Bool, Never>]
        lock.lock()
        guard !isSignalled else {
            lock.unlock()
            return
        }
        isSignalled = true
        resumptions = waiters.values.map(\.continuation)
        waiters.removeAll()
        lock.unlock()
        for continuation in resumptions {
            continuation.resume(returning: true)
        }
    }

    func wait(for duration: Duration) async -> Bool {
        guard duration > .zero else {
            return currentValue()
        }
        let token = UUID()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if isSignalled {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            waiters[token] = TimedWaiter(continuation: continuation)
            lock.unlock()

            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + OpenAIProcessWaitDuration.dispatchInterval(for: duration)
            ) { [weak self] in
                self?.timeOut(token: token)
            }
        }
    }

    private func timeOut(token: UUID) {
        let continuation: CheckedContinuation<Bool, Never>?
        lock.lock()
        continuation = waiters.removeValue(forKey: token)?.continuation
        lock.unlock()
        continuation?.resume(returning: false)
    }

    private func currentValue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isSignalled
    }

}

private enum OpenAIProcessWaitDuration {
    static func dispatchInterval(for duration: Duration) -> DispatchTimeInterval {
        let components = duration.components
        let seconds = max(components.seconds, 0)
        let attoseconds = max(components.attoseconds, 0)
        let secondsNanoseconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let fractionalNanoseconds = attoseconds / 1_000_000_000
        let total = secondsNanoseconds.partialValue.addingReportingOverflow(
            fractionalNanoseconds
        )
        guard !secondsNanoseconds.overflow,
              !total.overflow,
              total.partialValue <= Int64(Int.max) else {
            return .seconds(Int.max)
        }
        return .nanoseconds(Int(total.partialValue))
    }
}

private enum OpenAIProcessIO {
    private static let chunkSize = 16 * 1024

    static func drainStandardOutput(
        _ handle: FileHandle,
        channel: OpenAIJSONLLineChannel
    ) -> OpenAIAppServerProcessError? {
        do {
            while let chunk = try readPOSIXChunk(from: handle) {
                if let failure = channel.accept(chunk) { return failure }
            }
            channel.finish(.endOfFile)
            return nil
        } catch {
            channel.finish(.standardOutputReadFailed)
            return .standardOutputReadFailed
        }
    }

    static func drainStandardError(
        _ handle: FileHandle,
        collector: OpenAIDiscardingStandardErrorCollector
    ) -> OpenAIAppServerProcessError? {
        do {
            while let chunk = try readPOSIXChunk(from: handle) {
                if let failure = collector.accept(chunk) { return failure }
            }
            collector.finish()
            return nil
        } catch {
            collector.markReadFailure()
            return .standardErrorReadFailed
        }
    }

    private static func readPOSIXChunk(from handle: FileHandle) throws -> Data? {
        var storage = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let count = Darwin.read(handle.fileDescriptor, &storage, storage.count)
            if count > 0 {
                return Data(storage.prefix(count))
            }
            if count == 0 {
                return nil
            }
            if errno == EINTR {
                continue
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func closeQuietly(_ handle: FileHandle?) {
        guard let handle else { return }
        try? handle.close()
    }
}
