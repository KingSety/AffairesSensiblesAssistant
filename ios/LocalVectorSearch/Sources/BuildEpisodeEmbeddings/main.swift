import Foundation
import LocalVectorSearch
import Darwin

@main
struct BuildEpisodeEmbeddings {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(
                Data("Embedding build failed: \(error.localizedDescription)\n".utf8)
            )
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let databasePath = arguments.first,
              arguments.count == 1 || arguments == [databasePath, "--quick"]
        else {
            FileHandle.standardError.write(
                Data("Usage: build-episode-embeddings /path/to/episodes.sqlite [--quick]\n".utf8)
            )
            exit(2)
        }

        let useQuickIndex = arguments.contains("--quick")
        let databaseURL = URL(fileURLWithPath: databasePath)
        let database = try EpisodeDatabase(url: databaseURL)
        let search = try LocalEpisodeSearch(
            databaseURL: databaseURL,
            maximumChunksPerEpisode: useQuickIndex ? 1 : nil
        )
        try await search.prepareEmbeddings()
        let chunkCount = try database.transcriptChunkCount()
        let mode = useQuickIndex ? "quick testing" : "full"
        print("Built a \(mode) HNSW-style index for \(chunkCount) transcript chunks.")
    }
}
