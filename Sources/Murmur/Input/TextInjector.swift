import AppKit
import Carbon
import CoreGraphics

/// Puts text into whatever app has focus.
///
/// Uses the pasteboard rather than synthesising each character: measured at
/// 0.73 ms to save and restore the user's clipboard, versus per-keystroke
/// synthesis which is slow and which several apps drop entirely.
enum TextInjector {

    /// True when a password field (or similar) is focused. No app can inject then.
    static var isBlocked: Bool { IsSecureEventInputEnabled() }

    static func insert(_ text: String) throws {
        guard !text.isEmpty else { return }
        guard !isBlocked else { throw MurmurError.secureInputActive }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        sendCommandV()

        // Give the target app time to read the pasteboard before handing it back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            restore(saved, to: pasteboard)
        }
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        pb.pasteboardItems?.map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let value = item.data(forType: type) { entry[type] = value }
            }
            return entry
        } ?? []
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items: [NSPasteboardItem] = saved.map { entry in
            let item = NSPasteboardItem()
            for (type, value) in entry { item.setData(value, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
