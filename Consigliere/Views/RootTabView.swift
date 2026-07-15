import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("tab.pulse", systemImage: "waveform.path.ecg") }
            InstrumentSearchView()
                .tabItem { Label("tab.search", systemImage: "magnifyingglass") }
            PortfolioView()
                .tabItem { Label("tab.portfolio", systemImage: "chart.pie.fill") }
            SettingsView()
                .tabItem { Label("tab.settings", systemImage: "gearshape.fill") }
        }
        .tint(ConsigliereTheme.gold)
    }
}

