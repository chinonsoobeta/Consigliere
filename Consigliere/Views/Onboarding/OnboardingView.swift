import SwiftUI

/// Shown once. Sets expectations (filings arrive weeks after trades) and carries the disclaimer
/// so individual screens do not have to.
struct OnboardingView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Wordmark()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    Text("onboarding.title")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                    feature("doc.text.magnifyingglass", "onboarding.filings.title", "onboarding.filings.body")
                    feature("clock.badge.exclamationmark", "onboarding.timing.title", "onboarding.timing.body")
                    feature("star", "onboarding.follow.title", "onboarding.follow.body")
                }
                .padding(.horizontal, 28)
            }
            VStack(spacing: 14) {
                Text("onboarding.disclaimer")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: onContinue) {
                    Text("onboarding.continue").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(ConsigliereTheme.navy)
                .controlSize(.large)
            }
            .padding(24)
        }
    }

    private func feature(_ icon: String, _ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(ConsigliereTheme.accent)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
