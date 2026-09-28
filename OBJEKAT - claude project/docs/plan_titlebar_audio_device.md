# Plan — the audio device in the window title

Branch: `feature/titlebar-audio-device`. Request (27 September 2026): in the title bar, just to
the right of the centred project name and in grey, show `<audio device> — 44.1k — 512`, and make
sure it ALWAYS shows the device and settings really in use.

---

## 0. What exists already (read before writing anything)

- **The title** is plain AppKit. `EditViewModel.updateWindowTitle()`
  (`objekat/EditViewModel/EditViewModel.swift` ~l.1459) writes `window.title` (the project name,
  plus ` •` when dirty) and `window.representedURL` (the proxy icon, ⌘-click). The window is the
  one `adoptDocumentWindow()` remembered (`titledWindow`), never `NSApp.mainWindow`. There is no
  SwiftUI `.toolbar`, no `navigationTitle`; the transport and stem strips live in the CONTENT. The
  recent narrow-window work (`623097a8`, `8c35cc08`, `bc600a3f`) touches that content bar only.
- **A first attempt is already in the tree, switched off**: `objekat/App/AudioTitleBar.swift`.
  `AudioStatusTitleView` + `AudioTitlebarStatus.install` put a `NSTitlebarAccessoryViewController`
  (`layoutAttribute = .right`) in the title bar. `ContentView.onAppear` (~l.186) has the call
  commented out: "the accessory does not show reliably under this SwiftUI WindowGroup". The view
  also POLLED the engine every 0.5 s with a `Timer.publish` writing three `@State`s — the pattern
  the memory note "Polls qui repeignent à vide" forbids. The same file holds `AudioSettingsMenu`
  (the wrench menu in `TransportView`, device / rate / buffer pickers) and `AudioDeviceWatcher`
  (CoreAudio device-list listener). `AudioStatusTitleView.shortRate` is also read by
  `TimelineView.swift:2881` (the selection HUD).
- **Bridge** (`objekat/OBJEngineCore.h` ~l.601-616, `.mm` ~l.6018-6135):
  `currentOutputDeviceName`, `currentSampleRate`, `currentBufferSize` read
  `deviceManager.getCurrentAudioDevice()` live; `setOutputDevice:` / `setSampleRate:` /
  `setBufferSize:` go through `AudioDeviceManager::setAudioDeviceSetup(setup, true)`.
  No change notification crosses the bridge today.
- **`AudioOutputDevice.shared.name`** (`objekat/Shared/AudioOutputDevice.swift`) is the device
  the user CHOSE, persisted in UserDefaults (`pref.outputDevice`). It is NOT the device in use: an
  unplugged choice leaves JUCE on a fallback while this name stays. The title must never read it.
- **Engine init**: `OBJEngineCore.mm:1136` `getDeviceManager().initialise(0, gOBJAudioDisabled ? 0 : 2)`.
  `--no-audio` → 0 in / 0 out. `--headless` alone DOES open the real device.
- **API**: `app.info` (`objekat/CommandAPI/Commands+Core.swift:52-57`) already returns
  `sample_rate`, `buffer_size`, `output_device` read live. No tool asserts them (grepped). There is
  no `audio.*` family and no API door to change device / rate / buffer.
- **Strings**: `audio.device.none` exists in fr/en/es ("Aucune carte son" / "No audio device" /
  "Ninguna tarjeta de sonido"). Glossary l.63-65: carte son / audio device / tarjeta de sonido;
  fréquence d'échantillonnage; latence / taille du buffer.

---

## 1. Where the truth is, and every road by which it changes

Read in JUCE (`tracktion_engine/modules/juce/modules/juce_audio_devices/audio_io/juce_AudioDeviceManager.cpp`,
`native/juce_CoreAudio_mac.cpp`) and Tracktion (`playback/tracktion_DeviceManager.cpp`).

**The single signal**: `juce::AudioDeviceManager` is a `ChangeBroadcaster`, and EVERY road below
ends in its `sendChangeMessage()` (asynchronous, coalesced, delivered on the message thread = the
main thread on macOS). Tracktion's own `DeviceManager` already listens to it
(`changeListenerCallback` → `saveSettings(); rescanWaveDeviceList();`) — we add a second listener
on the SAME broadcaster, `_engine->getDeviceManager().deviceManager`.

