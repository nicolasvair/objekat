#!/bin/sh
# Run Script build phase "Build number": writes CFBundleVersion = number of commits reachable from HEAD
# into the Info.plist of the PRODUCT (not the source tree), before the code signature seals the bundle.
#
# Never fails the build: no git, no repository (a source archive), a shallow clone or a plist that is not
# there yet all end in the fallback, CURRENT_PROJECT_VERSION. CFBundleVersion has to stay digits and dots.
# MARKETING_VERSION (CFBundleShortVersionString) is left to the project settings.

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
    echo "note: build number: git unavailable, falling back to CURRENT_PROJECT_VERSION ($N)"
fi
case "$N" in
    ''|*[!0-9.]*) N="1" ;;
esac

if /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $N" "$PLIST" 2>/dev/null; then
    :
elif /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $N" "$PLIST" 2>/dev/null; then
    :
else
    echo "warning: build number: could not write CFBundleVersion into $PLIST"
fi
echo "note: build number: CFBundleVersion = $N"
exit 0
