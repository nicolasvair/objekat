//
//  OBJGainStagePlugin.h
//  objekat
//
//  The GAIN STAGE: a plugin of the user chain the hand lays from a "+" (a gain, or a
//  gain + pan + mute), and what the old chain trims and an FX link's output section became
//  (@see LegacyGainMigration). Unlike the clip's fader (ObjGainPlugin), it is a USER plugin: it
//  lives in the model as an ordinary `ObjectPlugin` leaf (`TracktionInternal`, identifier
//  `objGainStage` or `objGainPanMute`), is copied, linked, automated and counted like any other.
//
//  ONE class, registered under TWO type names (@see ObjGainStageBuiltInType): the "gain" face and
//  the "gain + pan + mute" face share ONE parameter list, so that `OBJParamMirror` (which pairs
//  linked instances by INDEX) can never pair a gain with a pan:
//      index 0  gain  (dB, -24 … +24, linear)
//      index 1  pan   (-1 … +1)
//      index 2  mute  (0 / 1, stepped)
//
//  It is deliberately NOT an ObjGainPlugin, nor derived from one: three engine sites take every
//  `ObjGainPlugin` for a SYSTEM plugin (the master anchor re-adopted after a reload, the bypassed
//  tail of an object render, the consolidate live listener). A user stage must never be one.
//

#pragma once

#include <tracktion_engine/tracktion_engine.h>
#include "OBJGainPlugin.h"   // ObjGainDbParameter / ObjPanParameter (parameter classes only)

namespace tracktion { inline namespace engine {

//==============================================================================
/** The stage's mute: a stepped 0 / 1 parameter (an automation curve on it jumps, never fades). */
struct ObjStageMuteParameter  : public AutomatableParameter
{
    ObjStageMuteParameter (const juce::String& xmlTag, const juce::String& name, Plugin& owner)
        : AutomatableParameter (xmlTag, name, owner, { 0.0f, 1.0f }) {}

    ~ObjStageMuteParameter() override       { notifyListenersOfDeletion(); }

    bool  isDiscrete() const override                   { return true; }
    int   getNumberOfStates() const override            { return 2; }
    float getValueForState (int i) const override       { return i > 0 ? 1.0f : 0.0f; }
    int   getStateForValue (float v) const override     { return v >= 0.5f ? 1 : 0; }
    float snapToState (float v) const override          { return v >= 0.5f ? 1.0f : 0.0f; }
    bool  hasLabels() const override                    { return true; }
    juce::String getLabelForValue (float v) const override  { return v >= 0.5f ? "Muted" : "On"; }
    juce::StringArray getAllLabels() const override     { return { "On", "Muted" }; }

    juce::String valueToString (float v) override       { return getLabelForValue (v); }
    float stringToValue (const juce::String& s) override
    {
        return (s.equalsIgnoreCase ("Muted") || s.getFloatValue() >= 0.5f) ? 1.0f : 0.0f;
    }
};

//==============================================================================
class ObjGainStagePlugin  : public Plugin
{
public:
    /// The range of `gain`, in dB: every legacy trim (-24…24) fits exactly, and a plugin-automation
    /// curve (stored 0…1 in the model, denormalised over THIS range) keeps a readable scale.
    static constexpr float minDb = -24.0f;
    static constexpr float maxDb =  24.0f;

    ObjGainStagePlugin (PluginCreationInfo info)
        : Plugin (info)
    {
        auto um = getUndoManager();

        gainDb.referTo (state, juce::Identifier ("gainDb"), um, 0.0f);
        pan.referTo    (state, IDs::pan,                    um, 0.0f);
        muted.referTo  (state, juce::Identifier ("muted"),  um, false);

        addAutomatableParameter (gainParam = new ObjGainDbParameter    ("gain", TRANS("Gain"), *this, { minDb, maxDb }));
        addAutomatableParameter (panParam  = new ObjPanParameter       ("pan",  TRANS("Pan"),  *this, { -1.0f, 1.0f }));
        addAutomatableParameter (muteParam = new ObjStageMuteParameter ("mute", TRANS("Mute"), *this));

        gainParam->attachToCurrentValue (gainDb);
        panParam->attachToCurrentValue (pan);
        muteParam->attachToCurrentValue (muted);
    }

