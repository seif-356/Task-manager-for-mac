import Charts
import SwiftUI

struct PerformanceView: View {
    let monitor: SystemMonitor

    enum Resource: String, CaseIterable, Identifiable {
        case cpu = "CPU"
        case memory = "Memory"
        case network = "Network"
        var id: Self { self }
    }

    @State private var selected: Resource? = .cpu

    var body: some View {
        HStack(spacing: 0) {
            List(Resource.allCases, selection: $selected) { resource in
                sidebarRow(resource)
            }
            .listStyle(.sidebar)
            .frame(width: 230)

            Divider()

            ScrollView {
                detail(selected ?? .cpu)
                    .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Sidebar

    private func sidebarRow(_ resource: Resource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(resource.rawValue).font(.headline)
                Spacer()
                Text(summary(resource))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Sparkline(values: sparklineValues(resource), maxValue: resource == .network ? nil : 100, color: color(resource))
                .frame(height: 30)
        }
        .padding(.vertical, 4)
    }

    private func summary(_ resource: Resource) -> String {
        switch resource {
        case .cpu: return Format.percent(monitor.cpuUsage)
        case .memory: return Format.percent(monitor.memoryPercent)
        case .network: return "↓ " + Format.rate(monitor.receiveRate)
        }
    }

    private func sparklineValues(_ resource: Resource) -> [Double] {
        switch resource {
        case .cpu: return monitor.cpuHistory
        case .memory: return monitor.memoryHistory
        case .network: return monitor.receiveHistory
        }
    }

    private func color(_ resource: Resource) -> Color {
        switch resource {
        case .cpu: return .blue
        case .memory: return .purple
        case .network: return .orange
        }
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(_ resource: Resource) -> some View {
        switch resource {
        case .cpu: cpuDetail
        case .memory: memoryDetail
        case .network: networkDetail
        }
    }

    private var cpuDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("CPU", subtitle: monitor.cpuName)
            HistoryChart(
                series: [.init(name: "CPU", values: monitor.cpuHistory, color: .blue)],
                yMax: 100,
                label: { Format.percent($0) }
            )
            .frame(height: 260)
            HStack(alignment: .top, spacing: 32) {
                Stat(label: "Utilization", value: Format.percent(monitor.cpuUsage))
                Stat(label: "Cores", value: coresText)
                Stat(label: "Up time", value: Format.duration(ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    private var memoryDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Memory", subtitle: Format.bytes(monitor.memoryTotal))
            HistoryChart(
                series: [.init(name: "Memory", values: monitor.memoryHistory, color: .purple)],
                yMax: 100,
                label: { Format.percent($0) }
            )
            .frame(height: 260)
            HStack(alignment: .top, spacing: 32) {
                Stat(label: "In use", value: Format.bytes(monitor.memoryUsed))
                Stat(label: "Available", value: Format.bytes(monitor.memoryTotal - min(monitor.memoryUsed, monitor.memoryTotal)))
                Stat(label: "Wired", value: Format.bytes(monitor.memoryWired))
                Stat(label: "Compressed", value: Format.bytes(monitor.memoryCompressed))
            }
        }
    }

    private var networkDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Network", subtitle: "Ethernet & Wi-Fi")
            HistoryChart(
                series: [
                    .init(name: "Receive", values: monitor.receiveHistory, color: .orange),
                    .init(name: "Send", values: monitor.sendHistory, color: .teal),
                ],
                yMax: nil,
                label: { Format.rate($0) }
            )
            .frame(height: 260)
            HStack(alignment: .top, spacing: 32) {
                Stat(label: "Receive", value: Format.rate(monitor.receiveRate))
                Stat(label: "Send", value: Format.rate(monitor.sendRate))
            }
        }
    }

    private func title(_ text: String, subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.largeTitle.weight(.semibold))
            Spacer()
            Text(subtitle).font(.title3).foregroundStyle(.secondary)
        }
    }

    private var coresText: String {
        if let performance = monitor.performanceCores, let efficiency = monitor.efficiencyCores {
            return "\(performance) performance + \(efficiency) efficiency"
        }
        return "\(monitor.logicalCores)"
    }
}

private struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).monospacedDigit()
        }
    }
}

/// Rolling 60-second line chart. Newest sample is on the right, like Windows.
struct HistoryChart: View {
    struct Series {
        let name: String
        let values: [Double]
        let color: Color
    }

    private struct Point: Identifiable {
        let id: String
        let series: String
        let x: Int
        let y: Double
    }

    let series: [Series]
    /// Fixed top of the Y axis, or nil to scale to the data.
    let yMax: Double?
    let label: (Double) -> String

    private var points: [Point] {
        series.flatMap { line in
            let offset = Sampling.historyLength - line.values.count
            return line.values.enumerated().map { index, value in
                Point(id: "\(line.name)-\(index)", series: line.name, x: offset + index, y: value)
            }
        }
    }

    private var upperBound: Double {
        if let yMax { return yMax }
        let peak = series.flatMap(\.values).max() ?? 0
        return max(peak * 1.2, 10_000)
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                if series.count == 1, let color = series.first?.color {
                    AreaMark(
                        x: .value("Time", point.x),
                        y: .value("Value", point.y)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.35), color.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                LineMark(
                    x: .value("Time", point.x),
                    y: .value("Value", point.y),
                    series: .value("Series", point.series)
                )
                .foregroundStyle(by: .value("Series", point.series))
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
        .chartXScale(domain: 0...(Sampling.historyLength - 1))
        .chartYScale(domain: 0...upperBound)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(label(number))
                    }
                }
            }
        }
        .chartLegend(series.count > 1 ? .visible : .hidden)
        .padding(8)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Lightweight mini-graph for the sidebar.
struct Sparkline: View {
    let values: [Double]
    let maxValue: Double?
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let upper = max(maxValue ?? 0, values.max() ?? 0, 0.0001)
            let step = geometry.size.width / CGFloat(Sampling.historyLength - 1)
            let offset = Sampling.historyLength - values.count
            Path { path in
                for (index, value) in values.enumerated() {
                    let point = CGPoint(
                        x: CGFloat(offset + index) * step,
                        y: geometry.size.height * (1 - CGFloat(value / upper))
                    )
                    if index == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
            }
            .stroke(color, lineWidth: 1.5)
        }
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
    }
}
