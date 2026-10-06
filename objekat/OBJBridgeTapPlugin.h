//
//  OBJBridgeTapPlugin.h
//  objekat
//
//  The TAP of the audio bridge: an engine-only marker laid at the END of a source's chain (after
//  its fader and its window, so what it records is what is HEARD of the source — the point the
//  sends tap), or of a stem's chain (after the bus fader and the meter).
//
//  It never processes anything. The graph builder does not build a PluginNode for it: it builds a
//  BridgeTapNode in its place (createPluginNodeForList, patch 0037), which records the signal in
//  the ring this plugin carries (`BridgeTapSource::ring`). The plugin exists because the ring and
//  the age of the previous build must outlive every graph, and a plugin outlives the graph.
//
//  It is NOT a model plugin: the model never sees it, never saves it, and gives it no id of its
//  own — the engine mints the EditItemID, so the "a plugin id is unique in the project" rule is
//  not concerned. Why a plugin and not a node, same reasoning as ObjAuxSendPlugin: a chain lives
//  on the plugin list of its clip, inside a TimedNode.
//  @see tracktion_ObjBridge.h, docs/plan_sidechain.md §5.8
//

#pragma once

#include <tracktion_engine/tracktion_engine.h>

namespace tracktion { inline namespace engine {

//==============================================================================
class ObjBridgeTapPlugin  : public Plugin,
                            public BridgeTapSource
{
public:
    ObjBridgeTapPlugin (PluginCreationInfo info)
        : Plugin (info)
    {
    }

    ~ObjBridgeTapPlugin() override
    {
        notifyListenersOfDeletion();
    }

    using Ptr = juce::ReferenceCountedObjectPtr<ObjBridgeTapPlugin>;

    static const char* getPluginName()                      { return NEEDS_TRANS("Bridge Tap"); }
    static const char* xmlTypeName;

    static juce::ValueTree create()
    {
        juce::ValueTree v (IDs::PLUGIN);
        v.setProperty (IDs::type, xmlTypeName, nullptr);
        return v;
    }

    //==============================================================================
    juce::String getName() const override                   { return TRANS("Bridge Tap"); }
    juce::String getPluginType() override                   { return xmlTypeName; }
    juce::String getShortName (int) override                { return "Tap"; }
    juce::String getSelectableDescription() override        { return getName(); }
    bool shouldMeasureCpuUsage() const noexcept final       { return false; }

    int getNumOutputChannelsGivenInputs (int numInputs) override    { return juce::jmax (2, numInputs); }
    BusLayout getBusses() const override                            { return BusLayout::singlePassThrough(); }

    void initialise (const PluginInitialisationInfo&) override {}
    void deinitialise() override {}

    /// Never called: the builder replaces this plugin with a BridgeTapNode.
    void applyToBuffer (const PluginRenderContext&) override {}

    void restorePluginStateFromValueTree (const juce::ValueTree&) override {}

private:
    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ObjBridgeTapPlugin)
};

inline const char* ObjBridgeTapPlugin::xmlTypeName = "objBridgeTap";

}} // namespace tracktion { inline namespace engine }
