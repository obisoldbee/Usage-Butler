import Foundation

/// Keep Swift Charts' axis identities fixed while a live window and its rate
/// scale move. Date-valued ticks generated a new retained axis-label subtree
/// every second on macOS 27.2. These are drawing coordinates only; labels,
/// accessibility and inspection continue to use the original dates and rates.
public struct NetworkChartCoordinates: Equatable, Sendable {
    public static let ticks = [0.0, 0.5, 1.0]
    public let now: Date
    public let window: TimeInterval
    public let upperBound: Double

    public init(now: Date, window: TimeInterval, upperBound: Double) {
        precondition(window.isFinite && window > 0)
        precondition(upperBound.isFinite && upperBound > 0)
        self.now = now
        self.window = window
        self.upperBound = upperBound
    }

    // Do not clamp: an out-of-window point must not masquerade as an endpoint.
    public func x(at date: Date) -> Double { 1 + date.timeIntervalSince(now) / window }
    public func date(atX x: Double) -> Date { now.addingTimeInterval((x - 1) * window) }
    public func y(for rate: Double) -> Double { rate / upperBound }
    public func rate(atY y: Double) -> Double { y * upperBound }
}
