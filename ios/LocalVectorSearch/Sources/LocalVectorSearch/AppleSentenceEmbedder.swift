import Accelerate
import Foundation
import NaturalLanguage

public struct AppleSentenceEmbedder {
    public let language: NLLanguage = .french
    public let revision: Int
    public let dimension: Int

    private let embedding: NLEmbedding

    public static var isAvailable: Bool {
        let revision = NLEmbedding.currentSentenceEmbeddingRevision(for: .french)
        return revision > 0
            && NLEmbedding.sentenceEmbedding(for: .french, revision: revision) != nil
    }

    public init(revision: Int? = nil) throws {
        let selectedRevision = revision
            ?? NLEmbedding.currentSentenceEmbeddingRevision(for: .french)
        guard selectedRevision > 0,
              let embedding = NLEmbedding.sentenceEmbedding(
                for: .french,
                revision: selectedRevision
              )
        else {
            throw LocalVectorSearchError.embeddingUnavailable(NLLanguage.french.rawValue)
        }

        self.revision = selectedRevision
        self.dimension = embedding.dimension
        self.embedding = embedding
    }

    public func vector(for text: String) throws -> [Float] {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            throw LocalVectorSearchError.emptyText
        }
        guard let doubles = embedding.vector(for: input), !doubles.isEmpty else {
            throw LocalVectorSearchError.embeddingUnavailable(language.rawValue)
        }

        let values = doubles.map(Float.init)
        var sumOfSquares: Float = 0
        vDSP_svesq(values, 1, &sumOfSquares, vDSP_Length(values.count))
        let magnitude = sqrt(sumOfSquares)
        guard magnitude.isFinite, magnitude > 0 else {
            throw LocalVectorSearchError.invalidEmbedding
        }

        var divisor = magnitude
        var normalized = [Float](repeating: 0, count: values.count)
        vDSP_vsdiv(
            values,
            1,
            &divisor,
            &normalized,
            1,
            vDSP_Length(values.count)
        )
        return normalized
    }
}

extension Array where Element == Float {
    var embeddingData: Data {
        withUnsafeBytes { Data($0) }
    }
}

extension Data {
    func floatEmbedding(expectedDimension: Int) throws -> [Float] {
        let stride = MemoryLayout<Float>.stride
        guard count == expectedDimension * stride else {
            throw LocalVectorSearchError.invalidEmbedding
        }

        var values = [Float](repeating: 0, count: expectedDimension)
        _ = values.withUnsafeMutableBytes { destination in
            copyBytes(to: destination)
        }
        return values
    }
}
