import Foundation
import UsageButlerDomain

/// Pure projection from the production Provider state tree into the existing
/// Stage 3 presentation DTO. The caller supplies `now`; this mapper performs no
/// I/O, starts no Provider process, and never reads wall-clock time itself.
public enum LiveProviderProjectionMapper {
    /// Disabled Providers are a visibility preference and do not enter the quota
    /// overview. Their retained state remains owned by `ProviderController`.
    public static func map(
        _ projection: ProviderProjection,
        now: Date,
        isProductEnabled: ((ProviderID, String) -> Bool)? = nil,
        monotonicNow: MonotonicInstant? = nil
    ) -> Stage3ProviderProjection? {
        guard projection.isEnabled else { return nil }
        return map(
            projection.state,
            phase: projection.phase,
            now: now,
            isProductEnabled: isProductEnabled,
            monotonicNow: monotonicNow, automaticRetry: projection.automaticRefresh
        )
    }

    public static func map(
        _ projections: [ProviderProjection],
        now: Date,
        isProductEnabled: ((ProviderID, String) -> Bool)? = nil,
        monotonicNow: MonotonicInstant? = nil
    ) -> [Stage3ProviderProjection] {
        projections
            .compactMap { map($0, now: now, isProductEnabled: isProductEnabled, monotonicNow: monotonicNow) }
            .sorted { $0.id.canonicalOrder < $1.id.canonicalOrder }
    }

    /// State-only entry point for deterministic tests and consumers that already
    /// applied Provider visibility policy.
    public static func map(
        _ state: ProviderState,
        now: Date,
        isProductEnabled: ((ProviderID, String) -> Bool)? = nil,
        monotonicNow: MonotonicInstant? = nil,
        automaticRetry: Bool? = nil
    ) -> Stage3ProviderProjection {
        map(state, phase: nil, now: now, isProductEnabled: isProductEnabled, monotonicNow: monotonicNow, automaticRetry: automaticRetry)
    }

    private static func map(
        _ state: ProviderState,
        phase: ProviderControllerPhase?,
        now: Date,
        isProductEnabled: ((ProviderID, String) -> Bool)? = nil,
        monotonicNow: MonotonicInstant? = nil,
        automaticRetry: Bool? = nil
    ) -> Stage3ProviderProjection {
        let quota = state.lastGood
        let visibleProducts = quota?.products.filter { product in
            if let isProductEnabled {
                guard isProductEnabled(state.id, product.sourceProductID) else { return false }
            } else {
                guard !isAuthoritativelyAbsent(product.state.presence) else { return false }
            }
            return true
        } ?? []

        let content = projectContent(
            providerID: state.id,
            products: visibleProducts,
            resetEntitlements: quota?.resetEntitlements ?? [],
            balances: quota?.balances ?? [],
            quota: quota
        )

        return Stage3ProviderProjection(
            id: state.id,
            rowState: rowState(for: state, phase: phase),
            dataState: dataState(for: state.freshness),
            activity: activity(for: state.refresh.activity),
            partialDataState: partialDataState(
                providerFreshness: state.freshness,
                products: visibleProducts,
                resetEntitlements: quota?.resetEntitlements ?? []
            ),
            failureCode: displayFailureCode(for: state),
            isQuotaValidationFailure: state.scopedFailures.current?.failure.userMessageKey == "provider.failure.partial-schema",
            retryAt: automaticRetry == true ? monotonicNow.flatMap {
                ProviderRetryTiming.date(for: state.refresh.gate, reading: ClockReading(wallTime: now, monotonicTime: $0))
            } : nil,
            automaticRetry: automaticRetry,
            loginMethod: state.capabilities.loginMethod,
            authenticationExpiresAt: authenticationExpiresAt(state.authentication),
            hasOfficialDocumentation: state.capabilities.hasOfficialDocumentation,
            allowsExecutableSelection: state.capabilities.allowsExecutableSelection,
            planLevel: content.providerPlan,
            sourceNotice: grokBotNotice(state),
            products: content.products,
            capturedAt: quota?.fetchedAt ?? now,
            origin: .runtime
        )
    }

