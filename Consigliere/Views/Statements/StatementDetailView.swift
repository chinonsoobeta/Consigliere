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

    var body: some View {
        List {
            Section {
                Text(verbatim: statement.title).font(.title2.bold())
                Text(verbatim: statement.kind).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: statement.publishedAt).font(.caption)
                if let signed = statement.signedAt { Text("statement.signed \(signed)") }
                if let number = statement.documentNumber { Text(verbatim: number).font(.caption.monospaced()) }
                Text(highlightedBody)
                Link("event.openSource", destination: statement.sourceURL)
                if let confirmation = statement.confirmationURL { Link("statement.confirmation", destination: confirmation) }
            }
            Section("statement.tags") {
                ForEach(statement.tags) { tag in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: "\(tag.value) · \(tag.kind)").font(.headline)
                        Text(verbatim: "“\(tag.quote)”").font(.subheadline)
                        Text(verbatim: "\(tag.model) · \(tag.promptVersion)").font(.caption2).foregroundStyle(.secondary)
                        Button("statement.report") { reportTag = tag; reason = ""; reported = false; reportError = nil }
                    }
                }
            }
            if let error { Text(verbatim: error).foregroundStyle(.orange) }
            if let detail {
                Section("statement.holdings") {
                    ForEach(detail.holdings) { holding in
                        NavigationLink(value: StockRoute(symbol: holding.ticker)) { Text("statement.holdingCount \(holding.ticker) \(holding.membersHolding)") }
                    }
                    Text("portfolio.estimated").font(.caption)
                }
                Section {
                    ForEach(detail.trades) { trade in
                        NavigationLink(value: trade) { TradeRow(trade: trade) }
                        Text(DisclosureDates.dayFormatter.string(from: trade.transactionDate) < String(statement.publishedAt.prefix(10)) ? "statement.before" : "statement.after").font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("statement.trades") } footer: { Text("statement.timing") }
            }
        }
        .navigationTitle("statement.title")
        .task { do { detail = try await appState.loadStatementDetail(id: statement.id) } catch { self.error = error.localizedDescription } }
        .sheet(item: $reportTag) { tag in
            NavigationStack {
                Form {
                    Text(verbatim: tag.quote)
                    TextField("statement.reason", text: $reason, axis: .vertical)
                    if let reportError { Text(verbatim: reportError).foregroundStyle(.orange) }
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
