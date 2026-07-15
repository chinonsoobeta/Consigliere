import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState

    private var primaryMarkets: [MarketInstrument] {
        let symbols = ["SPX", "NDX", "DJI", "TSX", "TX60", "WTI", "WCS"]
        return symbols.compactMap { symbol in appState.instruments.first { $0.symbol == symbol } }
    }

    private var globalContext: [MarketInstrument] {
        let symbols = ["STOXX", "FTSE", "DAX", "N225", "HSI", "MSCIW", "DXY", "GOLD"]
        return symbols.compactMap { symbol in appState.instruments.first { $0.symbol == symbol } }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    header
                    DisclaimerBanner()
                    marketSection("dashboard.northAmerica", subtitle: "dashboard.northAmerica.subtitle", instruments: primaryMarkets)
                    marketSection("dashboard.globalContext", subtitle: "dashboard.globalContext.subtitle", instruments: globalContext)
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
            Button(action: {}) {
                Image(systemName: "bell.fill")
                    .font(.headline)
                    .frame(width: 42, height: 42)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("alerts")
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
                    Text("dashboard.signalFeed").font(.title3.weight(.bold))
                    Text("dashboard.signalFeed.subtitle").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("dashboard.observedOnly").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            ForEach(appState.events) { event in
                NavigationLink(value: event) { EventCard(event: event) }.buttonStyle(.plain)
            }
        }
    }
}