    private static func authenticationExpiresAt(_ state: AuthenticationState) -> Date? {
        switch state {
        case let .healthy(evidence), let .warning(evidence), let .unknown(evidence): evidence.expiresAt
        case .expired: nil
        }
    }

    private static func dataState(
        for freshness: FreshnessState
    ) -> Stage3ProviderDataState {
        switch freshness {
        case .unknown:
            return .unknown
        case let .fresh(asOf):
            return .fresh(asOf: asOf)
        case let .stale(asOf, _):
            return .stale(asOf: asOf)
        }
    }

    private static func activity(
        for activity: RefreshActivity
    ) -> Stage3ProviderActivity {
        switch activity {
        case .idle:
            .idle
        case .detecting:
            .detecting
        case .refreshing:
            .refreshing
        case .loggingIn:
            .loggingIn
        case .shuttingDown:
            .shuttingDown
        }
    }

    private static func metricDataState(
        for freshness: FreshnessState
    ) -> Stage3QuotaMetricDataState? {
        switch freshness {
        case .unknown:
            nil
        case let .fresh(asOf):
            .fresh(asOf: asOf)
        case let .stale(asOf, _):
            .stale(asOf: asOf)
        }
    }

    private static func partialDataState(
        providerFreshness: FreshnessState,
        products: [QuotaProductData],
        resetEntitlements: [ResetEntitlementSummary]
    ) -> Stage3PartialDataState? {
        guard case .stale = providerFreshness else { return nil }

        let visibleNodeFreshness = products.flatMap { product in
            [product.state.freshness] + product.metrics.map(\.state.freshness)
        } + resetEntitlements.map(\.state.freshness)
        let freshAsOf = visibleNodeFreshness.compactMap { freshness -> Date? in
            guard case let .fresh(asOf) = freshness else { return nil }
            return asOf
        }.max()
        let retainedStaleAsOf = visibleNodeFreshness.compactMap { freshness -> Date? in
            guard case let .stale(asOf, _) = freshness else { return nil }
            return asOf
        }.max()

        guard let freshAsOf, let retainedStaleAsOf else { return nil }
        return Stage3PartialDataState(
            freshAsOf: freshAsOf,
            retainedStaleAsOf: retainedStaleAsOf
        )
    }

    private static func displayFailureCode(
        for state: ProviderState
    ) -> FailureCode? {
        let code = state.scopedFailures.current?.failure.code
        switch code {
        case .authenticationRequired, .authenticationExpired:
            // Authentication has a dedicated, evidence-aware row state. Keeping it
            // out of the generic failure channel prevents two competing banners.
            return nil
        default:
            return code
        }
    }

    private struct ProjectedContent {
        let providerPlan: Stage3PlanBadge?
        let products: [Stage3QuotaProductProjection]
    }

