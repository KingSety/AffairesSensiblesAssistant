import Accelerate
import Foundation

struct ApproximateVectorSearchMatch: Sendable {
    let key: TranscriptChunkKey
    let score: Float
}

/// A persisted, HNSW-style neighbor graph for transcript chunk embeddings.
/// The graph is created off-device with the data pack and only its nearby
/// vectors are read while answering a query.
struct ApproximateVectorIndex: Sendable {
    private static let maximumConnections = 12
    private static let constructionCandidateCount = 64

    let metadata: ApproximateIndexMetadata

    init(metadata: ApproximateIndexMetadata) {
        self.metadata = metadata
    }

    static func build(
        records: [TranscriptChunkEmbeddingRecord],
        embeddingRevision: Int,
        embeddingLanguage: String,
        embeddingDimension: Int
    ) throws -> (metadata: ApproximateIndexMetadata, edges: [ApproximateIndexEdge])? {
        let sortedRecords = records.sorted { left, right in
            if left.episodeID == right.episodeID {
                return left.chunkIndex < right.chunkIndex
            }
            return left.episodeID < right.episodeID
        }
        guard let firstRecord = sortedRecords.first else { return nil }

        var vectors: [TranscriptChunkKey: [Float]] = [:]
        vectors.reserveCapacity(sortedRecords.count)
        for record in sortedRecords {
            guard let data = record.embeddingData else { continue }
            vectors[record.key] = try data.floatEmbedding(expectedDimension: embeddingDimension)
        }
        guard vectors.count == sortedRecords.count else {
            throw LocalVectorSearchError.invalidEmbedding
        }

        var graph: [TranscriptChunkKey: [Int: [TranscriptChunkKey]]] = [:]
        var entryPoint = firstRecord.key
        var maximumLevel = 0

        for (offset, record) in sortedRecords.enumerated() {
            let key = record.key
            let vector = vectors[key] ?? []
            let nodeLevel = level(for: key)
            graph[key] = [:]

            guard offset > 0 else {
                entryPoint = key
                maximumLevel = nodeLevel
                continue
            }

            var currentEntry = entryPoint
            if maximumLevel > nodeLevel {
                for currentLevel in stride(from: maximumLevel, through: nodeLevel + 1, by: -1) {
                    if let nearest = searchLayer(
                        queryVector: vector,
                        entryPoints: [currentEntry],
                        level: currentLevel,
                        candidateCount: 1,
                        graph: graph,
                        vectors: vectors
                    ).first {
                        currentEntry = nearest.key
                    }
                }
            }

            let highestConnectionLevel = min(nodeLevel, maximumLevel)
            if highestConnectionLevel >= 0 {
                for currentLevel in stride(from: highestConnectionLevel, through: 0, by: -1) {
                    let candidates = searchLayer(
                        queryVector: vector,
                        entryPoints: [currentEntry],
                        level: currentLevel,
                        candidateCount: Self.constructionCandidateCount,
                        graph: graph,
                        vectors: vectors
                    )
                    let selected = candidates
                        .filter { $0.key != key }
                        .prefix(Self.maximumConnections)
                        .map(\.key)

                    for neighbor in selected {
                        connect(
                            from: key,
                            to: neighbor,
                            level: currentLevel,
                            graph: &graph,
                            vectors: vectors
                        )
                        connect(
                            from: neighbor,
                            to: key,
                            level: currentLevel,
                            graph: &graph,
                            vectors: vectors
                        )
                    }
                    if let nearest = candidates.first {
                        currentEntry = nearest.key
                    }
                }
            }

            if nodeLevel > maximumLevel {
                entryPoint = key
                maximumLevel = nodeLevel
            }
        }

        let metadata = ApproximateIndexMetadata(
            embeddingRevision: embeddingRevision,
            embeddingLanguage: embeddingLanguage,
            embeddingDimension: embeddingDimension,
            entryPoint: entryPoint,
            maximumLevel: maximumLevel,
            nodeCount: sortedRecords.count
        )
        let edges = graph.flatMap { source, levels in
            levels.flatMap { level, targets in
                targets.enumerated().map { rank, target in
                    ApproximateIndexEdge(
                        source: source,
                        target: target,
                        level: level,
                        rank: rank
                    )
                }
            }
        }
        return (metadata, edges)
    }

