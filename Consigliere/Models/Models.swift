import Foundation
import SwiftUI

enum MarketRegion: String, CaseIterable, Codable, Identifiable {
    case northAmerica, europe, asiaPacific, global
    var id: String { rawValue }
    var title: LocalizedStringKey { LocalizedStringKey("region.\(rawValue)") }
}

enum InstrumentKind: String, Codable, CaseIterable {
    case equity, etf, index, future, currency, yield, spotAssessment, differential
    var label: LocalizedStringKey { LocalizedStringKey("instrument.\(rawValue)") }
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
    case live, delayed, prototype, assessment, stale
    var label: LocalizedStringKey { LocalizedStringKey("freshness.\(rawValue)") }
    var color: Color {
        switch self {
        case .live: .green
        case .delayed: .orange
        case .prototype: .indigo
        case .assessment: .blue
        case .stale: .red
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

    var formattedPrice: String {
        if kind == .yield { return price.formatted(.number.precision(.fractionLength(2))) + "%" }
        return price.formatted(.currency(code: currency).precision(.fractionLength(price < 10 ? 2 : 1)))
    }
}

enum EventSource: String, Codable {
    case truthSocial, houseDisclosure, senateDisclosure
    var label: LocalizedStringKey { LocalizedStringKey("source.\(rawValue)") }
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
    var label: LocalizedStringKey { LocalizedStringKey("impact.\(rawValue)") }
    var color: Color { self == .elevated ? .red : (self == .moderate ? .orange : .blue) }
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

    var retrievalLatency: TimeInterval { retrievedAt.timeIntervalSince(publishedAt) }
}

struct PortfolioHolding: Identifiable, Hashable, Codable {
    let id: UUID
    let symbol: String
    let shares: Double
    let averageCost: Double
}

struct ExposureSlice: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let weight: Double
}

struct PortfolioSummary {
    let marketValue: Double
    let dayChange: Double
    let concentration: Double
    let exposures: [ExposureSlice]
    static let empty = PortfolioSummary(marketValue: 0, dayChange: 0, concentration: 0, exposures: [])
}

enum AnalysisEngine {
    static func summarize(holdings: [PortfolioHolding], instruments: [MarketInstrument]) -> PortfolioSummary {
        let lookup = Dictionary(uniqueKeysWithValues: instruments.map { ($0.symbol, $0) })
        let values = holdings.compactMap { holding -> (String, Double, Double)? in
            guard let instrument = lookup[holding.symbol] else { return nil }
            return (instrument.sector ?? "Other", holding.shares * instrument.price, instrument.changePercent)
        }
        let total = values.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return .empty }
        let dayChange = values.reduce(0) { $0 + ($1.1 / total * $1.2) }
        let grouped = Dictionary(grouping: values, by: \.0).mapValues { $0.reduce(0) { $0 + $1.1 } }
        let exposures = grouped.map { ExposureSlice(name: $0.key, weight: $0.value / total) }.sorted { $0.weight > $1.weight }
        return PortfolioSummary(marketValue: total, dayChange: dayChange, concentration: exposures.first?.weight ?? 0, exposures: exposures)
    }
}
