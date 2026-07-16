import Foundation

protocol IntelligenceProvider: Sendable {
    func snapshot() async throws -> IntelligenceSnapshot
}

enum LiveProviderError: LocalizedError {
    case missingBaseURL

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            "The live intelligence service is not configured. Set CONSILIERE_API_BASE_URL and try again."
        }
    }
}

struct UnconfiguredIntelligenceProvider: IntelligenceProvider {
    func snapshot() async throws -> IntelligenceSnapshot {
        throw LiveProviderError.missingBaseURL
    }
}