    func search(
        queryVector: [Float],
        candidateCount: Int,
        recordForKey: (TranscriptChunkKey) throws -> TranscriptChunkEmbeddingRecord?,
        neighborsForKey: (TranscriptChunkKey, Int) throws -> [TranscriptChunkKey]
    ) throws -> [ApproximateVectorSearchMatch] {
        guard candidateCount > 0 else { return [] }
        var scoreCache: [TranscriptChunkKey: Float] = [:]

        func score(for key: TranscriptChunkKey) throws -> Float? {
            if let cachedScore = scoreCache[key] {
                return cachedScore
            }
            guard let record = try recordForKey(key),
                  record.embeddingRevision == metadata.embeddingRevision,
                  record.embeddingLanguage == metadata.embeddingLanguage,
                  record.embeddingDimension == metadata.embeddingDimension,
                  let embeddingData = record.embeddingData
            else {
                return nil
            }
            let candidateVector = try embeddingData.floatEmbedding(
                expectedDimension: metadata.embeddingDimension
            )
            let candidateScore = cosineSimilarity(queryVector, candidateVector)
            guard candidateScore.isFinite else { return nil }
            scoreCache[key] = candidateScore
            return candidateScore
        }

        func searchLayer(
            entryPoints: [TranscriptChunkKey],
            level: Int,
            count: Int
        ) throws -> [ApproximateVectorSearchMatch] {
            var visited = Set<TranscriptChunkKey>()
            var frontier: [ApproximateVectorSearchMatch] = []
            var results: [ApproximateVectorSearchMatch] = []

            for entryPoint in entryPoints where visited.insert(entryPoint).inserted {
                if let entryScore = try score(for: entryPoint) {
                    let match = ApproximateVectorSearchMatch(key: entryPoint, score: entryScore)
                    frontier.append(match)
                    results.append(match)
                }
            }

            while !frontier.isEmpty {
                frontier.sort { $0.score > $1.score }
                let current = frontier.removeFirst()
                let lowestResultScore = results.map(\.score).min() ?? -.infinity
                if results.count >= count, current.score < lowestResultScore {
                    break
                }

                let neighbors = try neighborsForKey(current.key, level)
                for neighbor in neighbors where visited.insert(neighbor).inserted {
                    guard let neighborScore = try score(for: neighbor) else { continue }
                    let match = ApproximateVectorSearchMatch(key: neighbor, score: neighborScore)
                    let currentLowestScore = results.map(\.score).min() ?? -.infinity
                    if results.count < count || neighborScore > currentLowestScore {
                        frontier.append(match)
                        results.append(match)
                        results.sort { $0.score > $1.score }
                        if results.count > count {
                            results.removeLast()
                        }
                    }
                }
            }
            return results.sorted { $0.score > $1.score }
        }

        var entryPoint = metadata.entryPoint
        if metadata.maximumLevel > 0 {
            for currentLevel in stride(from: metadata.maximumLevel, through: 1, by: -1) {
                if let nearest = try searchLayer(
                    entryPoints: [entryPoint],
                    level: currentLevel,
                    count: 1
                ).first {
                    entryPoint = nearest.key
                }
            }
        }
        return try searchLayer(
            entryPoints: [entryPoint],
            level: 0,
            count: candidateCount
        )
    }

    private static func connect(
        from source: TranscriptChunkKey,
        to target: TranscriptChunkKey,
        level: Int,
        graph: inout [TranscriptChunkKey: [Int: [TranscriptChunkKey]]],
        vectors: [TranscriptChunkKey: [Float]]
    ) {
        var sourceLevels = graph[source, default: [:]]
        var targets = sourceLevels[level, default: []]
        if !targets.contains(target) {
            targets.append(target)
        }
        guard let sourceVector = vectors[source] else { return }
        sourceLevels[level] = targets
            .compactMap { candidate -> (key: TranscriptChunkKey, score: Float)? in
                guard let candidateVector = vectors[candidate] else { return nil }
                let score = cosineSimilarity(sourceVector, candidateVector)
                return score.isFinite ? (candidate, score) : nil
            }
            .sorted { $0.score > $1.score }
            .prefix(maximumConnections)
            .map(\.key)
        graph[source] = sourceLevels
    }

    private static func searchLayer(
        queryVector: [Float],
        entryPoints: [TranscriptChunkKey],
        level: Int,
        candidateCount: Int,
        graph: [TranscriptChunkKey: [Int: [TranscriptChunkKey]]],
        vectors: [TranscriptChunkKey: [Float]]
    ) -> [ApproximateVectorSearchMatch] {
        var visited = Set<TranscriptChunkKey>()
        var frontier: [ApproximateVectorSearchMatch] = []
        var results: [ApproximateVectorSearchMatch] = []

        for entryPoint in entryPoints where visited.insert(entryPoint).inserted {
            guard let vector = vectors[entryPoint] else { continue }
            let score = cosineSimilarity(queryVector, vector)
            guard score.isFinite else { continue }
            let match = ApproximateVectorSearchMatch(key: entryPoint, score: score)
            frontier.append(match)
            results.append(match)
        }

        while !frontier.isEmpty {
            frontier.sort { $0.score > $1.score }
            let current = frontier.removeFirst()
            let lowestResultScore = results.map(\.score).min() ?? -.infinity
            if results.count >= candidateCount, current.score < lowestResultScore {
                break
            }

            for neighbor in graph[current.key]?[level] ?? [] where visited.insert(neighbor).inserted {
                guard let vector = vectors[neighbor] else { continue }
                let score = cosineSimilarity(queryVector, vector)
                guard score.isFinite else { continue }
                let match = ApproximateVectorSearchMatch(key: neighbor, score: score)
                let currentLowestScore = results.map(\.score).min() ?? -.infinity
                if results.count < candidateCount || score > currentLowestScore {
                    frontier.append(match)
                    results.append(match)
                    results.sort { $0.score > $1.score }
                    if results.count > candidateCount {
                        results.removeLast()
                    }
                }
            }
        }
        return results.sorted { $0.score > $1.score }
    }

    private static func level(for key: TranscriptChunkKey) -> Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in "\(key.episodeID)#\(key.chunkIndex)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        var level = 0
        while hash & 0b11 == 0, level < 8 {
            level += 1
            hash >>= 2
        }
        return level
    }
}

private func cosineSimilarity(_ left: [Float], _ right: [Float]) -> Float {
    guard left.count == right.count, !left.isEmpty else { return -.infinity }
    var dotProduct: Float = 0
    vDSP_dotpr(left, 1, right, 1, &dotProduct, vDSP_Length(left.count))
    var leftMagnitudeSquared: Float = 0
    vDSP_svesq(left, 1, &leftMagnitudeSquared, vDSP_Length(left.count))
    var rightMagnitudeSquared: Float = 0
    vDSP_svesq(right, 1, &rightMagnitudeSquared, vDSP_Length(right.count))
    let magnitudeProduct = sqrtf(leftMagnitudeSquared * rightMagnitudeSquared)
    guard magnitudeProduct > 0 else { return -.infinity }
    return dotProduct / magnitudeProduct
}
