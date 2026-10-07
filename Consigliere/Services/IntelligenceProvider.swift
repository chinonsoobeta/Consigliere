import Foundation

protocol IntelligenceProvider: Sendable {
    func members(country: Country) async throws -> [Politician]
    func interests(country: Country, memberID: String?, ticker: String?) async throws -> [DeclaredInterest]
    func portfolioGroups() async throws -> [PortfolioGroup]
    func portfolio(id: String, ownOnly: Bool) async throws -> ReferencePortfolio
    func portfolioChanges(id: String, ownOnly: Bool) async throws -> [ReferenceChange]
    func statements(ticker: String?) async throws -> [PresidentialStatement]
    func statementDetail(id: String, politicians: [Politician]) async throws -> StatementDetail
    func reportTag(statementID: String, tagID: String, reason: String) async throws
    func snapshot() async throws -> IntelligenceSnapshot
    func disclosures(query: DisclosureQuery, politicians: [Politician]) async throws -> DisclosurePage
}

struct DisclosureQuery: Sendable {
    enum DateBasis: String, Sendable {
        case transaction, filed
    }

    let ticker: String?
    let politicianID: String?
    let representative: String?
    let chamber: Chamber?
    let from: Date?
    let to: Date?
    let dateBasis: DateBasis
    let limit: Int
    let cursor: DisclosureCursor?

    init(
        ticker: String? = nil,
        politicianID: String? = nil,
        representative: String? = nil,
        chamber: Chamber? = nil,
        from: Date? = nil,
        to: Date? = nil,
        dateBasis: DateBasis = .transaction,
        limit: Int = 100,
        cursor: DisclosureCursor? = nil
    ) {
        self.ticker = ticker
        self.politicianID = politicianID
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

extension IntelligenceProvider {
    func portfolioGroups() async throws -> [PortfolioGroup] { throw LiveProviderError.missingBaseURL }
    func members(country: Country) async throws -> [Politician] { throw LiveProviderError.missingBaseURL }
    func interests(country: Country, memberID: String?, ticker: String?) async throws -> [DeclaredInterest] { throw LiveProviderError.missingBaseURL }
    func portfolio(id: String, ownOnly: Bool) async throws -> ReferencePortfolio { throw LiveProviderError.missingBaseURL }
    func portfolioChanges(id: String, ownOnly: Bool) async throws -> [ReferenceChange] { throw LiveProviderError.missingBaseURL }
    func statements(ticker: String?) async throws -> [PresidentialStatement] { throw LiveProviderError.missingBaseURL }
    func statementDetail(id: String, politicians: [Politician]) async throws -> StatementDetail { throw LiveProviderError.missingBaseURL }
    func reportTag(statementID: String, tagID: String, reason: String) async throws { throw LiveProviderError.missingBaseURL }
}
