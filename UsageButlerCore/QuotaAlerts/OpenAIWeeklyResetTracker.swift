import Foundation
import UsageButlerDomain

/// Detects the OpenAI Codex weekly reset without requiring prior exhaustion.
///
/// OpenAI reports a rolling "now + 7 days" reset target while a full allowance
/// has not started a new usage window. That raw target is observation data, not
/// a stable cycle identity. This tracker promotes only a consumed or
/// multi-sample-stable target to an active boundary, then consumes that boundary
/// once the next weekly window becomes observable.
public enum OpenAIWeeklyResetTracker {
    public static let comparisonWindow: TimeInterval = 5 * 60
    public static let significantIncreasePoints = Decimal(5)

    private static let targetProductID = "codex"
    private static let observationKeyPrefix = "openai-weekly-reset-observation|"
    private static let fixedBoundaryJitter: TimeInterval = 60
    private static let minimumAnchorObservationSpan: TimeInterval = 2 * 60
    private static let minimumAnchorSampleCount = 3
    private static let weakBoundaryContinuityWindow: TimeInterval = 45 * 60
    private static let defaultWeeklyDuration: TimeInterval = 7 * 24 * 60 * 60
    private static let boundaryIdentityTolerance =
        QuotaExhaustionTracker.resetCycleToleranceSeconds

    private struct Observation {
        let sampleAt: Date
        let remainingPercent: Decimal
        let rawResetAt: Date?
        let candidateResetAt: Date?
        let candidateFirstSeenAt: Date?
        let candidateSampleCount: Int
        let activeBoundary: Date?
        let activeBoundaryIsWeak: Bool
        let successorBoundary: Date?
        let lastHandledBoundary: Date?
        let lastSignalledBoundary: Date?
        let lastSignalAt: Date?
        let lastUnanchoredSignalAt: Date?
    }

    /// Returns fresh reset statuses and advances the persisted observation even
    /// when no alert fires. Only current, fresh OpenAI "codex" weekly percent
    /// rows participate.
    public static func consume(
        data: ProviderQuotaData,
        into markers: inout [String: String]
    ) -> [QuotaMetricStatus] {
        guard data.providerID == .openAI else { return [] }

        var resets: [QuotaMetricStatus] = []
        for product in data.products where product.sourceProductID == targetProductID {
            for metric in product.metrics {
                guard metric.window?.kind == .weekly,
                      case let .fresh(sampleAt) = metric.state.freshness,
                      let remainingPercent = remainingPercent(for: metric.value),
                      remainingPercent >= 0,
                      remainingPercent <= 100 else {
                    continue
                }

                let metricKey = QuotaExhaustionEvaluator.stableMetricKey(
                    for: metric.id.sourceIdentity
                )
                let markerKey = observationKeyPrefix + metricKey
                let previous = markers[markerKey].flatMap(decode)
                if let previous, sampleAt <= previous.sampleAt {
                    continue
                }

                let rawResetAt = metric.window?.timeEvent?.occursAt
                let duration = metric.window?.duration
                let successorBoundary = successorBoundary(
                    previous: previous,
                    rawResetAt: rawResetAt,
                    duration: duration
                )
                let valueReset = previous.map {
                    hasExactFullRecovery(
                        previous: $0,
                        remainingPercent: remainingPercent
                    ) || hasSignificantHighValueIncrease(
                        previous: $0,
                        sampleAt: sampleAt,
                        remainingPercent: remainingPercent
                    )
                } ?? false
                let replacementWindow = previous.map {
                    hasStartedReplacementWindow(
                        previous: $0,
                        sampleAt: sampleAt,
                        remainingPercent: remainingPercent,
                        rawResetAt: rawResetAt,
                        duration: duration
                    )
                } ?? false
                let replacementWindowReset = replacementWindow && (
                    previous.map {
                        hasSignificantIncreasePoints(
                            previous: $0,
                            remainingPercent: remainingPercent
                        )
                    } ?? false
                )
                let handledBoundary = previous.flatMap {
                    resetBoundary(
                        previous: $0,
                        sampleAt: sampleAt,
                        remainingPercent: remainingPercent,
                        successorBoundary: successorBoundary,
                        valueReset: valueReset,
                        replacementWindowReset: replacementWindowReset
                    )
                }
                let valueOnlyReset = handledBoundary == nil
                    && previous?.activeBoundary == nil
                    && valueReset
                    && canSignalUnanchoredValueReset(
                        previous: previous,
                        sampleAt: sampleAt,
                        duration: duration
                    )
                let boundarySignalIsDuplicate = handledBoundary != nil
                    && isDuplicateBoundarySignal(
                        previous: previous,
                        boundary: handledBoundary,
                        sampleAt: sampleAt,
                        duration: duration
                    )
                let reconciledUnanchoredSignal = boundarySignalIsDuplicate
                    && latestSignalWasUnanchored(previous)
                let shouldSignalReset = (handledBoundary != nil
                    && !boundarySignalIsDuplicate) || valueOnlyReset

                let current = updatedObservation(
                    previous: previous,
                    sampleAt: sampleAt,
                    remainingPercent: remainingPercent,
                    rawResetAt: rawResetAt,
                    observedSuccessorBoundary: successorBoundary,
                    handledBoundary: handledBoundary,
                    consumedValueOnlyReset: valueOnlyReset,
                    reconciledUnanchoredSignal: reconciledUnanchoredSignal,
                    didSignalReset: shouldSignalReset,
                    replacingActiveBoundary: replacementWindow && handledBoundary == nil
                )

                if shouldSignalReset {
                    let cycleKey = handledBoundary.map {
                        "reset:\($0.timeIntervalSince1970)"
                    } ?? "observed:\(sampleAt.timeIntervalSince1970)"
                    resets.append(
                        QuotaMetricStatus(
                            providerID: .openAI,
                            metricKey: metricKey,
                            productLabel: "Codex",
                            windowLabel: "每周",
                            usageSummary: "剩余 \(remainingPercent)%",
                            cycleKey: cycleKey,
                            resetAt: rawResetAt,
                            isExhausted: false
                        )
                    )
                }

                markers[markerKey] = encode(current)
            }
        }
        return resets
    }

