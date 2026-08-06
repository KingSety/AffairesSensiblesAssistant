import Foundation
import LocalVectorSearch

struct LocalTranscriptSearchResult: Identifiable, Sendable {
    let episode: Episode
    let score: Float
    let matchKind: EpisodeSearchMatchKind
    let podcast: PodcastEpisode?

    var id: String { episode.id }

    var title: String {
        podcast?.title ?? episode.metadata.title
    }

    var excerpt: String {
        let text = matchedExcerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 420 else { return text }
        return String(text.prefix(420)) + "…"
    }

    let matchedExcerpt: String
}

enum EpisodeGenerationSource: Sendable, Equatable {
    case transcript
    case description

    var label: String {
        switch self {
        case .transcript:
            return "Deepgram transcript"
        case .description:
            return "imported episode description"
        }
    }
}

struct EpisodeGenerationInput: Sendable {
    let text: String
    let source: EpisodeGenerationSource
}

enum LocalTranscriptServiceError: LocalizedError {
    case insufficientTranscripts(indexedEpisodeCount: Int)

    var errorDescription: String? {
        switch self {
        case .insufficientTranscripts(let indexedEpisodeCount):
            return "Only \(indexedEpisodeCount) Deepgram transcript is indexed. Add more transcripts before requesting multiple similar podcasts."
        }
    }
}

enum LocalTranscriptService {
    private static let searchStore = LocalTranscriptSearchStore()

    static func search(_ query: String, limit: Int = 8) async throws -> [LocalTranscriptSearchResult] {
        let databaseURL = try EpisodeDatabase.bundledDatabaseURL()
        let database = try EpisodeDatabase(url: databaseURL, accessMode: .readOnly)
        let indexedEpisodeCount = try database.transcriptCount()
        guard indexedEpisodeCount > 1 else {
            throw LocalTranscriptServiceError.insufficientTranscripts(
                indexedEpisodeCount: indexedEpisodeCount
            )
        }

        let matches = try await searchStore.search(query, limit: limit)
        return matches.sorted { $0.score > $1.score }.map { match in
            LocalTranscriptSearchResult(
                episode: match.episode,
                score: match.score,
                matchKind: match.matchKind,
                podcast: PodcastEpisode(metadata: match.episode.metadata),
                matchedExcerpt: match.excerpt
            )
        }
    }

    static func transcript(for episode: PodcastEpisode) async throws -> String? {
        let databaseURL = try EpisodeDatabase.bundledDatabaseURL()
        let database = try EpisodeDatabase(url: databaseURL, accessMode: .readOnly)
        return try database.fetchTranscript(episodeID: episode.id)
    }

    static func generationInput(for episode: PodcastEpisode) async throws -> EpisodeGenerationInput {
        if let storedTranscript = try await transcript(for: episode) {
            let transcript = storedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty {
                return EpisodeGenerationInput(text: transcript, source: .transcript)
            }
        }

        let description = episode.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            throw OnDeviceLanguageServiceError.emptyTranscript
        }
        return EpisodeGenerationInput(text: description, source: .description)
    }
}

private actor LocalTranscriptSearchStore {
    private var search: LocalEpisodeSearch?

    func search(_ query: String, limit: Int) async throws -> [EpisodeSearchResult] {
        let search = try makeSearch()
        return try await search.search(query, limit: limit)
    }

    private func makeSearch() throws -> LocalEpisodeSearch {
        if let search {
            return search
        }
        let databaseURL = try EpisodeDatabase.bundledDatabaseURL()
        let createdSearch = try LocalEpisodeSearch(
            databaseURL: databaseURL,
            databaseAccessMode: .readOnly
        )
        search = createdSearch
        return createdSearch
    }
}
