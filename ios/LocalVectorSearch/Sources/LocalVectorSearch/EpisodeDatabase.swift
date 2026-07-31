import Foundation
import NaturalLanguage
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum EpisodeDatabaseAccessMode: Sendable {
    case readOnly
    case readWrite
}

public final class EpisodeDatabase {
    private var handle: OpaquePointer?
    private let accessMode: EpisodeDatabaseAccessMode

    public init(
        url: URL,
        accessMode: EpisodeDatabaseAccessMode = .readWrite
    ) throws {
        self.accessMode = accessMode
        var database: OpaquePointer?
        let flags: Int32
        switch accessMode {
        case .readOnly:
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        case .readWrite:
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        }
        let result = sqlite3_open_v2(
            url.path,
            &database,
            flags,
            nil
        )
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Unable to open \(url.path)"
            if let database {
                sqlite3_close(database)
            }
            throw LocalVectorSearchError.database(message)
        }
        handle = database
        sqlite3_busy_timeout(database, 10_000)
        if accessMode == .readWrite {
            try createSchema()
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    public static func installBundledDatabase(
        named name: String = "episodes",
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> URL {
        let resource = "\(name).sqlite"
        guard let sourceURL = bundle.url(forResource: name, withExtension: "sqlite") else {
            throw LocalVectorSearchError.bundledDatabaseMissing(resource)
        }

        let supportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDirectory = supportDirectory.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "LocalVectorSearch",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: appDirectory,
            withIntermediateDirectories: true
        )

        let destinationURL = appDirectory.appendingPathComponent(resource)
        let signatureURL = appDirectory.appendingPathComponent("\(resource).signature")
        let sourceSignature = try databaseSignature(for: sourceURL, fileManager: fileManager)
        let installedSignature = try? String(contentsOf: signatureURL, encoding: .utf8)
        if !fileManager.fileExists(atPath: destinationURL.path) || installedSignature != sourceSignature {
            let temporaryURL = appDirectory.appendingPathComponent("\(resource).replacement")
            try? fileManager.removeItem(at: temporaryURL)
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            try? fileManager.removeItem(at: destinationURL)
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            try sourceSignature.write(to: signatureURL, atomically: true, encoding: .utf8)
        }
        return destinationURL
    }

    public static func bundledDatabaseURL(
        named name: String = "episodes",
        bundle: Bundle = .main
    ) throws -> URL {
        let resource = "\(name).sqlite"
        guard let sourceURL = bundle.url(forResource: name, withExtension: "sqlite") else {
            throw LocalVectorSearchError.bundledDatabaseMissing(resource)
        }
        return sourceURL
    }

    public func fetchAllEpisodes() throws -> [Episode] {
        let sql = """
            SELECT id, source_file, transcript_file, summary_file,
                   transcript, summary, embedding, embedding_dimension,
                   embedding_revision, embedding_language
            FROM episodes
            ORDER BY source_file
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var episodes: [Episode] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let embeddingData: Data?
            let byteCount = Int(sqlite3_column_bytes(statement, 6))
            if byteCount > 0, let bytes = sqlite3_column_blob(statement, 6) {
                embeddingData = Data(bytes: bytes, count: byteCount)
            } else {
                embeddingData = nil
            }

            episodes.append(
                Episode(
                    id: text(statement, 0),
                    sourceFile: text(statement, 1),
                    transcriptFile: text(statement, 2),
                    summaryFile: text(statement, 3),
                    transcript: text(statement, 4),
                    summary: text(statement, 5),
                    embeddingDimension: optionalInt(statement, 7),
                    embeddingRevision: optionalInt(statement, 8),
                    embeddingLanguage: optionalText(statement, 9),
                    embeddingData: embeddingData
                )
            )
        }
        try checkLastStep(statement)
        return episodes
    }

    public func transcriptChunkCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM episode_transcript_chunks")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw databaseError()
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    func compatibleTranscriptChunkCount(
        revision: Int,
        language: String,
        dimension: Int
    ) throws -> Int {
        let statement = try prepare(
            """
            SELECT COUNT(*)
            FROM episode_transcript_chunks
            WHERE embedding_revision = ?
              AND embedding_language = ?
              AND embedding_dimension = ?
              AND embedding IS NOT NULL
            """
        )
        defer { sqlite3_finalize(statement) }
        try checkBinding(sqlite3_bind_int(statement, 1, Int32(revision)))
        try bindText(language, to: 2, in: statement)
        try checkBinding(sqlite3_bind_int(statement, 3, Int32(dimension)))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw databaseError()
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    func transcriptTextIndexCount() throws -> Int {
        guard try tableExists(named: "episode_transcript_search") else { return 0 }
        let statement = try prepare("SELECT COUNT(*) FROM episode_transcript_search")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw databaseError()
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    func rebuildTranscriptTextIndex() throws {
        try execute("DELETE FROM episode_transcript_search")
        try execute(
            """
            INSERT INTO episode_transcript_search (episode_id, source_file, transcript)
            SELECT id, source_file, transcript
            FROM episodes
            WHERE trim(transcript) != ''
            """
        )
    }

    func searchTranscriptText(
        _ query: String,
        limit: Int
    ) throws -> [TranscriptKeywordMatch] {
        guard limit > 0,
              try tableExists(named: "episode_transcript_search")
        else {
            return []
        }
        let ignoredTerms: Set<String> = [
            "about", "avec", "des", "episode", "episodes", "find", "podcast",
            "podcasts", "pour", "similar", "sur", "the", "top",
        ]
        let terms = query
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !ignoredTerms.contains($0) }
        guard !terms.isEmpty else { return [] }

        let matchExpression = terms
            .map { "\"\($0)\"*" }
            .joined(separator: " OR ")
        let statement = try prepare(
            """
            SELECT episode_id,
                   snippet(episode_transcript_search, 2, '', '', '…', 36)
            FROM episode_transcript_search
            WHERE episode_transcript_search MATCH ?
            ORDER BY bm25(episode_transcript_search)
            LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bindText(matchExpression, to: 1, in: statement)
        try checkBinding(sqlite3_bind_int(statement, 2, Int32(limit)))

        var matches: [TranscriptKeywordMatch] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            matches.append(
                TranscriptKeywordMatch(
                    episodeID: text(statement, 0),
                    excerpt: text(statement, 1)
                )
            )
        }
        try checkLastStep(statement)
        return matches
    }

