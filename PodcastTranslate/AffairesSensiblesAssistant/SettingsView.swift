//
//  SettingsView.swift
//  PodcastTranslate
//
//  Created by Sety Tekeu on 7/25/26.
//

import SwiftUI
import UserNotifications
import FoundationModels

struct SettingsView: View {
    @EnvironmentObject private var aiAvailability: AIAvailability
    
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
                Section("Notifications") {
                    Toggle("Enable Notifications", isOn: $notificationsEnabled)
                        .onChange(of: notificationsEnabled) { enabled in
                            NotificationManager.handleSettingChange(enabled: enabled)
                        }
                        .onAppear {
                            // Keep the toggle state in sync with system permission changes
                            UNUserNotificationCenter.current().getNotificationSettings { settings in
                                DispatchQueue.main.async {
                                    if settings.authorizationStatus == .denied {
                                        notificationsEnabled = false
                                    }
                                }
                            }
                        }
                }
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
        .preferredColorScheme(isDarkMode ? .dark : .light)
    }
    
    private var aiPreferenceSection: some View {
        Section("AI Preferences") {
            Picker("Response Length", selection: $responseLength) {
                ForEach(responseLengths, id: \.self) { length in
                    Text(length).tag(length)
                }
            }
            Toggle("Include Sources/Timestamps", isOn: $includeSourcesAndTimestamps)
            if aiAvailability.shouldDisableAI {
                Text(aiAvailability.reasonText() ?? "Apple Intelligence features are disabled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(aiAvailability.shouldDisableAI)
        .opacity(aiAvailability.shouldDisableAI ? 0.5 : 1)
    }
    
}
#Preview {
    SettingsView()
}
