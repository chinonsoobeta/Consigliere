import Charts
import SwiftUI

struct InstrumentDetailView: View {
    @EnvironmentObject private var appState: AppState
    let instrument: MarketInstrument

    private var relatedEvents: [MarketEvent] { appState.events.filter { $0.mentionedSymbols.contains(instrument.symbol) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text(instrument.symbol).font(.largeTitle.bold().monospaced())
                        Text(instrument.name).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { appState.toggleWatchlist(instrument) } label: {
                        Image(systemName: appState.watchlist.contains(instrument.symbol) ? "star.fill" : "star")
                            .font(.title3).foregroundStyle(ConsigliereTheme.gold)
                    }
                    .accessibilityLabel("watchlist.toggle")
                }
                HStack(alignment: .firstTextBaseline) { Text(instrument.formattedPrice).font(.title.bold()); ChangeLabel(value: instrument.changePercent) }
                chart
                metadata
                if !relatedEvents.isEmpty {
                    Text("instrument.relatedEvents").font(.title3.bold())
                    ForEach(relatedEvents) { EventCard(event: $0) }
                }
                DisclaimerBanner()
            }.padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(instrument.symbol)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var chart: some View {
        Chart(instrument.history) { point in
            LineMark(x: .value("Time", point.timestamp), y: .value("Value", point.value)).foregroundStyle(ConsigliereTheme.gold).interpolationMethod(.catmullRom)
            AreaMark(x: .value("Time", point.timestamp), y: .value("Value", point.value)).foregroundStyle(.linearGradient(colors: [ConsigliereTheme.gold.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom)).interpolationMethod(.catmullRom)
        }
        .frame(height: 240).consigliereCard()
    }

    private var metadata: some View {
        VStack(spacing: 12) {
            row("instrument.type", value: String(localized: String.LocalizationValue(instrument.kind.rawValue)))
            row("instrument.exchange", value: instrument.exchange)
            row("instrument.currency", value: instrument.currency)
            row("instrument.updated", value: instrument.updatedAt.formatted(date: .omitted, time: .standard))
            HStack { Text("instrument.status").foregroundStyle(.secondary); Spacer(); FreshnessBadge(freshness: instrument.freshness) }
        }.consigliereCard()
    }

    private func row(_ title: LocalizedStringKey, value: String) -> some View { HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing) } }
}
