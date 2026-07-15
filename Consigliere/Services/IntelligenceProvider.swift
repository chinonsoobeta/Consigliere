import Foundation

protocol IntelligenceProvider: Sendable {
    func instruments() async throws -> [MarketInstrument]
    func events() async throws -> [MarketEvent]
    func holdings() async throws -> [PortfolioHolding]
}

struct MockIntelligenceProvider: IntelligenceProvider {
    func instruments() async throws -> [MarketInstrument] { MockData.instruments }
    func events() async throws -> [MarketEvent] { MockData.events }
    func holdings() async throws -> [PortfolioHolding] { MockData.holdings }
}

private enum MockData {
    static let instruments: [MarketInstrument] = [
        make("SPX", "S&P 500", "S&P DJI", "USD", .northAmerica, .index, 6231.4, 0.42, sector: nil),
        make("NDX", "Nasdaq-100", "NASDAQ", "USD", .northAmerica, .index, 22884.7, 0.71, sector: "Technology"),
        make("DJI", "Dow Jones Industrial Average", "S&P DJI", "USD", .northAmerica, .index, 44782.2, 0.18, sector: nil),
        make("RUT", "Russell 2000", "FTSE Russell", "USD", .northAmerica, .index, 2268.5, -0.24, sector: nil),
        make("VIX", "CBOE Volatility Index", "CBOE", "USD", .northAmerica, .index, 15.8, -2.11, sector: nil),
        make("TSX", "S&P/TSX Composite", "TSX", "CAD", .northAmerica, .index, 27438.8, 0.36, sector: nil),
        make("TX60", "S&P/TSX 60", "TSX", "CAD", .northAmerica, .index, 1648.4, 0.31, sector: nil),
        make("JX", "S&P/TSX Venture Composite", "TSXV", "CAD", .northAmerica, .index, 896.9, -0.12, sector: nil),
        make("AAPL", "Apple Inc.", "NASDAQ", "USD", .northAmerica, .equity, 232.6, 1.14, sector: "Technology", aliases: ["Apple"]),
        make("SHOP", "Shopify Inc.", "TSX", "CAD", .northAmerica, .equity, 162.4, 1.83, sector: "Technology", aliases: ["SHOP.TO"]),
        make("CNQ", "Canadian Natural Resources", "TSX", "CAD", .northAmerica, .equity, 49.2, -0.41, sector: "Energy", aliases: ["CNQ.TO"]),
        make("WTI", "West Texas Intermediate", "NYMEX", "USD", .northAmerica, .future, 76.8, 1.32, sector: "Energy"),
        make("BRENT", "Brent Crude", "ICE", "USD", .global, .future, 80.2, 1.08, sector: "Energy"),
        make("WCS", "Western Canadian Select", "Physical assessment", "USD", .northAmerica, .differential, -13.7, 0.44, freshness: .assessment, sector: "Energy"),
        make("ARABL", "Arab Light", "Official selling price", "USD", .global, .spotAssessment, 82.1, 0.00, freshness: .assessment, sector: "Energy"),
        make("STOXX", "STOXX Europe 600", "STOXX", "EUR", .europe, .index, 548.3, 0.21, sector: nil),
        make("FTSE", "FTSE 100", "LSE", "GBP", .europe, .index, 8914.2, 0.09, sector: nil),
        make("DAX", "DAX", "XETRA", "EUR", .europe, .index, 24256.1, -0.18, sector: nil),
        make("N225", "Nikkei 225", "TSE", "JPY", .asiaPacific, .index, 41282.9, 0.58, sector: nil),
        make("HSI", "Hang Seng Index", "HKEX", "HKD", .asiaPacific, .index, 24138.3, -0.35, sector: nil),
        make("MSCIW", "MSCI World", "MSCI", "USD", .global, .index, 4219.7, 0.33, sector: nil),
        make("DXY", "U.S. Dollar Index", "ICE", "USD", .global, .currency, 97.9, -0.17, sector: nil),
        make("GOLD", "Gold Futures", "COMEX", "USD", .global, .future, 3381.6, 0.62, sector: "Materials"),
        make("US10Y", "U.S. 10-Year Treasury Yield", "Treasury", "USD", .global, .yield, 4.21, 0.03, sector: nil)
    ]

