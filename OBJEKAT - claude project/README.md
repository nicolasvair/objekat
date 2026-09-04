# OBJEKAT

**An object-oriented audio editor for macOS.**

A 2026 revival of the OBJEKAT project, sketched out in 2016 in the graduation thesis of Nicolas Vercambre (ENS Louis Lumière, Sound department). The central idea: replace the *audio track* with the *sound object* (in Pierre Schaeffer's sense) as the structuring primitive of the interface.

## The pitch in one sentence

A DAW where every sound is an object carrying its own attributes (position in time, volume, pan, plugins, routing) — thought out for film sound editors, built for macOS.

## Progress

| Phase | Status |
|---|---|
| **Phase 0** — Technical spike & architecture validation | ✅ Done |
| Phase 1 — UI skeleton with no audio | ✅ Done |
| Phase 2 — Audio wired in (= MVP V1) | ✅ Done |
| Phase 3 — Loose selection + the tool system | ✅ Done |
| Phase 4 — Stems, groups, auxiliaries | ✅ Done |
| Phase 5+ — Plugins, synoptic, MIDI, sound objects, stems/aux, automation, loop | 🚧 Under way |

The app runs: an object timeline, nested groups, stems and auxiliaries, an FX chain shown by the synoptic (series and parallel), MIDI clips + a piano roll, **sound objects** (one baked definition reused in N places; opening one instance edits the shared content, closing it resynchronises all the others), **automation** through curves that travel with the object, and the **loop** of a clip, of a group or of a MIDI clip.

It can also be driven **with no interface**: a command API over a UNIX socket (~105 commands) gives outside access to everything the interface does — it is the project's test harness. See `docs/command_api.md`.

See `docs/architecture_decisions.md` and `CLAUDE.md`, at the root of the repository (current state / next steps).

## Technical stack

- **macOS 15.6** (Sequoia) as the deployment target, modern SwiftUI. Built with Xcode 26.2: a Swift 6 compiler, driving the target in language mode 5.
- **Audio engine**: Tracktion Engine **3.5** (C++ / JUCE 8.0.13), as a submodule in `tracktion_engine/` — the folder no longer carries a version number, which used to go stale at every bump. The engine carries a series of 29 local patches (`engine-patches/3.5/`, numbered `0001`→`0031` with two holes: `0004` and `0010`, the only JUCE ones, sit in `pending/`).
- **Swift ↔ C++ bridge**: an Objective-C++ (`.mm`) wrapper exposing a simple API to Swift.
- **Build**: Xcode (`objekat.xcodeproj`); the engine is compiled as a JUCE module inside the target.

## Folder structure

```
OBJEKAT/
├── CLAUDE.md                              # (at the ROOT of the repository) the continuity memo,
│                                          #   loaded automatically by Claude Code
├── INSTALL.md                             # (at the ROOT) installing and building on a fresh
│                                          #   machine — the engine is NOT in the repository
├── README.md                              # this file
├── OBJEKAT_thesis_digest.md               # a structured digest of the 2016 thesis
├── OBJEKAT_work_plan.md                   # the 2026 plan/roadmap
├── Mémoire - Objekat - Nicolas Vercambre 2016.pdf
├── objekat/                               # Swift sources + the Obj-C++ bridge
├── engine-patches/3.5/                    # the engine's .patch archives — the live series
├── tools/                                 # CLI, MCP, test scenarios
└── tracktion_engine/                # the audio engine, a submodule (version 3.5)
    └── modules/juce/                       # a sub-submodule, branch objekat-patches-3.5
```

> The engine comes down with a `git clone --recurse-submodules`: the submodule points at the
> fork that carries the patched branch, and `modules/juce` at an official commit. On a fresh
> machine, see [`INSTALL.md`](../INSTALL.md) — and `tools/rebuild-engine.sh` if ever the fork
> were no longer reachable.
>
> Reapplying the patches after a clone or a bump: `engine-patches/3.5/README.md`. The series is
> a history, not a set of independent fixes — it applies whole and in order.

## Reference documents

- **[Thesis digest](OBJEKAT_thesis_digest.md)** — concepts, ergonomics, features. To be read first to understand OBJEKAT.
- **[Work plan](OBJEKAT_work_plan.md)** — architecture, phases, milestones, risks. To be read to know what to do.
- **[The original thesis (PDF, in French)](Mémoire%20-%20Objekat%20-%20Nicolas%20Vercambre%202016.pdf)** — 137 pages, the primary source.

## Guiding principles

1. **The sound object is the primitive everywhere** — the Swift model, the bridge's API, the structure inside the engine. No Tracktion concept (Track, Clip, Edit) may leak into the UI layer.
2. **A strict UI ↔ engine decoupling** — the Swift layer has no direct dependency on JUCE/Tracktion. Everything goes through the Obj-C++ bridge's API.
3. **Short iterations** in the Lean Startup spirit — one testable deliverable at each phase.
4. **Test on real editing sessions as soon as possible** — the conclusion of the 2016 thesis was clear: only prolonged use reveals the inconsistencies.

## Getting started

- Installing and building on a fresh machine: [INSTALL.md](../INSTALL.md), at the root of the repository.
- Picking up the thread of development: [CLAUDE.md](../CLAUDE.md), at the root of the repository.

## Contact

Questions, bug reports, patches: **ruisseaux-chances-1r@icloud.com**.

Commits carry a `users.noreply.github.com` address, which delivers nowhere — this is the one
that reaches a human.

## Licence

OBJEKAT is free software, under the **[GNU Affero General Public License v3](../LICENSE)** or
later. Copyright © 2026 Nicolas Vair.

The Affero clause is inherited rather than chosen: the app is built on Tracktion Engine, which
cannot run without JUCE, and the free option of JUCE 8 is the AGPLv3. For a desktop application
run on one's own machine that clause never comes into play — it is about users interacting with
the software remotely, over a network.

The third-party components and their respective licences — Tracktion Engine (GPL3), JUCE
(AGPLv3), LAME (LGPL2 or later) — are listed in [NOTICE](../NOTICE), which also sets out the
reasoning in full.
