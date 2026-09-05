# OBJEKAT

**An object-oriented audio editor (current support is macOS only).**

Following a 2016 graduation thesis of Nicolas Vercambre (ENS Louis Lumière, Sound department). The central idea: replace the *audio track* with the *sound object* (in Pierre Schaeffer's sense) as the structuring primitive of the interface.

**[The original thesis is available here (PDF, in French)](OBJEKAT%20-%20claude%20project/M%C3%A9moire%20-%20Objekat%20-%20Nicolas%20Vercambre%202016.pdf)** 


## Progress

The app runs: an object timeline, nested groups, stems and auxiliaries, an FX chain shown by the synoptic, MIDI clips + a basic piano roll, **automation** , and the **loop** of a clip, of a group or of a MIDI clip. I also introduced **sound objects**, which are basically a freeze or wav render of a clip or a group, but that you can revert back to previous "live" state if needed.

It can also be driven **with no interface**: a command API over a UNIX socket (~105 commands) gives outside access to everything the interface does — it is the project's test harness. See [`docs/command_api.md`](OBJEKAT%20-%20claude%20project/docs/command_api.md).

It has been though to be usable by an AI like Claude. The projects are json easy to understand / edit, and it can also runs the app headless to automate some things.

There is also a starting point to add custom scripts / extensions. It hasn't been deeply tested so don't expect much from it so far.

Not yet implemented : audio / midi recording, advanced export options (stems / objects). 

Everything is full vibe coded with claude code, closely monitored in the first steps and not so much since opus 5. The program runs well but the md documents are quite a mess. 


## Technical stack

- **macOS 15.6** (Sequoia) as the deployment target, modern SwiftUI. Built with Xcode 26.2: a Swift 6 compiler, driving the target in language mode 5.
- **Audio engine**: Tracktion Engine **3.5** (C++ / JUCE 8.0.13), as a submodule in `tracktion_engine/` — the folder no longer carries a version number, which used to go stale at every bump. The engine carries a series of 29 local patches (`engine-patches/3.5/`, numbered `0001`→`0031` with two holes: `0004` and `0010`, the only JUCE ones, sit in `pending/`).
- **Swift ↔ C++ bridge**: an Objective-C++ (`.mm`) wrapper exposing a simple API to Swift.
- **Build**: Xcode (`objekat.xcodeproj`); the engine is compiled as a JUCE module inside the target.


## Folder structure

```
objekat/
├── README.md                     # this file
├── INSTALL.md                    # installing and building on a fresh machine — the
│                                 #   engine is NOT in the repository
├── CLAUDE.md                     # the continuity memo, loaded automatically by Claude Code
├── LICENSE  NOTICE               # the AGPLv3, and the third-party components
├── objekat/                      # Swift sources + the Obj-C++ bridge
├── objekat.xcodeproj             # the Xcode project — target and scheme `objekat`
├── lame-3.100/                   # LAME, vendored and cut down to what is compiled
├── engine-patches/3.5/           # the engine's .patch archives — the live series
├── tools/                        # CLI, MCP, test scenarios, i18n
├── tracktion_engine/             # the audio engine, a submodule (version 3.5, patched)
│   └── modules/juce/             # a sub-submodule, on an official JUCE commit
└── OBJEKAT - claude project/     # the reference documents
    ├── OBJEKAT_thesis_digest.md  # a structured digest of the 2016 thesis
    ├── OBJEKAT_work_plan.md      # the 2026 plan/roadmap
    ├── Mémoire - Objekat - Nicolas Vercambre 2016.pdf
    └── docs/                     # architecture decisions, command API, glossary
```

> The engine comes down with a `git clone --recurse-submodules`: the submodule points at the
> fork that carries the patched branch, and `modules/juce` at an official commit. On a fresh
> machine, see [`INSTALL.md`](INSTALL.md) — and `tools/rebuild-engine.sh` if ever the fork
> were no longer reachable.
>
> Reapplying the patches after a clone or a bump: `engine-patches/3.5/README.md`. The series is
> a history, not a set of independent fixes — it applies whole and in order.


## Guiding principles

1. **The sound object is the primitive everywhere** — the Swift model, the bridge's API, the structure inside the engine. No Tracktion concept (Track, Clip, Edit) may leak into the UI layer.
2. **A strict UI ↔ engine decoupling** — the Swift layer has no direct dependency on JUCE/Tracktion. Everything goes through the Obj-C++ bridge's API.
3. **Short iterations** in the Lean Startup spirit — one testable deliverable at each phase.
4. **Test on real editing sessions as soon as possible** — the conclusion of the 2016 thesis was clear: only prolonged use reveals the inconsistencies.


## Getting started

```sh
git clone --recurse-submodules https://github.com/nicolasvair/objekat
cd objekat
xcodebuild -project objekat.xcodeproj -scheme objekat -configuration Debug build
```

macOS 15.6 and Xcode 26.2. The `--recurse-submodules` is not optional: it is what brings the
patched engine down. The project signs ad hoc — no Apple account, no development team.

- The detail, and what to do if the clone fails: [INSTALL.md](INSTALL.md).
- Picking up the thread of development: [CLAUDE.md](CLAUDE.md) — the state of play and the traps.


## Contact

Questions, bug reports, patches: **ruisseaux-chances-1r@icloud.com**.


## Licence

OBJEKAT is free software, under the **[GNU Affero General Public License v3](LICENSE)** or
later. Copyright © 2026 Nicolas Vair.

The Affero clause is inherited rather than chosen: the app is built on Tracktion Engine, which
cannot run without JUCE, and the free option of JUCE 8 is the AGPLv3. For a desktop application
run on one's own machine that clause never comes into play — it is about users interacting with
the software remotely, over a network.

The third-party components and their respective licences — Tracktion Engine (GPL3), JUCE
(AGPLv3), LAME (LGPL2 or later) — are listed in [NOTICE](NOTICE), which also sets out the
reasoning in full.
