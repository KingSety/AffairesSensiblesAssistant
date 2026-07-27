//
//  HomeView.swift
//  PodcastTranslate
//
//  Created by Sety Tekeu on 7/25/26.
//

import Foundation
import SwiftUI

struct HomeView: View {
    @State private var userInput = ""
    @State private var messages = [
        ChatMessage(
            role: .assistant,
            text: "Hi, I’m your library assistant. Ask me to summarize, find, or explore your imported episodes."
        )
    ]
    @State private var isResponding = false
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ChatTranscript(messages: messages, isResponding: isResponding)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    if messages.count == 1 {
                        ChatSuggestions { suggestion in
                            submit(suggestion)
                        }
                    }

                    HStack(alignment: .bottom, spacing: 10) {
                        TextField(
                            "Ask about your library…",
                            text: $userInput,
                            axis: .vertical
                        )
                        .lineLimit(1...4)
                        .focused($isComposerFocused)
                        .onSubmit {
                            submit(userInput)
                        }

                        Button {
                            submit(userInput)
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .disabled(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResponding)
                        .accessibilityLabel("Send message")
                    }
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
                .padding()
            }
            .navigationTitle("AI Chat")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func submit(_ draft: String) {
        let query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isResponding else {
            return
        }

        messages.append(ChatMessage(role: .user, text: query))
        userInput = ""
        isComposerFocused = false
        isResponding = true

        Task {
            let response = LibraryAssistant.response(to: query)
            await MainActor.run {
                messages.append(ChatMessage(role: .assistant, text: response))
                isResponding = false
            }
        }
    }
}

private struct ChatTranscript: View {
    let messages: [ChatMessage]
    let isResponding: Bool

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(messages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                    }

                    if isResponding {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Searching your library…")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .id("response-progress")
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) {
                guard let lastMessage = messages.last else {
                    return
                }
                withAnimation {
                    scrollProxy.scrollTo(lastMessage.id, anchor: .bottom)
                }
            }
            .onChange(of: isResponding) {
                if isResponding {
                    withAnimation {
                        scrollProxy.scrollTo("response-progress", anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 48)
            }

            Text(message.text)
                .foregroundStyle(message.role == .user ? .white : .primary)
                .padding(12)
                .background(
                    message.role == .user ? Color.accentColor : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 16)
                )

            if message.role == .assistant {
                Spacer(minLength: 48)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ChatSuggestions: View {
    let onSelect: (String) -> Void

    private let suggestions = [
        "Summarize my latest episodes",
        "Find episodes about history",
        "What can I listen to in French?"
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        onSelect(suggestion)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

private struct ChatMessage: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let text: String
}

private struct CatalogEpisode: Decodable {
    let title: String
    let description: String
    let language: String
}

private enum LibraryAssistant {
    static func response(to query: String) -> String {
        do {
            let episodes = try loadEpisodes()
            let matches = bestMatches(for: query, in: episodes)

            guard !matches.isEmpty else {
                return "I couldn't find a matching episode in your imported library. Try a person, topic, or title."
            }

            let results = matches.prefix(3).map { episode in
                "• \(episode.title) — \(episode.description)"
            }
            return "Here are the best matches from your library:\n\n\(results.joined(separator: "\n\n"))"
        } catch {
            return "I couldn't access the imported episode catalog. Make sure imported_episodes.json is included in the app target."
        }
    }

    private static func loadEpisodes() throws -> [CatalogEpisode] {
        guard let catalogURL = Bundle.main.url(
            forResource: "imported_episodes",
            withExtension: "json"
        ) else {
            throw CatalogError.missing
        }

        return try JSONDecoder().decode([CatalogEpisode].self, from: Data(contentsOf: catalogURL))
    }

    private static func bestMatches(
        for query: String,
        in episodes: [CatalogEpisode]
    ) -> [CatalogEpisode] {
        let normalizedQuery = query.lowercased()
        if normalizedQuery.contains("latest") || normalizedQuery.contains("recent")
            || normalizedQuery.contains("summar") || normalizedQuery.contains("résum") {
            return Array(episodes.prefix(3))
        }

        if normalizedQuery.contains("french") || normalizedQuery.contains("français")
            || normalizedQuery.contains("francais") {
            return episodes.filter { $0.language.lowercased() == "fr" }.prefix(3).map { $0 }
        }

        let keywords = normalizedQuery
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }

        guard !keywords.isEmpty else {
            return Array(episodes.prefix(3))
        }

        return episodes
            .map { episode in
                let title = episode.title.lowercased()
                let description = episode.description.lowercased()
                let score = keywords.reduce(into: 0) { total, keyword in
                    if title.contains(keyword) {
                        total += 3
                    }
                    if description.contains(keyword) {
                        total += 1
                    }
                    if episode.language.lowercased().contains(keyword) {
                        total += 1
                    }
                }
                return (episode, score)
            }
            .filter { $0.1 > 0 }
            .sorted { left, right in
                left.1 > right.1
            }
            .map(\.0)
    }

    private enum CatalogError: Error {
        case missing
    }
}

#Preview {
    HomeView()
}
