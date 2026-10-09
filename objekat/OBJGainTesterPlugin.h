//
//  OBJGainTesterPlugin.h
//  objekat
//
//  A MEASURING tool, reachable only through a DEBUG command (`debug.add_test_plugin`, type
//  `gainTester`): a plain fixed gain, in dB, read from the plugin state's `gainDb` property. It is the
//  IDENTIFIABLE plugin of the send-position proof (docs/plan_sends_rework.md §D.1.C, sections Q/R/V):
//  with gains of known, distinct values in the chain, the level of a send's wet says which of them sit
//  upstream of the tap, hence WHERE the tap is.
//
//  Registered in every build (a session that holds one must load), never added to the list of built-in
//  plugins the UI offers. No latency, no parameter, no editor.
//

#pragma once

#include <tracktion_engine/tracktion_engine.h>

namespace tracktion { inline namespace engine {

//==============================================================================
class ObjGainTesterPlugin  : public Plugin
{
public:
    ObjGainTesterPlugin (PluginCreationInfo info)
        : Plugin (info)
    {
        gainDb.referTo (state, juce::Identifier ("gainDb"), getUndoManager(), 0.0f);
    }

    ~ObjGainTesterPlugin() override
    {
        notifyListenersOfDeletion();
    }

    static const char* getPluginName()                      { return NEEDS_TRANS("Gain Tester"); }
    static const char* xmlTypeName;

    static juce::ValueTree create()
    {
        juce::ValueTree v (IDs::PLUGIN);
        v.setProperty (IDs::type, xmlTypeName, nullptr);
        return v;
    }

    //==============================================================================
    juce::String getName() const override                   { return TRANS("Gain Tester"); }
    juce::String getPluginType() override                   { return xmlTypeName; }
    juce::String getShortName (int) override                { return "Gain"; }
    juce::String getSelectableDescription() override        { return getName(); }
    bool shouldMeasureCpuUsage() const noexcept final       { return false; }

    int getNumOutputChannelsGivenInputs (int) override      { return 2; }
    BusLayout getBusses() const override                    { return BusLayout::singleStereoInOut(); }

    void initialise (const PluginInitialisationInfo&) override {}
    void deinitialise() override {}

    void applyToBuffer (const PluginRenderContext& fc) override
    {
        if (fc.destBuffer == nullptr || fc.bufferNumSamples <= 0)
            return;

        fc.destBuffer->applyGain (fc.bufferStartSample, fc.bufferNumSamples,
                                  juce::Decibels::decibelsToGain (gainDb.get()));
    }

    void restorePluginStateFromValueTree (const juce::ValueTree& v) override
    {
        copyPropertiesToCachedValues (v, gainDb);
    }

private:
    juce::CachedValue<float> gainDb;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ObjGainTesterPlugin)
};

inline const char* ObjGainTesterPlugin::xmlTypeName = "gainTester";

}} // namespace tracktion { inline namespace engine }
