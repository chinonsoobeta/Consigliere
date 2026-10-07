import Foundation
import SwiftUI

enum Chamber: String, Codable, CaseIterable {
    case house, senate, commons, lords, representatives
    var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "chamber.\(rawValue)") }
    var icon: String { self == .senate ? "building.columns.fill" : "person.3.fill" }
}

struct Politician: Identifiable, Hashable, Codable {
    var id: String
    let name: String
    let party: String
    let state: String
    let district: Int?
    let chamber: Chamber
    let imageURL: URL?
    let serviceStart: Int
    var country: String? = nil
    var sourceID: String? = nil
    var legislature: String? = nil
    var regionLabel: String? = nil
    var partyHex: String? = nil
    var wikidataID: String? = nil
    var photoSource: String? = nil
    var serviceEnd: String? = nil
    var nation: Country { Country(rawValue: country ?? String(id.split(separator: ":").first ?? "us")) ?? .us }

    var jurisdiction: Text {
        district.map { Text("politician.district \(state) \($0)") } ?? Text(state)
    }

    var partyAbbreviation: String {
        if nation != .us { return party }
        if party.localizedCaseInsensitiveContains("Democrat") { return "D" }
        if party.localizedCaseInsensitiveContains("Republican") { return "R" }
        return "I"
    }

    var partyColor: Color {
        if let hex = partyHex, let value = UInt32(hex, radix: 16) { return Color(red: Double((value >> 16) & 255)/255, green: Double((value >> 8) & 255)/255, blue: Double(value & 255)/255) }
        if nation != .us { return .secondary }
        return switch partyAbbreviation {
        case "D": ConsigliereTheme.democrat
        case "R": ConsigliereTheme.republican
        default: .secondary
        }
    }

    /// Compact newsroom label: "D-NJ" for senators and at-large seats, "D-NJ-5" otherwise.
    var shortLabel: String {
        if nation != .us { return "\(party) · \(state)" }
        let code = StateCodes.code(for: state) ?? state
        return district.map { "\(partyAbbreviation)-\(code)-\($0)" } ?? "\(partyAbbreviation)-\(code)"
    }
}

enum DisclosureTransactionType: String, Codable, CaseIterable {
    case purchase, sale, exchange
    var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "trade.\(rawValue)") }
    /// One-word pill label: Buy, Sell, Exchange.
    var shortLabel: LocalizedStringKey { LocalizedStringKey(stringLiteral: "trade.short.\(rawValue)") }
    var color: Color { self == .purchase ? ConsigliereTheme.positive : (self == .sale ? ConsigliereTheme.negative : ConsigliereTheme.accent) }

    /// Past-tense headline such as "Sold MSFT".
    func headline(_ symbol: String) -> Text {
        switch self {
        case .purchase: Text("trade.headline.purchase \(symbol)")
        case .sale: Text("trade.headline.sale \(symbol)")
        case .exchange: Text("trade.headline.exchange \(symbol)")
        }
    }
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
    let politicianID: String?
    let representative: String
    let chamber: Chamber?
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
    /// When Consigliere first stored the record; drives "new since your last visit".
    let observedAt: Date?
    /// The filing's asset-type code ("ST", "OP" for options, "GS" for government securities),
    /// when the source reports one.
    let assetType: String?
    /// The filer's note on the asset, such as an option's strike and expiry.
    let assetDescription: String?

    init(
        id: UUID, politicianID: String?, representative: String = "", chamber: Chamber? = nil, symbol: String, assetName: String,
        type: DisclosureTransactionType, owner: DisclosureOwner, amountRange: String,
        transactionDate: Date, filedDate: Date, sourceURL: URL,
        eventStudy: [EventStudyPoint], freshness: DataFreshness = .delayed,
        confidence: Double = 1, rankingScore: Double = 0,
        rankingReasons: [String] = [], whyItMatters: String = "", observedAt: Date? = nil,
        assetType: String? = nil, assetDescription: String? = nil
    ) {
        self.id = id
        self.politicianID = politicianID
        self.representative = representative
        self.chamber = chamber
        self.symbol = symbol
        let parsed = Self.parseAssetName(assetName)
        self.assetName = parsed.name
        self.type = type
        self.owner = parsed.owner ?? owner
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
        self.observedAt = observedAt
        self.assetType = assetType
        self.assetDescription = assetDescription
    }

    var disclosureLagDays: Int {
        DisclosureDates.calendar.dateComponents([.day], from: transactionDate, to: filedDate).day ?? 0
    }

    func returnAt(day: Int) -> EventStudyPoint? { eventStudy.first { $0.tradingDay == day } }

    /// The STOCK Act's outer limit: reports are due within 45 days of the transaction.
    static let lateFilingDays = 45
    var isLate: Bool { disclosureLagDays > Self.lateFilingDays }

    /// House PDF extraction can keep the report's row number and owner code in the name
    /// ("2000134527 SP   U.S. Bancorp …"). That code is the filing's own owner column, so it wins
    /// over the provider's owner field, which drops it.
    static func parseAssetName(_ name: String) -> (name: String, owner: DisclosureOwner?) {
        var owner: DisclosureOwner?
        var text = name
        if let match = name.firstMatch(of: /^\d{6,}\s+(?:(SP|JT|DC)\s+)?/) {
            owner = match.output.1.flatMap { ["SP": .spouse, "JT": .joint, "DC": .dependent][String($0)] }
            text = String(name[match.range.upperBound...])
        }
        let cleaned = text.replacing(/\s{2,}/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, owner)
    }

    var displaySymbol: String {
        let trimmed = symbol.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "--" ? assetName : trimmed
    }

    var amount: AmountRange { AmountRange(amountRange) }

    /// Options on the named stock rather than the stock itself.
    var isOption: Bool { assetType == "OP" }
}

