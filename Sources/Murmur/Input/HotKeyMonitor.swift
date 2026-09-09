import AppKit
import CoreGraphics
import Foundation

/// Global modifier-key monitor. Watches a set of modifiers across every app and
/// reports press, release, and *tap* — a press and release with no other key
/// in between, which is what toggles meeting mode. The "no other key" part
/// matters: Left Control is in half the shortcuts on the machine, and a
/// Ctrl-C must not start a recording.
///
/// Requires Accessibility permission — a listen-only tap still counts as one.
final class HotKeyMonitor {

    /// Which modifiers to watch. Read on every event, so it can change while
    /// the tap is live. A key that is held when it stops being watched is
    /// released first, or a recording started on it would never end.
    var keys: [HotKey] = [] {
        didSet {
            for key in down where !keys.contains(key) {
                down.remove(key)
                DispatchQueue.main.async { [weak self] in self?.onRelease(key) }
            }
        }
    }

    var onPress: (HotKey) -> Void = { _ in }
    var onRelease: (HotKey) -> Void = { _ in }
    /// Pressed and released within `tapWindow` with nothing else pressed.
    var onTap: (HotKey) -> Void = { _ in }

    private let tapWindow: TimeInterval = 0.6
    /// Injected so the tap window can be tested without sleeping.
    var clock: () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var down: Set<HotKey> = []
    private var pressedAt: [HotKey: CFAbsoluteTime] = [:]
    private var tapSpoiled: Set<HotKey> = []

    /// The event-tap callback is a bare C function pointer and cannot capture context,
    /// so the live instance is reachable through this.
    fileprivate static weak var active: HotKeyMonitor?

    func start() throws {
        HotKeyMonitor.active = self

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
                 | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                // The system disables a tap that takes too long; re-arm it.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    HotKeyMonitor.active?.reenable()
                } else if type == .keyDown {
                    HotKeyMonitor.active?.spoilTaps()
                } else {
                    HotKeyMonitor.active?.handle(event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            throw MurmurError.accessibilityDenied
        }

        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    fileprivate func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Any ordinary key while a watched modifier is held means it was a
    /// shortcut, not a tap.
    func spoilTaps() {
        tapSpoiled.formUnion(down)
    }

    func handle(_ event: CGEvent) {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard let key = keys.first(where: { $0.keyCode == code }) else { return }

        let isDown = key.isDown(in: event.flags)
        guard isDown != down.contains(key) else { return }

        if isDown {
            down.insert(key)
            pressedAt[key] = clock()
            tapSpoiled.remove(key)
            // A modifier pressed while another watched one is held is a chord, not a tap.
            if down.count > 1 { tapSpoiled.formUnion(down) }
            DispatchQueue.main.async { [weak self] in self?.onPress(key) }
        } else {
            down.remove(key)
            let held = clock() - (pressedAt[key] ?? 0)
            let tapped = held < tapWindow && !tapSpoiled.contains(key)
            tapSpoiled.remove(key)
            DispatchQueue.main.async { [weak self] in
                self?.onRelease(key)
                if tapped { self?.onTap(key) }
            }
        }
    }
}
