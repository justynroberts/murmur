# Troubleshooting

## Nothing happens when I hold the key

First check which key it is: the panel shows it under Ready, and Settings lets you
pick a different modifier if your keyboard has no Right Option.

Almost always Accessibility permission. Murmur needs it twice over — to watch for
the hotkey and to insert text.

System Settings → Privacy & Security → Accessibility → enable **Murmur**.

**If it is already enabled and still broken**, remove the entry with the `−` button
and re-add it. macOS ties the grant to the binary's code signature, so a rebuild
invalidates it. Always run `Scripts/bundle.sh` after `swift build`; running the bare
executable from `.build/` will fail every time, because a grant needs a bundle ID.

## Text appears nowhere, or an error mentions Secure Input

A password field has focus. When macOS enables Secure Input, no application can
inject text — this is the OS protecting the field, and there is no workaround.
Murmur detects it via `IsSecureEventInputEnabled()` and reports it rather than
failing silently.

Some apps leave Secure Input on when they should not. To find the culprit:

```bash
ioreg -l -w 0 | grep SecureInput
```

## The first launch after boot takes ~35 seconds

Known, unresolved. CoreML recompiles the Parakeet model for the Neural Engine on a
cold process. It happens once per launch, not per dictation, and transcription
speed is unaffected. Warm loads take 0.27s.

## It heard me wrong

The model is English-only (Parakeet TDT v2). Accuracy degrades with background
noise, distance from the microphone, and heavy accents.

`RuleCleaner` deliberately does *not* attempt to fix mistranscriptions — it only
removes filler words it can positively identify. A local model was benchmarked for
this and rejected for silently deleting content; see `BENCHMARKS.md`.

## Context-aware formatting does not work in Slack / VS Code / Discord

Electron apps expose no focused element over the Accessibility API — confirmed,
`AXUIElementCopyAttributeValue` returns `kAXErrorNoValue`. Text insertion works
fine; reading the surrounding text to match tone does not. This is a platform
limitation, not a bug, and any feature that assumes AX context will not work there.

## Does any audio leave my Mac?

No. After models load, `ModelHub.offlineMode` is set to `true`, and any network
call throws `DownloadError.networkDisabled` instead of succeeding.

Verify it yourself:

```bash
swift run Murmur selftest test_short.wav --offline
```

That refuses the network for the entire run and still transcribes. The only time
Murmur touches the network is the one-off model download on first launch.

## Rebuilding from scratch

```bash
swift build -c release
./Scripts/bundle.sh release
```

Signing is automatic when a Developer ID certificate is present, and falls back to
ad-hoc so a machine without one still gets a runnable local build.
