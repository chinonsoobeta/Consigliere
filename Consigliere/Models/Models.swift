import Foundation
import SwiftUI

enum MarketRegion: String, CaseIterable, Codable, Identifiable {
    case northAmerica, europe, asiaPacific, global
    var id: String { rawValue }
    var title: LocalizedStringKey { LocalizedStringKey(stringLiteral: "region.\(rawValue)") }
}

enum InstrumentKind: String, Codable, CaseIterable {
    case equity, etf, index, future, currency, yield, spotAssessment, differential
    var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "instrument.\(rawValue)") }
    var icon: String {
        switch self {
        case .equity: "building.2"
        case .etf: "square.stack.3d.up"
        case .index: "chart.line.uptrend.xyaxis"
        case .future: "calendar.badge.clock"
        case .currency: "dollarsign.arrow.circlepath"
        case .yield: "percent"
        case .spotAssessment: "drop"
        case .differential: "arrow.left.arrow.right"
        }
    }
}

enum DataFreshness: String, Codable {
    case live, delayed, assessment, stale
    var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "freshness.\(rawValue)") }
    var color: Color {
        switch self {
        case .live: ConsigliereTheme.positive
        case .delayed: ConsigliereTheme.warning
        case .assessment: ConsigliereTheme.accent
        case .stale: ConsigliereTheme.negative
        }
    }
}

struct PricePoint: Identifiable, Hashable, Codable {
    let id: UUID
    let timestamp: Date
    let value: Double
    init(_ value: Double, minutesAgo: Int) {
        id = UUID(); self.value = value
        timestamp = Calendar.current.date(byAdding: .minute, value: -minutesAgo, to: .now) ?? .now
    }
}

struct MarketInstrument: Identifiable, Hashable, Codable {
    let id: UUID
    let symbol: String
    let name: String
    let exchange: String
    let currency: String
    let region: MarketRegion
    let kind: InstrumentKind
    let price: Double
    let changePercent: Double
    let freshness: DataFreshness
    let updatedAt: Date
    let sector: String?
    let aliases: [String]
    let history: [PricePoint]
    var provider: String? = nil
    var attribution: String? = nil

    var formattedPrice: String {
        if kind == .yield { return price.formatted(.number.precision(.fractionLength(2))) + "%" }
        return price.formatted(.currency(code: currency).precision(.fractionLength(price < 10 ? 2 : 1)))
    }
}

enum EventSource: String, Codable {
    case truthSocial, houseDisclosure, senateDisclosure
    var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "source.\(rawValue)") }
    var icon: String {
        switch self {
        case .truthSocial: "bubble.left.and.text.bubble.right"
        case .houseDisclosure: "building.columns"
        case .senateDisclosure: "doc.text.magnifyingglass"
        }
    }
}

enum ImpactLevel: String, Codable {
    case low, moderate, elevated
    var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "impact.\(rawValue)") }
    var color: Color { self == .elevated ? ConsigliereTheme.negative : (self == .moderate ? ConsigliereTheme.warning : ConsigliereTheme.accent) }
    var icon: String { self == .elevated ? "exclamationmark.triangle.fill" : (self == .moderate ? "waveform.path.ecg" : "info.circle.fill") }
}

struct MarketReaction: Hashable, Codable {
    let symbol: String
    let oneMinute: Double?
    let fiveMinutes: Double?
    let fifteenMinutes: Double?
    let sixtyMinutes: Double?
    let oneDay: Double?
}

struct MarketEvent: Identifiable, Hashable, Codable {
    let id: UUID
    let source: EventSource
    let title: String
    let body: String
    let author: String
    let publishedAt: Date
    let retrievedAt: Date
    let transactionDate: Date?
    let sourceURL: URL
    let mentionedSymbols: [String]
    let topics: [String]
    let impact: ImpactLevel
    let confidence: Double
    let explanation: String
    let reaction: MarketReaction?
    let freshness: DataFreshness
    let rankingScore: Double
    let rankingReasons: [String]
    var politicianID: String? = nil
    var timePrecision: TimePrecision? = nil

    /// Disclosures carry calendar dates only; their stored time of day is a placeholder.
    var isDateOnly: Bool {
        timePrecision == .date || (timePrecision == nil && source != .truthSocial)
    }

    var retrievalLatency: TimeInterval { retrievedAt.timeIntervalSince(publishedAt) }
}

enum TimePrecision: String, Codable {
    case date, datetime
}

enum SourceAvailability: String, Codable {
    case available, degraded, failed, unconfigured

    var label: LocalizedStringKey { LocalizedStringKey(stringLiteral: "sourceStatus.\(rawValue)") }

    var color: Color {
        switch self {
        case .available: ConsigliereTheme.positive
        case .degraded: ConsigliereTheme.warning
        case .failed: ConsigliereTheme.negative
        case .unconfigured: .secondary
        }
    }
}

struct SourceHealth: Identifiable, Hashable, Codable {
    var id: String { provider }
    let provider: String
    let displayName: String
    let status: SourceAvailability
    let lastAttemptAt: Date?
    let lastSuccessAt: Date?
    let recordsSeen: Int
    let message: String?
    let coverageStart: String?
    let coverageEnd: String?
}

struct DisclosureCoverageSummary: Identifiable, Hashable, Codable {
    var id: String { chamber }
    let chamber: String
    let earliest: String?
    let latest: String?
    let records: Int
    let completeness: String
}

struct IntelligenceSnapshot: Hashable {
    let instruments: [MarketInstrument]
    let events: [MarketEvent]
    let politicians: [Politician]
    let disclosures: [DisclosureTrade]
    let sourceHealth: [SourceHealth]
    let coverage: [DisclosureCoverageSummary]
    var politicianSummaries: [PoliticianDisclosureSummary] = []
    var unmatchedFilers: [UnmatchedFiler] = []
    var pendingFilings: [PendingFiling] = []
}
