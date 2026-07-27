import Foundation
import LocalVectorSearch

enum AIAction: String, Codable {
    case chat
    case summarize
    case translate
}

struct ChatMessage: Identifiable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String

    init(role: Role, text: String) {
        self.id = UUID()
        self.role = role
        self.text = text
    }
}

struct EpisodeAIService {
    func respond(
        action: AIAction,
        query: String,
        messages: [ChatMessage],
        episode: PodcastEpisode? = nil,
        targetLanguage: String? = nil
    ) async throws -> String {
        let sourceEpisodes = try sources(for: query, selectedEpisode: episode)
        let context = try sourceEpisodes.map { sourceEpisode in
            EpisodeContext(
                episode: sourceEpisode,
                transcript: try EpisodeTranscriptStore.transcript(for: sourceEpisode)
            )
        }
        let requestBody = AIRequest(
            action: action,
            query: query,
            messages: messages,
            episode: context.first,
            sources: context,
            targetLanguage: targetLanguage,
            preferences: AIPreferences.current
        )

        var request = URLRequest(url: try backendURL().appendingPathComponent("v1/assist"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let error = try? JSONDecoder().decode(AIErrorResponse.self, from: data)
            throw AIServiceError.backend(error?.error ?? "The AI service returned HTTP \(httpResponse.statusCode).")
        }

        return try JSONDecoder().decode(AIBackendResponse.self, from: data).text
    }

    private func sources(
        for query: String,
        selectedEpisode: PodcastEpisode?
    ) throws -> [PodcastEpisode] {
        if let selectedEpisode {
            return [selectedEpisode]
        }
        return try EpisodeCatalog.matches(for: query)
    }

    private func backendURL() throws -> URL {
        let configuredURL = ProcessInfo.processInfo.environment["AI_BACKEND_URL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "AIBackendURL") as? String
            ?? "http://127.0.0.1:8080"
        guard let url = URL(string: configuredURL) else {
            throw AIServiceError.configuration("AIBackendURL is not a valid URL.")
        }
        return url
    }
}

private struct AIRequest: Codable {
    let action: AIAction
    let query: String
    let messages: [ChatMessage]
    let episode: EpisodeContext?
    let sources: [EpisodeContext]
    let targetLanguage: String?
    let preferences: AIPreferences
}

private struct AIPreferences: Codable {
    let responseLength: String
    let showTimestampsAndSources: Bool

    static var current: AIPreferences {
        let defaults = UserDefaults.standard
        let savedLength = defaults.string(forKey: "responseLength") ?? "Medium"
        let responseLength = ["Short", "Medium", "Long"].contains(savedLength)
            ? savedLength
            : "Medium"
        let showTimestampsAndSources = defaults.string(forKey: "timestamps") != "No"

        return AIPreferences(
            responseLength: responseLength,
            showTimestampsAndSources: showTimestampsAndSources
        )
    }

    enum CodingKeys: String, CodingKey {
        case responseLength
        case showTimestampsAndSources
    }
}

private struct EpisodeContext: Codable {
    let title: String
    let description: String
    let language: String
    let publishedDate: String?
    let durationSeconds: Int?
    let transcript: String?

    init(episode: PodcastEpisode, transcript: String?) {
        title = episode.title
        description = episode.description
        language = episode.language
        publishedDate = episode.publishedDate
        durationSeconds = episode.durationSeconds
        self.transcript = transcript.map { String($0.prefix(60_000)) }
    }

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case language
        case publishedDate = "published_date"
        case durationSeconds = "duration_seconds"
        case transcript
    }
}

private enum EpisodeTranscriptStore {
    static func transcript(for episode: PodcastEpisode) throws -> String? {
        let databaseURL = try EpisodeDatabase.installBundledDatabase()
        let database = try EpisodeDatabase(url: databaseURL)
        let normalizedTitle = normalized(episode.title)

        return try database.fetchAllEpisodes().first { storedEpisode in
            let normalizedSource = normalized(
                URL(fileURLWithPath: storedEpisode.sourceFile).deletingPathExtension().lastPathComponent
            )
            return normalizedSource.contains(normalizedTitle)
                || normalizedTitle.contains(normalizedSource)
        }?.transcript
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

private struct AIBackendResponse: Decodable {
    let text: String
}

private struct AIErrorResponse: Decodable {
    let error: String
}

private enum AIServiceError: LocalizedError {
    case configuration(String)
    case invalidResponse
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .configuration(let message), .backend(let message):
            return message
        case .invalidResponse:
            return "The AI service returned an invalid response."
        }
    }
}
