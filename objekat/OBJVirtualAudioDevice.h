//
//  OBJVirtualAudioDevice.h
//  objekat
//
//  A VIRTUAL sound card, for testing audio with no hardware: `--virtual-audio[=in:4,out:2,sr:48000,
//  bs:256,inlat:64,outlat:96]`. It is a real `juce::AudioIODeviceType` ("OBJ Virtual") whose device
//  calls the audio callback from a thread paced against the wall clock — one block every
//  `bs / sr` seconds, scheduled on ABSOLUTE deadlines so the cadence does not drift. Playback, the
//  input meters, monitoring and recording are therefore testable headless, at real-time speed, on a
//  machine with no interface (or one we do not want to touch).
//
//  INPUTS are synthetic, one signal per input channel, changed live from the command API
//  (`audio.virtual.set_input`):
//
//      silence    zeros (the default)
//      sine       amp * sin(2 pi f t); the phase is continuous across a change of frequency
//      impulse    a single sample of value `amp`, every `period` seconds (the first one at once)
//      loopback   the output's first active channel, DELAYED by `loopbackDelaySamples()` — what a
//                 cable from the output to this input would bring back
//
//  THE LATENCY MODEL, the one place to read it. `getInputLatencyInSamples` / `getOutputLatencyInSamples`
//  announce `inlat` / `outlat` PLUS one block each, the way JUCE's CoreAudio device does (it returns
//  deviceLatency + safetyOffset + framesInBuffer + streamLatency: the buffer is INCLUDED). A real round
//  trip is one buffer on the way out, the latencies, and one buffer on the way in, so the loopback
//  delay is  2 * bs + inlat + outlat  (never less than a block: a block-based callback cannot hand
//  back samples it has not produced yet) — which is exactly the sum of the two ANNOUNCED figures. A
//  host that compensates the way a real card needs it lands on that figure by adding the two;
//  `audio.virtual.status` reports it as `loopback_delay` and the announced ones as
//  `announced_input_latency` / `announced_output_latency`.
//
//  THE DEVICE LIVES IN THE PROCESS ONLY. It must never reach ~/Library/objekat/Settings.xml, or the
//  next normal launch would look for a card that does not exist: OBJPropertyStorage (OBJEngineCore.mm)
//  drops every device setting while `--virtual-audio` is on.
//
//  No JUCE module beyond what tracktion_engine.h already brings in; header only, like OBJAudioProbe.h.
//

#pragma once

#include <tracktion_engine/tracktion_engine.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <string>
#include <thread>
#include <vector>

