import Foundation

enum ProviderFactory {
    static func makeDefault() -> any IntelligenceProvider {
        guard let baseURL = AppConfiguration.apiBaseURL else {
            return UnconfiguredIntelligenceProvider()
        }
        return ConsigliereAPIClient(baseURL: baseURL)
    }
}

enum AppConfiguration {
    static var apiBaseURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        let environmentValues = [
            environment["CONSIGLIERE_API_BASE_URL"],
            environment["CONSILIERE_API_BASE_URL"]
        ]
        let bundleValues = [
            Bundle.main.object(forInfoDictionaryKey: "CONSIGLIERE_API_BASE_URL") as? String,
            Bundle.main.object(forInfoDictionaryKey: "CONSILIERE_API_BASE_URL") as? String
        ]
        guard let value = (environmentValues + bundleValues)
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty && !$0.contains("$(") })
        else { return nil }
        guard let url = URL(string: value), let host = url.host?.lowercased() else {
            return nil
        }
        let isSecure = url.scheme?.lowercased() == "https"
        let isLocalDevelopment = url.scheme?.lowercased() == "http"
            && (host == "localhost" || host == "127.0.0.1" || host == "::1")
        guard isSecure || isLocalDevelopment else { return nil }
        return url
    }

}

struct ConsigliereAPIClient: IntelligenceProvider {
    enum ClientError: LocalizedError {
        case invalidResponse
        case serverStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "The intelligence service returned an invalid response."
            case .serverStatus(let status): "The intelligence service returned HTTP \(status)."
            }
        }
    }

    let baseURL: URL

    func snapshot() async throws -> IntelligenceSnapshot {
        let url = baseURL.appending(path: "v1/snapshot")
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ClientError.serverStatus(httpResponse.statusCode)
        }
        return try Self.decodeSnapshot(data, politicians: CongressRosterLoader.load())
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
        let response = try decoder.decode(SnapshotResponse.self, from: data)
        let resolver = PoliticianIdentityResolver(politicians: politicians)
        let disclosures = response.data.disclosures.compactMap { record -> DisclosureTrade? in
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
            instruments: response.data.instruments,
            events: response.data.intelligence,
            politicians: politicians,
            disclosures: disclosures,
            sourceHealth: response.data.sourceHealth,
            coverage: response.data.coverage
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value + (value.contains("T") ? "" : "T12:00:00Z"))
    }
}

private struct SnapshotResponse: Decodable {
    let data: SnapshotData
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
