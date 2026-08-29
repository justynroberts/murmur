# Murmur

Offline push-to-talk dictation for macOS. Hold **Right Option**, speak, release —
cleaned-up text appears in whatever app you were typing in.

Nothing leaves your Mac. No account, no subscription, no network access after the
one-time model download.

## Why

Wispr Flow costs about $15/month and superwhisper about $84/year, and both send your
audio to a server. On Apple Silicon the models are fast enough to run locally, so the
subscription buys you latency and a privacy problem.

Measured on an M1 MacBook Pro, transcription of a short utterance takes **0.296s** —
faster than the network round trip a cloud service pays before its model even starts.

## Status

Early. The core loop works: hotkey, capture, transcription, cleanup, insertion.

## Requirements

macOS 14+, Apple Silicon.

## Build

```bash
swift build
./Scripts/bundle.sh
open Murmur.app
```

Grant Accessibility and Microphone when prompted. The first launch downloads the
Parakeet model (~2.3GB) once, then the network is locked off for good.

## Licence

MIT
