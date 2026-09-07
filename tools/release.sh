#!/bin/bash
# Build, sign, notarise and package an OBJEKAT release.
#
# The repository signs ad hoc on purpose, so that anyone can build with no Apple
# account (see CLAUDE.md). This script does NOT change that: it builds ad hoc like
# everybody else, then re-signs the built .app with a Developer ID identity passed
# on the command line. Nothing about the signing identity is ever written into
# project.pbxproj.
#
# What actually removes the Gatekeeper error on a downloaded app is the pair
# "Developer ID signature + Apple notarisation", not the signature alone. Hence
# --notary-profile, and hence the stapling at the end: a stapled app opens with no
# network round-trip and no right-click.
#
# Usage:
#   tools/release.sh --version=0.1.0 --notary-profile=objekat-notary
#   tools/release.sh --version=0.1.0 --skip-notarize      # dry run, signature only
#
# --version is what goes into the app's Info.plist, so it stays numeric. --label
# is what names the zips, and defaults to --version; pass it when the tag carries
# something Info.plist will not take, as in --version=0.1.0 --label=0.1.0-alpha.
#
# The notary profile is created ONCE, by a human, and stores its own credentials:
#   xcrun notarytool store-credentials objekat-notary \
#       --apple-id <apple id> --team-id 8ZMVCPUWKW --password <app-specific password>

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=""
LABEL=""
IDENTITY=""
NOTARY_PROFILE=""
SKIP_NOTARIZE=0
OUT_DIR="build/release"

for arg in "$@"; do
  case "$arg" in
    --version=*)        VERSION="${arg#*=}" ;;
    --label=*)          LABEL="${arg#*=}" ;;
    --identity=*)       IDENTITY="${arg#*=}" ;;
    --notary-profile=*) NOTARY_PROFILE="${arg#*=}" ;;
    --out=*)            OUT_DIR="${arg#*=}" ;;
    --skip-notarize)    SKIP_NOTARIZE=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[ -n "$VERSION" ] || { echo "--version=X.Y.Z is required" >&2; exit 2; }
[ -n "$LABEL" ] || LABEL="$VERSION"

# ---------------------------------------------------------------- preflight

if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning \
             | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi

if [ -z "$IDENTITY" ]; then
  cat >&2 <<'MSG'
No "Developer ID Application" certificate in the keychain.

An "Apple Development" certificate is NOT enough: it only runs on registered
development machines and does nothing for a downloaded app. The certificate has
to be created on the Apple developer portal by an Account Holder or Admin of the
team that lends the account, then installed here (or imported from a .p12).

Until it exists this script cannot produce anything shippable, so it stops here
rather than build for nothing.
MSG
  exit 1
fi

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  [ -n "$NOTARY_PROFILE" ] || {
    echo "--notary-profile=<name> is required (or pass --skip-notarize for a dry run)" >&2
    exit 2; }
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
    echo "notarytool cannot read the keychain profile '$NOTARY_PROFILE'." >&2
    echo "Create it once with 'xcrun notarytool store-credentials'." >&2
    exit 1; }
fi

echo "identity : $IDENTITY"
echo "version  : $VERSION (assets named $LABEL)"
echo "notarise : $([ "$SKIP_NOTARIZE" -eq 1 ] && echo no || echo "yes ($NOTARY_PROFILE)")"
echo

ENTITLEMENTS="objekat/objekat.entitlements"
mkdir -p "$OUT_DIR"

# ------------------------------------------------------------------ per arch

for ARCH in arm64 x86_64; do
  echo "=== $ARCH ==============================================================="

  ARCHIVE="$OUT_DIR/objekat-$ARCH.xcarchive"
  rm -rf "$ARCHIVE"

  xcodebuild archive \
    -project objekat.xcodeproj \
    -scheme objekat \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    | tail -5

  APP="$ARCHIVE/Products/Applications/objekat.app"
  [ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }

  # Sign the nested code innermost-first, then the app itself. --deep is
  # deprecated for signing and gets the entitlements wrong on nested bundles.
  echo "--- signing"
  find "$APP/Contents" \( -name "*.framework" -o -name "*.dylib" -o -name "*.xpc" \
                          -o -name "*.appex" -o -name "*.bundle" \) -depth -print0 2>/dev/null \
  | while IFS= read -r -d '' NESTED; do
      codesign --force --sign "$IDENTITY" --options runtime --timestamp "$NESTED"
    done

  codesign --force --sign "$IDENTITY" --options runtime --timestamp \
           --entitlements "$ENTITLEMENTS" "$APP"

  codesign --verify --strict --verbose=2 "$APP"

  # ditto is what preserves the signature through the round trip.
  ZIP="$OUT_DIR/objekat-$LABEL-$ARCH.zip"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

  if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    echo "--- notarising (this waits on Apple)"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

    # The ticket is stapled to the .app, never to the zip, so the zip is rebuilt
    # afterwards. A stapled app opens with no network round trip.
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    xcrun stapler validate "$APP"
  fi

  echo "--- Gatekeeper verdict"
  spctl --assess --type execute --verbose=4 "$APP" || true
  echo "=> $ZIP"
  echo
done

echo "Done. Assets in $OUT_DIR/"
