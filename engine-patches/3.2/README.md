# Engine patches — the tracktion 3.2 base (ABANDONED)

This base is no longer the app's. `main` has been running on **3.5** since 2026-08-08:
see `../3.5/README.md`, which is the live series.

These four archives are kept only as a **safety net for the application branch
`sav-moteur-en-pistes`** (the "one track per object" model), whose gitlink still points
at the 3.2 head of the submodule (`8d4f237`, local engine branch `objekat-patches`).
Those commits are pushed to no remote: if the local engine branch disappears,
these `.patch` files are the only way to rebuild it.

If `sav-moteur-en-pistes` is one day abandoned, this folder goes with it.

## Contents

- `0002` — a dynamic **time** offset (in seconds) for audio clips inside nested
  groups: `WaveNode::setDynamicOffsetTime` (the counterpart of `dynamicOffsetBeats`),
  `DynamicOffsetNode::getOffset` no longer double-counting, and `EditNodeBuilder`
  recursing over the `ContainerClip`s. **Not carried over to 3.5**: 3.5 abandons the
  `DynamicOffsetNode` path in favour of `ContainerClipNode`.
- `0003`, `0004`, `0005` — the three graph performance patches. Carried over to 3.5, where they
  became `../3.5/0001`, `0002` and `0003`.

The JUCE patch (the VST3 factory `jassert`) lives on the `objekat-patches` branch of the juce
sub-submodule; its 3.5 version, on the current file path, is `../3.5/0010`.

## Rebuilding the 3.2 engine branch from scratch

```sh
git -C tracktion_engine checkout -b objekat-patches v3.2.0
git -C tracktion_engine am ../engine-patches/3.2/000[2345]-*.patch
```
