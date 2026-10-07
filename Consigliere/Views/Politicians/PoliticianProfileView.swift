import SwiftUI

struct PoliticianProfileView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let politician: Politician
    @State private var referencePortfolio: ReferencePortfolio?

    private var trades: [DisclosureTrade] { appState.disclosures(for: politician) }
    private var stats: TradingStats? { appState.stats(for: politician) }
    private var coverage: DisclosureCoverageSummary? { appState.coverage(for: politician) }
    private var pendingFilings: [PendingFiling] { appState.pendingFilings(for: politician) }

    var body: some View {
        if politician.nation != .us { DeclaredInterestsView(country: politician.nation, member: politician) } else { usProfile }
    }

    private var usProfile: some View {
        List {
            Section { header }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
            if appState.disclosureLoadError != nil {
                Section {
                    HStack {
                        Label("disclosures.loadError", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline).foregroundStyle(.orange)
                        Spacer()
                        Button("common.retry") { Task { await appState.loadDisclosures(for: politician) } }
                            .buttonStyle(.bordered)
                    }
                }
            }
            if let stats { statsSection(stats) }
            if !trades.isEmpty && !appState.loadingPoliticianIDs.contains(politician.id) && appState.disclosureLoadError == nil { MemberFilingCharts(trades: trades) }
            Section {
                if let referencePortfolio {
                    ForEach(Array(referencePortfolio.positions.filter { $0.estimate > 0 }.prefix(10))) { position in
                        ReferencePositionRow(position: position)
                    }
                    if referencePortfolio.positions.allSatisfy({ $0.estimate == 0 }) { Text("portfolio.empty") }
                } else { Text("portfolio.unavailable") }
                NavigationLink("portfolio.seeAll") { ReferencePortfolioView(portfolioID: "member/" + politician.id) }
                NavigationLink("portfolio.method") { MethodologyView() }
            } header: { Text("portfolio.member") } footer: { Text("portfolio.estimated") }
            if !pendingFilings.isEmpty {
                Section {
                    ForEach(pendingFilings) { PendingFilingRow(filing: $0) }
                } header: {
                    Text("pending.title \(pendingFilings.count)")
                } footer: {
                    Text("pending.subtitle")
                }
            }
            tradesSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(verbatim: politician.name))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        async let history: Void = appState.loadDisclosures(for: politician)
        referencePortfolio = try? await appState.loadPortfolio(id: "member/" + politician.id, ownOnly: false)
        await history
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                PoliticianAvatar(politician: politician, size: 76)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: politician.name).font(.title2.bold())
                    let metadataLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        : AnyLayout(HStackLayout(spacing: 6))
                    metadataLayout {
                        Text(verbatim: politician.shortLabel).font(.subheadline.weight(.semibold)).foregroundStyle(politician.partyColor)
                        ChamberTag(chamber: politician.chamber)
                    }
                    (Text(verbatim: "\(politician.party) · ") + politician.jurisdiction)
                        .font(.caption).foregroundStyle(.secondary)
                    Text("politician.servingSince \(String(politician.serviceStart))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            followButton
        }
    }

    @ViewBuilder
    private var followButton: some View {
        let following = appState.isFollowing(politician)
        Button {
            appState.toggleFollow(politician)
        } label: {
            Label(following ? "profile.following" : "profile.follow", systemImage: following ? "checkmark" : "plus")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(following ? .secondary : ConsigliereTheme.accent)
        .controlSize(.large)
    }

    private func statsSection(_ stats: TradingStats) -> some View {
        Section {
            let statLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            VStack(alignment: .leading, spacing: 14) {
                statLayout {
                    StatTile(label: "profile.stat.lastYear") { Text(stats.lastYear, format: .number) }
                    StatTile(label: "profile.stat.buySell") { Text(verbatim: "\(stats.buys) / \(stats.sells)") }
                }
                statLayout {
                    StatTile(label: "profile.stat.medianLag") {
                        if let lag = stats.medianLagDays { Text("study.days \(lag)") } else { Text(verbatim: "—") }
                    }
                    StatTile(label: "profile.stat.late") {
                        Text(stats.lateCount, format: .number).foregroundStyle(stats.lateCount > 0 ? .orange : .primary)
                    }
                }
            }
            .padding(.vertical, 4)
            if !stats.topSymbols.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("profile.topTickers").font(.caption).foregroundStyle(.secondary)
                    let tickerLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        : AnyLayout(HStackLayout(spacing: 6))
                    tickerLayout {
                        ForEach(stats.topSymbols, id: \.self) { symbol in
                            NavigationLink(value: StockRoute(symbol: symbol)) {
                                Text(verbatim: symbol).font(.caption.monospaced().weight(.bold))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        } header: {
            Text("profile.atAGlance")
        } footer: {
            coverageFooter
        }
    }

    @ViewBuilder
    private var coverageFooter: some View {
        if let coverage,
           let earliest = coverage.earliest.flatMap(DisclosureDates.day),
           let latest = coverage.latest.flatMap(DisclosureDates.day) {
            Text("profile.coverage \(coverage.records) \(earliest, format: DisclosureDates.style()) \(latest, format: DisclosureDates.style())")
        }
    }

    private var tradesSection: some View {
        Section("politician.disclosures") {
            if trades.isEmpty {
                if appState.loadingPoliticianIDs.contains(politician.id) {
                    ProgressView("politician.loading").frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView(
                        "politician.noTrades",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("politician.noTrades.body")
                    )
                }
            } else {
                ForEach(trades) { trade in
                    NavigationLink(value: trade) { TradeRow(trade: trade, showsMember: false) }
                }
            }
        }
    }
}

private struct StatTile<Value: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            value.font(.title3.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
