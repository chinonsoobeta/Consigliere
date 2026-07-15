import SwiftUI

struct InstrumentSearchView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""
    @State private var selectedKind: InstrumentKind?
    @State private var selectedChamber: Chamber?
    @State private var selectedParty = PartyFilter.all
    @State private var scope = SearchScope.politicians

    enum SearchScope: String, CaseIterable, Identifiable {
        case politicians, markets
        var id: String { rawValue }
        var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "search.\(rawValue)") }
    }

    enum PartyFilter: String, CaseIterable, Identifiable {
        case all, democratic, republican
        var id: String { rawValue }
        var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "party.\(rawValue)") }
        var color: Color {
            switch self {
            case .all: ConsigliereTheme.navy
            case .democratic: .blue
            case .republican: .red
            }
        }
    }

    private var results: [MarketInstrument] {
        appState.instruments.filter { instrument in
            let matchesKind = selectedKind == nil || instrument.kind == selectedKind
            let terms = [instrument.symbol, instrument.name, instrument.exchange] + instrument.aliases
            let matchesQuery = query.isEmpty || terms.contains { $0.localizedCaseInsensitiveContains(query) }
            return matchesKind && matchesQuery
        }
    }

    private var politicianResults: [Politician] {
        appState.politicians.filter { politician in
            let matchesChamber = selectedChamber == nil || politician.chamber == selectedChamber
            let matchesParty = switch selectedParty {
            case .all: true
            case .democratic: politician.party.localizedCaseInsensitiveContains("Democrat")
            case .republican: politician.party.localizedCaseInsensitiveContains("Republican")
            }
            let terms = [politician.name, politician.state, politician.party, politician.partyAbbreviation]
            let matchesQuery = query.isEmpty || terms.contains { $0.localizedCaseInsensitiveContains(query) }
            return matchesChamber && matchesParty && matchesQuery
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("search.mode", selection: $scope) {
                        ForEach(SearchScope.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                }
                if scope == .markets {
                    Section { kindFilters.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                    Section {
                        ForEach(results) { instrument in
                            NavigationLink(value: instrument) { resultRow(instrument) }
                        }
                    } header: { Text("search.results \(results.count)") }
                } else {
                    if appState.disclosureLoadError != nil {
                        Section { disclosureErrorView }
                    }
                    Section { partyFilters.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                    Section { chamberFilters.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                    Section {
                        ForEach(politicianResults) { politician in
                            NavigationLink(value: politician) { politicianRow(politician) }
                        }
                    } header: { Text("search.politicianResults \(politicianResults.count)") }
                    footer: { Text("search.rosterSource") }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("search.title")
            .searchable(text: $query, prompt: scope == .markets ? "search.prompt" : "search.politicianPrompt")
            .navigationDestination(for: MarketInstrument.self) { InstrumentDetailView(instrument: $0) }
            .navigationDestination(for: Politician.self) { PoliticianProfileView(politician: $0) }
            .refreshable { await appState.load(force: true) }
        }
    }

    private var disclosureErrorView: some View {
        HStack {
            Label("disclosures.loadError", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline).foregroundStyle(.orange)
            Spacer()
            Button("common.retry") { Task { await appState.load(force: true) } }
                .buttonStyle(.bordered)
        }
    }

    private var partyFilters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("search.party").font(.headline).padding(.horizontal)
            HStack {
                ForEach(PartyFilter.allCases) { party in
                    Button { selectedParty = party } label: {
                        Text(party.label)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(selectedParty == party ? Color.white : party.color)
                            .background(selectedParty == party ? party.color : party.color.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private var chamberFilters: some View {
        HStack {
            chamberButton("search.all", chamber: nil)
            chamberButton("chamber.house", chamber: .house)
            chamberButton("chamber.senate", chamber: .senate)
        }.padding(.horizontal)
    }

    private func chamberButton(_ title: LocalizedStringKey, chamber: Chamber?) -> some View {
        Button { selectedChamber = chamber } label: {
            Text(title).font(.caption.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(selectedChamber == chamber ? Color.white : Color.primary)
                .background(selectedChamber == chamber ? ConsigliereTheme.navy : Color.secondary.opacity(0.12), in: Capsule())
        }.buttonStyle(.plain)
    }

    private var kindFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                filterButton("search.all", kind: nil)
                ForEach(InstrumentKind.allCases, id: \.self) { kind in filterButton(kind.label, kind: kind) }
            }.padding(.horizontal)
        }
    }

    private func filterButton(_ title: LocalizedStringKey, kind: InstrumentKind?) -> some View {
        Button { selectedKind = kind } label: {
            Text(title).font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(selectedKind == kind ? Color.white : Color.primary)
                .background(selectedKind == kind ? ConsigliereTheme.navy : Color.secondary.opacity(0.12), in: Capsule())
        }.buttonStyle(.plain)
    }

    private func resultRow(_ instrument: MarketInstrument) -> some View {
        HStack(spacing: 12) {
            Image(systemName: instrument.kind.icon).foregroundStyle(ConsigliereTheme.gold).frame(width: 32, height: 32).background(ConsigliereTheme.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                HStack { Text(instrument.symbol).font(.headline.monospaced()); FreshnessBadge(freshness: instrument.freshness) }
                Text(instrument.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text("\(instrument.exchange) · \(instrument.currency)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) { Text(instrument.formattedPrice).font(.subheadline.weight(.semibold)); ChangeLabel(value: instrument.changePercent) }
        }.padding(.vertical, 5)
    }

    private func politicianRow(_ politician: Politician) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: politician.imageURL) { image in image.resizable().scaledToFill() } placeholder: {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
            }
            .frame(width: 48, height: 48).clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(politician.name).font(.headline)
                HStack(spacing: 5) {
                    Text(politician.partyAbbreviation)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(politician.partyAbbreviation == "R" ? Color.red : (politician.partyAbbreviation == "D" ? Color.blue : Color.secondary))
                    Text("· \(politician.jurisdiction)").font(.subheadline).foregroundStyle(.secondary)
                }
                Label(politician.chamber.label, systemImage: politician.chamber.icon).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            let tradeCount = appState.disclosures(for: politician).count
            VStack(alignment: .trailing) {
                Text(tradeCount.formatted()).font(.headline.monospacedDigit())
                Text("search.disclosures").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}
