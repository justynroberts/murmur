import Foundation

enum MurmurError: LocalizedError {
    case accessibilityDenied
    case microphoneDenied
    case noInputDevice
    case modelsNotLoaded
    case secureInputActive

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return "Accessibility permission is required to watch for the hotkey and insert text."
        case .microphoneDenied:
            return "Microphone permission was denied."
        case .noInputDevice:
            return "No audio input device is available."
        case .modelsNotLoaded:
            return "Speech models are still loading."
        case .secureInputActive:
            return "A password field is focused — macOS blocks text insertion while Secure Input is on."
        }
    }
}