    private static func resetBoundary(
        previous: Observation,
        sampleAt: Date,
        remainingPercent: Decimal,
        successorBoundary: Date?,
        valueReset: Bool,
        replacementWindowReset: Bool
    ) -> Date? {
        guard let boundary = previous.activeBoundary,
              remainingPercent > 0,
              !sameBoundary(boundary, previous.lastHandledBoundary) else {
            return nil
        }
        if replacementWindowReset { return boundary }
        guard sampleAt >= boundary else { return nil }
        if previous.activeBoundaryIsWeak,
           remainingPercent == 100,
           sampleAt.timeIntervalSince(previous.sampleAt)
            > weakBoundaryContinuityWindow {
            // A weak 100%-only anchor cannot survive an observation gap: the
            // target may simply have resumed its normal now+7d slide.
            return nil
        }

        let targetAdvancedByWindow = successorBoundary != nil
        let nearFullAfterBoundary = remainingPercent >= 99
        return targetAdvancedByWindow || nearFullAfterBoundary || valueReset
            ? boundary
            : nil
    }

    private static func successorBoundary(
        previous: Observation?,
        rawResetAt: Date?,
        duration: TimeInterval?
    ) -> Date? {
        guard let previous,
              let boundary = previous.activeBoundary else {
            return nil
        }
        let cycleDuration = duration.flatMap { $0 > 0 ? $0 : nil }
            ?? defaultWeeklyDuration
        guard let rawResetAt,
              rawResetAt.timeIntervalSince(boundary)
                >= cycleDuration - boundaryIdentityTolerance else {
            return previous.successorBoundary
        }
        guard let carried = previous.successorBoundary else {
            return rawResetAt
        }
        return max(carried, rawResetAt)
    }

    private static func isDuplicateBoundarySignal(
        previous: Observation?,
        boundary: Date?,
        sampleAt: Date,
        duration: TimeInterval?
    ) -> Bool {
        guard let previous, let boundary else { return false }
        if sameBoundary(boundary, previous.lastSignalledBoundary) {
            return true
        }
        guard latestSignalWasUnanchored(previous) else {
            // Distinct, known boundaries are different cycles even when the
            // preceding cycle was observed late after the App was closed.
            return false
        }
        return wasSignalledWithinCurrentWindow(
            previous: previous,
            sampleAt: sampleAt,
            duration: duration
        )
    }

    private static func latestSignalWasUnanchored(
        _ observation: Observation?
    ) -> Bool {
        guard let lastSignalAt = observation?.lastSignalAt,
              let lastUnanchoredSignalAt = observation?.lastUnanchoredSignalAt
        else {
            return false
        }
        return abs(lastSignalAt.timeIntervalSince(lastUnanchoredSignalAt)) < 1
    }

