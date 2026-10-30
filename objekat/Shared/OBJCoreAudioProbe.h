// Does the output device carry ITS OWN input channels?
//
// Why it exists. The engine opens the card's inputs on demand (`-openAudioInputs`) by naming the
// SAME device for the input as for the output. JUCE then looks the name up in the list of input
// devices and the list of output devices, and when the two entries are not the same CoreAudio device
// it builds an `AudioIODeviceCombiner` (an aggregate of two devices). That is exactly what AirPods
// are: CoreAudio exposes TWO devices with one name — the speaker (output only) and the microphone
// (input only). Opening the microphone flips the AirPods into the call profile (HFP), CoreAudio
// removes and republishes both devices, and the combiner restarts itself from a CoreAudio thread
// while the main thread is still inside `setAudioDeviceSetup`: a crash (2026-10-29,
// `HALC_ShellPlugIn Connection Queue`, `AudioIODeviceCombiner::restartAsync`).
//
// So before opening anything, ask the system — through the plain C API, which neither opens a
// device nor makes macOS ask for the microphone — whether the output device is also an input device.
//
// Two layers on purpose:
//   * `classify` is PURE (a list of descriptions in, a verdict out) so the AirPods case, a duplicate
//     name and the rest are asserted with no card: `tools/test_coreaudio_probe.cpp`;
//   * `listDevices` / `outputOwnership` are the thin CoreAudio layer on top.
//
// Several devices with the same name. The system may list two output-capable devices called alike
// (two identical USB interfaces, a leftover aggregate). JUCE picks one by name and we cannot tell
// which, so the verdict is the CAUTIOUS one: `ownInputs` only when EVERY output-capable device of
// that name carries inputs; otherwise `separateInputs`. A false refusal costs a button; a false
// acceptance costs a crash.

#pragma once

#include <algorithm>
#include <string>
#include <vector>

#if defined(__APPLE__)
  #include <CoreAudio/CoreAudio.h>
  #include <CoreFoundation/CoreFoundation.h>
#endif

namespace objcoreaudio {

/// What the probe knows about one CoreAudio device: its name and how many channels it has on each side.
struct DeviceInfo {
    std::string name;          // UTF-8, as the system names it (what JUCE lists)
    int outputChannels = 0;
    int inputChannels  = 0;
};

enum class Ownership {
    ownInputs,        // the output device carries input channels itself: one device, one clock
    separateInputs,   // inputs exist under that name but NOT on the output device itself (AirPods)
    noInputs,         // no input of that name anywhere (speakers): nothing to open, nothing separate
    noSuchOutput,     // no output-capable device has that name (cannot say)
};

/// Names compare after trimming blanks at both ends (some drivers pad).
inline std::string trimmed(const std::string& s)
{
    const char* ws = " \t\r\n";
    const size_t b = s.find_first_not_of(ws);
    if (b == std::string::npos) return {};
    return s.substr(b, s.find_last_not_of(ws) - b + 1);
}

/// The verdict. Pure.
inline Ownership classify(const std::vector<DeviceInfo>& devices, const std::string& outputName)
{
    const std::string want = trimmed(outputName);
    int outputCapable = 0, withInputs = 0;
    bool inputOnlyTwin = false;
    for (const auto& d : devices) {
        if (trimmed(d.name) != want) continue;
        if (d.outputChannels <= 0) { if (d.inputChannels > 0) inputOnlyTwin = true; continue; }
        ++outputCapable;
        if (d.inputChannels > 0) ++withInputs;
    }
    if (outputCapable == 0) return Ownership::noSuchOutput;
    if (withInputs == outputCapable) return Ownership::ownInputs;
    // Some output-capable device of that name has no inputs. Inputs under that name (an input-only
    // twin, or another same-name device that has some) make it the AirPods case; none at all is a
    // plain pair of speakers.
    return (inputOnlyTwin || withInputs > 0) ? Ownership::separateInputs : Ownership::noInputs;
}

#if defined(__APPLE__)

namespace detail {

inline bool channelCount(AudioObjectID dev, AudioObjectPropertyScope scope, int& out)
{
    AudioObjectPropertyAddress a { kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, nullptr, &size) != noErr) return false;
    if (size < sizeof(UInt32)) { out = 0; return true; }      // no stream on this side
    std::vector<unsigned char> raw(std::max<size_t>(size, sizeof(AudioBufferList)));
    auto* list = reinterpret_cast<AudioBufferList*>(raw.data());
    if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, list) != noErr) return false;
    int n = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) n += (int) list->mBuffers[i].mNumberChannels;
    out = n;
    return true;
}

inline bool deviceName(AudioObjectID dev, std::string& out)
{
    AudioObjectPropertyAddress a { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef cf = nullptr;
    UInt32 size = sizeof(cf);
    if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, &cf) != noErr || cf == nullptr) return false;
    char buf[512];
    const bool ok = CFStringGetCString(cf, buf, sizeof(buf), kCFStringEncodingUTF8);
    CFRelease(cf);
    if (!ok) return false;
    out = buf;
    return true;
}

} // namespace detail

/// Every CoreAudio device the system lists right now. Empty if the system answers nothing. Never opens
/// a device.
inline std::vector<DeviceInfo> listDevices()
{
    std::vector<DeviceInfo> result;
    AudioObjectPropertyAddress a { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size) != noErr || size == 0) return result;
    std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, ids.data()) != noErr) return result;
    ids.resize(size / sizeof(AudioObjectID));
    for (AudioObjectID id : ids) {
        DeviceInfo d;
        if (!detail::deviceName(id, d.name)) continue;
        if (!detail::channelCount(id, kAudioObjectPropertyScopeOutput, d.outputChannels)) continue;
        if (!detail::channelCount(id, kAudioObjectPropertyScopeInput, d.inputChannels)) continue;
        result.push_back(std::move(d));
    }
    return result;
}

/// The verdict for the device called `outputName`, from the live system.
inline Ownership outputOwnership(const std::string& outputName)
{
    return classify(listDevices(), outputName);
}

#endif // __APPLE__

} // namespace objcoreaudio
