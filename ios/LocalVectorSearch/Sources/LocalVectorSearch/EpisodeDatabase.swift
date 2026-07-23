import Foundation
import NaturalLanguage
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class EpisodeDatabase {
    private var handle: OpaquePointer?

    public init(url: URL) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
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
        try createSchema()
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
        if !fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
        return destinationURL
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

    func fetchEmbeddingRecords() throws -> [EpisodeEmbeddingRecord] {
        let statement = try prepare(
            """
            SELECT id, summary, embedding, embedding_dimension,
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
                    summary: text(statement, 1),
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
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError()
        }
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
