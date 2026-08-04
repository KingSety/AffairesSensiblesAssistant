import SwiftUI

struct EpisodeDetailView: View {
    let episode: PodcastEpisode

    @State private var generatedText: String?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var usedDescriptionFallback = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                EpisodeHeaderCard(episode: episode)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Episode Tools")
                        .font(.headline)

                    Button {
                        generate()
                    } label: {
                        Label("Summarize", systemImage: "text.alignleft")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isGenerating)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                if isGenerating {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Using the on-device model…")
                    }
                    .padding()
                }

                if let generatedText {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Summary", systemImage: "text.alignleft")
                            .font(.headline)

                        Text(generatedText)
                            .textSelection(.enabled)

                        if usedDescriptionFallback {
                            Text("Based on the imported episode description. Add a Deepgram transcript for a full content summary.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                        "On-device request unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Episode")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func generate() {
        guard !isGenerating else { return }

        generatedText = nil
        errorMessage = nil
        usedDescriptionFallback = false
        isGenerating = true

        Task {
            do {
                let input = try await LocalTranscriptService.generationInput(for: episode)
                usedDescriptionFallback = input.source == .description
                generatedText = try await OnDeviceLanguageService.generate(input: input)
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
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
