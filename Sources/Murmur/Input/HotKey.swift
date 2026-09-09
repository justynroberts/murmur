import CoreGraphics
import Foundation

/// The modifier held to dictate. Modifiers only: a held modifier on its own
/// types nothing, so the choice never fights the app that has focus.
///
/// Fn/Globe is deliberately absent — on recent Apple keyboards a bare press
/// fires the system action (emoji picker or Apple dictation) on release, which
/// would pop up after every utterance. Shift is absent because holding it while
/// typing is how capitals happen.
enum HotKey: String, CaseIterable, Identifiable {
    case rightOption, leftOption, rightCommand, rightControl, leftControl

    static let `default`: HotKey = .rightOption

    var id: String { rawValue }

    /// Virtual key code carried by the `.flagsChanged` event.
    var keyCode: Int64 {
        switch self {
        case .rightOption:  return 61   // kVK_RightOption
        case .leftOption:   return 58   // kVK_Option
        case .rightCommand: return 54   // kVK_RightCommand
        case .rightControl: return 62   // kVK_RightControl
        case .leftControl:  return 59   // kVK_Control
        }
    }

    /// `flagsChanged` carries no up/down bit; the key is down iff its flag
    /// survived the event. These are the device-specific masks (NX_DEVICE*),
    /// which tell left from right — `.maskAlternate` alone would report Right
    /// Option still down while Left Option is held, and two keys are now in
    /// use at once.
    var deviceFlag: UInt64 {
        switch self {
        case .rightOption:  return 0x0040   // NX_DEVICERALTKEYMASK
        case .leftOption:   return 0x0020   // NX_DEVICELALTKEYMASK
        case .rightCommand: return 0x0010   // NX_DEVICERCMDKEYMASK
        case .rightControl: return 0x2000   // NX_DEVICERCTLKEYMASK
        case .leftControl:  return 0x0001   // NX_DEVICELCTLKEYMASK
        }
    }

    func isDown(in flags: CGEventFlags) -> Bool {
        flags.rawValue & deviceFlag != 0
    }

    var name: String {
        switch self {
        case .rightOption:  return "Right Option"
        case .leftOption:   return "Left Option"
        case .rightCommand: return "Right Command"
        case .rightControl: return "Right Control"
        case .leftControl:  return "Left Control"
        }
    }

    var symbol: String {
        switch self {
        case .rightOption, .leftOption:   return "⌥"
        case .rightCommand:               return "⌘"
        case .rightControl, .leftControl: return "⌃"
        }
    }
}
