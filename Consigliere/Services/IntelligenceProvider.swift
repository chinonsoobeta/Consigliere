import Foundation

protocol IntelligenceProvider: Sendable {
    func snapshot() async throws -> IntelligenceSnapshot
    func disclosures(query: DisclosureQuery, politicians: [Politician]) async throws -> DisclosurePage
}

struct DisclosureQuery: Sendable {
    enum DateBasis: String, Sendable {
        case transaction, filed
    }

    let representative: String?
    let chamber: Chamber?
    let from: Date?
    let to: Date?
    let dateBasis: DateBasis
    let limit: Int
    let cursor: DisclosureCursor?

    init(
        representative: String? = nil,
        chamber: Chamber? = nil,
        from: Date? = nil,
        to: Date? = nil,
        dateBasis: DateBasis = .transaction,
        limit: Int = 100,
        cursor: DisclosureCursor? = nil
    ) {
        self.representative = representative
        self.chamber = chamber
        self.from = from
        self.to = to
        self.dateBasis = dateBasis
        self.limit = limit
        self.cursor = cursor
    }
}

struct DisclosureCursor: Hashable, Codable, Sendable {
    let date: String
    let id: String
}

struct DisclosurePage: Sendable {
    let disclosures: [DisclosureTrade]
    let nextCursor: DisclosureCursor?
}

enum LiveProviderError: LocalizedError {
    case missingBaseURL

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            "The live intelligence service is not configured. Set CONSIGLIERE_API_BASE_URL and try again."
        }
    }
}

struct UnconfiguredIntelligenceProvider: IntelligenceProvider {
    func snapshot() async throws -> IntelligenceSnapshot {
        throw LiveProviderError.missingBaseURL
    }

    func disclosures(query: DisclosureQuery, politicians: [Politician]) async throws -> DisclosurePage {
        throw LiveProviderError.missingBaseURL
    }
}
