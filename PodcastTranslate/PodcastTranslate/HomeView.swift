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
            let response: String
            do {
                response = try await EpisodeAIService().respond(
                    action: .chat,
                    query: query,
                    messages: messages
                )
            } catch {
                response = "I couldn't complete that request. \(error.localizedDescription)"
            }
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

#Preview {
    HomeView()
}
