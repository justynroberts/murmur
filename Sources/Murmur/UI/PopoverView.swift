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

private struct MiddleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PopoverView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var systemScheme
    @State private var showAbout = false

    private var scheme: ColorScheme { state.theme.colorScheme ?? systemScheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if middleHeight > maxMiddleHeight {
                ScrollView(.vertical, showsIndicators: false) { middle }
                    .frame(height: maxMiddleHeight)
            } else {
                middle
            }
            footer
        }
        .padding(16)
        .frame(width: 340, alignment: .top)
        .background(Tokens.raised(scheme).opacity(scheme == .dark ? 0.5 : 0.6))
        .preferredColorScheme(state.theme.colorScheme)
        .onPreferenceChange(MiddleHeightKey.self) { middleHeight = $0 }
        .sheet(isPresented: $showAbout) { aboutPanel }
    }

    /// The middle scrolls only when it would not fit the screen; header and
    /// footer never leave it. Laid out plain until measured, so nothing is
    /// ever clipped by a stale size.
    private var middle: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusCard
            if let meeting = state.meeting { meetingCard(meeting) }
            if let update = state.availableUpdate { updateCard(update) }
            if !state.recent.isEmpty { recentList }
        }
        .background(GeometryReader { geo in
            Color.clear.preference(key: MiddleHeightKey.self, value: geo.size.height)
        })
    }

    @State private var middleHeight: CGFloat = 0
    /// Screen height minus menu bar, header, footer and paddings.
    private var maxMiddleHeight: CGFloat {
        let screen = (NSScreen.main?.visibleFrame.height ?? 800)
        return max(160, screen - 24 - 60 - 40 - 32)
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

            // Day-to-day first: transcripts and the word list are the two
            // things people open most. Settings is one tap away, not in the way.
            iconButton("folder", label: "Open transcripts") { state.openTranscripts() }
            iconButton("character.book.closed", label: "Edit word list") { openDictionary() }
            iconButton("gearshape", label: "Settings") { state.requestSettingsWindow?() }
            iconButton("info", label: "About this app") { showAbout = true }
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch state.phase {
            case .starting:
                label("Starting…", Tokens.text2(scheme))

            case .permissions(let accessibility, let microphone):
                HStack(spacing: 7) {
                    Circle().fill(Tokens.accent(scheme)).frame(width: 7, height: 7)
                    label("Two permissions to grant", Tokens.text(scheme), weight: .semibold)
                }
                permissionRow(
                    granted: accessibility, name: "Accessibility",
                    why: "Lets Murmur watch for the key and type into other apps.",
                    pane: "Privacy_Accessibility")
                permissionRow(
                    granted: microphone, name: "Microphone",
                    why: "So it can hear you. Audio never leaves this Mac.",
                    pane: "Privacy_Microphone")
                label("Murmur carries on by itself once both are on. No relaunch needed.",
                      Tokens.text3(scheme), size: 10)
                Button("Open the setup window") { state.requestSetupWindow?() }
                    .buttonStyle(.plain)
                    .font(Fonts.display(10.5, .medium))
                    .foregroundStyle(Tokens.accent(scheme))
                    .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }

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
                    keycap(state.hotKey.symbol)
                    label("Hold \(state.hotKey.name), speak, release.", Tokens.text2(scheme), size: 11)
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

    private func permissionRow(granted: Bool, name: String, why: String, pane: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(granted ? Color.green : Tokens.text3(scheme))
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                label(name, Tokens.text(scheme), size: 12, weight: .semibold)
                label(why, Tokens.text3(scheme), size: 10.5)
            }
            Spacer(minLength: 6)
            if !granted {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .font(Fonts.display(10.5, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Tokens.gradient))
                .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
            }
        }
        .padding(.vertical, 2)
    }

    /// Changing this forces the blur-in transition when the state changes kind,
    /// but not on every tick of the recording timer.
    private var phaseKey: String {
        switch state.phase {
        case .starting: return "starting"
        case .permissions(let a, let m): return "permissions-\(a)-\(m)"
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

    // MARK: - Settings

    // MARK: - Update available

    private func updateCard(_ update: UpdateInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Tokens.gradient)
            VStack(alignment: .leading, spacing: 1) {
                label("Murmur \(update.version) is available", Tokens.text(scheme), size: 12, weight: .semibold)
                if case .failed(let why)? = state.updateStep {
                    label(why, Tokens.coral, size: 10)
                } else {
                    label("You have \(Bundle.main.appVersion). Downloads, verifies the signature, installs and relaunches.",
                          Tokens.text3(scheme), size: 10)
                }
            }
            Spacer(minLength: 6)
            if let step = state.updateStep, step != .failed("") , !isFailure(step) {
                Text(stepText(step))
                    .font(Fonts.mono(10))
                    .foregroundStyle(Tokens.accent(scheme))
            } else {
                Button("Update") { state.installUpdate() }
                    .buttonStyle(.plain)
                    .font(Fonts.display(11, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Tokens.gradient))
                    .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: Tokens.rPanel, style: .continuous)
                .fill(Tokens.raised(scheme).opacity(scheme == .dark ? 0.7 : 1))
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.rPanel, style: .continuous)
                        .strokeBorder(Tokens.gradient, lineWidth: 1)
                )
        )
        .transition(.blurIn)
    }

    // MARK: - Meeting

    private func meetingCard(_ meeting: MeetingRecorder.Session) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(Tokens.coral).frame(width: 7, height: 7)
                label("Meeting mode", Tokens.text(scheme), weight: .semibold)
                Spacer()
                TimelineView(.periodic(from: meeting.startedAt, by: 1)) { context in
                    Text(elapsed(since: meeting.startedAt, now: context.date))
                        .font(Fonts.mono(11))
                        .foregroundStyle(Tokens.coral)
                }
            }
            label(meetingSavedLine(meeting), Tokens.text3(scheme), size: 10.5)
            HStack(spacing: 10) {
                Button("Open transcript") { NSWorkspace.shared.open(meeting.fileURL) }
                    .buttonStyle(.plain)
                    .font(Fonts.display(11, .medium))
                    .foregroundStyle(Tokens.accent(scheme))
                    .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
                Spacer()
                Button("Stop") { state.requestMeetingStop?() }
                    .buttonStyle(.plain)
                    .font(Fonts.display(11, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Tokens.coral))
                    .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: Tokens.rPanel, style: .continuous)
                .fill(Tokens.raised(scheme).opacity(scheme == .dark ? 0.7 : 1))
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.rPanel, style: .continuous)
                        .strokeBorder(Tokens.coral.opacity(0.6))
                )
        )
        .transition(.blurIn)
    }

    private func isFailure(_ step: UpdateInstaller.Step) -> Bool {
        if case .failed = step { return true }
        return false
    }

    private func stepText(_ step: UpdateInstaller.Step) -> String {
        switch step {
        case .downloading(let f): return f.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading…"
        case .verifying:          return "Verifying…"
        case .installing:         return "Installing…"
        case .relaunching:        return "Relaunching…"
        case .failed:             return ""
        }
    }

    private func elapsed(since start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func meetingSavedLine(_ m: MeetingRecorder.Session) -> String {
        let name = m.fileURL.lastPathComponent
        guard let saved = m.lastSavedAt else { return "Listening · \(name)" }
        let ago = Int(Date().timeIntervalSince(saved))
        let when = ago < 5 ? "just now" : "\(ago)s ago"
        return "\(m.segments) segment\(m.segments == 1 ? "" : "s") saved, last \(when) · \(name)"
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            if state.meeting == nil {
                Button {
                    state.requestMeetingStart?()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "record.circle").font(.system(size: 10, weight: .semibold))
                        Text("Start meeting")
                    }
                    .font(Fonts.display(11, .medium))
                    .foregroundStyle(Tokens.coral)
                }
                .buttonStyle(.plain)
                .help("Tap \(state.meetingKey.name) does the same")
                .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
            } else {
                Text("Runs entirely on this Mac")
                    .font(Fonts.mono(9.5))
                    .foregroundStyle(Tokens.text3(scheme))
            }
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

            // Update checks are opt-in; by default new versions are found by the
            // user, in the browser, and the app makes no network request at all.
            HStack(spacing: 14) {
                linkButton("Website", "https://justynroberts.github.io/murmur/")
                linkButton("Releases", "https://github.com/justynroberts/murmur/releases")
            }
            Text("Murmur only checks for updates if you switch that on in Settings, and only downloads one when you press Update.")
                .font(Fonts.display(10))
                .foregroundStyle(Tokens.text3(scheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

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

    /// Opens the substitution list in whatever the user edits JSON with.
    /// Touching the file is enough — it is re-read on the next dictation.
    private func openDictionary() {
        let url = UserDictionary.defaultFileURL
        _ = UserDictionary.shared.count          // ensures the seed file exists
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func linkButton(_ title: String, _ urlString: String) -> some View {
        Button {
            if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
            }
            .font(Fonts.display(11.5, .medium))
            .foregroundStyle(Tokens.accent(scheme))
        }
        .buttonStyle(.plain)
        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
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
        // Only reached when running the bare binary (render-ui), which has no
        // Info.plist. A placeholder is clearer here than a version that will rot.
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
