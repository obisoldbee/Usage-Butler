import Darwin
import Foundation
import UsageButlerCore

public enum SystemHistoryAgeClock {
    public static func sample() -> HistoryAgeSample {
        var bytes = [CChar](repeating: 0, count: 128); var size = bytes.count
        let success = sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0
        let boot = success ? String(cString: bytes) : ""
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        let ticks = mach_continuous_time(), denominator = UInt64(max(1, timebase.denom))
        let nanos = (ticks / denominator) * UInt64(timebase.numer)
            + (ticks % denominator) * UInt64(timebase.numer) / denominator
        return .init(boot: boot, continuousNanoseconds: nanos)
    }
}
