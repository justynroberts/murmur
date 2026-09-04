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

    /// `flagsChanged` carries no up/down bit; the key is down iff its modifier
    /// flag survived the event.
    var flag: CGEventFlags {
        switch self {
        case .rightOption, .leftOption:   return .maskAlternate
        case .rightCommand:               return .maskCommand
        case .rightControl, .leftControl: return .maskControl
        }
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
