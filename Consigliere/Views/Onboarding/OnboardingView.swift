import SwiftUI

/// Shown once. Sets expectations (filings arrive weeks after trades) and carries the disclaimer
/// so individual screens do not have to.
struct OnboardingView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    Wordmark()
                        .padding(.top, 48)
                    Text("onboarding.title")
                        .font(ConsigliereTheme.display(.largeTitle))
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 24) {
                        feature("doc.text.magnifyingglass", "onboarding.filings.title", "onboarding.filings.body")
                        feature("clock", "onboarding.timing.title", "onboarding.timing.body")
                        feature("star", "onboarding.follow.title", "onboarding.follow.body")
                    }
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 16) {
                Text("onboarding.disclaimer")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: onContinue) {
                    Text("onboarding.continue")
                        .font(.headline)
                        .foregroundStyle(ConsigliereTheme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(ConsigliereTheme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(24)
        }
        .background(ConsigliereTheme.background)
    }

    private func feature(_ icon: String, _ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ConsigliereTheme.accent)
                .frame(width: 48, height: 48)
                .background(ConsigliereTheme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