namespace objvirtual {

/// The device type's name, and the name of its one device (input and output share it, so that
/// "open the inputs of the output device" — `setup.inputDeviceName = setup.outputDeviceName` — works
/// exactly as on a card that has both).
inline const char* cardName() { return "OBJ Virtual"; }

/// The SECOND card (`in2:N`): an input-only card with its own N channels, to test an input card that is
/// not the output card. Its name is also its UID.
inline const char* secondCardName() { return "OBJ Virtual In 2"; }

constexpr int kMaxInputs = 64;

/// What `--virtual-audio=...` asks for. Defaults are the plan's: 4 in, 2 out, 48 kHz, 256 frames,
/// 64 / 96 frames of announced latency.
struct Config {
    int    numIn       = 4;
    int    numOut      = 2;
    /// `in2:N`: an INPUT-ONLY second card of N channels ("OBJ Virtual In 2"). The signals of its channels
    /// follow those of the main card: channel c of the second card is `inputs[numIn + c]`.
    int    numIn2      = 0;
    double sampleRate  = 48000.0;
    int    blockSize   = 256;
    int    inLatency   = 64;
    int    outLatency  = 96;
    /// `splitin:1`: the card says its inputs live on ANOTHER device that has the same name — the AirPods
    /// layout (a speaker and a microphone, two CoreAudio devices, one name). The engine refuses to open
    /// them (`-openAudioInputs`, same test as on a real card), which makes that refusal reachable with
    /// no hardware. Nothing else changes: the card still has its inputs, they are just never opened.
    bool   splitIn     = false;
};

/// "in:4,out:2,in2:0,sr:48000,bs:256,inlat:64,outlat:96,splitin:0" — every key optional, unknown keys and malformed
/// values ignored (a typo must not turn a test run into a failure to start). The rate must be one the
/// device lists (`availableRates()`), anything else keeps the default.
inline std::vector<double> availableRates()  { return { 44100.0, 48000.0, 88200.0, 96000.0 }; }
inline std::vector<int>    availableBlocks() { return { 32, 64, 128, 256, 512, 1024, 2048 }; }

inline Config parseConfig(const std::string& spec)
{
    Config c;
    size_t pos = 0;
    while (pos <= spec.size()) {
        size_t end = spec.find(',', pos);
        if (end == std::string::npos) end = spec.size();
        const std::string item = spec.substr(pos, end - pos);
        pos = end + 1;
        const size_t colon = item.find(':');
        if (colon == std::string::npos) continue;
        const std::string key = item.substr(0, colon);
        const double v = std::atof(item.c_str() + colon + 1);
        if (key == "in")          c.numIn      = std::max(0, std::min(kMaxInputs, (int) v));
        else if (key == "out")    c.numOut     = std::max(1, std::min(32, (int) v));
        else if (key == "in2")    c.numIn2     = std::max(0, std::min(kMaxInputs, (int) v));
        else if (key == "sr") {
            for (double r : availableRates()) if (std::fabs(r - v) < 0.5) c.sampleRate = r;
        }
        else if (key == "bs") {
            for (int b : availableBlocks()) if (b == (int) v) c.blockSize = b;
        }
        else if (key == "inlat")  c.inLatency  = std::max(0, (int) v);
        else if (key == "outlat") c.outLatency = std::max(0, (int) v);
        else if (key == "splitin") c.splitIn   = v != 0.0;
    }
    c.numIn2 = std::min(c.numIn2, kMaxInputs - c.numIn);       // the signals are shared: 64 channels in all
    return c;
}

enum class Signal : int { silence = 0, sine = 1, impulse = 2, loopback = 3 };

inline const char* signalName(Signal s)
{
    switch (s) {
        case Signal::silence:  return "silence";
        case Signal::sine:     return "sine";
        case Signal::impulse:  return "impulse";
        case Signal::loopback: return "loopback";
    }
    return "silence";
}

inline bool parseSignal(const std::string& s, Signal& out)
{
    for (Signal k : { Signal::silence, Signal::sine, Signal::impulse, Signal::loopback })
        if (s == signalName(k)) { out = k; return true; }
    return false;
}

/// One input channel's signal. Written by the command thread, read by the audio thread: every field
/// is an atomic, so a change lands between two samples at worst and never needs a lock.
struct ChannelSignal {
    std::atomic<int>    kind   { (int) Signal::silence };
    std::atomic<double> freq   { 440.0 };
    std::atomic<double> amp    { 0.5 };
    std::atomic<double> period { 1.0 };      // seconds between two impulses
};

/// The configuration and the live signals, shared between the device (audio thread) and the bridge.
/// A function-local static: constructed on first use, never destroyed before the audio thread stops.
struct State {
    Config config;
    bool   active = false;                   // `--virtual-audio` was given (and audio is not disabled)
    std::array<ChannelSignal, kMaxInputs> inputs;
};

inline State& state() { static State s; return s; }

/// Samples between an output frame leaving the callback and coming back on a `loopback` input: two
/// buffers (one each way) plus the announced latencies. @see the latency model in the file header.
inline int loopbackDelaySamples(const Config& c, int blockSize)
{
    return 2 * blockSize + c.inLatency + c.outLatency;
}

//==============================================================================
class OBJVirtualAudioDevice : public juce::AudioIODevice
{
public:
    /// `inputCard`: 0 = no inputs, 1 = the main card's, 2 = the second card's (`in2:`). A device made with
    /// the main card as output and the second as input is the virtual equivalent of an aggregate: one
    /// device, one clock, the inputs of another card.
    OBJVirtualAudioDevice(const Config& cfg, int inputCard, bool withOutputs)
        : juce::AudioIODevice(cardName(), cardName()),
          config(cfg),
          inputBase(inputCard == 2 ? cfg.numIn : 0),
          inputCount(inputCard == 2 ? cfg.numIn2 : inputCard == 1 ? cfg.numIn : 0),
          hasIn(inputCount > 0), hasOut(withOutputs),
          rate(cfg.sampleRate), block(cfg.blockSize),
          inputPrefix(inputCard == 2 ? "In2 " : "In ") {}

