import AppKit
import Combine
import SwiftUI

/// First-run setup in a real window, not the menu bar popover. A popover
/// hangs off the status item, and on a notched MacBook with a full menu bar
/// the item may have no window at all — the user then sees nothing while
/// permissions are refused and a 2.3GB download runs. This shows on launch
/// until setup has completed once, and never again unless a permission is
/// lost.
@MainActor
final class SetupWindowController {

    private let state: AppState
    private var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
        // Reaching ready is what completes setup, whether or not Done is
        // pressed; otherwise closing the window with the red button would
        // bring it back on every launch.
        state.$phase
            .sink { phase in if case .ready = phase { Self.hasCompletedSetup = true } }
            .store(in: &cancellables)
    }

    static var hasCompletedSetup: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedSetup") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedSetup") }
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SetupView(state: state, onDone: { [weak self] in self?.close() }))
        let w = NSWindow(contentViewController: host)
        w.title = "Set up Murmur"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 420, height: 420))
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close() {
        Self.hasCompletedSetup = true
        window?.close()
    }
}

struct SetupView: View {
    @ObservedObject var state: AppState
    var onDone: () -> Void
    @Environment(\.colorScheme) private var systemScheme
    private var scheme: ColorScheme { state.theme.colorScheme ?? systemScheme }

    private enum Step { case done, active, waiting }

    private var steps: (accessibility: Step, microphone: Step, model: Step) {
        switch state.phase {
        case .starting:
            return (.active, .waiting, .waiting)
        case .permissions(let a, let m):
            return (a ? .done : .active, m ? .done : (a ? .active : .waiting), .waiting)
        case .settingUp:
            return (.done, .done, .active)
        default:
            return (.done, .done, .done)
        }
    }

