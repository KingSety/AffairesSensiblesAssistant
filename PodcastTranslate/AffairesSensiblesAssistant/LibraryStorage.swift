import Foundation

struct LibraryStorageUsage {
    let transcriptAndEmbeddingCache: Int64

    var cacheText: String {
        ByteCountFormatter.string(fromByteCount: transcriptAndEmbeddingCache, countStyle: .file)
    }
}

enum LibraryStorage {
    private static let fileManager = FileManager.default

    static func usage() throws -> LibraryStorageUsage {
        LibraryStorageUsage(
            transcriptAndEmbeddingCache: try fileSize(at: databaseURL)
        )
    }

    static func clearTranscriptAndEmbeddingCache() throws {
        let cacheURL = try databaseURL
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return
        }
        try fileManager.removeItem(at: cacheURL)
    }

    static func clearLibraryData() throws {
        let storageURL = try applicationSupportDirectory
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return
        }
        try fileManager.removeItem(at: storageURL)
    }

    private static var applicationSupportDirectory: URL {
        get throws {
            let supportDirectory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return supportDirectory.appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "PodcastTranslate",
                isDirectory: true
            )
        }
    }

    private static var databaseURL: URL {
        get throws {
            try applicationSupportDirectory.appendingPathComponent("episodes.sqlite")
        }
    }

    private static func fileSize(at url: URL) throws -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else {
            return 0
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

}
