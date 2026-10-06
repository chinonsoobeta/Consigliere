import SwiftUI

struct MembersView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""
    @State private var party = PartyFilter.all
    @State private var chamber: Chamber?

    enum PartyFilter: String, CaseIterable, Identifiable {
        case all, democratic, republican
        var id: String { rawValue }
        var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "party.\(rawValue)") }
    }

    private var filtersActive: Bool { party != .all || chamber != nil }

    private var following: [Politician] { appState.followedPoliticians.filter(matches) }
    private var active: [Politician] { appState.politiciansWithDisclosures.filter(matches) }
    private var others: [Politician] {
        appState.politicians
            .filter { appState.disclosureCount(for: $0) == 0 && matches($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var unmatched: [UnmatchedFiler] {
        appState.unmatchedFilers.filter { filer in
            (chamber == nil || filer.chamber == chamber?.rawValue)
                && party == .all
                && (query.isEmpty || filer.representative.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if appState.disclosureLoadError != nil {
                    Section {
                        HStack {
                            Label("disclosures.loadError", systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline).foregroundStyle(.orange)
                            Spacer()
                            Button("common.retry") { Task { await appState.load(force: true) } }.buttonStyle(.bordered)
                        }
                    }
                } else if appState.isAwaitingFirstLoad {
                    Section { ProgressView("common.loading").frame(maxWidth: .infinity) }
                }
                if !following.isEmpty {
                    Section("members.following") { rows(following) }
                }
                if !active.isEmpty {
                    Section { rows(active) } header: { Text("members.active \(active.count)") }
                }
                Section { rows(others) } header: {
                    Text("members.others \(others.count)")
                } footer: {
                    Text("search.rosterSource")
                }
                if !unmatched.isEmpty {
                    Section {
                        ForEach(unmatched) { UnmatchedFilerRow(filer: $0) }
                    } header: {
                        Text("search.unmatched \(unmatched.count)")
                    } footer: {
                        Text("search.unmatched.footer")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("tab.members")
            .searchable(text: $query, prompt: "members.prompt")
            .toolbar { filterMenu }
            .refreshable { await appState.load(force: true) }
            .consigliereDestinations()
        }
    }

    private func rows(_ politicians: [Politician]) -> some View {
        ForEach(politicians) { politician in
            NavigationLink(value: politician) {
                MemberRow(politician: politician, trades: appState.disclosureCount(for: politician))
            }
            .swipeActions {
                Button {
                    appState.toggleFollow(politician)
                } label: {
                    appState.isFollowing(politician)
                        ? Label("profile.unfollow", systemImage: "star.slash")
                        : Label("profile.follow", systemImage: "star")
                }
                .tint(ConsigliereTheme.accent)
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("search.party", selection: $party) {
                ForEach(PartyFilter.allCases) { Text($0.label).tag($0) }
            }
            Picker("members.chamber", selection: $chamber) {
                Text("search.all").tag(Chamber?.none)
                Text("chamber.house").tag(Chamber?.some(.house))
                Text("chamber.senate").tag(Chamber?.some(.senate))
            }
        } label: {
            Image(systemName: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .accessibilityLabel(Text("members.filters"))
        }
    }

    private func matches(_ politician: Politician) -> Bool {
        let matchesChamber = chamber == nil || politician.chamber == chamber
        let matchesParty = switch party {
        case .all: true
        case .democratic: politician.partyAbbreviation == "D"
        case .republican: politician.partyAbbreviation == "R"
        }
        guard matchesChamber && matchesParty else { return false }
        guard !query.isEmpty else { return true }
        let tickers = appState.disclosures(for: politician).flatMap { [$0.symbol, $0.assetName] }
        let terms = [politician.name, politician.state, politician.shortLabel] + tickers
        return terms.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct MemberRow: View {
    let politician: Politician
    let trades: Int

    var body: some View {
        HStack(spacing: 12) {
            MemberHeaderRow(politician: politician, avatarSize: 44)
            Spacer()
            if trades > 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(trades, format: .number).font(.headline.monospacedDigit())
                    Text("members.trades").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct UnmatchedFilerRow: View {
    let filer: UnmatchedFiler

    var body: some View {
        HStack(spacing: 12) {
            PoliticianAvatar(politician: nil, fallbackName: filer.representative, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: filer.representative).font(.headline)
                if let latest = filer.latest.flatMap(DisclosureDates.day) {
                    Text("search.unmatched.latest \(latest, format: DisclosureDates.style())")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(filer.records, format: .number).font(.headline.monospacedDigit())
                Text("members.trades").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
