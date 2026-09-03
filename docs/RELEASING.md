# Releasing

One command, run on the machine that holds the Developer ID certificate and the
`notarytool` keychain profile:

```bash
Scripts/release.sh 0.3.0 --dry-run --notes notes.md   # build, notarise, verify; publish nothing
Scripts/release.sh 0.3.0 --notes notes.md             # the same, then tag and publish
```

It refuses a dirty tree, an existing tag, a missing certificate, a missing
notary profile, or a failing `cleantest`. It writes the version into
`Scripts/bundle.sh`, builds release, signs, notarises the **app** and staples it,
builds the disk image, signs, notarises and staples **that**, then checks the
result the way Gatekeeper will before anything is tagged.

The disk image lands in `dist/`. Without `--notes` the GitHub release body is
generated from commits.

## Why it is shaped like this

- **Not in CI.** A GitHub runner has neither the certificate nor the keychain
  profile, so a tag-triggered workflow publishes an ad-hoc build that tells
  people the app is damaged. Do not move signing there.
- **Two tickets.** The app and the disk image are notarised separately; the image
  does not inherit the app's ticket. The app is stapled before it goes into the
  image so the copy dragged into `/Applications` passes Gatekeeper offline.
- **Sign → notarise → staple.** Signing after stapling destroys the ticket.
- **A 403 from notarytool** ("required agreement is missing or has expired") is
  the Apple developer account, not this machine — a new licence agreement or a
  lapsed membership. Only the account holder can clear it at
  developer.apple.com. Signing keeps working throughout, which is why the script
  checks notarisation before building rather than after.

## One-time setup on a new machine

```bash
xcrun notarytool store-credentials notarytool --apple-id <apple id> --team-id 2H574B6N62
```

Uses an app-specific password from appleid.apple.com. It goes into the keychain,
never into a script, an environment variable or shell history.
