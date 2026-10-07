import SwiftUI

struct DeclaredInterestsView: View {
    @EnvironmentObject private var appState: AppState
    let country: Country
    var member: Politician? = nil
    @State private var interests: [DeclaredInterest] = []
    @State private var error: String?

    var body: some View {
        List {
            if let member { Section { MemberHeaderRow(politician: member); Button(appState.isFollowing(member) ? "profile.unfollow" : "profile.follow") { appState.toggleFollow(member) } } }
            Section { Text("interests.method").font(.caption); if country == .uk { ParliamentAttribution() } }
            if let error { Text(verbatim: error).foregroundStyle(.orange); Button("common.retry") { Task { await load() } } }
            if interests.isEmpty && error == nil { Text("interests.empty") }
            ForEach(interests) { interest in
                Section {
                    if member == nil, let politician = appState.politician(id: interest.memberID) {
                        NavigationLink(value: politician) { MemberHeaderRow(politician: politician) }
                    }
                    Text(verbatim: interest.organisation).font(.headline)
                    if let threshold = interest.thresholdText { Text(verbatim: threshold) }
                    if let symbol = interest.ticker { NavigationLink(value: StockRoute(symbol: symbol)) { Text(verbatim: symbol) } }
                    else { Text("interests.unmatched").font(.caption).foregroundStyle(.secondary) }
                    Text(LocalizedStringKey(stringLiteral: "interests.action.\(interest.action)"))
                    Text(LocalizedStringKey(stringLiteral: "interests.owner.\(interest.owner)"))
                    if let date = interest.registeredAt { LabeledContent("interests.registered", value: date) }
                    if let date = interest.effectiveAt { LabeledContent("interests.effective", value: date) }
                    if let date = interest.publishedAt { LabeledContent("interests.published", value: date) }
                    if let date = interest.endedAt { LabeledContent("interests.ended", value: date) }
                    Link("event.openSource", destination: interest.sourceURL)
                }
            }
        }
        .navigationTitle("interests.title")
        .task { await load() }
    }

    private func load() async {
        do { interests = try await appState.loadInterests(country: country, memberID: member?.id); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
