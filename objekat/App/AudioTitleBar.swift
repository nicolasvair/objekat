//
//  AudioTitleBar.swift
//  objekat
//
//  The 'audio settings' menu (the wrench, in the toolbar): device / sample rate / buffer size.
//  The device really in use, shown to the user, is the window's subtitle now
//  (@see EditViewModel.updateWindowSubtitle, AudioDeviceStatus) — the first attempt at it lived
//  HERE, as a title-bar accessory view that polled the engine every 0.5 s; it never showed
//  reliably under this SwiftUI WindowGroup and was removed 28 September 2026
//  (@see plan_titlebar_audio_device.md).
//

import SwiftUI
import AppKit
import Combine
import CoreAudio

// MARK: - Watching the CoreAudio devices

/// Watches the system's list of audio devices and bumps `generation` on every change (a device
/// plugged in or out, an aggregate created…). Any view that reads `generation` in its `body` is
/// therefore rebuilt when something is plugged in — with no periodic polling.
@Observable
@MainActor
final class AudioDeviceWatcher {
    static let shared = AudioDeviceWatcher()

    private(set) var generation = 0

    private init() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { _, _ in
            MainActor.assumeIsolated { AudioDeviceWatcher.shared.generation &+= 1 }
        }
    }
}

// MARK: - The 'audio settings' menu
//
// Gathers the current device's settings under a single icon: audio device, sample rate, buffer size.
// It is a transient popover on the shared tree picker (`Shared/TreePickerPopover.swift`), not a native
// `Menu`: a menu closes on every click and cannot say WHY a row is disabled, and one sets a card, then
// a rate, then a buffer in one go. What is listed and ticked is `AudioMenuModel`'s (pure, asserted
// alone); this view only reads the facts and applies a click.
//
// Everything the rows say is READ through observation, inside the popover's own body: the engine's
// snapshot (`AudioDeviceStatus`, what is really open) and the CoreAudio watcher's generation (a card
// plugged or unplugged). So the popover stays open and re-ticks itself when the engine has answered —
// the lists (supplied by the engine) always reflect the real state, freshly plugged devices included.

struct AudioSettingsMenu: View {
    @Bindable var viewModel: EditViewModel
    @State private var shown = false
    /// Why the last choice of an input card was refused (a recording is running…): said under the rows
    /// until the popover is closed or a choice succeeds.
    @State private var inputError: String? = nil

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "wrench.and.screwdriver")
        }
        .buttonStyle(.borderless)
        .frame(width: 26)
        .help(L("audio.menu.help"))
        .onChange(of: shown) { _, now in if !now { inputError = nil } }
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            TreePickerPopover(sections: { Self.sections(engine: viewModel.engine, inputError: inputError) },
                              closesOnChoose: false, minWidth: 260,
                              onChoose: { choose($0) },
                              dismiss: { shown = false })
        }
    }

    // MARK: The rows (read through observation)

    /// Evaluated in the popover's `body`: the two reads below (`AudioDeviceWatcher.generation` and the
    /// snapshot) are what redraw it when a card comes or goes or when the engine has changed something.
    @MainActor
    static func sections(engine: OBJEngineCore?, inputError: String? = nil) -> [TreePickerSection] {
        _ = AudioDeviceWatcher.shared.generation
        let snap = AudioDeviceStatus.shared.snapshot
        let state = AudioMenuState(
            outputDevices: (engine?.availableOutputDevices() as? [String]) ?? [],
            // Ticks the device the engine ACTUALLY has open: the SAME snapshot the window's subtitle
            // and `audio.status` read, never `AudioOutputDevice.shared` (the WISH). After an unplug,
            // JUCE falls back to another device and keeps it even once the original is replugged
            // (@see plan_titlebar_audio_device.md); `AudioOutputDevice.shared.name` is the fallback
            // only before any change message has landed (`snapshot.name == nil`, or `--no-audio`).
            currentOutput: snap.name ?? AudioOutputDevice.shared.name,
            sampleRates: (engine?.availableSampleRates() ?? []).map { $0.doubleValue },
            currentSampleRate: snap.sampleRate,
            sampleRateNote: rateDecisionNote(snap),
            bufferSizes: (engine?.availableBufferSizes() ?? []).map { $0.intValue },
            currentBufferSize: snap.bufferSize,
            // The cards with inputs OTHER than the output card (its own are the row « same card »). The
            // engine never lists its private aggregate; the choice ticked is the engine's, not the wish.
            inputCards: ((engine?.availableInputDevices() as? [[String: Any]]) ?? []).compactMap { d in
                guard (d["same_as_output"] as? Bool) != true, let uid = d["uid"] as? String,
                      let name = d["name"] as? String else { return nil }
                return AudioMenuInputCard(uid: uid, name: name)
            },
            currentInput: snap.inputDeviceUID,
            inputNote: inputNote(snap, error: inputError))
        return AudioMenuModel.sections(state, labels: AudioMenuLabels(
            output: L("audio.menu.device"), input: L("audio.menu.input"),
            sameInputCard: L("audio.menu.input.same"), sampleRate: L("audio.menu.sampleRate"),
            buffer: L("audio.menu.buffer"), noOutputDevice: L("audio.menu.noDevice")))
    }

    // MARK: A click (apply and restart if needed)

    private func choose(_ id: String) {
        switch AudioMenuModel.action(forID: id) {
        case .output(let name):
            // `--virtual-audio` is a test fixture: it must not become the remembered choice.
            if !OBJEngineCore.isVirtualAudio() {
                AudioOutputDevice.shared.name = name   // publishes and persists (previews aligned)
            }
            viewModel.engine?.setOutputDevice(name)    // applies to the engine
        case .input(let uid):
            // The engine decides (a recording refuses, a card may not open); what it ends up holding is
            // the choice remembered — `--virtual-audio` being a fixture, it never becomes one.
            inputError = viewModel.engine?.setInputDevice(uid)
            if !OBJEngineCore.isVirtualAudio() {
                AudioInputDevice.shared.uid = viewModel.engine?.currentInputDeviceUID()
            }
            AudioDeviceStatus.shared.refresh()
        case .sampleRate(let hz):
            viewModel.engine?.setSampleRate(hz)
        case .buffer(let frames):
            viewModel.engine?.setBufferSize(frames)
        case nil:
            break
        }
    }

    // MARK: Formatting

    /// The sentence under the input rows: a refusal first, else what the engine says of the inputs it is
    /// opening. Nil while all is quiet.
    static func inputNote(_ s: AudioDeviceSnapshot, error: String?) -> String? {
        if let error { return L("audio.menu.input.failed", error) }
        switch s.inputsState {
        case .stabilising: return L("audio.menu.input.stabilising")
        case .failed: return L("audio.menu.input.failed", s.inputsMessage ?? "")
        case .closed, .open: return nil
        }
    }

    /// The sentence under the sample-rate rows when the policy changed (or could not change) the
    /// card's rate: `nil` for `adopt` and `unknown`, which say nothing.
    static func rateDecisionNote(_ s: AudioDeviceSnapshot) -> String? {
        switch s.rateDecision {
        case .fallback:
            return L("audio.menu.sampleRate.fallback", AudioMenuModel.formatRate(s.deviceRateBeforeDecision),
                     AudioMenuModel.formatRate(s.sampleRate))
        case .outOfRangeKept:
            return L("audio.menu.sampleRate.outOfRange", AudioMenuModel.formatRate(s.deviceRateBeforeDecision))
        case .adopt, .unknown:
            return nil
        }
    }
}
