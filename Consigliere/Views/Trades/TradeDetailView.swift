import Charts
import SwiftUI

struct TradeDetailView: View {
    @EnvironmentObject private var appState: AppState
    let trade: DisclosureTrade
    @State private var horizon = 30

    private static let lowConfidence = 0.9
    private var politician: Politician? { appState.politician(id: trade.politicianID) }
    private var memberName: String { politician?.name ?? trade.representative }

    var body: some View {
        List {
            Section { header }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
            Section {
                if let politician {
                    NavigationLink(value: politician) { MemberHeaderRow(politician: politician) }
                } else {
                    Text(verbatim: trade.representative).font(.headline)
                }
            }
            Section {
                LabeledContent("trade.amount") { Text(verbatim: trade.amountRange) }
                LabeledContent("trade.owner") { Text(trade.owner.label) }
                LabeledContent("event.transaction") { Text(trade.transactionDate, format: DisclosureDates.style(.long)) }
                LabeledContent("event.filed") { Text(trade.filedDate, format: DisclosureDates.style(.long)) }
                LabeledContent("trade.lag") {
                    Text("study.days \(trade.disclosureLagDays)").foregroundStyle(trade.isLate ? .orange : .primary)
                }
            } header: {
                Text("trade.details")
            } footer: {
                if trade.isLate { Text("trade.late.footer") }
            }
            if !highlights.isEmpty {
                Section("trade.notable") {
                    ForEach(highlights, id: \.self) { key in
                        Label(LocalizedStringKey(key), systemImage: "checkmark.circle").font(.subheadline)
                    }
                }
            }
            if !trade.eventStudy.isEmpty { priceContext }
            Section {
                Link(destination: trade.sourceURL) { Label("event.openSource", systemImage: "doc.richtext") }
                if trade.confidence < Self.lowConfidence {
                    Label("trade.lowConfidence", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } footer: {
                if let observedAt = trade.observedAt {
                    Text("trade.added \(observedAt, format: .dateTime.month(.abbreviated).day().year())")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("trade.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: trade.sourceURL, message: shareMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TradeTypePill(type: trade.type)
                Spacer()
                AmountText(amount: trade.amount).font(.title3.bold().monospacedDigit())
            }
            trade.type.headline(trade.displaySymbol).font(.largeTitle.bold())
            Text(verbatim: trade.assetName).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// Facts that make this trade notable. Lateness is shown on the timing row; the backend's
    /// generic recency and review flags are not highlights.
    private var highlights: [String] {
        var keys: [String] = []
        if trade.rankingReasons.contains("Large reported value range") { keys.append("trade.highlight.large") }
        if trade.rankingReasons.contains("Relevant committee or policy connection") { keys.append("trade.highlight.committee") }
        return keys
    }

    private var shareMessage: Text {
        switch trade.type {
        case .purchase: Text("share.purchase \(memberName) \(trade.displaySymbol) \(trade.amountRange)")
        case .sale: Text("share.sale \(memberName) \(trade.displaySymbol) \(trade.amountRange)")
        case .exchange: Text("share.exchange \(memberName) \(trade.displaySymbol) \(trade.amountRange)")
        }
    }

    private var points: [EventStudyPoint] {
        trade.eventStudy.filter { $0.tradingDay >= -30 && $0.tradingDay <= horizon }
    }

    /// Benchmark-adjusted returns around the trade, shown only when licensed prices are attached.
    private var priceContext: some View {
        Section {
            Picker("study.horizon", selection: $horizon) {
                Text(verbatim: "10d").tag(10); Text(verbatim: "30d").tag(30); Text(verbatim: "90d").tag(90)
            }
            .pickerStyle(.segmented)
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Trading day", point.tradingDay), y: .value("Return", point.abnormalReturn))
                        .foregroundStyle(ConsigliereTheme.gold).interpolationMethod(.catmullRom)
                }
                RuleMark(x: .value("Transaction", 0)).foregroundStyle(.blue)
                    .annotation(position: .top, alignment: .leading) { Text("study.transactionMarker").font(.caption2).foregroundStyle(.blue) }
                RuleMark(x: .value("Disclosure", min(trade.disclosureLagDays, horizon)))
                    .foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 2, dash: [4]))
                    .annotation(position: .bottom, alignment: .leading) { Text("study.disclosureMarker").font(.caption2).foregroundStyle(.orange) }
            }
            .chartYAxis { AxisMarks(format: Decimal.FormatStyle.Percent.percent.scale(1).precision(.fractionLength(0))) }
            .frame(height: 220)
        } header: {
            Text("study.abnormalReturn")
        } footer: {
            Text("study.chartCaption")
        }
    }
}
