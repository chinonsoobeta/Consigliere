import Foundation
import SwiftUI

enum Chamber: String, Codable, CaseIterable {
    case house, senate
    var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "chamber.\(rawValue)") }
    var icon: String { self == .senate ? "building.columns.fill" : "person.3.fill" }
}

struct Politician: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let party: String
    let state: String
    let district: Int?
    let chamber: Chamber
    let imageURL: URL?
    let serviceStart: Int

    var jurisdiction: String {
        district.map { "\(state) · District \($0)" } ?? state
    }

    var partyAbbreviation: String {
        if party.localizedCaseInsensitiveContains("Democrat") { return "D" }
        if party.localizedCaseInsensitiveContains("Republican") { return "R" }
        return "I"
    }
}

enum DisclosureTransactionType: String, Codable, CaseIterable {
    case purchase, sale, exchange
    var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "trade.\(rawValue)") }
    var color: Color { self == .purchase ? ConsigliereTheme.positive : (self == .sale ? ConsigliereTheme.negative : .blue) }
    var icon: String { self == .purchase ? "arrow.down.to.line" : (self == .sale ? "arrow.up.from.line" : "arrow.left.arrow.right") }
}

enum DisclosureOwner: String, Codable {
    case member, spouse, dependent, joint
    var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "owner.\(rawValue)") }
}

struct EventStudyPoint: Identifiable, Hashable, Codable {
    var id: Int { tradingDay }
    let tradingDay: Int
    let securityReturn: Double
    let benchmarkReturn: Double
    let sectorReturn: Double
    var abnormalReturn: Double { securityReturn - benchmarkReturn }
}

struct DisclosureTrade: Identifiable, Hashable, Codable {
    let id: UUID
    let politicianID: String
    let symbol: String
    let assetName: String
    let type: DisclosureTransactionType
    let owner: DisclosureOwner
    let amountRange: String
    let transactionDate: Date
    let filedDate: Date
    let sourceURL: URL
    let eventStudy: [EventStudyPoint]
    let freshness: DataFreshness
    let confidence: Double
    let rankingScore: Double
    let rankingReasons: [String]
    let whyItMatters: String

    init(
        id: UUID, politicianID: String, symbol: String, assetName: String,
        type: DisclosureTransactionType, owner: DisclosureOwner, amountRange: String,
        transactionDate: Date, filedDate: Date, sourceURL: URL,
        eventStudy: [EventStudyPoint], freshness: DataFreshness = .delayed,
        confidence: Double = 1, rankingScore: Double = 0,
        rankingReasons: [String] = [], whyItMatters: String = ""
    ) {
        self.id = id
        self.politicianID = politicianID
        self.symbol = symbol
        self.assetName = assetName
        self.type = type
        self.owner = owner
        self.amountRange = amountRange
        self.transactionDate = transactionDate
        self.filedDate = filedDate
        self.sourceURL = sourceURL
        self.eventStudy = eventStudy
        self.freshness = freshness
        self.confidence = confidence
        self.rankingScore = rankingScore
        self.rankingReasons = rankingReasons
        self.whyItMatters = whyItMatters
    }

    var disclosureLagDays: Int {
        Calendar.current.dateComponents([.day], from: transactionDate, to: filedDate).day ?? 0
    }

    func returnAt(day: Int) -> EventStudyPoint? { eventStudy.first { $0.tradingDay == day } }
}
