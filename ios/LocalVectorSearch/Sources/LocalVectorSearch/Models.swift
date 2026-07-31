import Foundation

public struct Episode: Identifiable, Sendable, Equatable {
    public let id: String
    public let sourceFile: String
    public let transcriptFile: String
    public let summaryFile: String
    public let transcript: String
    public let summary: String
    public let embeddingDimension: Int?
    public let embeddingRevision: Int?
    public let embeddingLanguage: String?

    let embeddingData: Data?
}

public struct EpisodeSearchResult: Identifiable, Sendable, Equatable {
    public var id: String { episode.id }
    public let episode: Episode
    public let score: Float
    public let excerpt: String
    public let matchKind: EpisodeSearchMatchKind
}

public enum EpisodeSearchMatchKind: Sendable, Equatable {
    case semantic
    case transcriptKeyword
}

struct EpisodeEmbeddingRecord {
    let id: String
    let transcript: String
    let embeddingDimension: Int?
    let embeddingRevision: Int?
    let embeddingLanguage: String?
    let embeddingData: Data?
}

struct TranscriptChunkEmbeddingRecord {
    let episodeID: String
    let chunkIndex: Int
    let text: String
    let embeddingDimension: Int?
    let embeddingRevision: Int?
    let embeddingLanguage: String?
    let embeddingData: Data?

    var key: TranscriptChunkKey {
        TranscriptChunkKey(episodeID: episodeID, chunkIndex: chunkIndex)
    }
}

struct TranscriptChunkKey: Hashable, Sendable {
    let episodeID: String
    let chunkIndex: Int
}

struct ApproximateIndexMetadata: Sendable {
    let embeddingRevision: Int
    let embeddingLanguage: String
    let embeddingDimension: Int
    let entryPoint: TranscriptChunkKey
    let maximumLevel: Int
    let nodeCount: Int
}

struct ApproximateIndexEdge: Sendable {
    let source: TranscriptChunkKey
    let target: TranscriptChunkKey
    let level: Int
    let rank: Int
}

struct TranscriptKeywordMatch {
    let episodeID: String
    let excerpt: String
}

public enum LocalVectorSearchError: LocalizedError {
    case bundledDatabaseMissing(String)
    case database(String)
    case embeddingUnavailable(String)
    case prebuiltIndexRequired
    case emptyText
    case invalidEmbedding

    public var errorDescription: String? {
        switch self {
        case .bundledDatabaseMissing(let name):
            return "The bundled database resource \(name) was not found."
        case .database(let message):
            return "SQLite error: \(message)"
        case .embeddingUnavailable(let language):
            return "Apple's required French sentence embedding (\(language)) is unavailable; local semantic search cannot run on this device."
        case .prebuiltIndexRequired:
            return "The bundled offline library is missing its ready-made search index. Rebuild the data pack before installing the app."
        case .emptyText:
            return "Cannot embed empty text."
        case .invalidEmbedding:
            return "The stored embedding is malformed or has the wrong dimension."
        }
    }
}
