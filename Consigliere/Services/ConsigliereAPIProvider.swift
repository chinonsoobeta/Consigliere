import Foundation

enum ProviderFactory {
    static func makeDefault() -> any IntelligenceProvider {
        guard let configuration = AppConfiguration.apify else {
            return UnconfiguredIntelligenceProvider()
        }
        return ApifyAPIClient(configuration: configuration)
    }
}

enum AppConfiguration {
    static let apifyTokenKey = "APIFY_API_TOKEN"
    static let apifyActorIDKey = "APIFY_ACTOR_ID"
    static let apifyRunURLKey = "APIFY_RUN_URL"
    static let supportedApifyKeys = [apifyTokenKey, apifyActorIDKey, apifyRunURLKey]

    static var apify: ApifyConfiguration? {
        if let runURLValue = configuredValue(forKey: apifyRunURLKey),
           let runURL = URL(string: runURLValue),
           let runID = Self.runID(from: runURL) {
            let token = configuredValue(forKey: apifyTokenKey) ?? Self.token(from: runURL)
            guard let token else { return nil }
            return ApifyConfiguration(token: token, source: .run(id: runID))
        }

        let token = configuredValue(forKey: apifyTokenKey)
        let actorID = configuredValue(forKey: apifyActorIDKey)
        guard let token, let actorID else { return nil }
        return ApifyConfiguration(token: token, source: .actor(id: actorID))
    }

    private static func configuredValue(forKey key: String) -> String? {
        let environment = ProcessInfo.processInfo.environment[key]
        let bundle = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return [environment, bundle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.contains("$(") }
    }

    private static func runID(from url: URL) -> String? {
        let components = url.pathComponents
        guard let index = components.firstIndex(of: "actor-runs"), components.indices.contains(index + 1) else {
            return nil
        }
        return components[index + 1]
    }

    private static func token(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "token" }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ApifyConfiguration: Equatable {
    enum Source: Equatable {
        case actor(id: String)
        case run(id: String)
    }

    let token: String
    let source: Source
    var baseURL = URL(string: "https://api.apify.com")!
}

struct ApifyAPIClient: IntelligenceProvider {
    enum ClientError: LocalizedError {
        case invalidRequest
        case invalidResponse
        case emptyDataset
        case missingDataset
        case serverStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidRequest: "The Apify actor configuration is invalid."
            case .invalidResponse: "Apify returned an invalid intelligence dataset."
            case .emptyDataset: "The Apify actor did not return any intelligence records."
            case .missingDataset: "The Apify run does not have a default dataset."
            case .serverStatus(let status): "Apify returned HTTP \(status)."
            }
        }
    }

    let configuration: ApifyConfiguration

    func snapshot() async throws -> IntelligenceSnapshot {
        let data = try await snapshotData()
        return try Self.decodeSnapshot(data, politicians: CongressRosterLoader.load())
    }

    private func snapshotData() async throws -> Data {
        switch configuration.source {
        case .actor:
            let (data, response) = try await URLSession.shared.data(for: try makeSnapshotRequest())
            try validate(response)
            return data
        case .run:
            let (runData, runResponse) = try await URLSession.shared.data(for: try makeRunRequest())
            try validate(runResponse)
            let run = try JSONDecoder().decode(ApifyRunResponse.self, from: runData)
            guard let datasetID = run.data.defaultDatasetID else { throw ClientError.missingDataset }
            let (datasetData, datasetResponse) = try await URLSession.shared.data(for: try makeDatasetItemsRequest(datasetID: datasetID))
            try validate(datasetResponse)
            return datasetData
        }
    }

    func makeSnapshotRequest() throws -> URLRequest {
        guard case .actor(let actorID) = configuration.source else { throw ClientError.invalidRequest }
        let actorPathComponent = actorID.replacingOccurrences(of: "/", with: "~")
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/v2/actors/\(actorPathComponent)/run-sync-get-dataset-items"
        components?.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "clean", value: "true")
        ]
        guard let url = components?.url else { throw ClientError.invalidRequest }

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = Data("{}".utf8)
        return request
    }

    func makeRunRequest() throws -> URLRequest {
        guard case .run(let runID) = configuration.source else { throw ClientError.invalidRequest }
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/v2/actor-runs/\(runID)"
        guard let url = components?.url else { throw ClientError.invalidRequest }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    func makeDatasetItemsRequest(datasetID: String) throws -> URLRequest {
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/v2/datasets/\(datasetID)/items"
        components?.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "clean", value: "true")
        ]
        guard let url = components?.url else { throw ClientError.invalidRequest }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ClientError.serverStatus(httpResponse.statusCode)
        }
    }

    static func decodeSnapshot(_ data: Data, politicians: [Politician]) throws -> IntelligenceSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            if let date = ISO8601DateFormatter().date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
        let items = try decoder.decode([ApifySnapshotItem].self, from: data)
        guard let snapshotData = items.compactMap(\.snapshotData).first else {
            throw items.isEmpty ? ClientError.emptyDataset : ClientError.invalidResponse
        }
        let resolver = PoliticianIdentityResolver(politicians: politicians)
        let disclosures = snapshotData.disclosures.compactMap { record -> DisclosureTrade? in
            guard
                let id = UUID(uuidString: record.id),
                let politicianID = resolver.resolve(providerID: record.politicianID, name: record.representative),
                let transactionDate = parseDate(record.transactionDate),
                let filedDate = parseDate(record.filedDate),
                let type = DisclosureTransactionType(rawValue: record.type),
                let owner = DisclosureOwner(rawValue: record.owner),
                let sourceURL = URL(string: record.sourceURL)
            else { return nil }
            return DisclosureTrade(
                id: id,
                politicianID: politicianID,
                symbol: record.symbol,
                assetName: record.assetName,
                type: type,
                owner: owner,
                amountRange: record.amountRange,
                transactionDate: transactionDate,
                filedDate: filedDate,
                sourceURL: sourceURL,
                eventStudy: [],
                freshness: .delayed,
                confidence: record.confidence,
                rankingScore: record.rankingScore,
                rankingReasons: record.rankingReasons,
                whyItMatters: record.whyItMatters
            )
        }
        return IntelligenceSnapshot(
            instruments: snapshotData.instruments,
            events: snapshotData.intelligence,
            politicians: politicians,
            disclosures: disclosures,
            sourceHealth: snapshotData.sourceHealth,
            coverage: snapshotData.coverage
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value + (value.contains("T") ? "" : "T12:00:00Z"))
    }
}

