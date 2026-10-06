import SwiftUI

/// The landing page: what was filed recently, what stands out, and who is trading.
struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selectedTab: RootTab

    private static let filingLimit = 6
    private static let sectionLimit = 5

    private var followedFilings: [TradeFiling] {
        let ids = appState.followedIDs
        return Array(appState.latestFilings.filter { $0.politicianID.map(ids.contains) ?? false }.prefix(3))
    }

    /// Filings already shown under Following are not repeated.
    private var newFilings: [TradeFiling] {
        let shown = Set(followedFilings.map(\.id))
        return Array(appState.latestFilings.filter { !shown.contains($0.id) }.prefix(Self.filingLimit))
    }

    private var biggestTrades: [DisclosureTrade] {
        Array(appState.latestTrades.sorted { $0.amount.sortValue > $1.amount.sortValue }.prefix(Self.sectionLimit))
    }

    /// One row per member, so a batch of late reports filed the same day does not crowd the list.
    private var lateFilings: [TradeFiling] {
        var seen = Set<String>()
        return Array(appState.latestFilings
            .filter { $0.isLate && seen.insert($0.politicianID ?? $0.representative).inserted }
            .prefix(Self.sectionLimit))
    }

    var body: some View {
        NavigationStack {
            List {
                if appState.latestFilings.isEmpty {
                    Section {
                        SourceAwareEmptyView(
                            providers: AppState.disclosureProviders,
                            emptyTitle: "home.empty",
                            emptyMessage: "home.empty.body"
                        )
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } else {
                    if !followedFilings.isEmpty { followingSection }
                    newFilingsSection
                    biggestSection
                    if !appState.mostActive.isEmpty { mostActiveSection }
                    if !lateFilings.isEmpty { lateSection }
                    if !appState.posts.isEmpty { postsSection }
                    if appState.marketsEnabled && !appState.instruments.isEmpty { marketsSection }
                }
                footer
            }
            .listStyle(.insetGrouped)
            .navigationTitle("home.title")
            .refreshable { await appState.load(force: true) }
            .consigliereDestinations()
        }
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 3) {
            let newCount = appState.newFilingsSinceLastVisit.count
            if newCount > 0 {
                Text("home.newSinceVisit \(newCount)").foregroundStyle(ConsigliereTheme.accent).fontWeight(.semibold)
            }
            if appState.disclosureSourcesDelayed {
                NavigationLink { DataSourcesView() } label: {
                    Label("home.delayed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } else if let lastSync = appState.lastDisclosureSync {
                Text("home.checked \(lastSync, format: .relative(presentation: .named))")
            }
        }
        .font(.footnote)
        .textCase(nil)
    }

    private var followingSection: some View {
        Section {
            ForEach(followedFilings) { filing in
                NavigationLink(value: filing) { FilingRow(filing: filing) }
            }
        } header: {
            VStack(alignment: .leading, spacing: 6) {
                statusLine
                Text("home.following")
            }
        }
    }

    private var newFilingsSection: some View {
        Section {
            ForEach(newFilings) { filing in
                NavigationLink(value: filing) { FilingRow(filing: filing) }
            }
            Button("home.seeAllTrades") { selectedTab = .trades }
        } header: {
            // The status line heads whichever section comes first.
            VStack(alignment: .leading, spacing: 6) {
                if followedFilings.isEmpty { statusLine }
                Text("home.newFilings")
            }
        }
    }

    private var biggestSection: some View {
        Section {
            ForEach(biggestTrades) { trade in
                NavigationLink(value: trade) { TradeRow(trade: trade) }
            }
        } header: {
            Text("home.biggest")
        } footer: {
            Text("home.biggest.footer")
        }
    }

    private var mostActiveSection: some View {
        Section("home.mostActive") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(appState.mostActive.prefix(12), id: \.politician.id) { entry in
                        NavigationLink(value: entry.politician) {
                            ActiveMemberChip(politician: entry.politician, trades: entry.trades)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .listRowInsets(EdgeInsets())
        }
    }

    private var lateSection: some View {
        Section {
            ForEach(lateFilings) { filing in
                NavigationLink(value: filing) { FilingRow(filing: filing, emphasizesLag: true) }
            }
        } header: {
            Text("home.late")
        } footer: {
            Text("home.late.footer")
        }
    }

    private var postsSection: some View {
        Section("home.posts") {
            ForEach(appState.posts.prefix(3)) { post in
                NavigationLink(value: post) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: post.author).font(.subheadline.weight(.semibold))
                        Text(verbatim: post.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        EventDateText(event: post).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var marketsSection: some View {
        Section("home.markets") {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(appState.instruments.prefix(8)) { instrument in
                        NavigationLink(value: instrument) { MarketCard(instrument: instrument) }.buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
            .listRowInsets(EdgeInsets())
        }
    }

    private var footer: some View {
        Section {
            NavigationLink("home.aboutData") { MethodologyView() }
        } footer: {
            Text("home.footer")
        }
    }
}

private struct ActiveMemberChip: View {
    let politician: Politician
    let trades: Int

    var body: some View {
        VStack(spacing: 5) {
            PoliticianAvatar(politician: politician, size: 56)
            Text(verbatim: politician.name.split(separator: " ").last.map(String.init) ?? politician.name)
                .font(.caption.weight(.semibold)).lineLimit(1)
            Text(trades, format: .number).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(width: 68)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("home.mostActive.a11y \(politician.name) \(trades)"))
    }
}
