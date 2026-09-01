import Foundation
import SwiftUI

/// What the app is doing right now. The menu bar icon and the popover both read from this.
enum Phase: Equatable {
    case starting
    case settingUp(detail: String, fraction: Double?)
    case ready
    case recording(seconds: TimeInterval)
    case transcribing
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .starting, .settingUp: return true
        default: return false
        }
    }
}

struct Dictation: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let spoken: TimeInterval
    let latency: TimeInterval
    let injected: Bool
}

/// Theme preference. `auto` follows the system.
enum ThemeChoice: String, CaseIterable {
    case auto, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .auto:  return nil
        case .light: return .light
        case .dark:  return .dark
        }
    }
    var symbol: String {
        switch self {
        case .auto:  return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark:  return "moon"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var phase: Phase = .starting
    @Published var recent: [Dictation] = []
    @Published var theme: ThemeChoice = .auto {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
    }

    /// Set while the models are still loading and the user has already spoken.
    /// The dictation is queued rather than dropped.
    @Published var queuedWhileLoading = false

    init() {
        if let raw = UserDefaults.standard.string(forKey: "theme"),
           let stored = ThemeChoice(rawValue: raw) {
            theme = stored
        }
    }

    func record(_ dictation: Dictation) {
        recent.insert(dictation, at: 0)
        if recent.count > 3 { recent.removeLast() }
    }
}
