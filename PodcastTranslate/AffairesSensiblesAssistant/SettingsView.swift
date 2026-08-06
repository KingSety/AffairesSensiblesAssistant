//
//  SettingsView.swift
//  PodcastTranslate
//
//  Created by Sety Tekeu on 7/25/26.
//

import SwiftUI

struct SettingsView: View {
    private let responseLengths = ["Short", "Medium", "Long"]
    
    @AppStorage("responseLength") private var responseLength = "Medium"
    @AppStorage("includeSourcesAndTimestamps") private var includeSourcesAndTimestamps = true
    @AppStorage("isDarkMode") private var isDarkMode = false
    @AppStorage("username") private var username = "Guest"
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @State private var storageUsage = LibraryStorageUsage(transcriptAndEmbeddingCache: 0)
 
    @State private var storageError: String?
    
    var body: some View {
        NavigationStack {
            Form {
                profileSection
                preferenceSection
                aiPreferenceSection

            }
        }
    }
    
    private var profileSection: some View {
        Section("Profile") {
            TextField("Username", text: $username)
        }
    }
    
    private var preferenceSection: some View {
        Section("Preferences") {
            Toggle("Dark Mode", isOn: $isDarkMode)
        }
    }
    
    private var aiPreferenceSection: some View {
        Section("AI Preferences") {
            Picker("Response Length", selection: $responseLength) {
                ForEach(responseLengths, id: \.self) { length in
                    Text(length).tag(length)
                }
            }
            Toggle("Include Sources/Timestamps", isOn: $includeSourcesAndTimestamps)
            
        }
    }
    
}
#Preview {
    SettingsView()
}
