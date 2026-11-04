// A private AGGREGATE device, to record on one card while playing on another.
//
// Why it exists. The sound card of the INPUT may differ from the one of the OUTPUT (a studio interface
// to play on, a microphone to record on). JUCE's own answer is `AudioIODeviceCombiner` (two devices
// glued in the host): it plays with holes (no resampling between the two clocks) and its
// `restartAsync` crashed with AirPods (2026-10-29). The system's answer is an aggregate device: ONE
// device with ONE clock that the HAL feeds from several, drift-compensating the others. The engine
// then sees a plain CoreAudio device with both sides and never builds a combiner.
//
// What an aggregate is, as MEASURED on real cards (`tools/probe_aggregate_real_cards.py`, 2026-11-04):
//   * built from the sub-devices' UIDs, ready at once; private (`kAudioAggregateDeviceIsPrivateKey`):
//     visible to THIS process only (so the engine lists it, hence the masking below) and gone with it;
//   * its streams and channels follow the sub-device LIST ORDER: the input channels of the first
//     sub-device come first. So the card we want is a WINDOW (K, N) of the aggregate's channels, K
//     being the number of input channels of the sub-devices listed before it;
//   * its nominal rate is the master's; a sub-device on another rate is accepted (the HAL resamples
//     the drift-compensated one) and its own rate is left alone;
//   * destroying it while it runs is safe.
//
// The output card is the MASTER (`kAudioAggregateDeviceMasterSubDeviceKey`): it is what the user hears
// and what the project plays on, its clock wins. The input card is drift-compensated. The input card
// is LISTED FIRST, and that is a choice of the engine's, not of the HAL: the engine addresses its
// inputs by index (a channel's `first`, the names, the meters, the recordings), so the input window
// starts at 0 (K = 0, nothing listed before it) and every one of those indices stays the card's own.
// The OUTPUT side is addressed by the active-channel mask alone, so it can start anywhere: it starts
// at the number of output channels the input card has (J, 0 for a microphone). The two windows keep
// each side's other channels (the output card's own inputs, the input card's own outputs) out of the
// engine's reach.
//
// Two layers on purpose, like OBJCoreAudioProbe.h:
//   * the PURE part (names, masking, windows, the no-combiner guard) is asserted with no card:
//     `tools/test_aggregate_device.cpp`;
//   * the thin CoreAudio part creates and destroys.
//
// NAME MASKING. A private aggregate is listed by the process that made it. Its name must therefore
// never reach a menu, an API answer, the window title or Settings.xml (the next launch would look for
// a device that is gone): `isOurs` is asked at each of those doors. The name carries a fixed prefix
// and nothing else of the user's.

#pragma once

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#if defined(__APPLE__)
  #include <CoreAudio/CoreAudio.h>
  #include <CoreFoundation/CoreFoundation.h>
  #include <unistd.h>
#endif

