import XCTest
@testable import Consigliere

final class ConsigliereAPIProviderTests: XCTestCase {
    func testAPIConfigurationHasDefaultBackendURL() throws {
        let baseURL = try XCTUnwrap(AppConfiguration.apiBaseURL)

        XCTAssertEqual(baseURL.absoluteString, "https://consigliere-ingestion.chinonsoobeta.workers.dev")
    }

    func testDecodesNormalizedBackendDisclosure() throws {
        let json = """
        {
          "data": [{
            "id": "80565df0-f682-4f2c-a446-8a14fe94d86d",
            "politicianID": "P000197",
            "representative": "Nancy Pelosi",
            "symbol": "NVDA",
            "assetName": "NVIDIA Corporation",
            "type": "sale",
            "owner": "spouse",
            "amountRange": "$1,000,001–$5,000,000",
            "transactionDate": "2024-06-24",
            "filedDate": "2024-07-02",
            "sourceURL": "https://example.com/filing.pdf"
          }],
          "meta": { "provider": "quiver", "count": 1, "generatedAt": "2026-07-14T12:00:00Z" }
        }
        """

        let politicians = [Politician(
            id: "P000197", name: "Nancy Pelosi", party: "Democrat", state: "California",
            district: 11, chamber: .house, imageURL: nil, serviceStart: 1987
        )]
        let trades = try ConsigliereAPIClient.decodeDisclosures(Data(json.utf8), politicians: politicians)

        XCTAssertEqual(trades.count, 1)
        XCTAssertEqual(trades.first?.politicianID, "P000197")
        XCTAssertEqual(trades.first?.type, .sale)
        XCTAssertEqual(trades.first?.owner, .spouse)
        XCTAssertTrue(trades.first?.eventStudy.isEmpty == true)
    }

    func testResolvesApifyHonorificAndLastNameFirst() {
        let politicians = [Politician(
            id: "P000197", name: "Nancy Pelosi", party: "Democrat", state: "California",
            district: 11, chamber: .house, imageURL: nil, serviceStart: 1987
        )]
        let resolver = PoliticianIdentityResolver(politicians: politicians)

        XCTAssertEqual(resolver.resolve(providerID: nil, name: "Hon. Nancy Pelosi"), "P000197")
        XCTAssertEqual(resolver.resolve(providerID: nil, name: "Pelosi, Nancy"), "P000197")
    }

    func testResolvesProviderNamesWithMiddleNamesSuffixesAndCommonAliases() {
        let politicians = [
            Politician(id: "C001123", name: "Gilbert Ray Cisneros", party: "Democrat", state: "California", district: 31, chamber: .house, imageURL: nil, serviceStart: 2025),
            Politician(id: "V000139", name: "Matt Van Epps", party: "Republican", state: "Tennessee", district: 7, chamber: .house, imageURL: nil, serviceStart: 2025),
            Politician(id: "A000372", name: "Rick W. Allen", party: "Republican", state: "Georgia", district: 12, chamber: .house, imageURL: nil, serviceStart: 2015),
            Politician(id: "K000398", name: "Thomas H. Kean", party: "Republican", state: "New Jersey", district: 7, chamber: .house, imageURL: nil, serviceStart: 2023)
        ]
        let resolver = PoliticianIdentityResolver(politicians: politicians)

        XCTAssertEqual(resolver.resolve(providerID: nil, name: "Gilbert Cisneros"), "C001123")
        XCTAssertEqual(resolver.resolve(providerID: nil, name: "Matthew Robert Van Epps"), "V000139")
        XCTAssertEqual(resolver.resolve(providerID: nil, name: "Richard W. Allen"), "A000372")
        XCTAssertEqual(resolver.resolve(providerID: nil, name: "Thomas H. Kean Jr"), "K000398")
    }

    func testResolvesFuzzyProviderNamesAtSeventyFivePercentConfidence() {
        let politicians = [
            Politician(id: "C001123", name: "Gilbert Ray Cisneros", party: "Democrat", state: "California", district: 31, chamber: .house, imageURL: nil, serviceStart: 2025),
            Politician(id: "W000804", name: "Robert J. Wittman", party: "Republican", state: "Virginia", district: 1, chamber: .house, imageURL: nil, serviceStart: 2007)
        ]
        let resolver = PoliticianIdentityResolver(politicians: politicians)

        XCTAssertEqual(resolver.resolve(providerID: nil, name: "Gilbert Cizneros"), "C001123")
        XCTAssertEqual(resolver.resolve(providerID: nil, name: "Robrt Wittman"), "W000804")
    }

    func testFuzzyProviderNameRejectsEqualScoreAmbiguity() {
        let politicians = [
            Politician(id: "S000001", name: "Amy Smith", party: "Democrat", state: "Test", district: 1, chamber: .house, imageURL: nil, serviceStart: 2020),
            Politician(id: "S000002", name: "Ann Smith", party: "Republican", state: "Test", district: 2, chamber: .house, imageURL: nil, serviceStart: 2020)
        ]
        let resolver = PoliticianIdentityResolver(politicians: politicians)

        XCTAssertNil(resolver.resolve(providerID: nil, name: "A Smith"))
    }

    func testDebugMergeUsesPrototypeDisclosuresWhenBackendReturnsNone() {
        let fallback = PoliticianPrototypeData.disclosures

        let merged = HybridIntelligenceProvider.mergedDisclosures(primary: [], fallback: fallback)

        XCTAssertEqual(merged, fallback)
    }

    func testDebugMergeKeepsPrototypeDisclosuresWithBackendRows() throws {
        let backendTrade = try XCTUnwrap(makeTrade(politicianID: "L000560", symbol: "ABT"))
        let fallback = PoliticianPrototypeData.disclosures

        let merged = HybridIntelligenceProvider.mergedDisclosures(primary: [backendTrade], fallback: fallback)

        XCTAssertEqual(merged.count, fallback.count + 1)
        XCTAssertEqual(merged.first, backendTrade)
        XCTAssertTrue(Set(fallback).isSubset(of: Set(merged)))
    }

    private func makeTrade(politicianID: String, symbol: String) -> DisclosureTrade? {
        guard
            let transactionDate = ISO8601DateFormatter().date(from: "2026-07-08T12:00:00Z"),
            let filedDate = ISO8601DateFormatter().date(from: "2026-07-12T12:00:00Z"),
            let sourceURL = URL(string: "https://example.com/filing.pdf")
        else { return nil }
        return DisclosureTrade(
            id: UUID(),
            politicianID: politicianID,
            symbol: symbol,
            assetName: "\(symbol) Common Stock",
            type: .sale,
            owner: .member,
            amountRange: "$1,001 - $15,000",
            transactionDate: transactionDate,
            filedDate: filedDate,
            sourceURL: sourceURL,
            eventStudy: []
        )
    }
}
