import AppKit
import Combine
import SwiftUI

/// The place people go for their meetings: every transcript, rendered as
/// Markdown, with copy, open, reveal and delete. A window rather than a page
/// in the popover, because reading a transcript wants room.
@MainActor
final class TranscriptsWindowController {

    private let state: AppState
    private let store: TranscriptStore
    private var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var refresh: Timer?

    init(state: AppState) {
        self.state = state
        self.store = TranscriptStore(folder: state.transcriptFolder)
        state.$transcriptFolder.dropFirst()
            .sink { [weak self] in self?.store.setFolder($0) }
            .store(in: &cancellables)
        // A meeting starting or a segment landing changes the list and the
        // selected file; re-read rather than trusting a stale listing.
        state.$meeting.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.store.reload() }
            .store(in: &cancellables)
    }

    /// Opens the window, selecting `url` if given (the meeting card's link).
    func show(selecting url: URL? = nil) {
        store.reload()
        if window == nil {
            let host = NSHostingController(rootView: TranscriptsView(state: state, store: store, initialSelection: url))
            let w = NSWindow(contentViewController: host)
            w.title = "Meeting Transcripts"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 820, height: 540))
            w.minSize = NSSize(width: 640, height: 380)
            w.center()
            w.setFrameAutosaveName("MurmurTranscripts")
            w.isReleasedWhenClosed = false
            window = w
        } else if let url {
            NotificationCenter.default.post(name: TranscriptsView.selectNotification, object: url)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // While the window is up, a meeting in progress grows in place.
        refresh?.invalidate()
        refresh = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let w = self.window, w.isVisible else { self?.refresh?.invalidate(); return }
                self.store.reload()
            }
        }
    }
}

struct TranscriptsView: View {
    static let selectNotification = Notification.Name("com.fintonlabs.murmur.transcripts.select")

    @ObservedObject var state: AppState
    @ObservedObject var store: TranscriptStore
    var initialSelection: URL?
    /// Offscreen rendering cannot lay out a ScrollView; previews pass true to
    /// get plain stacks so the list and body are actually drawn.
    var staticLayout = false

    @Environment(\.colorScheme) private var systemScheme
    private var scheme: ColorScheme { state.theme.colorScheme ?? systemScheme }

    @State private var selection: URL?
    @State private var query = ""
    @State private var showSource = false
    @State private var copied: String?
    @State private var confirmDelete: TranscriptItem?
    @State private var text = ""
    @State private var textVersion = 0

    init(state: AppState, store: TranscriptStore, initialSelection: URL?, staticLayout: Bool = false) {
        self.state = state
        self.store = store
        self.initialSelection = initialSelection
        self.staticLayout = staticLayout
        // onAppear never fires in an offscreen render, and the first frame on
        // screen should not be blank either: pick and load up front.
        let first = initialSelection ?? store.items.first?.url
        _selection = State(initialValue: first)
        _text = State(initialValue: store.items.first { $0.url == first }.map { store.contents(of: $0) } ?? "")
    }

