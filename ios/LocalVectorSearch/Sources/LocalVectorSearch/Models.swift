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
}

struct EpisodeEmbeddingRecord {
    let id: String
    let summary: String
    let embeddingDimension: Int?
    let embeddingRevision: Int?
    let embeddingLanguage: String?
    let embeddingData: Data?
}

public enum LocalVectorSearchError: LocalizedError {
    case bundledDatabaseMissing(String)
    case database(String)
    case embeddingUnavailable(String)
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
        case .emptyText:
            return "Cannot embed empty text."
        case .invalidEmbedding:
            return "The stored embedding is malformed or has the wrong dimension."
        }
    }
}
