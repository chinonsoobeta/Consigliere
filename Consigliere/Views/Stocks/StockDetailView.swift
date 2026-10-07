import Charts
import SwiftUI

struct StockDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let symbol: String
    @State private var trades: [DisclosureTrade] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var holders: Int?
    @State private var interests: [DeclaredInterest] = []
    @State private var interestError: String?
    @State private var statements: [PresidentialStatement] = []
    @State private var showsAllTrades = false

    private var yearAgo: Date { DisclosureDates.calendar.date(byAdding: .year, value: -1, to: .now)! }
    private var lastYear: [DisclosureTrade] { trades.filter { $0.transactionDate >= yearAgo } }
    private var name: String { trades.first?.assetName ?? symbol }

    var body: some View {
        List {
            if let error {
                Section {
                    Text(verbatim: error).foregroundStyle(.orange)
                    Button("common.retry") { Task { await load() } }
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    if name != symbol { Text(verbatim: name).font(.subheadline).foregroundStyle(.secondary) }
                    HStack(alignment: .top, spacing: 0) {
                        stat(lastYear.filter { $0.type == .purchase }.count, "stock.stat.buys", ConsigliereTheme.positive)
                        stat(lastYear.filter { $0.type == .sale }.count, "stock.stat.sells", ConsigliereTheme.negative)
                        stat(Set(lastYear.map { $0.politicianID ?? $0.representative }).count, "stock.stat.members", .primary)
                        if let holders { stat(holders, "stock.stat.holders", .primary) }
                    }
                    Text("stock.stat.window").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            if !trades.isEmpty {
                Section {
                    activityChart
                } header: { Text("stock.activity") } footer: { Text("stock.timelineMethod") }
            } else if loaded && error == nil {
                Section { Text("stock.noTrades").foregroundStyle(.secondary) }
            }
            if !members.isEmpty {
                Section("stock.members") {
                    ForEach(members, id: \.politician.id) { entry in
                        NavigationLink(value: entry.politician) {
                            HStack {
                                MemberHeaderRow(politician: entry.politician)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(entry.latest.type.label).font(.caption.weight(.semibold)).foregroundStyle(entry.latest.type.color)
                                    Text(entry.latest.transactionDate, format: DisclosureDates.compact(entry.latest.transactionDate))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            if !statements.isEmpty {
                Section("statement.mentions \(statements.count)") {
                    ForEach(statements) { statement in NavigationLink(value: statement) { StatementRow(statement: statement) } }
                }
            }
            if symbol.hasPrefix("LSE:") || !interests.isEmpty {
                Section("stock.ukHolders") {
                    if let interestError { Text(verbatim: interestError).foregroundStyle(.orange) }
                    else if interests.isEmpty { Text("interests.empty") }
                    ForEach(interests) { interest in
                        if let member = appState.politicians.first(where: { $0.id == interest.memberID }) { NavigationLink(value: member) { MemberHeaderRow(politician: member) } }
                        Text(verbatim: interest.organisation)
                        Link("event.openSource", destination: interest.sourceURL)
                    }
                    ParliamentAttribution()
                }
            }
            if !trades.isEmpty {
                Section("stock.trades") {
                    ForEach(showsAllTrades ? trades : Array(trades.prefix(15))) { trade in NavigationLink(value: trade) { TradeRow(trade: trade) } }
                    if trades.count > 15 && !showsAllTrades { Button("portfolio.showAll \(trades.count)") { showsAllTrades = true } }
                }
            }
            Section {
                NavigationLink("portfolio.congress") { ReferencePortfolioView(portfolioID: "congress") }
            } footer: { Text("stock.footer") }
        }
        .navigationTitle(Text(verbatim: symbol))
        .task { await load() }
    }

    private func stat(_ value: Int, _ label: LocalizedStringKey, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number).font(.title3.bold().monospacedDigit()).foregroundStyle(value == 0 ? .secondary : color)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Purchases above the axis and sales below, per month of transaction, for the last two years.
    private var activityChart: some View {
        let buckets = TradeAnalytics.activityHistogram(trades)
        let peak = max(buckets.map(\.count).max() ?? 1, 1)
        return Chart(buckets) { bucket in
            BarMark(
                x: .value("Month", bucket.month, unit: .month, calendar: TradeAnalytics.calendar),
                y: .value("Trades", bucket.type == .sale ? -bucket.count : bucket.count)
            )
            .foregroundStyle(bucket.type == .purchase ? ConsigliereTheme.positive : ConsigliereTheme.negative)
        }
        .chartYScale(domain: -peak...peak)
        .chartYAxis {
            AxisMarks(values: [-peak, 0, peak]) { value in
                AxisGridLine()
                AxisValueLabel { if let count = value.as(Int.self) { Text(abs(count), format: .number) } }
            }
        }
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 260 : 170)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityChartDescriptor(FilingChartDescriptor(
            title: String(localized: "stock.activity", locale: locale),
            labels: buckets.filter { $0.type == .purchase }.map { $0.month.formatted(DisclosureDates.style(.omitted).month(.abbreviated).year().locale(locale)) },
            values: buckets.filter { $0.type == .purchase }.map { Double($0.count) },
            locale: locale,
            secondaryValues: buckets.filter { $0.type == .sale }.map { Double($0.count) }
        ))
    }

    /// Members who traded this security, most recent first, with their latest transaction.
    private var members: [(politician: Politician, latest: DisclosureTrade)] {
        Dictionary(grouping: trades.filter { $0.politicianID != nil }, by: { $0.politicianID! })
            .compactMap { id, trades in
                guard let politician = appState.politician(id: id), let latest = trades.max(by: { $0.transactionDate < $1.transactionDate }) else { return nil }
                return (politician, latest)
            }
            .sorted { $0.latest.transactionDate > $1.latest.transactionDate }
    }

    private func load() async {
        error = nil
        do {
            async let loadedTrades = appState.loadStockTrades(symbol: symbol)
            async let portfolio = try? appState.loadPortfolio(id: "congress", ownOnly: false, ticker: symbol)
            async let mentions = try? appState.loadStatements(ticker: symbol)
            trades = try await loadedTrades.sorted { $0.transactionDate > $1.transactionDate }
            holders = await portfolio.map { $0.positions.first { $0.group == "stocks" }?.membersHolding ?? 0 }
            statements = await mentions ?? []
        } catch { self.error = error.localizedDescription }
        loaded = true
        if symbol.hasPrefix("LSE:") || appState.homeCountries.contains(.uk) {
            do {
                interests = try await appState.loadInterests(country: .uk, ticker: symbol).filter { $0.endedAt == nil }
                if !interests.isEmpty && !appState.politicians.contains(where: { $0.nation == .uk }) { await appState.loadCountry(.uk) }
                interestError = nil
            } catch { interestError = error.localizedDescription }
        }
    }
}
