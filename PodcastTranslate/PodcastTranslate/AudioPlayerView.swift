import AVFoundation
import Combine
import SwiftUI

@MainActor
final class AudioPlayerController: ObservableObject {
    @Published private(set) var currentDownload: DownloadedEpisode?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    private var player: AVPlayer?
    private var timeObserver: Any?

    deinit {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
    }

    func play(_ download: DownloadedEpisode) {
        if currentDownload?.id == download.id {
            resume()
            return
        }

        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }

        currentDownload = download
        let player = AVPlayer(url: download.audioURL)
        self.player = player
        observeProgress(for: player)
        player.play()
        isPlaying = true
    }

    func togglePlayback() {
        isPlaying ? pause() : resume()
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
    }

    private func pause() {
        player?.pause()
        isPlaying = false
    }

    private func resume() {
        player?.play()
        isPlaying = true
    }

    private func observeProgress(for player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let playerDuration = player.currentItem?.duration.seconds ?? 0
            let elapsedTime = time.seconds.isFinite ? time.seconds : 0
            let totalDuration = playerDuration.isFinite ? playerDuration : 0

            Task { @MainActor [weak self] in
                self?.updateProgress(elapsedTime: elapsedTime, totalDuration: totalDuration)
            }
        }
    }

    private func updateProgress(elapsedTime: Double, totalDuration: Double) {
        currentTime = elapsedTime
        duration = totalDuration
        if duration > 0, currentTime >= duration {
            isPlaying = false
        }
    }
}

struct AudioPlayerView: View {
    @ObservedObject var player: AudioPlayerController
    let onExpand: () -> Void

    var body: some View {
        if let download = player.currentDownload {
            HStack(spacing: 12) {
                Button(action: onExpand) {
                    HStack(spacing: 12) {
                        AsyncImage(url: URL(string: download.episode.artworkURL)) { image in
                            image
                                .resizable()
                                .scaledToFill()
                        } placeholder: {
                            Color.secondary.opacity(0.2)
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading) {
                            Text(download.episode.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("Now playing")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            }
            .padding(10)
        }
    }
}

struct NowPlayingView: View {
    @ObservedObject var player: AudioPlayerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let download = player.currentDownload {
            VStack(spacing: 24) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.title3)
                    }

                    Spacer()

                    Text("NOW PLAYING")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Image(systemName: "ellipsis")
                        .font(.title3)
                }

                Spacer(minLength: 20)

                AsyncImage(url: URL(string: download.episode.artworkURL)) { image in
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
                .frame(maxWidth: 340)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(radius: 18, y: 10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(download.episode.title)
                        .font(.title3.bold())
                        .lineLimit(2)
                    Text(download.episode.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { player.currentTime },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0...max(player.duration, 1)
                    )

                    HStack {
                        Text(timeText(player.currentTime))
                        Spacer()
                        Text(timeText(player.duration))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 42) {
                    Image(systemName: "backward.fill")
                    Button {
                        player.togglePlayback()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                    }
                    Image(systemName: "forward.fill")
                }
                .font(.title2)

                Spacer()
            }
            .padding()
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite else {
            return "0:00"
        }
        let totalSeconds = Int(seconds)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}


#Preview("Audio Player") {
    let controller = AudioPlayerController()
    let sampleEpisode = PodcastEpisode(
        id: "ep1",
        title: "Sample Episode",
        description: "A brief description of a sample episode used for previews.",
        sourceURL: "https://example.com/audio.mp3",
        artworkURL: "https://picsum.photos/200",
        language: "en",
        publishedDate: "2026-07-27",
        durationSeconds: 300
    )
    let sampleDownload = DownloadedEpisode(
        episode: sampleEpisode,
        audioURL: URL(string: "https://example.com/audio.mp3")!
    )
    controller.play(sampleDownload)
    return VStack {
        AudioPlayerView(player: controller, onExpand: {})
        Divider()
        NowPlayingView(player: controller)
    }
}

