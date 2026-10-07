import SwiftUI

struct StatementDetailView: View {
    @EnvironmentObject private var appState: AppState
    let statement: PresidentialStatement
    @State private var detail: StatementDetail?
    @State private var error: String?
    @State private var reportError: String?
    @State private var reportTag: StatementTag?
    @State private var reason = ""
    @State private var reported = false
    @State private var showsFullText = false

    var body: some View {
        ThemedList {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: statement.title).font(.title3.bold())
                    HStack(spacing: 4) {
                        Text(verbatim: statement.kind)
                        if let published = DisclosureDates.day(statement.publishedAt) {
                            Text(verbatim: "·")
                            Text(published, format: DisclosureDates.style())
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let signed = statement.signedAt.flatMap(DisclosureDates.day) {
                        Text("statement.signed \(signed.formatted(DisclosureDates.style()))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(highlightedBody)
                    .font(.callout)
                    .lineLimit(showsFullText ? nil : 8)
                if !showsFullText && statement.body.count > 600 {
                    Button("statement.readFull") { showsFullText = true }
                }
                Link("event.openSource", destination: statement.sourceURL)
                if let confirmation = statement.confirmationURL { Link("statement.confirmation", destination: confirmation) }
            }
            if !statement.tags.isEmpty {
                Section {
                    ForEach(statement.tags) { tag in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(verbatim: tag.value).font(.subheadline.weight(.semibold))
                                Text(LocalizedStringKey(stringLiteral: "statement.kind.\(tag.kind)")).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Menu {
                                    Button("statement.report") { reportTag = tag; reason = ""; reported = false; reportError = nil }
                                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                                .accessibilityLabel(Text("statement.report"))
                            }
                            Text(verbatim: "“\(tag.quote)”").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                } header: { SectionTitle("statement.tags") } footer: { Text("statement.tagsFooter") }
            }
            if let error { Text(verbatim: error).foregroundStyle(ConsigliereTheme.warning) }
            if let detail, !detail.holdings.isEmpty || !detail.trades.isEmpty {
                Section(themed: "statement.holdings") {
                    ForEach(detail.holdings) { holding in
                        NavigationLink(value: StockRoute(symbol: holding.ticker)) {
                            LabeledContent {
                                Text("portfolio.memberCount \(holding.membersHolding)").monospacedDigit()
                            } label: { Text(verbatim: holding.ticker).font(.headline.monospaced()) }
                        }
                    }
                    Text("portfolio.estimated").font(.caption)
                }
                Section {
                    ForEach(detail.trades) { trade in
                        NavigationLink(value: trade) { TradeRow(trade: trade) }
                        Text(DisclosureDates.dayFormatter.string(from: trade.transactionDate) < String(statement.publishedAt.prefix(10)) ? "statement.before" : "statement.after").font(.caption).foregroundStyle(.secondary)
                    }
                } header: { SectionTitle("statement.trades") } footer: { Text("statement.timing") }
            }
        }
        .navigationTitle("statement.title")
        .navigationBarTitleDisplayMode(.inline)
        .task { do { detail = try await appState.loadStatementDetail(id: statement.id) } catch { self.error = error.localizedDescription } }
        .sheet(item: $reportTag) { tag in
            NavigationStack {
                ThemedList {
                    Text(verbatim: tag.quote)
                    TextField("statement.reason", text: $reason, axis: .vertical)
                    if let reportError { Text(verbatim: reportError).foregroundStyle(ConsigliereTheme.warning) }
                    if reported { Text("statement.reported") }
                    Button("statement.submit") {
                        Task {
                            reportError = nil
                            do { try await appState.reportTag(statementID: statement.id, tagID: tag.id, reason: reason); reported = true }
                            catch { self.reportError = error.localizedDescription }
                        }
                    }.disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).count < 5 || reported)
                }
                .navigationTitle("statement.report")
                .toolbar { Button("common.done") { reportTag = nil } }
            }
        }
    }

    private var highlightedBody: AttributedString {
        var text = AttributedString(statement.body)
        for tag in statement.tags {
            if let range = text.range(of: tag.quote) { text[range].backgroundColor = ConsigliereTheme.accent.opacity(0.2) }
        }
        return text
    }
}
