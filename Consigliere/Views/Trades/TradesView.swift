import SwiftUI

/// Every recently filed trade, newest filing day first, searchable by ticker, company, or member.
struct TradesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""
    @State private var filter = TradeFilter.all

    enum TradeFilter: String, CaseIterable, Identifiable {
        case all, purchase, sale
        var id: String { rawValue }
        var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "trades.filter.\(rawValue)") }
    }

    private var trades: [DisclosureTrade] {
        appState.latestTrades.filter { trade in
            let matchesType = switch filter {
            case .all: true
            case .purchase: trade.type == .purchase
            case .sale: trade.type == .sale
            }
            guard matchesType else { return false }
            guard !query.isEmpty else { return true }
            let name = appState.politician(id: trade.politicianID)?.name ?? trade.representative
            return [trade.symbol, trade.assetName, name].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var days: [(day: Date, trades: [DisclosureTrade])] {
        // Keep the noon-UTC anchor: midnight UTC renders as the previous day west of Greenwich.
        Dictionary(grouping: trades) { DisclosureDates.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: $0.filedDate) ?? $0.filedDate }
            .map { ($0.key, $0.value.sorted { $0.transactionDate > $1.transactionDate }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("trades.filter", selection: $filter) {
                        ForEach(TradeFilter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("trades.window.footer")
                }
                if !appState.pendingFilings.isEmpty && query.isEmpty {
                    Section {
                        DisclosureGroup {
                            ForEach(appState.pendingFilings) { PendingFilingRow(filing: $0) }
                        } label: {
                            Text("pending.title \(appState.pendingFilings.count)").font(.subheadline.weight(.semibold))
                        }
                    } footer: {
                        Text("pending.subtitle")
                    }
                }
                if appState.latestTrades.isEmpty {
                    Section {
                        SourceAwareEmptyView(
                            providers: AppState.disclosureProviders,
                            emptyTitle: "home.empty",
                            emptyMessage: "home.empty.body"
                        )
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } else if trades.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                ForEach(days, id: \.day) { group in
                    Section {
                        ForEach(group.trades) { trade in
                            NavigationLink(value: trade) { TradeRow(trade: trade) }
                        }
                    } header: {
                        Text("trades.filedOn \(group.day, format: DisclosureDates.style(.long))")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("tab.trades")
            .searchable(text: $query, prompt: "trades.searchPrompt")
            .refreshable { await appState.load(force: true) }
            .consigliereDestinations()
        }
    }
}
