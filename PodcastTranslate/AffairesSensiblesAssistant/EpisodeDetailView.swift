import UserNotifications
import SwiftUI
import FoundationModels

struct EpisodeDetailView: View {
    let episode: PodcastEpisode

    @EnvironmentObject private var aiAvailability: AIAvailability

    @State private var generatedText: String?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var usedDescriptionFallback = false
    @State private var summaryKind: EpisodeSummaryOutputKind = .generatedSummary
    @State private var summaryNotice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                EpisodeHeaderCard(episode: episode)

                if episode.mediaUnavailable {
                    ContentUnavailableView(
                        "Episode unavailable",
                        systemImage: "waveform.slash",
                        description: Text(
                            episode.availabilityMessage.isEmpty
                                ? "This episode is no longer available from Radio France, so a transcript could not be created."
                                : episode.availabilityMessage
                        )
                    )
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Episode Tools")
                        .font(.headline)

                    Button {
                        generate()
                    } label: {
                        if episode.transcriptAvailable {
                            Label("Summarize", systemImage: "text.alignleft")
                        } else {
                            Label("Short Description", systemImage: "text.alignleft")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isGenerating || aiAvailability.shouldDisableAI)
                    .opacity(aiAvailability.shouldDisableAI ? 0.5 : 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                if aiAvailability.shouldDisableAI {
                    Text(aiAvailability.reasonText() ?? "Apple Intelligence features are disabled.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if isGenerating {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Using the on-device model…")
                    }
                    .padding()
                }

                if let generatedText {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(summaryKind.title, systemImage: "text.alignleft")
                            .font(.headline)

                        Text(generatedText)
                            .textSelection(.enabled)

                        if let summaryNotice {
                            Text(summaryNotice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !episode.transcriptAvailable && usedDescriptionFallback && summaryNotice == nil {
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
        summaryKind = .generatedSummary
        summaryNotice = nil
        isGenerating = true

        Task {
            do {
                let input = try await LocalTranscriptService.generationInput(for: episode)
                usedDescriptionFallback = input.source == .description
                let result = try await OnDeviceLanguageService.generate(input: input)
                generatedText = result.text
                summaryKind = result.kind
                summaryNotice = result.notice
                NotificationManager.notifyEpisodeSummaryReady(episodeTitle: episode.title)
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
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    Image(systemName: statusIcon)
                        .imageScale(.small)
                        .foregroundStyle(statusColor)
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)

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

    private var statusIcon: String {
        if episode.mediaUnavailable { return "exclamationmark.triangle.fill" }
        return episode.transcriptAvailable ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var statusText: String {
        if episode.mediaUnavailable { return "Episode Unavailable" }
        return episode.transcriptAvailable ? "Transcript Available" : "Transcript Not Available"
    }

    private var statusColor: Color {
        if episode.mediaUnavailable { return .orange }
        return episode.transcriptAvailable ? .green : .secondary
    }
}