namespace objaggregate {

/// What the aggregate needs to know about a card.
struct Card {
    std::string uid;
    std::string name;
    int inputChannels  = 0;
    int outputChannels = 0;
};

/// The channels of the aggregate the engine opens, as windows.
struct Window {
    int inFirst = 0, inCount = 0;      // the INPUT card's input channels (K, N)
    int outFirst = 0, outCount = 0;    // the OUTPUT card's output channels (J, M)
    bool valid = false;
};

/// The aggregate's sub-device list: input card first, output card (the master) second.
inline std::vector<std::string> subDeviceUIDs(const Card& output, const Card& input)
{
    return { input.uid, output.uid };
}

/// The windows, by list order (input card listed first). Pure.
inline Window window(const Card& output, const Card& input)
{
    Window w;
    w.inFirst  = 0;                              // K: the input channels of what is listed before = none
    w.inCount  = input.inputChannels;            // N
    w.outFirst = input.outputChannels;           // J: the output channels of what is listed before
    w.outCount = output.outputChannels;          // M
    w.valid = w.outCount > 0 && w.inCount > 0;
    return w;
}

/// The aggregate's channel counts the HAL must show before we use it (both sides, sum of the two
/// sub-devices). Pure.
inline int expectedInputs(const Card& output, const Card& input)  { return output.inputChannels + input.inputChannels; }
inline int expectedOutputs(const Card& output, const Card& input) { return output.outputChannels + input.outputChannels; }

// MARK: Names

inline const char* namePrefix() { return "OBJEKAT private input aggregate"; }

/// The name (and the UID) of the aggregate of this process. `serial` tells two successive
/// aggregates apart: the HAL may still be tearing the previous one down.
inline std::string makeName(int pid, int serial)
{
    return std::string(namePrefix()) + " " + std::to_string(pid) + "." + std::to_string(serial);
}

inline std::string makeUID(int pid, int serial)
{
    return "org.labelpeche.objekat.aggregate." + std::to_string(pid) + "." + std::to_string(serial);
}

inline bool isOurs(const std::string& name)
{
    return name.compare(0, std::string(namePrefix()).size(), namePrefix()) == 0;
}

/// A list without our aggregate(s). Pure.
inline std::vector<std::string> withoutOurs(const std::vector<std::string>& names)
{
    std::vector<std::string> kept;
    for (const auto& n : names) if (!isOurs(n)) kept.push_back(n);
    return kept;
}

// MARK: The no-combiner guard

/// JUCE builds an `AudioIODeviceCombiner` as soon as the output and the input of the setup are named
/// differently. The engine asks this BEFORE `setAudioDeviceSetup` and refuses to go on when it would.
/// Pure.
inline bool wouldCombine(const std::string& outputName, const std::string& inputName)
{
    return !inputName.empty() && !outputName.empty() && inputName != outputName;
}

#if defined(__APPLE__)

namespace detail {

inline bool stringProp(AudioObjectID o, AudioObjectPropertySelector sel, std::string& out)
{
    AudioObjectPropertyAddress a { sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef cf = nullptr;
    UInt32 size = sizeof(cf);
    if (AudioObjectGetPropertyData(o, &a, 0, nullptr, &size, &cf) != noErr || cf == nullptr) return false;
    char buf[512];
    const bool ok = CFStringGetCString(cf, buf, sizeof(buf), kCFStringEncodingUTF8);
    CFRelease(cf);
    if (ok) out = buf;
    return ok;
}

inline int channels(AudioObjectID dev, AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress a { kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, nullptr, &size) != noErr || size < sizeof(UInt32)) return 0;
    std::vector<unsigned char> raw(std::max<size_t>(size, sizeof(AudioBufferList)));
    auto* list = reinterpret_cast<AudioBufferList*>(raw.data());
    if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, list) != noErr) return 0;
    int n = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) n += (int) list->mBuffers[i].mNumberChannels;
    return n;
}

} // namespace detail

/// The device with this UID, or kAudioObjectUnknown. Never opens it.
inline AudioObjectID deviceByUID(const std::string& uid)
{
    CFStringRef cf = CFStringCreateWithCString(kCFAllocatorDefault, uid.c_str(), kCFStringEncodingUTF8);
    if (cf == nullptr) return kAudioObjectUnknown;
    AudioObjectPropertyAddress a { kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal,
                                   kAudioObjectPropertyElementMain };
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    const OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(cf), &cf, &size, &dev);
    CFRelease(cf);
    return st == noErr ? dev : kAudioObjectUnknown;
}

/// What the system says about the card with this UID right now; false if it is not there.
inline bool describe(const std::string& uid, Card& out)
{
    const AudioObjectID dev = deviceByUID(uid);
    if (dev == kAudioObjectUnknown) return false;
    Card c;
    c.uid = uid;
    if (!detail::stringProp(dev, kAudioObjectPropertyName, c.name)) return false;
    c.inputChannels  = detail::channels(dev, kAudioObjectPropertyScopeInput);
    c.outputChannels = detail::channels(dev, kAudioObjectPropertyScopeOutput);
    out = c;
    return true;
}

