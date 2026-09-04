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
        }

        render(.starting)
        state.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.render($0) }
            .store(in: &cancellables)
        state.$hotKey
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
        case .starting, .settingUp:
            symbol = "waveform.badge.exclamationmark"
            tint = .secondaryLabelColor
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
        case .ready:                    button.toolTip = "Murmur — hold \(state.hotKey.name) to dictate"
        case .recording:                button.toolTip = "Murmur — recording"
        case .failed(let message):      button.toolTip = "Murmur — \(message)"
        default:                        button.toolTip = "Murmur"
        }
    }

    @objc private func toggle() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
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
