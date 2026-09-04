# Installing OBJEKAT on a fresh machine

**This repository does not contain the audio engine.** `tracktion_engine/` is a submodule,
and the engine OBJEKAT uses is not the official Tracktion: it is the official Tracktion **plus a
series of 29 patches** (`engine-patches/3.5/`), without which the app does not compile.

Allow 30 to 45 minutes, most of it spent cloning.

## Prerequisites

- macOS 15.6 (Sequoia) or newer — that is the project's deployment target.
- **Xcode 26.2 or newer.** That is the only version the project has been built with; nothing
  lower has been tried, so "or newer" is a fact and the floor is a guess. What the project
  actually asks of it: the macOS 26 SDK, a Swift 6 compiler driving the target in **language
  mode 5** (`SWIFT_VERSION = 5.0`), and a deployment target of macOS 15.6. If an older Xcode
  builds it, so much the better — but you will be the first to know.
- `git`, with an identity configured (`git config --global user.email …`): rebuilding the
  engine makes commits.
- ~3 GB of disk: Tracktion and JUCE are large repositories.

## Path A — clone, and that is all

Since 3 September 2026 the patched engine is published on a fork, and the submodule points at
it. One command:

```sh
git clone --recurse-submodules https://github.com/nicolasvair/objekat
```

JUCE, one level down, needs nothing either: the series holds no JUCE patch, so `modules/juce`
stays on the official `37c894f83d3`, public at juce-framework. One fork, no patch to apply, no
rebuilding.

### If that command fails

It used to, and the failure looked like this:

```console
fatal: remote error: upload-pack: not our ref d74e7b542b327bbb279bc07e6bd8dc548d21b5b1
```

That is what happens when the gitlink names a commit that lives only on one machine. It should
no longer occur — but if it does (the fork moved, was renamed, or went private), nothing is
lost: the engine is entirely rebuildable from the archives in this repository. That is path B.

## Path B — rebuild the engine from the patches

The fallback, and the safety net: even if every fork disappeared, the engine could be
reconstituted. Everything is in the repository; there is nothing to fetch anywhere but from
Tracktion and JUCE. One command, from the root:

```sh
git clone https://github.com/nicolasvair/objekat   # WITHOUT --recurse-submodules
cd objekat
tools/rebuild-engine.sh
```

The script clones the two official repositories, lays down the pinned bases (Tracktion
`494e91d2ff5`, JUCE `37c894f83d3`), and applies the whole series in order onto Tracktion. JUCE
needs no patch and no branch: it settles on the commit Tracktion pins. The script pushes nothing
and writes nothing outside the repository.

The equivalent manual procedure, and the detail of what each patch does, are in
[`engine-patches/3.5/README.md`](engine-patches/3.5/README.md) — with one snag the script takes
care of: the JUCE submodule's URL is SSH, so it is rewritten to HTTPS to avoid requiring a key
registered on GitHub. The patches also apply with `git am --keep-cr`, which is now belt and
braces rather than a requirement — only the JUCE sources were CRLF.

The rebuild has been verified end to end on 3 September 2026: the patches applied onto the
pinned base, clean tree, and `modules/juce` on `37c894f83d379179b2070d437ccd0f1cd9af9576`.

### Two traps, once the engine is rebuilt

- **`git status` will show `tracktion_engine` as modified.** That is normal and harmless:
  `git am` remakes the commits with a different committer and a different date, so the rebuilt
  SHAs cannot be those of the original machine. Do not commit that change.
- **Never run `git submodule update` afterwards.** It would try to go back to the original
  commit — unfindable on any server — and would lose the rebuilt branch.

## Building

```sh
open objekat.xcodeproj
```

Target and scheme `objekat`. The engine is compiled as a JUCE module inside the target: no
separate build, but the first compilation is long. From the command line, without opening
anything:

```sh
xcodebuild -project objekat.xcodeproj -scheme objekat -configuration Debug build
```

### Signing: nothing to arrange

The project is committed with **no development team**, and signs **ad hoc** (`CODE_SIGN_IDENTITY
= "-"`, what Xcode calls "Sign to Run Locally"). It therefore builds and runs with no Apple
account of any kind — that is the point: a repository that demands somebody else's team is a
repository nobody can build.

The app's entitlements survive that signature. They are hardened-runtime exceptions
(`disable-library-validation`, `allow-unsigned-executable-memory`) needed to host plugins, and
they call for no provisioning profile. Verified: the build signs `adhoc`, the entitlements are
present in the binary, and the headless smoke scenario runs.

You only need a real identity to **distribute** the app — notarised, opened on someone else's
machine. In that case, in Xcode ▸ Signing & Capabilities, pick your team and switch signing back
to Automatic. **Do not commit that change**: it is yours, not the project's. Or, to leave the
project file untouched:

```sh
xcodebuild -project objekat.xcodeproj -scheme objekat \
    DEVELOPMENT_TEAM=YOURTEAMID CODE_SIGN_STYLE=Automatic build
```

## Checking that it runs

With no window opened, using the repository's smoke scenario:

```sh
objekat.app/Contents/MacOS/objekat --headless --no-audio --no-recent \
    --exec=tools/smoke.jsonl
```

`--no-recent` keeps a trial run out of "Recent projects". Arguments are **always** written as
`--key=value`: an orphan argument starts the app with no window, silently. The complete command
API is documented in
[`OBJEKAT - claude project/docs/command_api.md`](OBJEKAT%20-%20claude%20project/docs/command_api.md).

## Publishing the engine (for the maintainer)

Path B is rebuildable but tedious, and it leaves every machine with its own SHAs. For path A to
work for everyone, the engine branch has to be pushed to a personal fork of Tracktion — **one
fork, since 3 September 2026**: JUCE no longer carries any local commit, so nothing has to be
published at that level.

1. On GitHub, fork `Tracktion/tracktion_engine` (the "Fork" button). A fork can be renamed —
   this one is called `tracktion_engine_for_objekat`, and the script knows that; for any other
   name, `--tracktion-fork=URL`.

   **A second fork, of `juce-framework/JUCE`, becomes necessary again only if a JUCE patch comes
   back into the series** (`--juce-fork=URL`). The script decides on its own, and on the right
   criterion: not whether a juce branch lingers on the machine, but whether the commit Tracktion
   pins is reachable from a public repository. What such a return costs is written up in
   [`engine-patches/3.5/pending/README.md`](engine-patches/3.5/pending/README.md).
2. From the root of the repository, with the patched engine present locally:

```sh
tools/publish-engine-forks.sh          # prints the plan, does nothing
tools/publish-engine-forks.sh --yes    # pushes the branch, repoints the .gitmodules
```

⚠️ The engine present on **your** machine may still be the old one. Setting `0004` and `0010`
aside changes the series, not the branch already rebuilt in the submodule: as long as
`git -C tracktion_engine ls-tree objekat-patches-3.5 modules/juce` answers `56cb73c…`
rather than `37c894f8…`, that branch still carries the JUCE patch, and the script will rightly
ask for a second fork. Rebuild it (`tools/rebuild-engine.sh --force`) before publishing.

The script leaves the final commit and the main repository's `git push` to be done by hand, for
review. After that, a recursive clone brings the patched engine down on its own, and
`engine-patches/3.5/` goes back to being a safety net rather than the only way in.
