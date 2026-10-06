import SwiftUI

@MainActor
final class AppState: ObservableObject {
    private static let maxDisclosurePages = 20
    private static let staleSourceInterval: TimeInterval = 36 * 60 * 60

    @Published private(set) var instruments: [MarketInstrument] = []
    @Published private(set) var events: [MarketEvent] = []
    @Published private(set) var politicians: [Politician] = []
    @Published private(set) var disclosures: [DisclosureTrade] = [] { didSet { reindexDisclosures() } }
    @Published private(set) var sourceHealth: [SourceHealth] = []
    @Published private(set) var availableCoverage: [DisclosureCoverageSummary] = []
    @Published private(set) var unmatchedFilers: [UnmatchedFiler] = []
    @Published private(set) var pendingFilings: [PendingFiling] = []
    @Published private(set) var politiciansWithDisclosures: [Politician] = []
    @Published private(set) var disclosureLoadError: String?
    @Published private(set) var loadingPoliticianIDs: Set<String> = []
    @Published private(set) var hasAttemptedLoad = false
    @Published var isLoading = false
    @Published var selectedRegion: MarketRegion = .northAmerica

    @AppStorage("appearance") private var storedAppearance = Appearance.system.rawValue
    @AppStorage("language") private var storedLanguage = AppLanguage.usEnglish.rawValue
    @AppStorage("watchlist") private var storedWatchlist = "SPY,QQQ,DIA"

    private let providerFactory: () -> any IntelligenceProvider
    private var hasLoaded = false
    private var politicianSummaries: [String: PoliticianDisclosureSummary] = [:] { didSet { reindexDisclosures() } }
    private var disclosuresByPolitician: [String: [DisclosureTrade]] = [:]
    private var politiciansByID: [String: Politician] = [:]

    init(providerFactory: @escaping () -> any IntelligenceProvider = ProviderFactory.makeDefault) {
        self.providerFactory = providerFactory
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
        id.flatMap { politiciansByID[$0] }
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
            setPoliticians(snapshot.politicians)
            politicianSummaries = Dictionary(
                snapshot.politicianSummaries.map { ($0.politicianID, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            disclosures = snapshot.disclosures
            sourceHealth = snapshot.sourceHealth
            availableCoverage = snapshot.coverage
            unmatchedFilers = snapshot.unmatchedFilers
            pendingFilings = snapshot.pendingFilings
            hasLoaded = true
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
        }
    }

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
        var pages = 0
        repeat {
            let page = try await provider.disclosures(
                query: DisclosureQuery(
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
            pages += 1
        } while cursor != nil && pages < Self.maxDisclosurePages
        return fetched
    }

    /// Total stored disclosures for a politician, preferring the server-wide summary over the
    /// records currently loaded on device.
    func disclosureCount(for politician: Politician) -> Int {
        max(politicianSummaries[politician.id]?.records ?? 0, disclosuresByPolitician[politician.id]?.count ?? 0)
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

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }
    var label: String {
        switch self {
        case .usEnglish: "English (US)"
        case .canadianEnglish: "English (Canada)"
        case .spanish: "Español"
        case .french: "Français"
        }
    }
}
