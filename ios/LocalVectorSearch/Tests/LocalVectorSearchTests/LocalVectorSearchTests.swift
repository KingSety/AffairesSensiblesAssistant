import Foundation
import SQLite3
import XCTest
@testable import LocalVectorSearch

final class LocalVectorSearchTests: XCTestCase {
    func testFloatEmbeddingRoundTrip() throws {
        let input: [Float] = [0.25, -0.5, 0.75]
        let output = try input.embeddingData.floatEmbedding(
            expectedDimension: input.count
        )
        XCTAssertEqual(output, input)
    }

    func testRejectsWrongEmbeddingDimension() {
        let input: [Float] = [0.25, -0.5, 0.75]
        XCTAssertThrowsError(
            try input.embeddingData.floatEmbedding(expectedDimension: 4)
        )
    }

    func testPersistentNeighborIndexReturnsClosestChunk() throws {
        let records = [
            chunk(id: "history", index: 0, vector: [1, 0, 0]),
            chunk(id: "africa", index: 0, vector: [0.95, 0.1, 0]),
            chunk(id: "sports", index: 0, vector: [0, 1, 0]),
            chunk(id: "music", index: 0, vector: [0, 0, 1]),
            chunk(id: "science", index: 0, vector: [-1, 0, 0]),
        ]
        let storedIndex = try XCTUnwrap(
            ApproximateVectorIndex.build(
                records: records,
                embeddingRevision: 1,
                embeddingLanguage: "fr",
                embeddingDimension: 3
            )
        )
        let index = ApproximateVectorIndex(metadata: storedIndex.metadata)
        let recordsByKey = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })

        let matches = try index.search(
            queryVector: [1, 0.05, 0],
            candidateCount: 3,
            recordForKey: { recordsByKey[$0] },
            neighborsForKey: { source, level in
                storedIndex.edges
                    .filter { $0.source == source && $0.level == level }
                    .sorted { $0.rank < $1.rank }
                    .map(\.target)
            }
        )

        XCTAssertEqual(matches.first?.key.episodeID, "history")
        XCTAssertTrue(matches.contains { $0.key.episodeID == "africa" })
    }

    func testCatalogMetadataAndTranscriptAreLoadedSeparatelyByID() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let database = try EpisodeDatabase(url: databaseURL)

        try executeSQL(
            """
            INSERT INTO episodes (
                id, title, short_description, source_url, artwork_url,
                language, published_date, duration_seconds,
                transcript_status, source_file
            ) VALUES (
                'episode-id', 'Episode title', 'Short description',
                'https://example.com/episode', 'https://example.com/art.jpg',
                'fr', '2026-08-04', 1200, 'available', 'Episode.m4a'
            );
            INSERT INTO episode_transcripts (
                episode_id, transcript_file, transcript
            ) VALUES ('episode-id', 'Episode.txt', 'Full transcript');
            """,
            at: databaseURL
        )

        let metadata = try XCTUnwrap(database.fetchCatalogEpisodes().first)
        XCTAssertEqual(metadata.id, "episode-id")
        XCTAssertEqual(metadata.title, "Episode title")
        XCTAssertEqual(metadata.shortDescription, "Short description")
        XCTAssertTrue(metadata.transcriptAvailable)
        XCTAssertEqual(try database.transcriptCount(), 1)
        XCTAssertEqual(
            try database.fetchTranscript(episodeID: metadata.id),
            "Full transcript"
        )
    }

    func testWriteModeMigratesLegacyEpisodeRows() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try executeSQL(
            """
            CREATE TABLE episodes (
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
            );
            INSERT INTO episodes (
                id, source_file, transcript_file, summary_file, transcript, summary
            ) VALUES (
                'legacy-id', 'Legacy.m4a', 'Legacy.txt', 'Legacy.txt',
                'Legacy transcript', 'Legacy transcript'
            );
            """,
            at: databaseURL
        )

        let database = try EpisodeDatabase(url: databaseURL)

        XCTAssertEqual(try database.transcriptCount(), 1)
        XCTAssertEqual(
            try database.fetchTranscript(episodeID: "legacy-id"),
            "Legacy transcript"
        )
        XCTAssertEqual(try database.fetchCatalogEpisodes().first?.id, "legacy-id")
    }

    private func chunk(
        id: String,
        index: Int,
        vector: [Float]
    ) -> TranscriptChunkEmbeddingRecord {
        TranscriptChunkEmbeddingRecord(
            episodeID: id,
            chunkIndex: index,
            text: id,
            embeddingDimension: vector.count,
            embeddingRevision: 1,
            embeddingLanguage: "fr",
            embeddingData: vector.embeddingData
        )
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalVectorSearchTests-\(UUID().uuidString).sqlite")
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "LocalVectorSearchTests", code: 1)
        }
        defer { sqlite3_close(handle) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(errorMessage)
            throw NSError(
                domain: "LocalVectorSearchTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}
