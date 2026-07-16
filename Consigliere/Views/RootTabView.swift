import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Brief", systemImage: "newspaper.fill") }
            IntelligenceLibraryView(scope: .disclosures)
                .tabItem { Label("Disclosures", systemImage: IntelligenceLibraryScope.disclosures.icon) }
            IntelligenceLibraryView(scope: .politics)
                .tabItem { Label("Politics", systemImage: IntelligenceLibraryScope.politics.icon) }
            IntelligenceLibraryView(scope: .markets)
                .tabItem { Label("Markets", systemImage: IntelligenceLibraryScope.markets.icon) }
            InstrumentSearchView()
                .tabItem { Label("Research", systemImage: "magnifyingglass") }
            SettingsView()
                .tabItem { Label("tab.settings", systemImage: "gearshape.fill") }
        }
        .tint(ConsigliereTheme.gold)
    }
}
