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

    func testAssetNamesDropHouseRowNumbersAndKeepOwnerCodes() {
        let plain = DisclosureTrade.parseAssetName("2000140445                 Alphabet Inc. - Class A Common Stock (GOOGL)")
        XCTAssertEqual(plain.name, "Alphabet Inc. - Class A Common Stock (GOOGL)")
        XCTAssertNil(plain.owner)

        let spouse = DisclosureTrade.parseAssetName("2000134527 SP              U.S. Bancorp Common Stock")
        XCTAssertEqual(spouse.name, "U.S. Bancorp Common Stock")
        XCTAssertEqual(spouse.owner, .spouse)

        XCTAssertEqual(DisclosureTrade.parseAssetName("3M Company").name, "3M Company")
        XCTAssertEqual(DisclosureTrade.parseAssetName("SPDR S&P 500 ETF").name, "SPDR S&P 500 ETF")
    }

    func testOwnerCodeInAssetNameOverridesProviderOwner() {
        let trade = DisclosureTrade(
            id: UUID(), politicianID: nil, symbol: "USB", assetName: "2000134527 SP   U.S. Bancorp Common Stock",
            type: .sale, owner: .member, amountRange: "$15,001 - $50,000", transactionDate: day("2025-03-10"),
            filedDate: day("2026-09-12"), sourceURL: URL(string: "https://example.com/a.pdf")!, eventStudy: []
        )
        XCTAssertEqual(trade.owner, .spouse)
    }
    func testHomeCountsFilingsOnceAndUsesFirstObservedDate() {
        let records = [trade("AAPL", source: "https://example.com/a.pdf", observed: "2026-09-01"),
                       trade("MSFT", source: "https://example.com/a.pdf", observed: "2026-09-01")]
        let summary = HomeSummary(trades: records, previousVisit: day("2026-08-31"), followed: ["T000001"], now: day("2026-10-06"))
        XCTAssertEqual(summary.filings, 1)
        XCTAssertEqual(summary.following, 1)
        XCTAssertEqual(HomeSummary(trades: records, previousVisit: day("2026-09-02"), followed: []).filings, 0)
    }

    func testNotableRanksByBandAndAvoidsLastWeeksMember() {
        let now = day("2026-08-21")
        let small = trade("AAPL")
        let large = trade("MSFT", amount: "$1,000,001 - $5,000,000")
        XCTAssertEqual(TradeAnalytics.notable([small, large], followed: [], previousMember: nil, now: now)?.symbol, "MSFT")
        XCTAssertEqual(TradeAnalytics.notable([large], followed: [], previousMember: "T000001", now: now)?.symbol, "MSFT")
        XCTAssertTrue(TradeFilter(minimumBand: 1_000_000).matches(large, now: now))
        XCTAssertFalse(TradeFilter(minimumBand: 1_000_000).matches(small, now: now))
    }

    func testDelayCountsOnePointPerReportAndActivityCountsTransactions() {
        let records = [trade("AAPL"), trade("MSFT")]
        XCTAssertEqual(TradeAnalytics.delays(records).count, 1)
        XCTAssertEqual(TradeAnalytics.activityHistogram(records, now: day("2026-08-21")).reduce(0) { $0 + $1.count }, 2)
        XCTAssertEqual(TradeAnalytics.weeklyPulse(records, now: day("2026-08-21")).last?.count, 1)
        XCTAssertNil(TradeAnalytics.medianReportingDelay([]))
        XCTAssertEqual(TradeAnalytics.medianReportingDelay(TradeAnalytics.delays([records[0]])), 19)
        let nextReport = trade("NVDA", filed: "2026-08-21", source: "https://example.com/b.pdf")
        XCTAssertEqual(TradeAnalytics.medianReportingDelay(TradeAnalytics.delays(records + [nextReport])), 19.5)
    }

}
