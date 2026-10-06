import SwiftUI

enum ConsigliereTheme {
    static let navy = Color(red: 0.06, green: 0.12, blue: 0.20)
    static let gold = Color(red: 0.82, green: 0.64, blue: 0.24)
    static let positive = Color(red: 0.10, green: 0.58, blue: 0.38)
    static let negative = Color(red: 0.78, green: 0.23, blue: 0.24)
    static let cardRadius: CGFloat = 20
    /// Interactive tint: a darker gold in light mode keeps links above 4.5:1 contrast on white.
    static let accent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.82, green: 0.64, blue: 0.24, alpha: 1)
            : UIColor(red: 0.56, green: 0.41, blue: 0.08, alpha: 1)
    })
}

extension View {
    /// Every tab's stack can open any record, so destinations are registered once per stack.
    func consigliereDestinations() -> some View {
        self
            .navigationDestination(for: TradeFiling.self) { FilingDetailView(filing: $0) }
            .navigationDestination(for: DisclosureTrade.self) { TradeDetailView(trade: $0) }
            .navigationDestination(for: Politician.self) { PoliticianProfileView(politician: $0) }
            .navigationDestination(for: MarketEvent.self) { EventDetailView(event: $0) }
            .navigationDestination(for: MarketInstrument.self) { InstrumentDetailView(instrument: $0) }
    }
}

extension View {
    func consigliereCard() -> some View {
        self
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ConsigliereTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ConsigliereTheme.cardRadius, style: .continuous)
                    .stroke(.primary.opacity(0.07), lineWidth: 1)
            }
    }
}

extension Double {
    var signedPercent: String {
        formatted(.percent.sign(strategy: .always()).precision(.fractionLength(2)).scale(1))
    }
}