    static let events: [MarketEvent] = [
        MarketEvent(
            id: UUID(), source: .truthSocial,
            title: "Trade policy remarks draw attention to autos and industrials",
            body: "Prototype source excerpt: the post discusses reciprocal trade measures and domestic manufacturing.",
            author: "@realDonaldTrump", publishedAt: .now.addingTimeInterval(-920), retrievedAt: .now.addingTimeInterval(-903), transactionDate: nil,
            sourceURL: URL(string: "https://truthsocial.com/@realDonaldTrump")!, mentionedSymbols: ["SPX", "TSX"], topics: ["Tariffs", "Industrials", "Canada"], impact: .elevated, confidence: 0.84,
            explanation: "Industrials and cross-border manufacturers moved more than the broad market during the first 15 minutes. This is an observed association, not evidence of causation.",
            reaction: MarketReaction(symbol: "SPX", oneMinute: -0.08, fiveMinutes: -0.24, fifteenMinutes: -0.31, sixtyMinutes: -0.12, oneDay: nil), freshness: .prototype
        ),
        MarketEvent(
            id: UUID(), source: .houseDisclosure,
            title: "Newly disclosed purchase in a large-cap technology company",
            body: "A House periodic transaction report lists a purchase valued between $15,001 and $50,000.",
            author: "House member · California", publishedAt: .now.addingTimeInterval(-5400), retrievedAt: .now.addingTimeInterval(-5310), transactionDate: .now.addingTimeInterval(-18 * 86_400),
            sourceURL: URL(string: "https://disclosures-clerk.house.gov/PublicDisclosure/FinancialDisclosure")!, mentionedSymbols: ["AAPL"], topics: ["Technology", "Congressional disclosure"], impact: .moderate, confidence: 0.96,
            explanation: "This is a newly available disclosure, not a real-time trade. The transaction date preceded publication by 18 days.",
            reaction: MarketReaction(symbol: "AAPL", oneMinute: nil, fiveMinutes: 0.03, fifteenMinutes: 0.07, sixtyMinutes: 0.11, oneDay: nil), freshness: .prototype
        ),
        MarketEvent(
            id: UUID(), source: .truthSocial,
            title: "Energy comments coincide with higher crude prices",
            body: "Prototype source excerpt: the post calls for changes to energy production and sanctions policy.",
            author: "@realDonaldTrump", publishedAt: .now.addingTimeInterval(-11_200), retrievedAt: .now.addingTimeInterval(-11_176), transactionDate: nil,
            sourceURL: URL(string: "https://truthsocial.com/@realDonaldTrump")!, mentionedSymbols: ["WTI", "BRENT", "WCS", "CNQ"], topics: ["Energy", "Oil", "Sanctions"], impact: .elevated, confidence: 0.79,
            explanation: "WTI and Brent rose during the event window while the WCS differential narrowed. Other news may have contributed.",
            reaction: MarketReaction(symbol: "WTI", oneMinute: 0.12, fiveMinutes: 0.38, fifteenMinutes: 0.74, sixtyMinutes: 1.05, oneDay: 1.32), freshness: .prototype
        ),
        MarketEvent(
            id: UUID(), source: .senateDisclosure,
            title: "Senate filing reports sale of an energy holding",
            body: "A periodic transaction report lists a sale valued between $1,001 and $15,000.",
            author: "Senator · Texas", publishedAt: .now.addingTimeInterval(-18_500), retrievedAt: .now.addingTimeInterval(-18_350), transactionDate: .now.addingTimeInterval(-31 * 86_400),
            sourceURL: URL(string: "https://efdsearch.senate.gov/search/")!, mentionedSymbols: ["CNQ"], topics: ["Energy", "Congressional disclosure"], impact: .low, confidence: 0.94,
            explanation: "The filing is presented for research context. Its value is reported as a range and the public disclosure followed the transaction.",
            reaction: nil, freshness: .prototype
        )
    ]

    static let holdings: [PortfolioHolding] = [
        PortfolioHolding(id: UUID(), symbol: "AAPL", shares: 12, averageCost: 191.20),
        PortfolioHolding(id: UUID(), symbol: "SHOP", shares: 18, averageCost: 128.40),
        PortfolioHolding(id: UUID(), symbol: "CNQ", shares: 42, averageCost: 44.10)
    ]

    static func make(
        _ symbol: String, _ name: String, _ exchange: String, _ currency: String,
        _ region: MarketRegion, _ kind: InstrumentKind, _ price: Double, _ change: Double,
        freshness: DataFreshness = .prototype, sector: String?, aliases: [String] = []
    ) -> MarketInstrument {
        let history = stride(from: 240, through: 0, by: -20).enumerated().map { index, minutes in
            let wave = sin(Double(index) * 0.78) * price * 0.003
            let trend = Double(index) / 12 * price * change / 100
            return PricePoint(price - trend + wave, minutesAgo: minutes)
        }
        return MarketInstrument(id: UUID(), symbol: symbol, name: name, exchange: exchange, currency: currency, region: region, kind: kind, price: price, changePercent: change, freshness: freshness, updatedAt: .now.addingTimeInterval(-42), sector: sector, aliases: aliases, history: history)
    }
}
