# Vendored libmp3lame — Objekat integration

## Why

macOS **cannot encode MP3**. CoreAudio does declare the file type `MPG3` for
writing, but only to copy already encoded frames across: the list of *encodable*
formats (`kAudioFormatProperty_EncodeFormatIDs`) does not hold `.mp3`, and
`afconvert -f MPG3 -d '.mp3'` fails on `fmt?`. JUCE has no encoder either — its
`LAMEEncoderAudioFormat` drives an external `lame` binary. Hence these sources, compiled into
the app, called from Swift through the bridging header (`Mp3Encoder.swift`).

## Contents

LAME **3.100**, `https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz`
(sha256 `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`), cut down to what we
compile: `include/`, `libmp3lame/`, plus `COPYING`, `LICENSE`, `README`, `ChangeLog`.
Set aside: the frontend, mpglib (the decoder), ACM/DLL/dshow, the docs, the MSVC projects.

## What is not original

Two minimal departures, and nothing else:

1. **`libmp3lame/lame.h` — an ADDED file** (one line: `#include "../include/lame.h"`).
   The sources include the public header through `#include "lame.h"`, counting on the `-I…/include`
   of the autoconf Makefile; the Xcode target lays down no extra include path.
2. **`libmp3lame/set_get.h`** — `#include <lame.h>` (angle brackets) replaced by
   `#include "../include/lame.h"`, for the same reason: angle brackets cannot resolve
   without a `-I`.

We could have added `$(SRCROOT)/lame-3.100/…` to the project's `HEADER_SEARCH_PATHS`, but that
setting holds for EVERY compilation unit: a folder full of generic names
(`util.h`, `version.h`, `encoder.h`, `tables.h`…) on JUCE's and Tracktion's include
path is a trap we do not want to lay.

## How it compiles

The `objekat/` group is a **synchronized** Xcode group: every `.c` found in it is compiled
with the same settings. There is no way to lay down there the `-DHAVE_CONFIG_H` LAME expects without laying it
down for the whole project — yet FLAC and Ogg, embedded in JUCE, test the same symbol.

Hence `objekat/LAMEModules/`: one compilation unit per LAME source, on the model of the
`objekat/JUCEModules/*_impl.mm`. Each first includes `objlame_config.h` (which reproduces the
output of `./configure --disable-frontend --disable-decoder` on macOS), then the vendored source.
The sources stay compiled **separately** — an amalgamation into a single unit was
tried and set aside: `presets.c` does `#undef Min/Max` and `takehiro.c` defines a `ROUNDFAC` that
`vbrquantize.c` uses as an identifier, two macro leaks from one file into another.

Deliberately not defined: `HAVE_MPGLIB` (no decoding), `HAVE_XMMINTRIN_H` (no SSE
path — the target is universal arm64/x86_64), `TAKEHIRO_IEEE754_HACK`, `HAVE_NASM`.

## Verification

The Objekat compilation produces an encoder **identical to the bit** to that of the reference
autoconf build: the same test program linked once against Objekat's objects, once against those produced
by `./configure && make`, encoding `testcase.wav` at 320 kbit/s CBR → the same sha256
(`dcd0c5df4b1124a8323a64fbee5ef415449f1018824c4cb0684c2b4f5dc03ff0`).

To redo this verification after a version bump:

```sh
# 1) the reference build, outside the repo
curl -LO https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
tar xzf lame-3.100.tar.gz && cd lame-3.100 && ./configure --disable-frontend --disable-decoder && make

# 2) the Objekat build of the same sources (from the root of the repo)
for f in objekat/LAMEModules/*_impl.c; do clang -c -O2 -std=gnu17 -o /tmp/$(basename $f .c).o $f; done
```

Then link one and the same small encoding program against both sets of objects and compare the MP3s produced.

## Licence

LAME is under the **LGPL 2.1** (`COPYING`). The sources used are here, unmodified apart
from the two points listed above.