/// The card's nominal rate now (0 = unknown) and the rates it offers (empty = unknown).
inline double nominalRate(const std::string& uid)
{
    const AudioObjectID dev = deviceByUID(uid);
    if (dev == kAudioObjectUnknown) return 0;
    AudioObjectPropertyAddress a { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 r = 0; UInt32 size = sizeof(r);
    return AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, &r) == noErr ? (double) r : 0.0;
}

inline std::vector<double> availableRates(const std::string& uid)
{
    std::vector<double> out;
    const AudioObjectID dev = deviceByUID(uid);
    if (dev == kAudioObjectUnknown) return out;
    AudioObjectPropertyAddress a { kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, nullptr, &size) != noErr || size == 0) return out;
    std::vector<AudioValueRange> ranges(size / sizeof(AudioValueRange));
    if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, ranges.data()) != noErr) return out;
    for (const auto& r : ranges) {
        out.push_back(r.mMinimum);
        if (r.mMaximum != r.mMinimum) out.push_back(r.mMaximum);
        // A continuous range lists its ends only: the usual rates inside it are offered too.
        for (double c : { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 })
            if (c > r.mMinimum && c < r.mMaximum) out.push_back(c);
    }
    return out;
}

/// Asks the card to run at `rate` (a nominal rate is the card's, for every application) and waits, bounded,
/// until it says so. True if it does.
inline bool setNominalRate(const std::string& uid, double rate, int waitMs = 2000)
{
    const AudioObjectID dev = deviceByUID(uid);
    if (dev == kAudioObjectUnknown) return false;
    AudioObjectPropertyAddress a { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 r = rate;
    if (AudioObjectSetPropertyData(dev, &a, 0, nullptr, sizeof(r), &r) != noErr) return false;
    for (int waited = 0; waited <= waitMs; waited += 25) {
        const double now = nominalRate(uid);
        if (now > 0 && std::fabs(now - rate) <= 1.0) return true;
        usleep(25 * 1000);
    }
    return false;
}

/// A throw-away IOProc started on a card's input, to PROVOKE what opening it provokes: a Bluetooth headset
/// switches from music to the call profile, and the system republishes its devices and changes their rate.
/// It reads nothing and touches nothing; it only keeps the input running until it is stopped. Without the
/// microphone permission the system simply delivers silence.
class PreSwitch {
public:
    PreSwitch() = default;
    PreSwitch(const PreSwitch&) = delete;
    PreSwitch& operator=(const PreSwitch&) = delete;
    ~PreSwitch() { stop(); }

    bool start(const std::string& uid)
    {
        stop();
        dev_ = deviceByUID(uid);
        if (dev_ == kAudioObjectUnknown) return false;
        const OSStatus c = AudioDeviceCreateIOProcID(dev_, &PreSwitch::ioProc, nullptr, &proc_);
        if (c != noErr || proc_ == nullptr) { proc_ = nullptr; dev_ = kAudioObjectUnknown; return false; }
        if (AudioDeviceStart(dev_, proc_) != noErr) { stop(); return false; }
        return true;
    }

    void stop()
    {
        if (proc_ != nullptr && dev_ != kAudioObjectUnknown) {
            AudioDeviceStop(dev_, proc_);
            AudioDeviceDestroyIOProcID(dev_, proc_);
        }
        proc_ = nullptr;
        dev_ = kAudioObjectUnknown;
    }

    bool running() const { return proc_ != nullptr; }

private:
    static OSStatus ioProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList*, const AudioTimeStamp*,
                           AudioBufferList*, const AudioTimeStamp*, void*) { return noErr; }
    AudioObjectID dev_ = kAudioObjectUnknown;
    AudioDeviceIOProcID proc_ = nullptr;
};

/// A live aggregate.
struct Live {
    AudioObjectID id = kAudioObjectUnknown;
    std::string   uid, name;
    explicit operator bool() const { return id != kAudioObjectUnknown; }
};

