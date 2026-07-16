import SwiftUI

struct IntelligenceLibraryView: View {
    @EnvironmentObject private var appState: AppState
    let scope: IntelligenceLibraryScope

    private var events: [MarketEvent] {
        appState.events.filter { event in
            switch scope {
            case .disclosures:
                event.source == .houseDisclosure || event.source == .senateDisclosure
            case .politics:
                event.source == .truthSocial
            case .markets:
                false
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if scope == .markets {
                    marketList
                } else {
                    eventList
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(scope.title)
            .refreshable { await appState.load(force: true) }
            .navigationDestination(for: MarketEvent.self) { EventDetailView(event: $0) }
            .navigationDestination(for: MarketInstrument.self) { InstrumentDetailView(instrument: $0) }
        }
    }

    private var eventList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                methodology
                if let error = appState.disclosureLoadError {
                    SourceUnavailableView(
                        title: "\(scope.title) unavailable",
                        message: error,
                        retry: { Task { await appState.load(force: true) } }
                    )
                } else if events.isEmpty {
                    SourceUnavailableView(
                        title: "No verified \(scope.title.lowercased()) items",
                        message: "No source-backed records are currently available. Consigliere does not substitute fixtures.",
                        retry: { Task { await appState.load(force: true) } }
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

    private var marketList: some View {
        List {
            Section {
                Text("Licensed quotes include source timestamps and freshness. Empty results indicate that market display rights or the provider are not configured.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if appState.instruments.isEmpty {
                Section {
                    SourceUnavailableView(
                        title: "Market data unavailable",
                        message: appState.disclosureLoadError ?? "No licensed market records are currently available.",
                        retry: { Task { await appState.load(force: true) } }
                    )
                    .listRowBackground(Color.clear)
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

    private var methodology: some View {
        Text(scope == .disclosures
            ? "Newly public filings are ordered by research priority, not transaction date. Trade and filing dates remain distinct."
            : "Political statements are ranked by recency, policy relevance, current licensed market context, and source confidence. Market context is not an event-window reaction.")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .consigliereCard()
    }
}

enum IntelligenceLibraryScope: String {
    case disclosures, politics, markets

    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .disclosures: "doc.text.magnifyingglass"
        case .politics: "building.columns"
        case .markets: "chart.line.uptrend.xyaxis"
        }
    }
}
