import Accessibility
import SwiftUI
import UsageButlerCore

/// Audio graphs must describe source units, not the normalized drawing space.
struct NetworkChartAccessibility: AXChartDescriptorRepresentable {
    let points: [NetworkChartPoint]
    let direction: NetworkChartDirection
    let coordinates: NetworkChartCoordinates

    func makeChartDescriptor() -> AXChartDescriptor {
        let title = direction == .upload ? "上传" : "下载"
        let x = AXNumericDataAxisDescriptor(title: "时间",
            range: coordinates.date(atX: 0).timeIntervalSince1970...coordinates.now.timeIntervalSince1970,
            gridlinePositions: NetworkChartCoordinates.ticks.map { coordinates.date(atX: $0).timeIntervalSince1970 }) {
                Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .standard)
            }
        let y = AXNumericDataAxisDescriptor(title: "字节每秒", range: 0...coordinates.upperBound,
            gridlinePositions: NetworkChartCoordinates.ticks.map { coordinates.rate(atY: $0) }) {
                NetworkPresentation.rate($0)
            }
        let groups = Dictionary(grouping: points, by: \.seriesKey).values.sorted {
            ($0.first?.at ?? .distantPast) < ($1.first?.at ?? .distantPast)
        }
        let series = groups.enumerated().map { index, group in
            AXDataSeriesDescriptor(name: "\(title) · 第 \(index + 1) 段", isContinuous: group.count > 1,
                dataPoints: group.map { AXDataPoint(x: $0.at.timeIntervalSince1970, y: $0.value) })
        }
        return AXChartDescriptor(title: "\(title)趋势", summary: "独立纵轴；未采样区间留空",
            xAxis: x, yAxis: y, series: series)
    }
}
