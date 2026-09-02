# CLAUDE.md

## What this is

Murmur — offline push-to-talk dictation for macOS. Hold Right Option, speak, release,
and cleaned-up text lands in whatever app has focus. A free replacement for
Wispr Flow (~$15/mo) and superwhisper (~$84/yr).

**Non-negotiable: nothing ever leaves the machine.** No cloud fallback, no telemetry,
no opt-in network path. `Transcriber.lockOffline()` sets `ModelHub.offlineMode = true`
after models load, so any later network attempt throws instead of silently succeeding.
Keep it that way — the offline guarantee is the product.

## Measured on the target machine (M1, 16GB, 2026-08-27)

Do not re-derive these; the model downloads take ~30 minutes.

| Model | 3.2s clip | 13.5s clip |
|---|---|---|
| whisper large-v3-turbo | — | 3.29s (unusable) |
| whisper small.en | 0.484s | 0.900s |
| **parakeet-tdt-0.6b-v2** | **0.296s** | **0.628s** |

Parakeet is both faster and more accurate than whisper small.en. whisper is not a
fallback worth keeping.

LLM cleanup, same machine:
- `Qwen3-1.7B-4bit` — 0.939s, but **silently deletes whole clauses**. Rejected outright.
- `Qwen3-4B-4bit` — 2.655s, output quality genuinely good.

**Consequence:** there is no local model on M1 that is both fast enough and safe enough
for an inline cleanup pass. Cleanup is therefore tiered, and tier two is opt-in only.

## Architecture

Two tiers, both fully local:

1. **Default (~0.3s)** — Parakeet + `RuleCleaner`. Deterministic, lossless, no LLM.
   `RuleCleaner` only removes what it can prove is noise (a fixed filler-word set),
   because the 1.7B benchmark showed that losing content is far worse than a stray "um".
2. **Polish key (~2.9s)** — Qwen3-4B rewrites the last dictation on explicit request.
   Latency is acceptable precisely because the user asked for it. *(not yet built)*

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
whenever its mtime changes — editing it needs no restart.

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

- **Text injection** uses pasteboard + synthesised Cmd-V, not per-character synthesis.
  Measured at 0.73ms to save and restore the clipboard, and it works in apps that drop
  synthetic keystrokes. Always restore the user's clipboard afterwards.
- **Secure Input**: when a password field is focused, `IsSecureEventInputEnabled()` is
  true and no app can inject. Detect and report it; there is no workaround.
- **Electron apps** (Slack, VS Code, Claude Desktop) expose no focused AX element —
  confirmed, `kAXErrorNoValue`. Injection works there, but reading surrounding text
  for context does not. Do not build features that assume AX context is available.
- **TCC grants are per bundle ID and per binary signature.** Run `Scripts/bundle.sh`
  after every build, or Accessibility silently stops working.
- The event tap gets disabled by the system on timeout; `HotKeyMonitor` re-arms it.

## Commands

```bash
swift build                          # compile
swift run Murmur cleantest           # RuleCleaner assertions (run after touching it)
./Scripts/bundle.sh                  # wrap in Murmur.app (do this after every build)
open Murmur.app                      # run
swift run Murmur selftest audio.wav  # exercise the ASR path with no keypress
```

`selftest` is the headless verification path — use it rather than asking someone to
hold a key.

## Stack

Swift 6 (language mode 5), SwiftPM, macOS 14+. ASR via
[FluidAudio](https://github.com/FluidInference/FluidAudio) 0.15.6 — pure Swift
CoreML Parakeet, which is why there is no Python sidecar to distribute.
