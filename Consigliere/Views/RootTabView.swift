import SwiftUI

enum RootTab: Hashable {
    case latest, trades, members, markets, settings
}

struct RootTabView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var selection = RootTab.latest

    var body: some View {
        TabView(selection: $selection) {
            HomeView(selectedTab: $selection)
                .tabItem { Label("tab.latest", systemImage: "newspaper") }
                .tag(RootTab.latest)
            TradesView()
                .tabItem { Label("tab.trades", systemImage: "list.bullet.rectangle") }
                .tag(RootTab.trades)
            MembersView()
                .tabItem { Label("tab.members", systemImage: "person.2") }
                .tag(RootTab.members)
            if appState.marketsEnabled {
                MarketsView()
                    .tabItem { Label("tab.markets", systemImage: "chart.line.uptrend.xyaxis") }
                    .tag(RootTab.markets)
            }
            SettingsView()
                .tabItem { Label("tab.settings", systemImage: "gearshape") }
                .tag(RootTab.settings)
        }
        .tint(ConsigliereTheme.accent)
        .sheet(isPresented: Binding(get: { !hasSeenOnboarding }, set: { if !$0 { hasSeenOnboarding = true } })) {
            OnboardingView { hasSeenOnboarding = true }
                .interactiveDismissDisabled()
        }
    }
}