/// Parsed congressional value band such as "$1,001 - $15,000" or "Over $50,000,000".
struct AmountRange: Hashable {
    let lower: Double?
    let upper: Double?
    let raw: String

    init(_ raw: String) {
        self.raw = raw
        let numbers = raw.matches(of: /[0-9][0-9,]*(\.[0-9]+)?/).compactMap {
            Double($0.output.0.replacingOccurrences(of: ",", with: ""))
        }
        // Bands start one dollar above a round number ($1,001); show the round number.
        lower = numbers.first.map { $0.truncatingRemainder(dividingBy: 1000) == 1 ? $0 - 1 : $0 }
        upper = numbers.count > 1 ? numbers[1] : nil
    }

    /// Best available magnitude for ranking: the band's ceiling, or its floor for "Over $X".
    var sortValue: Double { upper ?? lower ?? 0 }
}

/// One periodic transaction report: every trade that shares a source document.
struct TradeFiling: Identifiable, Hashable {
    var id: URL { sourceURL }
    let sourceURL: URL
    let trades: [DisclosureTrade]

    var politicianID: String? { trades.first?.politicianID }
    var representative: String { trades.first?.representative ?? "" }
    var chamber: Chamber? { trades.first?.chamber }
    var filedDate: Date { trades.map(\.filedDate).max() ?? .distantPast }
    var observedAt: Date? { trades.compactMap(\.observedAt).min() }
    var maxLagDays: Int { trades.map(\.disclosureLagDays).max() ?? 0 }
    var isLate: Bool { trades.contains(where: \.isLate) }
    /// Trades ordered by reported size, largest first.
    var bySize: [DisclosureTrade] { trades.sorted { $0.amount.sortValue > $1.amount.sortValue } }

    static func group(_ trades: [DisclosureTrade]) -> [TradeFiling] {
        Dictionary(grouping: trades, by: \.sourceURL)
            .map { TradeFiling(sourceURL: $0.key, trades: $0.value.sorted { $0.transactionDate > $1.transactionDate }) }
            .sorted {
                if $0.filedDate != $1.filedDate { return $0.filedDate > $1.filedDate }
                let lhs = $0.observedAt ?? .distantPast, rhs = $1.observedAt ?? .distantPast
                if lhs != rhs { return lhs > rhs }
                // Dictionary order is random; keep same-day filings in a stable order.
                return $0.sourceURL.absoluteString < $1.sourceURL.absoluteString
            }
    }
}

/// Trading pattern for one member, computed from the records loaded on device.
struct TradingStats: Hashable {
    let total: Int
    let lastYear: Int
    let buys: Int
    let sells: Int
    let medianLagDays: Int?
    let lateCount: Int
    let topSymbols: [String]

    init(trades: [DisclosureTrade], now: Date = .now) {
        let cutoff = DisclosureDates.calendar.date(byAdding: .year, value: -1, to: now) ?? now
        total = trades.count
        lastYear = trades.filter { $0.transactionDate >= cutoff }.count
        buys = trades.filter { $0.type == .purchase }.count
        sells = trades.filter { $0.type == .sale }.count
        let lags = trades.map(\.disclosureLagDays).filter { $0 >= 0 }.sorted()
        medianLagDays = lags.isEmpty ? nil : lags[lags.count / 2]
        lateCount = trades.filter(\.isLate).count
        let counts = Dictionary(grouping: trades.map(\.displaySymbol).filter { $0.count <= 6 }, by: { $0 }).mapValues(\.count)
        topSymbols = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5).map(\.key)
    }
}

/// Per-politician totals across all stored disclosures, not just the snapshot window.
struct PoliticianDisclosureSummary: Hashable, Codable {
    let politicianID: String
    let records: Int
    let earliest: String?
    let latest: String?
}

/// A filer name the roster could not attribute (often a former member).
struct UnmatchedFiler: Identifiable, Hashable, Codable {
    var id: String { "\(chamber ?? "")|\(representative)" }
    let representative: String
    let chamber: String?
    let records: Int
    let latest: String?
}

/// An official filing whose transactions have not been extracted yet.
struct PendingFiling: Identifiable, Hashable, Codable {
    let id: String
    let representative: String
    let politicianID: String?
    let chamber: String?
    let filedDate: String
    let sourceURL: URL
    let documentID: String?
}

enum Country: String, CaseIterable, Identifiable, Codable {
    case us, uk, ca, au
    var id: String { rawValue }
    /// Canada and Australia need written reuse permission before their collectors can be built.
    static let available: [Country] = [.us, .uk]
    var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "country.\(rawValue)") }
    var chambers: [Chamber] {
        switch self { case .us: [.house,.senate]; case .uk: [.commons,.lords]; case .ca: [.commons,.senate]; case .au: [.representatives,.senate] }
    }
}

struct DeclaredInterest: Identifiable, Codable, Hashable {
    let id: String
    let memberID: String
    let country: String
    let category: String
    let organisation: String
    let ticker: String?
    let exchange: String?
    let figi: String?
    let thresholdText: String?
    let action: String
    let owner: String
    let registeredAt: String?
    let effectiveAt: String?
    let publishedAt: String?
    let endedAt: String?
    let sourceURL: URL
    let confidence: Double
    let reviewStatus: String
}
