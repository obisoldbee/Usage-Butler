import Foundation
import UsageButlerDomain

public protocol ProcessNetworkSource: Sendable {
    func events() -> AsyncStream<ProcessNetworkFrame>
    /// Returns after this source's owned child and file descriptors close.
    func stop() async
}
