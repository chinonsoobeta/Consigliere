import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selectedTab: RootTab
    @AppStorage("notableWeek") private var storedWeek = ""
    @AppStorage("notableMember") private var storedMember = ""
    @AppStorage("previousNotableMember") private var previousMember = ""
    @State private var notable: DisclosureTrade?

    private var summary: HomeSummary { HomeSummary(trades: appState.latestTrades, previousVisit: appState.previousVisit, followed: appState.followedIDs) }
    private var followedFilings: [TradeFiling] { Array(appState.latestFilings.filter { appState.followedIDs.contains($0.politicianID ?? "") }.prefix(5)) }
    private var pulse: [WeeklyBucket] { TradeAnalytics.weeklyPulse(appState.latestTrades) }
    private var visitFilter: TradeFilter { TradeFilter(filedWithinDays: appState.previousVisit == nil ? 7 : nil, observedAfter: appState.previousVisit) }

    var body: some View {
        NavigationStack {
            List {
                if appState.disclosureSourcesDelayed {
                    NavigationLink { DataSourcesView() } label: { Label("home.delayed", systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange) }
                }
                if let error = appState.latestLoadError ?? appState.disclosureLoadError {
                    Text(verbatim: error).foregroundStyle(.orange)
                }
                if appState.homeCountries.contains(.us) {
                summarySection
                followingSection
                if let notable {
                    Section("home.notableWeek") {
                        NavigationLink(value: notable) { TradeRow(trade: notable) }
                        ViewThatFits(in: .horizontal) {
                            HStack { notableReasons(notable) }
                            VStack(alignment: .leading) { notableReasons(notable) }
                        }.font(.caption)
                    }
                }
                Section("home.pulse") {
                    FilingCharts.weekly(pulse, locale: appState.language.locale)
                    if TradeAnalytics.busierThanUsual(pulse) { Text("home.busier").font(.caption).foregroundStyle(ConsigliereTheme.accent) }
                    Button("home.seeAllTrades") { open(TradeFilter(filedWithinDays: 84)) }
                }
                Section("home.newFilings") {
                    ForEach(appState.latestFilings.filter { !Set(followedFilings.map(\.id)).contains($0.id) }.prefix(5)) { filing in
                        NavigationLink(value: filing) { FilingRow(filing: filing) }
                    }
                    Button("home.seeAllTrades") { open(TradeFilter()) }
                }
                Section("home.late") {
                    ForEach(appState.latestFilings.filter(\.isLate).prefix(3)) { filing in
                        NavigationLink(value: filing) { FilingRow(filing: filing, emphasizesLag: true) }
                    }
                    Button("home.seeAllTrades") { open(TradeFilter(lateOnly: true)) }
                }
                Section("home.mostActive") {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(appState.mostActive.prefix(5), id: \.politician.id) { entry in
                                NavigationLink(value: entry.politician) {
                                    VStack(spacing: 6) {
                                        PoliticianAvatar(politician: entry.politician, size: 48)
                                        Text(verbatim: entry.politician.name).font(.caption).multilineTextAlignment(.center)
                                    }.frame(width: 88)
                                }
                            }
                        }
                    }
                    Button("home.seeAllTrades") { open(TradeFilter(members: Set(appState.mostActive.prefix(5).map { $0.politician.id }))) }
                }
                if !appState.statements.isEmpty {
                    Section("statement.home") {
                        ForEach(appState.statements.prefix(3)) { statement in NavigationLink(value: statement) { Text(verbatim: statement.title) } }
                    }
                }
                Section { NavigationLink("portfolio.congress") { ReferencePortfolioView(portfolioID: "congress") } }
                }
                ForEach(Country.allCases.filter { $0 != .us && appState.homeCountries.contains($0) }) { country in
                    Section { NavigationLink { DeclaredInterestsView(country: country) } label: { Text(country.label) + Text(" · ") + Text("interests.title") } }
                }
                Section { NavigationLink("home.aboutData") { MethodologyView() } } footer: { Text("home.footer") }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("home.title")
            .refreshable { await appState.load(force: true) }
            .consigliereDestinations()
            .task(id: appState.latestTrades) { chooseNotable() }
        }
    }

    private var summarySection: some View {
        Section(appState.previousVisit == nil ? "home.thisWeek" : "home.sinceVisit") {
            ViewThatFits(in: .horizontal) {
                HStack { summaryButtons }
                VStack(alignment: .leading) { summaryButtons }
            }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle)
        }
    }

    @ViewBuilder private var summaryButtons: some View {
        Button { open(visitFilter) } label: { Text("home.count.filings \(summary.filings)") }
        Button { var filter = visitFilter; filter.members = appState.followedIDs; open(filter) } label: { Text("home.count.following \(summary.following)") }
        Button { var filter = visitFilter; filter.minimumBand = 1_000_000; open(filter) } label: { Text("home.count.large \(summary.large)") }
        Button { var filter = visitFilter; filter.lateOnly = true; open(filter) } label: { Text("home.count.late \(summary.late)") }
    }

    private var followingSection: some View {
        Section("home.following") {
            if appState.followedIDs.isEmpty {
                Text("home.followPrompt").foregroundStyle(.secondary)
                ForEach(suggestedMembers) { member in
                    Button { appState.toggleFollow(member) } label: { MemberHeaderRow(politician: member) }
                }
            } else if followedFilings.isEmpty {
                Text("home.followEmpty").foregroundStyle(.secondary)
            } else {
                ForEach(followedFilings) { filing in NavigationLink(value: filing) { FilingRow(filing: filing) } }
            }
            Button("home.seeAllTrades") { open(TradeFilter(members: appState.followedIDs)) }.disabled(appState.followedIDs.isEmpty)
        }
    }

    private var suggestedMembers: [Politician] {
        let ranked = appState.mostActive.map(\.politician)
        var picked: [Politician] = []
        var groups = Set<String>()
        for member in ranked where groups.insert("\(member.chamber.rawValue)|\(member.party)").inserted { picked.append(member) }
        picked.append(contentsOf: ranked.filter { member in !picked.contains(where: { $0.id == member.id }) })
        return Array(picked.prefix(5))
    }

    @ViewBuilder private func notableReasons(_ trade: DisclosureTrade) -> some View {
        Text("home.reason.largest")
        if TradeAnalytics.committeeLink(trade) { Text("trade.highlight.committee") }
        if trade.isOption { Text("trade.options") }
        if trade.isLate { Text("home.reason.late") }
        if appState.followedIDs.contains(trade.politicianID ?? "") { Text("profile.following") }
    }

    private func open(_ filter: TradeFilter) { appState.tradeFilter = filter; selectedTab = .trades }

    private func chooseNotable() {
        let weekDate = TradeAnalytics.calendar.dateInterval(of: .weekOfYear, for: .now)!.start
        let week = DisclosureDates.dayFormatter.string(from: weekDate)
        if week != storedWeek {
            let oldDate = DisclosureDates.day(storedWeek)
            previousMember = oldDate.map { weekDate.timeIntervalSince($0) < 8 * 86_400 ? storedMember : "" } ?? ""
            storedWeek = week
        }
        notable = TradeAnalytics.notable(appState.latestTrades, followed: appState.followedIDs, previousMember: previousMember)
        if let notable { storedMember = notable.politicianID ?? notable.representative }
    }
}
