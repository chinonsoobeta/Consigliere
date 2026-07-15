import Charts
import SwiftUI

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
            .accessibilityLabel(value >= 0 ? "Up \(value.signedPercent)" : "Down \(value.signedPercent)")
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
        .accessibilityLabel("Four hour price trend for \(instrument.name)")
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
                Text(event.publishedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
            Text(event.title).font(.headline).foregroundStyle(.primary)
            Text(event.explanation).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
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

struct DisclaimerBanner: View {
    var body: some View {
        Label("disclaimer.short", systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }
}
