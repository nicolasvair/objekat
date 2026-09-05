//
//  OBJTraceProbePlugin.h
//  objekat
//
//  The CAPTURE probe of a plugin trace. Inserted into a RENDER CLONE either side of the plugin
//  being traced, never into the live graph and never into a project file:
//
//      … → probe(pre-roll · gate · capture x) → THE PLUGIN → probe(capture y) → …
//
//  One class does the three jobs, because they are three flags on the same pass-through:
//
//   • PRE-ROLL — a delay of N seconds, DECLARED as latency. The plugin then starts on an empty
//     delay line, that is to say on true digital silence, for as long as it takes its detectors,
//     filters and smoothing cells to settle. The spec asks for at least 2 seconds.
//
//   • GATE — zeroes what falls outside the region. The clip's extent has to be opened past the
//     region for the tail to come out (@see OBJEngineCore, the capture's `prepare`), and that
//     opening would otherwise let material through: a looping group repeating, a wave clip
//     reading on past its window.
//
//   • CAPTURE — writes what passes into a destination buffer, indexed by EDIT TIME.
//
//  WHY EDIT TIME, and why that settles the alignment on its own. `PluginNode` hands each plugin
//  a `PluginRenderContext::editTime` already pulled back by the latency accumulated UPSTREAM of
//  it (`automationAdjustmentTime`). Between our two probes that accumulated latency differs by
//  exactly the traced plugin's own — so the material a downstream probe sees at block k carries
//  the edit time it really belongs to, not the time it came out. Indexing the captures by that
//  time therefore aligns x and y sample for sample, and it does the same for the pre-roll delay
//  above, whose samples simply fall before the capture window and are dropped. The engine's PDC
//  is the alignment; there is nothing to line up by hand.
//
//  @see docs/objekat-capture-trace.md
//

#pragma once

#include <tracktion_engine/tracktion_engine.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <memory>
#include <vector>

namespace tracktion { inline namespace engine {

//==============================================================================
/** Where a probe writes. Owned by the capture orchestration, which allocates it before the
    render and reads it once the render's completion has been marshalled back to the main
    thread — that hand-over is the synchronisation point, so the plain members below need no
    lock of their own.

    The CHANNEL COUNT is not known before the graph is built: it is what the chain carries at
    that point, which depends on the source, on the plugins upstream and on the host. So the
    buffer sizes itself on the first block. That is an allocation from the render thread, done
    once, on a thread that is not realtime (an offline render owns its own thread) — the trade
    is deliberate, and the alternative would be to guess a channel count and be wrong.
*/
struct ObjTraceCaptureBuffer
{
    double  sampleRate = 0.0;
    double  startSecs  = 0.0;      ///< the edit time of sample 0
    int64_t numSamples = 0;        ///< region + tail, per channel

    juce::AudioBuffer<float> audio;

    std::atomic<int>     numChannels { 0 };
    std::atomic<int64_t> samplesWritten { 0 };
    /// Blocks that fell wholly outside the window. NOT an error count: the pre-roll's blocks
    /// belong here by construction, since their material predates the region.
    std::atomic<int64_t> blocksOutsideWindow { 0 };
    std::atomic<bool>    allocationFailed { false };

    /** Sizes the buffer for the channel count the graph turned out to carry. Called from the
        render thread, and ALLOCATING ONLY ONCE: a later block arriving with more channels must
        not resize, because resizing does not keep what is already written and would silently
        empty the capture halfway through. Within one render the graph's channel count is fixed,
        so the case should not arise; if it ever does, the extra channels are dropped and the
        capture stays whole rather than becoming half of one. */
    void ensureChannels (int channels)
    {
        if (audio.getNumSamples() > 0 || channels <= 0 || numSamples <= 0)
            return;

        // A trace covers region + tail at full rate: 8 bytes per sample per channel once it
        // reaches float64, 4 while it is captured. A minute of stereo is 23 MB here. Refuse
        // rather than throw: the report then says why, instead of the app dying mid-render.
        const int64_t bytes = (int64_t) channels * numSamples * (int64_t) sizeof (float);
        if (bytes > (int64_t) 2 * 1024 * 1024 * 1024)
        {
            allocationFailed = true;
            return;
        }

        audio.setSize (channels, (int) numSamples, false, true, false);
        audio.clear();
        numChannels = channels;
    }

