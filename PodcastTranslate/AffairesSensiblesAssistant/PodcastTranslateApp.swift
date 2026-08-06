//
//  AffairesSensibles.swift
//  PodcastTranslate
//
//  Created by Sety Tekeu on 7/24/26.
//

import SwiftUI

@main
struct AffairesSensibles: App {
    init() {
        NotificationManager.configure()
        NotificationManager.requestAuthorizationIfEnabledSetting()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

