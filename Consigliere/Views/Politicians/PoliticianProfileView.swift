import Charts
import SwiftUI

struct PoliticianProfileView: View {
    @EnvironmentObject private var appState: AppState
    let politician: Politician

    private var trades: [DisclosureTrade] { appState.disclosures(for: politician) }
    private var coverage: DisclosureCoverageSummary? { appState.coverage(for: politician) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                profileHeader
                DisclosureMethodologyBanner()
                if appState.disclosureLoadError != nil { disclosureErrorView }
                coverageSection
                tradesSection
                DisclaimerBanner()
            }.padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(politician.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: DisclosureTrade.self) { TradeEventStudyView(trade: $0, politician: politician) }
        .task { await appState.loadDisclosures(for: politician) }
        .refreshable { await appState.loadDisclosures(for: politician) }
    }

    private var disclosureErrorView: some View {
        HStack {
            Label("disclosures.loadError", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline).foregroundStyle(.orange)
            Spacer()
            Button("common.retry") { Task { await appState.load(force: true) } }
                .buttonStyle(.bordered)
        }
        .consigliereCard()
    }

    private var profileHeader: some View {
        HStack(spacing: 16) {
            AsyncImage(url: politician.imageURL) { image in image.resizable().scaledToFill() } placeholder: {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
            }
            .frame(width: 82, height: 82).clipShape(Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(politician.name).font(.title.bold())
                Text("\(politician.party) · \(politician.jurisdiction)").foregroundStyle(.secondary)
                Label(politician.chamber.label, systemImage: politician.chamber.icon).font(.subheadline.weight(.semibold)).foregroundStyle(ConsigliereTheme.gold)
                Text("politician.servingSince \(politician.serviceStart)").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var coverageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available disclosure coverage").font(.title3.bold())
            Text("Coverage reflects disclosures matched to this person, rather than chamber-wide totals.")
                .font(.caption).foregroundStyle(.secondary)
            if let coverage {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(coverage.records) records").font(.headline.monospacedDigit())
                        Text([coverage.earliest, coverage.latest].compactMap { $0 }.joined(separator: " – "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("Available records", systemImage: "calendar.badge.checkmark")
                        .font(.caption).foregroundStyle(ConsigliereTheme.gold)
                }
            } else {
                Text("No verified coverage metadata is available for this chamber.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.consigliereCard()
    }

    private var tradesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("politician.disclosures").font(.title3.bold())
            if trades.isEmpty {
                if appState.loadingPoliticianIDs.contains(politician.id) {
                    ProgressView("Loading normalized disclosures…")
                        .frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView("politician.noTrades", systemImage: "doc.text.magnifyingglass", description: Text("politician.noTrades.body"))
                }
            } else {
                ForEach(trades) { trade in
                    NavigationLink(value: trade) { DisclosureTradeRow(trade: trade) }.buttonStyle(.plain)
                }
            }
        }
    }
}

struct DisclosureTradeRow: View {
    let trade: DisclosureTrade
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: trade.type.icon).foregroundStyle(trade.type.color).frame(width: 36, height: 36).background(trade.type.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(trade.symbol).font(.headline.monospaced()); Text(trade.type.label).font(.caption.weight(.semibold)).foregroundStyle(trade.type.color) }
                Text(trade.assetName).font(.subheadline).lineLimit(1)
                Text("\(trade.transactionDate.formatted(date: .abbreviated, time: .omitted)) · \(trade.amountRange)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.consigliereCard()
    }
}

struct DisclosureMethodologyBanner: View {
    var body: some View {
        Label("politician.methodologyBanner", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
            .font(.caption).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
    }
}