    ~OBJVirtualAudioDevice() override { stop(); }

    //--------------------------------------------------------------------------
    juce::StringArray getOutputChannelNames() override { return names("Out ", hasOut ? config.numOut : 0); }
    juce::StringArray getInputChannelNames() override  { return names(inputPrefix, hasIn ? inputCount : 0); }

    juce::Array<double> getAvailableSampleRates() override
    {
        juce::Array<double> r;
        for (double x : availableRates()) r.add(x);
        return r;
    }

    juce::Array<int> getAvailableBufferSizes() override
    {
        juce::Array<int> b;
        for (int x : availableBlocks()) b.add(x);
        return b;
    }

    int getDefaultBufferSize() override { return config.blockSize; }

    juce::String open(const juce::BigInteger& inputChannels, const juce::BigInteger& outputChannels,
                      double sampleRate, int bufferSizeSamples) override
    {
        stop();

        activeIn = inputChannels;
        activeIn.setRange(hasIn ? inputCount : 0, kMaxInputs, false);
        activeOut = outputChannels;
        activeOut.setRange(hasOut ? config.numOut : 0, 256, false);

        rate = config.sampleRate;
        for (double r : availableRates()) if (std::fabs(r - sampleRate) < 0.5) rate = r;
        block = config.blockSize;
        for (int b : availableBlocks()) if (b == bufferSizeSamples) block = b;

        opened = true;
        lastError = {};
        return {};
    }

    void close() override
    {
        stop();
        opened = false;
    }

    bool isOpen() override { return opened; }

    void start(juce::AudioIODeviceCallback* cb) override
    {
        if (! opened || cb == nullptr) return;
        stop();

        callback = cb;
        cb->audioDeviceAboutToStart(this);
        runner = std::make_unique<Runner>(*this);
        runner->startThread(juce::Thread::Priority::highest);
    }

    void stop() override
    {
        std::unique_ptr<Runner> r;
        std::swap(r, runner);
        if (r != nullptr) r->stopThread(5000);          // the callback is flushed before this returns
        r.reset();

        if (auto* cb = std::exchange(callback, nullptr))
            cb->audioDeviceStopped();
    }

    bool isPlaying() override { return runner != nullptr && runner->isThreadRunning(); }

    juce::String getLastError() override { return lastError; }

    int    getCurrentBufferSizeSamples() override { return block; }
    double getCurrentSampleRate() override        { return rate; }
    int    getCurrentBitDepth() override          { return 32; }

    juce::BigInteger getActiveOutputChannels() const override { return activeOut; }
    juce::BigInteger getActiveInputChannels() const override  { return activeIn; }

    // Like JUCE's CoreAudio device: the latencies PLUS the buffer (see the latency model in the header).
    int getOutputLatencyInSamples() override { return hasOut ? config.outLatency + block : 0; }
    int getInputLatencyInSamples() override  { return hasIn ? config.inLatency + block : 0; }

private:
    //--------------------------------------------------------------------------
    static juce::StringArray names(const char* prefix, int n)
    {
        juce::StringArray a;
        for (int i = 0; i < n; ++i) a.add(juce::String(prefix) + juce::String(i + 1));
        return a;
    }

