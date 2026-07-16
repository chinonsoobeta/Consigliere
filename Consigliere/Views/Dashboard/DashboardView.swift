import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @State private var scope = BriefScope.all

    enum BriefScope: String, CaseIterable, Identifiable {
        case all, disclosures, politics, markets
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    private var briefEvents: [MarketEvent] {
        appState.events.filter { event in
            switch scope {
            case .all: true
            case .disclosures: event.source == .houseDisclosure || event.source == .senateDisclosure
            case .politics: event.source == .truthSocial
            case .markets: event.reaction != nil
            }
        }
    }

    private var primaryMarkets: [MarketInstrument] {
        let symbols = ["SPY", "QQQ", "DIA", "IXIC", "TSX:TSX"]
        let preferred = symbols.compactMap { symbol in appState.instruments.first { $0.symbol == symbol } }
        return preferred.isEmpty
            ? Array(appState.instruments.filter { $0.region == .northAmerica }.prefix(7))
            : preferred
    }

    private var globalContext: [MarketInstrument] {
        Array(appState.instruments.filter { $0.region != .northAmerica }.prefix(8))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    header
                    DisclaimerBanner()
                    if !primaryMarkets.isEmpty {
                        marketSection("dashboard.northAmerica", subtitle: "dashboard.northAmerica.subtitle", instruments: primaryMarkets)
                    }
                    if !globalContext.isEmpty {
                        marketSection("dashboard.globalContext", subtitle: "dashboard.globalContext.subtitle", instruments: globalContext)
                    }
                    eventFeed
                }
                .padding(.horizontal)
                .padding(.bottom, 28)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarHidden(true)
            .refreshable { await appState.load(force: true) }
            .overlay { if appState.isLoading { ProgressView().controlSize(.large) } }
            .navigationDestination(for: MarketInstrument.self) { InstrumentDetailView(instrument: $0) }
            .navigationDestination(for: MarketEvent.self) { EventDetailView(event: $0) }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Wordmark()
                Text("dashboard.subtitle").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 10)
    }

    private func marketSection(_ title: LocalizedStringKey, subtitle: LocalizedStringKey, instruments: [MarketInstrument]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.bold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(instruments) { instrument in
                        NavigationLink(value: instrument) { MarketCard(instrument: instrument) }.buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var eventFeed: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Today’s Intelligence Brief").font(.title3.weight(.bold))
                    Text("Ranked by freshness, materiality, political relevance, market context, and evidence quality.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("dashboard.observedOnly").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            Picker("Brief scope", selection: $scope) {
                ForEach(BriefScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if let error = appState.disclosureLoadError {
                SourceUnavailableView(
                    title: "Live intelligence unavailable",
                    message: error,
                    retry: { Task { await appState.load(force: true) } }
                )
            } else if briefEvents.isEmpty {
                SourceUnavailableView(
                    title: "No verified intelligence yet",
                    message: "Consigliere does not substitute fixtures or inferred records. Check source status or refresh.",
                    retry: { Task { await appState.load(force: true) } }
                )
            } else {
                ForEach(briefEvents) { event in
                    NavigationLink(value: event) { EventCard(event: event) }.buttonStyle(.plain)
                }
            }
        }
    }
}
