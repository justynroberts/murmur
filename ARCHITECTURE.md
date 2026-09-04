# Architecture

How Murmur fits together, why each piece is the way it is, and what will bite
you. Read this before changing anything.

## What this is

Murmur — offline push-to-talk dictation for macOS. Hold Right Option, speak, release,
and cleaned-up text lands in whatever app has focus. A free replacement for
Wispr Flow (~$15/mo) and superwhisper (~$84/yr).

**Non-negotiable: nothing ever leaves the machine.** No cloud fallback, no telemetry,
no opt-in network path. `Transcriber.load` sets `ModelHub.offlineMode = true`
after models load, so any later network attempt throws `DownloadError.networkDisabled`
instead of silently succeeding. Keep it that way — the offline guarantee is the product.

## Commands

```bash
swift build                              # debug compile
swift build -c release                   # release compile
./Scripts/bundle.sh [debug|release]      # wrap in Murmur.app (do this after EVERY build)
open Murmur.app                          # run

swift run Murmur cleantest               # RuleCleaner + UserDictionary assertions
swift run Murmur selftest test_short.wav             # exercise the ASR path with no keypress
swift run Murmur selftest test_short.wav --offline   # same, with the network refused for the whole run
swift run Murmur render-ui <dir>         # render the popover to PNGs (light/dark × setup/ready/active)
```

There is no XCTest target. `cleantest` is the test suite — a table of
`(input, expected, note)` cases in `Cleanup/CleanerTest.swift`, exit code 1 on any
failure. Add a case there when touching `RuleCleaner` or `UserDictionary`. The dictionary
cases run against a fixed in-memory `UserDictionary`, never the user's own file.

`selftest` and `render-ui` are the headless verification paths — use them rather than
asking someone to hold a key or take a screenshot. `test_short.wav` (3.2s) and
`test_sample.wav` (13.5s) in the repo root are the clips the benchmarks were run on.

## Measured on the target machine (M1, 16GB, 2026-08-27)

Do not re-derive these; the model downloads take ~30 minutes. Full tables in
`docs/BENCHMARKS.md`.

| Model | 3.2s clip | 13.5s clip |
|---|---|---|
| whisper large-v3-turbo | — | 3.29s (unusable) |
| whisper small.en | 0.484s | 0.900s |
| **parakeet-tdt-0.6b-v2 (CoreML)** | **0.176–0.207s** | **0.293s** |

Parakeet is both faster and more accurate than whisper small.en, and CoreML via
FluidAudio is ~2x faster than the same model on MLX. whisper is not a fallback worth keeping.

LLM cleanup, same machine:
- `Qwen3-1.7B-4bit` — 0.939s, but **silently deletes whole clauses**. Rejected outright.
- `Qwen3-4B-4bit` — 2.655s, output quality genuinely good.

**Consequence:** there is no local model on M1 that is both fast enough and safe enough
for an inline cleanup pass. Cleanup is therefore tiered, and tier two is opt-in only.

Cold-process model load is 35–42s (CoreML recompiling for the Neural Engine). Known,
unresolved, once per launch. Warm load is 0.27s.

## Architecture

Two tiers, both fully local:

1. **Default (~0.3s)** — Parakeet + `RuleCleaner`. Deterministic, lossless, no LLM.
   `RuleCleaner` only removes what it can prove is noise (a fixed filler-word set),
   because the 1.7B benchmark showed that losing content is far worse than a stray "um".
2. **Polish key (~2.9s)** — Qwen3-4B rewrites the last dictation on explicit request.
   Latency is acceptable precisely because the user asked for it. *(not yet built)*

### The loop

`DictationController` owns the whole thing and is the only place the pieces meet:

```
HotKeyMonitor (CGEventTap, .flagsChanged, one modifier from `HotKey`)
  → AudioCapture (AVAudioEngine tap → AVAudioConverter → 16kHz mono Float)
  → Transcriber (actor; Parakeet TDT v2 via FluidAudio)
  → RuleCleaner.clean (fillers → capitalise → UserDictionary → terminal punctuation)
  → TextInjector (pasteboard + synthesised Cmd-V, clipboard restored after 200ms)
  → AppState.record
```

Things in the controller that look like bugs but are deliberate:

- The hotkey is armed **before** the models load. Audio captured while still loading is
  held in `pending` and transcribed the moment setup finishes, so a first-run user who
  speaks early is not silently ignored.
