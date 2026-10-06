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

    func testIdentityResolverUsesSeventyFivePercentNameMatchAndContext() {
        let politicians = [
            Politician(id: "P000197", name: "Nancy Pelosi", party: "Democratic", state: "California", district: 11, chamber: .house, imageURL: nil, serviceStart: 1987),
            Politician(id: "P999999", name: "Nancy Peloso", party: "Republican", state: "Texas", district: 4, chamber: .house, imageURL: nil, serviceStart: 2025)
        ]
        let resolver = PoliticianIdentityResolver(politicians: politicians)

        XCTAssertEqual(
            resolver.resolve(
                providerID: nil,
                name: "Nancy D. Pelosi",
                chamber: .house,
                party: "Democratic",
                state: "CA",
                district: 11
            ),
            "P000197"
        )
        XCTAssertNil(
            resolver.resolve(
                providerID: nil,
                name: "Nancy Pelosi",
                chamber: .senate,
                party: "Democratic",
                state: "CA",
                district: 11
            )
        )
    }

    func testDecodesPaginatedDisclosureResponse() throws {
        let json = """
        {
          "data": [{
            "id": "80565df0-f682-4f2c-a446-8a14fe94d86d",
            "politicianID": null,
            "representative": "Nancy D. Pelosi",
            "symbol": "NVDA",
            "assetName": "NVIDIA Corporation",
            "type": "sale",
            "owner": "spouse",
            "amountRange": "$1,000,001–$5,000,000",
            "transactionDate": "2024-06-24",
            "filedDate": "2024-07-02",
            "sourceURL": "https://example.com/filing.pdf",
            "chamber": "house",
            "party": "Democratic",
            "state": "CA",
            "district": 11,
            "matchConfidence": 0.95,
            "confidence": 0.95,
            "rankingScore": 0.84,
            "rankingReasons": ["Large reported value range"],
            "whyItMatters": "A newly public disclosure.",
            "assetType": "OP",
            "description": "Call options; Strike price $340; Expires 10/16/2026"
          }],
          "meta": {
            "count": 1,
            "generatedAt": "2026-07-16T12:00:00Z",
            "nextCursor": {
              "date": "2024-06-24",
              "id": "80565df0-f682-4f2c-a446-8a14fe94d86d"
            }
          }
        }
        """
        let politicians = [Politician(
            id: "P000197", name: "Nancy Pelosi", party: "Democratic", state: "California",
            district: 11, chamber: .house, imageURL: nil, serviceStart: 1987
        )]

        let page = try ConsigliereAPIClient.decodeDisclosurePage(Data(json.utf8), politicians: politicians)

        XCTAssertEqual(page.disclosures.first?.politicianID, "P000197")
        XCTAssertEqual(page.nextCursor?.date, "2024-06-24")
        XCTAssertEqual(page.disclosures.first?.isOption, true)
        XCTAssertEqual(page.disclosures.first?.assetDescription, "Call options; Strike price $340; Expires 10/16/2026")
    }

    func testEveryRosterStateHasACode() throws {
        let roster = try CongressRosterLoader.load()
        let missing = Set(roster.map(\.state).filter { StateCodes.code(for: $0) == nil })
        XCTAssertEqual(missing, [])
    }

    func testDistrictIsATieBreakerNotAHardConstraint() {
        let politicians = [
            Politician(id: "M001218", name: "Rich McCormick", party: "Republican", state: "Georgia", district: 7, chamber: .house, imageURL: nil, serviceStart: 2023),
            Politician(id: "D000999", name: "Pat Delaney", party: "Democratic", state: "Oklahoma", district: 1, chamber: .house, imageURL: nil, serviceStart: 2025)
        ]
        let resolver = PoliticianIdentityResolver(politicians: politicians)

        // Providers lag redistricting, so a stale district must not reject an otherwise exact match.
        XCTAssertEqual(resolver.resolve(providerID: nil, name: "Richard McCormick", chamber: .house, state: "GA", district: 6), "M001218")
        XCTAssertNil(resolver.resolve(providerID: nil, name: "Richard McCormick", chamber: .house, state: "OK"))
    }

    func testUnresolvedDisclosuresAreRetained() throws {
        let json = """
        {
          "data": [{
            "id": "80565df0-f682-4f2c-a446-8a14fe94d86d",
            "politicianID": null,
            "representative": "Mark Green",
            "symbol": "AAPL",
            "assetName": "Apple Inc.",
            "type": "purchase",
            "owner": "member",
            "amountRange": "$1,001 - $15,000",
            "transactionDate": "2026-08-30",
            "filedDate": "2026-09-14",
            "sourceURL": "https://example.com/filing.pdf",
            "chamber": "house",
            "confidence": 0.95,
            "rankingScore": 0.4,
            "rankingReasons": [],
            "whyItMatters": ""
          }],
          "meta": { "nextCursor": null }
        }
        """
        let page = try ConsigliereAPIClient.decodeDisclosurePage(Data(json.utf8), politicians: [])

        XCTAssertEqual(page.disclosures.count, 1)
        XCTAssertNil(page.disclosures.first?.politicianID)
        XCTAssertEqual(page.disclosures.first?.representative, "Mark Green")
        XCTAssertEqual(page.disclosures.first?.chamber, .house)
    }

    func testDecodesIdentitySummariesAndDatePrecision() throws {
        let json = """
        {
          "data": {
            "instruments": [],
            "intelligence": [{
              "id": "7908361b-75cd-4eaa-9715-a899a427593f",
              "source": "houseDisclosure",
              "title": "Nancy Pelosi disclosed a sale in NVDA",
              "body": "NVIDIA",
              "author": "Nancy Pelosi",
              "politicianID": "P000197",
              "timePrecision": "date",
              "publishedAt": "2026-09-14T12:00:00Z",
              "retrievedAt": "2026-09-18T00:00:00Z",
              "transactionDate": "2026-08-14T12:00:00Z",
              "sourceURL": "https://example.com/filing.pdf",
              "mentionedSymbols": ["NVDA"],
              "topics": [],
              "impact": "low",
              "confidence": 0.95,
              "explanation": "A House filing reported a sale.",
              "freshness": "delayed",
              "rankingScore": 0.4,
              "rankingReasons": []
            }],
            "disclosures": [],
            "sourceHealth": [],
            "coverage": [],
            "politicianSummaries": [{ "politicianID": "P000197", "records": 42, "earliest": "2020-01-02", "latest": "2026-09-14" }],
            "unmatchedFilers": [{ "representative": "Mark Green", "chamber": "house", "records": 3, "latest": "2026-09-01" }],
            "pendingFilings": [{
              "id": "f1", "representative": "Hon. Nancy Pelosi", "politicianID": "P000197", "chamber": "house",
              "filedDate": "2026-10-02", "sourceURL": "https://example.com/20035553.pdf",
              "documentID": "20035553", "status": "pending-extraction"
            }]
          }
        }
        """
        let snapshot = try ConsigliereAPIClient.decodeSnapshot(Data(json.utf8), politicians: [])
        let event = try XCTUnwrap(snapshot.events.first)

        XCTAssertEqual(event.politicianID, "P000197")
        XCTAssertTrue(event.isDateOnly)
        XCTAssertEqual(snapshot.politicianSummaries.first?.records, 42)
        XCTAssertEqual(snapshot.unmatchedFilers.first?.representative, "Mark Green")
        XCTAssertEqual(snapshot.pendingFilings.first?.documentID, "20035553")
    }

    func testOlderSnapshotsWithoutIdentityFieldsStillDecode() throws {
        let json = """
        { "data": { "instruments": [], "intelligence": [], "disclosures": [], "sourceHealth": [], "coverage": [] } }
        """
        let snapshot = try ConsigliereAPIClient.decodeSnapshot(Data(json.utf8), politicians: [])
        XCTAssertTrue(snapshot.politicianSummaries.isEmpty)
        XCTAssertTrue(snapshot.pendingFilings.isEmpty)
    }

    func testDisclosureDatesDisplayAsCalendarDaysInUTC() throws {
        let date = try XCTUnwrap(DisclosureDates.day("2026-09-14"))
        let components = DisclosureDates.calendar.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual(components.day, 14)
        XCTAssertEqual(DisclosureDates.dayFormatter.string(from: date), "2026-09-14")
    }
}
