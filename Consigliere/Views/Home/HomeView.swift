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
    private var flows: [TickerFlow] { TradeAnalytics.flows(appState.latestTrades) }
    private var visitFilter: TradeFilter { TradeFilter(filedWithinDays: appState.previousVisit == nil ? 7 : nil, observedAfter: appState.previousVisit) }
    /// Proclamations and ceremonial notices are kept in the feed but are not Home material.
    private var relevantStatements: [PresidentialStatement] { appState.statements.filter { $0.tier != "General" } }

    var body: some View {
        NavigationStack {
            ThemedList {
                if appState.disclosureSourcesDelayed {
                    NavigationLink { DataSourcesView() } label: { Label("home.delayed", systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(ConsigliereTheme.warning) }
                }
                if let error = appState.latestLoadError ?? appState.disclosureLoadError {
                    Text(verbatim: error).foregroundStyle(ConsigliereTheme.warning)
                }
                if appState.homeCountries.contains(.us) {
                    summarySection
                    followingSection
                    if let notable { notableSection(notable) }
                    flowSections
                    widelyHeldSection
                    pulseSection
                    Section(themed: "home.newFilings") {
                        ForEach(appState.latestFilings.filter { !Set(followedFilings.map(\.id)).contains($0.id) }.prefix(5)) { filing in
                            NavigationLink(value: filing) { FilingRow(filing: filing) }
                        }
                        Button("home.all.filings") { open(TradeFilter()) }
                    }
                    let late = appState.latestFilings.filter(\.isLate).prefix(3)
                    if !late.isEmpty {
                        Section {
                            ForEach(late) { filing in
                                NavigationLink(value: filing) { FilingRow(filing: filing, emphasizesLag: true) }
                            }
                            Button("home.all.late") { open(TradeFilter(lateOnly: true)) }
                        } header: { SectionTitle("home.late") } footer: { Text("home.late.footer") }
                    }
                    mostActiveSection
                    if !relevantStatements.isEmpty {
                        Section {
                            ForEach(relevantStatements.prefix(3)) { statement in
                                NavigationLink(value: statement) { StatementRow(statement: statement) }
                            }
                        } header: { SectionTitle("statement.home") } footer: { Text("statement.homeFooter") }
                    }
                }
                ForEach(Country.available.filter { $0 != .us && appState.homeCountries.contains($0) }) { country in
                    Section { NavigationLink { DeclaredInterestsView(country: country) } label: { Text(country.label) + Text(verbatim: " · ") + Text("interests.title") } }
                }
                Section { NavigationLink("home.aboutData") { MethodologyView() } } footer: { Text("home.footer") }
            }
            .navigationTitle("home.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { Wordmark(compact: true) } }
            .refreshable { await appState.load(force: true) }
            .consigliereDestinations()
            .task(id: appState.latestTrades) { chooseNotable() }
        }
    }

    // MARK: Sections

    private var weekTrades: [DisclosureTrade] { appState.latestTrades.filter { TradeFilter(filedWithinDays: 7).matches($0) } }

    @ViewBuilder private var summarySection: some View {
        Section { HomeHero(trades: weekTrades) }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
        Section {
            if summary.filings == 0 && appState.previousVisit != nil {
                Label("home.caughtUp", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    SummaryTile(count: summary.filings, label: "home.tile.filings") { open(visitFilter) }
                    SummaryTile(count: summary.following, label: "home.tile.following") {
                        var filter = visitFilter; filter.members = appState.followedIDs; open(filter)
                    }
                    SummaryTile(count: summary.large, label: "home.tile.large") {
                        var filter = visitFilter; filter.minimumBand = 1_000_000; open(filter)
                    }
                    SummaryTile(count: summary.late, label: "home.tile.late") {
                        var filter = visitFilter; filter.lateOnly = true; open(filter)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var followingSection: some View {
        Section(themed: "home.following") {
            if appState.followedIDs.isEmpty {
                Text("home.followPrompt").foregroundStyle(.secondary)
                ForEach(suggestedMembers) { member in
                    Button { appState.toggleFollow(member) } label: {
                        HStack {
                            MemberHeaderRow(politician: member)
                            Spacer()
                            Image(systemName: "plus.circle").foregroundStyle(ConsigliereTheme.accent)
                                .accessibilityLabel(Text("profile.follow"))
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else if followedFilings.isEmpty {
                Text("home.followEmpty").foregroundStyle(.secondary)
            } else {
                ForEach(followedFilings) { filing in NavigationLink(value: filing) { FilingRow(filing: filing) } }
                Button("home.all.following") { open(TradeFilter(members: appState.followedIDs)) }
            }
        }
    }

    private func notableSection(_ trade: DisclosureTrade) -> some View {
        Section {
            NavigationLink(value: trade) { TradeRow(trade: trade) }
            ViewThatFits(in: .horizontal) {
                HStack { notableReasons(trade) }
                VStack(alignment: .leading) { notableReasons(trade) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: { SectionTitle("home.notableWeek") }
    }

    @ViewBuilder private var flowSections: some View {
        let bought = TradeAnalytics.mostBought(flows)
        let sold = TradeAnalytics.mostSold(flows)
        if !bought.isEmpty {
            Section {
                ForEach(bought) { FlowRow(flow: $0, emphasis: .purchase) }
            } header: { SectionTitle("home.flow.bought") } footer: { Text("home.flow.footer") }
        }
        if !sold.isEmpty {
            Section(themed: "home.flow.sold") {
                ForEach(sold) { FlowRow(flow: $0, emphasis: .sale) }
            }
        }
    }

    @ViewBuilder private var widelyHeldSection: some View {
        if !appState.widelyHeld.isEmpty {
            Section {
                ForEach(appState.widelyHeld.prefix(5)) { position in
                    NavigationLink(value: StockRoute(symbol: position.ticker)) {
                        HStack {
                            SecurityLabel(symbol: position.ticker, name: position.assetName)
                            Spacer()
                            Text("portfolio.memberCount \(position.membersHolding)")
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink("portfolio.congress") { ReferencePortfolioView(portfolioID: "congress") }
            } header: { SectionTitle("home.widelyHeld") } footer: { Text("home.widelyHeld.footer") }
        }
    }

    private var pulseSection: some View {
        Section {
            FilingCharts.weekly(pulse, locale: appState.language.locale)
            if TradeAnalytics.busierThanUsual(pulse) {
                Label("home.busier", systemImage: "arrow.up.right").font(.caption).foregroundStyle(ConsigliereTheme.accent)
            }
            Button("home.all.recent") { open(TradeFilter(filedWithinDays: 84)) }
        } header: { SectionTitle("home.pulse") }
    }

    private var mostActiveSection: some View {
        Section(themed: "home.mostActive") {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(appState.mostActive.prefix(8), id: \.politician.id) { entry in
                        NavigationLink(value: entry.politician) {
                            VStack(spacing: 6) {
                                PoliticianAvatar(politician: entry.politician, size: 48)
                                Text(verbatim: entry.politician.name).font(.caption).multilineTextAlignment(.center).lineLimit(2)
                                Text("home.tradeCount \(entry.trades)").font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(width: 88)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("home.mostActive.a11y \(entry.politician.name) \(entry.trades)"))
                    }
                }
            }
            .scrollIndicators(.hidden)
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

private struct SummaryTile: View {
    let count: Int
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(count, format: .number).font(.title.bold().monospacedDigit())
                    .foregroundStyle(count == 0 ? Color.secondary : ConsigliereTheme.accent)
                Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(ConsigliereTheme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
    }
}

/// Ticker in bold with the issuer's name beneath, used wherever a list is keyed by security.
struct SecurityLabel: View {
    let symbol: String
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: symbol).font(.headline.monospaced())
            let issuer = Self.issuer(name, symbol: symbol)
            if !issuer.isEmpty && issuer != symbol { Text(verbatim: issuer).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    /// Filers write "Microsoft Corporation - Common Stock (MSFT)"; the ticker is already beside it.
    static func issuer(_ name: String, symbol: String) -> String {
        var value = name.replacingOccurrences(of: "(\(symbol))", with: "")
        for suffix in [" - Common Stock", " Common Stock", " - Ordinary Shares", " Ordinary Shares"] {
            value = value.replacingOccurrences(of: suffix, with: "", options: .caseInsensitive)
        }
        return value.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-–")))
    }
}

private struct FlowRow: View {
    let flow: TickerFlow
    let emphasis: DisclosureTransactionType

    var body: some View {
        NavigationLink(value: StockRoute(symbol: flow.symbol)) {
            HStack {
                SecurityLabel(symbol: flow.symbol, name: flow.assetName)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("home.flow.buyers \(flow.buyers)")
                        .foregroundStyle(emphasis == .purchase ? ConsigliereTheme.positive : .secondary)
                    Text("home.flow.sellers \(flow.sellers)")
                        .foregroundStyle(emphasis == .sale ? ConsigliereTheme.negative : .secondary)
                }
                .font(.caption.monospacedDigit())
            }
        }
    }
}

struct StatementRow: View {
    let statement: PresidentialStatement

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: statement.title).font(.subheadline.weight(.semibold)).lineLimit(3)
            HStack(spacing: 6) {
                if let date = DisclosureDates.day(statement.publishedAt) {
                    Text(date, format: DisclosureDates.compact(date)).foregroundStyle(.secondary)
                }
                ForEach(statement.tags.filter { $0.kind != "country" }.prefix(3)) { tag in
                    Text(verbatim: tag.value)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(ConsigliereTheme.accent.opacity(0.12), in: Capsule())
                }
            }
            .font(.caption)
        }
    }
}

/// The editorial top of Home: today's date, a one-line read of the window, and the buy/sell split.
private struct HomeHero: View {
    let trades: [DisclosureTrade]
    @ScaledMetric(relativeTo: .largeTitle) private var bigNumber: CGFloat = 52

    private var buys: Int { trades.filter { $0.type == .purchase }.count }
    private var sells: Int { trades.filter { $0.type == .sale }.count }
    private var members: Int { Set(trades.map { $0.politicianID ?? $0.representative }).count }

    private var headline: LocalizedStringKey {
        if buys + sells == 0 { return "home.hero.quiet" }
        if Double(buys) >= Double(sells) * 1.5 { return "home.hero.buying" }
        if Double(sells) >= Double(buys) * 1.5 { return "home.hero.selling" }
        return "home.hero.mixed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide)))
                Text(headline)
                    .font(ConsigliereTheme.display(.largeTitle, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if !trades.isEmpty {
                    Text("home.hero.week \(trades.count) \(members)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if buys + sells > 0 {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        figure(buys, "home.hero.buys", "arrow.up", ConsigliereTheme.positive)
                        Spacer()
                        figure(sells, "home.hero.sells", "arrow.down", ConsigliereTheme.negative, trailing: true)
                    }
                    GeometryReader { proxy in
                        let share = CGFloat(buys) / CGFloat(max(buys + sells, 1))
                        HStack(spacing: 4) {
                            Capsule().fill(ConsigliereTheme.positive).frame(width: max((proxy.size.width - 4) * share, buys > 0 ? 8 : 0))
                            Capsule().fill(ConsigliereTheme.negative)
                        }
                    }
                    .frame(height: 10)
                    .accessibilityHidden(true)
                }
                .padding(20)
                .background(ConsigliereTheme.surface, in: RoundedRectangle(cornerRadius: ConsigliereTheme.cardRadius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: ConsigliereTheme.cardRadius, style: .continuous).stroke(ConsigliereTheme.hairline) }
            }
        }
        .padding(.top, 8)
    }

    private func figure(_ value: Int, _ label: LocalizedStringKey, _ icon: String, _ color: Color, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Label { Text(label).foregroundStyle(.secondary) } icon: { Image(systemName: icon).foregroundStyle(color) }
                .font(.subheadline.weight(.medium))
            Text(value, format: .number)
                .font(.system(size: bigNumber, weight: .bold).monospacedDigit())
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }
}