    func fetchEmbeddingRecords() throws -> [EpisodeEmbeddingRecord] {
        let statement = try prepare(
            """
            SELECT id, transcript, embedding, embedding_dimension,
                   embedding_revision, embedding_language
            FROM episodes
            ORDER BY source_file
            """
        )
        defer { sqlite3_finalize(statement) }

        var records: [EpisodeEmbeddingRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(
                EpisodeEmbeddingRecord(
                    id: text(statement, 0),
                    transcript: text(statement, 1),
                    embeddingDimension: optionalInt(statement, 3),
                    embeddingRevision: optionalInt(statement, 4),
                    embeddingLanguage: optionalText(statement, 5),
                    embeddingData: blob(statement, 2)
                )
            )
        }
        try checkLastStep(statement)
        return records
    }

    func fetchTranscriptChunkEmbeddingRecords() throws -> [TranscriptChunkEmbeddingRecord] {
        let statement = try prepare(
            """
            SELECT episode_id, chunk_index, content, embedding, embedding_dimension,
                   embedding_revision, embedding_language
            FROM episode_transcript_chunks
            ORDER BY episode_id, chunk_index
            """
        )
        defer { sqlite3_finalize(statement) }

        var records: [TranscriptChunkEmbeddingRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(
                TranscriptChunkEmbeddingRecord(
                    episodeID: text(statement, 0),
                    chunkIndex: Int(sqlite3_column_int(statement, 1)),
                    text: text(statement, 2),
                    embeddingDimension: optionalInt(statement, 4),
                    embeddingRevision: optionalInt(statement, 5),
                    embeddingLanguage: optionalText(statement, 6),
                    embeddingData: blob(statement, 3)
                )
            )
        }
        try checkLastStep(statement)
        return records
    }

