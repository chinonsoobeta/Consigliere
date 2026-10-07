import Charts
import SwiftUI

struct ParliamentAttribution: View {
    var body: some View {
        Link(destination: URL(string: "https://www.parliament.uk/site-information/copyright/open-parliament-licence/")!) {
            Text(verbatim: "Contains Parliamentary information licensed under the Open Parliament Licence v3.0.")
        }
        .font(.caption)
    }
}

struct Wordmark: View {
    var compact = false
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: compact ? 9 : 12)
                    .fill(ConsigliereTheme.navy.gradient)
                Image(systemName: "building.columns.fill")
                    .foregroundStyle(ConsigliereTheme.gold)
                    .font(.system(size: compact ? 16 : 22, weight: .semibold))
            }
            .frame(width: compact ? 34 : 44, height: compact ? 34 : 44)
            Text("Consigliere")
                .font(compact ? .headline : .title2.weight(.bold))
                .tracking(-0.4)
        }
        .accessibilityElement(children: .combine)
    }
}

struct FreshnessBadge: View {
    let freshness: DataFreshness
    var body: some View {
        Label(freshness.label, systemImage: freshness == .live ? "dot.radiowaves.left.and.right" : "clock.badge.exclamationmark")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(freshness.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(freshness.color.opacity(0.12), in: Capsule())
    }
}

struct ChangeLabel: View {
    let value: Double
    var body: some View {
        Label(value.signedPercent, systemImage: value >= 0 ? "arrow.up.right" : "arrow.down.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(value >= 0 ? ConsigliereTheme.positive : ConsigliereTheme.negative)
            .accessibilityLabel(value >= 0 ? Text("change.up \(value.signedPercent)") : Text("change.down \(value.signedPercent)"))
    }
}

struct MiniChart: View {
    let instrument: MarketInstrument
    var body: some View {
        Chart(instrument.history) { point in
            LineMark(x: .value("Time", point.timestamp), y: .value("Value", point.value))
                .foregroundStyle(instrument.changePercent >= 0 ? ConsigliereTheme.positive : ConsigliereTheme.negative)
                .interpolationMethod(.catmullRom)
            AreaMark(x: .value("Time", point.timestamp), y: .value("Value", point.value))
                .foregroundStyle(.linearGradient(colors: [(instrument.changePercent >= 0 ? ConsigliereTheme.positive : ConsigliereTheme.negative).opacity(0.22), .clear], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .accessibilityLabel(Text("chart.trend \(instrument.name)"))
    }
}

struct MarketCard: View {
    let instrument: MarketInstrument
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(instrument.symbol).font(.headline.monospaced())
                    Text(instrument.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                ChangeLabel(value: instrument.changePercent)
            }
            MiniChart(instrument: instrument).frame(height: 44)
            HStack {
                Text(instrument.formattedPrice).font(.subheadline.weight(.semibold))
                Spacer()
                FreshnessBadge(freshness: instrument.freshness)
            }
        }
        .frame(width: 196, height: 130)
        .consigliereCard()
    }
}

struct ImpactBadge: View {
    let impact: ImpactLevel
    var body: some View {
        Label(impact.label, systemImage: impact.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(impact.color)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(impact.color.opacity(0.12), in: Capsule())
    }
}

struct EventCard: View {
    let event: MarketEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(event.source.label, systemImage: event.source.icon)
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                EventDateText(event: event).font(.caption).foregroundStyle(.secondary)
            }
            Text(event.title).font(.headline).foregroundStyle(.primary)
            Text("event.whyItMatters").font(.caption.weight(.bold)).foregroundStyle(ConsigliereTheme.gold)
            Text(event.explanation).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            if let reason = event.rankingReasons.first {
                Label(reason, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                ImpactBadge(impact: event.impact)
                Spacer()
                HStack(spacing: 5) {
                    ForEach(event.mentionedSymbols.prefix(3), id: \.self) { symbol in
                        Text(symbol).font(.caption2.monospaced().weight(.bold)).padding(.horizontal, 6).padding(.vertical, 4).background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .consigliereCard()
    }
}

/// Disclosure events carry calendar dates only, so they show the filing day (in UTC) rather
/// than a misleading relative time; timestamped posts keep relative times.
struct EventDateText: View {
    let event: MarketEvent
    var body: some View {
        if event.isDateOnly {
            Text(event.publishedAt, format: DisclosureDates.style())
        } else {
            Text(event.publishedAt, style: .relative)
        }
    }
}

struct SourceUnavailableView: View {
    let title: LocalizedStringKey
    let message: Text
    var systemImage = "antenna.radiowaves.left.and.right.slash"
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            message.font(.subheadline).foregroundStyle(.secondary)
            if let retry {
                Button("common.retry", action: retry).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .consigliereCard()
    }
}

/// Empty state that explains *why* a feed is empty using source health: a provider that is not
/// configured needs an operator, not a retry; a failed provider can be retried.
struct SourceAwareEmptyView: View {
    @EnvironmentObject private var appState: AppState
    let providers: [String]
    let emptyTitle: LocalizedStringKey
    let emptyMessage: LocalizedStringKey

    private var sources: [SourceHealth] { providers.compactMap(appState.health(for:)) }

    var body: some View {
        if appState.isAwaitingFirstLoad || appState.isLoading {
            ProgressView("common.loading")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else if let error = appState.disclosureLoadError {
            SourceUnavailableView(
                title: "source.serviceUnavailable",
                message: Text(error),
                retry: { Task { await appState.load(force: true) } }
            )
        } else if !sources.isEmpty, sources.allSatisfy({ $0.status == .unconfigured }) {
            SourceUnavailableView(
                title: "source.notConfigured",
                message: Text("source.notConfigured.body \(sources.map(\.displayName).joined(separator: ", "))"),
                systemImage: "powerplug"
            )
        } else if let failed = sources.first(where: { $0.status == .failed }) {
            SourceUnavailableView(
                title: "source.failed",
                message: Text("source.failed.body \(failed.displayName)"),
                retry: { Task { await appState.load(force: true) } }
            )
        } else {
            SourceUnavailableView(
                title: emptyTitle,
                message: Text(emptyMessage),
                systemImage: "tray",
                retry: { Task { await appState.load(force: true) } }
            )
        }
    }
}

struct PendingFilingRow: View {
    let filing: PendingFiling

    var body: some View {
        Link(destination: filing.sourceURL) {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.clock")
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Color.secondary.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(filing.representative).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text("pending.filed \(DisclosureDates.day(filing.filedDate) ?? .now, format: DisclosureDates.style())")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("pending.status").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PoliticianAvatar: View {
    let politician: Politician?
    var fallbackName = ""
    var size: CGFloat = 44

    var body: some View {
        AsyncImage(url: politician?.imageURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill().frame(width: size, height: size, alignment: .top)
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().stroke(.primary.opacity(0.08), lineWidth: 1) }
        .accessibilityHidden(true)
    }

    private var initials: some View {
        let parts = (politician?.name ?? fallbackName).split(separator: " ")
        let letters = [parts.first, parts.count > 1 ? parts.last : nil].compactMap { $0?.first }.map(String.init).joined()
        let tint = politician?.partyColor ?? .secondary
        return ZStack {
            Circle().fill(tint.opacity(0.14))
            Text(verbatim: letters).font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(tint)
        }
    }
}

struct TradeTypePill: View {
    let type: DisclosureTransactionType
    var body: some View {
        Text(type.shortLabel)
            .font(.caption2.weight(.heavy))
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(type.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(type.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Marks an options trade so it is not read as a trade in the stock itself.
struct OptionsTag: View {
    var body: some View {
        Text("trade.options")
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.secondary.opacity(0.5)))
    }
}

/// "$1K–$15K", "$50M+", or the filed text when it cannot be parsed.
struct AmountText: View {
    let amount: AmountRange
    // Currency compact notation needs iOS 18; filings are always in U.S. dollars.
    private static let style = FloatingPointFormatStyle<Double>.number.notation(.compactName)

    var body: some View {
        switch (amount.lower, amount.upper) {
        case let (lower?, upper?):
            dollars(lower) + Text(verbatim: "–") + dollars(upper)
        case let (lower?, nil):
            dollars(lower) + Text(verbatim: "+")
        default:
            Text(verbatim: amount.raw)
        }
    }

    private func dollars(_ value: Double) -> Text {
        Text(verbatim: "$") + Text(value, format: Self.style)
    }
}

struct ChamberTag: View {
    let chamber: Chamber
    var body: some View {
        Text(chamber.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

/// A single transaction. With `showsMember` the row leads with who traded; without it (inside a
/// filing or profile) it leads with what was traded.
struct TradeRow: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let trade: DisclosureTrade
    var showsMember = true
    @State private var showStock = false

    private var politician: Politician? { appState.politician(id: trade.politicianID) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsMember {
                PoliticianAvatar(politician: politician, fallbackName: trade.representative, size: 40)
            }
            VStack(alignment: .leading, spacing: 4) {
                let summaryLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
                summaryLayout {
                    TradeTypePill(type: trade.type)
                    if !trade.symbol.isEmpty {
                        Button { showStock = true } label: { Text(verbatim: trade.displaySymbol).font(.headline.monospaced()) }
                            .buttonStyle(.borderless)
                    } else { Text(verbatim: trade.displaySymbol).font(.headline).lineLimit(1) }
                    if trade.isOption { OptionsTag() }
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    AmountText(amount: trade.amount)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                if showsMember {
                    (Text(verbatim: politician?.name ?? trade.representative).foregroundStyle(.primary)
                        + Text(verbatim: politician.map { " · \($0.shortLabel)" } ?? "").foregroundStyle(.secondary))
                        .font(.subheadline)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                } else {
                    Text(verbatim: trade.assetName).font(.subheadline).foregroundStyle(.secondary).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
                detailLine.font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(trade.type.label) + Text(verbatim: " · " + trade.displaySymbol + " · " + trade.amountRange + (showsMember ? " · " + (politician?.name ?? trade.representative) : "")) + Text(verbatim: " · ") + detailLine)
        .navigationDestination(isPresented: $showStock) { StockDetailView(symbol: trade.symbol) }
    }

    private var detailLine: Text {
        var line = Text("trade.dates \(trade.transactionDate, format: DisclosureDates.compact(trade.transactionDate)) \(trade.filedDate, format: DisclosureDates.compact(trade.filedDate))")
        if trade.owner != .member { line = line + Text(verbatim: " · ") + Text(trade.owner.label) }
        if trade.isLate { line = line + Text(verbatim: " · ") + Text("trade.late").foregroundStyle(.orange) }
        return line
    }
}

/// One periodic transaction report, summarised as its largest distinct trades.
struct FilingRow: View {
    @EnvironmentObject private var appState: AppState
    let filing: TradeFiling
    var emphasizesLag = false

    private var politician: Politician? { appState.politician(id: filing.politicianID) }

    private var highlights: (shown: [DisclosureTrade], more: Int) {
        var seen = Set<String>()
        let distinct = filing.bySize.filter { seen.insert("\($0.type.rawValue)|\($0.displaySymbol)").inserted }
        return (Array(distinct.prefix(2)), max(distinct.count - 2, 0))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PoliticianAvatar(politician: politician, fallbackName: filing.representative, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: politician?.name ?? filing.representative).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(filing.filedDate, format: DisclosureDates.compact(filing.filedDate)).font(.caption).foregroundStyle(.secondary)
                }
                if let politician {
                    HStack(spacing: 6) {
                        Text(verbatim: politician.shortLabel).font(.caption.weight(.semibold)).foregroundStyle(politician.partyColor)
                        ChamberTag(chamber: politician.chamber)
                    }
                }
                summary.font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                if emphasizesLag {
                    Text("filing.lateBy \(filing.maxLagDays)").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var summary: Text {
        let (shown, more) = highlights
        var text = Text(verbatim: "")
        for (index, trade) in shown.enumerated() {
            if index > 0 { text = text + Text(verbatim: " · ") }
            text = text + trade.type.headline(trade.displaySymbol)
        }
        if more > 0 { text = text + Text(verbatim: " ") + Text("filing.more \(more)").foregroundStyle(.secondary) }
        return text
    }
}
