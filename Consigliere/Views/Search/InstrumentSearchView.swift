import SwiftUI

struct InstrumentSearchView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""
    @State private var selectedKind: InstrumentKind?

    private var results: [MarketInstrument] {
        appState.instruments.filter { instrument in
            let matchesKind = selectedKind == nil || instrument.kind == selectedKind
            let terms = [instrument.symbol, instrument.name, instrument.exchange] + instrument.aliases
            let matchesQuery = query.isEmpty || terms.contains { $0.localizedCaseInsensitiveContains(query) }
            return matchesKind && matchesQuery
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section { kindFilters.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                Section {
                    ForEach(results) { instrument in
                        NavigationLink(value: instrument) { resultRow(instrument) }
                    }
                } header: { Text("search.results \(results.count)") }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("search.title")
            .searchable(text: $query, prompt: "search.prompt")
            .navigationDestination(for: MarketInstrument.self) { InstrumentDetailView(instrument: $0) }
        }
    }

    private var kindFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                filterButton("search.all", kind: nil)
                ForEach(InstrumentKind.allCases, id: \.self) { kind in filterButton(kind.label, kind: kind) }
            }.padding(.horizontal)
        }
    }

    private func filterButton(_ title: LocalizedStringKey, kind: InstrumentKind?) -> some View {
        Button { selectedKind = kind } label: {
            Text(title).font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(selectedKind == kind ? Color.white : Color.primary)
                .background(selectedKind == kind ? ConsigliereTheme.navy : Color.secondary.opacity(0.12), in: Capsule())
        }.buttonStyle(.plain)
    }

    private func resultRow(_ instrument: MarketInstrument) -> some View {
        HStack(spacing: 12) {
            Image(systemName: instrument.kind.icon).foregroundStyle(ConsigliereTheme.gold).frame(width: 32, height: 32).background(ConsigliereTheme.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                HStack { Text(instrument.symbol).font(.headline.monospaced()); FreshnessBadge(freshness: instrument.freshness) }
                Text(instrument.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text("\(instrument.exchange) · \(instrument.currency)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) { Text(instrument.formattedPrice).font(.subheadline.weight(.semibold)); ChangeLabel(value: instrument.changePercent) }
        }.padding(.vertical, 5)
    }
}

