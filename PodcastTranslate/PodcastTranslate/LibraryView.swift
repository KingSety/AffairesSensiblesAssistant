//
//  LibraryView.swift
//  PodcastTranslate
//
//  Created by Sety Tekeu on 7/25/26.
//

import Foundation
import SwiftUI

struct LibraryView: View {
    @State private var episodes: [PodcastEpisode] = []
    @State private var catalogError: String?
    @State private var searchTerm: String = ""
    
    fileprivate var filteredEpisodes: [PodcastEpisode] {
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return episodes }
        let lower = term.lowercased()
        return episodes.filter { episode in
            episode.title.lowercased().contains(lower) ||
            episode.description.lowercased().contains(lower) ||
            episode.language.lowercased().contains(lower)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if episodes.isEmpty {
                    ContentUnavailableView(
                        "No Episodes Yet",
                        systemImage: "books.vertical",
                        description: Text(
                            catalogError ?? "Import a podcast catalog to fill your library."
                        )
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(filteredEpisodes) { episode in
                                NavigationLink {
                                    EpisodeDetailView(episode: episode)
                                } label: {
                                    EpisodeRow(episode: episode)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Library")
            .searchable(text: $searchTerm, placement: .navigationBarDrawer, prompt: "Search Episodes")
            .toolbar {
                if !episodes.isEmpty {
                    let count = filteredEpisodes.count
                    let total = episodes.count
                    Text(count == total ? "\(total) episodes" : "\(count) of \(total) episodes")
                        .foregroundStyle(.secondary)
                }
            }
            
        }
        
        .task {
            loadEpisodes()
        }
    }

    private func loadEpisodes() {
        do {
            episodes = try EpisodeCatalog.load()
            catalogError = nil
        } catch {
            catalogError = error.localizedDescription
        }
    }
}

private struct EpisodeRow: View {
    let episode: PodcastEpisode

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: URL(string: episode.artworkURL)) { image in
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
                Text(episode.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(episode.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(episode.language.uppercased())
                    Text(episode.durationText)
                    if let publishedDate = episode.publishedDate {
                        Text(publishedDate)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
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

#Preview {
    LibraryView()
}