    private var isReady: Bool {
        if case .ready = state.phase { return true }
        if case .recording = state.phase { return true }
        if case .transcribing = state.phase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Tokens.gradient)
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "waveform").font(.system(size: 20, weight: .bold)).foregroundStyle(.white))
                    .shadow(color: Tokens.iris.opacity(0.35), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isReady ? "Murmur is ready" : "Setting up Murmur")
                        .font(Fonts.display(19, .semibold))
                        .foregroundStyle(Tokens.text(scheme))
                    Text(isReady ? "Everything runs on this Mac. Nothing is sent anywhere."
                                 : "Three things, once. Everything stays on this Mac.")
                        .font(Fonts.display(11.5))
                        .foregroundStyle(Tokens.text3(scheme))
                }
            }

            VStack(spacing: 10) {
                stepRow(steps.accessibility, number: 1, title: "Allow Accessibility",
                        detail: "Lets Murmur watch for the key and type into other apps.",
                        pane: "Privacy_Accessibility")
                stepRow(steps.microphone, number: 2, title: "Allow the microphone",
                        detail: "So it can hear you. Audio never leaves this Mac.",
                        pane: "Privacy_Microphone")
                modelRow(steps.model)
            }

            if isReady {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        keycap(state.hotKey.symbol)
                        Text("Hold \(state.hotKey.name), speak, release. Text lands where your cursor is.")
                            .font(Fonts.display(12)).foregroundStyle(Tokens.text2(scheme))
                    }
                    HStack(spacing: 6) {
                        keycap(state.meetingKey.symbol)
                        Text("Tap \(state.meetingKey.name) to record a meeting to a file.")
                            .font(Fonts.display(12)).foregroundStyle(Tokens.text2(scheme))
                    }
                    Text("Murmur lives in the menu bar. If you cannot see its icon, your menu bar is full; quit another menu bar app to make room.")
                        .font(Fonts.display(10.5)).foregroundStyle(Tokens.text3(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.blurIn)
            }

            HStack {
                Text("Made by FintonLabs")
                    .font(Fonts.mono(9.5)).foregroundStyle(Tokens.text3(scheme))
                Spacer()
                Button(isReady ? "Done" : "Close") { onDone() }
                    .buttonStyle(.plain)
                    .font(Fonts.display(12, .semibold))
                    .foregroundStyle(isReady ? Color.white : Tokens.text2(scheme))
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Capsule().fill(isReady ? AnyShapeStyle(Tokens.gradient) : AnyShapeStyle(Tokens.raised(scheme))))
                    .overlay(Capsule().strokeBorder(isReady ? Color.clear : Tokens.border(scheme)))
                    .keyboardShortcut(.defaultAction)
                    .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
            }
        }
        .padding(26)
        .padding(.top, 8)
        .frame(width: 420)
        .background(Tokens.raised(scheme).opacity(scheme == .dark ? 0.5 : 0.7))
        .preferredColorScheme(state.theme.colorScheme)
        .animation(.easeOut(duration: 0.3), value: isReady)
    }

    private func stepRow(_ step: Step, number: Int, title: String, detail: String, pane: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            badge(step, number: number)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Fonts.display(13, .semibold)).foregroundStyle(Tokens.text(scheme))
                Text(detail).font(Fonts.display(11)).foregroundStyle(Tokens.text3(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if step == .active {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .font(Fonts.display(11, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(Tokens.gradient))
                .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
            }
        }
        .padding(12)
        .background(card(step))
    }

    private func modelRow(_ step: Step) -> some View {
        let (detail, fraction): (String, Double?) = {
            if case .settingUp(let d, let f) = state.phase {
                return (d + ". A few minutes on a typical connection, once. You can close this window; Murmur carries on in the menu bar.", f)
            }
            return step == .done ? ("Ready. Transcription is instant from now on.", nil)
                                 : ("About 2.3GB, downloaded once — a few minutes on a typical connection — then compiled for the Neural Engine, under a minute.", nil)
        }()
        return HStack(alignment: .center, spacing: 12) {
            badge(step, number: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Get the speech model").font(Fonts.display(13, .semibold)).foregroundStyle(Tokens.text(scheme))
                    Spacer()
                    if let fraction, step == .active {
                        Text("\(Int(fraction * 100))%").font(Fonts.mono(11)).foregroundStyle(Tokens.text3(scheme))
                    }
                }
                if step == .active {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Tokens.border(scheme))
                            Capsule().fill(Tokens.gradient)
                                .frame(width: max(6, geo.size.width * (fraction ?? 0.1)))
                                .animation(.easeOut(duration: 0.4), value: fraction)
                        }
                    }
                    .frame(height: 5)
                }
                Text(detail).font(Fonts.display(11)).foregroundStyle(Tokens.text3(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(card(step))
    }

    private func badge(_ step: Step, number: Int) -> some View {
        ZStack {
            Circle().fill(step == .done ? AnyShapeStyle(Color.green.opacity(0.9))
                          : step == .active ? AnyShapeStyle(Tokens.gradient)
                          : AnyShapeStyle(Tokens.border(scheme)))
            if step == .done {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            } else {
                Text("\(number)").font(Fonts.mono(11)).foregroundStyle(step == .active ? .white : Tokens.text3(scheme))
            }
        }
        .frame(width: 24, height: 24)
    }

    private func card(_ step: Step) -> some View {
        RoundedRectangle(cornerRadius: Tokens.rPanel, style: .continuous)
            .fill(Tokens.raised(scheme).opacity(scheme == .dark ? 0.7 : 1))
            .overlay(RoundedRectangle(cornerRadius: Tokens.rPanel, style: .continuous)
                .strokeBorder(step == .active ? Tokens.accent(scheme).opacity(0.5) : Tokens.border(scheme)))
    }

    private func keycap(_ text: String) -> some View {
        Text(text).font(Fonts.mono(10)).foregroundStyle(Tokens.text(scheme))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Tokens.raised(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Tokens.border(scheme)))
    }
}