    private static func canSignalUnanchoredValueReset(
        previous: Observation?,
        sampleAt: Date,
        duration: TimeInterval?
    ) -> Bool {
        !wasSignalledWithinCurrentWindow(
            previous: previous,
            sampleAt: sampleAt,
            duration: duration
        )
    }

    private static func wasSignalledWithinCurrentWindow(
        previous: Observation?,
        sampleAt: Date,
        duration: TimeInterval?
    ) -> Bool {
        guard let lastSignalAt = previous?.lastSignalAt
            ?? previous?.lastUnanchoredSignalAt else {
            return false
        }
        let cycleDuration = duration.flatMap { $0 > 0 ? $0 : nil }
            ?? defaultWeeklyDuration
        let elapsed = sampleAt.timeIntervalSince(lastSignalAt)
        return elapsed >= 0
            && elapsed < max(0, cycleDuration - comparisonWindow)
    }

    private static func updatedObservation(
        previous: Observation?,
        sampleAt: Date,
        remainingPercent: Decimal,
        rawResetAt: Date?,
        observedSuccessorBoundary: Date?,
        handledBoundary: Date?,
        consumedValueOnlyReset: Bool,
        reconciledUnanchoredSignal: Bool,
        didSignalReset: Bool,
        replacingActiveBoundary: Bool
    ) -> Observation {
        var candidateResetAt = previous?.candidateResetAt
        var candidateFirstSeenAt = previous?.candidateFirstSeenAt
        var candidateSampleCount = previous?.candidateSampleCount ?? 0
        var activeBoundary = previous?.activeBoundary
        var activeBoundaryIsWeak = previous?.activeBoundaryIsWeak ?? false
        var successorBoundary = observedSuccessorBoundary
        var lastHandledBoundary = previous?.lastHandledBoundary
        var lastSignalledBoundary = previous?.lastSignalledBoundary
        var lastUnanchoredSignalAt = previous?.lastUnanchoredSignalAt

        if replacingActiveBoundary {
            activeBoundary = nil
            activeBoundaryIsWeak = false
            candidateResetAt = nil
            candidateFirstSeenAt = nil
            candidateSampleCount = 0
            successorBoundary = nil
        }

        if let currentBoundary = activeBoundary,
           activeBoundaryIsWeak,
           remainingPercent == 100,
           sampleAt >= currentBoundary,
           sampleAt.timeIntervalSince(previous?.sampleAt ?? sampleAt)
            > weakBoundaryContinuityWindow {
            activeBoundary = nil
            activeBoundaryIsWeak = false
            candidateResetAt = nil
            candidateFirstSeenAt = nil
            candidateSampleCount = 0
            successorBoundary = nil
        }

        if let handledBoundary {
            let nextBoundary = successorBoundary
            activeBoundary = nil
            activeBoundaryIsWeak = false
            candidateResetAt = nil
            candidateFirstSeenAt = nil
            candidateSampleCount = 0
            successorBoundary = nil
            lastHandledBoundary = handledBoundary
            if remainingPercent < 100,
               let nextBoundary,
               !sameBoundary(nextBoundary, handledBoundary) {
                activeBoundary = nextBoundary
            }
        } else if consumedValueOnlyReset {
            candidateResetAt = nil
            candidateFirstSeenAt = nil
            candidateSampleCount = 0
            successorBoundary = nil
            lastUnanchoredSignalAt = sampleAt
        }

        if (didSignalReset || reconciledUnanchoredSignal),
           let handledBoundary {
            lastSignalledBoundary = handledBoundary
        }
        if reconciledUnanchoredSignal {
            lastUnanchoredSignalAt = nil
        }

        if let rawResetAt,
           !sameBoundary(rawResetAt, lastHandledBoundary),
           rawResetAt.timeIntervalSince(sampleAt)
            >= -boundaryIdentityTolerance {
            if let currentBoundary = activeBoundary,
               activeBoundaryIsWeak,
               remainingPercent == 100,
               abs(rawResetAt.timeIntervalSince(currentBoundary))
                > fixedBoundaryJitter {
                // A full allowance can briefly repeat a cached target before
                // resuming its now+7d slide. Weak anchors must be reversible.
                activeBoundary = nil
                activeBoundaryIsWeak = false
                candidateResetAt = nil
                candidateFirstSeenAt = nil
                candidateSampleCount = 0
                successorBoundary = nil
            }

            if activeBoundary == nil {
                if remainingPercent < 100 {
                    activeBoundary = rawResetAt
                    activeBoundaryIsWeak = false
                    candidateResetAt = nil
                    candidateFirstSeenAt = nil
                    candidateSampleCount = 0
                } else if rawResetAt > sampleAt,
                          let candidate = candidateResetAt,
                          let firstSeenAt = candidateFirstSeenAt,
                          abs(rawResetAt.timeIntervalSince(candidate))
                            <= fixedBoundaryJitter {
                    candidateSampleCount += 1
                    if candidateSampleCount >= minimumAnchorSampleCount,
                       sampleAt.timeIntervalSince(firstSeenAt)
                        >= minimumAnchorObservationSpan {
                        activeBoundary = rawResetAt
                        activeBoundaryIsWeak = true
                        candidateResetAt = nil
                        candidateFirstSeenAt = nil
                        candidateSampleCount = 0
                    }
                } else if rawResetAt > sampleAt {
                    candidateResetAt = rawResetAt
                    candidateFirstSeenAt = sampleAt
                    candidateSampleCount = 1
                } else {
                    candidateResetAt = nil
                    candidateFirstSeenAt = nil
                    candidateSampleCount = 0
                }
            } else if remainingPercent < 100,
                      let currentBoundary = activeBoundary,
                      activeBoundaryIsWeak
                        || sameBoundary(rawResetAt, currentBoundary) {
                // Consumption makes the Provider target authoritative and
                // upgrades any rounded-to-100 weak anchor.
                activeBoundary = rawResetAt
                activeBoundaryIsWeak = false
                candidateResetAt = nil
                candidateFirstSeenAt = nil
                candidateSampleCount = 0
            }
        } else if activeBoundary == nil {
            candidateResetAt = nil
            candidateFirstSeenAt = nil
            candidateSampleCount = 0
        }

        return Observation(
            sampleAt: sampleAt,
            remainingPercent: remainingPercent,
            rawResetAt: rawResetAt,
            candidateResetAt: candidateResetAt,
            candidateFirstSeenAt: candidateFirstSeenAt,
            candidateSampleCount: candidateSampleCount,
            activeBoundary: activeBoundary,
            activeBoundaryIsWeak: activeBoundaryIsWeak,
            successorBoundary: successorBoundary,
            lastHandledBoundary: lastHandledBoundary,
            lastSignalledBoundary: lastSignalledBoundary,
            lastSignalAt: didSignalReset ? sampleAt : previous?.lastSignalAt,
            lastUnanchoredSignalAt: lastUnanchoredSignalAt
        )
    }

