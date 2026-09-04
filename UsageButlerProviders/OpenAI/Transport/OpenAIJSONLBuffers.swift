import Foundation

final class OpenAIJSONLLineChannel: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumLineBytes: Int
    private let maximumQueuedLineCount: Int
    private let maximumQueuedBytes: Int

    private var partialLine = Data()
    private var queuedLines: [Data] = []
    private var queuedByteCount = 0
    private var waiters: [CheckedContinuation<Result<Data, OpenAIAppServerProcessError>, Never>] = []
    private var terminalFailure: OpenAIAppServerProcessError?

    init(
        maximumLineBytes: Int,
        maximumQueuedLineCount: Int,
        maximumQueuedBytes: Int
    ) {
        precondition(maximumLineBytes > 0)
        precondition(maximumQueuedLineCount > 0)
        precondition(maximumQueuedBytes > 0)
        self.maximumLineBytes = maximumLineBytes
        self.maximumQueuedLineCount = maximumQueuedLineCount
        self.maximumQueuedBytes = maximumQueuedBytes
    }

    func accept(_ chunk: Data) -> OpenAIAppServerProcessError? {
        guard !chunk.isEmpty else { return nil }
        var resumptions: [(
            CheckedContinuation<Result<Data, OpenAIAppServerProcessError>, Never>,
            Result<Data, OpenAIAppServerProcessError>
        )] = []
        var newFailure: OpenAIAppServerProcessError?

        lock.lock()
        if terminalFailure == nil {
            partialLine.append(chunk)

            while let newlineIndex = partialLine.firstIndex(of: 0x0A) {
                let line = Data(partialLine[..<newlineIndex])
                partialLine.removeSubrange(...newlineIndex)
                if line.count > maximumLineBytes {
                    newFailure = .standardOutputLineTooLarge
                    break
                }
                if !waiters.isEmpty {
                    resumptions.append((waiters.removeFirst(), .success(line)))
                } else if queuedLines.count >= maximumQueuedLineCount
                    || line.count > maximumQueuedBytes - queuedByteCount {
                    newFailure = .standardOutputQueueOverflow
                    break
                } else {
                    queuedLines.append(line)
                    queuedByteCount += line.count
                }
            }

            if newFailure == nil, partialLine.count > maximumLineBytes {
                newFailure = .standardOutputLineTooLarge
            }
            if let newFailure {
                terminalFailure = newFailure
                partialLine.removeAll(keepingCapacity: false)
                queuedLines.removeAll(keepingCapacity: false)
                queuedByteCount = 0
                resumptions = resumptions.map { ($0.0, .failure(newFailure)) }
                resumptions.append(contentsOf: waiters.map { ($0, .failure(newFailure)) })
                waiters.removeAll()
            }
        }
        lock.unlock()

        for (continuation, result) in resumptions {
            continuation.resume(returning: result)
        }
        return newFailure
    }

    func finish(_ failure: OpenAIAppServerProcessError) {
        var resumptions: [CheckedContinuation<Result<Data, OpenAIAppServerProcessError>, Never>] = []
        var deliveredFailure = failure

        lock.lock()
        if terminalFailure == nil {
            if !partialLine.isEmpty {
                deliveredFailure = .standardOutputTruncatedLine
                partialLine.removeAll(keepingCapacity: false)
            }
            terminalFailure = deliveredFailure
            if queuedLines.isEmpty {
                resumptions = waiters
                waiters.removeAll()
            }
        }
        lock.unlock()

        for continuation in resumptions {
            continuation.resume(returning: .failure(deliveredFailure))
        }
    }

    func nextLine() async -> Result<Data, OpenAIAppServerProcessError> {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !queuedLines.isEmpty {
                let line = queuedLines.removeFirst()
                queuedByteCount -= line.count
                lock.unlock()
                continuation.resume(returning: .success(line))
            } else if let terminalFailure {
                lock.unlock()
                continuation.resume(returning: .failure(terminalFailure))
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    var queuedLineCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return queuedLines.count
    }

    var queuedByteCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return queuedByteCount
    }
}

enum OpenAIStandardErrorClassification: String, Equatable, Sendable {
    case empty
    case discarded
    case byteLimitExceeded
    case lineLimitExceeded
    case readFailed
}

struct OpenAIStandardErrorSummary: Equatable, Sendable {
    let byteCount: Int
    let lineCount: Int
    let classification: OpenAIStandardErrorClassification
}

/// This collector intentionally has no raw-data storage. Bytes are classified and counted,
/// then immediately discarded. That keeps the Providers target independent from the internal
/// Infrastructure redactor without allowing stderr text to cross the transport boundary.
final class OpenAIDiscardingStandardErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let byteLimit: Int
    private let lineLimit: Int

    private var byteCount = 0
    private var completedLineCount = 0
    private var hasBytes = false
    private var endsInNewline = false
    private var classification: OpenAIStandardErrorClassification = .empty

    init(byteLimit: Int, lineLimit: Int) {
        precondition(byteLimit >= 0)
        precondition(lineLimit >= 0)
        self.byteLimit = byteLimit
        self.lineLimit = lineLimit
    }

    func accept(_ chunk: Data) -> OpenAIAppServerProcessError? {
        guard !chunk.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }

        guard classification != .byteLimitExceeded,
              classification != .lineLimitExceeded,
              classification != .readFailed else {
            return nil
        }

        let (newByteCount, overflowed) = byteCount.addingReportingOverflow(chunk.count)
        guard !overflowed, newByteCount <= byteLimit else {
            classification = .byteLimitExceeded
            return .standardErrorByteLimit
        }

        let newlines = chunk.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        let (newLineCount, lineOverflowed) = completedLineCount.addingReportingOverflow(newlines)
        guard !lineOverflowed, newLineCount <= lineLimit else {
            classification = .lineLimitExceeded
            return .standardErrorLineLimit
        }

        byteCount = newByteCount
        completedLineCount = newLineCount
        hasBytes = true
        endsInNewline = chunk.last == 0x0A
        classification = .discarded
        return nil
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard hasBytes, !endsInNewline, classification == .discarded else { return }
        if completedLineCount < lineLimit {
            completedLineCount += 1
            endsInNewline = true
        } else {
            classification = .lineLimitExceeded
        }
    }

    func markReadFailure() {
        lock.lock()
        classification = .readFailed
        lock.unlock()
    }

    var summary: OpenAIStandardErrorSummary {
        lock.lock()
        defer { lock.unlock() }
        return OpenAIStandardErrorSummary(
            byteCount: byteCount,
            lineCount: completedLineCount,
            classification: classification
        )
    }

    var rawStorageByteCountForTesting: Int { 0 }
}
