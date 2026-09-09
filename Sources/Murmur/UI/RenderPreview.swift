#if DEBUG_RENDER
#endif
import AppKit
import SwiftUI

/// Renders the popover offscreen to a PNG. Used to verify the interface without
/// needing Screen Recording permission to photograph the real window.
@MainActor
enum RenderPreview {

    static func run(outputDirectory: String) {
        Fonts.register()

        let cases: [(String, Phase, [Dictation])] = [
            ("setup", .settingUp(detail: "Compiling parakeet_encoder for the Neural Engine",
                                 fraction: 0.62), []),
            ("ready", .ready, []),
            ("active", .recording(seconds: 2.4), [
                Dictation(text: "Can you push that fix to staging and let me know when it's live.",
                          spoken: 3.24, latency: 0.176, injected: true)
            ])
        ]

        let allCases = cases + [
            ("permissions", .permissions(accessibility: false, microphone: true), []),
            ("settings", .ready, []),
            ("update", .ready, []),
            ("meeting", .ready, [
                Dictation(text: "Move the retro to Thursday and invite the platform team.",
                          spoken: 4.1, latency: 0.19, injected: true)
            ]),
        ]
        // README shots are taken from the bundled app so the version reads
        // as a real one; the bare binary says "dev".
        let setupCases: [(String, Phase)] = [
            ("permissions", .permissions(accessibility: false, microphone: false)),
            ("download", .settingUp(detail: "Downloading speech model — 3 of 7 files", fraction: 0.41)),
            ("ready", .ready),
        ]
        for scheme in [ThemeChoice.light, ThemeChoice.dark] {
            for (name, phase) in setupCases {
                let state = AppState()
                state.theme = scheme
                state.phase = phase
                let view = SetupView(state: state, onDone: {})
                    .environment(\.colorScheme, scheme == .dark ? .dark : .light)
                    .background(scheme == .dark
                                ? Color(red: 0.05, green: 0.04, blue: 0.09)
                                : Color(red: 0.96, green: 0.96, blue: 0.98))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    let path = "\(outputDirectory)/setup-\(scheme.rawValue)-\(name).png"
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("wrote \(path)  \(Int(image.size.width))x\(Int(image.size.height))pt")
                }
            }
        }
        for scheme in [ThemeChoice.light, ThemeChoice.dark] {
            for (name, phase, recent) in allCases {
                let state = AppState()
                state.theme = scheme
                state.phase = phase
                state.transcriptFolder = AppState.defaultTranscriptFolder
                if name == "settings" { state.page = .settings; state.checkForUpdates = true }
                state.hotKey = .default   // the bare binary's defaults persist between runs
                // Vary the settings across cases so every control state is drawn.
                if name == "active" { state.previewLaunchAtLogin(true) }
                if name == "ready" { state.hotKey = .leftOption; state.meetingKey = .rightOption }
                if name == "ready" {
                    state.checkForUpdates = true
                    state.updateStatus = .checked(Date().addingTimeInterval(-7200))
                }
                if name == "update" {
                    state.checkForUpdates = true
                    state.updateStatus = .checked(Date().addingTimeInterval(-7200))
                    state.availableUpdate = UpdateInfo(
                        version: "0.9.0",
                        url: URL(string: "https://github.com/justynroberts/murmur/releases/latest")!,
                        downloadURL: nil, downloadSize: nil)
                }
                if name == "meeting" {
                    state.meeting = MeetingRecorder.Session(
                        startedAt: Date().addingTimeInterval(-1523),
                        fileURL: state.transcriptFolder.appendingPathComponent("Meeting 2026-09-09 10.00.md"),
                        segments: 41, lastSavedAt: Date().addingTimeInterval(-3))
                }
                recent.forEach { state.record($0) }

                let view = PopoverView(state: state)
                    .environment(\.colorScheme, scheme == .dark ? .dark : .light)
                    .background(scheme == .dark
                                ? Color(red: 0.05, green: 0.04, blue: 0.09)
                                : Color(red: 0.96, green: 0.96, blue: 0.98))

                let renderer = ImageRenderer(content: view)
                renderer.scale = 2

                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    print("render failed: \(scheme.rawValue)/\(name)")
                    continue
                }
                let path = "\(outputDirectory)/popover-\(scheme.rawValue)-\(name).png"
                try? png.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)  \(Int(image.size.width))x\(Int(image.size.height))pt")
            }
        }
    }
}
