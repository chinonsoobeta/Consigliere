import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack { Spacer(); Wordmark(); Spacer() }
                    Text("settings.about.body").font(.subheadline).foregroundStyle(.secondary)
                }
                Section("settings.appearance") {
                    Picker("settings.theme", selection: Binding(get: { appState.appearance }, set: { appState.appearance = $0 })) {
                        ForEach(Appearance.allCases) { appearance in Text(appearance.label).tag(appearance) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("settings.language") {
                    Picker("settings.language", selection: Binding(get: { appState.language }, set: { appState.language = $0 })) {
                        ForEach(AppLanguage.allCases) { language in Text(language.label).tag(language) }
                    }
                }
                Section("settings.data") {
                    Label("settings.prototype", systemImage: "testtube.2").foregroundStyle(.indigo)
                    NavigationLink("settings.sources") { MethodologyView() }
                }
                Section("settings.legal") {
                    Text("disclaimer.full").font(.footnote).foregroundStyle(.secondary)
                    Link("settings.privacy", destination: URL(string: "https://github.com/chinonsoobeta/Consigliere")!)
                }
                Section { Text("Version 0.1.0 · Prototype").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }
            .navigationTitle("settings.title")
        }
    }
}

struct MethodologyView: View {
    var body: some View {
        List {
            Section("methodology.events") { Text("methodology.events.body") }
            Section("methodology.disclosures") { Text("methodology.disclosures.body") }
            Section("methodology.prices") { Text("methodology.prices.body") }
            Section("methodology.personalization") { Text("methodology.personalization.body") }
        }
        .navigationTitle("settings.sources")
        .navigationBarTitleDisplayMode(.inline)
    }
}
