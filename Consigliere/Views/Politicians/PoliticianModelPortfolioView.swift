import Charts
import SwiftUI

struct PoliticianModelPortfolioView: View {
    let politician: Politician
    let portfolio: PoliticianModelPortfolio
    @State private var mode = ModelPortfolioMode.publicInformation

    private var firstPoint: ModelPerformancePoint? { portfolio.performance.first }
    private var lastPoint: ModelPerformancePoint? { portfolio.performance.last }
    private var modelReturn: Double {
        guard let firstPoint, let lastPoint else { return 0 }
        return portfolio.value(for: lastPoint, mode: mode) / portfolio.value(for: firstPoint, mode: mode) - 1
    }
    private var benchmarkReturn: Double {
        guard let firstPoint, let lastPoint else { return 0 }
        return lastPoint.benchmarkValue / firstPoint.benchmarkValue - 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                modeSelector
                performance
                positions
                methodology
                DisclaimerBanner()
            }.padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("model.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(politician.name).font(.largeTitle.bold())
            Text("model.subtitle").foregroundStyle(.secondary)
            HStack { FreshnessBadge(freshness: .prototype); Text("model.updated \(portfolio.asOfDate.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("model.view", selection: $mode) { ForEach(ModelPortfolioMode.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
            Text(mode == .reportedHoldings ? "model.reportedDescription" : "model.publicDescription").font(.caption).foregroundStyle(.secondary)
        }.consigliereCard()
    }

    private var performance: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) { Text("model.twoYearReturn").font(.caption).foregroundStyle(.secondary); Text(modelReturn, format: .percent.precision(.fractionLength(1))).font(.title2.bold()).foregroundStyle(modelReturn >= 0 ? ConsigliereTheme.positive : ConsigliereTheme.negative) }
                Spacer()
                VStack(alignment: .trailing) { Text("model.benchmark").font(.caption).foregroundStyle(.secondary); Text(benchmarkReturn, format: .percent.precision(.fractionLength(1))).font(.headline) }
            }
            Chart {
                ForEach(portfolio.performance) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Model", portfolio.value(for: point, mode: mode)), series: .value("Series", "Model"))
                        .foregroundStyle(ConsigliereTheme.gold).lineStyle(StrokeStyle(lineWidth: 3)).interpolationMethod(.catmullRom)
                    LineMark(x: .value("Date", point.date), y: .value("Benchmark", point.benchmarkValue), series: .value("Series", "S&P 500"))
                        .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5])).interpolationMethod(.catmullRom)
                }
            }.chartYAxis { AxisMarks(position: .leading) }.frame(height: 250)
            HStack { Label("model.portfolioLine", systemImage: "minus").foregroundStyle(ConsigliereTheme.gold); Spacer(); Label("model.benchmarkLine", systemImage: "minus").foregroundStyle(.secondary) }.font(.caption)
        }.consigliereCard()
    }

    private var positions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("model.constituents").font(.title3.bold())
            ForEach(portfolio.positions) { position in
                HStack {
                    VStack(alignment: .leading, spacing: 3) { Text(position.symbol).font(.headline.monospaced()); Text(position.name).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) { Text(position.weight, format: .percent).font(.headline.monospacedDigit()); Text(position.owner.label).font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 4)
                if position.id != portfolio.positions.last?.id { Divider() }
            }
        }.consigliereCard()
    }

    private var methodology: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("model.methodology", systemImage: "doc.text.magnifyingglass").font(.headline)
            Text(portfolio.methodologyNote).font(.footnote).foregroundStyle(.secondary)
            Text("model.notETF").font(.footnote.weight(.semibold)).foregroundStyle(.orange)
            Text("model.lookAhead").font(.footnote).foregroundStyle(.secondary)
        }.consigliereCard()
    }
}
