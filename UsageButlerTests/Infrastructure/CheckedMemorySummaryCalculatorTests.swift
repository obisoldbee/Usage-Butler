import XCTest
import UsageButlerDomain
@testable import UsageButlerInfrastructure

final class CheckedMemorySummaryCalculatorTests: XCTestCase {
    func testSevenFieldsUseVersionedActivityMonitorNamedFormulaFamily() throws {
        let pageSize: UInt64 = 4_096
        let counters = HostMemoryCounters(
            pageSize: pageSize,
            free: 100,
            speculative: 20,
            external: 40,
            internal: 200,
            purgeable: 10,
            wired: 30,
            compressor: 25
        )
        let physical = UInt64(1_000) * pageSize

        let fields = CheckedMemorySummaryCalculator.fields(
            physicalTotalBytes: physical,
            counters: counters,
            swapUsedBytes: 777
        )

        XCTAssertEqual(fields.map(\.id), MemoryFieldID.allCases)
        XCTAssertEqual(value(.physical, in: fields), physical)
        XCTAssertEqual(value(.used, in: fields), UInt64(870) * pageSize)
        XCTAssertEqual(value(.cachedFiles, in: fields), UInt64(50) * pageSize)
        XCTAssertEqual(value(.swapUsed, in: fields), 777)
        XCTAssertEqual(value(.appMemory, in: fields), UInt64(190) * pageSize)
        XCTAssertEqual(value(.wired, in: fields), UInt64(30) * pageSize)
        XCTAssertEqual(value(.compressed, in: fields), UInt64(25) * pageSize)

        XCTAssertEqual(
            field(.used, in: fields)?.provenance,
            .derivedSystemEstimate(formulaID: "hostvm-summary-v1.used")
        )
        XCTAssertEqual(
            field(.cachedFiles, in: fields)?.provenance,
            .derivedSystemEstimate(formulaID: "hostvm-summary-v1.cached")
        )
        XCTAssertEqual(
            field(.appMemory, in: fields)?.provenance,
            .derivedSystemEstimate(formulaID: "hostvm-summary-v1.app")
        )
        XCTAssertEqual(field(.wired, in: fields)?.provenance, .directSystemValue)
        XCTAssertEqual(field(.compressed, in: fields)?.provenance, .directSystemValue)
    }

    func testInvalidUsedInputsDoNotEraseIndependentFields() throws {
        let counters = HostMemoryCounters(
            pageSize: 4_096,
            free: 10,
            speculative: 11,
            external: 3,
            internal: 20,
            purgeable: 2,
            wired: 4,
            compressor: 5
        )

        let fields = CheckedMemorySummaryCalculator.fields(
            physicalTotalBytes: 1_000_000,
            counters: counters,
            swapUsedBytes: 88
        )

        XCTAssertNil(value(.used, in: fields))
        XCTAssertEqual(
            field(.used, in: fields)?.availability,
            .unavailable(
                .inconsistentCounters(
                    formulaID: CheckedMemorySummaryCalculator.usedFormulaID
                )
            )
        )
        XCTAssertEqual(value(.cachedFiles, in: fields), UInt64(5) * 4_096)
        XCTAssertEqual(value(.appMemory, in: fields), UInt64(18) * 4_096)
        XCTAssertEqual(value(.wired, in: fields), UInt64(4) * 4_096)
        XCTAssertEqual(value(.compressed, in: fields), UInt64(5) * 4_096)
        XCTAssertEqual(value(.swapUsed, in: fields), 88)
    }

    func testZeroPageSizeAndOverflowAreFieldLocalFailures() throws {
        let zeroPage = HostMemoryCounters(
            pageSize: 0,
            free: 1,
            speculative: 0,
            external: 1,
            internal: 1,
            purgeable: 0,
            wired: 1,
            compressor: 1
        )
        let zeroFields = CheckedMemorySummaryCalculator.fields(
            physicalTotalBytes: 64,
            counters: zeroPage,
            swapUsedBytes: 9
        )
        XCTAssertEqual(value(.physical, in: zeroFields), 64)
        XCTAssertEqual(value(.swapUsed, in: zeroFields), 9)
        for id in [MemoryFieldID.used, .cachedFiles, .appMemory, .wired, .compressed] {
            XCTAssertNil(value(id, in: zeroFields))
        }
        XCTAssertEqual(
            field(.wired, in: zeroFields)?.availability,
            .unavailable(.invalidSystemValue(source: .hostPageSize))
        )

        let overflow = HostMemoryCounters(
            pageSize: 4_096,
            free: 0,
            speculative: 0,
            external: .max,
            internal: 2,
            purgeable: 1,
            wired: .max,
            compressor: 1
        )
        let overflowFields = CheckedMemorySummaryCalculator.fields(
            physicalTotalBytes: .max,
            counters: overflow,
            swapUsedBytes: nil
        )
        XCTAssertNil(value(.used, in: overflowFields))
        XCTAssertNil(value(.cachedFiles, in: overflowFields))
        XCTAssertNil(value(.wired, in: overflowFields))
        XCTAssertEqual(
            field(.wired, in: overflowFields)?.availability,
            .unavailable(.arithmeticOverflow(formulaID: "hostvm.direct.wired"))
        )
        XCTAssertEqual(value(.appMemory, in: overflowFields), 4_096)
        XCTAssertEqual(value(.compressed, in: overflowFields), 4_096)
    }

