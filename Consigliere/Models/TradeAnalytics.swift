import Foundation

/// Shared by Home and Trades; every condition applies to the same transaction.
struct TradeFilter: Equatable {
    var filedWithinDays: Int? = nil
    var members: Set<String>? = nil
    var minimumBand: Double? = nil
    var lateOnly = false
    var optionsOnly = false
    var observedAfter: Date? = nil
    var sourceURLs: Set<URL>? = nil

    func matches(_ trade: DisclosureTrade, now: Date = .now) -> Bool {
        if let days = filedWithinDays, trade.filedDate < now.addingTimeInterval(-Double(days) * 86_400) { return false }
        if let members, !members.contains(trade.politicianID ?? "") { return false }
        if let minimumBand, trade.amount.sortValue <= minimumBand { return false }
        if lateOnly && !trade.isLate { return false }
        if optionsOnly && !trade.isOption { return false }
        if let observedAfter, (trade.observedAt ?? .distantPast) <= observedAfter { return false }
        if let sourceURLs, !sourceURLs.contains(trade.sourceURL) { return false }
        return true
    }
}

struct HomeSummary {
    let filings: Int
    let following: Int
    let large: Int
    let late: Int

    init(trades: [DisclosureTrade], previousVisit: Date?, followed: Set<String>, now: Date = .now) {
        let filter = TradeFilter(filedWithinDays: previousVisit == nil ? 7 : nil, observedAfter: previousVisit)
        let records = trades.filter { filter.matches($0, now: now) }
        let reports = TradeFiling.group(records)
        filings = reports.count
        following = reports.filter { followed.contains($0.politicianID ?? "") }.count
        large = records.filter { $0.amount.sortValue > 1_000_000 }.count
        late = reports.filter(\.isLate).count
    }
}

struct WeeklyBucket: Identifiable {
    var id: Date { start }
    let start: Date
    let count: Int
}

struct ActivityBucket: Identifiable {
    var id: String { "\(month)|\(type.rawValue)" }
    let month: Date
    let type: DisclosureTransactionType
    let count: Int
}

/// Distinct members buying and selling one security over a recent window.
struct TickerFlow: Identifiable, Hashable {
    var id: String { symbol }
    let symbol: String
    let assetName: String
    let buyers: Int
    let sellers: Int
    var net: Int { buyers - sellers }
}

struct DelayRecord: Identifiable {
    var id: URL { filing.sourceURL }
    let filing: TradeFiling
    var days: Int { filing.maxLagDays }
}

enum TradeAnalytics {
    static var calendar: Calendar {
        var value = DisclosureDates.calendar
        value.firstWeekday = 2
        value.minimumDaysInFirstWeek = 4
        return value
    }

    static func weeklyPulse(_ trades: [DisclosureTrade], now: Date = .now) -> [WeeklyBucket] {
        let cal = calendar
        let current = cal.dateInterval(of: .weekOfYear, for: now)!.start
        let counts = Dictionary(grouping: TradeFiling.group(trades)) { cal.dateInterval(of: .weekOfYear, for: $0.filedDate)!.start }.mapValues(\.count)
        return (0..<12).reversed().map {
            let start = cal.date(byAdding: .weekOfYear, value: -$0, to: current)!
            return WeeklyBucket(start: start, count: counts[start] ?? 0)
        }
    }

    /// Compares the last complete week with the median of the weeks before it. The current week is
    /// still filling up, and a short history (or a median of zero) says nothing about "usual".
    static func busierThanUsual(_ buckets: [WeeklyBucket]) -> Bool {
        guard buckets.count >= 3 else { return false }
        let latest = buckets[buckets.count - 2].count
        let history = buckets.dropLast(2).map(\.count)
        guard history.filter({ $0 > 0 }).count >= 6 else { return false }
        let sorted = history.sorted()
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 0 ? Double(sorted[middle - 1] + sorted[middle]) / 2 : Double(sorted[middle])
        return median > 0 && Double(latest) > 1.5 * median
    }

