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
        ThemedList {
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
            if !trade.symbol.isEmpty { Section { NavigationLink(value: StockRoute(symbol: trade.symbol)) { Text("stock.open \(trade.symbol)") } } }
            Section {
                LabeledContent("trade.amount") { Text(verbatim: trade.amountRange) }
                LabeledContent("trade.owner") { Text(trade.owner.label) }
                if let note = trade.assetDescription {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("trade.filerNote").foregroundStyle(.secondary)
                        Text(verbatim: note)
                    }
                }
                LabeledContent("event.transaction") { Text(trade.transactionDate, format: DisclosureDates.style(.long)) }
                LabeledContent("event.filed") { Text(trade.filedDate, format: DisclosureDates.style(.long)) }
                LabeledContent("trade.lag") {
                    Text("study.days \(trade.disclosureLagDays)").foregroundStyle(trade.isLate ? ConsigliereTheme.warning : .primary)
                }
            } header: {
                SectionTitle("trade.details")
            } footer: {
                if trade.isLate { Text("trade.late.footer") }
            }
            if !highlights.isEmpty {
                Section(themed: "trade.notable") {
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
                        .font(.footnote).foregroundStyle(ConsigliereTheme.warning)
                }
            } footer: {
                if let observedAt = trade.observedAt {
                    Text("trade.added \(observedAt, format: .dateTime.month(.abbreviated).day().year())")
                }
            }
        }
        .navigationTitle("trade.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: trade.sourceURL, message: shareMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TradeTypePill(type: trade.type)
                if trade.isOption { OptionsTag() }
            }
            trade.type.headline(trade.displaySymbol)
                .font(ConsigliereTheme.display(.largeTitle, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: trade.assetName).font(.subheadline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                AmountText(amount: trade.amount)
                    .font(.system(.largeTitle, weight: .bold).monospacedDigit())
                    .foregroundStyle(trade.type.color)
                Text("trade.amount").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            lagBar
        }
        .padding(.top, 4)
    }

    /// Days from trade to filing against the 45-day STOCK Act deadline.
    private var lagBar: some View {
        let days = trade.disclosureLagDays
        let color = trade.isLate ? ConsigliereTheme.warning : ConsigliereTheme.accent
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("trade.lag").font(.subheadline.weight(.semibold))
                Spacer()
                Text("study.days \(days)").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(color)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(ConsigliereTheme.raised)
                    Capsule().fill(color).frame(width: max(8, proxy.size.width * min(Double(days) / 45, 1)))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
        }
        .padding(16)
        .background(ConsigliereTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ConsigliereTheme.hairline) }
        .padding(.top, 6)
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
                        .foregroundStyle(ConsigliereTheme.accent).interpolationMethod(.catmullRom)
                }
                RuleMark(x: .value("Transaction", 0)).foregroundStyle(.primary)
                    .annotation(position: .top, alignment: .leading) { Text("study.transactionMarker").font(.caption2).foregroundStyle(.primary) }
                RuleMark(x: .value("Disclosure", min(trade.disclosureLagDays, horizon)))
                    .foregroundStyle(ConsigliereTheme.warning).lineStyle(StrokeStyle(lineWidth: 2, dash: [4]))
                    .annotation(position: .bottom, alignment: .leading) { Text("study.disclosureMarker").font(.caption2).foregroundStyle(ConsigliereTheme.warning) }
            }
            .chartYAxis { AxisMarks(format: Decimal.FormatStyle.Percent.percent.scale(1).precision(.fractionLength(0))) }
            .frame(height: 220)
        } header: {
            SectionTitle("study.abnormalReturn")
        } footer: {
            Text("study.chartCaption")
        }
    }
}
