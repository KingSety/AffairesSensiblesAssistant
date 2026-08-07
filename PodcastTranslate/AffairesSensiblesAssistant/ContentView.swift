//
//  ContentView.swift
//  PodcastTranslate
//
//  Created by Sety Tekeu on 7/24/26.
//

import SwiftUI
import FoundationModels

struct ContentView: View {
    @EnvironmentObject private var aiAvailability: AIAvailability
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
        .alert("Apple Intelligence not available", isPresented: .constant(!aiAvailability.isAvailable && !aiAvailability.userRefused)) {
            let shouldShowOpenSettings: Bool = {
                if case .unavailable(let reason) = aiAvailability.availability {
                    return reason == .appleIntelligenceNotEnabled || reason == .modelNotReady
                }
                return false
            }()

            if shouldShowOpenSettings {
                Button("Open Settings") {
                    aiAvailability.clearRefusal()
                    aiAvailability.openSettings()
                }
            }

            Button("Not now", role: .cancel) {
                aiAvailability.markRefused()
            }
        } message: {
            Text(aiAvailability.reasonText() ?? "Apple Intelligence is currently unavailable.")
        }
        .task {
            aiAvailability.refresh()
        }
    }
}

#Preview {
    ContentView()
}