    /// Securities with the most distinct members on one side, by filing date. Only listed symbols
    /// count: private funds and Treasury bills cannot be followed or traded by a reader.
    static func flows(_ trades: [DisclosureTrade], days: Int = 30, now: Date = .now) -> [TickerFlow] {
        let start = now.addingTimeInterval(-Double(days) * 86_400)
        let recent = trades.filter { !$0.symbol.isEmpty && $0.filedDate >= start && $0.filedDate <= now }
        return Dictionary(grouping: recent, by: \.symbol).map { symbol, trades in
            let member = { (trade: DisclosureTrade) in trade.politicianID ?? trade.representative }
            return TickerFlow(
                symbol: symbol,
                assetName: trades.first?.assetName ?? symbol,
                buyers: Set(trades.filter { $0.type == .purchase }.map(member)).count,
                sellers: Set(trades.filter { $0.type == .sale }.map(member)).count
            )
        }
    }

    static func mostBought(_ flows: [TickerFlow], limit: Int = 4) -> [TickerFlow] {
        Array(flows.filter { $0.net > 0 }
            .sorted { ($0.buyers, $0.net, $1.symbol) > ($1.buyers, $1.net, $0.symbol) }.prefix(limit))
    }

    static func mostSold(_ flows: [TickerFlow], limit: Int = 4) -> [TickerFlow] {
        Array(flows.filter { $0.sellers > 0 && $0.net < 0 }
            .sorted { ($0.sellers, -$0.net, $1.symbol) > ($1.sellers, -$1.net, $0.symbol) }.prefix(limit))
    }

    /// Monthly buys and sells from the first trade (at most 24 months, at least 6), so a short
    /// record does not render as an empty chart with a sliver at the end.
    static func activityHistogram(_ trades: [DisclosureTrade], now: Date = .now) -> [ActivityBucket] {
        let cal = calendar
        let current = cal.dateInterval(of: .month, for: now)!.start
        let span = trades.map(\.transactionDate).min()
            .map { cal.dateComponents([.month], from: cal.dateInterval(of: .month, for: $0)!.start, to: current).month ?? 0 } ?? 0
        let months = min(max(span + 1, 6), 24)
        return (0..<months).reversed().flatMap { offset in
            let month = cal.date(byAdding: .month, value: -offset, to: current)!
            let end = cal.date(byAdding: .month, value: 1, to: month)!
            return [DisclosureTransactionType.purchase, .sale].map { type in
                ActivityBucket(month: month, type: type, count: trades.filter { $0.type == type && $0.transactionDate >= month && $0.transactionDate < end }.count)
            }
        }
    }

    static func delays(_ trades: [DisclosureTrade]) -> [DelayRecord] {
        TradeFiling.group(trades).filter { $0.maxLagDays >= 0 }.map { DelayRecord(filing: $0) }.sorted { $0.filing.filedDate < $1.filing.filedDate }
    }

    static func medianReportingDelay(_ records: [DelayRecord]) -> Double? {
        let days = records.map(\.days).sorted()
        guard !days.isEmpty else { return nil }
        let middle = days.count / 2
        return days.count.isMultiple(of: 2) ? Double(days[middle - 1] + days[middle]) / 2 : Double(days[middle])
    }

    static func notable(_ trades: [DisclosureTrade], followed: Set<String>, previousMember: String?, now: Date = .now) -> DisclosureTrade? {
        var candidates = trades.filter { $0.filedDate <= now && $0.filedDate >= now.addingTimeInterval(-7 * 86_400) }
        let alternatives = candidates.filter { ($0.politicianID ?? $0.representative) != previousMember }
        if !alternatives.isEmpty { candidates = alternatives }
        func factors(_ trade: DisclosureTrade) -> [Double] {
            // A listed security comes first: a private fund is not something a reader can act on.
            [trade.symbol.isEmpty ? 0 : 1, trade.amount.sortValue, committeeLink(trade) ? 1 : 0, trade.isOption ? 1 : 0, trade.isLate ? 1 : 0, followed.contains(trade.politicianID ?? "") ? 1 : 0]
        }
        return candidates.sorted {
            let lhs = factors($0), rhs = factors($1)
            for index in lhs.indices where lhs[index] != rhs[index] { return lhs[index] > rhs[index] }
            return $0.id.uuidString < $1.id.uuidString
        }.first
    }

    static func committeeLink(_ trade: DisclosureTrade) -> Bool {
        trade.rankingReasons.contains("Relevant committee or policy connection")
    }
}
