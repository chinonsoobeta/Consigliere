import Foundation

enum PoliticianPrototypeData {
    static func loadRoster() throws -> [Politician] {
        let url = Bundle.main.url(forResource: "current-politicians", withExtension: "json", subdirectory: "Data")
            ?? Bundle.main.url(forResource: "current-politicians", withExtension: "json")
        guard let url else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([Politician].self, from: Data(contentsOf: url))
    }

    static let disclosures: [DisclosureTrade] = [
        trade(
            politicianID: "P000197", symbol: "GOOGL", assetName: "Alphabet Inc. Class A call options",
            type: .purchase, owner: .spouse, amount: "$500,001–$1,000,000",
            transaction: "2020-02-27", filed: "2020-03-09",
            source: "https://disclosures-clerk.house.gov/public_disc/ptr-pdfs/2020/20016340.pdf", slope: 0.16
        ),
        trade(
            politicianID: "P000197", symbol: "MSFT", assetName: "Microsoft Corporation call options",
            type: .purchase, owner: .spouse, amount: "$500,001–$1,000,000",
            transaction: "2020-02-27", filed: "2020-03-09",
            source: "https://disclosures-clerk.house.gov/public_disc/ptr-pdfs/2020/20016340.pdf", slope: 0.11
        ),
        trade(
            politicianID: "P000197", symbol: "NVDA", assetName: "NVIDIA Corporation",
            type: .sale, owner: .spouse, amount: "$1,000,001–$5,000,000",
            transaction: "2024-06-24", filed: "2024-07-02",
            source: "https://disclosures-clerk.house.gov/public_disc/ptr-pdfs/2024/20025368.pdf", slope: -0.08
        )
    ]

    static let modelPortfolios: [PoliticianModelPortfolio] = [
        PoliticianModelPortfolio(
            politicianID: "P000197",
            asOfDate: date("2026-05-15"),
            positions: [
                ModelPosition(symbol: "AAPL", name: "Apple", weight: 0.25, owner: .spouse, sourceDate: date("2026-05-15"), estimated: true),
                ModelPosition(symbol: "NVDA", name: "NVIDIA", weight: 0.22, owner: .spouse, sourceDate: date("2026-05-15"), estimated: true),
                ModelPosition(symbol: "MSFT", name: "Microsoft", weight: 0.20, owner: .spouse, sourceDate: date("2026-05-15"), estimated: true),
                ModelPosition(symbol: "GOOGL", name: "Alphabet", weight: 0.18, owner: .spouse, sourceDate: date("2026-05-15"), estimated: true),
                ModelPosition(symbol: "AMZN", name: "Amazon", weight: 0.15, owner: .spouse, sourceDate: date("2026-05-15"), estimated: true)
            ],
            performance: performance(seed: 0.82),
            methodologyNote: "Equal-weighted within disclosed value bands, then adjusted to the latest annual report. Options are represented by their underlying security. Values are estimates, not reconstructed brokerage positions."
        )
    ]

    private static func trade(
        politicianID: String, symbol: String, assetName: String, type: DisclosureTransactionType,
        owner: DisclosureOwner, amount: String, transaction: String, filed: String, source: String, slope: Double
    ) -> DisclosureTrade {
        DisclosureTrade(
            id: UUID(), politicianID: politicianID, symbol: symbol, assetName: assetName, type: type,
            owner: owner, amountRange: amount, transactionDate: date(transaction), filedDate: date(filed),
            sourceURL: URL(string: source)!, eventStudy: eventStudy(slope: slope)
        )
    }

    private static func eventStudy(slope: Double) -> [EventStudyPoint] {
        stride(from: -30, through: 90, by: 1).map { day in
            let market = Double(day) * 0.00055 + sin(Double(day) / 7) * 0.008
            let sector = market + sin(Double(day) / 5) * 0.006
            let eventEffect = day > 0 ? Double(day) * slope / 90 : Double(day) * 0.0014
            return EventStudyPoint(tradingDay: day, securityReturn: market + eventEffect, benchmarkReturn: market, sectorReturn: sector)
        }
    }

    private static func performance(seed: Double) -> [ModelPerformancePoint] {
        (0...24).map { month in
            let baseDate = Calendar.current.date(byAdding: .month, value: month - 24, to: .now) ?? .now
            let benchmark = 100 + Double(month) * 1.05 + sin(Double(month) * 0.55) * 2.8
            let publicValue = 100 + Double(month) * (1.1 + seed / 3) + sin(Double(month) * 0.62) * 4.1
            let reportedValue = publicValue + 2.4 + sin(Double(month) * 0.31) * 2.2
            return ModelPerformancePoint(id: UUID(), date: baseDate, reportedValue: reportedValue, publicValue: publicValue, benchmarkValue: benchmark)
        }
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value + "T12:00:00Z") ?? .now
    }
}
