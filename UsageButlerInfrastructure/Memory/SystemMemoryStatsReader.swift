import Darwin
import Foundation
import UsageButlerCore
import UsageButlerDomain

public struct SystemMemoryStatsReader: MemoryStatsReader {
    public init() {}

    public func read(capturedAt: Date) async -> MemoryStatsReadback {
        let fields = CheckedMemorySummaryCalculator.fields(
            physicalTotal: physicalTotalBytes(),
            counters: hostMemoryCounters(),
            swapUsed: swapUsedBytes()
        )
        return MemoryStatsReadback(
            capturedAt: capturedAt,
            fields: fields,
            pressureRatio: MemoryStatusPressureReader.readRatio(),
            pressureState: KernelMemoryPressureReader.readState()
        )
    }

    private func physicalTotalBytes() -> MemoryInput<UInt64> {
        let value = ProcessInfo.processInfo.physicalMemory
        return value == 0
            ? .unavailable(.invalidSystemValue(source: .physicalMemory))
            : .available(value)
    }

    private func hostMemoryCounters() -> MemoryInput<HostMemoryCounters> {
        let host = mach_host_self()
        guard host != mach_port_t(MACH_PORT_NULL) else {
            return .unavailable(.sourceReadFailed(.hostVMInfo64))
        }
        defer { mach_port_deallocate(mach_task_self_, host) }

        var statistics = vm_statistics64()
        let requiredCount = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        var count = requiredCount
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return .unavailable(.sourceReadFailed(.hostVMInfo64))
        }
        guard count >= requiredCount else {
            return .unavailable(.shortSystemStructure(source: .hostVMInfo64))
        }

        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else {
            return .unavailable(.sourceReadFailed(.hostPageSize))
        }
        guard pageSize > 0 else {
            return .unavailable(.invalidSystemValue(source: .hostPageSize))
        }

        return .available(HostMemoryCounters(
            pageSize: UInt64(pageSize),
            free: UInt64(statistics.free_count),
            speculative: UInt64(statistics.speculative_count),
            external: UInt64(statistics.external_page_count),
            internal: UInt64(statistics.internal_page_count),
            purgeable: UInt64(statistics.purgeable_count),
            wired: UInt64(statistics.wire_count),
            compressor: UInt64(statistics.compressor_page_count)
        ))
    }

    private func swapUsedBytes() -> MemoryInput<UInt64> {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        guard result == 0 else {
            return .unavailable(.sourceReadFailed(.swapUsage))
        }
        guard size >= MemoryLayout<xsw_usage>.size else {
            return .unavailable(.shortSystemStructure(source: .swapUsage))
        }
        return .available(UInt64(usage.xsu_used))
    }
}

enum KernelMemoryPressureMapper {
    static func state(level: Int32) -> MemoryPressureState? {
        switch level {
        case 1: .normal
        case 2: .warning
        case 4: .critical
        default: nil
        }
    }
}

private enum KernelMemoryPressureReader {
    static func readState() -> MemoryPressureState? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(
            "kern.memorystatus_vm_pressure_level",
            &level,
            &size,
            nil,
            0
        ) == 0,
        size >= MemoryLayout<Int32>.size else {
            return nil
        }
        return KernelMemoryPressureMapper.state(level: level)
    }
}

/// Normalizes Activity Monitor's observed `100 - memorystatus level` value to
/// the chart's fixed 0...1 scale. This is deliberately independent from all VM
/// byte counters used by the summary table.
enum MemoryStatusPressureNormalizer {
    static func ratio(level: UInt32) -> Double? {
        guard level <= 100 else { return nil }
        return Double(100 - level) / 100
    }
}

enum MemoryStatusPressureReader {
    // This symbol is not part of the public macOS SDK. Resolve it dynamically
    // and fail closed so an unavailable or changed symbol cannot invent data.
    typealias GetLevel = @convention(c) (
        UnsafeMutablePointer<UInt32>
    ) -> Int32

    private static let getLevel: GetLevel? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        guard let symbol = dlsym(handle, "memorystatus_get_level") else {
            dlclose(handle)
            return nil
        }

        // Keep the process handle open for the process lifetime so the cached
        // function pointer remains valid between one-second samples.
        return unsafeBitCast(symbol, to: GetLevel.self)
    }()

    static func readRatio() -> Double? {
        readRatio(using: getLevel)
    }

    /// Testable fail-closed boundary for the dynamically resolved private ABI.
    /// Tests inject a C-compatible function and never resolve or call the live
    /// process symbol.
    static func readRatio(using getLevel: GetLevel?) -> Double? {
        guard let getLevel else { return nil }
        var level: UInt32 = 0
        guard getLevel(&level) == 0 else { return nil }
        return MemoryStatusPressureNormalizer.ratio(level: level)
    }
}
