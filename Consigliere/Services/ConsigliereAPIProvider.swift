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
    private static let productionAPIBaseURL = URL(
        string: "https://consigliere-ingestion.chinonsoobeta.workers.dev"
    )!

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
        else { return productionAPIBaseURL }
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

    func disclosures(query: DisclosureQuery, politicians: [Politician]) async throws -> DisclosurePage {
        var components = URLComponents(
            url: baseURL.appending(path: "v1/disclosures"),
            resolvingAgainstBaseURL: false
        )
        var items = [
            URLQueryItem(name: "date_basis", value: query.dateBasis.rawValue),
            URLQueryItem(name: "limit", value: String(min(max(query.limit, 1), 500)))
        ]
        if let representative = query.representative {
            items.append(URLQueryItem(name: "representative", value: representative))
        }
        if let chamber = query.chamber {
            items.append(URLQueryItem(name: "chamber", value: chamber.rawValue))
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        if let from = query.from {
            items.append(URLQueryItem(name: "from", value: formatter.string(from: from)))
        }
        if let to = query.to {
            items.append(URLQueryItem(name: "to", value: formatter.string(from: to)))
        }
        if let cursor = query.cursor {
            items.append(URLQueryItem(name: "cursor_date", value: cursor.date))
            items.append(URLQueryItem(name: "cursor_id", value: cursor.id))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ClientError.serverStatus(httpResponse.statusCode)
        }
        return try Self.decodeDisclosurePage(data, politicians: politicians)
    }

    static func decodeSnapshot(_ data: Data, politicians: [Politician]) throws -> IntelligenceSnapshot {
        let decoder = configuredDecoder()
        let response = try decoder.decode(SnapshotResponse.self, from: data)
        return snapshot(from: response.data, politicians: politicians)
    }

    static func decodeDisclosurePage(_ data: Data, politicians: [Politician]) throws -> DisclosurePage {
        let response = try configuredDecoder().decode(DisclosurePageResponse.self, from: data)
        return DisclosurePage(
            disclosures: decodeDisclosures(response.data, politicians: politicians),
            nextCursor: response.meta.nextCursor
        )
    }

    private static func configuredDecoder() -> JSONDecoder {
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
        return decoder
    }

    private static func snapshot(from data: SnapshotData, politicians: [Politician]) -> IntelligenceSnapshot {
        IntelligenceSnapshot(
            instruments: data.instruments,
            events: data.intelligence,
            politicians: politicians,
            disclosures: decodeDisclosures(data.disclosures, politicians: politicians),
            sourceHealth: data.sourceHealth,
            coverage: data.coverage
        )
    }

    private static func decodeDisclosures(
        _ records: [DisclosureRecord],
        politicians: [Politician]
    ) -> [DisclosureTrade] {
        let resolver = PoliticianIdentityResolver(politicians: politicians)
        return records.compactMap { record -> DisclosureTrade? in
            guard
                let id = UUID(uuidString: record.id),
                let politicianID = resolver.resolve(
                    providerID: record.politicianID,
                    name: record.representative,
                    chamber: record.chamber.flatMap(Chamber.init(rawValue:)),
                    party: record.party,
                    state: record.state,
                    district: record.district
                ),
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
    }

    private static func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value + (value.contains("T") ? "" : "T12:00:00Z"))
    }
}

private struct SnapshotResponse: Decodable {
    let data: SnapshotData
}

private struct DisclosurePageResponse: Decodable {
    let data: [DisclosureRecord]
    let meta: DisclosurePageMeta
}

private struct DisclosurePageMeta: Decodable {
    let nextCursor: DisclosureCursor?
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
    let chamber: String?
    let party: String?
    let state: String?
    let district: Int?
    let matchConfidence: Double?
}

struct PoliticianIdentityResolver {
    private static let fuzzyMatchThreshold = 0.75
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