    private static func hasSignificantHighValueIncrease(
        previous: Observation,
        sampleAt: Date,
        remainingPercent: Decimal
    ) -> Bool {
        remainingPercent >= 99
            && hasSignificantIncrease(
                previous: previous,
                sampleAt: sampleAt,
                remainingPercent: remainingPercent
            )
    }

    private static func hasSignificantIncrease(
        previous: Observation,
        sampleAt: Date,
        remainingPercent: Decimal
    ) -> Bool {
        let elapsed = sampleAt.timeIntervalSince(previous.sampleAt)
        return elapsed > 0
            && elapsed <= comparisonWindow
            && hasSignificantIncreasePoints(
                previous: previous,
                remainingPercent: remainingPercent
            )
    }

    private static func hasSignificantIncreasePoints(
        previous: Observation,
        remainingPercent: Decimal
    ) -> Bool {
        remainingPercent - previous.remainingPercent >= significantIncreasePoints
    }

    /// A consumed weekly window whose derived start is already in the past
    /// cannot belong to a different strong boundary that is still in the
    /// future. This repairs a drifted marker without treating an early
    /// next-window target as a reset.
    private static func hasStartedReplacementWindow(
        previous: Observation,
        sampleAt: Date,
        remainingPercent: Decimal,
        rawResetAt: Date?,
        duration: TimeInterval?
    ) -> Bool {
        guard let boundary = previous.activeBoundary,
              !previous.activeBoundaryIsWeak,
              boundary > sampleAt,
              remainingPercent > 0,
              remainingPercent <= 100,
              let rawResetAt,
              rawResetAt.timeIntervalSince(boundary) > boundaryIdentityTolerance else {
            return false
        }
        let cycleDuration = duration.flatMap { $0 > 0 ? $0 : nil }
            ?? defaultWeeklyDuration
        return rawResetAt.addingTimeInterval(-cycleDuration) <= sampleAt
    }

