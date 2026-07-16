import Foundation

enum ProviderFactory {
    static func makeDefault() -> any IntelligenceProvider {
        guard let baseURL = AppConfiguration.apiBaseURL else { return MockIntelligenceProvider() }
        #if DEBUG
        let fallbackOnFailure = true
        #else
        let fallbackOnFailure = false
        #endif
        return HybridIntelligenceProvider(
            apiClient: ConsigliereAPIClient(baseURL: baseURL),
            fallbackOnFailure: fallbackOnFailure
        )
    }
}

enum AppConfiguration {
    private static let defaultAPIBaseURL = URL(string: "https://consigliere-ingestion.chinonsoobeta.workers.dev")!

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
        else { return defaultAPIBaseURL }
        return URL(string: value)
    }
}

struct HybridIntelligenceProvider: IntelligenceProvider {
    private let prototype = MockIntelligenceProvider()
    let apiClient: ConsigliereAPIClient
    let fallbackOnFailure: Bool

    func instruments() async throws -> [MarketInstrument] { try await prototype.instruments() }
    func events() async throws -> [MarketEvent] { try await prototype.events() }
    func holdings() async throws -> [PortfolioHolding] { try await prototype.holdings() }
    func politicians() async throws -> [Politician] { try await prototype.politicians() }
    func modelPortfolios() async throws -> [PoliticianModelPortfolio] { try await prototype.modelPortfolios() }

    func disclosures() async throws -> [DisclosureTrade] {
        do {
            let roster = try await prototype.politicians()
            let backendDisclosures = try await apiClient.disclosures(politicians: roster)
            return Self.mergedDisclosures(
                primary: backendDisclosures,
                fallback: try await prototype.disclosures()
            )
        } catch {
            return try await prototype.disclosures()
        }
    }

    static func mergedDisclosures(primary: [DisclosureTrade], fallback: [DisclosureTrade]) -> [DisclosureTrade] {
        guard !primary.isEmpty else { return fallback }
        var seen = Set(primary.map { DisclosureIdentity(trade: $0) })
        let uniqueFallback = fallback.filter { seen.insert(DisclosureIdentity(trade: $0)).inserted }
        return primary + uniqueFallback
    }
}

private struct DisclosureIdentity: Hashable {
    let politicianID: String
    let symbol: String
    let assetName: String
    let type: DisclosureTransactionType
    let owner: DisclosureOwner
    let amountRange: String
    let transactionDate: Date
    let filedDate: Date
    let sourceURL: URL

    init(trade: DisclosureTrade) {
        politicianID = trade.politicianID
        symbol = trade.symbol
        assetName = trade.assetName
        type = trade.type
        owner = trade.owner
        amountRange = trade.amountRange
        transactionDate = trade.transactionDate
        filedDate = trade.filedDate
        sourceURL = trade.sourceURL
    }
}

struct ConsigliereAPIClient: Sendable {
    enum ClientError: Error {
        case invalidResponse
        case serverStatus(Int)
        case invalidRecord(String)
    }

    let baseURL: URL

    func disclosures(politicians: [Politician]) async throws -> [DisclosureTrade] {
        let url = baseURL.appending(path: "v1/disclosures")
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Consigliere/1.0 CFNetwork", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else { throw ClientError.serverStatus(httpResponse.statusCode) }
        return try Self.decodeDisclosures(data, politicians: politicians)
    }

    static func decodeDisclosures(_ data: Data, politicians: [Politician]) throws -> [DisclosureTrade] {
        let response = try JSONDecoder().decode(DisclosureResponse.self, from: data)
        let resolver = PoliticianIdentityResolver(politicians: politicians)
        return response.data.compactMap { record in
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
                freshness: .delayed
            )
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value + (value.contains("T") ? "" : "T12:00:00Z"))
    }
}

private struct DisclosureResponse: Decodable {
    let data: [DisclosureRecord]
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
}

struct PoliticianIdentityResolver {
    private static let fuzzyMatchThreshold = 0.75

    private let politicians: [Politician]
    private let IDs: Set<String>
    private let exactMatches: [String: Politician]

    init(politicians: [Politician]) {
        self.politicians = politicians
        IDs = Set(politicians.map(\.id))
        exactMatches = Dictionary(politicians.map { (Self.normalize($0.name), $0) }, uniquingKeysWith: { current, _ in current })
    }

    func resolve(providerID: String?, name: String) -> String? {
        if let providerID, IDs.contains(providerID) { return providerID }
        let normalized = Self.normalize(name)
        if let exact = exactMatches[normalized] { return exact.id }
        let components = Self.identityComponents(normalized)
        guard let givenName = components.first, let surname = components.last else { return nil }
        let givenAndSurnameMatches = politicians.filter {
            let candidate = Self.identityComponents(Self.normalize($0.name))
            guard let candidateGivenName = candidate.first, candidate.last == surname else { return false }
            return Self.canonicalGivenName(String(candidateGivenName)) == Self.canonicalGivenName(String(givenName))
        }
        if givenAndSurnameMatches.count == 1 { return givenAndSurnameMatches[0].id }

        guard let firstInitial = givenName.first else { return nil }
        let candidates = politicians.filter {
            let candidate = Self.identityComponents(Self.normalize($0.name))
            return candidate.first?.first == firstInitial && candidate.last == surname
        }
        if candidates.count == 1 { return candidates[0].id }
        return fuzzyMatch(normalizedName: normalized)?.id
    }

    private func fuzzyMatch(normalizedName: String) -> Politician? {
        let rankedMatches = politicians
            .map { politician in
                (politician, Self.similarity(normalizedName, Self.normalize(politician.name)))
            }
            .filter { $0.1 >= Self.fuzzyMatchThreshold }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.0.id < rhs.0.id }
                return lhs.1 > rhs.1
            }

        guard let best = rankedMatches.first else { return nil }
        if rankedMatches.dropFirst().first?.1 == best.1 { return nil }
        return best.0
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
            "val": "valerie"
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

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
        let distance = levenshteinDistance(lhs, rhs)
        let editSimilarity = 1 - Double(distance) / Double(max(lhs.count, rhs.count))
        return max(editSimilarity, tokenSimilarity(lhs, rhs))
    }

    private static func tokenSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = Set(lhs.split(separator: " "))
        let rhsTokens = Set(rhs.split(separator: " "))
        guard !lhsTokens.isEmpty || !rhsTokens.isEmpty else { return 1 }
        let sharedCount = lhsTokens.intersection(rhsTokens).count
        return Double(sharedCount * 2) / Double(lhsTokens.count + rhsTokens.count)
    }

    private static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)
        if lhsCharacters.isEmpty { return rhsCharacters.count }
        if rhsCharacters.isEmpty { return lhsCharacters.count }

        var previous = Array(0...rhsCharacters.count)
        var current = Array(repeating: 0, count: rhsCharacters.count + 1)

        for lhsIndex in 1...lhsCharacters.count {
            current[0] = lhsIndex
            for rhsIndex in 1...rhsCharacters.count {
                let substitutionCost = lhsCharacters[lhsIndex - 1] == rhsCharacters[rhsIndex - 1] ? 0 : 1
                current[rhsIndex] = min(
                    previous[rhsIndex] + 1,
                    current[rhsIndex - 1] + 1,
                    previous[rhsIndex - 1] + substitutionCost
                )
            }
            swap(&previous, &current)
        }

        return previous[rhsCharacters.count]
    }
}
