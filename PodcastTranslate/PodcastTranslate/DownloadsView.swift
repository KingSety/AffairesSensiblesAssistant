import SwiftUI

struct DownloadsView: View {
    @ObservedObject var player: AudioPlayerController

    @State private var downloads: [DownloadedEpisode] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if downloads.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text(
                            errorMessage ?? "Downloaded episodes will appear here for offline listening."
                        )
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(downloads) { download in
                                DownloadedEpisodeCard(download: download) {
                                    player.play(download)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                if !downloads.isEmpty {
                    Text("\(downloads.count)")
                        .foregroundStyle(.secondary)
                }
            }
            .task {
                loadDownloads()
            }
            .refreshable {
                loadDownloads()
            }
        }
    }

    private func loadDownloads() {
        do {
            downloads = try DownloadLibrary.load()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DownloadedEpisodeCard: View {
    let download: DownloadedEpisode
    let onPlay: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: URL(string: download.episode.artworkURL)) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 112, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                Text(download.episode.title)
                    .font(.headline)
                    .lineLimit(2)

                Text(download.episode.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(download.episode.language.uppercased())
                    Text(download.episode.durationText)
                    if let publishedDate = download.episode.publishedDate {
                        Text(publishedDate)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.title)
            }
            .accessibilityLabel("Play \(download.episode.title)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}