    private static func hasExactFullRecovery(
        previous: Observation,
        remainingPercent: Decimal
    ) -> Bool {
        previous.remainingPercent < 100 && remainingPercent == 100
    }

    private static func sameBoundary(_ lhs: Date, _ rhs: Date?) -> Bool {
        guard let rhs else { return false }
        return abs(lhs.timeIntervalSince(rhs)) <= boundaryIdentityTolerance
    }

    private static func remainingPercent(
        for value: QuotaMetricValue
    ) -> Decimal? {
        guard case let .percent(percent) = value else { return nil }
        switch percent.sourceDirection {
        case .used:
            return 100 - percent.sourceValue
        case .remaining:
            return percent.sourceValue
        case .neutral:
            return nil
        }
    }

    private static func encode(_ observation: Observation) -> String {
        [
            "v4",
            encode(observation.sampleAt),
            observation.remainingPercent.description,
            encode(observation.rawResetAt),
            encode(observation.candidateResetAt),
            encode(observation.candidateFirstSeenAt),
            String(observation.candidateSampleCount),
            encode(observation.activeBoundary),
            observation.activeBoundaryIsWeak ? "1" : "0",
            encode(observation.successorBoundary),
            encode(observation.lastHandledBoundary),
            encode(observation.lastSignalledBoundary),
            encode(observation.lastSignalAt),
            encode(observation.lastUnanchoredSignalAt)
        ].joined(separator: "|")
    }

    private static func encode(_ date: Date?) -> String {
        date?.timeIntervalSince1970.description ?? ""
    }

    private static func decode(_ encoded: String) -> Observation? {
        let fields = encoded.split(
            separator: "|",
            omittingEmptySubsequences: false
        ).map(String.init)
        switch fields.first {
        case "v4":
            return decodeV4(fields)
        case "v3":
            return decodeV3(fields)
        case "v2":
            return decodeV2(fields)
        case "v1":
            return decodeV1(fields)
        default:
            return nil
        }
    }

    private static func decodeV4(_ fields: [String]) -> Observation? {
        guard fields.count == 14,
              let sampleAt = decodeDate(fields[1]),
              let remainingPercent = Decimal(
                  string: fields[2],
                  locale: Locale(identifier: "en_US_POSIX")
              ),
              let candidateSampleCount = Int(fields[6]),
              fields[8] == "0" || fields[8] == "1" else {
            return nil
        }
        return Observation(
            sampleAt: sampleAt,
            remainingPercent: remainingPercent,
            rawResetAt: decodeDate(fields[3]),
            candidateResetAt: decodeDate(fields[4]),
            candidateFirstSeenAt: decodeDate(fields[5]),
            candidateSampleCount: max(0, candidateSampleCount),
            activeBoundary: decodeDate(fields[7]),
            activeBoundaryIsWeak: fields[8] == "1",
            successorBoundary: decodeDate(fields[9]),
            lastHandledBoundary: decodeDate(fields[10]),
            lastSignalledBoundary: decodeDate(fields[11]),
            lastSignalAt: decodeDate(fields[12]),
            lastUnanchoredSignalAt: decodeDate(fields[13])
        )
    }

    private static func decodeV3(_ fields: [String]) -> Observation? {
        guard fields.count == 12,
              let sampleAt = decodeDate(fields[1]),
              let remainingPercent = Decimal(
                  string: fields[2],
                  locale: Locale(identifier: "en_US_POSIX")
              ),
              let candidateSampleCount = Int(fields[6]),
              fields[8] == "0" || fields[8] == "1" else {
            return nil
        }
        let lastHandledBoundary = decodeDate(fields[9])
        let lastSignalAt = decodeDate(fields[10])
        let lastUnanchoredSignalAt = decodeDate(fields[11])
        let rawResetAt = decodeDate(fields[3])
        let activeBoundary = decodeDate(fields[7])
        let successorBoundary: Date?
        if let activeBoundary,
           let rawResetAt,
           rawResetAt.timeIntervalSince(activeBoundary)
            >= defaultWeeklyDuration - boundaryIdentityTolerance {
            successorBoundary = rawResetAt
        } else {
            successorBoundary = nil
        }
        let lastSignalledBoundary: Date?
        if let lastHandledBoundary,
           lastSignalAt != nil,
           lastSignalAt != lastUnanchoredSignalAt {
            lastSignalledBoundary = lastHandledBoundary
        } else {
            lastSignalledBoundary = nil
        }
        return Observation(
            sampleAt: sampleAt,
            remainingPercent: remainingPercent,
            rawResetAt: rawResetAt,
            candidateResetAt: decodeDate(fields[4]),
            candidateFirstSeenAt: decodeDate(fields[5]),
            candidateSampleCount: max(0, candidateSampleCount),
            activeBoundary: activeBoundary,
            activeBoundaryIsWeak: fields[8] == "1",
            successorBoundary: successorBoundary,
            lastHandledBoundary: lastHandledBoundary,
            lastSignalledBoundary: lastSignalledBoundary,
            lastSignalAt: lastSignalAt,
            lastUnanchoredSignalAt: lastUnanchoredSignalAt
        )
    }

