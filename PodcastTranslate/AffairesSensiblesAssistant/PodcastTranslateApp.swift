//
//  AffairesSensibles.swift
//  PodcastTranslate
//
//  Created by Sety Tekeu on 7/24/26.
//

import SwiftUI
import FoundationModels

@main
struct AffairesSensibles: App {
    init() {
        NotificationManager.configure()
        NotificationManager.requestAuthorizationIfEnabledSetting()
    }
    
    @StateObject private var aiAvailability = AIAvailability()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(aiAvailability)
        }
    }
}

