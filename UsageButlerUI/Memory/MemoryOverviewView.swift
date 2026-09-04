import AppKit
import Charts
import SwiftUI
import UsageButlerCore
import UsageButlerDomain

struct MemoryPressureChartLayout: Equatable, Sendable {
    /// Trailing (causal) moving-average window applied to the plotted
    /// pressureRatio. The raw signal moves in discrete level steps, so a
    /// single plotted sample looks like a spike; averaging turns steps into
    /// ramps. The window adapts to the visible range (`duration / 60`, clamped
    /// to 5...120 seconds): short ranges keep the five-second window that
    /// smooths the one-second-cadence tail, while the 30-minute-plus ranges —
    /// plotted from ten-second-cadence downsampled history — average several
    /// samples per point instead of rendering every raw step.
    static let minimumSmoothingInterval: TimeInterval = 5
    static let maximumSmoothingInterval: TimeInterval = 120

    static func smoothingInterval(forWindowDuration duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else {
            return minimumSmoothingInterval
        }
        return min(
            max(duration / 60, minimumSmoothingInterval),
            maximumSmoothingInterval
        )
    }

    struct Point: Equatable, Sendable {
        let timestamp: Date
        let x: Double
        let y: Double
        let pressure: MemoryPressureState
    }

    struct Trace: Equatable, Sendable {
        let points: [Point]
        let pressure: MemoryPressureState
    }

    let traces: [Trace]
    let markers: [Point]

    var hasKnownData: Bool { !traces.isEmpty || !markers.isEmpty }

    static func make(
        points: [MemoryTrendPoint],
        windowStart: Date,
        windowEnd: Date,
        maximumContinuousInterval: TimeInterval = MemoryHistoryDownsampler
            .maximumContinuousInterval
    ) -> MemoryPressureChartLayout {
        let start = windowStart.timeIntervalSinceReferenceDate
        let end = windowEnd.timeIntervalSinceReferenceDate
        guard
            start.isFinite,
            end.isFinite,
            end > start,
            maximumContinuousInterval.isFinite,
            maximumContinuousInterval > 0
        else {
            return MemoryPressureChartLayout(
                traces: [],
                markers: []
            )
        }

        let duration = end - start
        let smoothingInterval = Self.smoothingInterval(
            forWindowDuration: duration
        )
        var traces: [Trace] = []
        var run: [Point] = []
        var latestPoint: Point?
        var previousInputTimestamp: TimeInterval?
        var smoothingWindow: [(timestamp: TimeInterval, ratio: Double)] = []

        let chartPoints = leadingClampedPoints(
            points,
            start: start,
            end: end,
            maximumContinuousInterval: maximumContinuousInterval
        )

        func flushRun() {
            guard let first = run.first else { return }
            latestPoint = run.last

            if run.count > 1 {
                var tracePoints = [first]
                var tracePressure = first.pressure

                for index in 1..<run.count {
                    let current = run[index]
                    guard current.pressure != tracePressure else {
                        tracePoints.append(current)
                        continue
                    }

                    tracePoints.append(current)
                    if tracePoints.count > 1 {
                        traces.append(
                            Trace(points: tracePoints, pressure: tracePressure)
                        )
                    }
                    tracePoints = [current]
                    tracePressure = current.pressure
                }

                if tracePoints.count > 1 {
                    traces.append(Trace(points: tracePoints, pressure: tracePressure))
                }
            }

            run.removeAll(keepingCapacity: true)
        }

        for sourcePoint in chartPoints {
            let timestamp = sourcePoint.timestamp.timeIntervalSinceReferenceDate
            guard timestamp.isFinite else {
                flushRun()
                previousInputTimestamp = nil
                smoothingWindow.removeAll()
                continue
            }

            if let previousInputTimestamp,
               timestamp <= previousInputTimestamp {
                flushRun()
                continue
            }
            previousInputTimestamp = timestamp

            guard timestamp >= start, timestamp <= end else {
                flushRun()
                continue
            }
            guard
                let ratio = sourcePoint.pressureRatio,
                ratio.isFinite,
                (0...1).contains(ratio)
            else {
                flushRun()
                smoothingWindow.removeAll()
                continue
            }

            // A continuity gap invalidates the smoothing window before the
            // next sample is averaged: with an adaptive window wider than
            // maximumContinuousInterval, pre-gap samples would otherwise leak
            // into the first post-gap point.
            if let previous = run.last,
               timestamp - previous.timestamp.timeIntervalSinceReferenceDate
                    > maximumContinuousInterval {
                flushRun()
                smoothingWindow.removeAll()
            }

            smoothingWindow.append((timestamp, ratio))
            while let oldest = smoothingWindow.first,
                  timestamp - oldest.timestamp > smoothingInterval {
                smoothingWindow.removeFirst()
            }
            let smoothedRatio = smoothingWindow.map(\.ratio)
                .reduce(0, +) / Double(smoothingWindow.count)

            let x = (timestamp - start) / duration
            let y = 1 - smoothedRatio
            guard x.isFinite, y.isFinite, (0...1).contains(x) else {
                flushRun()
                continue
            }

            let point = Point(
                timestamp: sourcePoint.timestamp,
                x: x,
                y: y,
                pressure: sourcePoint.pressure
            )

            run.append(point)
        }
        flushRun()

        return MemoryPressureChartLayout(
            traces: traces,
            markers: latestPoint.map { [$0] } ?? []
        )
    }

