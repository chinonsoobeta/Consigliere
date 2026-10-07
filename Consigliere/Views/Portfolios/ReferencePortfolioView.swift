import Charts
import SwiftUI

struct ReferencePortfolioView: View {
    private enum Mode: Hashable { case holdings, changes }

    @EnvironmentObject private var appState: AppState
    let portfolioID: String
    var title: String? = nil
    @State private var portfolio: ReferencePortfolio?
    @State private var changes: [ReferenceChange] = []
    @State private var error: String?
    @State private var ownOnly = false
    @State private var expandedGroups: Set<String> = []
    @State private var mode = Mode.holdings
    @State private var groups: [PortfolioGroup] = []

    private var isAggregate: Bool { !portfolioID.hasPrefix("member/") }

    var body: some View {
        ThemedList {
            Section {
                Picker("portfolio.view", selection: $mode) {
                    Text("portfolio.holdings").tag(Mode.holdings)
                    Text("portfolio.changes").tag(Mode.changes)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let error {
                Section {
                    Text(verbatim: error).foregroundStyle(ConsigliereTheme.warning)
                    Button("common.retry") { Task { await load() } }
                }
            }
            if let portfolio {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(isAggregate ? "portfolio.aggregate.summary" : "portfolio.member.summary").font(.subheadline)
                        provenance(portfolio).font(.caption).foregroundStyle(.secondary)
                    }
                    if !isAggregate { Toggle("portfolio.ownOnly", isOn: $ownOnly) }
                    NavigationLink("portfolio.method") { MethodologyView() }
                }
                switch mode {
                case .holdings: holdings(portfolio)
                case .changes: changeList
                }
                if portfolioID == "congress" && !committees.isEmpty {
                    Section {
                        NavigationLink {
                            CommitteePortfolioList(groups: committees)
                        } label: {
                            LabeledContent("portfolio.committees") { Text(committees.count, format: .number) }
                        }
                    } footer: { Text("portfolio.committees.footer") }
                }
            } else if error == nil {
                ProgressView("common.loading").frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(title.map { Text(verbatim: $0) } ?? Text(portfolioID == "congress" ? "portfolio.congress" : "portfolio.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ownOnly) { await load() }
    }

    /// Full committees only; subcommittee portfolios are reachable from their parent's list.
    private var committees: [PortfolioGroup] {
        groups.filter { $0.kind == "committee" && $0.id.count == "committee/".count + 4 }
            .sorted { ($0.title ?? $0.id) < ($1.title ?? $1.id) }
    }

    @ViewBuilder private func provenance(_ portfolio: ReferencePortfolio) -> some View {
        if let asOf = portfolio.anchorAsOf.flatMap(DisclosureDates.day) {
            Text("portfolio.anchoredAt \(asOf.formatted(DisclosureDates.style()))")
        } else if let start = portfolio.historyStart.flatMap(DisclosureDates.day) {
            Text("portfolio.history \(start.formatted(DisclosureDates.style()))")
        }
        if let frozen = portfolio.frozenAt.flatMap(DisclosureDates.day) {
            Text("portfolio.frozen \(frozen.formatted(DisclosureDates.style()))")
        }
        if let source = portfolio.anchorSourceURL { Link("portfolio.anchorSource", destination: source).font(.caption) }
    }

    @ViewBuilder private func holdings(_ portfolio: ReferencePortfolio) -> some View {
        let held = portfolio.positions.filter { $0.estimate > 0 }
        if held.isEmpty {
            Section { Text("portfolio.empty").foregroundStyle(.secondary) }
        }
        ForEach(["stocks", "options", "funds", "bonds", "unmatched"], id: \.self) { group in
            let positions = held.filter { $0.group == group }
            if !positions.isEmpty {
                Section {
                    let expanded = expandedGroups.contains(group)
                    ForEach(expanded ? positions : Array(positions.prefix(group == "stocks" ? 15 : 5))) { position in
                        ReferencePositionRow(position: position, showsHolders: isAggregate)
                    }
                    if positions.count > (group == "stocks" ? 15 : 5) && !expanded {
                        Button("portfolio.showAll \(positions.count)") { expandedGroups.insert(group) }
                    }
                } header: {
                    SectionTitle(LocalizedStringKey(stringLiteral: "portfolio.group.\(group)"))
                }
            }
        }
        sectorSection(held.filter { $0.group == "stocks" })
    }

    @ViewBuilder private func sectorSection(_ stocks: [ReferencePosition]) -> some View {
        let known = stocks.filter { $0.sector != nil }
        // Sector coverage fills in over several syncs; a mostly unclassified chart would mislead.
        if !stocks.isEmpty && Double(known.count) / Double(stocks.count) >= 0.5 {
            let counts = Dictionary(grouping: known, by: { $0.sector! }).map { (sector: $0.key, count: $0.value.count) }.sorted { $0.count > $1.count }
            Section {
                Chart(counts, id: \.sector) { item in
                    BarMark(x: .value("Positions", item.count), y: .value("Sector", item.sector))
                        .foregroundStyle(ConsigliereTheme.accent)
                        .annotation(position: .trailing) { Text(item.count, format: .number).font(.caption2).foregroundStyle(.secondary) }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(counts.count) * 26 + 10)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            } header: { SectionTitle("portfolio.sectors") } footer: {
                Text("portfolio.sectorsCoverage \(known.count) \(stocks.count)")
            }
        }
    }

    @ViewBuilder private var changeList: some View {
        Section {
            if changes.isEmpty { Text("portfolio.noChanges").foregroundStyle(.secondary) }
            ForEach(changes) { change in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LocalizedStringKey(stringLiteral: "portfolio.action.\(change.action)"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(change.action == "added" || change.action == "increased" ? ConsigliereTheme.positive
                                : change.action == "trimmed" || change.action == "exited" ? ConsigliereTheme.negative : .secondary)
                        if change.ticker.isEmpty {
                            Text(verbatim: change.assetName).font(.subheadline).lineLimit(2)
                        } else {
                            NavigationLink(value: StockRoute(symbol: change.ticker)) {
                                SecurityLabel(symbol: change.ticker, name: change.assetName)
                            }
                        }
                        if let note = change.note { Text(verbatim: note).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        if let filed = DisclosureDates.day(change.filedDate) {
                            Text(filed, format: DisclosureDates.compact(filed)).font(.caption).foregroundStyle(.secondary)
                        }
                        Link(destination: change.sourceURL) { Image(systemName: "doc.text") }
                            .accessibilityLabel(Text("filing.openOriginal"))
                    }
                }
            }
        } footer: { Text("portfolio.changes.footer") }
    }

    private func load() async {
        error = nil
        do {
            async let loadedPortfolio = appState.loadPortfolio(id: portfolioID, ownOnly: ownOnly)
            async let loadedChanges = appState.loadPortfolioChanges(id: portfolioID, ownOnly: ownOnly)
            portfolio = try await loadedPortfolio
            changes = try await loadedChanges
            if portfolioID == "congress" { groups = (try? await appState.loadPortfolioGroups()) ?? [] }
        } catch ConsigliereAPIClient.ClientError.serverStatus(404) {
            // The server builds portfolios on its 12-hourly sync, so a fresh deploy has none yet.
            self.error = String(localized: "portfolio.notBuilt")
        } catch { self.error = error.localizedDescription }
    }
}

private struct CommitteePortfolioList: View {
    let groups: [PortfolioGroup]

    var body: some View {
        ThemedList {
            Section {
                ForEach(groups) { group in
                    NavigationLink(group.title ?? group.id) {
                        ReferencePortfolioView(portfolioID: group.id, title: group.title)
                    }
                }
            } footer: { Text("portfolio.committees.footer") }
        }
        .navigationTitle("portfolio.committees")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ReferencePositionRow: View {
    let position: ReferencePosition
    var showsHolders = false

    var body: some View {
        HStack(alignment: .center) {
            if position.ticker.isEmpty {
                Text(verbatim: position.assetName).font(.subheadline).lineLimit(2)
                Spacer()
                trailing
            } else {
                NavigationLink(value: StockRoute(symbol: position.ticker)) {
                    HStack {
                        SecurityLabel(symbol: position.ticker, name: position.assetName)
                        Spacer()
                        trailing
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var trailing: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if showsHolders {
                Text("portfolio.memberCount \(position.membersHolding)").font(.subheadline.monospacedDigit())
            } else {
                Text(verbatim: range).font(.subheadline.monospacedDigit())
            }
            if let last = DisclosureDates.day(position.lastActivity) {
                Text(last, format: DisclosureDates.compact(last)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// The reconstructed band, never a single dollar figure: the midpoint implies precision we do not have.
    private var range: String {
        let low = Self.compact(position.low)
        return position.high.map { low + "–" + Self.compact($0) } ?? String(localized: "portfolio.atLeast") + " " + low
    }

    /// "$15K", "$1.5M": band edges are round numbers, so three significant digits lose nothing.
    static func compact(_ value: Double) -> String {
        let (scaled, suffix): (Double, String) = value >= 1_000_000_000 ? (value / 1_000_000_000, "B")
            : value >= 1_000_000 ? (value / 1_000_000, "M") : value >= 1_000 ? (value / 1_000, "K") : (value, "")
        return "$" + scaled.formatted(.number.precision(.significantDigits(1...3))) + suffix
    }
}
