#!/bin/sh
# Run Script build phase "Build number": writes CFBundleVersion = number of commits reachable from HEAD
# (`git rev-list --count HEAD`) into the Info.plist of the PRODUCT, not the source tree.
#
# Ordering: the phase declares that Info.plist as an input, so it runs after ProcessInfoPlistFile (which
# would otherwise overwrite the number) and before the build's own CodeSign step.
#
# Stale signature: Xcode does not know a script touched the bundle, and on an incremental build it can
# skip CodeSign although the plist changed (Info.plist regenerated with the same bytes, then patched here).
# So when the bundle already carries a signature that this edit invalidated, it is re-sealed here with the
# same identity and the metadata it already had (entitlements, runtime flag). On a first build there is no
# signature yet and nothing to do: CodeSign comes later.
#
# Never fails the build: no git, no repository (a source archive) or a shallow clone ends in the fallback,
# CURRENT_PROJECT_VERSION. CFBundleVersion must stay digits and dots. MARKETING_VERSION
# (CFBundleShortVersionString) is left to the project settings.

APP="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

if [ ! -f "$PLIST" ]; then
    echo "warning: build number: $PLIST does not exist, CFBundleVersion left as generated"
    exit 0
fi

N=""
if command -v git >/dev/null 2>&1; then
    N=$(git -C "${SRCROOT}" rev-list --count HEAD 2>/dev/null)
fi
case "$N" in
    ''|*[!0-9]*) N="" ;;
esac
if [ -z "$N" ]; then
    N="${CURRENT_PROJECT_VERSION:-1}"
    case "$N" in
        ''|*[!0-9.]*) N="1" ;;
    esac
    echo "note: build number: git unavailable, falling back to $N"
fi

CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST" 2>/dev/null)
if [ "$CURRENT" != "$N" ]; then
    if ! /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $N" "$PLIST" 2>/dev/null \
       && ! /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $N" "$PLIST" 2>/dev/null; then
        echo "warning: build number: could not write CFBundleVersion into $PLIST"
        exit 0
    fi
fi
echo "note: build number: CFBundleVersion = $N"

# Re-seal only if there was a signature and the edit broke it.
if [ -d "$APP/Contents/_CodeSignature" ] && [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] \
   && ! /usr/bin/codesign --verify --strict "$APP" >/dev/null 2>&1; then
    ID="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    if /usr/bin/codesign --force --sign "$ID" --timestamp=none \
         --preserve-metadata=identifier,entitlements,requirements,flags,runtime "$APP" >/dev/null 2>&1; then
        echo "note: build number: bundle re-sealed after the edit"
    else
        echo "warning: build number: could not re-seal the bundle; the build's own CodeSign step will redo it"
    fi
fi
exit 0
