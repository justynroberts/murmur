import SwiftUI

/// MIT License - Copyright (c) fintonlabs.com
///
/// The design tokens, mirrored from the web surface so the app and the site
/// read as one thing. Every colour is defined for both schemes — see DESIGN.md.
enum Tokens {

    // Gradient pair: iris → magenta → coral. Carries the mark and the recording state.
    static let iris    = Color(red: 0.231, green: 0.180, blue: 0.561)
    static let magenta = Color(red: 0.541, green: 0.247, blue: 0.608)
    static let coral   = Color(red: 0.910, green: 0.380, blue: 0.373)

    static let gradient = LinearGradient(
        colors: [iris, magenta, coral],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func text(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.953, green: 0.945, blue: 0.973)
                   : Color(red: 0.078, green: 0.063, blue: 0.122)
    }
    static func text2(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.722, green: 0.694, blue: 0.800)
                   : Color(red: 0.275, green: 0.251, blue: 0.353)
    }
    static func text3(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.545, green: 0.514, blue: 0.639)
                   : Color(red: 0.435, green: 0.408, blue: 0.522)
    }
    static func raised(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.118, green: 0.094, blue: 0.188)
                   : Color(red: 0.937, green: 0.929, blue: 0.961)
    }
    static func border(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }
    static func accent(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.706, green: 0.549, blue: 0.910)
                   : Color(red: 0.420, green: 0.247, blue: 0.627)
    }

    // Soft-product radius language: generous everywhere, pill on controls.
    static let rPanel: CGFloat = 14
    static let rControl: CGFloat = 999
}

/// Registers the bundled variable font. Bricolage is not a system face, so
/// without this the UI silently falls back and the house style is not met.
enum Fonts {
    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true
        guard let url = Bundle.module.url(forResource: "BricolageGrotesque", withExtension: "ttf") else {
            NSLog("[murmur] Bricolage not found in bundle — falling back to system font")
            return
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            NSLog("[murmur] font registration failed: \(String(describing: error))")
        }
    }

    /// `weight` maps onto the variable `wght` axis via SwiftUI's weight bridging.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("BricolageGrotesque", size: size).weight(weight)
    }
    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}
