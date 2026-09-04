import Foundation
import CoreAudio

// MARK: - Output audio device shared by the UI, the engine and the previews
//
// The engine (JUCE) plays out of the device chosen in the toolbar, but the previews
// (the sound library's AVAudioPlayer) play by default on the SYSTEM device: as soon as the
// toolbar choice ≠ the system default, preview and timeline were not playing on the same card.
// This singleton publishes the name of the chosen device (persisted) and resolves its CoreAudio
// UID — `AVAudioPlayer.currentDevice` expects a UID, not a name. JUCE's names come from
// CoreAudio (kAudioObjectPropertyName), so matching by name is reliable.

@MainActor
@Observable
final class AudioOutputDevice {
    static let shared = AudioOutputDevice()

    /// Name of the output device chosen in the toolbar. Persisted: reapplied to the engine at
    /// launch (if it still exists), otherwise realigned on the engine's current device.
    var name: String {
        didSet { UserDefaults.standard.set(name, forKey: "pref.outputDevice") }
    }

    private init() {
        name = UserDefaults.standard.string(forKey: "pref.outputDevice") ?? ""
    }

    /// CoreAudio UID of the chosen device — to be set on `AVAudioPlayer.currentDevice` before
    /// `play()`. nil if not found (device unplugged…) → leave the system default alone.
    var uid: String? { Self.uid(forOutputDeviceNamed: name) }

    // MARK: Resolving a name into a UID (CoreAudio)

    nonisolated static func uid(forOutputDeviceNamed name: String) -> String? {
        guard !name.isEmpty else { return nil }
        for dev in allDeviceIDs() where hasOutput(dev) && deviceName(dev) == name {
            return deviceUID(dev)
        }
        return nil
    }

    private nonisolated static func allDeviceIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private nonisolated static func stringProperty(_ dev: AudioObjectID,
                                                   _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0)
        }
        guard err == noErr else { return nil }
        return value as String?
    }

    private nonisolated static func deviceName(_ dev: AudioObjectID) -> String? {
        stringProperty(dev, kAudioObjectPropertyName)
    }

    private nonisolated static func deviceUID(_ dev: AudioObjectID) -> String? {
        stringProperty(dev, kAudioDevicePropertyDeviceUID)
    }

    /// True if the device has at least one OUTPUT stream (ruling out microphones of the same name).
    private nonisolated static func hasOutput(_ dev: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }
}