    private static func decodeV2(_ fields: [String]) -> Observation? {
        guard fields.count == 9,
              let sampleAt = decodeDate(fields[1]),
              let remainingPercent = Decimal(
                  string: fields[2],
                  locale: Locale(identifier: "en_US_POSIX")
              ) else {
            return nil
        }
        let lastHandledBoundary = decodeDate(fields[7])
        let lastSignalAt = decodeDate(fields[8])
        return Observation(
            sampleAt: sampleAt,
            remainingPercent: remainingPercent,
            rawResetAt: decodeDate(fields[3]),
            candidateResetAt: decodeDate(fields[4]),
            candidateFirstSeenAt: decodeDate(fields[5]),
            candidateSampleCount: decodeDate(fields[4]) == nil ? 0 : 1,
            activeBoundary: decodeDate(fields[6]),
            activeBoundaryIsWeak: decodeDate(fields[6]) != nil
                && remainingPercent == 100,
            successorBoundary: nil,
            lastHandledBoundary: lastHandledBoundary,
            lastSignalledBoundary: lastSignalAt == nil
                ? nil
                : lastHandledBoundary,
            lastSignalAt: lastSignalAt,
            lastUnanchoredSignalAt: lastHandledBoundary == nil
                ? lastSignalAt : nil
        )
    }

    private static func decodeV1(_ fields: [String]) -> Observation? {
        guard fields.count == 6,
              let sampleAt = decodeDate(fields[1]),
              let remainingPercent = Decimal(
                  string: fields[2],
                  locale: Locale(identifier: "en_US_POSIX")
              ) else {
            return nil
        }
        let rawResetAt = QuotaExhaustionTracker
            .resetTimestamp(from: fields[3])
            .map(Date.init(timeIntervalSince1970:))
        let lastSignalAt = decodeDate(fields[4])
        let lastAlertTarget = QuotaExhaustionTracker
            .resetTimestamp(from: fields[5])
            .map(Date.init(timeIntervalSince1970:))
        let lastSignalledBoundary = lastSignalAt.flatMap { _ in
            lastAlertTarget?.addingTimeInterval(-defaultWeeklyDuration)
        }
        let currentTargetWasAlertTarget: Bool
        if let rawResetAt, let lastAlertTarget {
            currentTargetWasAlertTarget = sameBoundary(
                rawResetAt,
                lastAlertTarget
            )
        } else {
            currentTargetWasAlertTarget = lastAlertTarget == nil
        }
        let activeBoundary = remainingPercent < 100
            && currentTargetWasAlertTarget ? rawResetAt : nil
        return Observation(
            sampleAt: sampleAt,
            remainingPercent: remainingPercent,
            rawResetAt: rawResetAt,
            candidateResetAt: activeBoundary == nil ? rawResetAt : nil,
            candidateFirstSeenAt: activeBoundary == nil
                && rawResetAt != nil ? sampleAt : nil,
            candidateSampleCount: activeBoundary == nil
                && rawResetAt != nil ? 1 : 0,
            activeBoundary: activeBoundary,
            activeBoundaryIsWeak: false,
            successorBoundary: nil,
            lastHandledBoundary: lastSignalledBoundary,
            lastSignalledBoundary: lastSignalledBoundary,
            lastSignalAt: lastSignalAt,
            lastUnanchoredSignalAt: lastSignalAt != nil
                && lastSignalledBoundary == nil ? lastSignalAt : nil
        )
    }

    private static func decodeDate(_ encoded: String) -> Date? {
        guard !encoded.isEmpty, let timestamp = TimeInterval(encoded) else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }
}
