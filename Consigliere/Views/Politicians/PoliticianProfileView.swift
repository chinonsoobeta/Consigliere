import Charts
import SwiftUI

struct PoliticianProfileView: View {
    @EnvironmentObject private var appState: AppState
    let politician: Politician

    private var trades: [DisclosureTrade] { appState.disclosures(for: politician) }
    private var coverage: [DisclosureCoverageYear] { appState.coverage(for: politician) }
    private var portfolio: PoliticianModelPortfolio? { appState.modelPortfolio(for: politician) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                profileHeader
                DisclosureMethodologyBanner()
                coverageSection
                modelPortfolioSection
                tradesSection
                DisclaimerBanner()
            }.padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(politician.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: DisclosureTrade.self) { TradeEventStudyView(trade: $0, politician: politician) }
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
            Text("politician.coverage").font(.title3.bold())
            Text("politician.coverage.subtitle").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(coverage) { year in
                        VStack(spacing: 7) {
                            Text(String(year.year)).font(.caption.weight(.semibold))
                            Image(systemName: year.status.icon).foregroundStyle(year.status.color)
                            Text(year.status.label).font(.caption2).multilineTextAlignment(.center).lineLimit(2).frame(width: 74)
                        }
                        .padding(10).frame(height: 94)
                        .background(year.status.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                    }
                }
            }
        }.consigliereCard()
    }

    @ViewBuilder private var modelPortfolioSection: some View {
        if let portfolio {
            NavigationLink { PoliticianModelPortfolioView(politician: politician, portfolio: portfolio) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Label("model.title", systemImage: "chart.pie.fill").font(.headline); Spacer(); Image(systemName: "chevron.right") }
                    Text("model.profileDescription").font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        metric(portfolio.positions.count.formatted(), "model.positions")
                        Divider().frame(height: 32)
                        metric(portfolio.asOfDate.formatted(date: .abbreviated, time: .omitted), "model.asOf")
                    }
                }.foregroundStyle(.primary).consigliereCard()
            }.buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                Label("model.title", systemImage: "chart.pie").font(.headline)
                Text("model.unavailable").font(.subheadline).foregroundStyle(.secondary)
            }.consigliereCard()
        }
    }

    private func metric(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading) { Text(value).font(.headline); Text(label).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tradesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("politician.disclosures").font(.title3.bold())
            if trades.isEmpty {
                ContentUnavailableView("politician.noTrades", systemImage: "doc.text.magnifyingglass", description: Text("politician.noTrades.body"))
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
