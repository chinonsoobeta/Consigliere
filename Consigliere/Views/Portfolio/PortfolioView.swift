import Charts
import SwiftUI

struct PortfolioView: View {
    @EnvironmentObject private var appState: AppState
    private var summary: PortfolioSummary { appState.portfolioSummary }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DisclaimerBanner()
                    overview
                    exposures
                    diagnostics
                    holdings
                }.padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("portfolio.title")
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("portfolio.hypothetical").font(.caption.weight(.semibold)).foregroundStyle(ConsigliereTheme.gold)
            Text(summary.marketValue, format: .currency(code: "USD")).font(.largeTitle.bold())
            HStack { Text("portfolio.today").foregroundStyle(.secondary); ChangeLabel(value: summary.dayChange) }
        }.frame(maxWidth: .infinity, alignment: .leading).consigliereCard()
    }

    private var exposures: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("portfolio.exposure").font(.title3.bold())
            Chart(summary.exposures) { slice in
                SectorMark(angle: .value("Weight", slice.weight), innerRadius: .ratio(0.62), angularInset: 2)
                    .foregroundStyle(by: .value("Sector", slice.name))
            }.frame(height: 190).chartLegend(position: .bottom, alignment: .leading)
        }.consigliereCard()
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("portfolio.diagnostics", systemImage: "stethoscope").font(.headline)
            diagnostic("portfolio.concentration", value: summary.concentration, note: summary.concentration > 0.5 ? "portfolio.concentration.high" : "portfolio.concentration.balanced")
            diagnostic("portfolio.eventExposure", value: 0.62, note: "portfolio.eventExposure.note")
            Text("portfolio.diagnostics.disclaimer").font(.footnote).foregroundStyle(.secondary)
        }.consigliereCard()
    }

    private func diagnostic(_ title: LocalizedStringKey, value: Double, note: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title); Spacer(); Text(value, format: .percent).font(.subheadline.monospacedDigit()) }
            ProgressView(value: value).tint(value > 0.6 ? .orange : ConsigliereTheme.positive)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var holdings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("portfolio.holdings").font(.title3.bold()); Spacer(); Button("portfolio.edit") {} }
            ForEach(appState.holdings) { holding in
                if let instrument = appState.instruments.first(where: { $0.symbol == holding.symbol }) {
                    HStack {
                        VStack(alignment: .leading) { Text(instrument.symbol).font(.headline.monospaced()); Text("\(holding.shares.formatted()) shares").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        VStack(alignment: .trailing) { Text(holding.shares * instrument.price, format: .currency(code: instrument.currency)); ChangeLabel(value: instrument.changePercent) }
                    }.padding(.vertical, 5)
                    if holding.id != appState.holdings.last?.id { Divider() }
                }
            }
        }.consigliereCard()
    }
}

