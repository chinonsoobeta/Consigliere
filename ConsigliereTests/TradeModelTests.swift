import XCTest
@testable import Consigliere

final class TradeModelTests: XCTestCase {
    private func day(_ value: String) -> Date { DisclosureDates.day(value)! }

    private func trade(
        _ symbol: String, type: DisclosureTransactionType = .purchase, amount: String = "$1,001 - $15,000",
        traded: String = "2026-08-01", filed: String = "2026-08-20", source: String = "https://example.com/a.pdf",
        observed: String? = nil
    ) -> DisclosureTrade {
        DisclosureTrade(
            id: UUID(), politicianID: "T000001", symbol: symbol, assetName: symbol, type: type,
            owner: .member, amountRange: amount, transactionDate: day(traded), filedDate: day(filed),
            sourceURL: URL(string: source)!, eventStudy: [], observedAt: observed.map(day)
        )
    }

    func testAmountRangeParsesBandsAndOpenEndedValues() {
        let band = AmountRange("$1,001 - $15,000")
        XCTAssertEqual(band.lower, 1_000)
        XCTAssertEqual(band.upper, 15_000)
        XCTAssertEqual(band.sortValue, 15_000)

        let over = AmountRange("Over $50,000,000")
        XCTAssertEqual(over.lower, 50_000_000)
        XCTAssertNil(over.upper)
        XCTAssertEqual(over.sortValue, 50_000_000)

        XCTAssertEqual(AmountRange("Not reported").sortValue, 0)
    }

    func testFilingsGroupBySourceAndSortNewestFirst() {
        let filings = TradeFiling.group([
            trade("AAPL", filed: "2026-08-20", source: "https://example.com/old.pdf"),
            trade("MSFT", amount: "$250,001 - $500,000", filed: "2026-09-01", source: "https://example.com/new.pdf"),
            trade("NVDA", filed: "2026-09-01", source: "https://example.com/new.pdf")
        ])

        XCTAssertEqual(filings.map(\.sourceURL.lastPathComponent), ["new.pdf", "old.pdf"])
        XCTAssertEqual(filings[0].trades.count, 2)
        XCTAssertEqual(filings[0].bySize.first?.symbol, "MSFT")
    }

    func testFilingLagAndLateness() {
        let filing = TradeFiling.group([
            trade("AAPL", traded: "2026-08-01", filed: "2026-08-20"),
            trade("MSFT", traded: "2026-06-01", filed: "2026-08-20")
        ])[0]

        XCTAssertEqual(filing.maxLagDays, 80)
        XCTAssertTrue(filing.isLate)
    }

    func testTradingStatsSummarisesActivity() {
        let stats = TradingStats(trades: [
            trade("AAPL", traded: "2026-08-01", filed: "2026-08-20"),
            trade("AAPL", type: .sale, traded: "2026-07-01", filed: "2026-07-31"),
            trade("MSFT", traded: "2024-01-02", filed: "2024-06-01")
        ], now: day("2026-10-01"))

        XCTAssertEqual(stats.total, 3)
        XCTAssertEqual(stats.lastYear, 2)
        XCTAssertEqual(stats.buys, 2)
        XCTAssertEqual(stats.sells, 1)
        XCTAssertEqual(stats.medianLagDays, 30)
        XCTAssertEqual(stats.lateCount, 1)
        XCTAssertEqual(stats.topSymbols, ["AAPL", "MSFT"])
    }

    func testAssetNamesDropHouseRowNumbers() {
        XCTAssertEqual(
            DisclosureTrade.cleanAssetName("2000140445                 Alphabet Inc. - Class A Common Stock (GOOGL)"),
            "Alphabet Inc. - Class A Common Stock (GOOGL)"
        )
        XCTAssertEqual(DisclosureTrade.cleanAssetName("3M Company"), "3M Company")
    }
}
