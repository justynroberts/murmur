import SwiftUI

/// MIT License - Copyright (c) fintonlabs.com

/// The signature gesture: content resolves out of a blur, the way speech
/// resolves into text. Used on every state change. See DESIGN.md.
private struct Blur: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(radius > 0 ? 0 : 1)
    }
}

extension AnyTransition {
    static var blurIn: AnyTransition {
        .modifier(active: Blur(radius: 8), identity: Blur(radius: 0))
    }
}

struct PopoverView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var systemScheme
    @State private var showAbout = false

    private var scheme: ColorScheme { state.theme.colorScheme ?? systemScheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusCard
            if !state.recent.isEmpty { recentList }
            footer
        }
        .padding(16)
        .frame(width: 340)
        .background(Tokens.raised(scheme).opacity(scheme == .dark ? 0.5 : 0.6))
        .preferredColorScheme(state.theme.colorScheme)
        .sheet(isPresented: $showAbout) { aboutPanel }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Tokens.gradient)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                )
                .shadow(color: Tokens.iris.opacity(0.35), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: -1) {
                Text("Murmur")
                    .font(Fonts.display(16, .semibold))
                    .foregroundStyle(Tokens.text(scheme))
                Text("v\(Bundle.main.appVersion)")
                    .font(Fonts.mono(9))
                    .foregroundStyle(Tokens.text3(scheme))
            }

            Spacer()

            iconButton(state.theme.symbol, label: "Switch theme") {
                let all = ThemeChoice.allCases
                let idx = all.firstIndex(of: state.theme) ?? 0
                withAnimation(.easeOut(duration: 0.22)) {
                    state.theme = all[(idx + 1) % all.count]
                }
            }
            iconButton("info", label: "About this app") { showAbout = true }
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch state.phase {
            case .starting:
                label("Starting…", Tokens.text2(scheme))

            case .settingUp(let detail, let fraction):
                HStack(spacing: 7) {
                    Circle().fill(Tokens.accent(scheme)).frame(width: 7, height: 7)
                    label("Setting up", Tokens.text(scheme), weight: .semibold)
                    Spacer()
                    if let fraction {
                        Text("\(Int(fraction * 100))%")
                            .font(Fonts.mono(11))
                            .foregroundStyle(Tokens.text3(scheme))
                    }
                }
                progressBar(fraction)
                label(detail, Tokens.text3(scheme), size: 11)
                label("One-off. Transcription is instant afterwards.",
                      Tokens.text3(scheme), size: 10)

            case .ready:
                HStack(spacing: 7) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    label("Ready", Tokens.text(scheme), weight: .semibold)
                }
                HStack(spacing: 5) {
                    keycap("⌥")
                    label("Hold Right Option, speak, release.", Tokens.text2(scheme), size: 11)
                }

            case .recording(let seconds):
                HStack(spacing: 7) {
                    Circle().fill(Tokens.coral).frame(width: 7, height: 7)
                    label("Recording", Tokens.text(scheme), weight: .semibold)
                    Spacer()
                    Text(String(format: "%.1fs", seconds))
                        .font(Fonts.mono(11))
                        .foregroundStyle(Tokens.coral)
                }
                label("Release to insert.", Tokens.text3(scheme), size: 11)

            case .transcribing:
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    label("Transcribing…", Tokens.text(scheme), weight: .semibold)
                }

            case .failed(let message):
                label("Problem", Tokens.coral, weight: .semibold)
                label(message, Tokens.text2(scheme), size: 11)
            }

            if state.queuedWhileLoading {
                label("Your dictation is queued and will run as soon as setup finishes.",
                      Tokens.accent(scheme), size: 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: Tokens.rPanel, style: .continuous)
                .fill(Tokens.raised(scheme).opacity(scheme == .dark ? 0.7 : 1))
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.rPanel, style: .continuous)
                        .strokeBorder(Tokens.border(scheme))
                )
        )
        .transition(.blurIn)
        .id(phaseKey)
        .animation(.easeOut(duration: 0.32), value: phaseKey)
    }

    /// Changing this forces the blur-in transition when the state changes kind,
    /// but not on every tick of the recording timer.
    private var phaseKey: String {
        switch state.phase {
        case .starting: return "starting"
        case .settingUp: return "setup"
        case .ready: return "ready"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .failed: return "failed"
        }
    }

    private func progressBar(_ fraction: Double?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.border(scheme))
                Capsule()
                    .fill(Tokens.gradient)
                    .frame(width: max(6, geo.size.width * (fraction ?? 0.12)))
                    .animation(.easeOut(duration: 0.4), value: fraction)
            }
        }
        .frame(height: 5)
    }

    // MARK: - Recent

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RECENT")
                .font(Fonts.mono(9))
                .tracking(0.8)
                .foregroundStyle(Tokens.text3(scheme))

            ForEach(state.recent) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.text)
                        .font(Fonts.display(11.5))
                        .foregroundStyle(Tokens.text2(scheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(String(format: "%.2fs speech → %.3fs", item.spoken, item.latency))
                            .font(Fonts.mono(9))
                            .foregroundStyle(Tokens.text3(scheme))
                        if !item.injected {
                            Text("not inserted")
                                .font(Fonts.mono(9))
                                .foregroundStyle(Tokens.coral)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Tokens.raised(scheme).opacity(scheme == .dark ? 0.55 : 0.8))
                )
                .transition(.blurIn)
            }
        }
        .animation(.easeOut(duration: 0.32), value: state.recent)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("Runs entirely on this Mac")
                .font(Fonts.mono(9.5))
                .foregroundStyle(Tokens.text3(scheme))
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(Fonts.display(11, .medium))
                .foregroundStyle(Tokens.text3(scheme))
                .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
        }
    }

    // MARK: - About (the FintonLabs credit, reachable from the only screen there is)

    private var aboutPanel: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Tokens.gradient)
                .frame(width: 46, height: 46)
                .overlay(Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white))

            Text("Murmur").font(Fonts.display(17, .semibold))
                .foregroundStyle(Tokens.text(scheme))
            Text("Version \(Bundle.main.appVersion)")
                .font(Fonts.mono(10))
                .foregroundStyle(Tokens.text3(scheme))

            (Text("Made by ").foregroundColor(Tokens.text2(scheme))
             + Text("FintonLabs").foregroundColor(Tokens.accent(scheme)))
                .font(Fonts.display(12))
                .onTapGesture {
                    if let url = URL(string: "https://fintonlabs.com") {
                        NSWorkspace.shared.open(url)
                    }
                }

            Button("Close") { showAbout = false }
                .buttonStyle(.plain)
                .font(Fonts.display(11.5, .medium))
                .foregroundStyle(Tokens.text2(scheme))
                .padding(.horizontal, 18).padding(.vertical, 6)
                .background(Capsule().fill(Tokens.raised(scheme)))
                .overlay(Capsule().strokeBorder(Tokens.border(scheme)))
                .keyboardShortcut(.cancelAction)
        }
        .padding(26)
        .frame(width: 260)
        .background(Tokens.raised(scheme).opacity(scheme == .dark ? 0.6 : 1))
        .preferredColorScheme(state.theme.colorScheme)
    }

    // MARK: - Small pieces

    private func label(_ text: String, _ colour: Color,
                       size: CGFloat = 12.5, weight: Font.Weight = .regular) -> some View {
        Text(text)
            .font(Fonts.display(size, weight))
            .foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(Fonts.mono(10))
            .foregroundStyle(Tokens.text(scheme))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Tokens.raised(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Tokens.border(scheme)))
    }

    private func iconButton(_ symbol: String, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Tokens.text3(scheme))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Tokens.raised(scheme)))
                .overlay(Circle().strokeBorder(Tokens.border(scheme)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
    }
}

extension Bundle {
    var appVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }
}
