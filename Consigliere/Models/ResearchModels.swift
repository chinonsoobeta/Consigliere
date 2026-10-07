import Foundation

struct StockRoute: Hashable { let symbol: String }

struct ReferencePosition: Identifiable, Codable, Hashable {
    var id: String { key }
    let key: String
    let ticker: String
    let assetName: String
    let group: String
    let owner: String
    let estimate: Double
    let low: Double
    let high: Double?
    let membersHolding: Int
    let firstAdded: String?
    let lastActivity: String
    let status: String
    let sector: String?
}

struct ReferencePortfolio: Codable {
    let id: String
    let kind: String
    let members: [String]
    let methodVersion: Int
    let builtAt: String?
    let historyStart: String?
    let frozenAt: String?
    var anchorAsOf: String? = nil
    var anchorFiledDate: String? = nil
    var anchorSourceURL: URL? = nil
    let positions: [ReferencePosition]
}

struct ReferenceChange: Identifiable, Codable {
    let id: String
    let ticker: String
    let assetName: String
    let action: String
    let filedDate: String
    let disclosureID: String
    let sourceURL: URL
    let note: String?
}

struct StatementTag: Identifiable, Codable, Hashable {
    let id: String
    let kind: String
    let value: String
    let quote: String
    let model: String
    let promptVersion: String
}

struct PresidentialStatement: Identifiable, Codable, Hashable {
    let id: String
    let provider: String
    let kind: String
    let title: String
    let body: String
    let sourceURL: URL
    let publishedAt: String
    let signedAt: String?
    var confirmationURL: URL? = nil
    let documentNumber: String?
    let tags: [StatementTag]
    let tier: String
    let priority: Int
}

struct RelatedHolding: Codable, Identifiable {
    var id: String { ticker }
    let ticker: String
    let membersHolding: Int
}

struct StatementDetail {
    let statement: PresidentialStatement
    let holdings: [RelatedHolding]
    let trades: [DisclosureTrade]
}

struct ResearchResponse<Value: Decodable>: Decodable { let data: Value }

struct PortfolioGroup: Identifiable, Codable {
    let id: String
    let kind: String
    let title: String?
}