| Road | JUCE path | Ends in `sendChangeMessage`? |
|---|---|---|
| Startup restore (Settings.xml) | `te::DeviceManager::initialise` → `initialiseFromXML` → `setAudioDeviceSetup` → device `start` → `audioDeviceAboutToStartInt` | yes (l.1166) — but possibly BEFORE Swift attaches: read once at attach |
| Menu: device / rate / buffer | `setAudioDeviceSetup(setup,true)` → stop, (re)create, open, start | yes (aboutToStart / stopped, l.1166/1171; also l.771/816) |
| Rate or buffer changed OUTSIDE the app (Audio MIDI Setup, another app, the device itself) | CoreAudio property listener (`NominalSampleRate`, `BufferFrameSize`, `StreamFormat`, `DeviceIsAlive`…) → `deviceDetailsChanged` → 100 ms timer → `updateDetailsFromDevice` → `owner.restart()` → close (stopped) → 100 ms → start (aboutToStart) | yes, twice (stopped, then started) |
| Device unplugged | `kAudioHardwarePropertyDevices` → type `audioDeviceListChanged` → `AudioDeviceManager::audioDeviceListChanged` → current not available → `closeAudioDevice` + `initialiseFromXML/initialiseDefault` (fallback device) | yes (l.309) |
| Device replugged | same list change; the current device is still available → nothing reopened (JUCE does NOT go back by itself) | yes, and the snapshot is unchanged — which is the truth |
| System default output changed | nothing, unless the current device disappeared — JUCE keeps its device | no message needed: nothing changed in the engine |
| Device fails / dies (`updateDetailsFromDevice` false) | `stopWithPendingCallback` → `audioDeviceStopped` | yes; device object still there, NOT playing |
| Open failed (busy, bad rate) | `setAudioDeviceSetup` → `deleteCurrentDevice()` | yes → `getCurrentAudioDevice() == nullptr` |
| `--no-audio` (0 in / 0 out) | `setAudioDeviceSetup`: device CREATED, then `inputChannels.isZero() && outputChannels.isZero()` → `return {}` BEFORE `open` (l.877-883) | device object exists, `getName()` answers a real name, **but it is not open** |

**Two traps that make the existing getters lie** (and which the snapshot must close):

1. **`--no-audio`**: `getCurrentAudioDevice()` is non-null and `getName()` returns the default
   card's name although nothing is open. `currentOutputDeviceName` (hence `app.info.output_device`)
   reports a device that is not playing anything. → The snapshot requires `dev->isOpen()` AND at
   least one active output channel.
2. **A device stopped but not deleted** (death, restart gap): open, not playing. → The snapshot
   carries `running = dev->isPlaying()`.