    /// The audio thread. Absolute deadlines: block k is due at start + k * bs / sr, whatever the
    /// previous block cost; if the thread falls more than 100 ms behind (a debugger, a suspended
    /// laptop) the schedule is re-anchored instead of firing a burst to catch up.
    struct Runner : public juce::Thread
    {
        explicit Runner(OBJVirtualAudioDevice& d) : juce::Thread("OBJ Virtual audio"), dev(d) {}

        void run() override { dev.audioLoop(*this); }

        OBJVirtualAudioDevice& dev;
    };

    void audioLoop(juce::Thread& self)
    {
        using clock = std::chrono::steady_clock;

        const int    bs  = block;
        const double sr  = rate;
        const int    nIn  = activeIn.countNumberOfSetBits();
        const int    nOut = activeOut.countNumberOfSetBits();

        std::vector<int> inChannels, outChannelsUnused;
        for (int c = activeIn.findNextSetBit(0); c >= 0; c = activeIn.findNextSetBit(c + 1)) inChannels.push_back(c);

        std::vector<std::vector<float>> inBuf((size_t) nIn, std::vector<float>((size_t) bs, 0.0f));
        std::vector<std::vector<float>> outBuf((size_t) std::max(1, nOut), std::vector<float>((size_t) bs, 0.0f));
        std::vector<const float*> inPtr((size_t) nIn);
        std::vector<float*> outPtr((size_t) std::max(1, nOut));
        for (int i = 0; i < nIn; ++i)  inPtr[(size_t) i] = inBuf[(size_t) i].data();
        for (int i = 0; i < nOut; ++i) outPtr[(size_t) i] = outBuf[(size_t) i].data();

        // The loopback source: the first active output channel, kept as a ring indexed by stream frame.
        const int delay = loopbackDelaySamples(config, bs);
        const int ringSize = delay + 2 * bs + 8;
        std::vector<float> ring((size_t) ringSize, 0.0f);

        std::vector<double> phase((size_t) nIn, 0.0);
        std::vector<int64_t> nextImpulse((size_t) nIn, 0);
        std::vector<int> lastKind((size_t) nIn, -1);

        const auto blockDur = std::chrono::duration<double>((double) bs / sr);
        auto anchor = clock::now();
        int64_t stream = 0;                      // frames produced since start
        int64_t blockIndex = 0;

        while (! self.threadShouldExit())
        {
            // ---- the inputs for this block
            for (int i = 0; i < nIn; ++i)
            {
                auto& sig = state().inputs[(size_t) (inputBase + inChannels[(size_t) i])];
                const int kind = sig.kind.load(std::memory_order_relaxed);
                float* dst = inBuf[(size_t) i].data();

                if (kind != lastKind[(size_t) i])
                {
                    if (kind == (int) Signal::impulse) nextImpulse[(size_t) i] = stream;   // the first one at once
                    lastKind[(size_t) i] = kind;
                }

                if (kind == (int) Signal::sine)
                {
                    const double a = sig.amp.load(std::memory_order_relaxed);
                    const double step = sig.freq.load(std::memory_order_relaxed) / sr;
                    double p = phase[(size_t) i];
                    for (int j = 0; j < bs; ++j) {
                        dst[j] = (float) (a * std::sin(2.0 * M_PI * p));
                        p += step;
                        if (p >= 1.0) p -= std::floor(p);
                    }
                    phase[(size_t) i] = p;
                }
                else if (kind == (int) Signal::impulse)
                {
                    std::fill(dst, dst + bs, 0.0f);
                    const float a = (float) sig.amp.load(std::memory_order_relaxed);
                    const int64_t period = std::max<int64_t>(1, (int64_t) std::llround(sig.period.load(std::memory_order_relaxed) * sr));
                    int64_t& next = nextImpulse[(size_t) i];
                    while (next < stream + bs) {
                        if (next >= stream) dst[next - stream] = a;
                        next += period;
                    }
                }
                else if (kind == (int) Signal::loopback)
                {
                    for (int j = 0; j < bs; ++j) {
                        const int64_t src = stream + j - delay;
                        dst[j] = src >= 0 ? ring[(size_t) (src % ringSize)] : 0.0f;
                    }
                }
                else
                {
                    std::fill(dst, dst + bs, 0.0f);
                }
            }

            for (auto& o : outBuf) std::fill(o.begin(), o.end(), 0.0f);

            // ---- the callback
            {
                const juce::ScopedLock sl(callbackLock);
                if (callback != nullptr)
                    callback->audioDeviceIOCallbackWithContext(inPtr.data(), nIn, outPtr.data(), nOut, bs, {});
            }

            // ---- keep the output for a loopback input
            if (nOut > 0)
                for (int j = 0; j < bs; ++j)
                    ring[(size_t) ((stream + j) % ringSize)] = outBuf[0][(size_t) j];

            stream += bs;
            ++blockIndex;

            // ---- wait for the next deadline
            auto due = anchor + std::chrono::duration_cast<clock::duration>(blockDur * blockIndex);
            const auto now = clock::now();
            if (now > due + std::chrono::milliseconds(100)) {            // fell far behind: re-anchor
                anchor = now;
                blockIndex = 0;
                due = now;
            }
            // Sleep in short slices so a stop request is honoured within a few milliseconds.
            while (! self.threadShouldExit()) {
                const auto left = due - clock::now();
                if (left <= clock::duration::zero()) break;
                std::this_thread::sleep_for(std::min<clock::duration>(left, std::chrono::milliseconds(2)));
            }
        }
    }

