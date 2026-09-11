import AppKit
import SwiftUI

/// Settings, in a window of their own. They used to be a second page inside the
/// menu bar popover, which meant resizing the popover mid-transition and a
/// moment with the new page centred and clipped in the old frame. A window is
/// what macOS users expect from Settings… anyway, and it sizes itself.
@MainActor
final class SettingsWindowController {

    private let state: AppState
    private var window: NSWindow?

    init(state: AppState) {
        self.state = state
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SettingsView(state: state))
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.title = "Murmur Settings"
        w.styleMask = [.titled, .closable]
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var systemScheme
    private var scheme: ColorScheme { state.theme.colorScheme ?? systemScheme }

    /// Pure SwiftUI controls rather than Picker and Toggle: those are
    /// AppKit-backed, which ImageRenderer cannot draw, so `render-ui` would
    /// verify nothing. Keycaps and a pill switch also match DESIGN.md better
    /// than stock controls do.
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                label("Appearance", Tokens.text2(scheme), size: 11.5)
                Spacer()
                HStack(spacing: 4) {
                    ForEach(ThemeChoice.allCases, id: \.self) { choice in
                        themeChip(choice)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Hold to dictate", Tokens.text2(scheme), size: 11.5)
                HStack(spacing: 5) {
                    ForEach(HotKey.allCases) { key in
                        keyChip(key, selection: $state.hotKey, taken: state.meetingKey)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Tap for meeting mode", Tokens.text2(scheme), size: 11.5)
                HStack(spacing: 5) {
                    ForEach(HotKey.allCases) { key in
                        keyChip(key, selection: $state.meetingKey, taken: state.hotKey)
                    }
                }
                label("Records until you tap again and saves the transcript as a file. Audio is never kept.",
                      Tokens.text3(scheme), size: 9.5)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    label("Transcripts", Tokens.text2(scheme), size: 11.5)
                    Spacer()
                    Button("Open") { NSWorkspace.shared.open(state.transcriptFolder) }
                        .buttonStyle(.plain)
                        .font(Fonts.display(10, .medium))
                        .foregroundStyle(Tokens.accent(scheme))
                        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
                    Button("Change…") { chooseTranscriptFolder() }
                        .buttonStyle(.plain)
                        .font(Fonts.display(10, .medium))
                        .foregroundStyle(Tokens.accent(scheme))
                        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
                }
                Text(state.transcriptFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(Fonts.mono(9.5))
                    .foregroundStyle(Tokens.text3(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let note = state.meetingNote {
                label(note, Tokens.coral, size: 10)
                    .transition(.blurIn)
            }

            HStack {
                label("Launch at login", Tokens.text2(scheme), size: 11.5)
                Spacer()
                pillSwitch(isOn: $state.launchAtLogin, label: "Launch at login")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    label("Check for updates", Tokens.text2(scheme), size: 11.5)
                    Spacer()
                    pillSwitch(isOn: $state.checkForUpdates, label: "Check for updates")
                }
                if state.checkForUpdates {
                    HStack(spacing: 6) {
                        if state.updateStatus == .checking {
                            ProgressView().controlSize(.mini)
                        }
                        label(updateStatusText, Tokens.text3(scheme), size: 10)
                        Spacer()
                        if state.updateStatus != .checking {
                            Button("Check now") { state.requestUpdateCheck?() }
                                .buttonStyle(.plain)
                                .font(Fonts.display(10, .medium))
                                .foregroundStyle(Tokens.accent(scheme))
                                .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
                        }
                    }
                    .transition(.blurIn)
                }
                label("Off by default. When on, Murmur asks GitHub for the latest version number once a day. Nothing else is ever sent.",
                      Tokens.text3(scheme), size: 9.5)
            }
            .animation(.easeOut(duration: 0.22), value: state.checkForUpdates)

            if let note = state.settingsNote {
                label(note, Tokens.coral, size: 10)
                    .transition(.blurIn)
            }
        }
        .animation(.easeOut(duration: 0.22), value: state.settingsNote)
        .padding(22)
        .frame(width: 380)
        // A window has no material behind it, so the popover's translucent
        // tint would come out grey here. Solid ground, both themes.
        .background(scheme == .dark ? Color(red: 0.07, green: 0.06, blue: 0.11)
                                    : Color(red: 0.96, green: 0.96, blue: 0.98))
        .preferredColorScheme(state.theme.colorScheme)
    }

    private var updateStatusText: String {
        switch state.updateStatus {
        case .idle:      return "Not checked yet"
        case .checking:  return "Checking…"
        case .failed:    return "Could not reach GitHub"
        case .checked(let when):
            let ago = RelativeDateTimeFormatter()
            ago.unitsStyle = .short
            let base = state.availableUpdate == nil ? "Up to date" : "Update available"
            return "\(base) · checked \(ago.localizedString(for: when, relativeTo: Date()))"
        }
    }

    private func themeChip(_ choice: ThemeChoice) -> some View {
        let selected = state.theme == choice
        let name: String = { switch choice { case .auto: return "Auto"; case .light: return "Light"; case .dark: return "Dark" } }()
        return Button {
            withAnimation(.easeOut(duration: 0.22)) { state.theme = choice }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: choice.symbol).font(.system(size: 9, weight: .medium))
                Text(name).font(Fonts.display(10.5, .medium))
            }
            .foregroundStyle(selected ? Color.white : Tokens.text(scheme))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(selected ? AnyShapeStyle(Tokens.gradient) : AnyShapeStyle(Tokens.raised(scheme))))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Tokens.border(scheme)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) appearance")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
    }

    /// `taken` is the other mode's key: shown but not selectable, so the two
    /// can never collide.
    private func keyChip(_ key: HotKey, selection: Binding<HotKey>, taken: HotKey) -> some View {
        let selected = selection.wrappedValue == key
        let disabled = key == taken
        let side = key.name.hasPrefix("Right") ? "R" : "L"
        return Button {
            guard !disabled else { return }
            withAnimation(.easeOut(duration: 0.18)) { selection.wrappedValue = key }
        } label: {
            Text("\(side) \(key.symbol)")
                .font(Fonts.mono(10))
                .foregroundStyle(selected ? Color.white : Tokens.text(scheme).opacity(disabled ? 0.35 : 1))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? AnyShapeStyle(Tokens.gradient)
                                       : AnyShapeStyle(Tokens.raised(scheme)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(selected ? Color.clear : Tokens.border(scheme))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(key.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(disabled ? "\(key.name) is the other mode's key" : key.name)
        .onHover { $0 && !disabled ? NSCursor.pointingHand.push() : NSCursor.pop() }
    }

    private func chooseTranscriptFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = state.transcriptFolder
        panel.prompt = "Use this folder"
        panel.message = "Meeting transcripts will be saved here."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            state.transcriptFolder = url
        }
    }

    private func pillSwitch(isOn: Binding<Bool>, label: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { isOn.wrappedValue.toggle() }
        } label: {
            ZStack(alignment: isOn.wrappedValue ? .trailing : .leading) {
                Capsule()
                    .fill(isOn.wrappedValue ? AnyShapeStyle(Tokens.gradient)
                                            : AnyShapeStyle(Tokens.border(scheme)))
                Circle()
                    .fill(Color.white)
                    .padding(2)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
            }
            .frame(width: 32, height: 18)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
    }

    private func label(_ text: String, _ colour: Color,
                       size: CGFloat = 12.5, weight: Font.Weight = .regular) -> some View {
        Text(text)
            .font(Fonts.display(size, weight))
            .foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
    }
}
