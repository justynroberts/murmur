# Architecture

## The loop

```
Right Option held
   │
   ├─ HotKeyMonitor      CGEventTap on .flagsChanged, session-wide
   ├─ AudioCapture       AVAudioEngine tap → AVAudioConverter → 16kHz mono Float
   │
Right Option released
   │
   ├─ Transcriber        Parakeet TDT v2 (CoreML, via FluidAudio)
   ├─ RuleCleaner        deterministic filler/punctuation pass
   └─ TextInjector       pasteboard + synthesised Cmd-V, clipboard restored
```

Measured end to end on an M1: **0.176–0.207s** for a 3.2s utterance.

## Why each piece is the way it is

### Parakeet, not Whisper

Benchmarked on the target machine before committing (see `BENCHMARKS.md`).
Parakeet TDT v2 via CoreML is both faster and more accurate than whisper
small.en, and whisper large-v3-turbo is four times too slow to be usable.
Whisper is not kept as a fallback because there is no case where it wins.

### FluidAudio, not a Python sidecar

The obvious route to Parakeet is `parakeet-mlx`, which would mean shipping a
Python runtime and MLX inside the app bundle. FluidAudio runs the same model
through CoreML in pure Swift, so Murmur is an ordinary 16MB Swift binary.
It also turned out to be roughly twice as fast as the MLX path.

### A fresh decoder state per utterance

`TdtDecoderState` carries LSTM hidden state across chunks so that streaming
transcription keeps linguistic context across a chunk boundary. Dictations are
independent, so reusing it would let one dictation's context bleed into the next.
`Transcriber.transcribe` constructs a new state every call. This is deliberate —
do not "optimise" it away.

### Pasteboard injection, not keystroke synthesis

Synthesising each character is slow and several apps drop the events entirely.
Writing to the pasteboard and sending one Cmd-V is universal. The user's
clipboard is snapshotted and restored 200ms later; the round trip measured
**0.73ms**, so the cost is irrelevant.

### Rule-based cleanup, not an LLM

A local LLM pass was benchmarked and rejected for the default path. Qwen3-1.7B
runs in 0.939s but **silently deletes whole clauses**; Qwen3-4B preserves content
but takes 2.655s, which is far too long to sit between speaking and seeing text.

`RuleCleaner` therefore only removes what it can prove is noise — a fixed set of
filler words — then repairs the punctuation the removals stranded. It is lossless
by construction. An LLM pass belongs behind an explicit keystroke, where the user
has accepted the latency.

## Offline guarantee

`Transcriber.load` sets `ModelHub.offlineMode = true` immediately after the models
are in memory. Any subsequent network call throws `DownloadError.networkDisabled`
rather than quietly succeeding, so a future change that accidentally introduces
one fails loudly instead of leaking audio.

Verified: `swift run Murmur selftest <file> --offline` transcribes correctly with
the network refused outright.

## Threading

`Transcriber` is an actor. `HotKeyMonitor`'s tap callback is a bare C function
pointer that cannot capture context, so the live instance is reached through a
static weak reference and all delivery is bounced to the main queue.
`AudioCapture` accumulates on the audio thread behind an `NSLock`.