    func fetchTranscriptChunkEmbeddingRecord(
        key: TranscriptChunkKey
    ) throws -> TranscriptChunkEmbeddingRecord? {
        let statement = try prepare(
            """
            SELECT episode_id, chunk_index, content, embedding, embedding_dimension,
                   embedding_revision, embedding_language
            FROM episode_transcript_chunks
            WHERE episode_id = ? AND chunk_index = ?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        try bindText(key.episodeID, to: 1, in: statement)
        try checkBinding(sqlite3_bind_int(statement, 2, Int32(key.chunkIndex)))

        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { return nil }
            throw databaseError()
        }
        return TranscriptChunkEmbeddingRecord(
            episodeID: text(statement, 0),
            chunkIndex: Int(sqlite3_column_int(statement, 1)),
            text: text(statement, 2),
            embeddingDimension: optionalInt(statement, 4),
            embeddingRevision: optionalInt(statement, 5),
            embeddingLanguage: optionalText(statement, 6),
            embeddingData: blob(statement, 3)
        )
    }

    func fetchApproximateIndexMetadata() throws -> ApproximateIndexMetadata? {
        guard try tableExists(named: "transcript_vector_index_metadata") else {
            return nil
        }
        let metadataStatement = try prepare(
            "SELECT name, value FROM transcript_vector_index_metadata"
        )
        defer { sqlite3_finalize(metadataStatement) }

        var values: [String: String] = [:]
        while sqlite3_step(metadataStatement) == SQLITE_ROW {
            values[text(metadataStatement, 0)] = text(metadataStatement, 1)
        }
        try checkLastStep(metadataStatement)

        guard let revision = Int(values["embedding_revision"] ?? ""),
              let dimension = Int(values["embedding_dimension"] ?? ""),
              let entryEpisodeID = values["entry_episode_id"],
              let entryChunkIndex = Int(values["entry_chunk_index"] ?? ""),
              let maximumLevel = Int(values["maximum_level"] ?? ""),
              let nodeCount = Int(values["node_count"] ?? ""),
              let language = values["embedding_language"]
        else {
            return nil
        }

        return ApproximateIndexMetadata(
            embeddingRevision: revision,
            embeddingLanguage: language,
            embeddingDimension: dimension,
            entryPoint: TranscriptChunkKey(
                episodeID: entryEpisodeID,
                chunkIndex: entryChunkIndex
            ),
            maximumLevel: maximumLevel,
            nodeCount: nodeCount
        )
    }

    func fetchApproximateNeighbors(
        for key: TranscriptChunkKey,
        level: Int
    ) throws -> [TranscriptChunkKey] {
        let statement = try prepare(
            """
            SELECT target_episode_id, target_chunk_index
            FROM transcript_vector_index_edges
            WHERE source_episode_id = ?
              AND source_chunk_index = ?
              AND level = ?
            ORDER BY rank
            """
        )
        defer { sqlite3_finalize(statement) }
        try bindText(key.episodeID, to: 1, in: statement)
        try checkBinding(sqlite3_bind_int(statement, 2, Int32(key.chunkIndex)))
        try checkBinding(sqlite3_bind_int(statement, 3, Int32(level)))

        var neighbors: [TranscriptChunkKey] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            neighbors.append(
                TranscriptChunkKey(
                    episodeID: text(statement, 0),
                    chunkIndex: Int(sqlite3_column_int(statement, 1))
                )
            )
        }
        try checkLastStep(statement)
        return neighbors
    }

    func replaceApproximateIndex(
        metadata: ApproximateIndexMetadata,
        edges: [ApproximateIndexEdge]
    ) throws {
        try execute("DELETE FROM transcript_vector_index_edges")
        try execute("DELETE FROM transcript_vector_index_metadata")

        let metadataStatement = try prepare(
            "INSERT INTO transcript_vector_index_metadata (name, value) VALUES (?, ?)"
        )
        defer { sqlite3_finalize(metadataStatement) }
        let values = [
            ("embedding_revision", String(metadata.embeddingRevision)),
            ("embedding_language", metadata.embeddingLanguage),
            ("embedding_dimension", String(metadata.embeddingDimension)),
            ("entry_episode_id", metadata.entryPoint.episodeID),
            ("entry_chunk_index", String(metadata.entryPoint.chunkIndex)),
            ("maximum_level", String(metadata.maximumLevel)),
            ("node_count", String(metadata.nodeCount)),
        ]
        for (name, value) in values {
            sqlite3_reset(metadataStatement)
            sqlite3_clear_bindings(metadataStatement)
            try bindText(name, to: 1, in: metadataStatement)
            try bindText(value, to: 2, in: metadataStatement)
            guard sqlite3_step(metadataStatement) == SQLITE_DONE else {
                throw databaseError()
            }
        }

        let edgeStatement = try prepare(
            """
            INSERT INTO transcript_vector_index_edges (
                source_episode_id, source_chunk_index,
                target_episode_id, target_chunk_index, level, rank
            ) VALUES (?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(edgeStatement) }
        for edge in edges {
            sqlite3_reset(edgeStatement)
            sqlite3_clear_bindings(edgeStatement)
            try bindText(edge.source.episodeID, to: 1, in: edgeStatement)
            try checkBinding(sqlite3_bind_int(edgeStatement, 2, Int32(edge.source.chunkIndex)))
            try bindText(edge.target.episodeID, to: 3, in: edgeStatement)
            try checkBinding(sqlite3_bind_int(edgeStatement, 4, Int32(edge.target.chunkIndex)))
            try checkBinding(sqlite3_bind_int(edgeStatement, 5, Int32(edge.level)))
            try checkBinding(sqlite3_bind_int(edgeStatement, 6, Int32(edge.rank)))
            guard sqlite3_step(edgeStatement) == SQLITE_DONE else {
                throw databaseError()
            }
        }
    }

    func clearApproximateIndex() throws {
        try execute("DELETE FROM transcript_vector_index_edges")
        try execute("DELETE FROM transcript_vector_index_metadata")
    }

    func fetchEpisode(id: String) throws -> Episode? {
        let statement = try prepare(
            """
            SELECT id, source_file, transcript_file, summary_file,
                   transcript, summary, embedding, embedding_dimension,
                   embedding_revision, embedding_language
            FROM episodes
            WHERE id = ?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        try bindText(id, to: 1, in: statement)

        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { return nil }
            throw databaseError()
        }
        return Episode(
            id: text(statement, 0),
            sourceFile: text(statement, 1),
            transcriptFile: text(statement, 2),
            summaryFile: text(statement, 3),
            transcript: text(statement, 4),
            summary: text(statement, 5),
            embeddingDimension: optionalInt(statement, 7),
            embeddingRevision: optionalInt(statement, 8),
            embeddingLanguage: optionalText(statement, 9),
            embeddingData: blob(statement, 6)
        )
    }

    public func updateEmbedding(
        episodeID: String,
        vector: [Float],
        revision: Int,
        language: NLLanguage
    ) throws {
        let statement = try prepare(
            """
            UPDATE episodes
            SET embedding = ?, embedding_dimension = ?,
                embedding_revision = ?, embedding_language = ?,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }

        let data = vector.embeddingData
        let blobResult = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                1,
                bytes.baseAddress,
                Int32(data.count),
                sqliteTransient
            )
        }
        try checkBinding(blobResult)
        try checkBinding(sqlite3_bind_int(statement, 2, Int32(vector.count)))
        try checkBinding(sqlite3_bind_int(statement, 3, Int32(revision)))
        try bindText(language.rawValue, to: 4, in: statement)
        try bindText(episodeID, to: 5, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
        }
    }

    func replaceTranscriptChunkEmbeddings(
        episodeID: String,
        chunks: [(text: String, vector: [Float])],
        revision: Int,
        language: NLLanguage
    ) throws {
        let deleteStatement = try prepare(
            "DELETE FROM episode_transcript_chunks WHERE episode_id = ?"
        )
        defer { sqlite3_finalize(deleteStatement) }
        try bindText(episodeID, to: 1, in: deleteStatement)
        guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
            throw databaseError()
        }

        let insertStatement = try prepare(
            """
            INSERT INTO episode_transcript_chunks (
                episode_id, chunk_index, content, embedding, embedding_dimension,
                embedding_revision, embedding_language
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(insertStatement) }

        for (index, chunk) in chunks.enumerated() {
            sqlite3_reset(insertStatement)
            sqlite3_clear_bindings(insertStatement)
            try bindText(episodeID, to: 1, in: insertStatement)
            try checkBinding(sqlite3_bind_int(insertStatement, 2, Int32(index)))
            try bindText(chunk.text, to: 3, in: insertStatement)

            let data = chunk.vector.embeddingData
            let blobResult = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    insertStatement,
                    4,
                    bytes.baseAddress,
                    Int32(data.count),
                    sqliteTransient
                )
            }
            try checkBinding(blobResult)
            try checkBinding(sqlite3_bind_int(insertStatement, 5, Int32(chunk.vector.count)))
            try checkBinding(sqlite3_bind_int(insertStatement, 6, Int32(revision)))
            try bindText(language.rawValue, to: 7, in: insertStatement)

            guard sqlite3_step(insertStatement) == SQLITE_DONE else {
                throw databaseError()
            }
        }
    }

    func markTranscriptChunksPrepared(
        episodeID: String,
        revision: Int,
        language: NLLanguage
    ) throws {
        let statement = try prepare(
            """
            UPDATE episodes
            SET embedding = NULL, embedding_dimension = NULL,
                embedding_revision = ?, embedding_language = ?,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try checkBinding(sqlite3_bind_int(statement, 1, Int32(revision)))
        try bindText(language.rawValue, to: 2, in: statement)
        try bindText(episodeID, to: 3, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
        }
    }

    public func beginTransaction() throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
    }

    public func commitTransaction() throws {
        try execute("COMMIT")
    }

    public func rollbackTransaction() throws {
        try execute("ROLLBACK")
    }

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS episodes (
                id TEXT PRIMARY KEY,
                source_file TEXT NOT NULL,
                transcript_file TEXT NOT NULL,
                summary_file TEXT NOT NULL,
                transcript TEXT NOT NULL,
                summary TEXT NOT NULL,
                embedding BLOB,
                embedding_dimension INTEGER,
                embedding_revision INTEGER,
                embedding_language TEXT,
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS episode_transcript_chunks (
                episode_id TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                content TEXT NOT NULL,
                embedding BLOB NOT NULL,
                embedding_dimension INTEGER NOT NULL,
                embedding_revision INTEGER NOT NULL,
                embedding_language TEXT NOT NULL,
                PRIMARY KEY (episode_id, chunk_index)
            )
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS episode_transcript_chunks_episode_idx
            ON episode_transcript_chunks(episode_id)
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS transcript_vector_index_metadata (
                name TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS episode_transcript_search
            USING fts5(
                episode_id UNINDEXED,
                source_file,
                transcript,
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS transcript_vector_index_edges (
                source_episode_id TEXT NOT NULL,
                source_chunk_index INTEGER NOT NULL,
                target_episode_id TEXT NOT NULL,
                target_chunk_index INTEGER NOT NULL,
                level INTEGER NOT NULL,
                rank INTEGER NOT NULL,
                PRIMARY KEY (source_episode_id, source_chunk_index, level, rank)
            )
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS transcript_vector_index_edges_source_idx
            ON transcript_vector_index_edges(source_episode_id, source_chunk_index, level, rank)
            """
        )
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func tableExists(named name: String) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bindText(name, to: 1, in: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw databaseError()
    }

    private static func databaseSignature(
        for url: URL,
        fileManager: FileManager
    ) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let byteCount = attributes[.size] as? NSNumber
        let modificationDate = attributes[.modificationDate] as? Date
        return "\(byteCount?.int64Value ?? 0)-\(modificationDate?.timeIntervalSince1970 ?? 0)"
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw databaseError()
        }
        return statement
    }

    private func bindText(
        _ value: String,
        to index: Int32,
        in statement: OpaquePointer
    ) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
        }
        try checkBinding(result)
    }

    private func checkBinding(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func checkLastStep(_ statement: OpaquePointer) throws {
        let result = sqlite3_errcode(handle)
        guard result == SQLITE_OK || result == SQLITE_DONE else {
            throw databaseError()
        }
    }

    private func databaseError() -> LocalVectorSearchError {
        guard let handle else {
            return .database("The database is closed.")
        }
        return .database(String(cString: sqlite3_errmsg(handle)))
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func optionalText(
        _ statement: OpaquePointer,
        _ index: Int32
    ) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return text(statement, index)
    }

    private func optionalInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int(statement, index))
    }

    private func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount > 0, let bytes = sqlite3_column_blob(statement, index) else {
            return nil
        }
        return Data(bytes: bytes, count: byteCount)
    }
}
