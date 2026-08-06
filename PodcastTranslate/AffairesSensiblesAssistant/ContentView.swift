//
//  ContentView.swift
//  PodcastTranslate
//
//  Created by Sety Tekeu on 7/24/26.
//

import SwiftUI

struct ContentView: View {
    private enum Tab { case home, library, settings }
    @State private var selectedTab: Tab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tag(Tab.home)
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            LibraryView()
                .tag(Tab.library)
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }

            SettingsView()
                .tag(Tab.settings)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .onChange(of: selectedTab) { newValue in
            switch newValue {
            case .home:
                NotificationManager.clearDeliveredForHomeAssistant()
            case .library:
                NotificationManager.clearDeliveredForEpisodeSummary()
            case .settings:
                break
            }
        }
        .onAppear {
            NotificationManager.clearDeliveredForHomeAssistant()
        }
    }
}

#Preview {
    ContentView()
}
