import SwiftUI
import UIKit

/// Dark-first palette: deep ink grounds, a violet accent, and buy/sell colours that also differ
/// in lightness so they never rely on hue alone. Every colour adapts to light mode with
/// contrast kept at 4.5:1 or better for text.
enum ConsigliereTheme {
    static let background = dynamic(light: 0xF6F4FB, dark: 0x0B0A12)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x15131F)
    static let raised = dynamic(light: 0xEEEAF7, dark: 0x1E1B2C)
    static let hairline = dynamic(light: 0xE2DCEF, dark: 0x2A2640)
    /// The brand colour and interactive tint.
    static let accent = dynamic(light: 0x6D28D9, dark: 0xA78BFA)
    /// Text on an accent fill.
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0B0A12)
    static let accentSoft = dynamic(light: 0xEDE6FD, dark: 0x2A2145)
    static let positive = dynamic(light: 0x047857, dark: 0x34D399)
    static let negative = dynamic(light: 0xBE123C, dark: 0xFB7185)
    static let warning = dynamic(light: 0xB45309, dark: 0xFBBF24)
    static let democrat = dynamic(light: 0x1D4ED8, dark: 0x7AA7FF)
    static let republican = dynamic(light: 0xB91C1C, dark: 0xFF8A80)
    static let cardRadius: CGFloat = 22

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiDynamic(light: light, dark: dark))
    }

    static func uiDynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }

    /// Editorial serif for titles and headlines; scales with Dynamic Type.
    static func display(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .serif, weight: weight)
    }

    /// Navigation and tab bars are UIKit; style them once at launch.
    static func configureBars() {
        let serif = { (style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont in
            let base = UIFont.preferredFont(forTextStyle: style)
            let descriptor = UIFont.systemFont(ofSize: base.pointSize, weight: weight).fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            return UIFontMetrics(forTextStyle: style).scaledFont(for: UIFont(descriptor: descriptor, size: base.pointSize))
        }
        // Appearance objects hide large titles on iOS 26; the bar's own attributes do not.
        let text = UIColor.label
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: serif(.largeTitle, .semibold), .foregroundColor: text]
        UINavigationBar.appearance().titleTextAttributes = [.font: serif(.headline, .semibold), .foregroundColor: text]

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = uiDynamic(light: 0xFFFFFF, dark: 0x100E19)
        tab.shadowColor = uiDynamic(light: 0xE2DCEF, dark: 0x2A2640)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        UISegmentedControl.appearance().selectedSegmentTintColor = uiDynamic(light: 0x6D28D9, dark: 0xA78BFA)
        // Ink on the light violet in dark mode; white on the deep violet in light mode.
        let selectedText = uiDynamic(light: 0xFFFFFF, dark: 0x0B0A12)
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: selectedText], for: .selected)
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: selectedText], for: [.selected, .highlighted])
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

extension View {
    /// Every tab's stack can open any record, so destinations are registered once per stack.
    func consigliereDestinations() -> some View {
        self
            .navigationDestination(for: StockRoute.self) { StockDetailView(symbol: $0.symbol) }
            .navigationDestination(for: PresidentialStatement.self) { StatementDetailView(statement: $0) }
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
            .background(ConsigliereTheme.surface, in: RoundedRectangle(cornerRadius: ConsigliereTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ConsigliereTheme.cardRadius, style: .continuous)
                    .stroke(ConsigliereTheme.hairline, lineWidth: 1)
            }
    }

    /// Ink ground behind a scrolling screen.
    func consigliereScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(ConsigliereTheme.background)
    }
}

/// An inset-grouped list on the themed ground with themed row surfaces. A row that sets its
/// own `listRowBackground` (a clear hero, say) keeps it.
struct ThemedList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        List {
            content.listRowBackground(ConsigliereTheme.surface)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .consigliereScreen()
    }
}

/// Section titles in the editorial serif rather than small caps.
struct SectionTitle: View {
    let text: Text
    init(_ key: LocalizedStringKey) { text = Text(key) }
    init(_ text: Text) { self.text = text }

    var body: some View {
        text
            .font(ConsigliereTheme.display(.title3))
            .foregroundStyle(Color(uiColor: .label))
            .textCase(nil)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Small uppercase label in the accent, used above headlines.
struct Eyebrow: View {
    let text: Text
    var body: some View {
        text
            .font(.caption.weight(.semibold))
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(ConsigliereTheme.accent)
    }
}

extension Double {
    var signedPercent: String {
        formatted(.percent.sign(strategy: .always()).precision(.fractionLength(2)).scale(1))
    }
}

extension Section where Parent == SectionTitle, Footer == EmptyView, Content: View {
    /// A section headed by a serif `SectionTitle`.
    init(themed key: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { SectionTitle(key) })
    }
}
