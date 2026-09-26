import Darwin
import Foundation
import UsageButlerCore
import UsageButlerDomain

/// One owned nettop per session, with PTY line buffering. The detached worker
/// owns every descriptor and the child for its entire lifetime. Cancellation
/// is checked at most 100 ms apart; shutdown reaps only this Process instance.
public final class NettopProcessSource: ProcessNetworkSource, @unchecked Sendable {
    private let sessionID: CaptureSessionID
    private let lock = NSLock()
    private var worker: Task<Void, Never>?
    private var stopped = false
    private let stream: AsyncStream<ProcessNetworkFrame>
    private let continuation: AsyncStream<ProcessNetworkFrame>.Continuation
    public init(sessionID: CaptureSessionID) {
        self.sessionID = sessionID
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(2))
    }
    public func events() -> AsyncStream<ProcessNetworkFrame> {
        lock.lock()
        if worker == nil, !stopped {
            let id = sessionID, continuation = continuation
            worker = Task.detached(priority: .utility) { Self.run(id: id, continuation: continuation) }
            continuation.onTermination = { [weak self] _ in self?.cancel() }
        }
        lock.unlock()
        return stream
    }
    private func cancel() {
        lock.lock(); stopped = true; worker?.cancel(); lock.unlock()
    }
    private func taskToStop() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        stopped = true; worker?.cancel()
        if worker == nil { continuation.finish() }
        return worker
    }
    public func stop() async { await taskToStop()?.value }

    private static func run(id: CaptureSessionID, continuation: AsyncStream<ProcessNetworkFrame>.Continuation) {
        var master: Int32 = -1, slave: Int32 = -1
        var sequence: UInt64 = 0
        func failure(_ reason: String) {
            sequence &+= 1
            continuation.yield(.init(envelope: .init(sessionID: id, sequence: sequence, occurredAt: Date(),
                monotonicOccurredAt: .init(nanoseconds: DispatchTime.now().uptimeNanoseconds)),
                processes: [], complete: false, issue: reason))
        }
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            failure("pty-unavailable"); continuation.finish(); return
        }
        let output = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let errors = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        child.arguments = ["-P", "-L", "0", "-n", "-x", "-s", "1", "-J", "bytes_in,bytes_out"]
        child.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C", "TERM": "dumb"]
        child.standardOutput = output; child.standardError = errors
        // Keep stdin on the owned PTY as well. On macOS, nettop with
        // /dev/null stdin repeatedly wakes on EOF and can consume a core.
        // The parent only reads the master, so no interactive input is sent.
        child.standardInput = output
        defer {
            if child.isRunning {
                child.terminate()
                let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
                while child.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { usleep(10_000) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }
            close(master)
            try? output.close(); try? errors.fileHandleForReading.close(); try? errors.fileHandleForWriting.close()
            continuation.finish()
        }
        guard !Task.isCancelled else { return }
        do { try child.run() } catch { failure("launch-failed"); return }
        try? output.close(); try? errors.fileHandleForWriting.close()
        let stderrFD = errors.fileHandleForReading.fileDescriptor
        _ = fcntl(master, F_SETFL, O_NONBLOCK); _ = fcntl(stderrFD, F_SETFL, O_NONBLOCK)
        var parser = NettopCSVParser()
        var resolver = SystemProcessNetworkIdentity()
        var frameTime: ClockReading?
        var rows: [ProcessNetworkCounter] = []
        var valid = true, frameIssue: String?
        var bytesInFrame = 0, stderrBytes = 0
        var lastHeader = DispatchTime.now().uptimeNanoseconds
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while !Task.isCancelled {
            var pollFDs = [pollfd(fd: master, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: stderrFD, events: Int16(POLLIN), revents: 0)]
            let result = poll(&pollFDs, nfds_t(pollFDs.count), 100)
            if result < 0, errno != EINTR { failure("read-failed"); return }
            if pollFDs[1].revents & Int16(POLLIN) != 0 {
                let n = read(stderrFD, &buffer, buffer.count)
                if n > 0 { stderrBytes += n }
                if stderrBytes > 65_536 { failure("stderr-limit"); return }
            }
            if pollFDs[0].revents & Int16(POLLIN) != 0 {
                let n = read(master, &buffer, buffer.count)
                if n > 0 {
                    bytesInFrame += n
                    if bytesInFrame > 1_048_576 { failure("stdout-frame-limit"); return }
                    let records = parser.feed(Data(buffer.prefix(n)))
                    for record in records {
                        let now = ClockReading(wallTime: Date(), monotonicTime: .init(nanoseconds: DispatchTime.now().uptimeNanoseconds))
                        switch record {
                        case .header:
                            if let previous = frameTime {
                                let interval = Double(now.monotonicTime.nanoseconds - previous.monotonicTime.nanoseconds) / 1e9
                                // A buffered burst has no trustworthy cadence. Do not settle it.
                                let unbuffered = interval >= 0.5 && interval <= 2.5
                                sequence &+= 1
                                continuation.yield(.init(envelope: .init(sessionID: id, sequence: sequence,
                                    occurredAt: previous.wallTime, monotonicOccurredAt: previous.monotonicTime),
                                    processes: rows, complete: valid && unbuffered,
                                    issue: unbuffered ? frameIssue : "source-cadence-unverified"))
                            }
                            frameTime = now; lastHeader = now.monotonicTime.nanoseconds
                            rows.removeAll(keepingCapacity: true); valid = true; frameIssue = nil; bytesInFrame = 0
                        case let .process(pid, name, download, upload):
                            guard let frameTime else { valid = false; frameIssue = "missing-header"; continue }
                            guard rows.count < 2_048 else { valid = false; frameIssue = "process-limit"; continue }
                            let identity = resolver.resolve(pid: pid, name: name, frameStartedAt: frameTime.wallTime)
                            rows.append(.init(identity: identity, bytes: .init(upload: upload, download: download)))
                        case .invalid:
                            valid = false; frameIssue = "malformed-csv"
                        }
                    }
                } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                    failure("source-eof"); return
                }
            }
            if !child.isRunning { _ = parser.finish(); failure("source-exited"); return }
            if DispatchTime.now().uptimeNanoseconds - lastHeader > 8_000_000_000 { failure("source-timeout"); return }
        }
    }
}
