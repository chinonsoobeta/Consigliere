import SwiftUI

/// One periodic transaction report and every trade it lists.
struct FilingDetailView: View {
    @EnvironmentObject private var appState: AppState
    let filing: TradeFiling

    private var politician: Politician? { appState.politician(id: filing.politicianID) }

    var body: some View {
        List {
            Section {
                if let politician {
                    NavigationLink(value: politician) { MemberHeaderRow(politician: politician) }
                } else {
                    Text(verbatim: filing.representative).font(.headline)
                }
            }
            Section {
                LabeledContent("event.filed") { Text(filing.filedDate, format: DisclosureDates.style(.long)) }
                LabeledContent("filing.tradeCount") { Text(filing.trades.count, format: .number) }
                if filing.isLate {
                    LabeledContent("filing.longestLag") {
                        Text("study.days \(filing.maxLagDays)").foregroundStyle(.orange)
                    }
                }
                Link(destination: filing.sourceURL) { Label("filing.openOriginal", systemImage: "doc.richtext") }
            } footer: {
                if filing.isLate { Text("trade.late.footer") }
            }
            Section {
                ForEach(Array(Set(filing.trades.map(\.symbol).filter { !$0.isEmpty })).sorted(), id: \.self) { symbol in
                    NavigationLink(value: StockRoute(symbol: symbol)) { Text("stock.open \(symbol)") }
                }
            }
            Section("filing.trades") {
                ForEach(filing.bySize) { trade in
                    NavigationLink(value: trade) { TradeRow(trade: trade, showsMember: false) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("filing.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: filing.sourceURL)
        }
    }
}

struct MemberHeaderRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let politician: Politician
    var avatarSize: CGFloat = 48

    var body: some View {
        HStack(spacing: 12) {
            PoliticianAvatar(politician: politician, size: avatarSize)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: politician.name).font(.headline)
                let metadataLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                    : AnyLayout(HStackLayout(spacing: 6))
                metadataLayout {
                    Text(verbatim: politician.shortLabel).font(.caption.weight(.semibold)).foregroundStyle(politician.partyColor)
                    ChamberTag(chamber: politician.chamber)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
