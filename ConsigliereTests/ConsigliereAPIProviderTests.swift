import XCTest
@testable import Consigliere

final class ConsigliereAPIProviderTests: XCTestCase {
    func testProductionAPIHasAUsableDefault() throws {
        let baseURL = try XCTUnwrap(AppConfiguration.apiBaseURL)
        XCTAssertEqual(baseURL.scheme, "https")
        XCTAssertEqual(baseURL.host, "consigliere-ingestion.chinonsoobeta.workers.dev")
    }

    func testDecodesLiveSnapshotAndResolvesPolitician() throws {
        let json = """
        {
          "data": {
            "instruments": [],
            "intelligence": [{
              "id": "7908361b-75cd-4eaa-9715-a899a427593f",
              "source": "truthSocial",
              "title": "A political statement was published",
              "body": "Policy statement",
              "author": "Public official",
              "publishedAt": "2026-07-16T12:00:00.123Z",
              "retrievedAt": "2026-07-16T12:00:05.123Z",
              "transactionDate": null,
              "sourceURL": "https://example.com/post",
              "mentionedSymbols": [],
              "topics": ["Trade policy"],
              "impact": "moderate",
              "confidence": 0.8,
              "explanation": "Observed context, not causation.",
              "reaction": null,
              "freshness": "live",
              "rankingScore": 0.61,
              "rankingReasons": ["New political statement"]
            }],
            "disclosures": [{
              "id": "80565df0-f682-4f2c-a446-8a14fe94d86d",
              "politicianID": null,
              "representative": "Hon. Nancy Pelosi",
              "symbol": "NVDA",
              "assetName": "NVIDIA Corporation",
              "type": "sale",
              "owner": "spouse",
              "amountRange": "$1,000,001–$5,000,000",
              "transactionDate": "2024-06-24",
              "filedDate": "2024-07-02",
              "sourceURL": "https://example.com/filing.pdf",
              "confidence": 0.95,
              "rankingScore": 0.84,
              "rankingReasons": ["Large reported value range"],
              "whyItMatters": "A newly public disclosure."
            }],
            "sourceHealth": [],
            "coverage": [{
              "chamber": "house",
              "earliest": "2024-07-02",
              "latest": "2024-07-02",
              "records": 1,
              "completeness": "available-records"
            }]
          }
        }
        """
        let politicians = [Politician(
            id: "P000197", name: "Nancy Pelosi", party: "Democrat", state: "California",
            district: 11, chamber: .house, imageURL: nil, serviceStart: 1987
        )]

        let snapshot = try ConsigliereAPIClient.decodeSnapshot(Data(json.utf8), politicians: politicians)

        XCTAssertEqual(snapshot.disclosures.count, 1)
        XCTAssertEqual(snapshot.disclosures.first?.politicianID, "P000197")
        XCTAssertEqual(snapshot.disclosures.first?.rankingScore, 0.84)
        XCTAssertEqual(snapshot.coverage.first?.records, 1)
        XCTAssertEqual(snapshot.events.first?.rankingReasons, ["New political statement"])
        XCTAssertEqual(try XCTUnwrap(snapshot.events.first).retrievalLatency, 5, accuracy: 0.001)
    }

    func testUnconfiguredProviderNeverReturnsFixtures() async {
        do {
            _ = try await UnconfiguredIntelligenceProvider().snapshot()
            XCTFail("Expected missing configuration to fail")
        } catch {
            XCTAssertTrue(error is LiveProviderError)
        }
    }

    func testResolvesProviderNamesWithAliasesAndSuffixes() {
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

    func testIdentityResolverRejectsAmbiguousInitialAndSurname() {
        let politicians = [
            Politician(id: "S000001", name: "Amy Smith", party: "Democrat", state: "Test", district: 1, chamber: .house, imageURL: nil, serviceStart: 2020),
            Politician(id: "S000002", name: "Ann Smith", party: "Republican", state: "Test", district: 2, chamber: .house, imageURL: nil, serviceStart: 2020)
        ]
        let resolver = PoliticianIdentityResolver(politicians: politicians)

        XCTAssertNil(resolver.resolve(providerID: nil, name: "A Smith"))
    }
}
