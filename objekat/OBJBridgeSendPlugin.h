//
//  OBJBridgeSendPlugin.h
//  objekat
//
//  A SEND, on the audio bridge: an engine-only plugin laid at the END of a sender's chain (after its
//  fader and its window, so what it sends is what is HEARD of the sender), that carries the send's
//  LEVEL and names the aux it feeds. docs/plan_sends_rework.md §A.2.
//
//  Like ObjBridgeTapPlugin it is never processed through a PluginNode: the builder puts a
//  BridgeTapNode in its place (createPluginNodeForList, patch 0037), which records the signal in the
//  ring this plugin carries. The difference is `processesTapCopy()`: for a send the node runs
//  `applyToBuffer` on its COPY of the signal — once per block, never in 128-sample sub-blocks — and
//  writes THAT to the ring. The signal that passes through is never touched. That is the whole of the
//  send level (and what removes the "automated send overwrites its own tap" defect of the first,
//  pre-bridge send plugin, measured at about 6 dB under the curve — plan §B.J).
//
//  The aux return reads the ring through one BridgeReader per send (patch 0039,
//  BridgeBuild::registerAuxReaders); the aux clip lists its sends in `objBridgeSends`, written by
//  the app in the same transaction as the sends themselves.
//
//  It is NOT a model plugin: the model never sees it, never saves it, and gives it no id of its own.
//  The pre-bridge send plugin (ObjAuxSendPlugin) and its OBJ_SENDS_LEGACY switch were deleted in INC 2.
//  @see tracktion_ObjBridge.h, ObjBridgeTapPlugin
//

#pragma once

#include <atomic>
#include <tracktion_engine/tracktion_engine.h>
#include "OBJGainPlugin.h"   // ObjGainDbParameter : same dB curve as the object's fader

namespace tracktion { inline namespace engine {

//==============================================================================
class ObjBridgeSendPlugin  : public Plugin,
                             public BridgeTapSource
{
public:
    ObjBridgeSendPlugin (PluginCreationInfo info)
        : Plugin (info)
    {
        auto um = getUndoManager();

        auxClipID.referTo (state, juce::Identifier ("auxClip"), um, juce::String());
        levelDb.referTo   (state, juce::Identifier ("levelDb"), um, silenceDb);

        addAutomatableParameter (levelParam = new ObjGainDbParameter ("level", TRANS("Send Level"),
                                                                      *this, { silenceDb, 12.0f }));
        levelParam->attachToCurrentValue (levelDb);
    }

    ~ObjBridgeSendPlugin() override
    {
        notifyListenersOfDeletion();
        levelParam->detachFromCurrentValue();
    }

    using Ptr = juce::ReferenceCountedObjectPtr<ObjBridgeSendPlugin>;

    static const char* getPluginName()                      { return NEEDS_TRANS("Bridge Send"); }
    static const char* xmlTypeName;

    /// The floor of the parameter, as the legacy send and ObjGainPlugin have it.
    static constexpr float silenceDb = -96.0f;

    /// At or under this level the send is EXACT silence (the model's sendMinDb, "-inf"): a send
    /// at -60 dB must not leave a residue of 0.001 in the aux. Plan P8.
    static constexpr float exactSilenceDb = -60.0f;

    static juce::ValueTree create()
    {
        juce::ValueTree v (IDs::PLUGIN);
        v.setProperty (IDs::type, xmlTypeName, nullptr);
        return v;
    }

    //==============================================================================
    void setTargetAuxClip (EditItemID id)                   { auxClipID = id.toString(); }

    float getLevelDb() const                                { return levelParam->getCurrentValue(); }
    void  setLevelDb (float dB)                             { levelParam->setParameter (juce::jlimit (silenceDb, 12.0f, dB),
                                                                                        juce::sendNotification); }

    /// The audibility gate (docs/plan_sends_rework.md §1.6): a send whose sender is silenced by a
    /// GROUP's mute — which acts downstream of the tap — must go quiet too. Read at the block, no
    /// graph rebuild: the 50 ms smoother takes the level down, and back up on release.
    void setGated (bool g) noexcept                         { gated.store (g, std::memory_order_relaxed); }
    bool isGated() const noexcept                           { return gated.load (std::memory_order_relaxed); }

    //==============================================================================
    // BridgeTapSource
    EditItemID getBridgeTargetAuxClipID() const override    { return EditItemID::fromString (auxClipID.get()); }
    bool processesTapCopy() const override                  { return true; }

    //==============================================================================
    juce::String getName() const override                   { return TRANS("Bridge Send"); }
    juce::String getPluginType() override                   { return xmlTypeName; }
    juce::String getShortName (int) override                { return "Send"; }
    juce::String getSelectableDescription() override        { return getName(); }
    bool shouldMeasureCpuUsage() const noexcept final       { return false; }

    int getNumOutputChannelsGivenInputs (int numInputs) override    { return juce::jmax (2, numInputs); }
    BusLayout getBusses() const override                            { return BusLayout::singlePassThrough(); }

    void initialise (const PluginInitialisationInfo& info) override
    {
        smoothedLevel.reset (info.sampleRate, 0.05);
        smoothedLevel.setCurrentAndTargetValue (currentGain());
    }

    void deinitialise() override {}

    /// Called by BridgeTapNode on ITS COPY of the signal, once per block (the node moves the edit time
    /// back by the input's age, so a level curve is read where the signal was made). The buffer is the
    /// send's output: it is scaled in place.
    void applyToBuffer (const PluginRenderContext& fc) override
    {
        SCOPED_REALTIME_CHECK

        auto* buffer = fc.destBuffer;

        if (buffer == nullptr || fc.bufferNumSamples <= 0)
            return;

        smoothedLevel.setTargetValue (currentGain());

        if (! smoothedLevel.isSmoothing() && smoothedLevel.getTargetValue() == 0.0f)
        {
            buffer->clear (fc.bufferStartSample, fc.bufferNumSamples);
            return;
        }

        auto level = smoothedLevel;

        for (int c = 0; c < buffer->getNumChannels(); ++c)
        {
            auto channelLevel = level;
            channelLevel.applyGain (buffer->getWritePointer (c, fc.bufferStartSample), fc.bufferNumSamples);

            if (c + 1 == buffer->getNumChannels())
                smoothedLevel = channelLevel;
        }
    }

    void restorePluginStateFromValueTree (const juce::ValueTree& v) override
    {
        copyPropertiesToCachedValues (v, auxClipID, levelDb);

        for (auto* p : getAutomatableParameters())
            p->updateFromAttachedValue();
    }

    //==============================================================================
    juce::CachedValue<juce::String> auxClipID;
    juce::CachedValue<float> levelDb;
    AutomatableParameter::Ptr levelParam;

private:
    //==============================================================================
    juce::SmoothedValue<float> smoothedLevel;
    std::atomic<bool> gated { false };

    float currentGain() const
    {
        if (gated.load (std::memory_order_relaxed))
            return 0.0f;

        const float dB = levelParam->getCurrentValue();
        return dB <= exactSilenceDb ? 0.0f : dbToGain (dB);
    }

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ObjBridgeSendPlugin)
};

inline const char* ObjBridgeSendPlugin::xmlTypeName = "objBridgeSend";

}} // namespace tracktion { inline namespace engine }
