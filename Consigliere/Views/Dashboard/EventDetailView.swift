import Charts
import SwiftUI

struct EventDetailView: View {
    @EnvironmentObject private var appState: AppState
    let event: MarketEvent

    private var reactedInstrument: MarketInstrument? {
        guard let symbol = event.reaction?.symbol else { return nil }
        return appState.instruments.first { $0.symbol == symbol }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { ImpactBadge(impact: event.impact); Spacer(); FreshnessBadge(freshness: event.freshness) }
                Text(event.title).font(.largeTitle.bold())
                sourceCard
                if let instrument = reactedInstrument { reactionChart(instrument) }
                analysisCard
                rankingCard
                methodology
                DisclaimerBanner()
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("event.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(event.source.label, systemImage: event.source.icon).font(.headline)
            Text(event.body).font(.body)
            Divider()
            timestampRow("event.published", value: event.publishedAt)
            timestampRow("event.retrieved", value: event.retrievedAt)
            if let transactionDate = event.transactionDate { timestampRow("event.transaction", value: transactionDate) }
            Link(destination: event.sourceURL) { Label("event.openSource", systemImage: "arrow.up.right.square") }
        }
        .consigliereCard()
    }

    private func timestampRow(_ title: LocalizedStringKey, value: Date) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.monospacedDigit()) }
    }

    private func reactionChart(_ instrument: MarketInstrument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("event.marketReaction").font(.headline); Spacer(); ChangeLabel(value: instrument.changePercent) }
            Chart(instrument.history) { point in
                LineMark(x: .value("Time", point.timestamp), y: .value("Price", point.value))
                    .foregroundStyle(ConsigliereTheme.gold).interpolationMethod(.catmullRom)
                RuleMark(x: .value("Event", event.publishedAt)).foregroundStyle(.red).lineStyle(StrokeStyle(dash: [4]))
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
            .frame(height: 190)
            if let reaction = event.reaction {
                HStack { window("1m", reaction.oneMinute); window("5m", reaction.fiveMinutes); window("15m", reaction.fifteenMinutes); window("60m", reaction.sixtyMinutes) }
            }
        }
        .consigliereCard()
    }

    private func window(_ label: String, _ value: Double?) -> some View {
        VStack(spacing: 4) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value?.signedPercent ?? "—").font(.caption.weight(.bold)).foregroundStyle((value ?? 0) >= 0 ? ConsigliereTheme.positive : ConsigliereTheme.negative) }.frame(maxWidth: .infinity)
    }

    private var analysisCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("event.analysis", systemImage: "sparkles").font(.headline)
            Text(event.explanation)
            ProgressView(value: event.confidence) { Text("event.confidence") } currentValueLabel: { Text(event.confidence.formatted(.percent)) }
            FlowLayout(items: event.topics)
        }
        .consigliereCard()
    }

    private var rankingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Why this ranked", systemImage: "list.number").font(.headline)
            Text(event.rankingScore, format: .percent.precision(.fractionLength(0)))
                .font(.title2.bold().monospacedDigit())
            ForEach(event.rankingReasons, id: \.self) { reason in
                Label(reason, systemImage: "checkmark.circle").font(.subheadline)
            }
            Text("This score prioritizes research attention. It is not a trading recommendation.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .consigliereCard()
    }

    private var methodology: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("event.methodology").font(.headline)
            Text("event.methodology.body").font(.footnote).foregroundStyle(.secondary)
        }
        .consigliereCard()
    }
}

struct FlowLayout: View {
    let items: [String]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack { ForEach(items, id: \.self) { Text($0).font(.caption).padding(.horizontal, 9).padding(.vertical, 6).background(.quaternary, in: Capsule()) } }
        }
    }
}
