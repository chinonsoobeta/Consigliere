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

    static func busierThanUsual(_ buckets: [WeeklyBucket]) -> Bool {
        let sorted = buckets.map(\.count).sorted()
        guard !sorted.isEmpty else { return false }
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 0 ? Double(sorted[middle - 1] + sorted[middle]) / 2 : Double(sorted[middle])
        return Double(buckets.last?.count ?? 0) > 1.5 * median
    }

    static func activityHistogram(_ trades: [DisclosureTrade], now: Date = .now) -> [ActivityBucket] {
        let cal = calendar
        let current = cal.dateInterval(of: .month, for: now)!.start
        return (0..<24).reversed().flatMap { offset in
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
            [trade.amount.sortValue, committeeLink(trade) ? 1 : 0, trade.isOption ? 1 : 0, trade.isLate ? 1 : 0, followed.contains(trade.politicianID ?? "") ? 1 : 0]
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
