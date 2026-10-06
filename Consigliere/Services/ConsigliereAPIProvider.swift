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
        if let politicianID = query.politicianID {
            items.append(URLQueryItem(name: "politician_id", value: politicianID))
        }
        if let representative = query.representative {
            items.append(URLQueryItem(name: "representative", value: representative))
        }
        if let chamber = query.chamber {
            items.append(URLQueryItem(name: "chamber", value: chamber.rawValue))
        }
        let formatter = DisclosureDates.dayFormatter
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
            if let date = DisclosureDates.timestamp(value) { return date }
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
            coverage: data.coverage,
            politicianSummaries: data.politicianSummaries ?? [],
            unmatchedFilers: data.unmatchedFilers ?? [],
            pendingFilings: data.pendingFilings ?? []
        )
    }

    // Records the roster cannot attribute are kept with a nil politicianID so they still
    // appear in feeds and unmatched-filer lists instead of silently disappearing.
    fileprivate static func decodeDisclosures(
        _ records: [DisclosureRecord],
        politicians: [Politician]
    ) -> [DisclosureTrade] {
        let resolver = PoliticianIdentityResolver(politicians: politicians)
        return records.compactMap { record -> DisclosureTrade? in
            let chamber = record.chamber.flatMap(Chamber.init(rawValue:))
            guard
                let id = UUID(uuidString: record.id),
                let transactionDate = DisclosureDates.day(record.transactionDate),
                let filedDate = DisclosureDates.day(record.filedDate),
                let type = DisclosureTransactionType(rawValue: record.type),
                let owner = DisclosureOwner(rawValue: record.owner),
                let sourceURL = URL(string: record.sourceURL)
            else { return nil }
            return DisclosureTrade(
                id: id,
                politicianID: resolver.resolve(
                    providerID: record.politicianID,
                    name: record.representative,
                    chamber: chamber,
                    party: record.party,
                    state: record.state,
                    district: record.district
                ),
                representative: record.representative,
                chamber: chamber,
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
}

/// Disclosure dates are calendar days with no time of day. They are anchored at noon UTC and
/// must be displayed in UTC so a filing never shifts to the previous or next day.
enum DisclosureDates {
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }()

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let whole = ISO8601DateFormatter()

    static func timestamp(_ value: String) -> Date? {
        fractional.date(from: value) ?? whole.date(from: value)
    }

    static func day(_ value: String) -> Date? {
        if value.contains("T") { return timestamp(value) }
        return timestamp(value + "T12:00:00Z")
    }

    /// Use with `Text(date, format:)` or string interpolation in a `Text` so the in-app
    /// language (the environment locale) is respected.
    static func style(_ style: Date.FormatStyle.DateStyle = .abbreviated) -> Date.FormatStyle {
        var format = Date.FormatStyle(date: style, time: .omitted)
        format.timeZone = utc
        return format
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
    let politicianSummaries: [PoliticianDisclosureSummary]?
    let unmatchedFilers: [UnmatchedFiler]?
    let pendingFilings: [PendingFiling]?
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

/// Fallback for records the backend has not yet matched. Mirrors backend/src/identity.js:
/// chamber and state are hard constraints; district and party only break ties.
struct PoliticianIdentityResolver {
    private struct Candidate {
        let politician: Politician
        let state: String?
        let normalized: String
        let given: String
        let surname: String
    }

    private static let fuzzyMatchThreshold = 0.75
    private let candidates: [Candidate]
    private let IDs: Set<String>

    init(politicians: [Politician]) {
        IDs = Set(politicians.map(\.id))
        candidates = politicians.compactMap { politician in
            let normalized = Self.normalize(politician.name)
            let parts = normalized.split(separator: " ").map(String.init)
            guard let given = parts.first, let surname = parts.last else { return nil }
            return Candidate(
                politician: politician,
                state: StateCodes.code(for: politician.state),
                normalized: normalized,
                given: given,
                surname: surname
            )
        }
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
        let parts = normalized.split(separator: " ").map(String.init)
        guard let given = parts.first, let surname = parts.last else { return nil }
        let code = state.flatMap(StateCodes.code(for:))
        let pool = candidates.filter {
            (chamber == nil || $0.politician.chamber == chamber) && (code == nil || $0.state == code)
        }
        func unique(_ matches: [Candidate]) -> String? {
            let narrowed = Self.tieBreak(matches, district: district, party: party)
            return narrowed.count == 1 ? narrowed[0].politician.id : nil
        }

        let exact = pool.filter { $0.normalized == normalized }
        if !exact.isEmpty { return unique(exact) }
        let sameSurname = pool.filter { $0.surname == surname }
        let byGiven = sameSurname.filter { Self.canonicalGivenName($0.given) == Self.canonicalGivenName(given) }
        if !byGiven.isEmpty { return unique(byGiven) }
        let byInitial = sameSurname.filter { $0.given.first == given.first }
        if !byInitial.isEmpty { return unique(byInitial) }
        // A surname unique within a known state delegation is a strong identity signal.
        if code != nil, !sameSurname.isEmpty { return unique(sameSurname) }

        let ranked = pool.compactMap { candidate -> (Candidate, Double)? in
            let score = Self.similarity(normalized, candidate.normalized)
            return score >= Self.fuzzyMatchThreshold ? (candidate, score) : nil
        }.sorted {
            if $0.1 == $1.1 { return $0.0.politician.id < $1.0.politician.id }
            return $0.1 > $1.1
        }
        guard let best = ranked.first else { return nil }
        guard ranked.dropFirst().first.map({ best.1 - $0.1 >= 0.05 }) ?? true else { return nil }
        return best.0.politician.id
    }

    private static func tieBreak(_ matches: [Candidate], district: Int?, party: String?) -> [Candidate] {
        guard matches.count > 1 else { return matches }
        if let district {
            let byDistrict = matches.filter { $0.politician.district == district }
            if byDistrict.count == 1 { return byDistrict }
        }
        if let initial = party?.prefix(1).uppercased(), !initial.isEmpty {
            let byParty = matches.filter { $0.politician.party.prefix(1).uppercased() == initial }
            if byParty.count == 1 { return byParty }
        }
        return matches
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

    private static let givenNameAliases = [
        "bill": "william", "will": "william", "bob": "robert", "rob": "robert",
        "chris": "christopher", "chuck": "charles", "dan": "daniel", "don": "donald",
        "ed": "edward", "jack": "john", "jim": "james", "jimmy": "james", "joe": "joseph",
        "ken": "kenneth", "matt": "matthew", "mike": "michael", "rick": "richard",
        "rich": "richard", "dick": "richard", "ron": "ronald", "tom": "thomas", "tim": "timothy",
        "val": "valerie", "gil": "gilbert", "greg": "gregory", "steve": "steven",
        "stephen": "steven", "dave": "david", "andy": "andrew", "tony": "anthony",
        "pat": "patrick", "pete": "peter", "sam": "samuel", "ted": "edward", "nick": "nicholas",
        "vince": "vincent", "liz": "elizabeth", "beth": "elizabeth", "kathy": "katherine",
        "cathy": "catherine", "debbie": "deborah", "sue": "susan", "abe": "abraham",
        "fred": "frederick", "jerry": "gerald", "larry": "lawrence", "mitch": "mitchell",
        "josh": "joshua", "zach": "zachary", "ben": "benjamin", "buddy": "earl"
    ]

    private static func canonicalGivenName(_ value: String) -> String {
        givenNameAliases[value] ?? value
    }

    private static let ignoredTokens: Set<String> = [
        "hon", "honorable", "sen", "senator", "rep", "representative", "dr", "mr", "mrs", "ms",
        "jr", "sr", "ii", "iii", "iv", "md", "facs", "phd", "dds", "cpa", "esq"
    ]
    private static let credentials: Set<String> = [
        "md", "facs", "phd", "dds", "cpa", "esq", "jr", "sr", "ii", "iii", "iv"
    ]

    static func normalize(_ value: String) -> String {
        var candidate = value
        // "Pelosi, Nancy" is surname-first; "Neal Patrick MD, FACS Dunn" only has a credential comma.
        if let comma = candidate.firstIndex(of: ","), comma != candidate.startIndex {
            let surname = candidate[..<comma]
            let given = candidate[candidate.index(after: comma)...]
            let firstAfterComma = given.split(whereSeparator: { !$0.isLetter }).first.map { $0.lowercased() } ?? ""
            candidate = credentials.contains(firstAfterComma)
                ? candidate.replacingOccurrences(of: ",", with: " ")
                : "\(given) \(surname)"
        }
        return candidate
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !ignoredTokens.contains($0) }
            .joined(separator: " ")
    }
}

enum StateCodes {
    static let byName: [String: String] = [
        "alabama": "AL", "alaska": "AK", "arizona": "AZ", "arkansas": "AR", "california": "CA",
        "colorado": "CO", "connecticut": "CT", "delaware": "DE", "florida": "FL", "georgia": "GA",
        "hawaii": "HI", "idaho": "ID", "illinois": "IL", "indiana": "IN", "iowa": "IA",
        "kansas": "KS", "kentucky": "KY", "louisiana": "LA", "maine": "ME", "maryland": "MD",
        "massachusetts": "MA", "michigan": "MI", "minnesota": "MN", "mississippi": "MS",
        "missouri": "MO", "montana": "MT", "nebraska": "NE", "nevada": "NV",
        "new hampshire": "NH", "new jersey": "NJ", "new mexico": "NM", "new york": "NY",
        "north carolina": "NC", "north dakota": "ND", "ohio": "OH", "oklahoma": "OK",
        "oregon": "OR", "pennsylvania": "PA", "rhode island": "RI", "south carolina": "SC",
        "south dakota": "SD", "tennessee": "TN", "texas": "TX", "utah": "UT", "vermont": "VT",
        "virginia": "VA", "washington": "WA", "west virginia": "WV", "wisconsin": "WI",
        "wyoming": "WY", "district of columbia": "DC", "puerto rico": "PR", "guam": "GU",
        "virgin islands": "VI", "american samoa": "AS", "northern mariana islands": "MP"
    ]

    static func code(for state: String) -> String? {
        let trimmed = state.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 2, trimmed.allSatisfy(\.isLetter) { return trimmed.uppercased() }
        return byName[trimmed.lowercased()]
    }
}