- A hold under 0.25s or under 1,600 samples is dropped — an accidental tap must not
  fire an empty transcription.
- `Transcriber.transcribe` constructs a fresh `TdtDecoderState` per call. The state
  carries LSTM context across streaming chunks; reusing it would bleed one dictation
  into the next. Do not "optimise" this away.
- A cleaned result of `""` or `"."` is discarded without injecting.

### Why each piece is the way it is

- **Parakeet, not Whisper.** Benchmarked on the target machine before committing.
  Parakeet TDT v2 via CoreML is both faster and more accurate than whisper small.en,
  and whisper large-v3-turbo is four times too slow to be usable. Whisper is not kept
  as a fallback because there is no case where it wins.
- **FluidAudio, not a Python sidecar.** The obvious route to Parakeet is
  `parakeet-mlx`, which would mean shipping a Python runtime and MLX inside the app
  bundle. FluidAudio runs the same model through CoreML in pure Swift, so Murmur is
  an ordinary 16MB Swift binary. It also turned out to be roughly twice as fast.
- **Pasteboard injection, not keystroke synthesis.** Synthesising each character is
  slow and several apps drop the events entirely. Writing to the pasteboard and
  sending one Cmd-V is universal; the clipboard round trip is 0.73ms.
- **Rule-based cleanup, not an LLM.** `RuleCleaner` only removes what it can prove
  is noise, then repairs the punctuation the removals stranded. It is lossless by
  construction. An LLM pass belongs behind an explicit keystroke, where the user
  has accepted the latency.

### Threading

`Transcriber` is an actor. `HotKeyMonitor`'s tap callback is a bare C function pointer
that cannot capture context, so the live instance is reached through a static weak
`active` reference and every delivery bounces to the main queue. `AudioCapture`
accumulates on the audio thread behind an `NSLock`. Everything UI-facing is `@MainActor`.
`main.swift` is top-level code under language mode 5, hence the
`MainActor.assumeIsolated` wrappers there.

### UI

`AppState` is the single source of truth. Its `Phase` enum (`starting`, `settingUp`,
`ready`, `recording`, `transcribing`, `failed`) drives both the menu bar icon
(`MenuBarController.render`) and the popover (`PopoverView`). Add state to `Phase`,
not to views. `recent` keeps the last three dictations. Settings (`hotKey`,
`launchAtLogin`, `theme`) live there too; `DictationController` subscribes to `hotKey`
and pushes it into the live event tap.

`Theme.swift` holds the design tokens (iris → magenta → coral gradient, per-scheme
text/surface colours) and `Fonts.register()`, which loads the bundled Bricolage
Grotesque. Every colour has both a light and a dark value; the visual language is
specified in `DESIGN.md` (Soft-product archetype, blur-in motion signature) and the
popover must keep the "Made by FintonLabs" affordance.

The popover is shown automatically on first launch (`hasLaunchedBefore` in
UserDefaults) so model download does not look like a hang. The 0.4s delay before
showing it is required — the status item has no window until the run loop turns.

## Filler stripping

`RuleCleaner` matches vocal noises as regex patterns, not a word list, so elongations
("uhhhh", "errrr", "aaaah") are caught without enumerating spellings. Two rules govern
what may be added:

1. **Only sounds that are never words.** "so", "well", "like", "right" and "oh" are
   deliberately absent — they carry meaning often enough that stripping them changes
   what the speaker said. Note "ooh" is matched as `o{2,}h*`, which leaves "oh" alone.
2. **A capitalised token mid-sentence is a proper noun and is kept.** "Ah" and "Er" are
   names. At a sentence start the capital carries no signal, so filler still goes.

`swift run Murmur cleantest` covers both directions. The negative cases matter more than
the positive ones: the risk is not missing an "um", it is eating a real word.

## Word list

`UserDictionary` applies literal term substitutions from
`~/Library/Application Support/Murmur/dictionary.json`, seeded on launch and re-read
whenever its mtime changes — editing it needs no restart. The book icon in the popover
opens it.

It exists because two classes of error are unfixable at the model level: terms the
model splits or cases wrongly ("pager duty" -> "PagerDuty"), and names that are
homophones of a commoner spelling ("Justin" -> "Justyn"). Parakeet will never emit the
rarer spelling on its own.

