# Patches set aside

These are not lost, and they are not dead: they are out of the active series on purpose. The
rebuild scripts glob `engine-patches/3.5/0*.patch`, which does not reach into this directory, so
a patch parked here is simply not applied.

## Why these two left, on 3 September 2026

Both concern JUCE, and they were the only two that did. Between them they forced a whole extra
level of machinery on anyone cloning the project: a local JUCE branch, a second personal fork to
publish it, and a gitlink to realign after every rebuild — all for four lines of Debug comfort.
With the project going open source, that price stopped being worth paying.

- `0004` — moved the JUCE pin from `37c894f83d3` (official, JUCE 8.0.13) to `56cb73c` (the
  patched one). It exists only to record `0010`; without `0010` it has no purpose.
- `0010` — removes a `jassert (factory != nullptr)` from the VST3 scan. What it buys: in **Debug
  only**, scanning a VST3 that provides no factory (a broken plugin, a 32/64-bit mismatch) breaks
  into the debugger instead of carrying on. The null factory is **already handled by the
  caller**, and `jassert` does not compile in Release — so the shipped binary is unaffected.

Taking out both, rather than `0010` alone, is what avoids a corrective commit: the pin simply
stays where the base already had it. Verified on 3 September 2026 — the remaining 28 patches
apply cleanly onto `494e91d2ff5`, the tree comes out clean, and `modules/juce` ends on
`37c894f83d379179b2070d437ccd0f1cd9af9576`, public at juce-framework.

The series therefore has holes at `0004` and `0010`. That is deliberate; the numbering is a
history, not a count. The next patch will still be `0031`.

## Taking one back

Move the archive back up, apply it to the right repository, and — if it is `0010` — regenerate a
pin commit so that `modules/juce` names the JUCE you rebuilt:

```sh
git mv engine-patches/3.5/pending/0010-*.patch engine-patches/3.5/
git -C tracktion_engine/modules/juce am --keep-cr ../../../engine-patches/3.5/0010-*.patch
git -C tracktion_engine add modules/juce
git -C tracktion_engine commit -m "build(juce): repoint the gitlink at the rebuilt juce"
```

`tools/rebuild-engine.sh` picks the patch up again on its own: it looks for `0010-*.patch` in the
series and takes its JUCE branch whenever it finds one. Note that this brings back the need for a
second fork — the patched JUCE commit exists nowhere public.
