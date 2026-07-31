import Foundation
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
}
