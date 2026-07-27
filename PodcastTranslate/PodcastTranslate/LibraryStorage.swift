import Foundation

struct LibraryStorageUsage {
    let downloads: Int64
    let transcriptAndEmbeddingCache: Int64

    var downloadsText: String {
        ByteCountFormatter.string(fromByteCount: downloads, countStyle: .file)
    }

    var cacheText: String {
        ByteCountFormatter.string(fromByteCount: transcriptAndEmbeddingCache, countStyle: .file)
    }
}

enum LibraryStorage {
    private static let fileManager = FileManager.default

    static func usage() throws -> LibraryStorageUsage {
        LibraryStorageUsage(
            downloads: try directorySize(at: downloadsDirectory),
            transcriptAndEmbeddingCache: try fileSize(at: databaseURL)
        )
    }

    static func clearDownloads() throws {
        let downloadsURL = try downloadsDirectory
        guard fileManager.fileExists(atPath: downloadsURL.path) else {
            return
        }
        try fileManager.removeItem(at: downloadsURL)
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
        UserDefaults.standard.removeObject(forKey: "listeningProgress")
        UserDefaults.standard.removeObject(forKey: "recentlyOpenedEpisodes")
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

    private static var downloadsDirectory: URL {
        get throws {
            try applicationSupportDirectory.appendingPathComponent(
                "Downloads",
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

    private static func directorySize(at url: URL) throws -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else {
            return 0
        }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        var total: Int64 = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: keys)
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
