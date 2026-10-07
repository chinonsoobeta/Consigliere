import SwiftUI

struct MembersView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""
    @State private var party = ""
    @State private var chamber: Chamber?

    private var filtersActive: Bool { !party.isEmpty || chamber != nil }

    private var following: [Politician] { appState.followedPoliticians.filter(matches) }
    private var active: [Politician] { appState.politiciansWithDisclosures.filter(matches) }
    private var others: [Politician] {
        appState.politicians
            .filter { appState.disclosureCount(for: $0) == 0 && matches($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var unmatched: [UnmatchedFiler] {
        guard appState.selectedCountry == .us else { return [] }
        return appState.unmatchedFilers.filter { filer in
            (chamber == nil || filer.chamber == chamber?.rawValue)
                && party.isEmpty
                && (query.isEmpty || filer.representative.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            ThemedList {
                Section {
                    Picker("countries.members", selection: $appState.selectedCountry) {
                        ForEach(Country.available) { Text($0.label).tag($0) }
                    }
                    if appState.selectedCountry == .us {
                        NavigationLink { ReferencePortfolioView(portfolioID: "congress") } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "chart.pie.fill")
                                    .font(.title3)
                                    .foregroundStyle(ConsigliereTheme.accent)
                                    .frame(width: 44, height: 44)
                                    .background(ConsigliereTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("portfolio.congress").font(ConsigliereTheme.display(.headline))
                                    Text("portfolio.estimated").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    else { NavigationLink("interests.title") { DeclaredInterestsView(country: appState.selectedCountry) } }
                    if let error = appState.countryLoadError { Text(verbatim: error).font(.caption).foregroundStyle(ConsigliereTheme.warning) }
                }
                if appState.disclosureLoadError != nil {
                    Section {
                        HStack {
                            Label("disclosures.loadError", systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline).foregroundStyle(ConsigliereTheme.warning)
                            Spacer()
                            Button("common.retry") { Task { await appState.load(force: true) } }.buttonStyle(.bordered)
                        }
                    }
                } else if appState.isAwaitingFirstLoad {
                    Section { ProgressView("common.loading").frame(maxWidth: .infinity) }
                }
                if !following.isEmpty {
                    Section(themed: "members.following") { rows(following) }
                }
                if !active.isEmpty {
                    Section { rows(active) } header: { SectionTitle(Text("members.active \(active.count)")) }
                }
                Section { rows(others) } header: {
                    if appState.selectedCountry == .us { SectionTitle(Text("members.others \(others.count)")) }
                    else { SectionTitle(Text("members.all \(others.count)")) }
                } footer: {
                    if appState.selectedCountry == .us { Text("search.rosterSource") }
                    else { Text("interests.method") }
                }
                if !unmatched.isEmpty {
                    Section {
                        ForEach(unmatched) { UnmatchedFilerRow(filer: $0) }
                    } header: {
                        SectionTitle(Text("search.unmatched \(unmatched.count)"))
                    } footer: {
                        Text("search.unmatched.footer")
                    }
                }
            }
            .navigationTitle("tab.members")
            .searchable(text: $query, prompt: "members.prompt")
            .toolbar { filterMenu }
            .refreshable { await appState.load(force: true) }
            .consigliereDestinations()
            .task(id: appState.selectedCountry) { party = ""; chamber = nil; await appState.loadCountry(appState.selectedCountry) }
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
                Text("search.all").tag("")
                ForEach(Array(Set(appState.politicians.filter { $0.nation == appState.selectedCountry }.map(\.party))).sorted(), id: \.self) { Text(verbatim: $0).tag($0) }
            }
            Picker("members.chamber", selection: $chamber) {
                Text("search.all").tag(Chamber?.none)
                ForEach(appState.selectedCountry.chambers, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
        } label: {
            Image(systemName: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .accessibilityLabel(Text("members.filters"))
        }
    }

    private func matches(_ politician: Politician) -> Bool {
        let matchesChamber = chamber == nil || politician.chamber == chamber
        let matchesParty = party.isEmpty || politician.party == party
        guard politician.nation == appState.selectedCountry && matchesChamber && matchesParty else { return false }
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