private struct ApifyRunResponse: Decodable {
    let data: ApifyRun
}

private struct ApifyRun: Decodable {
    let defaultDatasetID: String?

    private enum CodingKeys: String, CodingKey {
        case defaultDatasetID = "defaultDatasetId"
    }
}

private struct ApifySnapshotItem: Decodable {
    let data: SnapshotData?
    let instruments: [MarketInstrument]?
    let intelligence: [MarketEvent]?
    let disclosures: [DisclosureRecord]?
    let sourceHealth: [SourceHealth]?
    let coverage: [DisclosureCoverageSummary]?

    var snapshotData: SnapshotData? {
        if let data { return data }
        guard
            let instruments,
            let intelligence,
            let disclosures,
            let sourceHealth,
            let coverage
        else { return nil }
        return SnapshotData(
            instruments: instruments,
            intelligence: intelligence,
            disclosures: disclosures,
            sourceHealth: sourceHealth,
            coverage: coverage
        )
    }
}

private struct SnapshotData: Decodable {
    let instruments: [MarketInstrument]
    let intelligence: [MarketEvent]
    let disclosures: [DisclosureRecord]
    let sourceHealth: [SourceHealth]
    let coverage: [DisclosureCoverageSummary]
}

private struct DisclosureRecord: Decodable {
    let id: String
    let politicianID: String?
    let representative: String
    let symbol: String
    let assetName: String
    let type: String
    let owner: String
    let amountRange: String
    let transactionDate: String
    let filedDate: String
    let sourceURL: String
    let confidence: Double
    let rankingScore: Double
    let rankingReasons: [String]
    let whyItMatters: String
}

struct PoliticianIdentityResolver {
    private let politicians: [Politician]
    private let IDs: Set<String>
    private let exactMatches: [String: Politician]

    init(politicians: [Politician]) {
        self.politicians = politicians
        IDs = Set(politicians.map(\.id))
        exactMatches = Dictionary(
            politicians.map { (Self.normalize($0.name), $0) },
            uniquingKeysWith: { current, _ in current }
        )
    }

    func resolve(providerID: String?, name: String) -> String? {
        if let providerID, IDs.contains(providerID) { return providerID }
        let normalized = Self.normalize(name)
        if let exact = exactMatches[normalized] { return exact.id }
        let components = Self.identityComponents(normalized)
        guard let givenName = components.first, let surname = components.last else { return nil }
        let matches = politicians.filter {
            let candidate = Self.identityComponents(Self.normalize($0.name))
            guard let candidateGiven = candidate.first, candidate.last == surname else { return false }
            return Self.canonicalGivenName(String(candidateGiven)) == Self.canonicalGivenName(String(givenName))
        }
        if matches.count == 1 { return matches[0].id }
        guard let firstInitial = givenName.first else { return nil }
        let initialMatches = politicians.filter {
            let candidate = Self.identityComponents(Self.normalize($0.name))
            return candidate.first?.first == firstInitial && candidate.last == surname
        }
        return initialMatches.count == 1 ? initialMatches[0].id : nil
    }

    private static func identityComponents(_ normalizedName: String) -> [Substring] {
        let ignored: Set<Substring> = ["dr", "jr", "sr", "ii", "iii", "iv"]
        return normalizedName.split(separator: " ").filter { !ignored.contains($0) }
    }

    private static func canonicalGivenName(_ value: String) -> String {
        let aliases = [
            "bill": "william", "bob": "robert", "chris": "christopher", "chuck": "charles",
            "dan": "daniel", "don": "donald", "ed": "edward", "jack": "john",
            "jim": "james", "joe": "joseph", "ken": "kenneth", "matt": "matthew",
            "mike": "michael", "rick": "richard", "ron": "ronald", "tom": "thomas",
            "val": "valerie", "gilbert": "gilbert", "gil": "gilbert"
        ]
        return aliases[value] ?? value
    }

    private static func normalize(_ value: String) -> String {
        var candidate = value
        if let comma = candidate.firstIndex(of: ",") {
            let surname = candidate[..<comma]
            let given = candidate[candidate.index(after: comma)...]
            candidate = "\(given) \(surname)"
        }
        let honorifics: Set<String> = ["hon", "honorable", "sen", "senator", "rep", "representative"]
        return candidate.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !honorifics.contains($0.lowercased()) }
            .joined(separator: " ")
            .lowercased()
    }

}
