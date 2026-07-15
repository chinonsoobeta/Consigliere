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

enum DisclosureCoverageStatus: String, Codable, CaseIterable {
    case complete, partial, noReportableTransactions, sourceUnavailable, notServing
    var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "coverage.\(rawValue)") }
    var color: Color {
        switch self {
        case .complete: ConsigliereTheme.positive
        case .partial: .orange
        case .noReportableTransactions: .blue
        case .sourceUnavailable: .red
        case .notServing: .secondary
        }
    }
    var icon: String {
        switch self {
        case .complete: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .noReportableTransactions: "minus.circle.fill"
        case .sourceUnavailable: "exclamationmark.triangle.fill"
        case .notServing: "calendar.badge.minus"
        }
    }
}

struct DisclosureCoverageYear: Identifiable, Hashable {
    var id: Int { year }
    let year: Int
    let status: DisclosureCoverageStatus
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

    init(
        id: UUID, politicianID: String, symbol: String, assetName: String,
        type: DisclosureTransactionType, owner: DisclosureOwner, amountRange: String,
        transactionDate: Date, filedDate: Date, sourceURL: URL,
        eventStudy: [EventStudyPoint], freshness: DataFreshness = .prototype
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
    }

    var disclosureLagDays: Int {
        Calendar.current.dateComponents([.day], from: transactionDate, to: filedDate).day ?? 0
    }

    func returnAt(day: Int) -> EventStudyPoint? { eventStudy.first { $0.tradingDay == day } }
}

enum ModelPortfolioMode: String, CaseIterable, Identifiable {
    case reportedHoldings, publicInformation
    var id: String { rawValue }
    var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "model.\(rawValue)") }
}

struct ModelPosition: Identifiable, Hashable, Codable {
    var id: String { symbol + owner.rawValue }
    let symbol: String
    let name: String
    let weight: Double
    let owner: DisclosureOwner
    let sourceDate: Date
    let estimated: Bool
}

struct ModelPerformancePoint: Identifiable, Hashable, Codable {
    let id: UUID
    let date: Date
    let reportedValue: Double
    let publicValue: Double
    let benchmarkValue: Double
}

struct PoliticianModelPortfolio: Identifiable, Hashable, Codable {
    var id: String { politicianID }
    let politicianID: String
    let asOfDate: Date
    let positions: [ModelPosition]
    let performance: [ModelPerformancePoint]
    let methodologyNote: String

    func value(for point: ModelPerformancePoint, mode: ModelPortfolioMode) -> Double {
        mode == .reportedHoldings ? point.reportedValue : point.publicValue
    }
}

enum PoliticianAnalytics {
    static func coverage(for politician: Politician, currentYear: Int = Calendar.current.component(.year, from: .now)) -> [DisclosureCoverageYear] {
        (currentYear - 9...currentYear).map { year in
            let status: DisclosureCoverageStatus
            if year < politician.serviceStart { status = .notServing }
            else if year < currentYear - 5 { status = .sourceUnavailable }
            else { status = .noReportableTransactions }
            return DisclosureCoverageYear(year: year, status: status)
        }
    }

    static func coverage(for politician: Politician, trades: [DisclosureTrade], currentYear: Int = Calendar.current.component(.year, from: .now)) -> [DisclosureCoverageYear] {
        let tradeYears = Set(trades.map { Calendar.current.component(.year, from: $0.transactionDate) })
        return coverage(for: politician, currentYear: currentYear).map { item in
            guard item.status != .notServing, item.status != .sourceUnavailable else { return item }
            return DisclosureCoverageYear(year: item.year, status: tradeYears.contains(item.year) ? .complete : .noReportableTransactions)
        }
    }
}
