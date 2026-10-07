import XCTest
@testable import Consigliere

final class AnalysisEngineTests: XCTestCase {
    func testPulseIncludesTwelveEmptyWeeks() {
        let buckets = TradeAnalytics.weeklyPulse([], now: DisclosureDates.day("2026-10-06")!)
        XCTAssertEqual(buckets.count, 12)
        XCTAssertEqual(buckets.map(\.count), Array(repeating: 0, count: 12))
        XCTAssertFalse(TradeAnalytics.busierThanUsual(buckets))
    }

    func testActivityIncludesEmptyMonthsAndExcludesOldTrades() {
        XCTAssertEqual(TradeAnalytics.activityHistogram([]).count, 48)
        XCTAssertTrue(TradeAnalytics.delays([]).isEmpty)
        XCTAssertNil(TradeAnalytics.notable([], followed: [], previousMember: nil))
    }
}
