import Dispatch
import UsageButlerCore
import UsageButlerDomain

public final class DispatchMemoryPressureSource: MemoryPressureSource, @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "io.github.obisoldbee.UsageButler.memory-pressure",
        qos: .utility
    )

    public init() {}

    public func events() async -> AsyncStream<MemoryPressureState> {
        let queue = self.queue
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.normal, .warning, .critical],
                queue: queue
            )
            source.setEventHandler {
                continuation.yield(
                    MemoryPressureEventMapper.state(for: source.data)
                )
            }
            source.setCancelHandler {
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                source.cancel()
            }
            source.resume()
        }
    }
}

enum MemoryPressureEventMapper {
    static func state(
        for event: DispatchSource.MemoryPressureEvent
    ) -> MemoryPressureState {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .warning }
        if event.contains(.normal) { return .normal }
        return .unknown
    }
}
