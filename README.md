<div align="center">
  <img src="Assets/icon.svg" width="128" alt="Murmur">
  <h1>Murmur</h1>
  <p><strong>Offline push-to-talk dictation for macOS.</strong></p>
</div>

Hold **Right Option**, speak, release — cleaned-up text appears in whatever app you
were typing in.

Nothing leaves your Mac. No account, no subscription, no network access after the
one-time model download.

## Why

Wispr Flow costs about $15/month and superwhisper about $84/year, and both send
your audio to a server. On Apple Silicon the models are now fast enough to run
locally, so the subscription is buying you latency and a privacy problem.

Measured on an M1 MacBook Pro, a short utterance transcribes in **0.176s** —
faster than the network round trip a cloud service pays before its model even
starts.

## Install

Requires macOS 14+ on Apple Silicon.

Download the latest disk image from
[Releases](https://github.com/justynroberts/murmur/releases/latest) and drag
Murmur into Applications. Or build it yourself:

```bash
git clone https://github.com/justynroberts/murmur.git && cd murmur
swift build -c release
./Scripts/bundle.sh release
open Murmur.app
```

Grant **Accessibility** and **Microphone** when prompted. The first launch
downloads the Parakeet model (~2.3GB) once, after which the network is locked off
for good.

Releases are signed with a Developer ID and notarised by Apple, so they open
without a Gatekeeper warning.

## How it works

```
Right Option held    →  CGEventTap  →  AVAudioEngine @ 16kHz
Right Option released →  Parakeet TDT v2 (CoreML)  →  rule-based cleanup
                      →  pasteboard + Cmd-V into the frontmost app
```

Transcription runs on the Neural Engine via
[FluidAudio](https://github.com/FluidInference/FluidAudio) — pure Swift, no Python
sidecar, a 16MB binary.

Cleanup is deliberately conservative. A local LLM pass was benchmarked and rejected
for the default path: Qwen3-1.7B was fast but **silently deleted whole clauses**,
and Qwen3-4B preserved meaning but took 2.7 seconds. Leaving a stray "um" in is far
better than losing something you said, so the default pass only removes what it can
prove is noise.

## Verify the offline claim

```bash
swift run Murmur selftest test_short.wav --offline
```

Refuses the network for the whole run and still transcribes.

## Documentation

| | |
|---|---|
| [Architecture](docs/ARCHITECTURE.md) | How the loop fits together, and why each piece is the way it is |
| [Benchmarks](docs/BENCHMARKS.md) | Every measurement behind the design decisions |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Permissions, Secure Input, Electron limitations |
| [Design](DESIGN.md) | Visual language for the menu bar interface |
| [Releasing](docs/RELEASING.md) | Signing, notarisation, and the one command that publishes |

## Word list

Terms the model gets wrong — product names it splits, names spelled the common way —
are fixed by a substitution list at
`~/Library/Application Support/Murmur/dictionary.json`:

```json
{
  "pager duty": "PagerDuty",
  "justin": "Justyn"
}
```

Open it from the book icon in the panel. Changes apply on the next dictation, no
restart needed.

## Status

The core loop, menu bar interface and word list are done. Still to come: an
opt-in "polish" key that runs a local LLM over the last dictation.

## Licence

MIT — Copyright (c) fintonlabs.com
