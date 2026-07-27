import Foundation

struct PodcastEpisode: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let description: String
    let sourceURL: String
    let artworkURL: String
    let language: String
    let publishedDate: String?
    let durationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case sourceURL = "source_url"
        case artworkURL = "artwork_url"
        case language
        case publishedDate = "published_date"
        case durationSeconds = "duration_seconds"
    }

    var durationText: String {
        guard let durationSeconds else {
            return ""
        }
        return "\(durationSeconds / 60) min"
    }
}

enum EpisodeCatalog {
    enum CatalogError: LocalizedError {
        case missing

        var errorDescription: String? {
            "The imported episode catalog is not in the app bundle."
        }
    }

    static func load() throws -> [PodcastEpisode] {
        guard let url = Bundle.main.url(
            forResource: "imported_episodes",
            withExtension: "json"
        ) else {
            throw CatalogError.missing
        }

        return try JSONDecoder().decode([PodcastEpisode].self, from: Data(contentsOf: url))
    }

    static func matches(for query: String, limit: Int = 3) throws -> [PodcastEpisode] {
        let episodes = try load()
        let keywords = query
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }

        guard !keywords.isEmpty else {
            return Array(episodes.prefix(limit))
        }

        return episodes
            .map { episode in
                let title = episode.title.folding(
                    options: [.diacriticInsensitive, .caseInsensitive],
                    locale: .current
                )
                let description = episode.description.folding(
                    options: [.diacriticInsensitive, .caseInsensitive],
                    locale: .current
                )
                let score = keywords.reduce(into: 0) { total, keyword in
                    if title.contains(keyword) {
                        total += 3
                    }
                    if description.contains(keyword) {
                        total += 1
                    }
                    if episode.language.contains(keyword) {
                        total += 1
                    }
                }
                return (episode, score)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}
