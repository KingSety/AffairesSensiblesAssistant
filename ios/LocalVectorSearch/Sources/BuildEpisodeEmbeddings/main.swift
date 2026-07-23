import Foundation
import LocalVectorSearch
import Darwin

@main
struct BuildEpisodeEmbeddings {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(
                Data("Embedding build failed: \(error.localizedDescription)\n".utf8)
            )
            exit(1)
        }
    }

    private static func run() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(
                Data("Usage: build-episode-embeddings /path/to/episodes.sqlite\n".utf8)
            )
            exit(2)
        }

        let databaseURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let database = try EpisodeDatabase(url: databaseURL)
        let embedder = try AppleSentenceEmbedder()
        let episodes = try database.fetchAllEpisodes()

        for (offset, episode) in episodes.enumerated() {
            let vector = try embedder.vector(for: episode.summary)
            try database.updateEmbedding(
                episodeID: episode.id,
                vector: vector,
                revision: embedder.revision,
                language: embedder.language
            )
            print("Embedded \(offset + 1)/\(episodes.count): \(episode.sourceFile)")
        }

        print(
            "Stored French revision \(embedder.revision) embeddings "
                + "with \(embedder.dimension) dimensions."
        )
    }
}
