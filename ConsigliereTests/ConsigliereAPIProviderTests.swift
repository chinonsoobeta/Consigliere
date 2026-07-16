import Darwin
import XCTest
@testable import Consigliere

final class ConsigliereAPIProviderTests: XCTestCase {
    func testDecodesApifyDatasetSnapshotAndResolvesPolitician() throws {
        let json = """
        [{
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
        }]
        """
        let politicians = [Politician(
            id: "P000197", name: "Nancy Pelosi", party: "Democrat", state: "California",
            district: 11, chamber: .house, imageURL: nil, serviceStart: 1987
        )]

        let snapshot = try ApifyAPIClient.decodeSnapshot(Data(json.utf8), politicians: politicians)

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

    func testMissingConfigurationErrorMentionsApifyKeys() {
        XCTAssertEqual(
            LiveProviderError.missingApifyConfiguration.localizedDescription,
            "The live intelligence service is not configured. Set APIFY_RUN_URL, or set APIFY_API_TOKEN and APIFY_ACTOR_ID, and try again."
        )
    }

    func testAppConfigurationUsesApifyKeys() {
        withApifyEnvironment([
            AppConfiguration.apifyTokenKey: "token-123",
            AppConfiguration.apifyActorIDKey: "user/actor"
        ]) {
            XCTAssertEqual(AppConfiguration.apify, ApifyConfiguration(token: "token-123", source: .actor(id: "user/actor")))
        }
    }

    func testAppConfigurationUsesApifyRunURL() {
        withApifyEnvironment([
            AppConfiguration.apifyRunURLKey: "https://api.apify.com/v2/actor-runs/run-123?token=token-123"
        ]) {
            XCTAssertEqual(AppConfiguration.apify, ApifyConfiguration(token: "token-123", source: .run(id: "run-123")))
        }
    }

    func testAppConfigurationRequiresRunnableApifySource() {
        withApifyEnvironment([AppConfiguration.apifyTokenKey: "token-123"]) {
            XCTAssertNil(AppConfiguration.apify)
        }
    }

    func testApifySnapshotRequestUsesActorEndpoint() throws {
        let client = ApifyAPIClient(configuration: ApifyConfiguration(token: "token-123", source: .actor(id: "user/actor")))

        let request = try client.makeSnapshotRequest()

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "api.apify.com")
        XCTAssertEqual(request.url?.path, "/v2/actors/user~actor/run-sync-get-dataset-items")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertTrue(request.url?.query?.contains("format=json") == true)
        XCTAssertTrue(request.url?.query?.contains("clean=true") == true)
    }

    func testApifyRunRequestUsesRunEndpoint() throws {
        let client = ApifyAPIClient(configuration: ApifyConfiguration(token: "token-123", source: .run(id: "run-123")))

        let runRequest = try client.makeRunRequest()
        let datasetRequest = try client.makeDatasetItemsRequest(datasetID: "dataset-123")

        XCTAssertEqual(runRequest.url?.path, "/v2/actor-runs/run-123")
        XCTAssertEqual(runRequest.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(datasetRequest.url?.path, "/v2/datasets/dataset-123/items")
        XCTAssertEqual(datasetRequest.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertTrue(datasetRequest.url?.query?.contains("format=json") == true)
        XCTAssertTrue(datasetRequest.url?.query?.contains("clean=true") == true)
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

    private func withApifyEnvironment(_ values: [String: String], body: () -> Void) {
        let previousValues = Dictionary(
            uniqueKeysWithValues: AppConfiguration.supportedApifyKeys.map { key in
                (key, getenv(key).map { String(cString: $0) })
            }
        )

        AppConfiguration.supportedApifyKeys.forEach { unsetenv($0) }
        values.forEach { key, value in setenv(key, value, 1) }

        defer {
            for (key, previousValue) in previousValues {
                if let previousValue {
                    setenv(key, previousValue, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        body()
    }
}
