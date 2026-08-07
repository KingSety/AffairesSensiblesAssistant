import Foundation
import FoundationModels
import Combine
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class AIAvailability: ObservableObject {
    @Published private(set) var availability: SystemLanguageModel.Availability = .available
    @Published private(set) var userRefused: Bool

    private let refusedKey = "aiRefusedByUser"

    init() {
        self.userRefused = UserDefaults.standard.bool(forKey: refusedKey)
        refresh()
    }

    var isAvailable: Bool {
        switch availability {
        case .available: return true
        case .unavailable: return false
        }
    }

    var shouldDisableAI: Bool {
        userRefused || !isAvailable
    }

    func refresh() {
        // Avoid querying the model in previews
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            availability = .available
            return
        }
        let model = SystemLanguageModel.default
        availability = model.availability
    }

    func markRefused() {
        userRefused = true
        UserDefaults.standard.set(true, forKey: refusedKey)
    }

    func clearRefusal() {
        userRefused = false
        UserDefaults.standard.removeObject(forKey: refusedKey)
    }

    func reasonText() -> String? {
        switch availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This device is not eligible for Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is disabled in system settings."
            case .modelNotReady:
                return "The model is downloading or preparing."
            @unknown default:
                return "An unknown system condition prevented the model from loading."
            }
        }
    }

    func openSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}
