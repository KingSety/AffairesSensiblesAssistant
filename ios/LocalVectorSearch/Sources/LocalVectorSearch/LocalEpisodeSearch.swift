import Foundation

public actor LocalEpisodeSearch {
    private static let maximumChunkCharacters = 900

    private let database: EpisodeDatabase
    private let embedder: AppleSentenceEmbedder
    private let databaseAccessMode: EpisodeDatabaseAccessMode
    private let maximumChunksPerEpisode: Int?
    private var isPrepared = false
    private var approximateIndex: ApproximateVectorIndex?

    public init(
        databaseURL: URL,
        databaseAccessMode: EpisodeDatabaseAccessMode = .readWrite,
        maximumChunksPerEpisode: Int? = nil
    ) throws {
        self.database = try EpisodeDatabase(url: databaseURL, accessMode: databaseAccessMode)
        self.embedder = try AppleSentenceEmbedder()
        self.databaseAccessMode = databaseAccessMode
        self.maximumChunksPerEpisode = maximumChunksPerEpisode
    }

    public func prepareEmbeddings() throws {
        guard !isPrepared else { return }

        if let storedIndex = try database.fetchApproximateIndexMetadata(),
           try isCompatible(storedIndex) {
            if databaseAccessMode == .readWrite,
               try database.transcriptTextIndexCount() != storedIndex.nodeCount {
                try database.beginTransaction()
                do {
                    try database.rebuildTranscriptTextIndex()
                    try database.commitTransaction()
                } catch {
                    try? database.rollbackTransaction()
                    throw error
                }
            }
            approximateIndex = ApproximateVectorIndex(metadata: storedIndex)
            isPrepared = true
            return
        }

        guard databaseAccessMode == .readWrite else {
            throw LocalVectorSearchError.prebuiltIndexRequired
        }

        let episodes = try database.fetchEmbeddingRecords()
        let chunkRecords = try database.fetchTranscriptChunkEmbeddingRecords()
        let chunkedEpisodeIDs = Set(chunkRecords.map(\.episodeID))
        let requiresEmbeddingBuild = episodes.contains { episode in
            !chunkedEpisodeIDs.contains(episode.id)
                || episode.embeddingRevision != embedder.transcriptEmbeddingRevision
                || episode.embeddingLanguage != embedder.language.rawValue
        }

        if requiresEmbeddingBuild {
            try database.clearApproximateIndex()
        }
        try database.beginTransaction()
        do {
            for episode in episodes {
                let isCompatible = chunkedEpisodeIDs.contains(episode.id)
                    && episode.embeddingRevision == embedder.transcriptEmbeddingRevision
                    && episode.embeddingLanguage == embedder.language.rawValue

                if !isCompatible {
                    let chunks = transcriptChunks(from: episode.transcript)
                    let selectedChunks: [String]
                    if let maximumChunksPerEpisode {
                        selectedChunks = Array(chunks.prefix(maximumChunksPerEpisode))
                    } else {
                        selectedChunks = chunks
                    }
                    let vectors = try selectedChunks.map { chunk in
                        (text: chunk, vector: try embedder.vector(for: chunk))
                    }
                    try database.replaceTranscriptChunkEmbeddings(
                        episodeID: episode.id,
                        chunks: vectors,
                        revision: embedder.transcriptEmbeddingRevision,
                        language: embedder.language
                    )
                    try database.markTranscriptChunksPrepared(
                        episodeID: episode.id,
                        revision: embedder.transcriptEmbeddingRevision,
                        language: embedder.language
                    )
                }
            }
            try database.commitTransaction()
        } catch {
            try? database.rollbackTransaction()
            throw error
        }

        let rebuiltChunkRecords = try database.fetchTranscriptChunkEmbeddingRecords()
        guard let builtIndex = try ApproximateVectorIndex.build(
            records: rebuiltChunkRecords,
            embeddingRevision: embedder.transcriptEmbeddingRevision,
            embeddingLanguage: embedder.language.rawValue,
            embeddingDimension: embedder.dimension
        ) else {
            throw LocalVectorSearchError.emptyText
        }
        try database.beginTransaction()
        do {
            try database.rebuildTranscriptTextIndex()
            try database.replaceApproximateIndex(
                metadata: builtIndex.metadata,
                edges: builtIndex.edges
            )
            try database.commitTransaction()
        } catch {
            try? database.rollbackTransaction()
            throw error
        }
        approximateIndex = ApproximateVectorIndex(metadata: builtIndex.metadata)
        isPrepared = true
    }

    public func search(_ query: String, limit: Int = 10) throws -> [EpisodeSearchResult] {
        guard limit > 0 else { return [] }
        try prepareEmbeddings()

        let queryVector = try embedder.vector(for: query)
        guard let approximateIndex else {
            throw LocalVectorSearchError.invalidEmbedding
        }
        let keywordMatches = try database.searchTranscriptText(query, limit: limit)
        if !keywordMatches.isEmpty {
            return try keywordMatches.enumerated().compactMap { offset, match in
                guard let episode = try database.fetchEpisode(id: match.episodeID) else {
                    return nil
                }
                return EpisodeSearchResult(
                    episode: episode,
                    score: 1 - (Float(offset) / Float(max(keywordMatches.count, 1))),
                    excerpt: match.excerpt,
                    matchKind: .transcriptKeyword
                )
            }
        }
        var bestMatches: [String: (score: Float, excerpt: String)] = [:]
        let candidateCount = max(limit * 32, 128)
        let candidates = try approximateIndex.search(
            queryVector: queryVector,
            candidateCount: candidateCount,
            recordForKey: { key in
                try database.fetchTranscriptChunkEmbeddingRecord(key: key)
            },
            neighborsForKey: { key, level in
                try database.fetchApproximateNeighbors(for: key, level: level)
            }
        )
        for candidate in candidates {
            guard let record = try database.fetchTranscriptChunkEmbeddingRecord(key: candidate.key) else {
                continue
            }
            if bestMatches[record.episodeID]?.score ?? -.infinity < candidate.score {
                bestMatches[record.episodeID] = (candidate.score, record.text)
            }
        }

        let rankedMatches = bestMatches
            .map { (id: $0.key, score: $0.value.score, excerpt: $0.value.excerpt) }
            .sorted { left, right in
                if left.score == right.score {
                    return left.id < right.id
                }
                return left.score > right.score
            }
            .prefix(limit)

        var results: [EpisodeSearchResult] = []
        results.reserveCapacity(rankedMatches.count)
        for ranked in rankedMatches {
            if let episode = try database.fetchEpisode(id: ranked.id) {
                results.append(
                    EpisodeSearchResult(
                        episode: episode,
                        score: ranked.score,
                        excerpt: ranked.excerpt,
                        matchKind: .semantic
                    )
                )
            }
        }
        return results
    }

    private func isCompatible(_ metadata: ApproximateIndexMetadata) throws -> Bool {
        guard metadata.embeddingRevision == embedder.transcriptEmbeddingRevision,
              metadata.embeddingLanguage == embedder.language.rawValue,
              metadata.embeddingDimension == embedder.dimension
        else {
            return false
        }
        return try database.compatibleTranscriptChunkCount(
            revision: metadata.embeddingRevision,
            language: metadata.embeddingLanguage,
            dimension: metadata.embeddingDimension
        ) == metadata.nodeCount
    }

    private func transcriptChunks(from transcript: String) -> [String] {
        let sentences = transcript.sentences
        let units = sentences.isEmpty ? transcript.paragraphs : sentences
        var chunks: [String] = []
        var currentChunk = ""

        for unit in units {
            let parts = unit.splitIntoChunks(ofAtMost: Self.maximumChunkCharacters)
            for part in parts {
                let candidate = currentChunk.isEmpty ? part : "\(currentChunk) \(part)"
                if candidate.count > Self.maximumChunkCharacters, !currentChunk.isEmpty {
                    chunks.append(currentChunk)
                    currentChunk = part
                } else {
                    currentChunk = candidate
                }
            }
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }
        return chunks.isEmpty ? [transcript] : chunks
    }
}

private extension String {
    var sentences: [String] {
        var values: [String] = []
        enumerateSubstrings(in: startIndex..<endIndex, options: .bySentences) { substring, _, _, _ in
            guard let substring else { return }
            let sentence = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                values.append(sentence)
            }
        }
        return values
    }

    var paragraphs: [String] {
        components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func splitIntoChunks(ofAtMost maximumCharacterCount: Int) -> [String] {
        guard count > maximumCharacterCount else { return [self] }
        var chunks: [String] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: maximumCharacterCount, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[start..<end]))
            start = end
        }
        return chunks
    }
}
