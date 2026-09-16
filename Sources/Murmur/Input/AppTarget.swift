import AppKit
import Foundation

/// Where the text is about to land. Read at the moment the key is released,
/// because that is the app the paste goes to. Terminals and editors get the
/// code profile and, for terminals, Enter after the paste, so speaking to a
/// coding agent is speak, release, sent.
struct AppTarget: Equatable {
    enum Kind: String { case terminal, editor, other }

    let bundleID: String?
    let name: String?
    let kind: Kind

    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "com.mitchellh.ghostty", "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
        "co.zeit.hyper", "org.tabby", "com.apple.dt.Xcode.Console",
    ]
    static let editors: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92" /* Cursor */, "com.exafunction.windsurf", "dev.zed.Zed",
        "com.sublimetext.4", "com.sublimetext.3", "com.neovide.neovide", "org.vim.MacVim",
        "com.panic.Nova", "com.barebones.bbedit", "abnerworks.Typora",
    ]
    static let editorPrefixes = ["com.jetbrains.", "com.google.android.studio"]

    static func kind(of bundleID: String?) -> Kind {
        guard let id = bundleID else { return .other }
        if terminals.contains(id) { return .terminal }
        if editors.contains(id) || editorPrefixes.contains(where: { id.hasPrefix($0) }) { return .editor }
        return .other
    }

    @MainActor
    static func frontmost() -> AppTarget {
        let app = NSWorkspace.shared.frontmostApplication
        return AppTarget(bundleID: app?.bundleIdentifier, name: app?.localizedName, kind: kind(of: app?.bundleIdentifier))
    }
}
