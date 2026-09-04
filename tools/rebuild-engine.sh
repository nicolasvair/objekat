#!/usr/bin/env bash
#
# Rebuilds OBJEKAT's audio engine from the archives in engine-patches/3.5/.
#
# Why this script exists: it is the SAFETY NET, not the way in. Since 3 September 2026 the
# `tracktion_engine/` submodule points at a fork that carries the patched branch, and a plain
# `git clone --recurse-submodules` brings the engine down on its own. Before that, the gitlink
# named a branch pushed nowhere, and a third-party clone failed with:
#
#     fatal: remote error: upload-pack: not our ref d74e7b5…
#
# Should that come back — the fork moved, was renamed, or went private — the engine is
# REbuilt here: the pinned official bases plus the series of patches, whole and in order.
#
# Where it clones from: the URL in .gitmodules (the fork) by default, since that is a plain
# clone of Tracktion and holds the pinned base. If it is unreachable, the script falls back on
# Tracktion's OFFICIAL repository by itself — the base commit lives there too, and the patches
# do the rest. So the rebuild holds even if every fork disappeared.
#
# Usage:
#     tools/rebuild-engine.sh [--force] [--patches-dir=engine-patches/3.5] [--tracktion-url=URL]
#
#     --force            overwrites an `objekat-patches-3.5` branch already present in the
#                        submodules.
#     --ssh              keeps the SSH URLs as they are (by default they are switched to HTTPS:
#                        the tracktion .gitmodules names juce as `git@github.com:`, which
#                        requires an SSH key registered on GitHub — needless just to read the
#                        repository).
#     --tracktion-url=   clones tracktion from this URL instead of the one in .gitmodules.
#
# No effect outside this machine: no push, nothing written outside the repository.

set -euo pipefail

BRANCH="objekat-patches-3.5"
TE_DIR="tracktion_engine"
TE_BASE="494e91d2ff5"                                    # develop at 2026-08-08
JUCE_BASE="37c894f83d379179b2070d437ccd0f1cd9af9576"     # JUCE 8.0.13
PATCHES_REL="engine-patches/3.5"
TE_UPSTREAM="https://github.com/Tracktion/tracktion_engine.git"   # the fallback, if the fork is gone
TE_URL_ARG=""
FORCE=0
KEEP_SSH=0

for arg in "$@"; do
    case "$arg" in
        --force)         FORCE=1 ;;
        --ssh)           KEEP_SSH=1 ;;
        --patches-dir=*) PATCHES_REL="${arg#*=}" ;;
        --tracktion-url=*) TE_URL_ARG="${arg#*=}" ;;
        -h|--help)       sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)               echo "unknown argument: $arg (see --help)" >&2; exit 2 ;;
    esac
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# The tracktion .gitmodules points at juce over SSH (`git@github.com:…`), which needs a key
# registered on GitHub. For a read-only clone, HTTPS works for everyone.
to_https() {
    [ "$KEEP_SSH" = 1 ] && { printf '%s' "$1"; return; }
    case "$1" in
        git@github.com:*)       printf 'https://github.com/%s' "${1#git@github.com:}" ;;
        ssh://git@github.com/*) printf 'https://github.com/%s' "${1#ssh://git@github.com/}" ;;
        *)                      printf '%s' "$1" ;;
    esac
}
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null || die "git cannot be found."
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

PATCHES="$ROOT/$PATCHES_REL"
TE="$ROOT/$TE_DIR"
JUCE="$TE/modules/juce"

[ -d "$PATCHES" ] || die "patch directory not found: $PATCHES"

# `git am` makes commits: with no identity configured it stops at the first one.
git config user.email >/dev/null 2>&1 || die "configure git first: git config --global user.email … && git config --global user.name …"

# The juce patch is OPTIONAL: if it is not in the series, juce stays on the official commit
# that tracktion pins, and there is neither a juce branch nor a juce fork to arrange.
JUCE_PATCH="$(ls "$PATCHES"/0010-*.patch 2>/dev/null | head -1)" || true
JUCE_PATCH="${JUCE_PATCH:-}"
TE_PATCHES=()
while IFS= read -r p; do TE_PATCHES+=("$p"); done < <(ls "$PATCHES"/0*.patch | grep -v '/0010-')
[ "${#TE_PATCHES[@]}" -gt 0 ] || die "no tracktion patch in $PATCHES_REL."

TE_URL="$TE_URL_ARG"
[ -n "$TE_URL" ] || TE_URL="$(git config -f "$ROOT/.gitmodules" --get "submodule.$TE_DIR.url" || true)"
TE_URL="$(to_https "$TE_URL")"
[ -n "$TE_URL" ] || die "URL of submodule $TE_DIR not found in .gitmodules."

clone_if_needed() {  # <directory> <url> <what> [fallback-url]
    local dir="$1" url="$2" what="$3" fallback="${4:-}"
    if [ -e "$dir/.git" ]; then
        say "$what: repository already present, fetching what is new"
        git -C "$dir" fetch --tags origin
        return
    fi
    say "$what: cloning from $url (long, it is a large repository)"
    mkdir -p "$dir"
    if git clone "$url" "$dir"; then
        return
    fi
    # The fork is unreachable — the very case this script exists for. The official repository
    # holds the pinned base just as well; the patches do the rest.
    if [ -z "$fallback" ] || [ "$fallback" = "$url" ]; then
        die "$what: cloning from $url failed."
    fi
    say "$what: $url is unreachable, falling back on $fallback"
    # A failed clone cleans up after itself; rmdir only ever removes an EMPTY directory, so
    # nothing of yours can go with it. If something is left, git says so below.
    rmdir "$dir" 2>/dev/null || true
    git clone "$fallback" "$dir" || die "$what: cloning from $fallback failed too."
}

