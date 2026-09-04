#!/usr/bin/env bash
#
# Publishes the patched engine on YOUR fork, so that a clone of OBJEKAT brings the engine
# down on its own.
#
# The problem it settles: the submodule points at Tracktion's official repository, but the
# commit it references exists only on your machine. Nobody else can fetch it. By pushing the
# `objekat-patches-3.5` branch to a fork of your own, then pointing .gitmodules at it, a clone
# becomes again:
#
#     git clone --recurse-submodules https://github.com/<you>/objekat
#
# ONE fork is normally enough. Since 3 September 2026 the series carries no JUCE patch (0004
# and 0010 sit in engine-patches/3.5/pending/), so modules/juce stays on a commit that is public
# at juce-framework and needs publishing by nobody. The script works this out on its own, and on
# the right criterion: not whether a juce branch lingers on the machine — one does on any machine
# that once built with the patch — but whether the commit tracktion PINS is reachable from a
# public repository. It asks for a second fork only when that commit is not.
#
# Prerequisites: having forked Tracktion/tracktion_engine on your account (the "Fork" button on
# GitHub, nothing else), and having the patched engine locally.
#
# Usage:
#     tools/publish-engine-forks.sh                     # shows the plan, does nothing
#     tools/publish-engine-forks.sh --yes               # runs
#     tools/publish-engine-forks.sh --tracktion-fork=URL [--juce-fork=URL] [--yes]
#
# Without --yes, NO push, NO commit: the script merely prints what it would do.

set -euo pipefail

BRANCH="objekat-patches-3.5"
TE_DIR="tracktion_engine"
REMOTE_NAME="objekat"     # the remote added inside the submodules to name your fork
DO_IT=0
TE_FORK=""
JUCE_FORK=""

for arg in "$@"; do
    case "$arg" in
        --yes|-y)           DO_IT=1 ;;
        --tracktion-fork=*) TE_FORK="${arg#*=}" ;;
        --juce-fork=*)      JUCE_FORK="${arg#*=}" ;;
        -h|--help)          sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                  echo "unknown argument: $arg (see --help)" >&2; exit 2 ;;
    esac
done

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# In plan mode, `run` prints; with --yes, it runs.
run() {
    if [ "$DO_IT" = 1 ]; then
        printf '\033[2m+ %s\033[0m\n' "$*"
        "$@"
    else
        printf '   %s\n' "$*"
    fi
}

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
TE="$ROOT/$TE_DIR"
JUCE="$TE/modules/juce"

[ -e "$TE/.git" ] || die "$TE_DIR is not a repository. Run tools/rebuild-engine.sh first."
git -C "$TE" rev-parse --verify --quiet "$BRANCH" >/dev/null || die "tracktion has no $BRANCH branch."

# Is a second fork needed? The question is NOT whether a juce branch happens to exist locally —
# one lingers on any machine that once built with the JUCE patch. What decides is the commit
# tracktion PINS: if it came from the official repository, a recursive clone will find it there
# and nobody has to publish anything. `branch -r --contains` answers exactly that — a commit
# reachable from a remote-tracking branch is a commit the world can fetch.
JUCE_PIN="$(git -C "$TE" ls-tree "$BRANCH" modules/juce | awk '{print $3}')"
[ -n "$JUCE_PIN" ] || die "cannot read the juce gitlink of $BRANCH in $TE_DIR."
JUCE_LOCAL=1
if [ -e "$JUCE/.git" ] && [ -n "$(git -C "$JUCE" branch -r --contains "$JUCE_PIN" 2>/dev/null)" ]; then
    JUCE_LOCAL=0
fi

# Default forks: the same account as OBJEKAT's `origin` remote. The tracktion fork was renamed
# when it was created, hence a name that is not the original repository's.
OWNER="$(git remote get-url origin | sed -E 's#^.*[/:]([^/]+)/[^/]+/?$#\1#')"
[ -n "$TE_FORK" ]   || TE_FORK="https://github.com/$OWNER/tracktion_engine_for_objekat.git"
[ -n "$JUCE_FORK" ] || JUCE_FORK="https://github.com/$OWNER/JUCE.git"

