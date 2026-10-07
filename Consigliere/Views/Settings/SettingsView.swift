import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ThemedList {
                Section {
                    VStack(spacing: 10) {
                        Wordmark()
                        Text("settings.about.body").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                Section(themed: "settings.appearance") {
                    Picker("settings.theme", selection: Binding(get: { appState.appearance }, set: { appState.appearance = $0 })) {
                        ForEach(Appearance.allCases) { appearance in Text(appearance.label).tag(appearance) }
                    }
                    .pickerStyle(.segmented)
                }
                Section(themed: "settings.language") {
                    Picker("settings.language", selection: Binding(get: { appState.language }, set: { appState.language = $0 })) {
                        ForEach(AppLanguage.allCases) { language in Text(verbatim: language.label).tag(language) }
                    }
                }
                Section(themed: "countries.home") {
                    ForEach(Country.available) { country in
                        Toggle(country.label, isOn: Binding(get: { appState.homeCountries.contains(country) }, set: { enabled in
                            var countries = appState.homeCountries
                            if enabled { countries.insert(country) } else { countries.remove(country) }
                            appState.homeCountries = countries
                        }))
                    }
                }
                Section(themed: "settings.data") {
                    NavigationLink { DataSourcesView() } label: {
                        HStack {
                            Text("settings.dataSources")
                            Spacer()
                            StatusDot(status: overallStatus)
                        }
                    }
                    NavigationLink("settings.methodology") { MethodologyView() }
                }
                Section(themed: "settings.legal") {
                    NavigationLink("settings.disclaimer") { DisclaimerView() }
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

    /// Worst status among sources that are expected to work.
    private var overallStatus: SourceAvailability {
        let configured = appState.sourceHealth.filter { $0.status != .unconfigured }
        if appState.sourceHealth.isEmpty || configured.contains(where: { $0.status == .failed }) { return .failed }
        if !appState.sourceAlerts.isEmpty { return .degraded }
        return .available
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

struct StatusDot: View {
    let status: SourceAvailability
    var body: some View {
        Circle().fill(status.color).frame(width: 9, height: 9).accessibilityLabel(Text(status.label))
    }
}

struct DataSourcesView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ThemedList {
            Section {
                ForEach(appState.sourceHealth) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            StatusDot(status: source.status)
                            Text(verbatim: source.displayName).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(source.status.label).font(.caption).foregroundStyle(.secondary)
                        }
                        if let lastSuccess = source.lastSuccessAt {
                            Text("settings.lastSync \(lastSuccess, format: .relative(presentation: .named))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if source.status != .unconfigured, let message = source.message, !message.isEmpty {
                            Text(verbatim: message).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                if appState.sourceHealth.isEmpty {
                    Label("settings.sourcesUnavailable", systemImage: "exclamationmark.triangle").foregroundStyle(ConsigliereTheme.warning)
                }
            } footer: {
                Text("settings.dataSources.footer")
            }
        }
        .navigationTitle("settings.dataSources")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await appState.load(force: true) }
    }
}

struct DisclaimerView: View {
    var body: some View {
        ThemedList {
            Section { Text("disclaimer.full") }
        }
        .navigationTitle("settings.disclaimer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyView: View {
    var body: some View {
        ThemedList {
            Section(themed: "privacy.collected") { Text("privacy.collected.body") }
            Section(themed: "privacy.device") { Text("privacy.device.body") }
            Section(themed: "privacy.network") { Text("privacy.network.body") }
        }
        .navigationTitle("settings.privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MethodologyView: View {
    var body: some View {
        ThemedList {
            Section(themed: "home.notableWeek") { Text("home.notableMethod") }
            Section(themed: "portfolio.method") { Text("portfolio.method.body") }
            Section(themed: "methodology.disclosures") { Text("methodology.disclosures.body") }
            Section(themed: "methodology.late") { Text("methodology.late.body") }
            Section(themed: "methodology.highlights") { Text("methodology.highlights.body") }
            Section(themed: "methodology.matching") { Text("methodology.matching.body") }
            Section(themed: "interests.title") { Text("interests.method"); ParliamentAttribution() }
            Section(themed: "methodology.prices") { Text("methodology.prices.body") }
        }
        .navigationTitle("settings.methodology")
        .navigationBarTitleDisplayMode(.inline)
    }
}