    /// Extends the last valid sample at-or-before the window start
    /// horizontally onto the left axis, matching Activity Monitor: a window
    /// fully covered by history renders flush against the axis even when the
    /// covering samples are on a coarse (10 s) cadence, while history younger
    /// than the window keeps an honest leading blank. The clamp only repeats a
    /// real measured value. Check continuity using the original timestamps,
    /// before clamping can shorten a real gap at the window boundary.
    private static func leadingClampedPoints(
        _ points: [MemoryTrendPoint],
        start: TimeInterval,
        end: TimeInterval,
        maximumContinuousInterval: TimeInterval
    ) -> [MemoryTrendPoint] {
        var prefixEndIndex = points.endIndex
        var boundary: MemoryTrendPoint?
        for (index, point) in points.enumerated() {
            let timestamp = point.timestamp.timeIntervalSinceReferenceDate
            guard timestamp.isFinite, timestamp < start else {
                prefixEndIndex = index
                break
            }
            boundary = point
        }

        guard let boundary,
              let ratio = boundary.pressureRatio,
              ratio.isFinite,
              (0...1).contains(ratio) else {
            return points
        }
        guard prefixEndIndex < points.endIndex else { return points }
        let firstInside = points[prefixEndIndex]
        let firstTimestamp = firstInside.timestamp.timeIntervalSinceReferenceDate
        guard firstTimestamp > start,
              firstTimestamp <= end,
              firstTimestamp - boundary.timestamp.timeIntervalSinceReferenceDate
                  <= maximumContinuousInterval,
              let firstRatio = firstInside.pressureRatio,
              firstRatio.isFinite,
              (0...1).contains(firstRatio) else {
            return points
        }

        let clamped = MemoryTrendPoint(
            id: boundary.id,
            timestamp: Date(timeIntervalSinceReferenceDate: start),
            loadRatio: boundary.loadRatio,
            pressureRatio: boundary.pressureRatio,
            pressure: boundary.pressure
        )
        var result = points
        result.insert(clamped, at: prefixEndIndex)
        return result
    }
}

struct MemoryPressureChartDrawingPlan: Equatable, Sendable {
    enum CommandKind: Equatable, Sendable {
        case fill
        case stroke
        case marker
    }

    struct Command: Equatable, Sendable {
        let kind: CommandKind
        let points: [MemoryPressureChartLayout.Point]
        let pressure: MemoryPressureState
        let closesToBaseline: Bool
    }

    let commands: [Command]

