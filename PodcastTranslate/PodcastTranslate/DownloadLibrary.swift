import Foundation

struct DownloadedEpisode: Identifiable, Equatable {
    let episode: PodcastEpisode
    let audioURL: URL

    var id: String { episode.id }
}

enum DownloadLibrary {
    private static let supportedExtensions = Set(["m4a", "mp3", "wav", "aac", "ogg", "opus"])

    static func load() throws -> [DownloadedEpisode] {
        let directory = try downloadsDirectoryURL()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }

        let catalog = try EpisodeCatalog.load()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return files
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { audioURL in
                guard let episode = matchingEpisode(for: audioURL, in: catalog) else {
                    return nil
                }
                return DownloadedEpisode(episode: episode, audioURL: audioURL)
            }
            .sorted { $0.episode.title < $1.episode.title }
    }

    private static func downloadsDirectoryURL() throws -> URL {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return supportDirectory
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "PodcastTranslate", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    private static func matchingEpisode(
        for audioURL: URL,
        in catalog: [PodcastEpisode]
    ) -> PodcastEpisode? {
        let filename = normalized(audioURL.deletingPathExtension().lastPathComponent)
        return catalog.first { episode in
            let title = normalized(episode.title)
            return filename.contains(title) || title.contains(filename)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
