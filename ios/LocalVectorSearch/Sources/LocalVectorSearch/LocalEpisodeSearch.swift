import Accelerate
import Foundation

public actor LocalEpisodeSearch {
    private let database: EpisodeDatabase
    private let embedder: AppleSentenceEmbedder
    private var isPrepared = false

    public init(databaseURL: URL) throws {
        self.database = try EpisodeDatabase(url: databaseURL)
        self.embedder = try AppleSentenceEmbedder()
    }

    public func prepareEmbeddings() throws {
        guard !isPrepared else { return }

        let episodes = try database.fetchEmbeddingRecords()
        try database.beginTransaction()
        do {
            for episode in episodes {
                let isCompatible = episode.embeddingData != nil
                    && episode.embeddingDimension == embedder.dimension
                    && episode.embeddingRevision == embedder.revision
                    && episode.embeddingLanguage == embedder.language.rawValue

                if !isCompatible {
                    let vector = try embedder.vector(for: episode.summary)
                    try database.updateEmbedding(
                        episodeID: episode.id,
                        vector: vector,
                        revision: embedder.revision,
                        language: embedder.language
                    )
                }
            }
            try database.commitTransaction()
        } catch {
            try? database.rollbackTransaction()
            throw error
        }
        isPrepared = true
    }

    public func search(_ query: String, limit: Int = 10) throws -> [EpisodeSearchResult] {
        guard limit > 0 else { return [] }
        try prepareEmbeddings()

        let queryVector = try embedder.vector(for: query)
        let rankedIDs = try database.fetchEmbeddingRecords()
            .compactMap { record -> (id: String, score: Float)? in
                guard let data = record.embeddingData,
                      record.embeddingDimension == queryVector.count
                else { return nil }

                let candidate = try data.floatEmbedding(
                    expectedDimension: queryVector.count
                )
                var score: Float = 0
                vDSP_dotpr(
                    queryVector,
                    1,
                    candidate,
                    1,
                    &score,
                    vDSP_Length(queryVector.count)
                )
                return (record.id, score)
            }
            .sorted { left, right in
                if left.score == right.score {
                    return left.id < right.id
                }
                return left.score > right.score
            }
            .prefix(limit)

        var results: [EpisodeSearchResult] = []
        results.reserveCapacity(rankedIDs.count)
        for ranked in rankedIDs {
            if let episode = try database.fetchEpisode(id: ranked.id) {
                results.append(EpisodeSearchResult(episode: episode, score: ranked.score))
            }
        }
        return results
    }
}