    ~ObjGainStagePlugin() override
    {
        notifyListenersOfDeletion();
        gainParam->detachFromCurrentValue();
        panParam->detachFromCurrentValue();
        muteParam->detachFromCurrentValue();
    }

    /// The two type names (faces). The model's `ObjectPlugin.identifier` is one of them.
    static const char* xmlTypeName;            // "objGainStage"   — the gain face
    static const char* panMuteXmlTypeName;     // "objGainPanMute" — the gain + pan + mute face

    static const char* getPluginName()          { return NEEDS_TRANS("Gain"); }

    static bool isGainStageType (const juce::String& type)
    {
        return type == xmlTypeName || type == panMuteXmlTypeName;
    }

    //==============================================================================
    /// The type this instance was created under (its face) — the state's own `type`.
    juce::String getPluginType() override
    {
        const auto t = state[IDs::type].toString();
        return isGainStageType (t) ? t : juce::String (xmlTypeName);
    }

    bool isPanMuteFace()                        { return getPluginType() == panMuteXmlTypeName; }

    juce::String getName() const override
    {
        return state[IDs::type].toString() == panMuteXmlTypeName ? TRANS("Gain · Pan") : TRANS("Gain");
    }
    juce::String getShortName (int) override                { return "Gain"; }
    juce::String getSelectableDescription() override        { return getName(); }
    bool shouldMeasureCpuUsage() const noexcept final       { return false; }

    int getNumOutputChannelsGivenInputs (int numInputs) override
    {
        // Mirror of ObjGainPlugin: the only place the graph says how many channels really arrive.
        numInputChannels = numInputs;
        return juce::jmax (2, numInputs);
    }

    BusLayout getBusses() const override                    { return BusLayout::singlePassThrough(); }

    //==============================================================================
    // DSP: a VERBATIM mirror of ObjGainPlugin's initialise / applyToBuffer / updateTargets — keep
    // in step. A migrated trim must be the SAME arithmetic at the same place, so that an old
    // project sounds the same (the null test of scenario_gain_migration.py proves it). The only
    // differences: the gain range, and the mute (its own parameter here, a -96 dB there — both give
    // an exact zero with the fast ramp).

    void initialise (const PluginInitialisationInfo& info) override
    {
        sourceIsMono = (numInputChannels == 1);
        if (! sourceIsMono)
            if (auto* clip = dynamic_cast<AudioClipBase*> (getOwnerClip()))
                if (dynamic_cast<ContainerClip*> (clip) == nullptr)
                    sourceIsMono = clip->getActiveChannelConfiguration().getNumChannels() == 1;

        currentSampleRate = info.sampleRate;
        smoothedGainL.reset (info.sampleRate, rampSeconds);
        smoothedGainR.reset (info.sampleRate, rampSeconds);
        smoothedGain.reset  (info.sampleRate, rampSeconds);
        rampIsFast = false;
        updateTargets (true);
        // First block: the level asked for, as it is — never a ramp from unity (a stage restored at
        // -6 dB would otherwise be heard at 0 dB for its first 50 ms).
        snapToTargets();
        snapPending = false;
    }

    void deinitialise() override {}

    void applyToBuffer (const PluginRenderContext& fc) override
    {
        if (! isEnabled())
            return;

        SCOPED_REALTIME_CHECK

        if (auto* buffer = fc.destBuffer)
        {
            const auto numChans = buffer->getNumChannels();
            updateTargets (numChans > 2);

            // A state RESTORE (undo, a link's resync, a reloaded instance) lands on the value at
            // once, like a creation: it is a new state, not a hand moving a fader.
            if (snapPending.exchange (false))
                snapToTargets();

            if (sourceIsMono && numChans > 1)
                buffer->copyFrom (1, fc.bufferStartSample, *buffer, 0, fc.bufferStartSample,
                                  fc.bufferNumSamples);

            smoothedGainL.applyGain (buffer->getWritePointer (0, fc.bufferStartSample), fc.bufferNumSamples);

            if (numChans > 1)
            {
                smoothedGainR.applyGain (buffer->getWritePointer (1, fc.bufferStartSample), fc.bufferNumSamples);

                if (numChans > 2)
                {
                    auto original = smoothedGain;

                    for (int i = 2; i < numChans; ++i)
                    {
                        smoothedGain = original;
                        smoothedGain.applyGain (buffer->getWritePointer (i, fc.bufferStartSample), fc.bufferNumSamples);
                    }
                }
            }
        }
    }

