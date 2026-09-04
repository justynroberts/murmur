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

        for scheme in [ThemeChoice.light, ThemeChoice.dark] {
            for (name, phase, recent) in cases {
                let state = AppState()
                state.theme = scheme
                state.phase = phase
                // Vary the settings across cases so every control state is drawn.
                if name == "active" { state.hotKey = .rightCommand; state.previewLaunchAtLogin(true) }
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