/// Builds the private aggregate [input (drift-compensated), output (master)]. Waits until the HAL
/// shows the channels of both sub-devices (bounded). Returns an empty handle and says why in `error`.
inline Live create(const Card& output, const Card& input, int serial, std::string& error, int waitMs = 4000)
{
    const int pid = (int) getpid();
    Live h;
    h.name = makeName(pid, serial);
    h.uid  = makeUID(pid, serial);

    auto sub = [](const std::string& uid, int drift) {
        CFStringRef u = CFStringCreateWithCString(kCFAllocatorDefault, uid.c_str(), kCFStringEncodingUTF8);
        const void* keys[]   = { CFSTR(kAudioSubDeviceUIDKey), CFSTR(kAudioSubDeviceDriftCompensationKey) };
        const void* values[] = { u, CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &drift) };
        CFDictionaryRef d = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                               &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFRelease(u);
        CFRelease((CFNumberRef) values[1]);
        return d;
    };
    CFDictionaryRef s0 = sub(input.uid, 1);        // listed first: its channels start at 0
    CFDictionaryRef s1 = sub(output.uid, 0);       // the master
    const void* list[] = { s0, s1 };
    CFArrayRef subs = CFArrayCreate(kCFAllocatorDefault, list, 2, &kCFTypeArrayCallBacks);
    CFRelease(s0); CFRelease(s1);

    CFStringRef cfName   = CFStringCreateWithCString(kCFAllocatorDefault, h.name.c_str(), kCFStringEncodingUTF8);
    CFStringRef cfUID    = CFStringCreateWithCString(kCFAllocatorDefault, h.uid.c_str(), kCFStringEncodingUTF8);
    CFStringRef cfMaster = CFStringCreateWithCString(kCFAllocatorDefault, output.uid.c_str(), kCFStringEncodingUTF8);
    int one = 1, zero = 0;
    CFNumberRef cfOne  = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &one);
    CFNumberRef cfZero = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &zero);
    const void* keys[]   = { CFSTR(kAudioAggregateDeviceNameKey), CFSTR(kAudioAggregateDeviceUIDKey),
                             CFSTR(kAudioAggregateDeviceSubDeviceListKey), CFSTR(kAudioAggregateDeviceMasterSubDeviceKey),
                             CFSTR(kAudioAggregateDeviceIsPrivateKey), CFSTR(kAudioAggregateDeviceIsStackedKey) };
    const void* values[] = { cfName, cfUID, subs, cfMaster, cfOne, cfZero };
    CFDictionaryRef desc = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 6,
                                              &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    AudioObjectID id = kAudioObjectUnknown;
    const OSStatus st = AudioHardwareCreateAggregateDevice(desc, &id);
    CFRelease(desc); CFRelease(subs); CFRelease(cfName); CFRelease(cfUID); CFRelease(cfMaster);
    CFRelease(cfOne); CFRelease(cfZero);

    if (st != noErr || id == kAudioObjectUnknown) {
        error = "the system refused to create the aggregate device (" + std::to_string((int) st) + ")";
        return {};
    }
    h.id = id;

    const int wantIn = expectedInputs(output, input), wantOut = expectedOutputs(output, input);
    int waited = 0;
    while (waited < waitMs && (detail::channels(id, kAudioObjectPropertyScopeInput) != wantIn
                               || detail::channels(id, kAudioObjectPropertyScopeOutput) != wantOut)) {
        usleep(25 * 1000);
        waited += 25;
    }
    if (detail::channels(id, kAudioObjectPropertyScopeInput) != wantIn
        || detail::channels(id, kAudioObjectPropertyScopeOutput) != wantOut) {
        error = "the aggregate device did not show the channels of its sub-devices";
        AudioHardwareDestroyAggregateDevice(id);
        return {};
    }
    return h;
}

inline void destroy(Live& h)
{
    if (h.id != kAudioObjectUnknown) AudioHardwareDestroyAggregateDevice(h.id);
    h = {};
}

#endif // __APPLE__

} // namespace objaggregate
