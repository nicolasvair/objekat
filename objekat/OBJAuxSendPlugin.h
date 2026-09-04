//
//  OBJAuxSendPlugin.h
//  objekat
//
//  Envoi vers un aux INTERNE au groupe : il prélève une copie du signal, au niveau réglé,
//  à l'endroit de la chaîne où il est posé (l'app le met post-fader). Le signal continue
//  son chemin inchangé — un send n'est pas un insert.
//
//  Portée : l'émetteur et l'aux visé doivent être enfants directs du MÊME ContainerClip.
//  C'est la frontière du graphe local d'un container, et rien ne la traverse.
//  @see te::ContainerAuxSend, ObjAuxReturnNode, EditViewModel.canRouteSend
//
//  Pourquoi un PLUGIN et pas un nœud de graphe : la chaîne de chaque objet vit sur la
//  plugin-list de son CLIP, donc dans un TimedNode du CombiningNode de la piste — et
//  CombiningNode::getInternalNodes() expose tous ces nœuds au graphe englobant, où un
//  transform les rattraperait. Un plugin, lui, est enveloppé dans un PluginNode ordinaire.
//  C'est le piège qui a tué LatencyMaskingNode ; on ne le repose pas.
//
//  Chaque envoi possède SON buffer, dimensionné dans initialise() — au bon moment, sur le
//  bon thread, à la bonne taille de bloc. Le nœud de retour se contente de sommer ceux qui
//  ont écrit : aucune propriété partagée, aucune énigme de durée de vie, et un envoi qui ne
//  joue pas ne coûte rien.
//

#pragma once

#include <tracktion_engine/tracktion_engine.h>
#include "OBJGainPlugin.h"   // ObjGainDbParameter : même courbe dB que le fader d'objet

namespace tracktion { inline namespace engine {

//==============================================================================
class ObjAuxSendPlugin  : public Plugin,
                          public ContainerAuxSend
{
public:
    ObjAuxSendPlugin (PluginCreationInfo info)
        : Plugin (info)
    {
        auto um = getUndoManager();

        auxClipID.referTo (state, juce::Identifier ("auxClip"), um, juce::String());
        levelDb.referTo   (state, juce::Identifier ("levelDb"), um, silenceDb);

        addAutomatableParameter (levelParam = new ObjGainDbParameter ("level", TRANS("Send Level"),
                                                                      *this, { silenceDb, 12.0f }));
        levelParam->attachToCurrentValue (levelDb);
    }

    ~ObjAuxSendPlugin() override
    {
        notifyListenersOfDeletion();
        levelParam->detachFromCurrentValue();
    }

    using Ptr = juce::ReferenceCountedObjectPtr<ObjAuxSendPlugin>;

    static const char* getPluginName()                      { return NEEDS_TRANS("Aux Send"); }
    static const char* xmlTypeName;

    /// Niveau « rien du tout ». Même valeur que le plancher d'ObjGainPlugin, qui la traite en
    /// zéro EXACT — un silence vrai, pas un -96 dB résiduel.
    static constexpr float silenceDb = -96.0f;

    static juce::ValueTree create()
    {
        juce::ValueTree v (IDs::PLUGIN);
        v.setProperty (IDs::type, xmlTypeName, nullptr);
        return v;
    }

    //==============================================================================
    /// Le clip aux visé (un ContainerClip marqué bus d'aux, frère de l'émetteur).
    void setTargetAuxClip (EditItemID id)                   { auxClipID = id.toString(); }

    float getLevelDb() const                                { return levelParam->getCurrentValue(); }
    void  setLevelDb (float dB)                             { levelParam->setParameter (juce::jlimit (silenceDb, 12.0f, dB),
                                                                                        juce::sendNotification); }

    //==============================================================================
    EditItemID getTargetAuxClipID() const override
    {
        return EditItemID::fromString (auxClipID.get());
    }

    const juce::AudioBuffer<float>* getAndClearAuxTap (int& numSamples) override
    {
        if (! tapWritten)
        {
            numSamples = 0;
            return nullptr;
        }

        tapWritten = false;
        numSamples = tapNumSamples;

        return &tap;
    }

    //==============================================================================
    juce::String getName() const override                   { return TRANS("Aux Send"); }
    juce::String getPluginType() override                   { return xmlTypeName; }
    juce::String getShortName (int) override                { return "Send"; }
    juce::String getSelectableDescription() override        { return getName(); }
    bool shouldMeasureCpuUsage() const noexcept final       { return false; }

    int getNumOutputChannelsGivenInputs (int numInputs) override    { return juce::jmax (2, numInputs); }
    BusLayout getBusses() const override                            { return BusLayout::singlePassThrough(); }

    void initialise (const PluginInitialisationInfo& info) override
    {
        // Dimensionné large : le nœud de retour ne lit que `tapNumSamples`, mais un bloc plus
        // grand que prévu ne doit jamais nous faire écrire hors du buffer.
        tap.setSize (2, juce::jmax (info.blockSizeSamples, 64), false, true, true);
        tap.clear();
        tapWritten = false;
        tapNumSamples = 0;

        smoothedLevel.reset (info.sampleRate, 0.05);
        smoothedLevel.setCurrentAndTargetValue (currentGain());
    }

    void deinitialise() override
    {
        tapWritten = false;
    }

    void applyToBuffer (const PluginRenderContext& fc) override
    {
        // Le signal continue TOUJOURS son chemin : on ne fait que le recopier. Un envoi
        // bypassé ou muet ne laisse simplement pas de tap, et le retour n'a rien à sommer.
        if (! isEnabled())
            return;

        SCOPED_REALTIME_CHECK

        auto* buffer = fc.destBuffer;

        if (buffer == nullptr || fc.bufferNumSamples <= 0)
            return;

        smoothedLevel.setTargetValue (currentGain());

        const int numSamples = juce::jmin (fc.bufferNumSamples, tap.getNumSamples());
        const int numChans   = juce::jmin (buffer->getNumChannels(), tap.getNumChannels());

        if (numSamples <= 0 || numChans <= 0)
            return;

        for (int c = 0; c < numChans; ++c)
            tap.copyFrom (c, 0, *buffer, c, fc.bufferStartSample, numSamples);

        // Un seul canal en entrée : le retour sommerait un signal collé à gauche.
        if (numChans == 1 && tap.getNumChannels() > 1)
            tap.copyFrom (1, 0, tap, 0, 0, numSamples);

        auto level = smoothedLevel;

        for (int c = 0; c < tap.getNumChannels(); ++c)
        {
            auto channelLevel = level;
            channelLevel.applyGain (tap.getWritePointer (c), numSamples);

            if (c + 1 == tap.getNumChannels())
                smoothedLevel = channelLevel;
        }

        tapNumSamples = numSamples;
        tapWritten = true;
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
    juce::AudioBuffer<float> tap { 2, 512 };
    int  tapNumSamples = 0;
    bool tapWritten = false;

    juce::SmoothedValue<float> smoothedLevel;

    float currentGain() const
    {
        const float dB = levelParam->getCurrentValue();
        return dB <= silenceDb ? 0.0f : dbToGain (dB);
    }

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ObjAuxSendPlugin)
};

inline const char* ObjAuxSendPlugin::xmlTypeName = "objAuxSend";

}} // namespace tracktion { inline namespace engine }