    const float* read (int channel) const
    {
        return channel < audio.getNumChannels() ? audio.getReadPointer (channel) : nullptr;
    }
};

using ObjTraceCaptureBufferPtr = std::shared_ptr<ObjTraceCaptureBuffer>;

//==============================================================================
class ObjTraceProbePlugin  : public Plugin
{
public:
    ObjTraceProbePlugin (PluginCreationInfo info)  : Plugin (info) {}

    ~ObjTraceProbePlugin() override                         { notifyListenersOfDeletion(); }

    using Ptr = juce::ReferenceCountedObjectPtr<ObjTraceProbePlugin>;

    static const char* getPluginName()                      { return NEEDS_TRANS("Trace Probe"); }
    static const char* xmlTypeName;

    static juce::ValueTree create()
    {
        juce::ValueTree v (IDs::PLUGIN);
        v.setProperty (IDs::type, xmlTypeName, nullptr);
        return v;
    }

    //==============================================================================
    // Everything below is set on the C++ object right after insertion into the clone, BEFORE
    // the render graph is built. Nothing goes through the ValueTree: this plugin never travels,
    // it lives and dies inside one render.

    /** Seconds of silence to run the downstream plugin over before the region. Declared as
        latency so that the engine's own bookkeeping carries it. Set before the graph is built:
        `PluginNode` reads `getLatencySeconds()` once, in its constructor. */
    void setPreRoll (double seconds)                        { preRollSeconds = juce::jmax (0.0, seconds); }

    /** The window this probe reasons in: the edit time of sample 0, and how many samples it
        runs for. Both the gate and the capture index against it.

        Set SEPARATELY from the destination on purpose. A probe can be asked to gate without
        capturing anything — that is pass A's input probe — and deriving the origin from the
        destination buffer would then silently fall back on a different origin, putting the gate
        somewhere else entirely. One window, one origin, whether or not anything is being
        written down. */
    void setWindow (double startSecs, int64_t numSamples)
    {
        windowStartSecs = startSecs;
        windowSamples   = numSamples;
    }

    /** Where to write what passes. nullptr = this probe only gates. */
    void setCapture (ObjTraceCaptureBufferPtr buffer)       { capture = std::move (buffer); }

    /** Zero everything outside [firstSample, endSample) of the window. A negative `endSample`
        disables the gate. */
    void setGate (int64_t firstSample, int64_t endSample)
    {
        gateFirst = firstSample;
        gateEnd   = endSample;
    }

    /** Pass A: the plugin downstream receives strict digital silence over the whole length. */
    void setSilencesInput (bool shouldSilence)              { silencesInput = shouldSilence; }

    //==============================================================================
    juce::String getName() const override                   { return TRANS("Trace Probe"); }
    juce::String getPluginType() override                   { return xmlTypeName; }
    juce::String getShortName (int) override                { return "Trace"; }
    juce::String getSelectableDescription() override        { return getName(); }
    bool shouldMeasureCpuUsage() const noexcept final       { return false; }

    /// Transparent to the channel count: a probe that widened the buffer would change what the
    /// traced plugin receives, and the trace would then describe a signal the live graph never
    /// carries. `getNodeProperties` takes a max, so returning the input unchanged is a no-op.
    int getNumOutputChannelsGivenInputs (int numInputs) override    { return juce::jmax (1, numInputs); }

    BusLayout getBusses() const override                    { return BusLayout::singlePassThrough(); }

    double getLatencySeconds() override                     { return preRollSeconds; }

    void initialise (const PluginInitialisationInfo& info) override
    {
        currentSampleRate = info.sampleRate;

        // The SAME rounding as `PluginNode::initialisePlugin`, which does
        // `roundToInt (getLatencySeconds() * sampleRate)`. If the delay line and the engine's
        // bookkeeping disagreed by a sample, every capture would be off by that sample and the
        // trace would describe a signal shifted against its own input.
        delaySamples = juce::roundToInt (preRollSeconds * info.sampleRate);
        delayWritePos = 0;
        delayLine.setSize (0, 0, false, true, false);
    }

    void deinitialise() override
    {
        delayLine.setSize (0, 0, false, true, false);
    }

    void reset() override
    {
        delayLine.clear();
        delayWritePos = 0;
    }

