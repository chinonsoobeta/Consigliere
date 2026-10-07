import Charts
import SwiftUI

struct StockDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let symbol: String
    @State private var trades: [DisclosureTrade] = []
    @State private var error: String?
    @State private var holders: Int?
    @State private var interests: [DeclaredInterest] = []
    @State private var interestError: String?
    @State private var statements: [PresidentialStatement] = []

    var body: some View {
        List {
            if let error { Text(verbatim: error).foregroundStyle(.orange); Button("common.retry") { Task { await load() } } }
            Section("stock.activity") {
                if trades.isEmpty {
                    Text("politician.noTrades")
                } else {
                    let filedDates = trades.map { $0.filedDate.timeIntervalSince1970 }
                    Chart(trades) { trade in
                        PointMark(x: .value("Transaction", trade.transactionDate), y: .value("Filed", trade.filedDate.timeIntervalSince1970))
                            .foregroundStyle(trade.type.color)
                            .symbolSize(20 + min(80, log10(max(trade.amount.sortValue, 1)) * 10))
                    }
                    .chartYScale(domain: (filedDates.min()! - 86_400)...(filedDates.max()! + 86_400))
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: dynamicTypeSize.isAccessibilitySize ? 2 : 5)) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(verbatim: date.formatted(DisclosureDates.style(.omitted).month(.abbreviated).day().locale(locale)))
                                        .font(.caption2)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let timestamp = value.as(Double.self) {
                                    Text(verbatim: Date(timeIntervalSince1970: timestamp).formatted(DisclosureDates.style().locale(locale)))
                                }
                            }
                        }
                    }
                    .frame(height: dynamicTypeSize.isAccessibilitySize ? 320 : 220)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .accessibilityRepresentation {
                        VStack {
                            ForEach(trades) { trade in
                                Text(trade.type.label)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(Text(trade.type.label) + Text(verbatim: " · " + trade.transactionDate.formatted(DisclosureDates.style().locale(locale))))
                                    .accessibilityValue(Text("event.filed") + Text(verbatim: " · " + trade.filedDate.formatted(DisclosureDates.style().locale(locale)) + " · " + trade.amountRange))
                            }
                        }
                    }
                    .accessibilityChartDescriptor(FilingChartDescriptor(title: symbol, labels: trades.map { $0.transactionDate.formatted(DisclosureDates.style().locale(locale)) }, values: trades.map { $0.filedDate.timeIntervalSince1970 }, axisTitle: String(localized: "event.filed", locale: locale), locale: locale, dates: true))
                }
                Text("stock.timelineMethod").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if let holders { Text("portfolio.holders \(holders)") } else { Text("portfolio.unavailable") }
                NavigationLink("portfolio.congress") { ReferencePortfolioView(portfolioID: "congress") }
            } footer: { Text("portfolio.estimated") }
            Section("stock.members") {
                ForEach(members) { politician in NavigationLink(value: politician) { MemberHeaderRow(politician: politician) } }
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
            if !statements.isEmpty {
                Section("statement.mentions \(statements.count)") {
                    ForEach(statements) { statement in NavigationLink(value: statement) { Text(verbatim: statement.title) } }
                }
            }
            Section("filing.trades") {
                ForEach(trades) { trade in NavigationLink(value: trade) { TradeRow(trade: trade) } }
            }
        }
        .navigationTitle(Text(verbatim: symbol))
        .task { await load() }
    }

    private var members: [Politician] {
        let ids = Set(trades.compactMap(\.politicianID))
        return appState.politicians.filter { ids.contains($0.id) }.sorted { $0.name < $1.name }
    }

    private func load() async {
        error = nil
        do {
            trades = try await appState.loadStockTrades(symbol: symbol)
            if let portfolio = try? await appState.loadPortfolio(id: "congress", ownOnly: false) { holders = portfolio.positions.first { $0.ticker == symbol && $0.group == "stocks" }?.membersHolding ?? 0 }
            statements = (try? await appState.loadStatements(ticker: symbol)) ?? []
            do {
                interests = try await appState.loadInterests(country: .uk, ticker: symbol).filter { $0.endedAt == nil }
                if !interests.isEmpty && !appState.politicians.contains(where: { $0.nation == .uk }) { await appState.loadCountry(.uk) }
                interestError = nil
            } catch { interestError = error.localizedDescription }
        } catch { self.error = error.localizedDescription }
    }
}
