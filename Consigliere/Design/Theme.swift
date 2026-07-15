import SwiftUI

enum ConsigliereTheme {
    static let navy = Color(red: 0.06, green: 0.12, blue: 0.20)
    static let gold = Color(red: 0.82, green: 0.64, blue: 0.24)
    static let positive = Color(red: 0.10, green: 0.58, blue: 0.38)
    static let negative = Color(red: 0.78, green: 0.23, blue: 0.24)
    static let cardRadius: CGFloat = 20
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

