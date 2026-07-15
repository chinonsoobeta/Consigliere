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
    static var apiBaseURL: URL? {
        let environmentValue = ProcessInfo.processInfo.environment["CONSILIERE_API_BASE_URL"]
        let bundleValue = Bundle.main.object(forInfoDictionaryKey: "CONSILIERE_API_BASE_URL") as? String
        guard let value = [environmentValue, bundleValue]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty && !$0.contains("$(") })
        else { return nil }
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
            return try await apiClient.disclosures(politicians: roster)
        } catch {
            guard fallbackOnFailure else { throw error }
            // Debug builds remain usable before the backend is deployed or while it is unavailable.
            return try await prototype.disclosures()
        }
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
        let (data, response) = try await URLSession.shared.data(from: url)
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
        return candidates.count == 1 ? candidates[0].id : nil
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
}
