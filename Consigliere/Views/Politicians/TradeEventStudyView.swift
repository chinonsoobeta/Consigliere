import Charts
import SwiftUI

struct TradeEventStudyView: View {
    let trade: DisclosureTrade
    let politician: Politician
    @State private var horizon = 30
    @State private var series = EventStudySeries.abnormal

    enum EventStudySeries: String, CaseIterable, Identifiable {
        case security, abnormal
        var id: String { rawValue }
        var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "study.\(rawValue)") }
    }

    private var points: [EventStudyPoint] {
        trade.eventStudy.filter { $0.tradingDay >= -30 && $0.tradingDay <= horizon }
    }

    private var disclosureMarker: Int { min(trade.disclosureLagDays, horizon) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                controls
                if points.isEmpty {
                    ContentUnavailableView(
                        "study.marketDataUnavailable",
                        systemImage: "chart.xyaxis.line",
                        description: Text("study.marketDataUnavailable.body")
                    )
                    .consigliereCard()
                } else {
                    chart
                    windows
                }
                dates
                methodology
                Link(destination: trade.sourceURL) { Label("event.openSource", systemImage: "arrow.up.right.square") }.consigliereCard()
                DisclaimerBanner()
            }.padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("study.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(trade.symbol).font(.largeTitle.bold().monospaced()); Spacer(); Label(trade.type.label, systemImage: trade.type.icon).foregroundStyle(trade.type.color) }
            Text("\(politician.name) · \(trade.assetName)").foregroundStyle(.secondary)
            Text(trade.amountRange).font(.headline)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("study.series", selection: $series) { ForEach(EventStudySeries.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
            Picker("study.horizon", selection: $horizon) {
                Text("10d").tag(10); Text("30d").tag(30); Text("90d").tag(90)
            }.pickerStyle(.segmented)
        }.consigliereCard()
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(series == .security ? "study.rawReturn" : "study.abnormalReturn").font(.headline)
            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Trading day", point.tradingDay),
                        y: .value("Return", series == .security ? point.securityReturn : point.abnormalReturn)
                    ).foregroundStyle(ConsigliereTheme.gold).interpolationMethod(.catmullRom)
                }
                RuleMark(x: .value("Transaction", 0)).foregroundStyle(.blue).lineStyle(StrokeStyle(lineWidth: 2))
                    .annotation(position: .top, alignment: .leading) { Text("study.transactionMarker").font(.caption2).foregroundStyle(.blue) }
                RuleMark(x: .value("Disclosure", disclosureMarker)).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 2, dash: [4]))
                    .annotation(position: .bottom, alignment: .leading) { Text("study.disclosureMarker").font(.caption2).foregroundStyle(.orange) }
            }
            .chartYScale(domain: .automatic(includesZero: true))
            .chartYAxis { AxisMarks(format: Decimal.FormatStyle.Percent.percent.scale(1).precision(.fractionLength(0))) }
            .frame(height: 270)
            Text("study.chartCaption").font(.caption).foregroundStyle(.secondary)
        }.consigliereCard()
    }

    private var windows: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("study.keyWindows").font(.headline)
            let days = [-30, -10, -5, -1, 1, 5, 10, 30, 90].filter { $0 <= horizon }
            Grid(horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow { Text("study.window").foregroundStyle(.secondary); Text("study.security").foregroundStyle(.secondary); Text("study.vsBenchmark").foregroundStyle(.secondary) }
                ForEach(days, id: \.self) { day in
                    if let point = trade.returnAt(day: day) {
                        GridRow {
                            Text(day > 0 ? "+\(day)d" : "\(day)d").font(.subheadline.monospaced())
                            returnText(point.securityReturn)
                            returnText(point.abnormalReturn)
                        }
                    }
                }
            }.font(.subheadline)
        }.consigliereCard()
    }

    private func returnText(_ value: Double) -> some View {
        Text(value, format: .percent.precision(.fractionLength(1))).font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(value >= 0 ? ConsigliereTheme.positive : ConsigliereTheme.negative)
    }

    private var dates: some View {
        VStack(spacing: 11) {
            row("event.transaction", trade.transactionDate)
            row("event.published", trade.filedDate)
            HStack { Text("study.disclosureLag").foregroundStyle(.secondary); Spacer(); Text("\(trade.disclosureLagDays) days").font(.subheadline.monospacedDigit()) }
            HStack { Text("study.owner").foregroundStyle(.secondary); Spacer(); Text(trade.owner.label) }
        }.consigliereCard()
    }

    private func row(_ label: LocalizedStringKey, _ date: Date) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(date.formatted(date: .long, time: .omitted)).font(.subheadline) }
    }

    private var methodology: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("event.methodology", systemImage: "function").font(.headline)
            Text("study.methodology").font(.footnote).foregroundStyle(.secondary)
            FreshnessBadge(freshness: trade.freshness)
        }.consigliereCard()
    }
}