    private static func projectContent(
        providerID: ProviderID,
        products: [QuotaProductData],
        resetEntitlements: [ResetEntitlementSummary],
        balances: [QuotaBalance],
        quota: ProviderQuotaData?
    ) -> ProjectedContent {
        let orderedProducts = products.sorted(by: productComesBefore)

        switch providerID {
        case .openAI:
            let metrics = orderedProducts.flatMap { product in
                product.metrics.compactMap {
                    projectOpenAIMetric($0, product: product)
                }
            } + resetEntitlements.compactMap(projectOpenAIResetEntitlement)
              + balances.map { balance in
                  Stage3QuotaMetricProjection(id: "balance." + balance.sourceBalanceID, title: "Credits",
                      value: .balance(amount: balance.amount, unlimited: balance.unlimited),
                      dataState: metricDataState(for: balance.state.freshness))
              }
            let projectedProducts = metrics.isEmpty && orderedProducts.isEmpty
                ? []
                : [
                    Stage3QuotaProductProjection(
                        id: "runtime.openai.overview",
                        metrics: metrics
                    )
                ]
            return ProjectedContent(
                providerPlan: orderedProducts.lazy.compactMap { planBadge($0.planLevel) }.first,
                products: projectedProducts
            )

        case .miniMax:
            let metrics = orderedProducts.flatMap { product in
                product.metrics.compactMap {
                    projectMiniMaxMetric($0, product: product)
                }
            }
            let projectedProducts = metrics.isEmpty && orderedProducts.isEmpty
                ? []
                : [
                    Stage3QuotaProductProjection(
                        id: "runtime.minimax.overview",
                        metrics: metrics
                    )
                ]
            return ProjectedContent(
                providerPlan: orderedProducts.lazy.compactMap { planBadge($0.planLevel) }.first,
                products: projectedProducts
            )

        case .grokBot:
            if quota?.source.adapterID == "cursor-grok-shared", let shared = quota?.grokBotUsage?.shared {
                return ProjectedContent(providerPlan: nil, products: orderedProducts.map { product in
                    .init(id: "runtime.grokbot.shared", sourceProductID: product.sourceProductID,
                        title: String(localized: "Grok / Cursor 共享周额度"), metrics: product.metrics.map { metric in
                            let number = shared.usagePercent.flatMap(boundedPercent)
                            return .init(id: stableMetricID(metric.id), title: String(localized: "每周"),
                                value: shared.weeklyValueState == .available && number != nil ? .percent(value: number!, direction: .used) : .unavailable,
                                event: shared.availability == .available && shared.weeklyStatus == .metered
                                    ? shared.resetsAt.map { .init(kind: .reset, occursAt: $0, style: .absoluteDateTime) } : nil,
                                dataState: metricDataState(for: metric.state.freshness),
                                displayValueText: sharedValueText(shared), detailText: sharedDetailText(shared))
                        })
                })
            }
            return ProjectedContent(providerPlan: nil, products: orderedProducts.map { product in
                Stage3QuotaProductProjection(id: "runtime.grokbot.overview", metrics: product.metrics.map { metric in
                    let value: Stage3QuotaValue
                    if case let .percent(percent) = metric.value, let number = boundedPercent(percent.sourceValue) {
                        value = .percent(value: number, direction: .used)
                    } else { value = .unavailable }
                    return Stage3QuotaMetricProjection(id: stableMetricID(metric.id), title: "Sand 来源读数", value: value,
                        event: metric.window?.timeEvent.map { event in
                            Stage3TimeEvent(kind: event.kind == .entitlementExpiry ? .entitlementExpiry : .reset,
                                occursAt: event.occursAt, style: .absoluteDateTime)
                        }, dataState: metricDataState(for: metric.state.freshness))
                })
            })
        case .ark:
            return ProjectedContent(
                providerPlan: nil,
                products: orderedProducts.map(projectArkProduct)
            )
        }
    }

    private static func grokBotNotice(_ state: ProviderState) -> String? {
        guard state.id == .grokBot else { return nil }
        guard let observation = state.lastGood?.grokBotUsage else {
            return "仅支持已授权的 Cursor 登录来源。请在设置中确认授权和来源状态。"
        }
        if let shared = observation.shared {
            switch shared.availability {
            case .identityUnlinked: return String(localized: "官方尚未提供此账户的共享用量。请在官方页面核对账户关联。")
            case .missingTeamID: return String(localized: "官方返回了团队作用域错误，请重试并核对账户。")
            case .unknown: return String(localized: "共享用量状态未提供，请稍后重试。")
            case .available: return nil
            }
        }
        let meter: String
        switch observation.meteringSystem {
        case .unknown: meter = "Sand 来源读数，账户计量体系未确认。"
        case .xShared: meter = "共享周额度缺少已核实的数据来源。"
        case .legacyCursor: meter = "Cursor 旧计量体系。"
        }
        let entitlement = observation.hasIncludedLimit == true ? "包含额度。" : (observation.trialExpiresAt != nil ? "试用权益，到期时间见额度行。" : "权益状态未确认。")
        return "Cursor 当前账户已核对。" + meter + entitlement
    }

