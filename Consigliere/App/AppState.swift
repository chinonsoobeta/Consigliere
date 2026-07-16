import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var instruments: [MarketInstrument] = []
    @Published private(set) var events: [MarketEvent] = []
    @Published private(set) var politicians: [Politician] = []
    @Published private(set) var disclosures: [DisclosureTrade] = []
    @Published private(set) var sourceHealth: [SourceHealth] = []
    @Published private(set) var availableCoverage: [DisclosureCoverageSummary] = []
    @Published private(set) var disclosureLoadError: String?
    @Published var isLoading = false
    @Published var selectedRegion: MarketRegion = .northAmerica

    @AppStorage("appearance") private var storedAppearance = Appearance.system.rawValue
    @AppStorage("language") private var storedLanguage = AppLanguage.usEnglish.rawValue
    @AppStorage("watchlist") private var storedWatchlist = "SPY,QQQ,DIA"

    private let provider: any IntelligenceProvider
    private var hasLoaded = false

    init(provider: any IntelligenceProvider = ProviderFactory.makeDefault()) {
        self.provider = provider
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

    var politiciansWithDisclosures: [Politician] {
        politicians
            .filter { disclosureCount(for: $0) > 0 }
            .sorted {
                let leftCount = disclosureCount(for: $0)
                let rightCount = disclosureCount(for: $1)
                if leftCount != rightCount { return leftCount > rightCount }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    func load(force: Bool = false) async {
        guard !isLoading else { return }
        guard force || !hasLoaded else { return }
        isLoading = true
        defer { isLoading = false }
        disclosureLoadError = nil

        do {
            let snapshot = try await provider.snapshot()
            instruments = snapshot.instruments
            events = snapshot.events.sorted {
                if $0.rankingScore == $1.rankingScore { return $0.publishedAt > $1.publishedAt }
                return $0.rankingScore > $1.rankingScore
            }
            politicians = snapshot.politicians
            disclosures = snapshot.disclosures
            sourceHealth = snapshot.sourceHealth
            availableCoverage = snapshot.coverage
            hasLoaded = true
        } catch {
            disclosureLoadError = error.localizedDescription
            instruments = []
            events = []
            politicians = (try? CongressRosterLoader.load()) ?? []
            disclosures = []
            sourceHealth = []
            availableCoverage = []
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
        disclosures.filter { $0.politicianID == politician.id }.sorted { $0.transactionDate > $1.transactionDate }
    }

    func disclosureCount(for politician: Politician) -> Int {
        disclosures.filter { $0.politicianID == politician.id }.count
    }

    func coverage(for politician: Politician) -> DisclosureCoverageSummary? {
        availableCoverage.first { $0.chamber == politician.chamber.rawValue }
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
