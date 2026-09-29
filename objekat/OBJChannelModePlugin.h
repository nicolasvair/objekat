//
//  OBJChannelModePlugin.h
//  objekat
//
//  Choix de canal d'un clip audio STÉRÉO, en lecture, sans toucher au fichier : LR (le
//  clip tel qu'il est), L (le canal gauche seul, sur les deux côtés), R (le droit seul, sur
//  les deux côtés) ou C (la somme mono (L+R)/2, sur les deux côtés).
//
//  Placé en TÊTE de la plugin-list du clip, donc AVANT trims, FX, fader et fenêtre : le choix
//  porte sur la SOURCE, et tout ce qui suit travaille sur le signal choisi (un compresseur voit
//  le canal retenu, pas le stéréo d'origine). Il n'existe que tant que le mode n'est pas LR —
//  un clip ordinaire ne paie pas un nœud de plus dans son graphe (@see
//  OBJEngineCore `-updateChannelMode:forID:`). Et comme l'ObjGain, il n'a pas de carte dans la
//  synoptique : le modèle ne le liste pas, c'est un plugin de service.
//
//  Le mode est un entier (codes miroir de `ChannelMode.engineCode` côté Swift, figés : ils
//  s'écrivent dans l'état du plugin) ; il se relit par un atomique, le thread audio ne touchant
//  jamais à l'arbre d'état. Un buffer de moins de deux canaux (un mono qui aurait passé la
//  garde du modèle) traverse sans être touché.
//

#pragma once

#include <tracktion_engine/tracktion_engine.h>

namespace tracktion { inline namespace engine {

//==============================================================================
class ObjChannelModePlugin  : public Plugin
{
public:
    /// Codes miroir de `ChannelMode.engineCode` (Swift) — ne jamais renuméroter.
    enum Mode { lr = 0, left = 1, right = 2, centre = 3 };

    ObjChannelModePlugin (PluginCreationInfo info)
        : Plugin (info)
    {
        modeValue.referTo (state, juce::Identifier ("chMode"), getUndoManager(), (int) lr);
        modeAtomic.store (juce::jlimit ((int) lr, (int) centre, (int) modeValue.get()));
    }

    ~ObjChannelModePlugin() override                        { notifyListenersOfDeletion(); }

    using Ptr = juce::ReferenceCountedObjectPtr<ObjChannelModePlugin>;

    static const char* getPluginName()                      { return NEEDS_TRANS("Channel Mode"); }
    static const char* xmlTypeName;

    static juce::ValueTree create()
    {
        juce::ValueTree v (IDs::PLUGIN);
        v.setProperty (IDs::type, xmlTypeName, nullptr);
        return v;
    }

    //==============================================================================
    int  getMode() const noexcept                           { return modeAtomic.load(); }

    void setMode (int m)
    {
        m = juce::jlimit ((int) lr, (int) centre, m);
        modeValue = m;
        modeAtomic.store (m);
    }

    //==============================================================================
    juce::String getName() const override                   { return TRANS("Channel Mode"); }
    juce::String getPluginType() override                   { return xmlTypeName; }
    juce::String getShortName (int) override                { return "Chan"; }
    juce::String getSelectableDescription() override        { return getName(); }
    bool shouldMeasureCpuUsage() const noexcept final       { return false; }

    int getNumOutputChannelsGivenInputs (int numInputs) override    { return numInputs; }

    // Un bus audio de chaque côté, sans exigence de nombre de canaux (comme ObjGain).
    BusLayout getBusses() const override                            { return BusLayout::singlePassThrough(); }

    void initialise (const PluginInitialisationInfo&) override {}
    void deinitialise() override {}

    void applyToBuffer (const PluginRenderContext& fc) override
    {
        if (! isEnabled())
            return;

        SCOPED_REALTIME_CHECK

        auto* buffer = fc.destBuffer;
        if (buffer == nullptr || buffer->getNumChannels() < 2 || fc.bufferNumSamples <= 0)
            return;

        const int mode = modeAtomic.load();
        if (mode == lr)
            return;

        float* l = buffer->getWritePointer (0, fc.bufferStartSample);
        float* r = buffer->getWritePointer (1, fc.bufferStartSample);
        const int n = fc.bufferNumSamples;

        switch (mode)
        {
            case left:   juce::FloatVectorOperations::copy (r, l, n); break;
            case right:  juce::FloatVectorOperations::copy (l, r, n); break;
            case centre:
                for (int i = 0; i < n; ++i)
                {
                    const float m = 0.5f * (l[i] + r[i]);
                    l[i] = m;
                    r[i] = m;
                }
                break;
            default: break;
        }
    }

    void restorePluginStateFromValueTree (const juce::ValueTree& v) override
    {
        copyPropertiesToCachedValues (v, modeValue);
        modeAtomic.store (juce::jlimit ((int) lr, (int) centre, (int) modeValue.get()));
    }

private:
    juce::CachedValue<int> modeValue;
    std::atomic<int>       modeAtomic { (int) lr };

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ObjChannelModePlugin)
};

inline const char* ObjChannelModePlugin::xmlTypeName = "objChannelMode";

}} // namespace tracktion { inline namespace engine }