    private static func sharedValueText(_ shared: GrokSharedUsageObservation) -> String {
        switch shared.weeklyValueState {
        case .available: return String(localized: "已用 \(shared.officialDisplayPercent!)%")
        case .notReported: return String(localized: "周用量未提供")
        case .zeroBudget: return String(localized: "周预算为零")
        case .invalid: return String(localized: "周用量数值无效")
        case .overBudget: return String(localized: "已超出周额度")
        case .unavailable:
            return shared.weeklyStatus == .notApplicable ? String(localized: "共享周额度不适用") : String(localized: "周额度暂不可用")
        }
    }
    private static func sharedDetailText(_ shared: GrokSharedUsageObservation) -> String {
        func precise(_ value: Decimal?) -> String {
            guard var value, !value.isNaN else { return String(localized: "未提供") }
            var rounded = Decimal(); NSDecimalRound(&rounded, &value, 4, .plain)
            return NSDecimalNumber(decimal: rounded).stringValue + "%"
        }
        func money(_ amount: Decimal?) -> String {
            guard shared.availability == .available, let amount else { return String(localized: "未提供") }
            guard GrokSharedUsageObservation.nonnegative(amount) else { return String(localized: "来源数值无效") }
            return "US$" + NSDecimalNumber(decimal: amount / 100).stringValue
        }
        let limit: String
        switch shared.availability == .available ? shared.monthlyLimit : .notReported {
        case .notReported: limit = String(localized: "未提供")
        case .unset: limit = String(localized: "未设置")
        case let .amount(amount): limit = money(amount)
        }
        var lines = [String(localized: "周已用 \(precise(shared.usagePercent))"), String(localized: "周剩余 \(precise(shared.remainingPercent))"),
            String(localized: "本月额外用量 \(money(shared.monthlyUsedCents))"), String(localized: "本月额外用量限额 \(limit)"),
            String(localized: "本月积分已用 \(money(shared.monthlyCreditsUsedCents))"), String(localized: "额外积分余额未提供")]
        if shared.availability == .available, let reset = shared.monthlyResetsAt {
            let time = reset.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute())
            lines.append(String(localized: "月用量重置 \(time)"))
        }
        return lines.joined(separator: "\n")
    }

    private static func projectOpenAIMetric(
        _ metric: QuotaMetric,
        product: QuotaProductData
    ) -> Stage3QuotaMetricProjection? {
        guard !isAuthoritativelyAbsent(metric.state.presence),
              case let .percent(percent) = metric.value,
              percent.sourceDirection == .used,
              let rawUsed = boundedPercent(percent.sourceValue) else {
            return nil
        }

        let remaining = 100 - rawUsed
        return Stage3QuotaMetricProjection(
            id: stableMetricID(metric.id),
            title: openAIProductTitle(product, metric: metric),
            windowBadge: openAIWindowBadge(metric.window),
            value: .percent(value: remaining, direction: .remaining),
            event: metric.window?.timeEvent.flatMap { event in
                guard event.kind == .reset else { return nil }
                return Stage3TimeEvent(
                    kind: .reset,
                    occursAt: event.occursAt,
                    style: .absoluteDateTime
                )
            },
            dataState: metricDataState(for: metric.state.freshness)
        )
    }

    private static func projectMiniMaxMetric(
        _ metric: QuotaMetric,
        product: QuotaProductData
    ) -> Stage3QuotaMetricProjection? {
        guard !isAuthoritativelyAbsent(metric.state.presence),
              !isMiniMaxWeeklyVideo(metric) else {
            return nil
        }

        let value: Stage3QuotaValue
        switch metric.value {
        case let .percent(percent):
            guard percent.sourceDirection == .remaining,
                  let rawRemaining = boundedPercent(percent.sourceValue) else {
                return nil
            }
            value = .percent(value: 100 - rawRemaining, direction: .used)

        case let .count(count):
            guard isMiniMaxVideo(metric),
                  count.sourceDirection == .used,
                  let totalValue = count.total,
                  let used = exactNonnegativeInt(count.sourceValue),
                  let total = exactNonnegativeInt(totalValue),
                  used <= total else {
                return nil
            }
            value = .usedCount(used: used, total: total, unit: displayUnit(count.unit))

        case .unlimited:
            value = .unlimited

        case .usedTotal, .absolute, .unavailable:
            // The Stage 3 DTO cannot represent these semantics. Omitting the row is
            // safer than manufacturing zero, 100%, or an unlimited state.
            return nil
        }

        return Stage3QuotaMetricProjection(
            id: stableMetricID(metric.id),
            title: miniMaxMetricTitle(metric),
            windowBadge: miniMaxWindowBadge(metric),
            value: value,
            event: metric.window?.timeEvent.flatMap { event in
                guard event.kind == .reset else { return nil }
                return Stage3TimeEvent(
                    kind: .reset,
                    occursAt: event.occursAt,
                    style: .relativeCountdown
                )
            },
            dataState: metricDataState(for: metric.state.freshness)
        )
    }

    private static func projectArkProduct(
        _ product: QuotaProductData
    ) -> Stage3QuotaProductProjection {
        Stage3QuotaProductProjection(
            id: stableProductID(product.id),
            sourceProductID: product.sourceProductID,
            title: arkProductTitle(product),
            planLevel: planBadge(product.planLevel),
            metrics: product.metrics.compactMap {
                projectArkMetric($0, product: product)
            }
        )
    }

    private static func projectArkMetric(
        _ metric: QuotaMetric,
        product: QuotaProductData
    ) -> Stage3QuotaMetricProjection? {
        guard !isAuthoritativelyAbsent(metric.state.presence),
              let percent = arkUsedPercent(metric.value) else {
            return nil
        }

        let eventKind: Stage3TimeEventKind = product.sourceProductID == "coding-plan"
            ? .refresh
            : .reset
        let event = metric.window?.timeEvent.map {
            Stage3TimeEvent(
                kind: eventKind,
                occursAt: $0.occursAt,
                style: .relativeCountdown
            )
        }

        return Stage3QuotaMetricProjection(
            id: stableMetricID(metric.id),
            title: arkMetricTitle(metric),
            windowBadge: arkWindowBadge(metric.window),
            value: .percent(value: percent, direction: .used),
            event: event,
            dataState: metricDataState(for: metric.state.freshness)
        )
    }

    private static func arkUsedPercent(_ value: QuotaMetricValue) -> Double? {
        switch value {
        case let .percent(percent):
            guard percent.sourceDirection == .used else { return nil }
            return boundedPercent(percent.sourceValue)

        case let .usedTotal(amount):
            if let sourcePercent = amount.sourcePercent {
                guard sourcePercent.sourceDirection == .used else { return nil }
                return boundedPercent(sourcePercent.sourceValue)
            }

            guard let used = finiteDouble(amount.used),
                  let total = finiteDouble(amount.total),
                  used >= 0,
                  total > 0,
                  used <= total else {
                return nil
            }
            return (used / total) * 100

        case .count, .unlimited, .absolute, .unavailable:
            return nil
        }
    }

    private static func projectOpenAIResetEntitlement(
        _ summary: ResetEntitlementSummary
    ) -> Stage3QuotaMetricProjection? {
        guard !isAuthoritativelyAbsent(summary.state.presence),
              let availableCount = exactNonnegativeInt(summary.availableCount),
              availableCount > 0 else {
            return nil
        }

        let availableDetails = summary.details?
            .filter {
                $0.status.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("available") == .orderedSame
            }
            .sorted(by: resetDetailComesBefore)

        let selectedDetail = availableDetails?.first

        return Stage3QuotaMetricProjection(
            id: stableMetricID(MetricID(sourceIdentity: summary.provenance.sourceIdentity)),
            title: nonEmpty(selectedDetail?.title) ?? "重置权益",
            windowBadge: "重置权益",
            value: .entitlement(availableCount: availableCount),
            event: selectedDetail?.expiresAt.map {
                Stage3TimeEvent(
                    kind: .entitlementExpiry,
                    occursAt: $0,
                    style: .absoluteDateTime
                )
            },
            dataState: metricDataState(for: summary.state.freshness),
            resetEntitlements: availableDetails.map {
                $0.map { detail in
                    return Stage3ResetEntitlementItem(
                        id: detail.sourceID,
                        title: detail.title,
                        expiresAt: detail.expiresAt
                    )
                }
            }
        )
    }

    private static func rowState(
        for state: ProviderState,
        phase: ProviderControllerPhase?
    ) -> Stage3ProviderRowState {
        if phase == .shuttingDown || phase == .stopped {
            return .unavailable
        }

        if case .detecting = state.connection {
            return .detecting
        }

        let lastSuccessAt = state.refresh.lastSuccessAt ?? state.lastGood?.fetchedAt
        if case .expired = state.authentication {
            return .expired(lastSuccessAt: lastSuccessAt)
        }
        if state.failure?.code == .authenticationExpired {
            return .expired(lastSuccessAt: lastSuccessAt)
        }
        if state.failure?.code == .authenticationRequired {
            return .requiresLogin
        }

        switch state.connection {
        case .detecting:
            return .detecting
        case .connected:
            // A warning is an expiring session only while still connected.
            // OpenAI also reports warning when credentials are required.
            if case .warning = state.authentication {
                return .authenticationWarning
            }
            return .connected
        case .requiresLogin:
            return .requiresLogin
        case .disabled, .unavailable:
            return .unavailable
        }
    }

    private static func planBadge(
        _ observation: PlanLevelObservation?
    ) -> Stage3PlanBadge? {
        guard let observation,
              let value = nonEmpty(observation.value) else {
            return nil
        }

        let origin: Stage3PlanOrigin
        switch observation.origin {
        case let .reported(sourceField):
            origin = .reported(sourceField: sourceField)
        case let .inferred(ruleID, _, _, _):
            origin = .inferred(ruleID: ruleID)
        }
        return Stage3PlanBadge(value: displayPlanLevel(value), origin: origin)
    }

    private static func displayPlanLevel(_ sourceValue: String) -> String {
        switch sourceValue.lowercased() {
        case "plus": "Plus"
        case "max": "Max"
        case "ultra": "Ultra"
        case "lite": "Lite"
        case "medium": "Medium"
        case "pro": "Pro"
        default: sourceValue
        }
    }

    private static func openAIProductTitle(
        _ product: QuotaProductData,
        metric: QuotaMetric
    ) -> String {
        switch product.titleKey {
        case "provider.openai.product.codex":
            return "Codex"
        case "provider.openai.product.spark":
            return "Codex Spark"
        default:
            return nonEmpty(metric.sourceLabel)
                ?? nonEmpty(product.sourceProductID)
                ?? "其他额度"
        }
    }

    private static func openAIWindowBadge(_ window: QuotaWindow?) -> String? {
        guard let window else { return nil }
        switch window.kind {
        case .session:
            return "当前会话"
        case .shortCycle:
            return durationBadge(window.duration) ?? "短周期"
        case .weekly:
            return "每周"
        case .monthly:
            return "每月"
        case .providerDefined:
            return durationBadge(window.duration)
        }
    }

    private static func miniMaxMetricTitle(_ metric: QuotaMetric) -> String {
        if isMiniMaxVideo(metric) { return "视频赠送" }
        if metric.sourceLabel == "general" {
            if metric.window?.kind == .weekly { return "每周" }
            return "当前周期"
        }
        return nonEmpty(metric.sourceLabel) ?? "其他额度"
    }

    private static func miniMaxWindowBadge(_ metric: QuotaMetric) -> String? {
        if isMiniMaxVideo(metric) { return "当日" }
        guard let kind = metric.window?.kind else { return nil }
        switch kind {
        case .weekly:
            return nil
        case .session:
            return "当前会话"
        case .monthly:
            return "每月"
        case .shortCycle, .providerDefined:
            // MiniMax does not report a business label for current_interval.
            // Its timestamps/duration alone cannot authorize a fabricated "5 小时".
            return nil
        }
    }

    private static func arkProductTitle(_ product: QuotaProductData) -> String {
        switch product.sourceProductID {
        case "agent-plan": "Agent Plan"
        case "coding-plan": "Coding Plan"
        default: nonEmpty(product.sourceProductID) ?? "其他套餐"
        }
    }

    private static func arkMetricTitle(_ metric: QuotaMetric) -> String {
        guard let kind = metric.window?.kind else {
            return nonEmpty(metric.sourceLabel) ?? "其他额度"
        }
        switch kind {
        case .session, .shortCycle:
            return "短周期"
        case .weekly:
            return "每周"
        case .monthly:
            return "每月"
        case .providerDefined:
            return nonEmpty(metric.sourceLabel) ?? "其他额度"
        }
    }

    private static func arkWindowBadge(_ window: QuotaWindow?) -> String? {
        guard let window else { return nil }
        switch window.kind {
        case .session:
            return "当前会话"
        case .shortCycle:
            return durationBadge(window.duration) ?? "短周期"
        case .weekly, .monthly, .providerDefined:
            return nil
        }
    }

    private static func durationBadge(_ duration: TimeInterval?) -> String? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        let wholeMinutes = duration / 60
        guard wholeMinutes.rounded() == wholeMinutes else { return nil }
        if wholeMinutes.truncatingRemainder(dividingBy: 1_440) == 0 {
            return "\(Int(wholeMinutes / 1_440)) 天"
        }
        if wholeMinutes.truncatingRemainder(dividingBy: 60) == 0 {
            return "\(Int(wholeMinutes / 60)) 小时"
        }
        return "\(Int(wholeMinutes)) 分钟"
    }

    private static func isMiniMaxVideo(_ metric: QuotaMetric) -> Bool {
        metric.sourceLabel == "video"
            || metric.id.sourceIdentity.sourceBucketID?.hasPrefix("video.") == true
    }

    private static func isMiniMaxWeeklyVideo(_ metric: QuotaMetric) -> Bool {
        guard isMiniMaxVideo(metric) else { return false }
        if metric.window?.kind == .weekly { return true }
        return metric.id.sourceIdentity.sourceBucketID == "video.weekly"
    }

    private static func displayUnit(_ sourceUnit: String) -> String {
        switch sourceUnit.lowercased() {
        case "count", "counts", "times": "次"
        default: nonEmpty(sourceUnit) ?? "次"
        }
    }

    private static func isAuthoritativelyAbsent(_ presence: PresenceState) -> Bool {
        if case .notEntitled = presence { return true }
        return false
    }

    private static func productComesBefore(
        _ lhs: QuotaProductData,
        _ rhs: QuotaProductData
    ) -> Bool {
        if lhs.canonicalOrder != rhs.canonicalOrder {
            return lhs.canonicalOrder < rhs.canonicalOrder
        }
        return lhs.sourceProductID < rhs.sourceProductID
    }

    private static func resetDetailComesBefore(
        _ lhs: ResetEntitlementDetail,
        _ rhs: ResetEntitlementDetail
    ) -> Bool {
        let lhsExpiry = lhs.expiresAt ?? .distantFuture
        let rhsExpiry = rhs.expiresAt ?? .distantFuture
        if lhsExpiry != rhsExpiry { return lhsExpiry < rhsExpiry }

        let lhsGranted = lhs.grantedAt ?? .distantFuture
        let rhsGranted = rhs.grantedAt ?? .distantFuture
        if lhsGranted != rhsGranted { return lhsGranted < rhsGranted }
        return lhs.sourceID < rhs.sourceID
    }

    private static func boundedPercent(_ value: Decimal) -> Double? {
        guard let value = finiteDouble(value), value >= 0, value <= 100 else {
            return nil
        }
        return value
    }

    private static func finiteDouble(_ value: Decimal) -> Double? {
        let value = NSDecimalNumber(decimal: value).doubleValue
        return value.isFinite ? value : nil
    }

    private static func exactNonnegativeInt(_ value: Decimal) -> Int? {
        guard let value = finiteDouble(value),
              value >= 0,
              value <= Double(Int.max),
              value.rounded(.towardZero) == value else {
            return nil
        }
        return Int(value)
    }

    private static func stableMetricID(_ metricID: MetricID) -> String {
        let identity = metricID.sourceIdentity
        return stableID(
            prefix: "metric",
            components: [
                identity.providerID.rawValue,
                identity.sourceProductID,
                identity.sourceBucketID ?? "",
                identity.sourceMetricID
            ]
        )
    }

    private static func stableProductID(_ productID: ProductID) -> String {
        stableID(
            prefix: "product",
            components: [productID.providerID.rawValue, productID.sourceProductID]
        )
    }

    private static func stableID(prefix: String, components: [String]) -> String {
        let encoded = components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return "\(prefix)|\(encoded)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