branch_guard() {  # <directory> <what>
    local dir="$1" what="$2"
    if git -C "$dir" rev-parse --verify --quiet "$BRANCH" >/dev/null; then
        [ "$FORCE" = 1 ] || die "$what already has a $BRANCH branch. Run again with --force to overwrite it."
    fi
    if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no --ignore-submodules=all)" ]; then
        die "$what has uncommitted changes. Put them away before rebuilding."
    fi
}

clone_if_needed "$TE" "$TE_URL" "tracktion" "$TE_UPSTREAM"

JUCE_URL="$(git config -f "$TE/.gitmodules" --get "submodule.modules/juce.url" \
         || git config -f "$TE/.gitmodules" --get "submodule.juce.url" || true)"
JUCE_URL="$(to_https "$JUCE_URL")"
[ -n "$JUCE_URL" ] || die "URL of the juce submodule not found in $TE/.gitmodules."
clone_if_needed "$JUCE" "$JUCE_URL" "juce"

branch_guard "$TE" "tracktion"
[ -n "$JUCE_PATCH" ] && branch_guard "$JUCE" "juce"

# 1. juce: the pinned base, plus the patch that belongs to it if it is in the series.
if [ -n "$JUCE_PATCH" ]; then
    say "juce: branch $BRANCH on $JUCE_BASE"
    git -C "$JUCE" checkout -B "$BRANCH" "$JUCE_BASE"
    # --keep-cr: the JUCE sources are CRLF and the archives keep those CRs. Without the
    # option, the `mailinfo` of `git am` removes them from the body of the patch, which then
    # stops matching the file — "patch does not apply" on a patch that is perfectly sound
    # (`git apply` takes it, for its part).
    git -C "$JUCE" am --keep-cr "$JUCE_PATCH"
    echo "juce rebuilt: $(git -C "$JUCE" rev-parse HEAD)"
else
    say "juce: no patch in the series, we will follow tracktion's pin"
    git -C "$JUCE" checkout --detach --quiet "$JUCE_BASE"
fi

# 2. tracktion: the pinned base + the whole active series, in order. (The exclusion below is
#    a no-op while 0010 sits in pending/; it matters again the day it is brought back.)
say "tracktion: branch $BRANCH on $TE_BASE, then ${#TE_PATCHES[@]} patches"
git -C "$TE" checkout -B "$BRANCH" "$TE_BASE"
if ! git -C "$TE" am --keep-cr "${TE_PATCHES[@]}"; then
    die "a patch did not go through. Look at 'git -C $TE_DIR am --show-current-patch', then give up with 'git -C $TE_DIR am --abort'."
fi

# 3. Bring juce and the gitlink tracktion records into agreement.
if [ -n "$JUCE_PATCH" ]; then
    #    The gitlink laid back down by patch 0004 names the juce rebuilt ON THE ORIGINAL
    #    MACHINE (56cb73c…). `git am` remakes the commits with a different committer and a
    #    different date: the local SHA necessarily differs. Without this realignment,
    #    modules/juce points into the void and the build's first `git submodule update` fails.
    say "tracktion: realign the juce gitlink onto the juce rebuilt here"
    git -C "$TE" add modules/juce
    if git -C "$TE" diff --cached --quiet; then
        echo "gitlink already right (nothing to realign)."
    else
        git -C "$TE" commit -m "build(juce): repoint the gitlink at the locally rebuilt juce

Patch 0004 freezes the gitlink on the original machine's juce; git am
remakes the commits, so the local SHA differs. This commit restores the
agreement between modules/juce and the $BRANCH branch rebuilt here."
    fi
else
    #    With no juce patch it is the other way round: nothing to realign, juce settles on what
    #    tracktion pins. That pin still has to be public — if it still names the original
    #    patched juce, the series is keeping the 0004 bump without the patch that justifies it.
    say "juce: settling on tracktion's pin"
    PIN="$(git -C "$TE" ls-tree HEAD modules/juce | awk '{print $3}')"
    if ! git -C "$JUCE" cat-file -e "$PIN^{commit}" 2>/dev/null; then
        git -C "$JUCE" fetch --quiet origin "$PIN" 2>/dev/null || true
    fi
    git -C "$JUCE" cat-file -e "$PIN^{commit}" 2>/dev/null \
        || die "tracktion pins the juce commit $PIN, which cannot be found at juce-framework.
       The series most likely still carries the 0004 gitlink bump without the juce patch 0010
       that justifies it: a commit is needed to put the pin back on $JUCE_BASE."
    git -C "$JUCE" checkout --detach --quiet "$PIN"
    echo "juce: $PIN (official commit, no fork needed)"
fi

# 4. Verification.
say "verification"
COUNT="$(git -C "$TE" log --oneline "$TE_BASE..HEAD" | wc -l | tr -d ' ')"
echo "tracktion: $COUNT commits above $TE_BASE (expected ${#TE_PATCHES[@]} patches + 0 or 1 gitlink realignment)"
echo "tracktion HEAD: $(git -C "$TE" rev-parse HEAD)"
echo "juce      HEAD: $(git -C "$JUCE" rev-parse HEAD)"

cat <<EOF

The engine is rebuilt. Two things to know before opening Xcode:

  • \`git status\` at the root will show $TE_DIR as modified: that is normal, your rebuilt
    engine does not have the same SHAs as the one on the original machine. Do not commit
    that change if you contribute to the repository.

  • DO NOT RUN \`git submodule update\`: it would try to go back to the original commit,
    which exists on no server, and it would lose you the rebuilt branch.

Build: open objekat.xcodeproj in Xcode, target "objekat".
EOF
