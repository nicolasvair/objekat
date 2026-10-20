//
//  OBJMonoFoldPlugin.h
//  objekat
//
//  What a plugin with ONE input is fed when the signal reaching it is stereo (`MonoFold`, Swift; request
//  of 20 October 2026). Left alone, the engine's graph builder reads the first channel only: through a
//  1 → 1 plugin the right channel passes round it dry, after a 1 → 2 plugin it is not heard
//  (tracktion_EditNodeBuilder.cpp, createNodeForPlugin). That is what a plugin with NO fold chosen (an
//  old file, no `monoFold` key) gets: NOTHING is laid — an old project keeps its graph, sample for sample.
//
//  For a CHOSEN fold — `left` included, which lays only the OUT half: the plugin reads channel 0 by itself,
//  what changes is that the right channel is cut instead of passing round it dry — the compile (@see
//  OBJEngineCore compileSeries:) lays one or two of these around the plugin, as service plugins with no
//  card (like ObjGain or ObjChannelMode):
//
//    • the IN half, just BEFORE it: channel 0 becomes the right channel, or (L + R) / 2 — half of each,
//      so a centred sound keeps its level and two full-scale channels cannot clip. Channel 1 is left as
//      it is (a 1 → 2 plugin with a sidechain input reads it there, as before);
//    • the OUT half, just AFTER a 1 → 1 plugin: channel 1 becomes channel 0, the plugin's output — so
//      the plugin's result replaces the pair instead of sitting beside a dry right channel.
//
//  No engine patch: both are plain pass-through plugins on the list, and they work in a render clone too
//  (the mode and the half are in their state, the neighbour is found by position).
//
//  WHEN they act is decided on the message thread, at every graph preparation (`initialise` /
//  `initialiseWithoutStopping`, both called by Plugin::baseClassInitialise) and whenever the bridge says
//  so (`refreshActivity`, after a bypass): the neighbour must be an external plugin that is loaded, ON,
//  with a main bus of ONE input (and, for the OUT half, one output). A channel-layout change and an
//  instance finishing its load both rebuild the graph, so both come back here. The audio thread reads one
//  atomic. A buffer of fewer than two channels (a mono signal) is never touched: the fold only exists for
//  a stereo signal.
//

#pragma once

#include <tracktion_engine/tracktion_engine.h>

namespace tracktion { inline namespace engine {

//==============================================================================
class ObjMonoFoldPlugin  : public Plugin
{
public:
    /// Codes written in the plugin's state — never renumber.
    enum Mode { right = 1, sum = 2, left = 3 };
    enum Half { inHalf = 0, outHalf = 1 };

    ObjMonoFoldPlugin (PluginCreationInfo info)
        : Plugin (info)
    {
        modeValue.referTo (state, juce::Identifier ("foldMode"), getUndoManager(), (int) sum);
        halfValue.referTo (state, juce::Identifier ("foldHalf"), getUndoManager(), (int) inHalf);
        modeAtomic.store (clampMode (modeValue.get()));
    }

    ~ObjMonoFoldPlugin() override                           { notifyListenersOfDeletion(); }

    using Ptr = juce::ReferenceCountedObjectPtr<ObjMonoFoldPlugin>;

    static const char* getPluginName()                      { return NEEDS_TRANS("Mono Fold"); }
    static const char* xmlTypeName;

    static juce::ValueTree create (int half, int mode)
    {
        juce::ValueTree v (IDs::PLUGIN);
        v.setProperty (IDs::type, xmlTypeName, nullptr);
        v.setProperty (juce::Identifier ("foldHalf"), half, nullptr);
        v.setProperty (juce::Identifier ("foldMode"), clampMode (mode), nullptr);
        return v;
    }

    //==============================================================================
    int  getMode() const noexcept                           { return modeAtomic.load(); }
    int  getHalf() const noexcept                           { return halfValue.get(); }
    bool isActive() const noexcept                          { return activeAtomic.load(); }

    void setMode (int m)
    {
        m = clampMode (m);
        if (modeValue.get() != m) modeValue = m;
        modeAtomic.store (m);
    }

    /// Message thread. Whether the neighbour is a loaded, enabled external plugin with ONE main input (and
    /// one output, for the OUT half). @see the header.
    void refreshActivity()
    {
        bool active = false;
        if (auto* list = getOwnerList())
        {
            const int me = list->indexOf (this);
            const int other = getHalf() == outHalf ? me - 1 : me + 1;
            if (me >= 0 && other >= 0 && other < list->size())
                if (auto* ext = dynamic_cast<ExternalPlugin*> ((*list)[other]))
                    if (ext->isEnabled() && ! ext->isInitialisingAsync())
                        if (auto* proc = ext->getAudioPluginInstance())
                            active = proc->getMainBusNumInputChannels() == 1
                                  && (getHalf() == inHalf || proc->getMainBusNumOutputChannels() <= 1);
        }
        activeAtomic.store (active);
    }

    //==============================================================================
    juce::String getName() const override                   { return TRANS("Mono Fold"); }
    juce::String getPluginType() override                   { return xmlTypeName; }
    juce::String getShortName (int) override                { return "Fold"; }
    juce::String getSelectableDescription() override        { return getName(); }
    bool shouldMeasureCpuUsage() const noexcept final       { return false; }

    int getNumOutputChannelsGivenInputs (int numInputs) override    { return numInputs; }

    // One audio bus each side, no channel count imposed (like ObjGain): a mono signal stays mono.
    BusLayout getBusses() const override                            { return BusLayout::singlePassThrough(); }

    void initialise (const PluginInitialisationInfo&) override              { refreshActivity(); }
    void initialiseWithoutStopping (const PluginInitialisationInfo&) override { refreshActivity(); }
    void deinitialise() override {}

    void applyToBuffer (const PluginRenderContext& fc) override
    {
        if (! isEnabled() || ! activeAtomic.load())
            return;

        SCOPED_REALTIME_CHECK

        auto* buffer = fc.destBuffer;
        if (buffer == nullptr || buffer->getNumChannels() < 2 || fc.bufferNumSamples <= 0)
            return;

        float* l = buffer->getWritePointer (0, fc.bufferStartSample);
        float* r = buffer->getWritePointer (1, fc.bufferStartSample);
        const int n = fc.bufferNumSamples;

        if (halfValue.get() == outHalf)
        {
            juce::FloatVectorOperations::copy (r, l, n);   // the plugin's output on both sides
            return;
        }

        if (modeAtomic.load() == left)
        {
            return;                                         // the plugin reads channel 0 by itself
        }
        else if (modeAtomic.load() == right)
        {
            juce::FloatVectorOperations::copy (l, r, n);
        }
        else
        {
            for (int i = 0; i < n; ++i)
                l[i] = 0.5f * (l[i] + r[i]);
        }
    }

    void restorePluginStateFromValueTree (const juce::ValueTree& v) override
    {
        copyPropertiesToCachedValues (v, modeValue, halfValue);
        modeAtomic.store (clampMode (modeValue.get()));
    }

private:
    static int clampMode (int m)                            { return (m == right || m == left) ? m : (int) sum; }

    juce::CachedValue<int> modeValue, halfValue;
    std::atomic<int>       modeAtomic { (int) sum };
    std::atomic<bool>      activeAtomic { false };

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ObjMonoFoldPlugin)
};

inline const char* ObjMonoFoldPlugin::xmlTypeName = "objMonoFold";

}} // namespace tracktion { inline namespace engine }
