import Foundation
import UsageButlerDomain

public struct HostMemoryCounters: Equatable, Sendable {
    public let pageSize: UInt64
    public let free: UInt64
    public let speculative: UInt64
    public let external: UInt64
    public let `internal`: UInt64
    public let purgeable: UInt64
    public let wired: UInt64
    public let compressor: UInt64

    public init(
        pageSize: UInt64,
        free: UInt64,
        speculative: UInt64,
        external: UInt64,
        internal: UInt64,
        purgeable: UInt64,
        wired: UInt64,
        compressor: UInt64
    ) {
        self.pageSize = pageSize
        self.free = free
        self.speculative = speculative
        self.external = external
        self.internal = `internal`
        self.purgeable = purgeable
        self.wired = wired
        self.compressor = compressor
    }
}

public enum CheckedMemorySummaryCalculator {
    public static let usedFormulaID = "hostvm-summary-v1.used"
    public static let cachedFormulaID = "hostvm-summary-v1.cached"
    public static let appFormulaID = "hostvm-summary-v1.app"

    public static func fields(
        physicalTotalBytes: UInt64?,
        counters: HostMemoryCounters?,
        swapUsedBytes: UInt64?
    ) -> [MemorySummaryField] {
        fields(
            physicalTotal: physicalTotalBytes.map(MemoryInput.available)
                ?? .unavailable(.sourceReadFailed(.physicalMemory)),
            counters: counters.map(MemoryInput.available)
                ?? .unavailable(.sourceReadFailed(.hostVMInfo64)),
            swapUsed: swapUsedBytes.map(MemoryInput.available)
                ?? .unavailable(.sourceReadFailed(.swapUsage))
        )
    }

    public static func fields(
        physicalTotal: MemoryInput<UInt64>,
        counters: MemoryInput<HostMemoryCounters>,
        swapUsed: MemoryInput<UInt64>
    ) -> [MemorySummaryField] {
        let physical = validatePositive(
            physicalTotal,
            source: .physicalMemory
        )
        let pageSize: MemoryInput<UInt64> = counters.flatMap { counters in
            guard counters.pageSize > 0 else {
                return .unavailable(.invalidSystemValue(source: .hostPageSize))
            }
            return .available(counters.pageSize)
        }

        return [
            MemorySummaryField(
                id: .physical,
                availability: physical.availability,
                provenance: .directSystemValue
            ),
            MemorySummaryField(
                id: .used,
                availability: usedBytes(
                    physicalTotal: physical,
                    counters: counters,
                    pageSize: pageSize
                ).availability,
                provenance: .derivedSystemEstimate(formulaID: usedFormulaID)
            ),
            MemorySummaryField(
                id: .cachedFiles,
                availability: counters.flatMap { counters in
                    checkedPageBytes(
                        counters.external,
                        counters.purgeable,
                        pageSize: pageSize,
                        formulaID: cachedFormulaID
                    )
                }.availability,
                provenance: .derivedSystemEstimate(formulaID: cachedFormulaID)
            ),
            MemorySummaryField(
                id: .swapUsed,
                availability: swapUsed.availability,
                provenance: .directSystemValue
            ),
            MemorySummaryField(
                id: .appMemory,
                availability: counters.flatMap { counters in
                    guard counters.internal >= counters.purgeable else {
                        return .unavailable(
                            .arithmeticUnderflow(formulaID: appFormulaID)
                        )
                    }
                    return checkedMultiply(
                        counters.internal - counters.purgeable,
                        by: pageSize,
                        formulaID: appFormulaID
                    )
                }.availability,
                provenance: .derivedSystemEstimate(formulaID: appFormulaID)
            ),
            MemorySummaryField(
                id: .wired,
                availability: counters.flatMap {
                    checkedMultiply(
                        $0.wired,
                        by: pageSize,
                        formulaID: "hostvm.direct.wired"
                    )
                }.availability,
                provenance: .directSystemValue
            ),
            MemorySummaryField(
                id: .compressed,
                availability: counters.flatMap {
                    checkedMultiply(
                        $0.compressor,
                        by: pageSize,
                        formulaID: "hostvm.direct.compressed"
                    )
                }.availability,
                provenance: .directSystemValue
            )
        ]
    }

    private static func usedBytes(
        physicalTotal: MemoryInput<UInt64>,
        counters: MemoryInput<HostMemoryCounters>,
        pageSize: MemoryInput<UInt64>
    ) -> MemoryInput<UInt64> {
        physicalTotal.flatMap { physicalTotalBytes in
            counters.flatMap { counters in
                guard counters.free >= counters.speculative else {
                    return .unavailable(
                        .inconsistentCounters(formulaID: usedFormulaID)
                    )
                }

                let adjustedFree = counters.free - counters.speculative
                return checkedAdd(
                    adjustedFree,
                    counters.external,
                    counters.purgeable,
                    formulaID: usedFormulaID
                ).flatMap { excludedPages in
                    checkedMultiply(
                        excludedPages,
                        by: pageSize,
                        formulaID: usedFormulaID
                    ).flatMap { excludedBytes in
                        guard physicalTotalBytes >= excludedBytes else {
                            return .unavailable(
                                .arithmeticUnderflow(formulaID: usedFormulaID)
                            )
                        }
                        return .available(physicalTotalBytes - excludedBytes)
                    }
                }
            }
        }
    }

    private static func checkedPageBytes(
        _ first: UInt64,
        _ second: UInt64,
        pageSize: MemoryInput<UInt64>,
        formulaID: String
    ) -> MemoryInput<UInt64> {
        checkedAdd(first, second, formulaID: formulaID).flatMap {
            checkedMultiply($0, by: pageSize, formulaID: formulaID)
        }
    }

    private static func checkedAdd(
        _ values: UInt64...,
        formulaID: String
    ) -> MemoryInput<UInt64> {
        var result: UInt64 = 0
        for value in values {
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else {
                return .unavailable(.arithmeticOverflow(formulaID: formulaID))
            }
            result = addition.partialValue
        }
        return .available(result)
    }

    private static func checkedMultiply(
        _ value: UInt64,
        by multiplier: MemoryInput<UInt64>,
        formulaID: String
    ) -> MemoryInput<UInt64> {
        multiplier.flatMap { multiplier in
            let product = value.multipliedReportingOverflow(by: multiplier)
            return product.overflow
                ? .unavailable(.arithmeticOverflow(formulaID: formulaID))
                : .available(product.partialValue)
        }
    }

    private static func validatePositive(
        _ input: MemoryInput<UInt64>,
        source: MemorySystemSource
    ) -> MemoryInput<UInt64> {
        input.flatMap { value in
            value > 0
                ? .available(value)
                : .unavailable(.invalidSystemValue(source: source))
        }
    }
}

public enum MemoryInput<Value: Equatable & Sendable>: Equatable, Sendable {
    case available(Value)
    case unavailable(MemoryUnavailableReason)

    fileprivate func flatMap<Output: Equatable & Sendable>(
        _ transform: (Value) -> MemoryInput<Output>
    ) -> MemoryInput<Output> {
        switch self {
        case let .available(value): transform(value)
        case let .unavailable(reason): .unavailable(reason)
        }
    }

}

private extension MemoryInput where Value == UInt64 {
    var availability: MemoryFieldAvailability {
        switch self {
        case let .available(bytes): .available(bytes: bytes)
        case let .unavailable(reason): .unavailable(reason)
        }
    }
}
