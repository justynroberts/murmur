# Benchmarks

All figures measured on the target machine — **MacBook Pro, Apple M1 (8-core), 16GB,
macOS 15.6.1** — on 2026-08-27. Re-deriving these costs roughly 30 minutes of model
downloads, so they are recorded rather than re-measured.

Test audio was macOS `say` output, which is cleaner than real speech. Absolute
accuracy is therefore optimistic; the relative ranking holds.

## Speech recognition

Warm, best of three runs.

| Model | Runtime | 3.2s clip | 13.5s clip |
|---|---|---|---|
| whisper large-v3-turbo | MLX | — | 3.29s |
| whisper small.en | MLX | 0.484s | 0.900s |
| parakeet-tdt-0.6b-v2 | MLX | 0.296s | 0.628s |
| **parakeet-tdt-0.6b-v2** | **CoreML (FluidAudio)** | **0.176–0.207s** | **0.293s** |

Two conclusions:

- **whisper large-v3-turbo is unusable here.** 3.29s of silence after you stop
  speaking. Not a tuning problem.
- **CoreML is roughly twice as fast as MLX** for the same model, and more accurate
  in practice — on the short clip MLX Parakeet heard *"when it's lived"* where
  CoreML correctly produced *"when it's live"*.

whisper small.en also misheard *"and uh make sure"* as *"and I'll make sure"*,
which is the class of error that erodes trust fastest.

## Model load

| Condition | Time |
|---|---|
| First run (download ~2.3GB) | 387s |
| Warm | 0.27s |
| Cold process, models cached | 35–42s |

The cold-process figure is CoreML recompiling for the Neural Engine. It is a
per-launch cost, not per-dictation, and it does not affect transcription speed.
**Unresolved** — see `TROUBLESHOOTING.md`.

## LLM cleanup

Rewriting a dictated sentence: removing fillers, resolving a self-correction
("Tuesday — no sorry, Wednesday"), fixing grammar. 120 max tokens, greedy.

| Model | Time | Outcome |
|---|---|---|
| Qwen3-1.7B-4bit | 0.939s | **Silently deleted a whole clause.** Rejected. |
| Qwen3-4B-4bit | 2.655s | Content preserved, genuinely good output. |

Both resolved the self-correction correctly, which is the hard part.

**The finding that shaped the architecture:** on M1 there is no local model that is
both fast enough and safe enough for an inline cleanup pass. The 1.7B is fast and
lossy; the 4B is accurate and slow. Hence tiering, with the LLM behind an explicit
keystroke.

## Input injection

| Operation | Time |
|---|---|
| Pasteboard save + restore | 0.73ms avg, 8.79ms max |

Negligible, which is what makes clipboard-based injection viable.