What NOT to read: `AudioDeviceSetup` (what was REQUESTED — JUCE may have chosen the nearest rate /
buffer with `chooseBestSampleRate` / `chooseBestBufferSize`), Tracktion's cached
`te::DeviceManager::currentSampleRate` (falls back to 44100 when out of range, l.838), and
`AudioOutputDevice.shared.name` (the user's wish).

The name: for CoreAudio the device object's name IS the output device name
(`createDevice`: `combinedName = outputDeviceName.isEmpty() ? inputDeviceName : outputDeviceName`),
so `dev->getName()` is right, including for a combiner.

---

## 2. Implementation

### Step 1 — Engine bridge: snapshot + change callback (`OBJEngineCore.h/.mm`)

Header, beside the `// Device` block:

```objc
@interface OBJAudioDeviceSnapshot : NSObject
@property (nonatomic, copy, nullable) NSString* deviceName; // nil = no OPEN output device
@property (nonatomic, copy, nullable) NSString* deviceType; // "CoreAudio"…
@property (nonatomic) double    sampleRate;                  // Hz, 0 when deviceName == nil
@property (nonatomic) NSInteger bufferSize;                  // frames, 0 when deviceName == nil
@property (nonatomic) NSInteger outputChannels;              // active output channels
@property (nonatomic) BOOL      running;                     // dev->isPlaying()
@end

// The audio device ACTUALLY in use, read from the open juce::AudioIODevice — never from the
// requested AudioDeviceSetup, never from the persisted choice. Main thread.
- (OBJAudioDeviceSnapshot* _Nonnull)audioDeviceSnapshot;

// Called on the MAIN thread each time juce::AudioDeviceManager broadcasts a change (device
// opened / closed / restarted, rate or buffer changed, device list changed). Coalesced by JUCE.
// Carries nothing: the receiver reads -audioDeviceSnapshot (one truth, one reader).
@property (nonatomic, copy, nullable) void (^onAudioDeviceChanged)(void);
```

`.mm`:
- `struct OBJDeviceChangeWatcher : juce::ChangeListener` holding `__unsafe_unretained OBJEngineCore* owner`
  (same ownership convention as the other watchers, @see `OBJLatencyWatcher`), whose
  `changeListenerCallback` does `if (owner.onAudioDeviceChanged) owner.onAudioDeviceChanged();`.
  ChangeListener callbacks already run on the message thread — no `dispatch_async` needed, but
  assert `juce::MessageManager::existsAndIsCurrentThread()` in Debug.
- A `std::unique_ptr<OBJDeviceChangeWatcher> _deviceWatcher` ivar, created and
  `deviceManager.addChangeListener(...)` right AFTER `initialise(...)` (l.1136); removed in
  `dealloc` before the engine goes (the engine is never destroyed, but the pair must still be
  symmetrical).
- `audioDeviceSnapshot`:
  ```cpp
  auto& dm = _engine->getDeviceManager().deviceManager;
  auto* dev = dm.getCurrentAudioDevice();
  if (dev == nullptr || ! dev->isOpen()) return empty;                // --no-audio, open failed
  const int outs = dev->getActiveOutputChannels().countNumberOfSetBits();
  if (outs == 0) return empty;                                          // input-only: no output
  juce::String n = dev->getName(), t = dev->getTypeName();             // named locals (toRawUTF8 trap)
  s.deviceName = @(n.toRawUTF8()); s.deviceType = @(t.toRawUTF8());
  s.sampleRate = dev->getCurrentSampleRate();
  s.bufferSize = dev->getCurrentBufferSizeSamples();
  s.outputChannels = outs; s.running = dev->isPlaying();
  ```
- Leave `currentOutputDeviceName` / `currentSampleRate` / `currentBufferSize` as they are (the
  wrench menu and `ContentView.onAppear` read them; changing their `--no-audio` answer would make
  `ContentView` persist a fallback name into UserDefaults — out of scope). Add a one-line comment
  above them pointing to `audioDeviceSnapshot` as the truth for DISPLAY.

### Step 2 — Pure formatting unit (`objekat/Shared/AudioStatusText.swift`, new)

No model, no `L()` inside (the localised words are passed in) → compilable alone.

```swift
enum AudioStatusText {
    /// 44100 → "44.1k", 48000 → "48k", 88200 → "88.2k", 176400 → "176.4k", 22050 → "22.05k",
    /// 0 / negative / NaN → "". Up to two decimals, trailing zeros dropped, '.' always
    /// (POSIX, not the user's locale — it is a unit, like "dB").
    static func shortRate(_ hz: Double) -> String
    /// "Name — 48k — 512"; nil name → `none`; running == false → appends " — \(stopped)".
    /// A rate or buffer of 0 is omitted rather than printed as "0".
    static func line(name: String?, sampleRate: Double, bufferSize: Int,
                     running: Bool, none: String, stopped: String) -> String
}
```

The separator ` — ` is a glyph (no translation). Replace `AudioStatusTitleView.shortRate` at
`TimelineView.swift:2881` with `AudioStatusText.shortRate` (its old `%.1f` printed 22050 as
"22.1k").

### Step 3 — Observable status (`objekat/Shared/AudioDeviceStatus.swift`, new)

```swift
struct AudioDeviceSnapshot: Equatable { name: String?; type: String?; sampleRate: Double;
    bufferSize: Int; outputChannels: Int; running: Bool; static let none }

@MainActor @Observable final class AudioDeviceStatus {
    static let shared = AudioDeviceStatus()
    private(set) var snapshot: AudioDeviceSnapshot = .none
    private(set) var generation = 0          // bumped on every CHANGE (API waits on it)
    var text: String { AudioStatusText.line(..., none: L("audio.device.none"),
                                            stopped: L("audio.status.stopped")) }
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private weak var engine: OBJEngineCore?

    func attach(_ engine: OBJEngineCore)     // idempotent; sets engine.onAudioDeviceChanged; refresh()
    func refresh()                            // read snapshot; WRITE ONLY IF != (no idle repaint);
                                              // generation += 1; onChange?()
}
```

- **Only-on-change**: `refresh()` compares before assigning — the rule of
  "Polls qui repeignent à vide" even though this is not a poll.
- **The restart gap**: an external rate change produces "stopped" then "started" messages ~100 ms
  apart; they are coalesced but not guaranteed to be. If a refresh lands on `running == false`,
  schedule ONE deferred re-read (`asyncAfter 0.3 s`, at most 5 in a row, reset on any running
  snapshot). This is a bounded confirmation, not a steady-state poll: once running (or definitively
  stopped) nothing is scheduled. A device that is really dead therefore shows "stopped"; a restart
  shows at worst a ≤ 0.3 s flicker of the suffix.
- Attach in `ObjekatSession.start()` (`objekat/App/ObjekatSession.swift`) — it runs for the
  windowed AND the headless launch, and is idempotent — with
  `AudioDeviceStatus.shared.onChange = { [weak viewModel] in viewModel?.updateWindowSubtitle() }`.
  The initial `refresh()` in `attach` covers the startup message that fired before the block existed.

### Step 4 — The title (`EditViewModel.swift`, beside `updateWindowTitle`)

**Chosen approach: `NSWindow.subtitle`** (macOS 11+). On a window with NO toolbar — which is
this one — AppKit draws the subtitle on the SAME line, after the title, separated by an em dash,
in the secondary (grey) label colour, the whole group centred. That is exactly "centred, grey,
to the right of the project name", with: no view of ours in the title bar, no layout constraint,
no interference with the content toolbar or its narrow-window logic, the proxy icon and ⌘-click
kept, and the tabs untouched (the subtitle is per window; the engine is per process).

```swift
func updateWindowSubtitle() {
    guard let window = documentWindow else { return }          // nil headless: nothing to do
    let text = AudioDeviceStatus.shared.text
    if window.subtitle != text { window.subtitle = text }
}
```
Called from: `AudioDeviceStatus.onChange`, the end of `adoptDocumentWindow()` (the window was just
found), and `updateWindowTitle()` (cheap, and re-asserts after any title change — a tab switch, a
Save As). No SwiftUI `.navigationSubtitle`: SwiftUI would then also start managing the title and
could overwrite the project name the AppKit side sets.

**Step 4a — SPIKE, before anything else is built (10 min, user's eyes).** Put
`window.subtitle = "TEST — 48k — 512"` in `adoptDocumentWindow`, build, launch
(`--no-recent`), and ask the user to look. Expected: `Project — TEST — 48k — 512`, the tail grey,
on one line, centred. If AppKit instead draws it on a second line or not at all on this
`WindowGroup` window, fall back to **4b**; do NOT resurrect the right-side accessory (it did not
show, and it is not centred).

**Step 4b — Fallback only if 4a fails**: a non-interactive `NSTextField` (secondary label colour,
system font at the title's size) added to the title bar's own container
(`window.standardWindowButton(.closeButton)?.superview`), its leading anchored to the trailing
edge of the title's text field (found as the `NSTextField` in that container whose `stringValue ==
window.title`) + 6 pt, its centerY to the title's. Private view hierarchy → wrap in a function
that fails silently (nothing shown) if the title field is not found, and re-anchor in
`updateWindowTitle`. Title stays centred alone; the grey text hangs off its right.

### Step 5 — Remove the dead first attempt (`objekat/App/AudioTitleBar.swift`, `ContentView.swift`)

Delete `AudioStatusTitleView` (the 0.5 s poll), `AudioTitlebarStatus`,
`AudioStatusAccessoryController`, and the commented call + its comment in `ContentView.onAppear`.
Keep `AudioDeviceWatcher` and `AudioSettingsMenu` (the wrench menu) as they are. Update the file
header comment.

### Step 6 — Strings

- Reuse `audio.device.none`.
- New key `audio.status.stopped`: fr "arrêtée", en "stopped", es "detenida" (it qualifies
  "carte son" / "tarjeta", both feminine). Add via the catalogue with `"extractionState": "manual"`
  like its neighbours. Nothing else visible: device names are data, "k" and numbers are units.
- `tools/i18n/xcstrings.py check` and `orphans` must stay clean.

### Step 7 — API (`objekat/CommandAPI/Commands+Runtime.swift` or a new `Commands+Audio.swift`
registered in `CommandRegistry`), and `docs/command_api.md`

- `audio.status` → from `AudioDeviceStatus.shared`, the SAME object the title reads:
  `{device: str|null, type: str|null, sample_rate, buffer_size, output_channels, running,
    text, generation, window_subtitle: str|null, live: {…same fields read NOW from
    engine.audioDeviceSnapshot()…}}`.
  `window_subtitle` = `viewModel.titledWindow?.subtitle` (null headless — no window).
  `live` lets a script prove the cached snapshot equals the engine at that instant.
- `audio.devices` → `{outputs: [names], sample_rates: [..], buffer_sizes: [..]}` (engine lists).
- `audio.set_buffer_size {frames}`, `audio.set_sample_rate {hz}`, `audio.set_device {name}` →
  call the existing engine setters (NOT `AudioOutputDevice.shared` — a script must not write the
  user's UserDefaults), then `await` until `generation` moves (poll the observable every 20 ms,
  timeout 3 s) and answer the new status + `settled: bool`. `undo: .none`. `invalid_state` if no
  engine; `bad_params` if the value is not in the device's available list.
- `app.info`: re-route `output_device` / `sample_rate` / `buffer_size` to the snapshot (so
  `--no-audio` answers `output_device: null`, the truth) and add `audio_running`. No existing
  tool reads those fields (grepped `tools/`). Document the change.
- `docs/command_api.md`: new "Audio device" section: the fields, that `set_*` touch the REAL
  hardware and Tracktion rewrites `~/Library/objekat/Settings.xml` on every device change (a
  script must restore what it changes), and that `set_sample_rate` changes the device's nominal
  rate for the WHOLE system (CoreAudio), not only for OBJEKAT.

### Step 8 — Docs

CLAUDE.md "Current state" entry (what was verified, what was not seen); glossary unchanged
(no new term); the permanent-point candidate: "`getCurrentAudioDevice()` is non-null under
`--no-audio` — the device is created, never opened: test `isOpen()`".

### Adjacent defect, flagged, NOT in scope unless the user says so

`AudioSettingsMenu.deviceBinding` ticks `AudioOutputDevice.shared.name` (the wish). After an
unplug JUCE falls back to another device and the wrench menu keeps ticking the unplugged one while
the title (correctly) names the fallback. Same family as this request ("always the right card"):
suggest a follow-up where the device Picker ticks the snapshot's name when it is in the list.

---

## 3. Test plan

Every launch with `--no-recent`. `/tmp/o.sock`-style SHORT socket paths (103-byte limit).

### T1 — Build
- `xcodebuild -project objekat.xcodeproj -scheme objekat -configuration Debug build`
  → succeeds; warning count = the 1518 baseline, **0 new** (recount the same way as the tabs
  entry did; a line-number shift is not a new warning).

### T2 — Standalone unit: `tools/test_audio_status_text.swift` (new)
`swiftc -parse-as-library ../objekat/Shared/AudioStatusText.swift test_audio_status_text.swift -o /tmp/ast && /tmp/ast`
- `shortRate`: 44100→"44.1k", 48000→"48k", 88200→"88.2k", 96000→"96k", 176400→"176.4k",
  192000→"192k", 22050→"22.05k", 11025→"11.03k" or "11.025k" (decide and pin), 0→"", -1→"",
  `.nan`→"", 44100.0000001→"44.1k" (no float noise).
- `line`: full ("MOTU M2 — 48k — 512"); nil name → `none` exactly (no dashes); running false →
  "… — 512 — stopped"; buffer 0 omitted; rate 0 omitted; a name containing " — " is kept verbatim.
- Locale independence: run once with `LC_ALL=fr_FR.UTF-8` → still "44.1k", never "44,1k".

### T3 — Headless scenario: `tools/scenario_audio_device.py` (new), asserting
Pattern of the other `scenario_*.py` (`ObjekatClient`, `check()`, exit 0/1). Two phases, each on
its OWN fresh instance:

**Phase A — `--headless --api --no-audio --no-recent --language=en --socket=…`**
- `audio.status.device` is null, `sample_rate` 0, `buffer_size` 0, `running` false,
  `text == "No audio device"`, `window_subtitle` null.
- `audio.status.live` equals the cached fields.
- `app.info.output_device` is null (the lie of trap 1 is gone).
- `audio.set_buffer_size` → `invalid_state` or `bad_params` (no open device), nothing crashes.
- No window: `CGWindowListCopyWindowInfo` on the pid → empty.

**Phase B — `--headless --api --no-recent --language=en --socket=…` (real device)**
The script FIRST copies `~/Library/objekat/Settings.xml` to the scratch dir and restores it
byte-for-byte in a `finally` AFTER the instance has quit (Tracktion saves on every change and at
exit). It also records the starting buffer/rate and sets them back through the API before quitting.
- `device` non-null, equals the name CoreAudio reports for that device (cross-check: a tiny
  `swift -e` / `system_profiler SPAudioDataType -json` lookup that the name exists as an output
  device); `sample_rate > 0`, `buffer_size > 0`, `output_channels >= 1`, `running` true.
- `text == f"{device} — {shortRate(sr)} — {buffer}"` recomputed in Python from the numeric fields.
- cached == `live` (every field).
- `app.info` fields == `audio.status` fields.
- **Buffer change follows**: pick a size from `audio.devices.buffer_sizes` ≠ current (prefer 256
  or 1024) → `audio.set_buffer_size` → `settled` true, `buffer_size` == requested (or, if JUCE
  picked the nearest, == `live.buffer_size` — the assertion is cached == live, and the value
  moved), `generation` strictly increased, `running` true. Then back to the original → same checks.
- **Idempotence / no idle churn**: two `audio.status` 1 s apart with nothing done → same
  `generation` (nothing writes the observable when nothing changed).
- `audio.set_buffer_size` with a value not in the list → `bad_params`, `generation` unchanged.
- Optional `--mutate-rate` flag (off by default, because it changes the hardware's nominal rate
  for the whole system): set another available rate → `sample_rate` follows, cached == live;
  restore.
- Optional `--external-rate` flag (off by default): simulates Audio MIDI Setup — a helper
  `swift` snippet sets `kAudioDevicePropertyNominalSampleRate` on the device by UID OUTSIDE the
  app; the script then waits (≤ 3 s) for `generation` to move and asserts `sample_rate` == the new
  rate, `running` true, cached == live; then restores the rate the same way. This is the one
  automated proof of the "changed outside the app" road (property listener → restart →
  change message).
- Optional `--switch-device NAME`: `audio.set_device` to a second output (e.g. the built-in
  speakers) → `device == NAME`, cached == live; switch back.

**Phase C — UI mode (`--api --no-recent --language=en --socket=…`, NO `--headless`)**, like
`scenario_navigation.py` (the window appears; hands off):
- `window_subtitle == text` at start (after `wait_idle`).
- After `audio.set_buffer_size` to another value: `window_subtitle` has followed (the title really
  is driven by the snapshot, not only the API field). Restore.
- `tab.new` then `tab.select` back: `window_subtitle` unchanged and still == `text`.
- `project.save_as` to a scratch path: title changes, `window_subtitle` still == `text`.
- Same run with `--language=fr` under `--no-audio`: `window_subtitle == "Aucune carte son"`.

### T4 — Non-regression (each on its own fresh headless `--no-audio` instance)
`smoke.jsonl` (`--exec`) clean; `scenario_families.py` 191 OK; `scenario_markers.py` ALL PASS;
`scenario_plugin_selection.py` 58; `scenario_plugin_state_undo.py` ALL PASS;
`scenario_relink.py` ALL PASS; `scenario_export_preview.py` OK; `scenario_consolidate.py` ALL
PASS; `scenario_tabs.py` ALL PASS; the standalone Swift suites in `tools/test_*.swift`; the
selection HUD's samples line still compiles through `AudioStatusText.shortRate`.
i18n: `tools/i18n/xcstrings.py check` (one key more than before, 3 languages, nothing missing)
and `orphans` empty (the deleted `AudioStatusTitleView` used only `audio.device.none`, still used).
No window on any headless pid.

### T5 — For the user's eyes and hands (cannot be done here — list it explicitly)
1. The spike (4a): grey, one line, centred, right of the name; with a dirty project (`•`); in a
   narrow window (700 pt) — who truncates first, the name or the subtitle?
2. Wrench menu → change buffer 512 → 256: the title follows at once.
3. Wrench menu → change device: follows.
4. Audio MIDI Setup → change the open device's rate: the title follows within ~0.3 s.
5. Unplug the USB interface in use: the title names the fallback JUCE opened (or "No audio
   device"); replug: the title stays on the fallback (JUCE does not go back) — and the wrench menu
   still ticks the unplugged one (the adjacent defect above).
6. Change the system default output in System Settings while OBJEKAT plays on another card: the
   title does NOT change (correct: the engine did not).
7. Launch with the chosen card absent: the title names what actually opened.
8. The three languages with no device (`--no-audio --language=fr|en|es`).
