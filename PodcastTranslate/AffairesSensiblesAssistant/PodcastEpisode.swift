import Foundation
import LocalVectorSearch

struct PodcastEpisode: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let description: String
    let sourceURL: String
    let artworkURL: String
    let language: String
    let publishedDate: String?
    let durationSeconds: Int?
    let transcriptAvailable: Bool
    let mediaUnavailable: Bool
    let availabilityMessage: String

    init(metadata: EpisodeMetadata) {
        id = metadata.id
        title = metadata.title
        description = metadata.shortDescription
        sourceURL = metadata.sourceURL
        artworkURL = metadata.artworkURL
        language = metadata.language
        publishedDate = metadata.publishedDate
        durationSeconds = metadata.durationSeconds
        transcriptAvailable = metadata.transcriptAvailable
        mediaUnavailable = metadata.mediaAvailability == .unavailable
        availabilityMessage = metadata.availabilityMessage
    }

    var durationText: String {
        guard let durationSeconds else {
            return ""
        }
        return "\(durationSeconds / 60) min"
    }
}

enum EpisodeCatalog {
    static func load() throws -> [PodcastEpisode] {
        let databaseURL = try EpisodeDatabase.bundledDatabaseURL()
        let database = try EpisodeDatabase(url: databaseURL, accessMode: .readOnly)
        return try database.fetchCatalogEpisodes().map(PodcastEpisode.init(metadata:))
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
