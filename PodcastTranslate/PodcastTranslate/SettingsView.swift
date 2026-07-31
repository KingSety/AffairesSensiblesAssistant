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
    @State private var pendingStorageAction: StorageAction?
    @State private var storageError: String?

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                preferenceSection
                aiPreferenceSection
                storageSection
            }
            .navigationTitle("Settings")
            .task {
                refreshStorageUsage()
            }
            .confirmationDialog(
                pendingStorageAction?.title ?? "",
                isPresented: Binding(
                    get: { pendingStorageAction != nil },
                    set: { if !$0 { pendingStorageAction = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let action = pendingStorageAction {
                    Button(action.title, role: .destructive) {
                        clear(action)
                        pendingStorageAction = nil
                    }
                }
            } message: {
                Text(pendingStorageAction?.message ?? "")
            }
            .alert(
                "Storage action failed",
                isPresented: Binding(
                    get: { storageError != nil },
                    set: { if !$0 { storageError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(storageError ?? "")
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
            Toggle("Enable Notifications", isOn: $notificationsEnabled)
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

    private var storageSection: some View {
        Section("Storage") {
            StorageRow(
                title: "Transcript & Embedding Cache",
                detail: storageUsage.cacheText,
                actionTitle: "Clear Cache"
            ) {
                pendingStorageAction = .cache
            }

            Button("Clear Library Data", role: .destructive) {
                pendingStorageAction = .library
            }
        }
    }

    private func clear(_ action: StorageAction) {
        do {
            switch action {
            case .cache:
                try LibraryStorage.clearTranscriptAndEmbeddingCache()
            case .library:
                try LibraryStorage.clearLibraryData()
            }
            refreshStorageUsage()
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func refreshStorageUsage() {
        do {
            storageUsage = try LibraryStorage.usage()
        } catch {
            storageError = error.localizedDescription
        }
    }
}

private struct StorageRow: View {
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(actionTitle, action: action)
                .buttonStyle(.borderless)
        }
    }
}

private enum StorageAction: String, Identifiable {
    case cache
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cache:
            return "Clear Transcript & Embedding Cache"
        case .library:
            return "Clear Library Data"
        }
    }

    var message: String {
        switch self {
        case .cache:
            return "Stored transcripts and generated embeddings will be removed. They can be recreated later."
        case .library:
            return "Local transcripts, embeddings, and library state will be removed from this device."
        }
    }
}

#Preview {
    SettingsView()
}
