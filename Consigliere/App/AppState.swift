import SwiftUI

@MainActor
final class AppState: ObservableObject {
    private static let staleSourceInterval: TimeInterval = 36 * 60 * 60
    private static let latestWindowDays = 90
    static let disclosureProviders = ["apify", "house-ptr", "official-disclosures"]

    @Published private(set) var instruments: [MarketInstrument] = []
    @Published private(set) var events: [MarketEvent] = []
    @Published private(set) var politicians: [Politician] = []
    @Published private(set) var disclosures: [DisclosureTrade] = [] { didSet { reindexDisclosures() } }
    @Published private(set) var sourceHealth: [SourceHealth] = []
    @Published private(set) var availableCoverage: [DisclosureCoverageSummary] = []
    @Published private(set) var unmatchedFilers: [UnmatchedFiler] = []
    @Published private(set) var pendingFilings: [PendingFiling] = []
    @Published private(set) var politiciansWithDisclosures: [Politician] = []
    /// Most recently filed trades across Congress, newest filing first.
    @Published private(set) var latestTrades: [DisclosureTrade] = [] { didSet { latestFilings = TradeFiling.group(latestTrades) } }
    @Published private(set) var latestFilings: [TradeFiling] = []
    @Published private(set) var disclosureLoadError: String?
    @Published private(set) var loadingPoliticianIDs: Set<String> = []
    @Published private(set) var hasAttemptedLoad = false
    @Published private(set) var statements: [PresidentialStatement] = []
    @Published var selectedCountry: Country = .us
    @Published private(set) var countryLoadError: String?
    @Published var tradeFilter = TradeFilter()
    @Published private(set) var latestLoadError: String?
    @Published var isLoading = false
    @Published var selectedRegion: MarketRegion = .northAmerica

    @AppStorage("appearance") private var storedAppearance = Appearance.system.rawValue
    @AppStorage("language") private var storedLanguage = AppLanguage.usEnglish.rawValue
    @AppStorage("watchlist") private var storedWatchlist = "SPY,QQQ,DIA"
    @AppStorage("homeCountries") private var storedHomeCountries = "us"
    @AppStorage("following") private var storedFollowing = ""
    @AppStorage("lastVisit") private var storedLastVisit: Double = 0

    private let providerFactory: () -> any IntelligenceProvider
    private var hasLoaded = false
    private var politicianSummaries: [String: PoliticianDisclosureSummary] = [:] { didSet { reindexDisclosures() } }
    private var disclosuresByPolitician: [String: [DisclosureTrade]] = [:]
    private var politiciansByID: [String: Politician] = [:]

    /// The previous session's visit, captured at launch so "new" survives this session's refreshes.
    let previousVisit: Date?

