import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var instruments: [MarketInstrument] = []
    @Published private(set) var events: [MarketEvent] = []
    @Published private(set) var holdings: [PortfolioHolding] = []
    @Published private(set) var politicians: [Politician] = []
    @Published private(set) var disclosures: [DisclosureTrade] = []
    @Published private(set) var modelPortfolios: [PoliticianModelPortfolio] = []
    @Published var isLoading = false
    @Published var selectedRegion: MarketRegion = .northAmerica

    @AppStorage("appearance") private var storedAppearance = Appearance.system.rawValue
    @AppStorage("language") private var storedLanguage = AppLanguage.usEnglish.rawValue
    @AppStorage("watchlist") private var storedWatchlist = "SPX,TSX,WTI"

    private let provider: any IntelligenceProvider

    init(provider: any IntelligenceProvider = MockIntelligenceProvider()) {
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

    var portfolioSummary: PortfolioSummary {
        AnalysisEngine.summarize(holdings: holdings, instruments: instruments)
    }

    func load() async {
        guard instruments.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let loadedInstruments = provider.instruments()
            async let loadedEvents = provider.events()
            async let loadedHoldings = provider.holdings()
            async let loadedPoliticians = provider.politicians()
            async let loadedDisclosures = provider.disclosures()
            async let loadedModelPortfolios = provider.modelPortfolios()
            instruments = try await loadedInstruments
            events = try await loadedEvents.sorted { $0.publishedAt > $1.publishedAt }
            holdings = try await loadedHoldings
            politicians = try await loadedPoliticians
            disclosures = try await loadedDisclosures
            modelPortfolios = try await loadedModelPortfolios
        } catch {
            // A production client exposes provider health and recovery actions here.
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

    func coverage(for politician: Politician) -> [DisclosureCoverageYear] {
        PoliticianAnalytics.coverage(for: politician, trades: disclosures(for: politician))
    }

    func modelPortfolio(for politician: Politician) -> PoliticianModelPortfolio? {
        modelPortfolios.first { $0.politicianID == politician.id }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? { self == .system ? nil : (self == .dark ? .dark : .light) }
    var label: LocalizedStringKey { LocalizedStringKey("appearance.\(rawValue)") }
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