    private var filtered: [TranscriptItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.items }
        return store.items.filter { $0.title.lowercased().contains(q) || $0.fileName.lowercased().contains(q)
            || store.contents(of: $0).lowercased().contains(q) }
    }
    private var selected: TranscriptItem? { store.items.first { $0.url == selection } }
    private var isRecording: Bool { selected.map { state.meeting?.fileURL == $0.url } ?? false }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 260)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(scheme == .dark ? Color(red: 0.07, green: 0.06, blue: 0.11) : Color(red: 0.96, green: 0.96, blue: 0.98))
        .preferredColorScheme(state.theme.colorScheme)
        .onChange(of: selection) { _, _ in loadText() }
        .onChange(of: store.items) { _, items in
            if selection == nil || !items.contains(where: { $0.url == selection }) { selection = items.first?.url }
            loadText()
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.selectNotification)) { note in
            if let url = note.object as? URL { selection = url }
        }
        .alert("Move this transcript to the Bin?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Move to Bin", role: .destructive) {
                if let item = confirmDelete { try? store.trash(item) }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text(confirmDelete?.fileName ?? "")
        }
    }

    @ViewBuilder
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if staticLayout {
            VStack(alignment: .leading, spacing: 0) { content(); Spacer(minLength: 0) }
        } else {
            ScrollView { content() }
        }
    }

    private func loadText() {
        text = selected.map { store.contents(of: $0) } ?? ""
        textVersion += 1
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Tokens.text3(scheme)).font(.system(size: 11))
                TextField("Search transcripts", text: $query)
                    .textFieldStyle(.plain)
                    .font(Fonts.display(12))
                    .foregroundStyle(Tokens.text(scheme))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tokens.raised(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Tokens.border(scheme)))
            .padding(12)

            if store.items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No meetings yet").font(Fonts.display(13, .semibold)).foregroundStyle(Tokens.text(scheme))
                    Text("Tap \(state.meetingKey.name) to start one. Each meeting becomes a file here, written as you go.")
                        .font(Fonts.display(11)).foregroundStyle(Tokens.text3(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                Spacer()
            } else {
                scrolling {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(filtered) { item in row(item) }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
            }

            Divider()
            HStack {
                Text("\(store.items.count) transcript\(store.items.count == 1 ? "" : "s")")
                    .font(Fonts.mono(9.5)).foregroundStyle(Tokens.text3(scheme))
                Spacer()
                Button("Show in Finder") { state.openTranscripts() }
                    .buttonStyle(.plain).font(Fonts.display(10.5, .medium)).foregroundStyle(Tokens.accent(scheme))
                    .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
    }

    private func row(_ item: TranscriptItem) -> some View {
        let live = state.meeting?.fileURL == item.url
        let isSelected = selection == item.url
        return Button { selection = item.url } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if live { Circle().fill(Tokens.coral).frame(width: 7, height: 7) }
                    Text(Self.day.string(from: item.started))
                        .font(Fonts.display(12.5, .semibold))
                        .foregroundStyle(isSelected ? .white : Tokens.text(scheme))
                        .lineLimit(1)
                    Spacer()
                    Text(Self.clock.string(from: item.started))
                        .font(Fonts.mono(10))
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : Tokens.text3(scheme))
                }
                Text(live ? "Recording now" : (item.length.map { "\($0)" + (item.segments.map { " · \($0) segments" } ?? "") } ?? "No footer — ended early"))
                    .font(Fonts.display(10.5))
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : (live ? Tokens.coral : Tokens.text3(scheme)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Tokens.gradient) : AnyShapeStyle(Color.clear)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item = selected {
                toolbar(item)
                Divider()
                scrolling {
                    Group {
                        if showSource {
                            Text(text)
                                .font(Fonts.mono(11.5))
                                .foregroundStyle(Tokens.text2(scheme))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            rendered
                        }
                    }
                    .padding(24)
                    .id(textVersion)
                }
            } else {
                Spacer()
                HStack { Spacer(); Text("Select a transcript").font(Fonts.display(13)).foregroundStyle(Tokens.text3(scheme)); Spacer() }
                Spacer()
            }
        }
    }

    private func toolbar(_ item: TranscriptItem) -> some View {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title.replacingOccurrences(of: "Meeting — ", with: ""))
                    .font(Fonts.display(14, .semibold)).foregroundStyle(Tokens.text(scheme)).lineLimit(1)
                    .layoutPriority(1)
                HStack(spacing: 6) {
                    if isRecording {
                        Circle().fill(Tokens.coral).frame(width: 6, height: 6)
                        Text("Recording · updates as you speak").font(Fonts.mono(9.5)).foregroundStyle(Tokens.coral)
                    } else {
                        Text([item.startedClock.map { "Started \($0)" }, item.endedClock.map { "ended \($0)" }, item.length, item.segments.map { "\($0) segments" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(Fonts.mono(9.5)).foregroundStyle(Tokens.text3(scheme))
                    }
                }
            }
            Spacer(minLength: 12)
            viewToggle.fixedSize()
        }
        HStack(spacing: 8) {
                actionButton(copied == "md" ? "Copied" : "Copy Markdown", symbol: "doc.on.doc", primary: true) {
                    store.copyMarkdown(item); flashCopied("md")
                }
                .keyboardShortcut("c", modifiers: .command)
                actionButton(copied == "txt" ? "Copied" : "Copy Text", symbol: "text.alignleft") {
                    store.copyPlainText(item); flashCopied("txt")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                iconAction("arrow.up.forward.app", help: "Open in your default Markdown editor") { NSWorkspace.shared.open(item.url) }
                iconAction("folder", help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                iconAction("trash", help: isRecording ? "Stop the meeting before deleting" : "Move to Bin", disabled: isRecording) { confirmDelete = item }
                Spacer(minLength: 0)
        }
      }
      .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var viewToggle: some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { source in
                let on = showSource == source
                Button { withAnimation(.easeOut(duration: 0.15)) { showSource = source } } label: {
                    Text(source ? "Markdown" : "Rendered")
                        .font(Fonts.display(10.5, .medium))
                        .foregroundStyle(on ? Color.white : Tokens.text2(scheme))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(on ? AnyShapeStyle(Tokens.gradient) : AnyShapeStyle(Color.clear)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Tokens.raised(scheme)))
        .overlay(Capsule().strokeBorder(Tokens.border(scheme)))
    }

    private func iconAction(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: { if !disabled { action() } }) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Tokens.text2(scheme).opacity(disabled ? 0.35 : 1))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Tokens.raised(scheme)))
                .overlay(Circle().strokeBorder(Tokens.border(scheme)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { $0 && !disabled ? NSCursor.pointingHand.push() : NSCursor.pop() }
    }

    private func flashCopied(_ what: String) {
        withAnimation(.easeOut(duration: 0.15)) { copied = what }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { copied = nil } }
    }

    private func actionButton(_ title: String, symbol: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(Fonts.display(11, .semibold))
            }
            .foregroundStyle(primary ? Color.white : Tokens.text(scheme))
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(primary ? AnyShapeStyle(Tokens.gradient) : AnyShapeStyle(Tokens.raised(scheme))))
            .overlay(Capsule().strokeBorder(primary ? Color.clear : Tokens.border(scheme)))
        }
        .buttonStyle(.plain)
        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
    }

    private var rendered: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let t):
                    Text(t)
                        .font(Fonts.display(level == 1 ? 20 : 15, .semibold))
                        .foregroundStyle(Tokens.text(scheme))
                        .padding(.top, level == 1 ? 0 : 8)
                case .rule:
                    Divider().padding(.vertical, 4)
                case .note(let t):
                    Text(t).font(Fonts.display(11)).italic().foregroundStyle(Tokens.text3(scheme))
                case .paragraph(let t):
                    Text(Self.inline(t, size: 13, base: Tokens.text2(scheme), strong: Tokens.text(scheme)))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
    }

    /// Inline Markdown to attributed text in the house face. A plain
    /// `.font()` on the Text would flatten the bold and italic runs that
    /// AttributedString(markdown:) marks up, so each run gets its own font.
    static func inline(_ markdown: String, size: CGFloat, base: Color, strong: Color) -> AttributedString {
        var s = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        for run in s.runs {
            let intent = run.inlinePresentationIntent ?? []
            let bold = intent.contains(.stronglyEmphasized)
            let italic = intent.contains(.emphasized)
            var font = Fonts.display(size, bold ? .semibold : .regular)
            if italic { font = font.italic() }
            s[run.range].font = font
            s[run.range].foregroundColor = bold ? strong : base
        }
        return s
    }

    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM yyyy"; return f }()
    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
}
