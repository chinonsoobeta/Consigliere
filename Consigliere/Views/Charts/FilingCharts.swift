import Accessibility
import Charts
import SwiftUI

struct FilingChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let labels: [String]
    let values: [Double]
    var axisTitle: String? = nil
    var locale: Locale = .current
    var dates = false
    var secondaryValues: [Double]? = nil

    func makeChartDescriptor() -> AXChartDescriptor {
        let x = AXCategoricalDataAxisDescriptor(title: String(localized: "charts.date", locale: locale), categoryOrder: labels)
        let y = AXNumericDataAxisDescriptor(title: axisTitle ?? String(localized: "charts.count", locale: locale), range: (dates ? (values.min() ?? 0) : 0)...max(max(values.max() ?? 0, secondaryValues?.max() ?? 0), 1), gridlinePositions: []) { dates ? Date(timeIntervalSince1970: $0).formatted(DisclosureDates.style().locale(locale)) : String(Int($0)) }
        let points = zip(labels, values).map { AXDataPoint(x: $0.0, y: $0.1) }
        var series = [AXDataSeriesDescriptor(name: secondaryValues == nil ? title : String(localized: "trade.short.purchase", locale: locale), isContinuous: false, dataPoints: points)]
        if let secondaryValues {
            series.append(AXDataSeriesDescriptor(name: String(localized: "trade.short.sale", locale: locale), isContinuous: false, dataPoints: zip(labels, secondaryValues).map { AXDataPoint(x: $0.0, y: $0.1) }))
        }
        return AXChartDescriptor(title: title, summary: title, xAxis: x, yAxis: y, additionalAxes: [], series: series)
    }
}

enum FilingCharts {
    static func weekly(_ buckets: [WeeklyBucket], locale: Locale) -> some View {
        Chart(buckets) { bucket in
            BarMark(x: .value("Week", bucket.start, unit: .weekOfYear, calendar: TradeAnalytics.calendar), y: .value("Filings", bucket.count))
                .foregroundStyle(bucket.start == buckets.last?.start ? ConsigliereTheme.accent : Color.secondary.opacity(0.4))
        }
        .frame(height: 120)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityChartDescriptor(FilingChartDescriptor(title: String(localized: "home.pulse", locale: locale), labels: buckets.map { $0.start.formatted(DisclosureDates.style().locale(locale)) }, values: buckets.map { Double($0.count) }, locale: locale))
    }
}

struct MemberFilingCharts: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let trades: [DisclosureTrade]
    @State private var selectedMonth: Date?
    private var activity: [ActivityBucket] { TradeAnalytics.activityHistogram(trades) }
    private var delays: [DelayRecord] { TradeAnalytics.delays(trades) }
    private var monthlyTotals: [WeeklyBucket] {
        Dictionary(grouping: activity, by: \.month).map { WeeklyBucket(start: $0.key, count: $0.value.reduce(0) { $0 + $1.count }) }.sorted { $0.start < $1.start }
    }
    private var medianDelay: String {
        TradeAnalytics.medianReportingDelay(delays)?.formatted(.number.locale(locale).precision(.fractionLength(0...1))) ?? "—"
    }

    var body: some View {
        Section(themed: "charts.activity") {
            Chart(activity) { bucket in
                BarMark(x: .value("Month", bucket.month, unit: .month, calendar: TradeAnalytics.calendar), y: .value("Trades", bucket.count))
                    .foregroundStyle(by: .value("Type", bucket.type == .purchase ? String(localized: "trade.short.purchase", locale: locale) : String(localized: "trade.short.sale", locale: locale)))
            }
            .chartForegroundStyleScale([String(localized: "trade.short.purchase", locale: locale): ConsigliereTheme.positive, String(localized: "trade.short.sale", locale: locale): ConsigliereTheme.negative])
            .chartXSelection(value: $selectedMonth)
            .chartGesture { proxy in
                SpatialTapGesture().onEnded { event in proxy.selectXValue(at: event.location.x) }
            }
            .frame(height: dynamicTypeSize.isAccessibilitySize ? 300 : 200)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityChartDescriptor(FilingChartDescriptor(title: String(localized: "charts.activity", locale: locale), labels: monthlyTotals.map { $0.start.formatted(DisclosureDates.style().locale(locale)) }, values: activity.filter { $0.type == .purchase }.map { Double($0.count) }, locale: locale, secondaryValues: activity.filter { $0.type == .sale }.map { Double($0.count) }))
            if let peak = monthlyTotals.max(by: { $0.count < $1.count }), peak.count > 0 {
                Text("charts.peak \(peak.start.formatted(DisclosureDates.style(.omitted).month(.wide).year().locale(locale))) \(peak.count)").font(.caption)
            }
            if let selectedMonth {
                let interval = TradeAnalytics.calendar.dateInterval(of: .month, for: selectedMonth)!
                ForEach(trades.filter { $0.transactionDate >= interval.start && $0.transactionDate < interval.end }) { trade in
                    NavigationLink(value: trade) { TradeRow(trade: trade, showsMember: false) }
                }
            }
        }
        Section(themed: "charts.delay") {
            Chart(delays) { record in
                PointMark(x: .value("Filed", record.filing.filedDate), y: .value("Days", min(record.days, 120)))
                    .foregroundStyle(record.days > 45 ? ConsigliereTheme.warning : ConsigliereTheme.accent)
                    .annotation(position: .top) { if record.days > 120 { Text("↑ \(record.days)").font(.caption2) } }
                RuleMark(y: .value("Deadline", 45)).foregroundStyle(ConsigliereTheme.warning).lineStyle(StrokeStyle(dash: [4]))
            }
            .chartYScale(domain: 0...120)
            .frame(height: dynamicTypeSize.isAccessibilitySize ? 280 : 180)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityChartDescriptor(FilingChartDescriptor(title: String(localized: "charts.delay", locale: locale), labels: delays.map { $0.filing.filedDate.formatted(DisclosureDates.style().locale(locale)) }, values: delays.map { Double($0.days) }, axisTitle: String(localized: "trade.lag", locale: locale), locale: locale))
            Text("charts.delaySummary \(delays.filter { $0.days > 45 }.count) \(delays.count) \(medianDelay)").font(.caption)
        }
    }
}
