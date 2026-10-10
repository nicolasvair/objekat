//
//  OBJBridgeSendPlugin.h
//  objekat
//
//  A SEND, on the audio bridge: an engine-only plugin that carries the send's LEVEL and names the aux it
//  feeds. By default it is laid at the END of a sender's chain (after its fader and its window, so what it
//  sends is what is HEARD of the sender); since INC 2 the model can put it elsewhere in the list — before
//  the fader, before the chain's IN gain, or between two plugins — and `-applySendPositionsForKey:` moves
//  it there. docs/plan_sends_rework.md §A.2, §D.1.
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
#include "OBJWindowFadePlugin.h"   // the envelope a pre-fader / in-chain send FOLLOWS (setEnvelopeSource)

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

        // No state.addListener: Plugin is registered already, valueTreeChildAdded/Removed are overridden.
        rebuildChainList();
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

    /// WHERE the model wants this send in its sender's list (docs/plan_sends_rework.md §D.1.A): set by the
    /// bridge sync, read by `-applySendPositionsForKey:` on the message thread only. 0 post-fader (the end
    /// of the list), 1 pre-fader (before the fader), 2 input (before the chain's IN gain), 3 in the chain
    /// (per the order the last compile recorded). Not state: it is rebuilt by every sync.
    enum TapPosition { postFader = 0, preFader = 1, input = 2, chain = 3 };
    void setTapPosition (int p) noexcept                    { tapPosition = p; }
    int  getTapPosition() const noexcept                    { return tapPosition; }

    /// The sender's window + fades, which this send lays on its COPY (never on the direct signal), AFTER
    /// its plugins and BEFORE its level (`processTapEnvelope`). Two cases set it, one leaves it null:
    ///   • a send that taps BEFORE the fader (input, in the chain, pre-fader — Q-U5): it still follows the
    ///     object's fades and window — a cropped object stops feeding its aux at its window's edge, a
    ///     fade-out fades the reverb send — but not its volume or pan;
    ///   • a post-fader send that CARRIES PLUGINS (Q-U18, 10 October): the engine then lays it between
    ///     the fader and the window-fade (`-applySendPositionsForKey:`), so that the envelope comes
    ///     ONCE, after the plugins — an effect's tail follows the fade-out and stops with the window;
    ///   • null for a post-fader send without plugins: the window sits upstream of its tap already.
    /// Message thread; the audio thread reads a raw mirror. The previous plugin is kept alive one
    /// generation (`retired`): a block that started with the old pointer finishes against a live
    /// object, and the next replacement is an edit away — milliseconds are not at stake, an edit is a
    /// human gesture.
    void setEnvelopeSource (ObjWindowFadePlugin::Ptr window)
    {
        if (window.get() == envelope.get())
            return;

        retired  = envelope;
        envelope = window;
        envelopeRaw.store (window.get(), std::memory_order_release);
    }

    bool hasEnvelopeSource() const noexcept                 { return envelopeRaw.load (std::memory_order_acquire) != nullptr; }

    float getLevelDb() const                                { return levelParam->getCurrentValue(); }
    void  setLevelDb (float dB)                             { levelParam->setParameter (juce::jlimit (silenceDb, 12.0f, dB),
                                                                                        juce::sendNotification); }

    /// The audibility gate (docs/plan_sends_rework.md §1.6): a send whose sender is silenced by a
    /// GROUP's mute — which acts downstream of the tap — must go quiet too. Read at the block, no
    /// graph rebuild: the 50 ms smoother takes the level down, and back up on release.
    void setGated (bool g) noexcept                         { gated.store (g, std::memory_order_relaxed); }
    bool isGated() const noexcept                           { return gated.load (std::memory_order_relaxed); }

    //==============================================================================
    // The send's PLUGINS (INC 3, docs/plan_sends_rework.md §D.2.A): a mini-chain processed on the
    // send's copy, between the tap and the envelope (then the level). It is ONE PluginList over a
    // <BRANCH> child of this plugin's state — the tree type PluginList::initialise accepts (patch 0018);
    // this plugin does NOT implement ParallelPluginBlock, or the builder would unfold it as a block.
    // The list has its own entry limit: its plugins do not count in the sender's chain.

    /// The mini-chain, or nullptr while the send has never carried a plugin. Message thread.
    PluginList* getChainList() const                        { return chainList.get(); }

    /// The mini-chain, its <BRANCH> created if need be (the compile is about to fill it).
    PluginList& ensureChainList()
    {
        if (chainList == nullptr)
            state.appendChild (juce::ValueTree (ParallelPluginBlock::branchTreeType), nullptr);   // → rebuildChainList

        jassert (chainList != nullptr);
        refreshChainOwners();
        return *chainList;
    }

    /// Re-seats the mini-chain's owners on the send plugin's CURRENT track and clip. The list keeps
    /// raw pointers (`PluginList::setTrackAndClip`) taken when it was built; a clip that changes
    /// pool track afterwards (a rank or a stem change: `moveClipToOwner`) would leave the old
    /// track there, freed once its pool slot is pruned — and `PluginList::insertPlugin` reads it.
    void refreshChainOwners()
    {
        if (chainList != nullptr)
            chainList->setTrackAndClip (getOwnerTrack(), getOwnerClip());
    }

    /// The series latency of the mini-chain. The clip's head and tail read it (Clip::getHead /
    /// getTail), so that the wet branch is fed before the window and flushed after it; the lane's
    /// equalisation reads NODE latencies, where it does not appear: it ages the tap, never the dry.
    double getLatencySeconds() override
    {
        double latency = 0.0;

        if (chainList != nullptr)
            for (auto p : *chainList)
                latency += std::max (0.0, p->getLatencySeconds());

        return latency;
    }

    /// The mini-chain's plugins are in no host list: nobody else would initialise them, and their
    /// latency would read 0 at the first build of the graph (as for a parallel block's branches).
    void initialiseFully() override
    {
        Plugin::initialiseFully();

        if (chainList != nullptr)
            for (auto p : *chainList)
                p->initialiseFully();
    }

    //==============================================================================
    // BridgeTapSource
    EditItemID getBridgeTargetAuxClipID() const override    { return EditItemID::fromString (auxClipID.get()); }
    bool processesTapCopy() const override                  { return true; }
    PluginList* getTapChain() override                      { return chainList.get(); }

    /// The envelope of the send: the sender's window and fades, laid on the copy AFTER the send's
    /// plugins and BEFORE its level, so that the tail of a delay or a reverb on the send follows the
    /// object's fade-out and is exact silence past its window — what the window-fade does to a plugin
    /// of the object's own chain. `editTime` is the time the samples were MADE at (the tap node moves
    /// it back by the copy's age, the mini-chain's latency included): the same time the window-fade of
    /// the main path reads for the same material. Once per block, no-op without an envelope source.
    void processTapEnvelope (juce::AudioBuffer<float>& buffer, int start, int numSamples, TimeRange editTime) override
    {
        if (auto* env = envelopeRaw.load (std::memory_order_acquire))
            env->applyEnvelope (buffer, start, numSamples, editTime);
    }

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
    /// back by the copy's age, so a level curve is read where the signal was made), AFTER the send's
    /// plugins and the envelope (processTapEnvelope): the LEVEL and the gate come last (Q-U17). The
    /// buffer is the send's output: it is scaled in place.
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
    std::unique_ptr<PluginList> chainList;      // a view on the <BRANCH> child, null without one
    std::atomic<bool> gated { false };
    int tapPosition = postFader;       // message thread only
    ObjWindowFadePlugin::Ptr envelope, retired;                 // message thread only
    std::atomic<ObjWindowFadePlugin*> envelopeRaw { nullptr };  // the audio thread's mirror

    // The list is only a view on the <BRANCH> subtree: rebuilt whole when that child comes or goes
    // (an edit of the structure, never during playback; the graph is rebuilt behind it anyway).
    void rebuildChainList()
    {
        chainList.reset();

        auto branch = state.getChildWithName (ParallelPluginBlock::branchTreeType);

        if (! branch.isValid())
            return;

        chainList = std::make_unique<PluginList> (edit);
        chainList->setTrackAndClip (getOwnerTrack(), getOwnerClip());
        chainList->initialise (branch);
    }

    void valueTreeChildAdded (juce::ValueTree& parent, juce::ValueTree& child) override
    {
        if (parent == state && child.hasType (ParallelPluginBlock::branchTreeType))
            rebuildChainList();

        Plugin::valueTreeChildAdded (parent, child);
    }

    void valueTreeChildRemoved (juce::ValueTree& parent, juce::ValueTree& child, int index) override
    {
        if (parent == state && child.hasType (ParallelPluginBlock::branchTreeType))
            rebuildChainList();

        Plugin::valueTreeChildRemoved (parent, child, index);
    }

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
