import SwiftUI

struct PoliticianProfileView: View {
    @EnvironmentObject private var appState: AppState
    let politician: Politician

    private var trades: [DisclosureTrade] { appState.disclosures(for: politician) }
    private var stats: TradingStats? { appState.stats(for: politician) }
    private var coverage: DisclosureCoverageSummary? { appState.coverage(for: politician) }
    private var pendingFilings: [PendingFiling] { appState.pendingFilings(for: politician) }

    var body: some View {
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
        .task { await appState.loadDisclosures(for: politician) }
        .refreshable { await appState.loadDisclosures(for: politician) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                PoliticianAvatar(politician: politician, size: 76)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: politician.name).font(.title2.bold())
                    HStack(spacing: 6) {
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
            Grid(horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    StatTile(label: "profile.stat.lastYear") { Text(stats.lastYear, format: .number) }
                    StatTile(label: "profile.stat.buySell") { Text(verbatim: "\(stats.buys) / \(stats.sells)") }
                }
                GridRow {
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
                    HStack(spacing: 6) {
                        ForEach(stats.topSymbols, id: \.self) { symbol in
                            Text(verbatim: symbol).font(.caption.monospaced().weight(.bold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
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
