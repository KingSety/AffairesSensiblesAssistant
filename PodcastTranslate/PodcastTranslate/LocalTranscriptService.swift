import Foundation
import LocalVectorSearch

struct LocalTranscriptSearchResult: Identifiable, Sendable {
    let episode: Episode
    let score: Float
    let matchKind: EpisodeSearchMatchKind
    let podcast: PodcastEpisode?

    var id: String { episode.id }

    var title: String {
        podcast?.title ?? URL(fileURLWithPath: episode.sourceFile)
            .deletingPathExtension()
            .lastPathComponent
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

    static func prepareSearchIndex() async throws {
        try await searchStore.prepare()
    }

    static func search(_ query: String, limit: Int = 8) async throws -> [LocalTranscriptSearchResult] {
        let databaseURL = try EpisodeDatabase.bundledDatabaseURL()
        let database = try EpisodeDatabase(url: databaseURL, accessMode: .readOnly)
        let indexedEpisodeCount = try database.fetchAllEpisodes().reduce(into: 0) { count, episode in
            if !episode.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
        guard indexedEpisodeCount > 1 else {
            throw LocalTranscriptServiceError.insufficientTranscripts(
                indexedEpisodeCount: indexedEpisodeCount
            )
        }

        let matches = try await searchStore.search(query, limit: limit)
        let catalog = try? EpisodeCatalog.load()
        return matches.sorted { $0.score > $1.score }.map { match in
            let storedTitle = normalized(
                URL(fileURLWithPath: match.episode.sourceFile)
                    .deletingPathExtension()
                    .lastPathComponent
            )
            return LocalTranscriptSearchResult(
                episode: match.episode,
                score: match.score,
                matchKind: match.matchKind,
                podcast: catalog?.first { catalogEpisode in
                    let catalogTitle = normalized(catalogEpisode.title)
                    return storedTitle.contains(catalogTitle) || catalogTitle.contains(storedTitle)
                },
                matchedExcerpt: match.excerpt
            )
        }
    }

    static func transcript(for episode: PodcastEpisode) async throws -> String? {
        let databaseURL = try EpisodeDatabase.bundledDatabaseURL()
        let database = try EpisodeDatabase(url: databaseURL, accessMode: .readOnly)
        let normalizedTitle = normalized(episode.title)

        return try database.fetchAllEpisodes().first { storedEpisode in
            let storedTitle = normalized(
                URL(fileURLWithPath: storedEpisode.sourceFile)
                    .deletingPathExtension()
                    .lastPathComponent
            )
            return storedTitle.contains(normalizedTitle) || normalizedTitle.contains(storedTitle)
        }?.transcript
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

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

private actor LocalTranscriptSearchStore {
    private var search: LocalEpisodeSearch?

    func prepare() async throws {
        let search = try makeSearch()
        try await search.prepareEmbeddings()
    }

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