    //--------------------------------------------------------------------------
    const Config config;
    const int  inputBase, inputCount;      // which signals, and how many channels, this device's inputs are
    const bool hasIn, hasOut;
    double rate;
    int    block;
    const char* inputPrefix;
    juce::BigInteger activeIn, activeOut;
    bool   opened = false;
    juce::String lastError;

    juce::CriticalSection callbackLock;
    juce::AudioIODeviceCallback* callback = nullptr;
    std::unique_ptr<Runner> runner;
};

//==============================================================================
class OBJVirtualAudioDeviceType : public juce::AudioIODeviceType
{
public:
    explicit OBJVirtualAudioDeviceType(const Config& cfg) : juce::AudioIODeviceType(cardName()), config(cfg) {}

    void scanForDevices() override {}

    juce::StringArray getDeviceNames(bool wantInputNames = false) const override
    {
        juce::StringArray names;
        if (wantInputNames) {
            if (config.numIn > 0)  names.add(cardName());
            if (config.numIn2 > 0) names.add(secondCardName());
        } else if (config.numOut > 0) {
            names.add(cardName());
        }
        return names;
    }

    int getDefaultDeviceIndex(bool) const override { return 0; }

    int getIndexOfDevice(juce::AudioIODevice* device, bool asInput) const override
    {
        if (device == nullptr || device->getName() != cardName()) return -1;
        return (asInput ? (config.numIn > 0 || config.numIn2 > 0) : config.numOut > 0) ? 0 : -1;
    }

    bool hasSeparateInputsAndOutputs() const override { return false; }

    juce::AudioIODevice* createDevice(const juce::String& outputDeviceName,
                                      const juce::String& inputDeviceName) override
    {
        const juce::String mine(cardName()), second(secondCardName());
        if (outputDeviceName.isNotEmpty() && outputDeviceName != mine) return nullptr;
        if (inputDeviceName.isNotEmpty() && inputDeviceName != mine && inputDeviceName != second) return nullptr;
        if (outputDeviceName.isEmpty() && inputDeviceName.isEmpty()) return nullptr;
        const int inputCard = inputDeviceName.isEmpty() ? 0 : inputDeviceName == second ? 2 : 1;
        return new OBJVirtualAudioDevice(config, inputCard, outputDeviceName.isNotEmpty());
    }

private:
    Config config;
};

} // namespace objvirtual
