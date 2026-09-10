import AppKit
import SwiftUI
import Combine

/// The status bar item and the popover hung off it.
@MainActor
final class MenuBarController {

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let host: NSHostingController<PopoverView>
    private let state: AppState
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover.behavior = .transient
        popover.animates = true
        host = NSHostingController(rootView: PopoverView(state: state))
        // The popover does not follow SwiftUI's size on its own. Left alone it
        // keeps the size it had, and a taller view is centred inside it, so the
        // header is the first thing to vanish. Size it to fit, every change.
        host.sizingOptions = []
        popover.contentViewController = host
        popover.contentSize = fittingSize()

        if let button = statusItem.button {
            button.action = #selector(toggle)
            button.target = self
            button.imagePosition = .imageOnly
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        render(.starting)
        state.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.render($0) }
            .store(in: &cancellables)
        // Anything that can change the panel's height: resize on the next turn
        // of the run loop, after SwiftUI has laid the new content out.
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.resizeToFit() }
            }
            .store(in: &cancellables)
        state.$hotKey.map { _ in () }.merge(with: state.$meeting.map { _ in () })
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self.map { $0.render($0.state.phase) } }
            .store(in: &cancellables)
    }

    private func fittingSize() -> NSSize {
        var size = host.sizeThatFits(in: NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude))
        size.width = 340
        // Never taller than the screen below the menu bar.
        if let screen = statusItem.button?.window?.screen ?? NSScreen.main {
            size.height = min(size.height, screen.visibleFrame.height - 24)
        }
        return size
    }

    private func resizeToFit() {
        let size = fittingSize()
        guard abs(size.height - popover.contentSize.height) > 0.5 else { return }
        popover.contentSize = size
    }

    /// The icon carries state on its own, so the popover does not have to be open
    /// for the user to know what is happening.
    private func render(_ phase: Phase) {
        guard let button = statusItem.button else { return }

        let symbol: String
        var tint: NSColor?

        switch phase {
        case .starting, .settingUp, .permissions:
            symbol = "waveform.badge.exclamationmark"
            tint = .secondaryLabelColor
        case .ready where state.meeting != nil:
            // Meeting mode is never silent in the menu bar.
            symbol = "record.circle"
            tint = NSColor(red: 0.910, green: 0.380, blue: 0.373, alpha: 1)
        case .ready:
            symbol = "waveform"
        case .recording:
            symbol = "waveform.circle.fill"
            tint = NSColor(red: 0.910, green: 0.380, blue: 0.373, alpha: 1)  // coral
        case .transcribing:
            symbol = "waveform.badge.magnifyingglass"
            tint = NSColor(red: 0.706, green: 0.549, blue: 0.910, alpha: 1)
        case .failed:
            symbol = "waveform.badge.xmark"
            tint = .systemRed
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmur")
        image?.isTemplate = (tint == nil)
        button.image = image
        button.contentTintColor = tint

        switch phase {
        case .settingUp(let detail, _): button.toolTip = "Murmur — \(detail)"
        case .permissions:              button.toolTip = "Murmur — needs Accessibility and Microphone; click for details"
        case .ready where state.meeting != nil:
            button.toolTip = "Murmur — meeting mode is recording; tap \(state.meetingKey.name) to stop"
        case .ready:                    button.toolTip = "Murmur — hold \(state.hotKey.name) to dictate"
        case .recording:                button.toolTip = "Murmur — recording"
        case .failed(let message):      button.toolTip = "Murmur — \(message)"
        default:                        button.toolTip = "Murmur"
        }
    }

    @objc private func toggle() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            state.page = .main
            popover.contentSize = fittingSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Test hook: fills the recent list with long entries and opens the panel,
    /// so the on-screen size can be checked without dictating three times.
    func debugFillAndPresent() {
        // Open first, fill second: the failure mode is content growing while
        // the panel is already up.
        presentOnce()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            for i in 1...3 {
                state.record(Dictation(
                    text: "Entry \(i): a long dictation that wraps to two lines in the panel so the recent list is as tall as it can get, and then some more words to be sure.",
                    spoken: 9.5, latency: 0.25, injected: true))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [self] in
            let frame = popover.contentViewController?.view.window?.frame ?? .zero
            let screen = NSScreen.main?.visibleFrame ?? .zero
            let line = String(format: "content=%.0fx%.0f window=%@ screenVisible=%@ shown=%d\n",
                              popover.contentSize.width, popover.contentSize.height,
                              NSStringFromRect(frame), NSStringFromRect(screen), popover.isShown ? 1 : 0)
            NSLog("[murmur] debug-fill-panel %@", line)
            let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Murmur/debug-panel.log")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Right-click: the day-to-day actions without opening the panel.
    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Transcripts", action: #selector(openTranscripts), keyEquivalent: "t").target = self
        if state.meeting == nil {
            menu.addItem(withTitle: "Start Meeting", action: #selector(startMeeting), keyEquivalent: "m").target = self
        } else {
            menu.addItem(withTitle: "Stop Meeting", action: #selector(stopMeeting), keyEquivalent: "m").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Murmur", action: #selector(quit), keyEquivalent: "q").target = self

        // The documented way to pop a menu from a status item that also has
        // a click action: attach it, click, detach.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openTranscripts() { state.openTranscripts() }
    @objc private func startMeeting() { state.requestMeetingStart?() }
    @objc private func stopMeeting() { state.requestMeetingStop?() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @objc private func openSettings() {
        guard let button = statusItem.button else { return }
        state.page = .settings
        if !popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
            popover.contentSize = fittingSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Opens the popover unprompted — used once at first launch so the setup
    /// progress is visible without the user having to hunt for the icon.
    /// The app is an accessory and never activates on its own, so a `.transient`
    /// popover would be dismissed the instant it appeared. Activating first is
    /// what makes it stay up.
    func presentOnce() {
        guard let button = statusItem.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.contentSize = fittingSize()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
