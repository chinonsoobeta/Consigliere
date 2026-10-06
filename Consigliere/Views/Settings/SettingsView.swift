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
                    ForEach(appState.sourceHealth) { source in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Label(source.displayName, systemImage: "server.rack")
                                Spacer()
                                Text(source.status.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(source.status.color)
                            }
                            if let lastSuccess = source.lastSuccessAt {
                                Text("settings.lastSync \(lastSuccess, format: Date.FormatStyle(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if source.status != .unconfigured, let message = source.message, !message.isEmpty {
                                Text(message).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if appState.sourceHealth.isEmpty {
                        Label("settings.sourcesUnavailable", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    NavigationLink("settings.sources") { MethodologyView() }
                }
                Section("settings.legal") {
                    Text("disclaimer.full").font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("settings.privacy") { PrivacyView() }
                }
                Section {
                    Text("settings.version \(Self.appVersion)")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("settings.title")
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

struct PrivacyView: View {
    var body: some View {
        List {
            Section("privacy.collected") { Text("privacy.collected.body") }
            Section("privacy.device") { Text("privacy.device.body") }
            Section("privacy.network") { Text("privacy.network.body") }
        }
        .navigationTitle("settings.privacy")
        .navigationBarTitleDisplayMode(.inline)
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
