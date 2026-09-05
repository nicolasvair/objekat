//
//  OBJTracePlaybackPlugin.h
//  objekat
//
//  The RESTITUTION of a plugin trace: what stands in the chain where the plugin stood, on a
//  machine where the plugin is absent. It applies, sample by sample and in float64,
//
//      y[n] = g[n] · x[n] + d[n]
//
//  reading the two run-length encoded signals straight out of the loaded trace.
//
//  WHY IT DECLARES NO LATENCY, although the plugin it replaces did. The captures are indexed by
//  EDIT TIME, that is by the time of the MATERIAL rather than the time it came out (@see
//  OBJTraceProbePlugin): `y[m]` is the plugin's response to the input at m, with its internal
//  delay already taken out by the engine's own bookkeeping. So this node has nothing to delay
//  and nothing to announce — it answers m with the response to m. Declaring the original's
//  latency would delay the chain twice over. The project simply loses those samples of latency,
//  which is a small gift rather than a change of behaviour: PDC is global and compensates the
//  chain as it now stands.
//
//  @see docs/objekat-capture-trace.md
//

#pragma once

#include <tracktion_engine/tracktion_engine.h>

#include "OBJTrace.h"

#include <cmath>
#include <memory>

namespace tracktion { inline namespace engine {

//==============================================================================
class ObjTracePlaybackPlugin  : public Plugin
{
public:
    ObjTracePlaybackPlugin (PluginCreationInfo info)
        : Plugin (info)
    {
        auto um = getUndoManager();
        tracePath.referTo (state, juce::Identifier ("tracePath"), um, juce::String());
        displayName.referTo (state, juce::Identifier ("traceName"), um, juce::String());
    }

    ~ObjTracePlaybackPlugin() override                      { notifyListenersOfDeletion(); }

    using Ptr = juce::ReferenceCountedObjectPtr<ObjTracePlaybackPlugin>;

    static const char* getPluginName()                      { return NEEDS_TRANS("Traced Plugin"); }
    static const char* xmlTypeName;

    static juce::ValueTree create()
    {
        juce::ValueTree v (IDs::PLUGIN);
        v.setProperty (IDs::type, xmlTypeName, nullptr);
        return v;
    }

    //==============================================================================
    /** Loads a trace from disk. Returns false — and leaves the node transparent — if the file is
        missing or is not a trace this version understands. */
    bool loadTrace (const juce::File& file)
    {
        auto loaded = std::make_shared<objtrace::Trace>();
        if (! objtrace::readFromFile (file, *loaded))
        {
            trace.reset();
            return false;
        }

        tracePath = file.getFullPathName();
        displayName = juce::String (loaded->header.pluginName);
        trace = std::move (loaded);
        return true;
    }

    /** The trace currently loaded, or nullptr. */
    std::shared_ptr<const objtrace::Trace> getTrace() const  { return trace; }

    /** True when the node has a trace it can actually apply at this sample rate. A trace read at
        a rate other than the one it was captured at describes nothing: `g[n]` is a sequence of
        samples, not a curve to resample, and stretching it would invent values the plugin never
        produced. */
    bool isUsableAt (double sampleRate) const
    {
        return trace != nullptr
            && std::abs (trace->header.sampleRate - sampleRate) < 0.5;
    }

    //==============================================================================
    juce::String getName() const override                   { return TRANS("Traced Plugin"); }
    juce::String getPluginType() override                   { return xmlTypeName; }
    juce::String getShortName (int) override                { return "Trace"; }
    juce::String getSelectableDescription() override        { return getName(); }
    bool shouldMeasureCpuUsage() const noexcept final       { return false; }

    int getNumOutputChannelsGivenInputs (int numInputs) override    { return juce::jmax (1, numInputs); }
    BusLayout getBusses() const override                            { return BusLayout::singlePassThrough(); }

    void initialise (const PluginInitialisationInfo& info) override
    {
        currentSampleRate = info.sampleRate;
        rewind();
    }

    void deinitialise() override {}

    void reset() override                                   { rewind(); }

    void applyToBuffer (const PluginRenderContext& fc) override
    {
        if (! isEnabled())
            return;

        SCOPED_REALTIME_CHECK

        auto* buffer = fc.destBuffer;
        if (buffer == nullptr || fc.bufferNumSamples <= 0 || trace == nullptr)
            return;

        const auto& header = trace->header;
        if (std::abs (header.sampleRate - currentSampleRate) > 0.5 || header.numSamples <= 0)
            return;   // a trace from another sample rate: transparent rather than wrong

        const int numChans = buffer->getNumChannels();
        const int n        = fc.bufferNumSamples;
        const int start    = fc.bufferStartSample;

        const int64_t first = (int64_t) std::llround (
            (fc.editTime.getStart().inSeconds() - header.regionStart) * header.sampleRate);

        // Outside the traced span the node is transparent. It is not a hole: the object's window
        // cuts there anyway, exactly as it cut the plugin's own tail when the plugin was in the
        // chain.
        const int64_t from = juce::jmax<int64_t> (0, -first);
        const int64_t to   = juce::jmin<int64_t> ((int64_t) n, (int64_t) header.numSamples - first);
        if (to <= from)
            return;

        const int storedChannels = (int) trace->g.size();
        if (storedChannels <= 0)
            return;

        for (int c = 0; c < numChans; ++c)
        {
            // `linked`: one stored channel drives them all. Otherwise a channel beyond what was
            // captured keeps the last stored one rather than falling silent — a trace narrower
            // than the chain is a mismatch, and going quiet would hide it.
            const int sourceChannel = juce::jmin (c, storedChannels - 1);
            const auto& g = trace->g[(size_t) sourceChannel];
            const objtrace::Signal* d = (! header.multiplicativeOnly
                                         && (size_t) sourceChannel < trace->d.size())
                                          ? &trace->d[(size_t) sourceChannel] : nullptr;

            auto* samples = buffer->getWritePointer (c, start);

            for (int64_t i = from; i < to; ++i)
            {
                const uint64_t idx = (uint64_t) (first + i);
                const double   x   = (double) samples[i];
                const double   y   = g.at (idx) * x + (d != nullptr ? d->at (idx) : 0.0);
                samples[i] = (float) y;
            }
        }
    }

    void restorePluginStateFromValueTree (const juce::ValueTree& v) override
    {
        copyPropertiesToCachedValues (v, tracePath, displayName);
    }

    //==============================================================================
    /// The trace file this node was asked to play, as recorded in the project.
    juce::CachedValue<juce::String> tracePath, displayName;

private:
    void rewind()
    {
        if (trace == nullptr)
            return;

        for (const auto& s : trace->g) s.rewind();
        for (const auto& s : trace->d) s.rewind();
    }

    std::shared_ptr<const objtrace::Trace> trace;
    double currentSampleRate = 44100.0;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ObjTracePlaybackPlugin)
};

inline const char* ObjTracePlaybackPlugin::xmlTypeName = "objTracePlayback";

}} // namespace tracktion { inline namespace engine }
