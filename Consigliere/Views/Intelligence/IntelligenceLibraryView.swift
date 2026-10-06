import SwiftUI

struct IntelligenceLibraryView: View {
    @EnvironmentObject private var appState: AppState
    let scope: IntelligenceLibraryScope

    private var events: [MarketEvent] {
        appState.events.filter { $0.source == .houseDisclosure || $0.source == .senateDisclosure }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch scope {
                case .disclosures: eventList
                case .markets: marketList
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(scope.title)
            .refreshable { await appState.load(force: true) }
            .navigationDestination(for: MarketEvent.self) { EventDetailView(event: $0) }
            .navigationDestination(for: MarketInstrument.self) { InstrumentDetailView(instrument: $0) }
            .navigationDestination(for: Politician.self) { PoliticianProfileView(politician: $0) }
        }
    }

    private var eventList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("library.disclosures.methodology")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .consigliereCard()
                if !appState.pendingFilings.isEmpty {
                    pendingSection
                }
                if events.isEmpty {
                    SourceAwareEmptyView(
                        providers: ["apify"],
                        emptyTitle: "library.disclosures.empty",
                        emptyMessage: "library.disclosures.empty.body"
                    )
                } else {
                    ForEach(events) { event in
                        NavigationLink(value: event) { EventCard(event: event) }.buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
    }

    private var pendingSection: some View {
        DisclosureGroup {
            VStack(spacing: 10) {
                ForEach(appState.pendingFilings) { PendingFilingRow(filing: $0) }
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("pending.title \(appState.pendingFilings.count)").font(.headline)
                Text("pending.subtitle").font(.caption).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(.primary)
        .consigliereCard()
    }

    private var marketList: some View {
        List {
            Section {
                Text("library.markets.methodology")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if appState.instruments.isEmpty {
                Section {
                    SourceAwareEmptyView(
                        providers: ["twelve-data"],
                        emptyTitle: "library.markets.empty",
                        emptyMessage: "library.markets.empty.body"
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            } else {
                Section {
                    ForEach(appState.instruments) { instrument in
                        NavigationLink(value: instrument) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(instrument.symbol).font(.headline.monospaced())
                                    Text(instrument.name).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(instrument.formattedPrice).font(.subheadline.weight(.semibold))
                                    ChangeLabel(value: instrument.changePercent)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

enum IntelligenceLibraryScope: String {
    case disclosures, markets

    var title: LocalizedStringKey { LocalizedStringKey(stringLiteral: "tab.\(rawValue)") }
    var icon: String {
        switch self {
        case .disclosures: "doc.text.magnifyingglass"
        case .markets: "chart.line.uptrend.xyaxis"
        }
    }
}
