import AppKit
import Combine
import SwiftUI

/// The panel without the menu bar. On a notched MacBook with a full menu bar
/// macOS drops status items silently, and then the popover has nothing to hang
/// from. This hosts the same PopoverView in a floating panel under the menu
/// bar, opened by a tap of the dictation key, a click on the Dock icon when
/// that is on, or `Murmur panel`. Escape or clicking elsewhere closes it.
@MainActor
final class PanelWindowController {

    private let state: AppState
    private var panel: NSPanel?
    private var host: NSHostingController<PopoverView>?
    private var cancellables = Set<AnyCancellable>()
    private var observer: Any?

    init(state: AppState) {
        self.state = state
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.resize() } }
            .store(in: &cancellables)
    }

    var isShown: Bool { panel?.isVisible ?? false }

    func toggle() { isShown ? hide() : show() }

    func show() {
        state.focusTarget = AppTarget.frontmost()
        if panel == nil { build() }
        guard let panel else { return }
        resize()
        place(panel)
        panel.makeKeyAndOrderFront(nil)
        // Close when the user clicks elsewhere. Armed a beat later: the
        // key-status churn of ordering a non-activating panel in can fire a
        // resign straight away and dismiss it before it is seen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak panel] in
            guard let self, let panel, panel.isVisible else { return }
            self.observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    func hide() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        panel?.orderOut(nil)
    }

    private func build() {
        let host = NSHostingController(rootView: PopoverView(state: state))
        host.sizingOptions = []
        // The popover gets a blurred material from NSPopover for free; a bare
        // panel does not, and the view's translucent tint over whatever is
        // behind it is unreadable. Same material, rounded, behind the view.
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 14
        material.layer?.masksToBounds = true
        host.view.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: material.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                             styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                             backing: .buffered, defer: false)
        p.contentView = material
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        self.host = host
        panel = p
    }

    private func resize() {
        guard let panel, let host else { return }
        host.view.layoutSubtreeIfNeeded()
        var size = host.sizeThatFits(in: NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude))
        size.width = 340
        if let screen = panel.screen ?? NSScreen.main { size.height = min(size.height, screen.visibleFrame.height - 24) }
        guard abs(size.height - panel.contentView!.frame.height) > 0.5 || abs(size.width - panel.contentView!.frame.width) > 0.5 else { return }
        let top = panel.frame.maxY
        panel.setContentSize(size)
        if panel.isVisible { panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top)) }
    }

    /// Centred under the menu bar of the screen the pointer is on — where the
    /// user is looking, which is not always where the key window is.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        let x = v.midX - panel.frame.width / 2
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: v.maxY - 6))
    }
}

/// A non-activating panel still has to be able to become key, or its buttons
/// and text fields are dead.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
