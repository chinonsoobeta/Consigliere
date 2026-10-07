import SwiftUI

@main
struct ConsigliereApp: App {
    @StateObject private var appState = AppState()

    init() { ConsigliereTheme.configureBars() }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                // Navigation bar titles are cached by UIKit; rebuild the tree when the language changes.
                .id(appState.language)
                .environmentObject(appState)
                .preferredColorScheme(appState.appearance.colorScheme)
                .environment(\.locale, appState.language.locale)
                .task { await appState.load() }
        }
    }
}

