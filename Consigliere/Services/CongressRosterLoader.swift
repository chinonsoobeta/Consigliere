import Foundation

enum CongressRosterLoader {
    static func load() throws -> [Politician] {
        let url = Bundle.main.url(
            forResource: "current-politicians",
            withExtension: "json",
            subdirectory: "Data"
        ) ?? Bundle.main.url(forResource: "current-politicians", withExtension: "json")
        guard let url else { return [] }
        return try JSONDecoder().decode([Politician].self, from: Data(contentsOf: url))
    }
}
