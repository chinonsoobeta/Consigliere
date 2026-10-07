import SwiftUI

struct ReferencePortfolioView: View {
    @EnvironmentObject private var appState: AppState
    let portfolioID: String
    @State private var portfolio: ReferencePortfolio?
    @State private var changes: [ReferenceChange] = []
    @State private var error: String?
    @State private var ownOnly = false
    @State private var showAll = false
    @State private var showChanges = false
    @State private var groups: [PortfolioGroup] = []

    var body: some View {
        List {
            Section {
                Text("portfolio.estimated").font(.headline)
                NavigationLink("portfolio.method") { MethodologyView() }
                if let asOf = portfolio?.anchorAsOf {
                    Text("portfolio.anchor \(asOf) \(portfolio?.anchorFiledDate ?? "")").font(.caption)
                    if let source = portfolio?.anchorSourceURL { Link("filing.openOriginal", destination: source) }
                } else if let start = portfolio?.historyStart { Text("portfolio.history \(start)").font(.caption) }
                if let frozen = portfolio?.frozenAt { Text("portfolio.frozen \(frozen)").font(.caption) }
                if portfolioID.hasPrefix("member/") { Toggle("portfolio.ownOnly", isOn: $ownOnly) }
                Toggle("portfolio.changes", isOn: $showChanges)
            }
            if portfolioID == "congress" && !groups.isEmpty {
                Section("portfolio.committees") {
                    ForEach(groups.filter { $0.kind == "committee" }) { group in
                        NavigationLink { ReferencePortfolioView(portfolioID: group.id) } label: { Text(verbatim: group.title ?? group.id) }
                    }
                }
            }
            if let error { Text(verbatim: error).foregroundStyle(.orange); Button("common.retry") { Task { await load() } } }
            if let portfolio {
                if showChanges {
                    Section("portfolio.changes") {
                        ForEach(changes) { change in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(LocalizedStringKey(stringLiteral: "portfolio.action.\(change.action)")) + Text(verbatim: " · \(change.ticker.isEmpty ? change.assetName : change.ticker)")
                                Text(verbatim: change.filedDate).font(.caption).foregroundStyle(.secondary)
                                if let note = change.note { Text(verbatim: note).font(.caption) }
                                Link("filing.openOriginal", destination: change.sourceURL)
                            }
                        }
                    }
                } else {
                    let sectors = Dictionary(grouping: portfolio.positions.filter { $0.group == "stocks" && $0.estimate > 0 }, by: { $0.sector ?? String(localized: "portfolio.unknownSector") })
                    if !sectors.isEmpty {
                        Section("portfolio.sectors") {
                            ForEach(sectors.keys.sorted(), id: \.self) { sector in
                                LabeledContent(sector) { Text(sectors[sector]?.count ?? 0, format: .number) }
                            }
                            Text("portfolio.sectorsMethod").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(["stocks", "options", "bonds", "funds", "unmatched"], id: \.self) { group in
                        let positions = portfolio.positions.filter { $0.group == group && $0.estimate > 0 }
                        if !positions.isEmpty {
                            Section(LocalizedStringKey(stringLiteral: "portfolio.group.\(group)")) {
                                ForEach(showAll ? positions : Array(positions.prefix(10))) { position in
                                    ReferencePositionRow(position: position, showsHolders: portfolio.kind != "member")
                                }
                            }
                        }
                    }
                    if portfolio.positions.allSatisfy({ $0.estimate == 0 }) { Text("portfolio.empty") }
                    if !showAll { Button("portfolio.seeAll") { showAll = true } }
                }
            } else { ProgressView("common.loading") }
        }
        .navigationTitle("portfolio.title")
        .task(id: ownOnly) { await load() }
    }

    private func load() async {
        error = nil
        do {
            portfolio = try await appState.loadPortfolio(id: portfolioID, ownOnly: ownOnly)
            changes = try await appState.loadPortfolioChanges(id: portfolioID, ownOnly: ownOnly)
            if portfolioID == "congress" { groups = try await appState.loadPortfolioGroups() }
        } catch { self.error = error.localizedDescription }
    }
}

struct ReferencePositionRow: View {
    let position: ReferencePosition
    var showsHolders = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if position.ticker.isEmpty { Text(verbatim: position.assetName).font(.headline) }
            else { NavigationLink(value: StockRoute(symbol: position.ticker)) { Text(verbatim: position.ticker).font(.headline) } }
            if showsHolders { Text("portfolio.holders \(position.membersHolding)").font(.subheadline) }
            Text("portfolio.midpoint \(position.estimate.formatted(.currency(code: "USD").precision(.fractionLength(0))))").font(.caption.monospacedDigit())
            Text(range).font(.caption.monospacedDigit())
            Text("portfolio.lastActivity \(position.lastActivity)").font(.caption).foregroundStyle(.secondary)
            if let sector = position.sector { Text(verbatim: sector).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var range: String {
        let low = position.low.formatted(.currency(code: "USD").precision(.fractionLength(0)))
        return position.high.map { low + "–" + $0.formatted(.currency(code: "USD").precision(.fractionLength(0))) } ?? String(localized: "portfolio.atLeast") + " " + low
    }
}
