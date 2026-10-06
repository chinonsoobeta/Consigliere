import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("tab.brief", systemImage: "newspaper.fill") }
            IntelligenceLibraryView(scope: .disclosures)
                .tabItem { Label("tab.disclosures", systemImage: IntelligenceLibraryScope.disclosures.icon) }
            InstrumentSearchView()
                .tabItem { Label("tab.research", systemImage: "magnifyingglass") }
            IntelligenceLibraryView(scope: .markets)
                .tabItem { Label("tab.markets", systemImage: IntelligenceLibraryScope.markets.icon) }
            SettingsView()
                .tabItem { Label("tab.settings", systemImage: "gearshape.fill") }
        }
        .tint(ConsigliereTheme.gold)
    }
}
