import Foundation
import XCTest
@testable import UsageButlerProviders

final class OpenAIAppServerBufferTests: XCTestCase {
    func testJSONLChannelFramesChunksAndBoundsQueuedBytesAndCount() async throws {
        let channel = OpenAIJSONLLineChannel(
            maximumLineBytes: 8,
            maximumQueuedLineCount: 2,
            maximumQueuedBytes: 8
        )

        XCTAssertNil(channel.accept(Data("123".utf8)))
        XCTAssertNil(channel.accept(Data("4\n56\n".utf8)))
        XCTAssertEqual(channel.queuedLineCountForTesting, 2)
        XCTAssertEqual(channel.queuedByteCountForTesting, 6)
        let first = try unwrap(await channel.nextLine())
        let second = try unwrap(await channel.nextLine())
        XCTAssertEqual(first, Data("1234".utf8))
        XCTAssertEqual(second, Data("56".utf8))

        XCTAssertNil(channel.accept(Data("12345678\n".utf8)))
        XCTAssertEqual(
            channel.accept(Data("x\n".utf8)),
            .standardOutputQueueOverflow
        )
        XCTAssertEqual(channel.queuedLineCountForTesting, 0)
        XCTAssertEqual(channel.queuedByteCountForTesting, 0)
    }

    func testJSONLChannelRejectsOversizedAndTruncatedLines() async throws {
        let oversized = OpenAIJSONLLineChannel(
            maximumLineBytes: 4,
            maximumQueuedLineCount: 2,
            maximumQueuedBytes: 8
        )
        XCTAssertEqual(
            oversized.accept(Data("12345".utf8)),
            .standardOutputLineTooLarge
        )
        let oversizedFailure = try unwrapFailure(await oversized.nextLine())
        XCTAssertEqual(oversizedFailure, .standardOutputLineTooLarge)

        let truncated = OpenAIJSONLLineChannel(
            maximumLineBytes: 8,
            maximumQueuedLineCount: 2,
            maximumQueuedBytes: 8
        )
        XCTAssertNil(truncated.accept(Data("partial".utf8)))
        truncated.finish(.endOfFile)
        let truncatedFailure = try unwrapFailure(await truncated.nextLine())
        XCTAssertEqual(truncatedFailure, .standardOutputTruncatedLine)
    }

    func testLimitInSameChunkOverridesEarlierLineDelivery() async throws {
        let channel = OpenAIJSONLLineChannel(
            maximumLineBytes: 4,
            maximumQueuedLineCount: 2,
            maximumQueuedBytes: 8
        )
        let waiting = Task { await channel.nextLine() }
        await Task.yield()

        XCTAssertEqual(
            channel.accept(Data("ok\n12345\n".utf8)),
            .standardOutputLineTooLarge
        )
        let failure = try unwrapFailure(await waiting.value)
        XCTAssertEqual(failure, .standardOutputLineTooLarge)
    }

    func testStandardErrorCollectorStoresNoRawTextAndOnlyReturnsTypedCounts() {
        let secret = "Authorization: Bearer TOP-SECRET\naccount@example.invalid\n"
        let collector = OpenAIDiscardingStandardErrorCollector(
            byteLimit: 1_024,
            lineLimit: 10
        )

        XCTAssertNil(collector.accept(Data(secret.utf8)))
        collector.finish()
        let summary = collector.summary

        XCTAssertEqual(summary.byteCount, Data(secret.utf8).count)
        XCTAssertEqual(summary.lineCount, 2)
        XCTAssertEqual(summary.classification, .discarded)
        XCTAssertEqual(collector.rawStorageByteCountForTesting, 0)
        XCTAssertFalse(String(describing: summary).contains("TOP-SECRET"))
        XCTAssertFalse(String(describing: summary).contains("account@example.invalid"))
    }

    func testStandardErrorCollectorLimitsAreTypedWithoutRetainingRawBytes() {
        let byteLimited = OpenAIDiscardingStandardErrorCollector(byteLimit: 4, lineLimit: 10)
        XCTAssertEqual(
            byteLimited.accept(Data("secret".utf8)),
            .standardErrorByteLimit
        )
        XCTAssertEqual(byteLimited.summary.classification, .byteLimitExceeded)
        XCTAssertEqual(byteLimited.rawStorageByteCountForTesting, 0)

        let lineLimited = OpenAIDiscardingStandardErrorCollector(byteLimit: 100, lineLimit: 1)
        XCTAssertEqual(
            lineLimited.accept(Data("one\ntwo\n".utf8)),
            .standardErrorLineLimit
        )
        XCTAssertEqual(lineLimited.summary.classification, .lineLimitExceeded)
        XCTAssertEqual(lineLimited.rawStorageByteCountForTesting, 0)
    }

    private func unwrap(
        _ result: Result<Data, OpenAIAppServerProcessError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        switch result {
        case let .success(data): return data
        case let .failure(failure):
            XCTFail("Unexpected failure: \(failure)", file: file, line: line)
            throw OpenAIAppServerBufferTestError.unexpectedFailure
        }
    }

    private func unwrapFailure(
        _ result: Result<Data, OpenAIAppServerProcessError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> OpenAIAppServerProcessError {
        switch result {
        case .success:
            XCTFail("Expected failure", file: file, line: line)
            throw OpenAIAppServerBufferTestError.unexpectedSuccess
        case let .failure(failure): return failure
        }
    }
}

private enum OpenAIAppServerBufferTestError: Error {
    case unexpectedFailure
    case unexpectedSuccess
}
