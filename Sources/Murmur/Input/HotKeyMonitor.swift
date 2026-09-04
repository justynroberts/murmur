import AppKit
import CoreGraphics
import Foundation

/// Global push-to-talk monitor. Watches a held modifier key across every app.
/// Requires Accessibility permission — a listen-only tap still counts as one.
final class HotKeyMonitor {

    /// Which modifier to watch. Read on every event, so it can change while the
    /// tap is live. Switching mid-hold releases the old key first, or the
    /// recording would never end.
    var key: HotKey = .default {
        didSet {
            guard key != oldValue, isDown else { return }
            isDown = false
            DispatchQueue.main.async { [weak self] in self?.onRelease() }
        }
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}

    /// The event-tap callback is a bare C function pointer and cannot capture context,
    /// so the live instance is reachable through this.
    fileprivate static weak var active: HotKeyMonitor?

    func start() throws {
        HotKeyMonitor.active = self

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                // The system disables a tap that takes too long; re-arm it.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    HotKeyMonitor.active?.reenable()
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

    fileprivate func handle(_ event: CGEvent) {
        guard event.getIntegerValueField(.keyboardEventKeycode) == key.keyCode else { return }

        // flagsChanged carries no up/down bit — infer it from whether the modifier survived the event.
        let down = event.flags.contains(key.flag)
        guard down != isDown else { return }
        isDown = down

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            down ? self.onPress() : self.onRelease()
        }
    }
}
