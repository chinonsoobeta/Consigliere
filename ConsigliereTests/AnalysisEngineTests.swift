import XCTest
@testable import Consigliere

final class AnalysisEngineTests: XCTestCase {
    func testPortfolioSummaryWeightsAndValue() {
        let technology = instrument(symbol: "AAA", sector: "Technology", price: 100, change: 2)
        let energy = instrument(symbol: "BBB", sector: "Energy", price: 50, change: -1)
        let holdings = [
            PortfolioHolding(id: UUID(), symbol: "AAA", shares: 2, averageCost: 90),
            PortfolioHolding(id: UUID(), symbol: "BBB", shares: 2, averageCost: 45)
        ]

        let summary = AnalysisEngine.summarize(holdings: holdings, instruments: [technology, energy])

        XCTAssertEqual(summary.marketValue, 300, accuracy: 0.001)
        XCTAssertEqual(summary.concentration, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(summary.dayChange, 1.0, accuracy: 0.001)
    }

    func testMissingSymbolsAreIgnored() {
        let summary = AnalysisEngine.summarize(
            holdings: [PortfolioHolding(id: UUID(), symbol: "MISSING", shares: 10, averageCost: 1)],
            instruments: []
        )
        XCTAssertEqual(summary.marketValue, 0)
        XCTAssertTrue(summary.exposures.isEmpty)
    }

    private func instrument(symbol: String, sector: String, price: Double, change: Double) -> MarketInstrument {
        MarketInstrument(id: UUID(), symbol: symbol, name: symbol, exchange: "TEST", currency: "USD", region: .northAmerica, kind: .equity, price: price, changePercent: change, freshness: .delayed, updatedAt: .now, sector: sector, aliases: [], history: [])
    }
}
