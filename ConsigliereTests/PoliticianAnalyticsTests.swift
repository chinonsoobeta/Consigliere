import XCTest
@testable import Consigliere

final class PoliticianAnalyticsTests: XCTestCase {
    private let politician = Politician(
        id: "T000001", name: "Test Member", party: "Independent", state: "Test State",
        district: 1, chamber: .house, imageURL: nil, serviceStart: 2020
    )

    func testBundledRosterLoadsCurrentCongress() throws {
        let roster = try CongressRosterLoader.load()

        XCTAssertGreaterThan(roster.count, 500)
        XCTAssertTrue(roster.contains { $0.id == "P000197" && $0.name.localizedCaseInsensitiveContains("Pelosi") })
    }

    func testEventStudyComputesAbnormalReturn() {
        let point = EventStudyPoint(tradingDay: 5, securityReturn: 0.08, benchmarkReturn: 0.03, sectorReturn: 0.04)
        XCTAssertEqual(point.abnormalReturn, 0.05, accuracy: 0.0001)
    }
}