    void restorePluginStateFromValueTree (const juce::ValueTree& v) override
    {
        copyPropertiesToCachedValues (v, gainDb, pan, muted);

        for (auto* p : getAutomatableParameters())
            p->updateFromAttachedValue();

        snapPending = true;
    }

    //==============================================================================
    juce::CachedValue<float> gainDb, pan;
    juce::CachedValue<bool>  muted;
    AutomatableParameter::Ptr gainParam, panParam, muteParam;

    double rampSeconds = 0.05;
    double muteRampSeconds = 0.005;

private:
    juce::SmoothedValue<float> smoothedGainL, smoothedGainR, smoothedGain;
    double currentSampleRate = 44100.0;
    bool   rampIsFast = false;
    bool   sourceIsMono = false;
    int    numInputChannels = -1;
    std::atomic<bool> snapPending { false };

    void snapToTargets()
    {
        smoothedGainL.setCurrentAndTargetValue (smoothedGainL.getTargetValue());
        smoothedGainR.setCurrentAndTargetValue (smoothedGainR.getTargetValue());
        smoothedGain.setCurrentAndTargetValue  (smoothedGain.getTargetValue());
    }

    void updateTargets (bool updateMonoGain)
    {
        const float dB = gainParam->getCurrentValue();
        const bool  isMuted = muteParam->getCurrentValue() >= 0.5f;
        const float g  = isMuted ? 0.0f : dbToGain (dB);

        const bool wantFast = (g == 0.0f);
        if (wantFast != rampIsFast)
        {
            rampIsFast = wantFast;
            const double seconds = wantFast ? muteRampSeconds : rampSeconds;
            setRampPreservingValue (smoothedGainL, currentSampleRate, seconds);
            setRampPreservingValue (smoothedGainR, currentSampleRate, seconds);
            setRampPreservingValue (smoothedGain,  currentSampleRate, seconds);
        }

        float panL = 1.0f, panR = 1.0f;
        getGainsFromVolumeFaderPositionAndPan (decibelsToVolumeFaderPosition (0.0f),
                                               panParam->getCurrentValue(),
                                               getDefaultPanLaw(), panL, panR);

        smoothedGainL.setTargetValue (g * panL);
        smoothedGainR.setTargetValue (g * panR);

        if (updateMonoGain)
            smoothedGain.setTargetValue (g);
    }

    static void setRampPreservingValue (juce::SmoothedValue<float>& sv, double sampleRate, double seconds)
    {
        const float current = sv.getCurrentValue();
        const float target  = sv.getTargetValue();
        sv.reset (sampleRate, seconds);
        sv.setCurrentAndTargetValue (current);
        sv.setTargetValue (target);
    }

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ObjGainStagePlugin)
};

inline const char* ObjGainStagePlugin::xmlTypeName        = "objGainStage";
inline const char* ObjGainStagePlugin::panMuteXmlTypeName = "objGainPanMute";

//==============================================================================
/** Registers the ONE stage class under one of its two type names. Tracktion's `createBuiltInType<T>`
    takes the name from `T::xmlTypeName`; this one takes it as an argument, and the created instance
    reads its face back from its state's `type`. */
struct ObjGainStageBuiltInType  : public PluginManager::BuiltInType
{
    explicit ObjGainStageBuiltInType (const char* typeName) : BuiltInType (typeName) {}
    Plugin::Ptr create (PluginCreationInfo info) override   { return new ObjGainStagePlugin (info); }
};

}} // namespace tracktion { inline namespace engine }
