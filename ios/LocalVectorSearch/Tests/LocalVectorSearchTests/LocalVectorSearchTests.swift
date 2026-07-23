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
}
