import XCTest
@testable import Consigliere

final class PoliticianAnalyticsTests: XCTestCase {
    private let politician = Politician(
        id: "T000001", name: "Test Member", party: "Independent", state: "Test State",
        district: 1, chamber: .house, imageURL: nil, serviceStart: 2020
    )

    func testTenYearCoverageDistinguishesUnavailableFromNoTrades() {
        let coverage = PoliticianAnalytics.coverage(for: politician, currentYear: 2026)

        XCTAssertEqual(coverage.count, 10)
        XCTAssertEqual(coverage.first(where: { $0.year == 2017 })?.status, .notServing)
        XCTAssertEqual(coverage.first(where: { $0.year == 2020 })?.status, .sourceUnavailable)
        XCTAssertEqual(coverage.first(where: { $0.year == 2026 })?.status, .noReportableTransactions)
    }

    func testBundledRosterLoadsCurrentCongress() throws {
        let roster = try PoliticianPrototypeData.loadRoster()

        XCTAssertGreaterThan(roster.count, 500)
        XCTAssertTrue(roster.contains { $0.id == "P000197" && $0.name.localizedCaseInsensitiveContains("Pelosi") })
    }

    func testTradeYearBecomesComplete() {
        let trade = DisclosureTrade(
            id: UUID(), politicianID: politician.id, symbol: "TEST", assetName: "Test Security",
            type: .purchase, owner: .member, amountRange: "$1,001–$15,000",
            transactionDate: ISO8601DateFormatter().date(from: "2025-04-01T12:00:00Z")!,
            filedDate: ISO8601DateFormatter().date(from: "2025-04-20T12:00:00Z")!,
            sourceURL: URL(string: "https://example.com")!, eventStudy: []
        )

        let coverage = PoliticianAnalytics.coverage(for: politician, trades: [trade], currentYear: 2026)

        XCTAssertEqual(coverage.first(where: { $0.year == 2025 })?.status, .complete)
    }

    func testEventStudyComputesAbnormalReturn() {
        let point = EventStudyPoint(tradingDay: 5, securityReturn: 0.08, benchmarkReturn: 0.03, sectorReturn: 0.04)
        XCTAssertEqual(point.abnormalReturn, 0.05, accuracy: 0.0001)
    }
}
