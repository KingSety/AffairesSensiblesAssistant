//
//  ContentView.swift
//  PodcastTranslate
//
//  Created by Sety Tekeu on 7/24/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var player = AudioPlayerController()
    @State private var isShowingNowPlaying = false

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }

            DownloadsView(player: player)
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AudioPlayerView(player: player) {
                isShowingNowPlaying = true
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
        .fullScreenCover(isPresented: $isShowingNowPlaying) {
            NowPlayingView(player: player)
        }
    }
}

#Preview {
    ContentView()
}
