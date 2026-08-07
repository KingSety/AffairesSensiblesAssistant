//
//  HomeView.swift
//  PodcastTranslate
//
//  Created by Sety Tekeu on 7/25/26.
//

import LocalVectorSearch
import SwiftUI
import UserNotifications

struct HomeView: View {
    @State private var userInput = ""
    @State private var queryHistory: [PodcastSearchQuery] = []
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if queryHistory.isEmpty {
                    ContentUnavailableView(
                        "Ask your podcast assistant",
                        systemImage: "sparkles",
                        description: Text("Describe a topic to find similar podcasts from your local Deepgram transcripts.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(queryHistory) { query in
                                PodcastSearchQueryView(query: query)
                            }
                        }
                        .padding()
                    }
                }

                Divider()

                VStack(spacing: 10) {
                    HStack(alignment: .bottom, spacing: 10) {
                        TextField(
                            "Find podcasts about…",
                            text: $userInput,
                            axis: .vertical
                        )
                        .accessibilityLabel("Podcast search query.")
                        .accessibilityIdentifier("podcast-search-query-field")
                        .lineLimit(1...4)
                        .focused($isComposerFocused)
                        .onSubmit {
                            submit(userInput)
                        }

                        Button {
                            submit(userInput)
                        } label: {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .font(.title2)
                        }
                        .disabled(
                            userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        .accessibilityIdentifier("podcast-search-submit-button")
                    }
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
                .padding()
            }
            .navigationTitle("Podcast Assistant")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func submit(_ draft: String) {
        let query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return
        }

        let queryID = UUID()
        userInput = ""
        isComposerFocused = false
        queryHistory.append(PodcastSearchQuery(id: queryID, text: query, isSearching: true))

        Task {
            do {
                let frenchQuery = await OnDeviceLanguageService.frenchSearchQuery(for: query)
                let results = try await LocalTranscriptService.search(frenchQuery, limit: 5)
                updateQuery(id: queryID) { searchQuery in
                    searchQuery.results = results
                    searchQuery.isSearching = false
                    NotificationManager.notifyAssistantResultsReady(query: query)
                }
            } catch {
                updateQuery(id: queryID) { searchQuery in
                    searchQuery.errorMessage = error.localizedDescription
                    searchQuery.isSearching = false
                }
            }
        }
    }

    private func updateQuery(
        id: UUID,
        update: (inout PodcastSearchQuery) -> Void
    ) {
        guard let index = queryHistory.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&queryHistory[index])
    }
}

private struct PodcastSearchQuery: Identifiable {
    let id: UUID
    let text: String
    var results: [LocalTranscriptSearchResult] = []
    var errorMessage: String?
    var isSearching: Bool
}

private struct PodcastSearchQueryView: View {
    let query: PodcastSearchQuery

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(query.text)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(12)
                .background(.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))

            if query.isSearching {
                ProgressView("Finding similar episodes…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else if let errorMessage = query.errorMessage {
                ContentUnavailableView(
                    "Local search unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if query.results.isEmpty {
                ContentUnavailableView(
                    "No similar podcasts found",
                    systemImage: "magnifyingglass",
                    description: Text("Try a broader topic or add more local Deepgram transcripts.")
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Similar Podcasts")
                        .font(.headline)
                    Text("Matched from your local transcripts")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(Array(query.results.enumerated()), id: \.element.id) { index, result in
                        resultLink(for: result, rank: index + 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func resultLink(
        for result: LocalTranscriptSearchResult,
        rank: Int
    ) -> some View {
        if let podcast = result.podcast {
            NavigationLink {
                EpisodeDetailView(episode: podcast)
            } label: {
                TranscriptSearchResultCard(result: result, rank: rank)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                TranscriptView(result: result)
            } label: {
                TranscriptSearchResultCard(result: result, rank: rank)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct TranscriptSearchResultCard: View {
    let result: LocalTranscriptSearchResult
    let rank: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.title)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(result.excerpt)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(4)

            Text(matchLabel)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var matchLabel: String {
        switch result.matchKind {
        case .semantic:
            return "#\(rank) · Local similarity \(result.score.formatted(.percent.precision(.fractionLength(0))))"
        case .transcriptKeyword:
            return "#\(rank) · Matching transcript topic"
        }
    }
}

private struct TranscriptView: View {
    let result: LocalTranscriptSearchResult

    var body: some View {
        ScrollView {
            Text(result.episode.transcript)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(result.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    HomeView()
}