    void applyToBuffer (const PluginRenderContext& fc) override
    {
        // Deliberately NOT guarded by isEnabled(): a probe is machinery, not an effect. Nothing
        // in the app can bypass it — it exists only inside a render clone — and a bypass here
        // would silently produce an empty capture.
        auto* buffer = fc.destBuffer;
        if (buffer == nullptr || fc.bufferNumSamples <= 0)
            return;

        const int numChans = buffer->getNumChannels();
        const int n        = fc.bufferNumSamples;
        const int start    = fc.bufferStartSample;

        if (delaySamples > 0)
            applyDelay (*buffer, start, n, numChans);

        // The block's position in the window. `editTime` is the material's own time (see this
        // file's header), so this index is the same one the probe on the other side of the
        // plugin computes for the same material.
        const double sr = currentSampleRate > 0.0 ? currentSampleRate : 44100.0;
        const int64_t first = (int64_t) std::llround (
            (fc.editTime.getStart().inSeconds() - windowStartSecs) * sr);

        if (silencesInput)
        {
            buffer->clear (start, n);
        }
        else if (gateEnd >= 0)
        {
            // Sample-accurate: the region's edges do not land on block boundaries.
            for (int i = 0; i < n; ++i)
            {
                const int64_t idx = first + i;
                if (idx >= gateFirst && idx < gateEnd)
                    continue;

                for (int c = 0; c < numChans; ++c)
                    buffer->getWritePointer (c, start)[i] = 0.0f;
            }
        }

        if (capture == nullptr)
            return;

        capture->ensureChannels (numChans);
        if (capture->allocationFailed.load())
            return;

        const int  storedChans = juce::jmin (numChans, capture->audio.getNumChannels());
        const auto total       = windowSamples > 0 ? windowSamples : capture->numSamples;

        // Clip the block to the window rather than testing sample by sample: a block is
        // contiguous, and the pre-roll's blocks fall wholly before it.
        const int64_t from = juce::jmax<int64_t> (0, -first);
        const int64_t to   = juce::jmin<int64_t> ((int64_t) n, total - first);

        if (to <= from)
        {
            capture->blocksOutsideWindow.fetch_add (1);
            return;
        }

        for (int c = 0; c < storedChans; ++c)
            capture->audio.copyFrom (c, (int) (first + from),
                                     *buffer, c, start + (int) from, (int) (to - from));

        const int64_t reached = first + to;
        int64_t seen = capture->samplesWritten.load();
        while (reached > seen && ! capture->samplesWritten.compare_exchange_weak (seen, reached))
        {}
    }

    void restorePluginStateFromValueTree (const juce::ValueTree&) override {}

private:
    //==============================================================================
    /// A plain ring delay. Sized on the first block: the channel count is only known once the
    /// graph is built, and this runs on an offline render thread, not a realtime one.
    void applyDelay (juce::AudioBuffer<float>& buffer, int start, int n, int numChans)
    {
        if (delayLine.getNumChannels() < numChans || delayLine.getNumSamples() < delaySamples)
        {
            delayLine.setSize (numChans, delaySamples, false, true, false);
            delayLine.clear();
            delayWritePos = 0;
        }

        for (int i = 0; i < n; ++i)
        {
            const int slot = (delayWritePos + i) % delaySamples;

            for (int c = 0; c < numChans; ++c)
            {
                auto* line = delayLine.getWritePointer (c);
                auto* dest = buffer.getWritePointer (c, start);
                const float delayed = line[slot];
                line[slot] = dest[i];
                dest[i] = delayed;
            }
        }

        delayWritePos = (delayWritePos + n) % delaySamples;
    }

    //==============================================================================
    double  preRollSeconds  = 0.0;
    bool    silencesInput   = false;
    double  windowStartSecs = 0.0;
    int64_t windowSamples   = 0;
    int64_t gateFirst = 0;
    int64_t gateEnd   = -1;          ///< < 0 = no gate

    ObjTraceCaptureBufferPtr capture;

    double currentSampleRate = 44100.0;
    int    delaySamples = 0;
    int    delayWritePos = 0;
    juce::AudioBuffer<float> delayLine;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ObjTraceProbePlugin)
};

inline const char* ObjTraceProbePlugin::xmlTypeName = "objTraceProbe";

}} // namespace tracktion { inline namespace engine }
