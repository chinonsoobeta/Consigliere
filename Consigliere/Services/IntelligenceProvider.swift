import Foundation

protocol IntelligenceProvider: Sendable {
    func snapshot() async throws -> IntelligenceSnapshot
}

enum LiveProviderError: LocalizedError {
    case missingApifyConfiguration

    var errorDescription: String? {
        switch self {
        case .missingApifyConfiguration:
            "The live intelligence service is not configured. Set APIFY_RUN_URL, or set APIFY_API_TOKEN and APIFY_ACTOR_ID, and try again."
        }
    }
}

struct UnconfiguredIntelligenceProvider: IntelligenceProvider {
    func snapshot() async throws -> IntelligenceSnapshot {
        throw LiveProviderError.missingApifyConfiguration
    }
}