- Applied **after** `capitaliseSentences`, so the user's spelling wins. Run it earlier
  and sentence-start capitalisation turns "npm" into "Npm".
- One combined regex, matched back-to-front, so a substitution can never be re-matched
  by another rule in the same pass.
- Alternatives are sorted longest-first, or "pager duty pro" loses to "pager duty".
- Boundaries are lookarounds, not `\b`, which misbehaves on terms like "c++".
- A malformed JSON file is ignored rather than fatal — dictation keeps working.

## Things that will bite you

- **TCC grants are per bundle ID and per binary signature.** Run `Scripts/bundle.sh`
  after every build, or Accessibility silently stops working. Running the bare binary
  from `.build/` never gets a grant. If it is enabled and still broken, remove and
  re-add Murmur in System Settings → Accessibility.
- **Resources must travel into the bundle.** SwiftPM emits `.bundle` directories next to
  the binary; `bundle.sh` copies them into `Contents/Resources`. Skip that and
  `Bundle.module` finds nothing, which shows up as the UI silently falling back to the
  system font.
- **Text injection** uses pasteboard + synthesised Cmd-V, not per-character synthesis.
  Measured at 0.73ms to save and restore the clipboard, and it works in apps that drop
  synthetic keystrokes. Always restore the user's clipboard afterwards.
- **Secure Input**: when a password field is focused, `IsSecureEventInputEnabled()` is
  true and no app can inject. Detect and report it; there is no workaround.
- **Electron apps** (Slack, VS Code, Claude Desktop) expose no focused AX element —
  confirmed, `kAXErrorNoValue`. Injection works there, but reading surrounding text
  for context does not. Do not build features that assume AX context is available.
- The event tap gets disabled by the system on timeout; `HotKeyMonitor` re-arms it.
- `flagsChanged` carries no up/down bit — key state is inferred from whether the
  chosen modifier's flag survived the event.
- **The hotkey is a modifier, chosen from `HotKey`** and persisted in UserDefaults.
  Fn/Globe is excluded because a bare press fires the system emoji or dictation
  action on release; Shift because holding it is how capitals happen. The monitor
  reads `key` on every event and releases a held key when it changes, or a recording
  started on the old key would never end.
- **Launch at login is `SMAppService.mainApp`**, and `AppState` asks the system for
  the real status on launch rather than trusting a stored flag, because the user can
  remove the item in System Settings. It only works from inside `Murmur.app`; the bare
  binary reports not registered.
- **Murmur never checks for updates.** No network request of any kind is allowed, and
  that includes the releases API. About links to the website and releases page in the
  browser instead.

## Signing and release

`bundle.sh` discovers a "Developer ID Application" identity via `security find-identity`
and signs with hardened runtime and `Assets/Murmur.entitlements`; without one it falls
back to ad-hoc so the build still runs locally. The app version is the `VERSION`
variable at the top of `bundle.sh`. The bundle ID is `com.fintonlabs.murmur` and the
app is `LSUIElement` (no Dock icon).

A signed local build is **not** distributable — Gatekeeper rejects it as
"Unnotarized Developer ID" on any other Mac. `Scripts/release.sh <version>` is the only
thing that ships: it notarises and staples the app and the disk image separately,
verifies with `spctl`, then tags and publishes. Releases are cut locally, never in CI,
because the certificate and the `notarytool` keychain profile live on this machine.
Never cut a release unless asked in that message. See `docs/RELEASING.md`.

## Site

`site/index.html` is the landing page, deployed to GitHub Pages by
`.github/workflows/pages.yml` on any push to `main` that touches `site/**`. It shares the
design tokens in `Theme.swift`; keep the two in step.

The download button is baked with a direct link to the current disk image so it works
with no JavaScript, then upgraded client-side from the GitHub releases API. `release.sh`
rewrites the baked link and version on every release, so the page and the release
never drift; do not hand-edit the version there.

## Docs

`docs/BENCHMARKS.md` (every measurement), `docs/TROUBLESHOOTING.md` (permissions,
Secure Input, Electron), `docs/RELEASING.md` (the publish path), `DESIGN.md` (visual
language). Update them alongside the code they describe.

## Stack

Swift 6 (language mode 5), SwiftPM, macOS 14+, Apple Silicon. ASR via
[FluidAudio](https://github.com/FluidInference/FluidAudio) 0.15.6 — pure Swift
CoreML Parakeet, which is why there is no Python sidecar to distribute.
