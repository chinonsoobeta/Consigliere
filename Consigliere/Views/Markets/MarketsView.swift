import SwiftUI

/// Licensed quotes. The tab only appears once a market data source is connected.
struct MarketsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""

    private var results: [MarketInstrument] {
        guard !query.isEmpty else { return appState.instruments }
        return appState.instruments.filter { instrument in
            ([instrument.symbol, instrument.name, instrument.exchange] + instrument.aliases)
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if appState.instruments.isEmpty {
                    Section {
                        SourceAwareEmptyView(
                            providers: ["twelve-data"],
                            emptyTitle: "library.markets.empty",
                            emptyMessage: "library.markets.empty.body"
                        )
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } else {
                    Section {
                        ForEach(results) { instrument in
                            NavigationLink(value: instrument) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(verbatim: instrument.symbol).font(.headline.monospaced())
                                        Text(verbatim: instrument.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text(verbatim: instrument.formattedPrice).font(.subheadline.weight(.semibold))
                                        ChangeLabel(value: instrument.changePercent)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    } footer: {
                        Text("library.markets.methodology")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("tab.markets")
            .searchable(text: $query, prompt: "search.prompt")
            .refreshable { await appState.load(force: true) }
            .consigliereDestinations()
        }
    }
}