    static func make(
        layout: MemoryPressureChartLayout
    ) -> MemoryPressureChartDrawingPlan {
        let fills = layout.traces.map { trace in
            let first = trace.points[0]
            let last = trace.points[trace.points.count - 1]
            let closedAreaPoints = trace.points + [
                MemoryPressureChartLayout.Point(
                    timestamp: last.timestamp,
                    x: last.x,
                    y: 1,
                    pressure: trace.pressure
                ),
                MemoryPressureChartLayout.Point(
                    timestamp: first.timestamp,
                    x: first.x,
                    y: 1,
                    pressure: trace.pressure
                )
            ]
            return Command(
                kind: .fill,
                points: closedAreaPoints,
                pressure: trace.pressure,
                closesToBaseline: true
            )
        }
        let strokes = layout.traces.map { trace in
            Command(
                kind: .stroke,
                points: trace.points,
                pressure: trace.pressure,
                closesToBaseline: false
            )
        }
        let markers = layout.markers.map { point in
            Command(
                kind: .marker,
                points: [point],
                pressure: point.pressure,
                closesToBaseline: false
            )
        }
        return MemoryPressureChartDrawingPlan(
            commands: fills + strokes + markers
        )
    }
}

struct MemoryPressureFillGradientPlan: Equatable, Sendable {
    let startY: Double
    let endY: Double
    let topOpacity: Double
    let bottomOpacity: Double

    static let activityMonitorObserved = MemoryPressureFillGradientPlan(
        startY: 0,
        endY: 1,
        topOpacity: 0.5,
        bottomOpacity: 1.0 / 3.0
    )
}

private func pressureStrokeColor(_ state: MemoryPressureState) -> Color {
    switch state {
    case .normal: Color(nsColor: .systemGreen)
    case .warning: Color(nsColor: .systemOrange)
    case .critical: Color(nsColor: .systemRed)
    case .unknown: .secondary
    }
}

public struct MemoryOverviewView: View {
    let snapshot: Stage3MemoryProjection
    @Binding var range: MemoryRange
    let activityMonitorState: ActivityMonitorActionState
    let onOpenActivityMonitor: () -> Void