    init(providerFactory: @escaping () -> any IntelligenceProvider = ProviderFactory.makeDefault) {
        self.providerFactory = providerFactory
        let stored = UserDefaults.standard.double(forKey: "lastVisit")
        previousVisit = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    convenience init(provider: any IntelligenceProvider) {
        self.init(providerFactory: { provider })
    }

    var appearance: Appearance {
        get { Appearance(rawValue: storedAppearance) ?? .system }
        set { storedAppearance = newValue.rawValue; objectWillChange.send() }
    }

    var language: AppLanguage {
        get { AppLanguage(rawValue: storedLanguage) ?? .usEnglish }
        set { storedLanguage = newValue.rawValue; objectWillChange.send() }
    }

    var watchlist: Set<String> {
        Set(storedWatchlist.split(separator: ",").map(String.init))
    }

    var watchedInstruments: [MarketInstrument] {
        instruments.filter { watchlist.contains($0.symbol) }
    }

    var followedIDs: Set<String> {
        Set(storedFollowing.split(separator: ",").map { $0.contains(":") ? String($0) : "us:" + $0 })
    }

    var followedPoliticians: [Politician] {
        let ids = followedIDs
        return politicians.filter { ids.contains($0.id) }.sorted { $0.name < $1.name }
    }

    func isFollowing(_ politician: Politician) -> Bool { followedIDs.contains(politician.id) }

    func toggleFollow(_ politician: Politician) {
        var ids = followedIDs
        if ids.contains(politician.id) { ids.remove(politician.id) } else { ids.insert(politician.id) }
        storedFollowing = ids.sorted().joined(separator: ",")
        objectWillChange.send()
    }

    /// Filings first stored after the previous visit. Empty on first launch.
    var newFilingsSinceLastVisit: [TradeFiling] {
        guard let previousVisit else { return [] }
        return latestFilings.filter { ($0.observedAt ?? .distantPast) > previousVisit }
    }

    /// Market quotes are optional; hide market UI entirely until a quote source is connected.
    var marketsEnabled: Bool {
        !instruments.isEmpty || (health(for: "twelve-data").map { $0.status != .unconfigured } ?? false)
    }

    var posts: [MarketEvent] { events.filter { $0.source == .truthSocial } }

    var disclosureSourcesDelayed: Bool {
        sourceAlerts.contains { Self.disclosureProviders.contains($0.provider) }
    }

    var lastDisclosureSync: Date? {
        Self.disclosureProviders.compactMap { health(for: $0)?.lastSuccessAt }.max()
    }

    /// True until the first snapshot request finishes, so views show progress rather than empty states.
    var isAwaitingFirstLoad: Bool { !hasAttemptedLoad || (isLoading && events.isEmpty) }

    /// Sources that failed, degraded, or have not synced recently. Unconfigured sources are
    /// reported where their content would appear, not as alerts.
    var sourceAlerts: [SourceHealth] {
        sourceHealth.filter { source in
            switch source.status {
            case .failed, .degraded: return true
            case .unconfigured: return false
            case .available:
                guard let lastSuccess = source.lastSuccessAt else { return true }
                return Date.now.timeIntervalSince(lastSuccess) > Self.staleSourceInterval
            }
        }
    }

    func health(for provider: String) -> SourceHealth? {
        sourceHealth.first { $0.provider == provider }
    }

    func politician(id: String?) -> Politician? {
        id.flatMap { politiciansByID[$0] ?? politiciansByID["us:" + $0] }
    }

    func load(force: Bool = false) async {
        guard !isLoading else { return }
        guard force || !hasLoaded else { return }
        isLoading = true
        defer { isLoading = false; hasAttemptedLoad = true }
        disclosureLoadError = nil

        do {
            let snapshot = try await providerFactory().snapshot()
            instruments = snapshot.instruments
            events = snapshot.events.sorted {
                if $0.rankingScore == $1.rankingScore { return $0.publishedAt > $1.publishedAt }
                return $0.rankingScore > $1.rankingScore
            }
            setPoliticians(snapshot.politicians + politicians.filter { $0.nation != .us })
            politicianSummaries = Dictionary(
                snapshot.politicianSummaries.map { ($0.politicianID.contains(":") ? $0.politicianID : "us:" + $0.politicianID, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            disclosures = snapshot.disclosures
            sourceHealth = snapshot.sourceHealth
            availableCoverage = snapshot.coverage
            unmatchedFilers = snapshot.unmatchedFilers
            pendingFilings = snapshot.pendingFilings
            hasLoaded = true
            await loadLatest()
            statements = (try? await providerFactory().statements(ticker: nil)) ?? []
            storedLastVisit = Date.now.timeIntervalSince1970
        } catch {
            disclosureLoadError = error.localizedDescription
            instruments = []
            events = []
            setPoliticians((try? CongressRosterLoader.load()) ?? [])
            politicianSummaries = [:]
            disclosures = []
            sourceHealth = []
            availableCoverage = []
            unmatchedFilers = []
            pendingFilings = []
            latestTrades = []
        }
    }

    /// Loads the newest filings by filing date, separately from the ranked snapshot.
    private func loadLatest() async {
        let from = DisclosureDates.calendar.date(byAdding: .day, value: -Self.latestWindowDays, to: .now)
        do {
            let fetched = try await fetchDisclosures(DisclosureQuery(from: from, dateBasis: .filed, limit: 500))
            latestTrades = fetched
            latestLoadError = nil
        } catch {
            latestTrades = []
            latestLoadError = error.localizedDescription
        }
        let known = Set(disclosures.map(\.id))
        let additions = latestTrades.filter { !known.contains($0.id) }
        if !additions.isEmpty { disclosures.append(contentsOf: additions) }
    }

    var homeCountries: Set<Country> {
        get { Set(storedHomeCountries.split(separator: ",").compactMap { Country(rawValue: String($0)) }) }
        set { storedHomeCountries = newValue.map(\.rawValue).sorted().joined(separator: ","); objectWillChange.send() }
    }
    func loadCountry(_ country: Country) async {
        countryLoadError = nil
        guard country != .us else { return }
        do {
            let members = try await providerFactory().members(country: country)
            setPoliticians(politicians.filter { $0.nation != country } + members)
        } catch { countryLoadError = error.localizedDescription }
    }
    func loadInterests(country: Country, memberID: String? = nil, ticker: String? = nil) async throws -> [DeclaredInterest] {
        try await providerFactory().interests(country: country, memberID: memberID, ticker: ticker)
    }

    func loadPortfolioGroups() async throws -> [PortfolioGroup] { try await providerFactory().portfolioGroups() }
    func loadPortfolio(id: String, ownOnly: Bool) async throws -> ReferencePortfolio { try await providerFactory().portfolio(id: id, ownOnly: ownOnly) }
    func loadPortfolioChanges(id: String, ownOnly: Bool) async throws -> [ReferenceChange] { try await providerFactory().portfolioChanges(id: id, ownOnly: ownOnly) }
    func loadStatements(ticker: String?) async throws -> [PresidentialStatement] { try await providerFactory().statements(ticker: ticker) }
    func loadStatementDetail(id: String) async throws -> StatementDetail { try await providerFactory().statementDetail(id: id, politicians: politicians) }
    func reportTag(statementID: String, tagID: String, reason: String) async throws { try await providerFactory().reportTag(statementID: statementID, tagID: tagID, reason: reason) }
    func loadStockTrades(symbol: String) async throws -> [DisclosureTrade] { try await fetchDisclosures(DisclosureQuery(ticker: symbol, limit: 500)) }

    func toggleWatchlist(_ instrument: MarketInstrument) {
        var symbols = watchlist
        if symbols.contains(instrument.symbol) { symbols.remove(instrument.symbol) }
        else { symbols.insert(instrument.symbol) }
        storedWatchlist = symbols.sorted().joined(separator: ",")
        objectWillChange.send()
    }

    func disclosures(for politician: Politician) -> [DisclosureTrade] {
        disclosuresByPolitician[politician.id] ?? []
    }

    func pendingFilings(for politician: Politician) -> [PendingFiling] {
        pendingFilings.filter { $0.politicianID == politician.id }
    }

    func loadDisclosures(
        for politician: Politician,
        from: Date? = nil,
        to: Date? = nil,
        dateBasis: DisclosureQuery.DateBasis = .transaction
    ) async {
        guard !loadingPoliticianIDs.contains(politician.id) else { return }
        loadingPoliticianIDs.insert(politician.id)
        defer { loadingPoliticianIDs.remove(politician.id) }
        do {
            var fetched = try await fetchDisclosures(DisclosureQuery(
                politicianID: politician.id, chamber: politician.chamber,
                from: from, to: to, dateBasis: dateBasis, limit: 500
            ))
            // Older backends, or rows not yet re-matched server-side, only answer surname queries.
            if fetched.isEmpty, let surname = politician.name.split(separator: " ").last.map(String.init) {
                fetched = try await fetchDisclosures(DisclosureQuery(
                    representative: surname, chamber: politician.chamber,
                    from: from, to: to, dateBasis: dateBasis, limit: 500
                ))
            }
            fetched = fetched.filter { $0.politicianID == politician.id }
            let replacements = Set(fetched.map(\.id))
            var merged = disclosures.filter { !replacements.contains($0.id) }
            merged.append(contentsOf: fetched)
            disclosures = merged
            disclosureLoadError = nil
        } catch {
            disclosureLoadError = error.localizedDescription
        }
    }

    private func fetchDisclosures(_ query: DisclosureQuery) async throws -> [DisclosureTrade] {
        let provider = providerFactory()
        var cursor: DisclosureCursor?
        var fetched: [DisclosureTrade] = []
        var seenCursors = Set<DisclosureCursor>()
        repeat {
            let page = try await provider.disclosures(
                query: DisclosureQuery(
                    ticker: query.ticker,
                    politicianID: query.politicianID,
                    representative: query.representative,
                    chamber: query.chamber,
                    from: query.from,
                    to: query.to,
                    dateBasis: query.dateBasis,
                    limit: query.limit,
                    cursor: cursor
                ),
                politicians: politicians
            )
            fetched.append(contentsOf: page.disclosures)
            cursor = page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted { throw ConsigliereAPIClient.ClientError.invalidResponse }
        } while cursor != nil
        return fetched
    }

    /// Total stored disclosures for a politician, preferring the server-wide summary over the
    /// records currently loaded on device.
    func disclosureCount(for politician: Politician) -> Int {
        max(politicianSummaries[politician.id]?.records ?? 0, disclosuresByPolitician[politician.id]?.count ?? 0)
    }

    func stats(for politician: Politician) -> TradingStats? {
        let trades = disclosures(for: politician)
        return trades.isEmpty ? nil : TradingStats(trades: trades)
    }

    /// Members ranked by trades in the latest window.
    var mostActive: [(politician: Politician, trades: Int)] {
        let counts = Dictionary(grouping: latestTrades.compactMap(\.politicianID), by: { $0 }).mapValues(\.count)
        return counts.compactMap { id, count in politiciansByID[id].map { ($0, count) } }
            .sorted { $0.trades != $1.trades ? $0.trades > $1.trades : $0.politician.name < $1.politician.name }
    }

    func coverage(for politician: Politician) -> DisclosureCoverageSummary? {
        let records = disclosures(for: politician)
        let summary = politicianSummaries[politician.id]
        guard summary != nil || !records.isEmpty else { return nil }
        let dates = records.map(\.filedDate).sorted()
        let localEarliest = dates.first.map(DisclosureDates.dayFormatter.string(from:))
        let localLatest = dates.last.map(DisclosureDates.dayFormatter.string(from:))
        return DisclosureCoverageSummary(
            chamber: politician.id,
            earliest: [summary?.earliest, localEarliest].compactMap { $0 }.min(),
            latest: [summary?.latest, localLatest].compactMap { $0 }.max(),
            records: disclosureCount(for: politician),
            completeness: "matched-records"
        )
    }

    private func setPoliticians(_ roster: [Politician]) {
        politicians = roster
        politiciansByID = Dictionary(roster.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        reindexDisclosures()
    }

    private func reindexDisclosures() {
        var grouped: [String: [DisclosureTrade]] = [:]
        for trade in disclosures {
            guard let id = trade.politicianID else { continue }
            grouped[id, default: []].append(trade)
        }
        disclosuresByPolitician = grouped.mapValues { $0.sorted { $0.transactionDate > $1.transactionDate } }
        let counts = Dictionary(uniqueKeysWithValues: politicians.map { ($0.id, disclosureCount(for: $0)) })
        politiciansWithDisclosures = politicians
            .filter { (counts[$0.id] ?? 0) > 0 }
            .sorted {
                let leftCount = counts[$0.id] ?? 0
                let rightCount = counts[$1.id] ?? 0
                if leftCount != rightCount { return leftCount > rightCount }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? { self == .system ? nil : (self == .dark ? .dark : .light) }
    var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "appearance.\(rawValue)") }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case usEnglish = "en-US"
    case canadianEnglish = "en-CA"
    case spanish = "es"
    case french = "fr"
    case canadianFrench = "fr-CA"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }
    var label: String {
        switch self {
        case .usEnglish: "English (US)"
        case .canadianEnglish: "English (Canada)"
        case .spanish: "Español"
        case .french: "Français"
        case .canadianFrench: "Français (Canada)"
        }
    }
}