    func testAppUnderflowDoesNotChangeUsedCacheOrDirectCounters() throws {
        let counters = HostMemoryCounters(
            pageSize: 1,
            free: 10,
            speculative: 2,
            external: 3,
            internal: 1,
            purgeable: 2,
            wired: 4,
            compressor: 5
        )
        let fields = CheckedMemorySummaryCalculator.fields(
            physicalTotalBytes: 100,
            counters: counters,
            swapUsedBytes: 6
        )

        XCTAssertEqual(value(.used, in: fields), 87)
        XCTAssertEqual(value(.cachedFiles, in: fields), 5)
        XCTAssertNil(value(.appMemory, in: fields))
        XCTAssertEqual(
            field(.appMemory, in: fields)?.availability,
            .unavailable(
                .arithmeticUnderflow(
                    formulaID: CheckedMemorySummaryCalculator.appFormulaID
                )
            )
        )
        XCTAssertEqual(value(.wired, in: fields), 4)
        XCTAssertEqual(value(.compressed, in: fields), 5)
    }

    func testTypedSourceFailuresRemainFieldLocal() {
        let fields = CheckedMemorySummaryCalculator.fields(
            physicalTotal: .unavailable(.sourceReadFailed(.physicalMemory)),
            counters: .unavailable(.shortSystemStructure(source: .hostVMInfo64)),
            swapUsed: .unavailable(.sourceReadFailed(.swapUsage))
        )

        XCTAssertEqual(
            field(.physical, in: fields)?.availability,
            .unavailable(.sourceReadFailed(.physicalMemory))
        )
        XCTAssertEqual(
            field(.used, in: fields)?.availability,
            .unavailable(.sourceReadFailed(.physicalMemory))
        )
        XCTAssertEqual(
            field(.cachedFiles, in: fields)?.availability,
            .unavailable(.shortSystemStructure(source: .hostVMInfo64))
        )
        XCTAssertEqual(
            field(.swapUsed, in: fields)?.availability,
            .unavailable(.sourceReadFailed(.swapUsage))
        )
    }

    func testMemoryStatusPressureNormalizationUsesFixedZeroToOneScale() {
        XCTAssertEqual(
            MemoryStatusPressureNormalizer.ratio(level: 100),
            0
        )
        XCTAssertEqual(
            MemoryStatusPressureNormalizer.ratio(level: 47),
            0.53
        )
        XCTAssertEqual(
            MemoryStatusPressureNormalizer.ratio(level: 0),
            1
        )
        XCTAssertNil(MemoryStatusPressureNormalizer.ratio(level: 101))
    }

    func testKernelPressureMapperDoesNotDefaultUnknownValuesToNormal() {
        XCTAssertEqual(KernelMemoryPressureMapper.state(level: 1), .normal)
        XCTAssertEqual(KernelMemoryPressureMapper.state(level: 2), .warning)
        XCTAssertEqual(KernelMemoryPressureMapper.state(level: 4), .critical)
        XCTAssertNil(KernelMemoryPressureMapper.state(level: 0))
        XCTAssertNil(KernelMemoryPressureMapper.state(level: 3))
    }

    func testMemoryStatusPressureReaderFailsClosedWithoutResolvedSymbol() {
        XCTAssertNil(MemoryStatusPressureReader.readRatio(using: nil))
    }

    func testMemoryStatusPressureReaderFailsClosedWhenCallFails() {
        XCTAssertNil(
            MemoryStatusPressureReader.readRatio(
                using: failingMemoryStatusLevel
            )
        )
    }

    func testMemoryStatusPressureReaderFailsClosedForOutOfRangeLevel() {
        XCTAssertNil(
            MemoryStatusPressureReader.readRatio(
                using: outOfRangeMemoryStatusLevel
            )
        )
    }

    func testMemoryStatusPressureReaderUsesInjectedSuccessfulLevel() {
        XCTAssertEqual(
            MemoryStatusPressureReader.readRatio(
                using: successfulMemoryStatusLevel
            ),
            0.53
        )
    }

    private func field(
        _ id: MemoryFieldID,
        in fields: [MemorySummaryField]
    ) -> MemorySummaryField? {
        fields.first { $0.id == id }
    }

    private func value(
        _ id: MemoryFieldID,
        in fields: [MemorySummaryField]
    ) -> UInt64? {
        field(id, in: fields)?.bytes
    }
}

private func failingMemoryStatusLevel(
    _ level: UnsafeMutablePointer<UInt32>
) -> Int32 {
    level.pointee = 47
    return -1
}

private func outOfRangeMemoryStatusLevel(
    _ level: UnsafeMutablePointer<UInt32>
) -> Int32 {
    level.pointee = 101
    return 0
}

private func successfulMemoryStatusLevel(
    _ level: UnsafeMutablePointer<UInt32>
) -> Int32 {
    level.pointee = 47
    return 0
}
