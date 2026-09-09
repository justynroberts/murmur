import AppKit
import SwiftUI
import Combine

/// The status bar item and the popover hung off it.
@MainActor
final class MenuBarController {

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let state: AppState
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 340, height: 260)
        popover.contentViewController = NSHostingController(rootView: PopoverView(state: state))

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
        state.$hotKey.map { _ in () }.merge(with: state.$meeting.map { _ in () })
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self.map { $0.render($0.state.phase) } }
            .store(in: &cancellables)
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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
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
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
