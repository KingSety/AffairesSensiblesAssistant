import SwiftUI

struct EpisodeDetailView: View {
    let episode: PodcastEpisode

    @State private var generatedText: String?
    @State private var selectedAction: AIAction?
    @State private var targetLanguage = "English"
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showPlayer = false
    @State private var playerController = AudioPlayerController()

    private let service = EpisodeAIService()
    private let translationLanguages = ["English", "French", "Spanish", "German"]

    var body: some View {
        ScrollView {
            VStack {
                EpisodeHeaderCard(episode: episode)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Episode Tools")
                        .font(.headline)

                    HStack(spacing: 12) {
                        Menu {
                            Picker("Translate to", selection: $targetLanguage) {
                                ForEach(translationLanguages, id: \.self) { language in
                                    Text(language).tag(language)
                                }
                            }

                            Divider()

                            Button("Translate to \(targetLanguage)") {
                                run(.translate)
                            }
                        } label: {
                            Label("Translate", systemImage: "globe")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isLoading)

                        Button {
                            run(.summarize)
                        } label: {
                            Label("Summarize", systemImage: "text.alignleft")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading)
                    }

                    HStack {
                        //Button {
                            //let sampleURL = URL(string: episode.sourceURL) ?? URL(string: "https://example.com/audio.mp3")!
                            //let download = DownloadedEpisode(episode: episode, audioURL: sampleURL)
                            //playerController.play(download)
                            //showPlayer = true
                        //}  label: {
                            //Label("Download", systemImage: "arrow.down.circle")
                        //}
                        //.buttonStyle(.bordered)

                        //Spacer()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Creating your \(selectedAction == .translate ? "translation" : "summary")…")
                    }
                    .padding()
                }

                if let generatedText, let selectedAction {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            selectedAction == .translate
                                ? "Translation to \(targetLanguage)"
                                : "Summary",
                            systemImage: selectedAction == .translate ? "globe" : "text.alignleft"
                        )
                        .font(.headline)

                        Text(generatedText)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.background, in: RoundedRectangle(cornerRadius: 18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(.quaternary, lineWidth: 1)
                    }
                }

                if let errorMessage {
                    ContentUnavailableView(
                        "AI request unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Episode")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPlayer) {
            NowPlayingView(player: playerController)
        }
    }

    private func run(_ action: AIAction) {
        selectedAction = action
        generatedText = nil
        errorMessage = nil
        isLoading = true

        Task {
            do {
                let prompt = action == .summarize
                    ? "Summarize this episode."
                    : "Translate this episode to \(targetLanguage)."
                let response = try await service.respond(
                    action: action,
                    query: prompt,
                    messages: [ChatMessage(role: .user, text: prompt)],
                    episode: episode,
                    targetLanguage: action == .translate ? targetLanguage : nil
                )
                await MainActor.run {
                    generatedText = response
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

private struct EpisodeHeaderCard: View {
    let episode: PodcastEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AsyncImage(url: URL(string: episode.artworkURL)) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "waveform")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 18))

            Text(episode.title)
                .font(.title2.bold())

            Text(episode.description)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text(episode.language.uppercased())
                Text(episode.durationText)
                if let publishedDate = episode.publishedDate {
                    Text(publishedDate)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
