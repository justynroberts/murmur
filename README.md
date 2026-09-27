<div align="center">
  <img src="Assets/icon.svg" width="128" alt="Murmur">
  <h1>Murmur</h1>
  <p><strong>Offline dictation and meeting transcription for macOS.</strong></p>
  <p>
    <a href="https://github.com/justynroberts/murmur/releases/latest"><strong>Download</strong></a> ·
    <a href="https://justynroberts.github.io/murmur/">Website</a> ·
    <a href="#install">Install</a> ·
    <a href="#dictate">Dictate</a> ·
    <a href="#meetings">Meetings</a> ·
    <a href="#settings">Settings</a>
  </p>
</div>

Hold a key, speak, release: cleaned-up text lands in whatever app you were typing in.
Tap another key and Murmur records a meeting to a file until you tap again.

Nothing leaves your Mac. No account, no subscription, no network access after the
one-time model download unless you switch on the optional update check.

<p align="center">
  <img src="docs/screenshots/panel-ready.png" width="326" alt="The Murmur panel, ready to dictate">
  <img src="docs/screenshots/menubar-menu.png" width="166" alt="The right-click menu on the menu bar icon">
</p>

## Install

Requires macOS 14 or later on Apple Silicon.

1. **Download** [the latest disk image](https://github.com/justynroberts/murmur/releases/latest)
   and drag Murmur into Applications. It is signed and notarised, so it opens without a
   Gatekeeper warning.
2. **Open Murmur.** A setup window appears and walks through the rest. Grant
   **Accessibility** and **Microphone** with the Open Settings buttons; Accessibility is
   what lets it watch for the key and type into other apps. It carries on by itself the
   moment each is granted.
3. **Let it fetch the speech model.** About 450MB, downloaded once as a single file from
   GitHub, then under a minute to compile for the Neural Engine. The window shows
   progress; close it if you like and the menu bar icon takes over.

<p align="center">
  <img src="docs/screenshots/setup-light-download.png" width="420" alt="The setup window during the model download">
</p>

After that, Murmur lives in the menu bar. Turn on **Launch at login** in Settings and you
never have to think about it again.

**If the key does nothing**, it is almost always Accessibility. System Settings →
Privacy & Security → Accessibility → enable Murmur. If it is already on, remove the entry
and add it back. See [Troubleshooting](docs/TROUBLESHOOTING.md) for the rest.

## The menu bar icon

<p align="center">
  <img src="docs/screenshots/menubar-menu.png" width="332" alt="Right-click menu: Open Transcripts, Start Meeting, Settings, Quit">
</p>

The icon tells you what is happening without opening anything: plain when ready, a coral
waveform while you hold the key, a record glyph the whole time a meeting is on, and dimmed
or badged while setting up or if something is wrong.

**Left-click** opens the panel. **Right-click** gives you the day-to-day actions without it:
Open Transcripts, Start or Stop Meeting, Settings, Quit.

## Dictate

Hold **Left Option**, speak, release. The text appears wherever your cursor is, in any app.

- A short tap does nothing, so an accidental press never fires an empty transcription.
- Speaking during first-run setup is fine: the audio is queued and typed the moment setup
  finishes.
- Cleanup is deliberately conservative. Filler sounds like "um" and "erm" are removed,
  sentences are capitalised and ended, and nothing else is touched. A stray "so" is far
  better than a lost clause.
- Nothing you dictate is saved anywhere. Only the last three appear in the panel, with the
  time they took.

If the text lands nowhere, a password field probably has focus. macOS blocks every app
from typing while Secure Input is on, and Murmur says so in the panel.

### Words it gets wrong

Product names it splits ("pager duty") and names spelled the common way ("Justin") are
fixed once, in a word list. Click the **book icon** in the panel to open it:

```json
{
  "pager duty": "PagerDuty",
  "justin": "Justyn"
}
```

Changes apply on the next dictation. Your spelling wins, so "npm" stays "npm" even at the
start of a sentence.

## Meetings

Tap **Right Option** and Murmur records until you tap again. Nothing is typed anywhere.
The transcript is written to a file as you go.

<p align="center">
  <img src="docs/screenshots/popover-light-meeting.png" width="340" alt="Meeting mode running, with segments saved and an Open transcript link">
</p>

- **One file per meeting**, in `~/Documents/Murmur` unless you choose another folder,
  named for when it started: `Meeting 2026-09-09 10.00.md`. The start time is in the
  header and the end time and length in the footer. Plain Markdown, so Obsidian, Spotlight
  or any editor can read it.
- **Saved as you go.** Each segment is written and forced to disk the moment it is
  transcribed, and the file is forced to disk every minute on top. The panel shows how many
  segments are saved and how long ago.
- **A flat battery loses nothing.** Audio for the segment being spoken is spooled to disk
  until its words are safely written. Open Murmur again after a crash or a power cut and
  it transcribes what was left and appends it under a "Recovered after an interruption"
  heading. Audio is never kept beyond that.
- **Stops on sleep and on quit**, and does not restart by itself.
- A tap is a press and release with nothing else in between, so pressing another key
  while the modifier is down is treated as a shortcut, not a tap.

**Your transcripts live in a window of their own.** The Transcripts card in the panel, the
document icon beside it, **Open transcript** on the meeting card, and **Transcripts…** in the
right-click menu all open it. Every meeting is listed newest first with its length and
segment count; the selected one is shown rendered, or as raw Markdown with a flick of the
toggle. **Copy Markdown** (⌘C) copies the whole file; **Copy Text** (⇧⌘C) copies just the
words, without the header and footer. Open in your editor, show in Finder, or move to the
Bin from the same row. Search covers titles and the text inside. A meeting in progress
shows with a red dot and grows in place while you watch.

You can also start and stop from a script or a Shortcut:

```bash
/Applications/Murmur.app/Contents/MacOS/Murmur meeting start
/Applications/Murmur.app/Contents/MacOS/Murmur meeting stop
```

## For developers

Murmur is built to be the voice in front of a terminal and a coding agent.

### Speak identifiers

Say a casing mode and the words, anywhere:

| You say | You get |
|---|---|
| camel case user session token | `userSessionToken` |
| snake case max retry count | `max_retry_count` |
| kebab case build and deploy | `build-and-deploy` |
| constant case default timeout | `DEFAULT_TIMEOUT` |
| pascal case user profile view | `UserProfileView` |
| dot case config server port | `config.server.port` |
| slash path usr local bin | `usr/local/bin` |

Two more modes for the things speech gets wrong: **spell** and **number**.

| You say | You get |
|---|---|
| spell k u b e c t l | `kubectl` |
| spell capital m u r m u r | `Murmur` |
| number one dot two dot three | `1.2.3` |
| number two thousand and four | `2004` |
| digits zero seven one one | `0711` |

Letter names work too ("kay you bee ee" is `kube`), and so do dash, underscore and dot
inside a spelling. A mode runs until you pause (the model puts a comma there), say "end",
or stop talking. "Rename it to camel case user session token, then save" comes out as
"Rename it to userSessionToken, then save."

### Speak symbols

In a terminal or an editor, Murmur switches to a code vocabulary: open and close paren,
brace, bracket and angle; arrow, fat arrow, equals, double and triple equals, not equals,
plus, minus, pipe, ampersand, slash, backslash, dot, colon, semicolon, comma, hash,
dollar, percent, caret, tilde, underscore, star, backtick, dash, at sign, new line, tab.
Brackets and dots glue to their neighbours, operators get spaces, and nothing gets a
capital letter or a full stop, so "git checkout dash b camel case feature branch" is
`git checkout -b featureBranch` and "foo open paren bar comma baz close paren" is
`foo(bar, baz)`. In Slack or mail the same words stay words.

### Take it back

Say **"scratch that"** and Murmur deletes what the last dictation inserted, as long as you
are still in the same app and it was not already sent with Enter.

### Macros

Say a phrase on its own and its text goes in instead: a signature, a standup template, a
commit message skeleton. They live in `~/Library/Application Support/Murmur/macros.json`,
opened from Settings under Developers, and `{date}` and `{time}` are filled in:

```json
{
  "sign off": "Thanks,\nJustyn",
  "standup": "Yesterday: \nToday: \nBlocked: "
}
```

### Speak to your agent

End any phrase with **"send"** and Murmur presses Enter after inserting, in any app, so
talking to Claude Code, Codex or any terminal agent is "fix the failing test, send". "Send"
on its own just presses Enter. If you would rather every terminal dictation were sent
without the word, there is a switch for that under Developers in Settings; it is off by
default because it would fire mid-command and inside vim. The Ready card in the panel says
where the next words are going and which vocabulary applies. Terminals it knows: Terminal, iTerm2, Warp, Ghostty, Alacritty, kitty,
WezTerm, Hyper. Editors: Xcode, VS Code, Cursor, Windsurf, Zed, Sublime, JetBrains, Nova,
BBEdit, MacVim, Neovide.

### Give your agent your meetings

Murmur is an MCP server. Register it once and any MCP client can list, read and search
your meeting transcripts, and start or stop a meeting:

```bash
claude mcp add murmur -- /Applications/Murmur.app/Contents/MacOS/Murmur mcp
```

Then ask: "what did we decide about the budget on Thursday?" The agent process is local
and reads local files; nothing leaves the machine. The same is available by hand:

```bash
/Applications/Murmur.app/Contents/MacOS/Murmur transcripts list
/Applications/Murmur.app/Contents/MacOS/Murmur transcripts show latest
/Applications/Murmur.app/Contents/MacOS/Murmur transcripts search budget
```

## Settings

The **gear icon** in the panel, or Settings from the right-click menu.

<p align="center">
  <img src="docs/screenshots/panel-settings.png" width="331" alt="Settings page">
</p>

| Setting | What it does |
|---|---|
| Appearance | Auto, light or dark. |
| Hold to dictate | Which modifier to hold. Left Option by default. |
| Tap for meeting mode | Which modifier to tap. Right Option by default. The two can never be the same key. |
| Transcripts | Where meeting files go. Open it, or change it. |
| Launch at login | Keeps Murmur in the menu bar after a restart. |
| Code vocabulary in terminals and editors | Symbols, no capitals, no full stops when the text is going to a terminal or editor. On by default. |
| Always press Enter after inserting in a terminal | Off by default; "…send" presses Enter regardless, anywhere. |
| Check for updates | **Off by default.** When on, asks GitHub for the latest version number once a day and sends nothing else. |

Fn/Globe is not offered as a key because a bare press fires the emoji picker or Apple's
own dictation on release, and Shift is not offered because holding it is how capitals
happen.

## Updating

With the update check on, a new version appears in the panel. **Update** downloads it,
checks the new copy carries the same Developer ID signature as the one you are running,
installs it and relaunches. It refuses to do this during a meeting. Nothing is downloaded
until you press the button.

<p align="center">
  <img src="docs/screenshots/popover-light-update.png" width="340" alt="An update offered in the panel">
</p>

With the check off, new versions are on the
[releases page](https://github.com/justynroberts/murmur/releases); About links there.

## How it works, briefly

```
key held      →  CGEventTap  →  AVAudioEngine @ 16kHz
key released  →  Parakeet TDT v2 (CoreML, Neural Engine)  →  rule-based cleanup
              →  pasteboard + Cmd-V into the frontmost app        (dictation)
              →  appended to a Markdown file                       (meeting)
```

A short utterance transcribes in **0.176s** on an M1, faster than the network round trip a
cloud service pays before its model starts. The model runs through
[FluidAudio](https://github.com/FluidInference/FluidAudio), pure Swift, no Python sidecar,
a 16MB binary.

After the models load the network is locked off: any later network call throws rather
than quietly succeeding. Check it yourself:

```bash
swift run Murmur selftest test_short.wav --offline
```

## Build from source

```bash
git clone https://github.com/justynroberts/murmur.git && cd murmur
swift build -c release
./Scripts/bundle.sh release
open Murmur.app
```

Always run `bundle.sh` after a build. macOS ties the Accessibility grant to the bundle and
its signature, so the bare binary never gets one.

## Documentation

| | |
|---|---|
| [Architecture](ARCHITECTURE.md) | How the loop fits together, why each piece is the way it is, and what will bite you |
| [Benchmarks](docs/BENCHMARKS.md) | Every measurement behind the design decisions |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Permissions, Secure Input, Electron limitations, recovery |
| [Releasing](docs/RELEASING.md) | Signing, notarisation, and the one command that publishes |
| [Design](DESIGN.md) | Visual language for the menu bar interface |

## Licence

MIT — Copyright (c) fintonlabs.com
