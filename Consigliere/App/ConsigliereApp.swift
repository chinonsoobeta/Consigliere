import SwiftUI

@main
struct ConsigliereApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(appState)
                .preferredColorScheme(appState.appearance.colorScheme)
                .environment(\.locale, appState.language.locale)
                .task { await appState.load() }
        }
    }
}

