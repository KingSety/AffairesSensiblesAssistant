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
        let location: String
        switch accessMode {
        case .readOnly:
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
            location = "\(url.absoluteString)?mode=ro&immutable=1"
        case .readWrite:
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            location = url.path
        }
        let result = sqlite3_open_v2(
            location,
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
            SELECT e.id, e.title, e.short_description, e.source_url,
                   e.artwork_url, e.language, e.published_date, e.duration_seconds,
                   e.source_file, t.transcript_file, t.transcript,
                   t.embedding, t.embedding_dimension,
                   t.embedding_revision, t.embedding_language
            FROM episodes AS e
            JOIN episode_transcripts AS t ON t.episode_id = e.id
            ORDER BY e.source_file
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var episodes: [Episode] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let embeddingData: Data?
            let byteCount = Int(sqlite3_column_bytes(statement, 11))
            if byteCount > 0, let bytes = sqlite3_column_blob(statement, 11) {
                embeddingData = Data(bytes: bytes, count: byteCount)
            } else {
                embeddingData = nil
            }

            episodes.append(
                Episode(
                    id: text(statement, 0),
                    metadata: episodeMetadata(from: statement),
                    sourceFile: text(statement, 8),
                    transcriptFile: text(statement, 9),
                    transcript: text(statement, 10),
                    embeddingDimension: optionalInt(statement, 12),
                    embeddingRevision: optionalInt(statement, 13),
                    embeddingLanguage: optionalText(statement, 14),
                    embeddingData: embeddingData
                )
            )
        }
        try checkLastStep(statement)
        return episodes
    }

    public func fetchCatalogEpisodes() throws -> [EpisodeMetadata] {
        let statement = try prepare(
            """
            SELECT e.id, e.title, e.short_description, e.source_url,
                   e.artwork_url, e.language, e.published_date, e.duration_seconds,
                   e.media_status, e.availability_message,
                   EXISTS (
                       SELECT 1 FROM episode_transcripts AS t
                       WHERE t.episode_id = e.id AND trim(t.transcript) != ''
                   )
            FROM episodes AS e
            ORDER BY e.catalog_position
            """
        )
        defer { sqlite3_finalize(statement) }

        var episodes: [EpisodeMetadata] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            episodes.append(
                episodeMetadata(
                    from: statement,
                    transcriptFlagColumn: 10,
                    mediaStatusColumn: 8,
                    availabilityMessageColumn: 9
                )
            )
        }
        try checkLastStep(statement)
        return episodes
    }

    public func transcriptCount() throws -> Int {
        let statement = try prepare(
            "SELECT COUNT(*) FROM episode_transcripts WHERE trim(transcript) != ''"
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw databaseError()
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func fetchTranscript(episodeID: String) throws -> String? {
        let statement = try prepare(
            "SELECT transcript FROM episode_transcripts WHERE episode_id = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bindText(episodeID, to: 1, in: statement)

        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw databaseError() }
        return text(statement, 0)
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
            SELECT e.id, e.source_file, t.transcript
            FROM episodes AS e
            JOIN episode_transcripts AS t ON t.episode_id = e.id
            WHERE trim(t.transcript) != ''
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
            SELECT t.episode_id, t.transcript, t.embedding, t.embedding_dimension,
                   t.embedding_revision, t.embedding_language
            FROM episode_transcripts AS t
            JOIN episodes AS e ON e.id = t.episode_id
            ORDER BY e.source_file
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
            SELECT e.id, e.title, e.short_description, e.source_url,
                   e.artwork_url, e.language, e.published_date, e.duration_seconds,
                   e.source_file, t.transcript_file, t.transcript,
                   t.embedding, t.embedding_dimension,
                   t.embedding_revision, t.embedding_language
            FROM episodes AS e
            JOIN episode_transcripts AS t ON t.episode_id = e.id
            WHERE e.id = ?
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
            metadata: episodeMetadata(from: statement),
            sourceFile: text(statement, 8),
            transcriptFile: text(statement, 9),
            transcript: text(statement, 10),
            embeddingDimension: optionalInt(statement, 12),
            embeddingRevision: optionalInt(statement, 13),
            embeddingLanguage: optionalText(statement, 14),
            embeddingData: blob(statement, 11)
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
            UPDATE episode_transcripts
            SET embedding = ?, embedding_dimension = ?,
                embedding_revision = ?, embedding_language = ?,
                updated_at = CURRENT_TIMESTAMP
            WHERE episode_id = ?
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
            UPDATE episode_transcripts
            SET embedding = NULL, embedding_dimension = NULL,
                embedding_revision = ?, embedding_language = ?,
                updated_at = CURRENT_TIMESTAMP
            WHERE episode_id = ?
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

    /// Makes a completed database safe to ship as a read-only app resource.
    public func finalizeForBundling() throws {
        guard case .readWrite = accessMode else { return }
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("PRAGMA journal_mode=DELETE")
    }

    private func createSchema() throws {
        try execute("PRAGMA foreign_keys = ON")
        if try tableExists(named: "episodes"),
           try columnExists(named: "transcript", in: "episodes") {
            try migrateLegacyEpisodeSchema()
        }
        try createEpisodeTables()
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
        try execute("PRAGMA user_version = 3")
    }

    private func createEpisodeTables() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS episodes (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                short_description TEXT NOT NULL DEFAULT '',
                source_url TEXT NOT NULL DEFAULT '',
                artwork_url TEXT NOT NULL DEFAULT '',
                language TEXT NOT NULL DEFAULT 'fr',
                published_date TEXT,
                duration_seconds INTEGER,
                catalog_position INTEGER NOT NULL DEFAULT 0,
                transcript_status TEXT NOT NULL DEFAULT 'missing'
                    CHECK (transcript_status IN ('available', 'description_only', 'missing')),
                media_status TEXT NOT NULL DEFAULT 'unknown'
                    CHECK (media_status IN ('available', 'unavailable', 'unknown')),
                availability_message TEXT NOT NULL DEFAULT '',
                source_file TEXT NOT NULL DEFAULT '',
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS episode_transcripts (
                episode_id TEXT PRIMARY KEY,
                transcript_file TEXT NOT NULL DEFAULT '',
                transcript TEXT NOT NULL,
                embedding BLOB,
                embedding_dimension INTEGER,
                embedding_revision INTEGER,
                embedding_language TEXT,
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (episode_id) REFERENCES episodes(id) ON DELETE CASCADE
            )
            """
        )
        if try !columnExists(named: "catalog_position", in: "episodes") {
            try execute(
                "ALTER TABLE episodes ADD COLUMN catalog_position INTEGER NOT NULL DEFAULT 0"
            )
        }
        if try !columnExists(named: "media_status", in: "episodes") {
            try execute(
                "ALTER TABLE episodes ADD COLUMN media_status TEXT NOT NULL "
                    + "DEFAULT 'unknown' CHECK (media_status IN "
                    + "('available', 'unavailable', 'unknown'))"
            )
        }
        if try !columnExists(named: "availability_message", in: "episodes") {
            try execute(
                "ALTER TABLE episodes ADD COLUMN availability_message "
                    + "TEXT NOT NULL DEFAULT ''"
            )
        }
        try execute(
            "CREATE INDEX IF NOT EXISTS episodes_source_file_idx ON episodes(source_file)"
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS episodes_published_date_idx "
                + "ON episodes(published_date DESC)"
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS episodes_catalog_position_idx "
                + "ON episodes(catalog_position)"
        )
    }

    private func migrateLegacyEpisodeSchema() throws {
        try execute("PRAGMA foreign_keys = OFF")
        defer { try? execute("PRAGMA foreign_keys = ON") }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("ALTER TABLE episodes RENAME TO episodes_legacy")
            try createEpisodeTables()
            try execute(
                """
                INSERT INTO episodes (
                    id, title, short_description, source_url, artwork_url,
                    language, transcript_status, media_status,
                    availability_message, source_file, updated_at
                )
                SELECT id, source_file, '', '', '',
                       COALESCE(NULLIF(embedding_language, ''), 'fr'),
                       CASE WHEN trim(transcript) = '' THEN 'missing' ELSE 'available' END,
                       CASE WHEN trim(transcript) = '' THEN 'unknown' ELSE 'available' END,
                       '', source_file, updated_at
                FROM episodes_legacy
                """
            )
            try execute(
                """
                INSERT INTO episode_transcripts (
                    episode_id, transcript_file, transcript, embedding,
                    embedding_dimension, embedding_revision, embedding_language, updated_at
                )
                SELECT id, transcript_file, transcript, embedding,
                       embedding_dimension, embedding_revision, embedding_language, updated_at
                FROM episodes_legacy
                WHERE trim(transcript) != ''
                """
            )
            try execute("DROP TABLE episodes_legacy")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
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

    private func columnExists(named name: String, in table: String) throws -> Bool {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == name { return true }
        }
        try checkLastStep(statement)
        return false
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

    private func episodeMetadata(
        from statement: OpaquePointer,
        transcriptFlagColumn: Int32? = nil,
        mediaStatusColumn: Int32? = nil,
        availabilityMessageColumn: Int32? = nil
    ) -> EpisodeMetadata {
        let mediaAvailability = mediaStatusColumn.flatMap {
            EpisodeMediaAvailability(rawValue: text(statement, $0))
        } ?? (transcriptFlagColumn == nil ? .available : .unknown)
        return EpisodeMetadata(
            id: text(statement, 0),
            title: text(statement, 1),
            shortDescription: text(statement, 2),
            sourceURL: text(statement, 3),
            artworkURL: text(statement, 4),
            language: text(statement, 5),
            publishedDate: optionalText(statement, 6),
            durationSeconds: optionalInt(statement, 7),
            transcriptAvailable: transcriptFlagColumn.map {
                sqlite3_column_int(statement, $0) != 0
            } ?? true,
            mediaAvailability: mediaAvailability,
            availabilityMessage: availabilityMessageColumn.map {
                text(statement, $0)
            } ?? ""
        )
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