    func resolve(
        providerID: String?,
        name: String,
        chamber: Chamber? = nil,
        party: String? = nil,
        state: String? = nil,
        district: Int? = nil
    ) -> String? {
        if let providerID, IDs.contains(providerID) { return providerID }
        let normalized = Self.normalize(name)
        if let exact = exactMatches[normalized],
           Self.contextMatches(exact, chamber: chamber, party: party, state: state, district: district) {
            return exact.id
        }
        let components = Self.identityComponents(normalized)
        guard let givenName = components.first, let surname = components.last else { return nil }
        let matches = politicians.filter {
            let candidate = Self.identityComponents(Self.normalize($0.name))
            guard let candidateGiven = candidate.first, candidate.last == surname else { return false }
            return Self.canonicalGivenName(String(candidateGiven)) == Self.canonicalGivenName(String(givenName))
        }
        let contextualMatches = matches.filter {
            Self.contextMatches($0, chamber: chamber, party: party, state: state, district: district)
        }
        if contextualMatches.count == 1 { return contextualMatches[0].id }
        guard let firstInitial = givenName.first else { return nil }
        let initialMatches = politicians.filter {
            let candidate = Self.identityComponents(Self.normalize($0.name))
            return candidate.first?.first == firstInitial && candidate.last == surname
        }
        let contextualInitialMatches = initialMatches.filter {
            Self.contextMatches($0, chamber: chamber, party: party, state: state, district: district)
        }
        if contextualInitialMatches.count == 1 { return contextualInitialMatches[0].id }
        return fuzzyMatch(
            normalizedName: normalized,
            chamber: chamber,
            party: party,
            state: state,
            district: district
        )?.id
    }

    private func fuzzyMatch(
        normalizedName: String,
        chamber: Chamber?,
        party: String?,
        state: String?,
        district: Int?
    ) -> Politician? {
        let ranked = politicians.compactMap { politician -> (Politician, Double)? in
            guard Self.contextMatches(
                politician,
                chamber: chamber,
                party: party,
                state: state,
                district: district
            ) else { return nil }
            let score = Self.similarity(normalizedName, Self.normalize(politician.name))
            return score >= Self.fuzzyMatchThreshold ? (politician, score) : nil
        }.sorted {
            if $0.1 == $1.1 { return $0.0.id < $1.0.id }
            return $0.1 > $1.1
        }
        guard let best = ranked.first else { return nil }
        guard ranked.dropFirst().first.map({ best.1 - $0.1 >= 0.05 }) ?? true else { return nil }
        return best.0
    }

    private static func contextMatches(
        _ politician: Politician,
        chamber: Chamber?,
        party: String?,
        state: String?,
        district: Int?
    ) -> Bool {
        if let chamber, politician.chamber != chamber { return false }
        if let state, !state.isEmpty {
            let normalizedState = state.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            let candidateState = politician.state.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            if normalizedState != candidateState
                && normalizedState != Self.stateAbbreviation(candidateState) {
                return false
            }
        }
        if let district, let candidateDistrict = politician.district, district != candidateDistrict {
            return false
        }
        if let party, !party.isEmpty {
            let sourceParty = party.lowercased().prefix(1)
            if sourceParty != politician.party.lowercased().prefix(1) { return false }
        }
        return true
    }

    private static func stateAbbreviation(_ state: String) -> String {
        let names = [
            "california": "ca", "new york": "ny", "texas": "tx", "florida": "fl",
            "georgia": "ga", "alabama": "al", "arkansas": "ar", "tennessee": "tn",
            "new jersey": "nj", "north carolina": "nc", "south carolina": "sc",
            "pennsylvania": "pa", "illinois": "il", "ohio": "oh", "michigan": "mi",
            "virginia": "va", "washington": "wa", "massachusetts": "ma"
        ]
        return names[state.lowercased()] ?? state.lowercased()
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
        let distance = levenshteinDistance(lhs, rhs)
        let editSimilarity = 1 - Double(distance) / Double(max(lhs.count, rhs.count))
        let lhsTokens = Set(lhs.split(separator: " "))
        let rhsTokens = Set(rhs.split(separator: " "))
        let shared = lhsTokens.intersection(rhsTokens).count
        let tokenSimilarity = Double(shared * 2) / Double(max(lhsTokens.count + rhsTokens.count, 1))
        return max(editSimilarity, tokenSimilarity)
    }

    private static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for leftIndex in left.indices {
            var current = [leftIndex + 1] + Array(repeating: 0, count: right.count)
            for rightIndex in right.indices {
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    previous[rightIndex] + (left[leftIndex] == right[rightIndex] ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[right.count]
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