    public init(
        snapshot: Stage3MemoryProjection,
        range: Binding<MemoryRange>,
        activityMonitorState: ActivityMonitorActionState,
        onOpenActivityMonitor: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self._range = range
        self.activityMonitorState = activityMonitorState
        self.onOpenActivityMonitor = onOpenActivityMonitor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                Text("内存压力")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(pressureStatusColor)
                        .frame(width: 7, height: 7)
                    Text(pressureStatusLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(pressureAccessibilityValue)
                Spacer()
                EqualWidthSegmentedPicker(
                    options: MemoryRange.allCases.map { ($0.title, $0) },
                    selection: $range
                )
                .frame(width: 300)
            }

            MemoryPressureChart(
                points: snapshot.history,
                windowStart: snapshot.historyWindowEnd.addingTimeInterval(-range.interval),
                windowEnd: snapshot.historyWindowEnd
            )
                .frame(height: 180)
                .accessibilityLabel("内存压力")
                .accessibilityValue(memoryChartAccessibilityValue)

            HStack {
                Text(rangeStartLabel)
                Spacer()
                Text("现在")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            MemorySummaryTable(fields: snapshot.fields)

            Divider()

            HStack {
                Spacer()
                Button(action: onOpenActivityMonitor) {
                    if activityMonitorState == .opening {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在打开")
                    } else {
                        Label("打开活动监视器", systemImage: "waveform.path.ecg.rectangle")
                    }
                }
                .disabled(activityMonitorState == .opening)
                .accessibilityValue(activityMonitorState == .opening ? "正在打开" : "")
            }

            if let activityMonitorErrorMessage {
                Text(activityMonitorErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        }
    }

    private var activityMonitorErrorMessage: String? {
        switch activityMonitorState {
        case .idle, .opening:
            nil
        case .notFound:
            String(localized: "未找到“活动监视器”。")
        case .launchFailed:
            String(localized: "无法打开“活动监视器”，请重试。")
        }
    }

    private var rangeStartLabel: String {
        switch range {
        case .oneMinute: String(localized: "1 分钟前")
        case .tenMinutes: String(localized: "10 分钟前")
        case .thirtyMinutes: String(localized: "30 分钟前")
        case .oneHour: String(localized: "1 小时前")
        case .twoHours: String(localized: "2 小时前")
        }
    }

    private var pressureAccessibilityValue: String {
        switch snapshot.pressure {
        case .normal: String(localized: "当前内存压力正常")
        case .warning: String(localized: "当前内存压力为警告")
        case .critical: String(localized: "当前内存压力严重")
        case .unknown: String(localized: "当前内存压力未知")
        }
    }

    private var pressureStatusLabel: String {
        switch snapshot.pressure {
        case .normal: String(localized: "正常")
        case .warning: String(localized: "警告")
        case .critical: String(localized: "严重")
        case .unknown: String(localized: "未知")
        }
    }

    private var pressureStatusColor: Color {
        pressureStrokeColor(snapshot.pressure)
    }

    private var memoryChartAccessibilityValue: String {
        var values = [range.title, pressureAccessibilityValue]
        if let point = currentMemoryChartLayout.markers.last {
            let ratio = 1 - point.y
            values.append(
                String(
                    localized: "最新内存压力 \(ratio.formatted(.percent.precision(.fractionLength(0))))"
                )
            )
        } else {
            values.append(String(localized: "暂无内存压力数据"))
        }
        return values.joined(separator: "，")
    }

    private var currentMemoryChartLayout: MemoryPressureChartLayout {
        MemoryPressureChartLayout.make(
            points: snapshot.history,
            windowStart: snapshot.historyWindowEnd.addingTimeInterval(-range.interval),
            windowEnd: snapshot.historyWindowEnd
        )
    }
}

private struct MemoryPressureChart: View {
    let points: [MemoryTrendPoint]
    let windowStart: Date
    let windowEnd: Date

    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    var body: some View {
        let layout = MemoryPressureChartLayout.make(
            points: points,
            windowStart: windowStart,
            windowEnd: windowEnd
        )
        let drawingPlan = MemoryPressureChartDrawingPlan.make(layout: layout)
        let fillCommandIndices = drawingPlan.commands.indices.filter {
            drawingPlan.commands[$0].kind == .fill
        }
        let strokeCommandIndices = drawingPlan.commands.indices.filter {
            drawingPlan.commands[$0].kind == .stroke
        }
        let markerCommandIndices = drawingPlan.commands.indices.filter {
            drawingPlan.commands[$0].kind == .marker
        }

        ZStack {
            Chart {
                ForEach([0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0], id: \.self) { x in
                    RuleMark(x: .value("Grid x", x))
                        .foregroundStyle(.secondary.opacity(0.18))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                ForEach([0.25, 0.5, 0.75], id: \.self) { y in
                    RuleMark(y: .value("Grid y", y))
                        .foregroundStyle(.secondary.opacity(0.18))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }

                ForEach(fillCommandIndices, id: \.self) { commandIndex in
                    let command = drawingPlan.commands[commandIndex]
                    let chartPoints = chartPoints(for: command)

                    ForEach(chartPoints, id: \.timestamp) { point in
                        AreaMark(
                            x: .value("Time", point.x),
                            yStart: .value("Baseline", 0),
                            yEnd: .value("Pressure", 1 - point.y),
                            series: .value("Fill series", commandIndex)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(fillGradient(for: command.pressure))
                        .alignsMarkStylesWithPlotArea()
                    }
                }

                ForEach(strokeCommandIndices, id: \.self) { commandIndex in
                    let command = drawingPlan.commands[commandIndex]
                    let chartPoints = chartPoints(for: command)

                    ForEach(chartPoints, id: \.timestamp) { point in
                        LineMark(
                            x: .value("Time", point.x),
                            y: .value("Pressure", 1 - point.y),
                            series: .value("Stroke series", commandIndex)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(pressureStrokeColor(command.pressure))
                        .lineStyle(strokeStyle(for: command.pressure))
                    }
                }

                ForEach(markerCommandIndices, id: \.self) { commandIndex in
                    let command = drawingPlan.commands[commandIndex]
                    let chartPoints = chartPoints(for: command)

                    ForEach(chartPoints, id: \.timestamp) { point in
                        PointMark(
                            x: .value("Time", point.x),
                            y: .value("Pressure", 1 - point.y)
                        )
                        .foregroundStyle(pressureStrokeColor(point.pressure))
                        .symbolSize(28)
                    }
                }
            }
            .chartXScale(
                domain: 0...1,
                range: .plotDimension(startPadding: 0, endPadding: 0)
            )
            .chartYScale(
                domain: 0...1,
                range: .plotDimension(startPadding: 0, endPadding: 0)
            )
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)

            if !layout.hasKnownData {
                Text("暂无内存压力数据")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
    }

    private func fillGradient(for pressure: MemoryPressureState) -> LinearGradient {
        let color = pressureFillColor(pressure)
        let gradient = MemoryPressureFillGradientPlan.activityMonitorObserved
        return LinearGradient(
            colors: [
                color.opacity(gradient.topOpacity),
                color.opacity(gradient.bottomOpacity)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func chartPoints(
        for command: MemoryPressureChartDrawingPlan.Command
    ) -> [MemoryPressureChartLayout.Point] {
        guard command.closesToBaseline, command.points.count >= 2 else {
            return command.points
        }
        return Array(command.points.dropLast(2))
    }

    private func pressureFillColor(_ state: MemoryPressureState) -> Color {
        switch state {
        case .normal: Color(red: 0, green: 0.8, blue: 0)
        case .warning: Color(red: 240.0 / 255, green: 190.0 / 255, blue: 36.0 / 255)
        case .critical: Color(red: 1, green: 0, blue: 0)
        case .unknown: .secondary
        }
    }

    private func strokeStyle(for state: MemoryPressureState) -> StrokeStyle {
        if state == .unknown {
            return StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [3, 4])
        }

        guard differentiateWithoutColor else {
            return StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        }

        return switch state {
        case .normal:
            StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        case .warning:
            StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [8, 3])
        case .critical:
            StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [3, 2])
        case .unknown:
            StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [2, 4])
        }
    }
}

extension MemoryRange {
    var interval: TimeInterval {
        switch self {
        case .oneMinute: 60
        case .tenMinutes: 10 * 60
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .twoHours: 2 * 60 * 60
        }
    }
}

/// A segmented selector with strictly equal segment widths. NSSegmentedControl
/// sizes segments by title width, so the selected pill visibly resized between
/// ranges (measured 60/68/70 pt across captures); this custom control keeps
/// the geometry identical for every selection and on first layout.
private struct EqualWidthSegmentedPicker<Option: Hashable>: View {
    let options: [(String, Option)]
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.1) { title, option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title)
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isSelected ? Color.accentColor : Color.clear)
                        )
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(.quaternary.opacity(0.6))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "时间范围"))
    }
}

private struct MemorySummaryTable: View {
    let fields: [MemorySummaryField]

    private var fieldsByID: [MemoryFieldID: MemorySummaryField] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) })
    }

    private var leftFieldIDs: [MemoryFieldID] {
        Array(MemoryFieldPresentation.orderedFieldIDs.prefix(4))
    }

    private var rightFieldIDs: [MemoryFieldID] {
        Array(MemoryFieldPresentation.orderedFieldIDs.dropFirst(4))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            MemoryFieldColumn(fieldIDs: leftFieldIDs, fieldsByID: fieldsByID)
            Divider()
            MemoryFieldColumn(fieldIDs: rightFieldIDs, fieldsByID: fieldsByID)
        }
        .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }
}

private struct MemoryFieldColumn: View {
    let fieldIDs: [MemoryFieldID]
    let fieldsByID: [MemoryFieldID: MemorySummaryField]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(fieldIDs.enumerated()), id: \.element) { index, fieldID in
                if index > 0 { Divider() }
                HStack {
                    Text(MemoryFieldPresentation.title(for: fieldID))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(MemoryFieldPresentation.value(bytes: fieldsByID[fieldID]?.bytes))
                        .monospacedDigit()
                }
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
