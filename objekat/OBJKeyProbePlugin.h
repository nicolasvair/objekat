//
//  OBJKeyProbePlugin.h
//  objekat
//
//  A MEASURING tool for the audio bridge, reachable only through a DEBUG command
//  (`debug.add_test_plugin`). It declares a sidechain input — so `canSidechain()` is true and the
//  builder wires a key to it — and writes what it receives where an export can read it: its output
//  LEFT is the direct signal, its output RIGHT is the key, sample for sample. Peaks found on the
//  two channels of a render say whether the key is aligned with the signal it was meant for
//  (tools/scenario_bridge_latency.py).
//
//  Registered in every build (a session that holds one must load), but never added to the list of
//  built-in plugins the UI offers. @see docs/plan_sidechain.md §5.8
//

#pragma once

#include <tracktion_engine/tracktion_engine.h>

namespace tracktion { inline namespace engine {

//==============================================================================
class ObjKeyProbePlugin  : public Plugin
{
public:
    ObjKeyProbePlugin (PluginCreationInfo info)
        : Plugin (info)
    {
    }

    ~ObjKeyProbePlugin() override
    {
        notifyListenersOfDeletion();
    }

    static const char* getPluginName()                      { return NEEDS_TRANS("Key Probe"); }
    static const char* xmlTypeName;

    static juce::ValueTree create()
    {
        juce::ValueTree v (IDs::PLUGIN);
        v.setProperty (IDs::type, xmlTypeName, nullptr);
        return v;
    }

    //==============================================================================
    juce::String getName() const override                   { return TRANS("Key Probe"); }
    juce::String getPluginType() override                   { return xmlTypeName; }
    juce::String getShortName (int) override                { return "Probe"; }
    juce::String getSelectableDescription() override        { return getName(); }
    bool shouldMeasureCpuUsage() const noexcept final       { return false; }

    /// Four inputs (the direct stereo pair, then the key's), two outputs: more inputs than
    /// outputs is what makes `canSidechain()` answer true.
    void getChannelNames (juce::StringArray* ins, juce::StringArray* outs) override
    {
        if (ins != nullptr)
        {
            ins->add ("Left");
            ins->add ("Right");
            ins->add ("Key L");
            ins->add ("Key R");
        }

        if (outs != nullptr)
        {
            outs->add ("Left");
            outs->add ("Right");
        }
    }

    int getNumOutputChannelsGivenInputs (int) override      { return 2; }
    BusLayout getBusses() const override                    { return BusLayout::singleStereoInOut(); }

    void initialise (const PluginInitialisationInfo&) override {}
    void deinitialise() override {}

    void applyToBuffer (const PluginRenderContext& fc) override
    {
        auto* buffer = fc.destBuffer;

        // Without a key (3 channels needed: the pair, then Key L) there is nothing to expose.
        if (buffer == nullptr || buffer->getNumChannels() < 3 || fc.bufferNumSamples <= 0)
            return;

        buffer->copyFrom (1, fc.bufferStartSample, *buffer, 2, fc.bufferStartSample, fc.bufferNumSamples);
    }

    void restorePluginStateFromValueTree (const juce::ValueTree&) override {}

private:
    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ObjKeyProbePlugin)
};

inline const char* ObjKeyProbePlugin::xmlTypeName = "objKeyProbe";

}} // namespace tracktion { inline namespace engine }
