import Foundation
import ServiceManagement
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

    /// The modifier held to dictate. `DictationController` pushes changes into
    /// the live event tap, so switching takes effect immediately.
    @Published var hotKey: HotKey = .default {
        didSet { UserDefaults.standard.set(hotKey.rawValue, forKey: "hotKey") }
    }

    /// Mirrors `SMAppService.mainApp`. Setting it registers or unregisters the
    /// login item; if macOS refuses, the value is put back and `settingsNote`
    /// says why, so the switch never lies about what is enabled.
    @Published var launchAtLogin: Bool = false {
        didSet {
            guard !applyingLoginItem, launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                settingsNote = nil
            } catch {
                applyingLoginItem = true
                launchAtLogin = oldValue
                applyingLoginItem = false
                settingsNote = "Could not change the login item: \(error.localizedDescription)"
            }
        }
    }
    @Published var settingsNote: String?
    private var applyingLoginItem = false

    // MARK: Meeting mode — see MeetingRecorder.

    /// Tapped to start and stop meeting mode. Must differ from `hotKey`.
    @Published var meetingKey: HotKey = .rightControl {
        didSet { UserDefaults.standard.set(meetingKey.rawValue, forKey: "meetingKey") }
    }
    /// Where session transcripts go. Defaults to ~/Documents/Murmur.
    @Published var transcriptFolder: URL = AppState.defaultTranscriptFolder {
        didSet { UserDefaults.standard.set(transcriptFolder.path, forKey: "transcriptFolder") }
    }
    @Published var meeting: MeetingRecorder.Session?
    @Published var meetingNote: String?
    /// Set by `DictationController`; the popover's Stop button calls it.
    var requestMeetingStop: (() -> Void)?

    static var defaultTranscriptFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
    }

    // MARK: Updates — opt-in, off by default. See UpdateChecker.

    enum UpdateStatus: Equatable { case idle, checking, checked(Date), failed }

    @Published var checkForUpdates: Bool = false {
        didSet { UserDefaults.standard.set(checkForUpdates, forKey: "checkForUpdates") }
    }
    @Published var availableUpdate: UpdateInfo?
    @Published var updateStatus: UpdateStatus = .idle
    /// Set by `UpdateChecker`; the "Check now" button calls it.
    var requestUpdateCheck: (() -> Void)?

    /// Sets the switch without touching `SMAppService`. For previews only —
    /// the bare binary has no bundle to register.
    func previewLaunchAtLogin(_ on: Bool) {
        applyingLoginItem = true
        launchAtLogin = on
        applyingLoginItem = false
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: "theme"),
           let stored = ThemeChoice(rawValue: raw) {
            theme = stored
        }
        if let raw = UserDefaults.standard.string(forKey: "hotKey"),
           let stored = HotKey(rawValue: raw) {
            hotKey = stored
        }
        checkForUpdates = UserDefaults.standard.bool(forKey: "checkForUpdates")
        if let raw = UserDefaults.standard.string(forKey: "meetingKey"),
           let stored = HotKey(rawValue: raw), stored != hotKey {
            meetingKey = stored
        }
        if let path = UserDefaults.standard.string(forKey: "transcriptFolder") {
            transcriptFolder = URL(fileURLWithPath: path, isDirectory: true)
        }
        // Ask the system rather than trusting a stored flag: the user can remove
        // the login item in System Settings and the switch must show that.
        applyingLoginItem = true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        applyingLoginItem = false
    }

    func record(_ dictation: Dictation) {
        recent.insert(dictation, at: 0)
        if recent.count > 3 { recent.removeLast() }
    }
}
