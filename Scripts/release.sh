#!/usr/bin/env bash
# The only thing in this repository that ships anything.
#
# Releases are built here rather than in CI, because signing and notarising need
# the Developer ID certificate and the notarytool keychain profile, and those
# live on this machine. A GitHub runner has neither, so a release built there is
# ad-hoc signed — which tells whoever downloads it that the application is
# damaged.
#
#   Scripts/release.sh 0.3.0
#   Scripts/release.sh 0.3.0 --dry-run          # everything except tag and publish
#   Scripts/release.sh 0.3.0 --notes NOTES.md   # release body; otherwise generated
#
# It refuses rather than guesses: a dirty tree, a version that already exists, a
# failing test, or an unnotarised disk image all stop it before anything becomes
# visible.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

VERSION="" ; DRY_RUN=0 ; NOTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --notes)   shift; NOTES="$1" ;;
    *) [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && VERSION="$1" ;;
  esac
  shift
done

red()   { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
dim()   { printf '\033[2m%s\033[0m'  "$1"; }
step()  { printf '\n%s %s\n' "$(green ▸)" "$1"; }
die()   { printf '\n%s %s\n' "$(red ✗)" "$1" >&2; [ $# -gt 1 ] && printf '%s\n' "$(dim "  $2")" >&2; exit 1; }

[ -n "$VERSION" ] || die "no version given" "Scripts/release.sh 0.3.0 [--dry-run] [--notes file]"
[ -z "$NOTES" ] || [ -f "$NOTES" ] || die "notes file not found: $NOTES"

PROFILE="${NOTARY_KEYCHAIN_PROFILE:-notarytool}"
APP="Murmur.app"
DIST="dist"
DMG="$DIST/Murmur-$VERSION.dmg"

# ---- refuse before building anything ---------------------------------------

step "Checking the tree is clean"
[ -z "$(git status --porcelain)" ] || \
  die "the working tree has uncommitted changes" \
      "a release must correspond to a commit, or nobody can tell what shipped"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" = "main" ] || printf '%s\n' "$(dim "  on $BRANCH, not main — continuing, but this is unusual")"

step "Checking the version is new"
git fetch --tags --quiet origin
git tag --list | grep -qx "v$VERSION" && die "v$VERSION already exists as a tag" "pick a later version"

step "Checking the signing identity is present"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')"
[ -n "$IDENTITY" ] || \
  die "no Developer ID certificate in the keychain" \
      "without it the build is ad-hoc signed and cannot be distributed"

# Checked now rather than after the build, because the failure is the same
# either way and finding out early costs nothing. A 403 here is the Apple
# developer agreement or membership, not this machine — see docs/RELEASING.md.
step "Checking notarytool credentials"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || \
  die "notarytool refused the keychain profile '$PROFILE'" \
      "xcrun notarytool store-credentials \"$PROFILE\" --apple-id <id> --team-id <team>  (or: the developer agreement needs accepting)"

# ---- prove it works before making it visible -------------------------------

step "Running the cleaner tests"
swift run -c release Murmur cleantest >/dev/null || die "cleantest failed" "a release with failing tests is not a release"

step "Setting the version to $VERSION"
# A dry run has to leave the tree exactly as it found it. Without this the bump
# survives, the next dry run sees a dirty tree, and refuses.
[ "$DRY_RUN" = "1" ] && trap 'git checkout -- Scripts/bundle.sh site/index.html 2>/dev/null || true' EXIT
sed -i '' -E "s|^VERSION=\"[^\"]*\"|VERSION=\"$VERSION\"|" Scripts/bundle.sh
grep -q "^VERSION=\"$VERSION\"" Scripts/bundle.sh || die "could not set VERSION in Scripts/bundle.sh"

# The landing page bakes in a direct link to the current disk image so the
# download works with no JavaScript; keep it pointing at this release.
sed -i '' -E \
  -e "s|releases/download/v[0-9.]+/Murmur-[0-9.]+\.dmg|releases/download/v$VERSION/Murmur-$VERSION.dmg|g" \
  -e "s|releases/tag/v[0-9.]+|releases/tag/v$VERSION|g" \
  -e "s|(dl-ver(sion)?\">)[0-9.]+|\1$VERSION|g" site/index.html
grep -q "Murmur-$VERSION.dmg" site/index.html || die "could not set the download link in site/index.html"

step "Building and signing (universal: arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 2>&1 | tail -1
./Scripts/bundle.sh release | sed 's/^/  /'
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Murmur")"
case "$ARCHS" in *x86_64*arm64*|*arm64*x86_64*) echo "  slices: $ARCHS" ;;
  *) die "the bundle is not universal" "got: $ARCHS" ;; esac

# The one machine a release is never tested on is a machine without this
# checkout. SwiftPM's Bundle.module accessor falls back to an absolute path
# into .build here, so a resource lookup that only works because of it passes
# every local test and crashes at launch for everyone else (0.8.0 did). Launch
# the built app headlessly with .build out of the way; it must render the UI.
# Run a *copy*: launching a bundle tags it with com.apple.provenance, after
# which stapler cannot write its ticket into it (error 73).
step "Launching a copy of the built app with .build hidden"
SMOKE="$(mktemp -d)"
ditto "$APP" "$SMOKE/Murmur.app"
mv .build .build.release-smoke
trap 'mv .build.release-smoke .build 2>/dev/null || true' EXIT
if ! "$SMOKE/Murmur.app/Contents/MacOS/Murmur" render-ui "$SMOKE" >"$SMOKE/log" 2>&1 || ! ls "$SMOKE"/*.png >/dev/null 2>&1; then
  mv .build.release-smoke .build
  die "the built app does not launch without this checkout's .build directory" "$(tail -3 "$SMOKE/log")"
fi
# The Intel slice too, under Rosetta, when this Mac has it. Not a test of
# CoreML on Intel hardware, but it proves the x86_64 code path launches and
# draws — the class of failure a build machine never sees on its own.
if arch -x86_64 /usr/bin/true 2>/dev/null; then
  rm -f "$SMOKE"/*.png
  if ! arch -x86_64 "$SMOKE/Murmur.app/Contents/MacOS/Murmur" render-ui "$SMOKE" >"$SMOKE/log-x86" 2>&1 || ! ls "$SMOKE"/*.png >/dev/null 2>&1; then
    mv .build.release-smoke .build
    die "the x86_64 slice does not launch under Rosetta" "$(tail -3 "$SMOKE/log-x86")"
  fi
  echo "  x86_64 slice launches and renders under Rosetta"
else
  echo "  (no Rosetta here; x86_64 slice not exercised)"
fi
mv .build.release-smoke .build
trap - EXIT
[ "$DRY_RUN" = "1" ] && trap 'git checkout -- Scripts/bundle.sh site/index.html 2>/dev/null || true' EXIT
rm -rf "$SMOKE"
echo "  launches and renders without .build"

rm -rf "$DIST" && mkdir -p "$DIST"

# The app and the disk image each need their own ticket — the image does not
# inherit the app's. Notarise the app first so that the copy a user drags into
# /Applications carries a stapled ticket and passes Gatekeeper offline.
step "Notarising the app"
ditto -c -k --keepParent "$APP" "$DIST/Murmur-$VERSION.zip"
xcrun notarytool submit "$DIST/Murmur-$VERSION.zip" --keychain-profile "$PROFILE" --wait 2>&1 | sed 's/^/  /' | tee "$DIST/notary-app.log"
grep -q "status: Accepted" "$DIST/notary-app.log" || \
  die "Apple did not accept the app" "xcrun notarytool log <id> --keychain-profile $PROFILE"
xcrun stapler staple "$APP" >/dev/null || die "could not staple the app"
rm "$DIST/Murmur-$VERSION.zip"

step "Building the disk image"
# A previous verification can leave a volume called Murmur mounted, and
# hdiutil then fails building a new one of the same name with a misleading
# "operation not permitted". Detach anything of ours first.
for v in /Volumes/Murmur*; do
  [ -d "$v" ] && hdiutil detach "$v" -force -quiet 2>/dev/null && echo "  detached stale $v"
done
true
STAGING="$DIST/staging"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$APP"
ln -s /Applications "$STAGING/Applications"
# Versioned volume name: macOS refuses writes under a /Volumes/<name> path an
# app was once launched from ("operation not permitted"), and every user has
# launched from /Volumes/Murmur. It also lets two versions mount side by side.
hdiutil create -volname "Murmur $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null || \
  die "hdiutil could not build the disk image" "run it without >/dev/null to see why"
rm -rf "$STAGING"

# Order is sign → notarise → staple. Signing after stapling destroys the ticket.
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

step "Notarising the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1 | sed 's/^/  /' | tee "$DIST/notary-dmg.log"
grep -q "status: Accepted" "$DIST/notary-dmg.log" || \
  die "Apple did not accept the disk image" "xcrun notarytool log <id> --keychain-profile $PROFILE"
xcrun stapler staple "$DMG" >/dev/null || die "could not staple the disk image"

# ---- verify the artifacts, not the intention -------------------------------

step "Verifying what a download will see"
xcrun stapler validate "$DMG" >/dev/null 2>&1 || die "$DMG has no notarisation ticket stapled"

ASSESSMENT=$(spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 || true)
case "$ASSESSMENT" in
  *"Notarized Developer ID"*) echo "  $(basename "$DMG") — Gatekeeper accepts it" ;;
  *) die "Gatekeeper does not accept $(basename "$DMG")" "$ASSESSMENT" ;;
esac

MNT=$(hdiutil attach -nobrowse -readonly "$DMG" | grep Volumes | awk -F'\t' '{print $NF}')
ASSESSMENT=$(spctl -a -vvv -t exec "$MNT/$APP" 2>&1 || true)
STAPLED=$(xcrun stapler validate "$MNT/$APP" 2>&1 | tail -1)
hdiutil detach "$MNT" -quiet
case "$ASSESSMENT" in
  *"Notarized Developer ID"*) echo "  $APP inside it — Gatekeeper accepts it" ;;
  *) die "Gatekeeper does not accept the app inside the image" "$ASSESSMENT" ;;
esac
case "$STAPLED" in
  *"worked"*) echo "  $APP inside it — ticket stapled" ;;
  *) die "the app inside the image has no stapled ticket" "$STAPLED" ;;
esac

if [ "$DRY_RUN" = "1" ]; then
  printf '\n%s %s is built and verified. Nothing was tagged or published.\n  %s\n\n' \
    "$(green ✓)" "$VERSION" "$(dim "artifact: $DMG; tree left untouched")"
  exit 0
fi

# ---- only now does any of it become visible --------------------------------

step "Committing, tagging and publishing"
if [ -n "$(git status --porcelain)" ]; then
  git add Scripts/bundle.sh site/index.html
  git commit -q -m "Release $VERSION"
fi
git push -q origin "$BRANCH"
git tag -a "v$VERSION" -m "Murmur $VERSION"
git push -q origin "v$VERSION"

NOTES_ARG=(--generate-notes)
[ -n "$NOTES" ] && NOTES_ARG=(--notes-file "$NOTES")

gh release create "v$VERSION" "$DMG" --title "Murmur $VERSION" "${NOTES_ARG[@]}"

printf '\n%s Murmur %s published.\n\n' "$(green ✓)" "$VERSION"