# The forks must exist BEFORE we touch anything: pushing one and then discovering that the other
# is missing would leave the work half done.
check_fork() {  # <what> <option> <url>
    git ls-remote --heads "$3" >/dev/null 2>&1 && return
    die "the $1 fork cannot be reached: $3
       Create it on GitHub (the \"Fork\" button), or give its URL with $2=…
       A renamed fork keeps its content but changes URL."
}
check_fork tracktion --tracktion-fork "$TE_FORK"
[ "$JUCE_LOCAL" = 1 ] && check_fork juce --juce-fork "$JUCE_FORK"

say "plan"
cat <<EOF
  account        : $OWNER
  tracktion fork : $TE_FORK
  branch         : $BRANCH
  tracktion HEAD : $(git -C "$TE" rev-parse "$BRANCH")
EOF
if [ "$JUCE_LOCAL" = 1 ]; then
cat <<EOF
  juce fork      : $JUCE_FORK
  juce HEAD      : $(git -C "$JUCE" rev-parse "$BRANCH")
EOF
else
    echo "  juce           : nothing to publish"
    echo "  juce pin       : $JUCE_PIN (public, reachable from juce-framework)"
fi
[ "$DO_IT" = 1 ] || echo "
  (plan mode — nothing will be pushed. Run again with --yes to execute.)"

# 1. juce: only if it carries local commits.
if [ "$JUCE_LOCAL" = 1 ]; then
    say "1. juce → $JUCE_FORK"
    if [ "$DO_IT" = 1 ] && git -C "$JUCE" remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
        run git -C "$JUCE" remote set-url "$REMOTE_NAME" "$JUCE_FORK"
    else
        run git -C "$JUCE" remote add "$REMOTE_NAME" "$JUCE_FORK"
    fi
    run git -C "$JUCE" push -u "$REMOTE_NAME" "$BRANCH"

    # tracktion must point ITS .gitmodules at the juce fork, otherwise a recursive clone will go
    # looking for the patched juce commit at juce-framework, where it does not exist.
    say "2. tracktion: .gitmodules → juce fork"
    run git -C "$TE" config -f .gitmodules submodule.modules/juce.url "$JUCE_FORK"
    run git -C "$TE" add .gitmodules modules/juce
    if [ "$DO_IT" = 1 ] && git -C "$TE" diff --cached --quiet; then
        echo "   (nothing to commit on the tracktion side)"
    else
        run git -C "$TE" commit -m "build(juce): point the submodule at the objekat fork

The patched juce commit does not exist at juce-framework: a recursive clone has
to look for it on the fork that carries it."
    fi
else
    say "1-2. juce: nothing to do"
    echo "   tracktion pins a public juce commit, which a recursive clone finds by itself."
    echo "   No second fork, and tracktion's .gitmodules is left pointing at juce-framework."
fi

# 3. tracktion: push the branch to the fork.
say "3. tracktion → $TE_FORK"
if [ "$DO_IT" = 1 ] && git -C "$TE" remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
    run git -C "$TE" remote set-url "$REMOTE_NAME" "$TE_FORK"
else
    run git -C "$TE" remote add "$REMOTE_NAME" "$TE_FORK"
fi
run git -C "$TE" push -u "$REMOTE_NAME" "$BRANCH"

# 4. OBJEKAT: .gitmodules on the tracktion fork + the gitlink on the commit just pushed.
say "4. objekat: .gitmodules → tracktion fork, gitlink realigned"
run git config -f .gitmodules "submodule.$TE_DIR.url" "$TE_FORK"
run git add .gitmodules "$TE_DIR"

cat <<EOF

Left to do by hand, so that you read it over first:

    git commit -m "build(engine): submodule on the objekat fork"
    git push -u origin \$(git rev-parse --abbrev-ref HEAD)

Then check from an empty directory, the way a stranger would:

    git clone --recurse-submodules https://github.com/$OWNER/objekat verify-clone
    git -C verify-clone submodule status --recursive
EOF
