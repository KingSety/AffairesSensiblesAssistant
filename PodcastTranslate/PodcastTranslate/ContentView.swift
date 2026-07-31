//
//  ContentView.swift
//  PodcastTranslate
//
//  Created by Sety Tekeu on 7/24/26.
//

import SwiftUI

struct ContentView: View {
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

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .task {
            try? await LocalSearchIndexPrewarmer.shared.prepare()
        }
    }
}

#Preview {
    ContentView()
}
