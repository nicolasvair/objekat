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
// Gathers the current device's three settings under a single icon: audio device, sample rate,
// latency/buffer size. Each group is a Picker → rendered as a native submenu with a tick on the
// current value. The content is built lazily when the menu opens, so the lists (supplied by the
// engine) always reflect the real state — including devices freshly plugged in, re-enumerated
// on every click.

struct AudioSettingsMenu: View {
    @Bindable var viewModel: EditViewModel

    /// The list of audio devices, re-enumerated on appearance, on hovering the icon (so just
    /// before the click that opens the menu) and on every change CoreAudio reports.
    @State private var devices: [String] = []

    var body: some View {
        Menu {
            if !devices.isEmpty {
                Picker(L("audio.menu.device"), selection: deviceBinding) {
                    ForEach(devices, id: \.self) { Text($0).tag($0) }
                }
            }

            let rates = (viewModel.engine?.availableSampleRates() ?? []).map { $0.doubleValue }
            if !rates.isEmpty {
                Picker(L("audio.menu.sampleRate"), selection: sampleRateBinding) {
                    ForEach(rates, id: \.self) { Text(Self.formatRate($0)).tag($0) }
                }
            }

            let buffers = Self.usefulBufferSizes(
                (viewModel.engine?.availableBufferSizes() ?? []).map { $0.intValue },
                current: viewModel.engine.map { Int($0.currentBufferSize()) } ?? 0)
            if !buffers.isEmpty {
                let sr = viewModel.engine?.currentSampleRate() ?? 0
                Picker(L("audio.menu.buffer"), selection: bufferBinding) {
                    ForEach(buffers, id: \.self) { Text(Self.formatBuffer($0, sampleRate: sr)).tag($0) }
                }
            }
        } label: {
            Image(systemName: "wrench.and.screwdriver")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 26)
        .help(L("audio.menu.help"))
        .onAppear(perform: reloadDevices)
        // The hover necessarily comes before the click that opens the menu: the list is therefore
        // fresh by the time it shows, even if CoreAudio reported nothing (SwiftUI gives no hook
        // for 'the menu is opening').
        .onHover { inside in if inside { reloadDevices() } }
        // A device plugged in or out: the list updates on its own.
        .onChange(of: AudioDeviceWatcher.shared.generation) { _, _ in reloadDevices() }
    }

    private func reloadDevices() {
        let fresh = (viewModel.engine?.availableOutputDevices() as? [String]) ?? []
        if fresh != devices { devices = fresh }
    }

    // MARK: Bindings (read = the engine's truth, write = apply and restart if needed)

    private var deviceBinding: Binding<String> {
        // Ticks the device the engine ACTUALLY has open — read from `AudioDeviceStatus`, the
        // SAME snapshot the window's subtitle and `audio.status` read, never
        // `AudioOutputDevice.shared` (the WISH). After an unplug, JUCE falls back to another
        // device and keeps it even once the original is replugged (@see
        // plan_titlebar_audio_device.md, the adjacent defect it flags): ticking the requested
        // name there would show a choice that is not what plays, the very thing the title bar
        // exists to stop happening. `AudioOutputDevice.shared.name` is the fallback only before
        // any change message has ever landed (`snapshot.name == nil`, or `--no-audio`).
        Binding(get: {
                    AudioDeviceStatus.shared.snapshot.name ?? AudioOutputDevice.shared.name
                },
                set: { name in
                    AudioOutputDevice.shared.name = name       // publishes and persists (previews aligned)
                    viewModel.engine?.setOutputDevice(name)    // applies to the engine
                })
    }

    private var sampleRateBinding: Binding<Double> {
        Binding(get: { viewModel.engine?.currentSampleRate() ?? 0 },
                set: { viewModel.engine?.setSampleRate($0) })
    }

    private var bufferBinding: Binding<Int> {
        Binding(get: { viewModel.engine.map { Int($0.currentBufferSize()) } ?? 0 },
                set: { viewModel.engine?.setBufferSize($0) })
    }

    // MARK: Buffer sizes

    /// The sizes kept in the menu: the usual powers of 2. CoreAudio exposes plenty of others
    /// (14, 96, 176…) which serve no purpose and drown the list. The CURRENT value is always
    /// kept, even outside the list, so that the Picker ticks a row.
    static let standardBufferSizes: [Int] = [32, 64, 128, 256, 512, 1024, 2048]

    static func usefulBufferSizes(_ available: [Int], current: Int) -> [Int] {
        var kept = available.filter { standardBufferSizes.contains($0) }
        // An exotic device exposing no power of 2: we keep its list as it is rather than
        // present an empty menu.
        if kept.isEmpty { kept = available }
        if current > 0, !kept.contains(current) { kept.append(current) }
        return kept.sorted()
    }

    // MARK: Formatting

    static func formatRate(_ hz: Double) -> String {
        let k = hz / 1000
        return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
    }

    static func formatBuffer(_ frames: Int, sampleRate: Double) -> String {
        guard sampleRate > 0 else { return "\(frames)" }
        let ms = Double(frames) / sampleRate * 1000
        return String(format: "%d — %.1f ms", frames, ms)
    }
}
