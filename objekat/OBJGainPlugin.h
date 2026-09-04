//
//  OBJGainPlugin.h
//  objekat
//
//  Plugin de gain de sortie au niveau clip.
//
//  Placé en DERNIER dans la plugin list du clip → il s'applique APRÈS les
//  inserts utilisateur (vrai gain post-FX), contrairement au VolumeAndPanPlugin
//  natif qui : (1) plafonne à +6 dB en dur, (2) travaille en position de fader
//  (pas en dB) et (3) était inséré en tête de chaîne (pré-FX).
//
//  Ici le gain est un VRAI gain dB, plage -96…+40 dB. Un clip exactement à
//  -96 dB est considéré comme silencieux (sert aussi de valeur de mute).
//

#pragma once

#include <tracktion_engine/tracktion_engine.h>

namespace tracktion { inline namespace engine {

//==============================================================================
/** Paramètre automatisable affiché/édité en dB. */
struct ObjGainDbParameter  : public AutomatableParameter
{
    ObjGainDbParameter (const juce::String& xmlTag, const juce::String& name,
                        Plugin& owner, juce::Range<float> r)
        : AutomatableParameter (xmlTag, name, owner, r) {}

    ~ObjGainDbParameter() override          { notifyListenersOfDeletion(); }

    juce::String valueToString (float value) override
    {
        return juce::Decibels::toString (value, 1, -96.0f);
    }

    float stringToValue (const juce::String& str) override
    {
        return dbStringToDb (str);
    }
};

//==============================================================================
/** Paramètre de panoramique -1…+1. */
struct ObjPanParameter  : public AutomatableParameter
{
    ObjPanParameter (const juce::String& xmlTag, const juce::String& name,
                     Plugin& owner, juce::Range<float> r)
        : AutomatableParameter (xmlTag, name, owner, r) {}

    ~ObjPanParameter() override             { notifyListenersOfDeletion(); }

    juce::String valueToString (float value) override        { return getPanString (value); }

    float stringToValue (const juce::String& str) override
    {
        const float v = str.retainCharacters ("0123456789.-").getFloatValue();
        return str.contains (TRANS("Left")) ? -v : v;
    }
};

//==============================================================================
class ObjGainPlugin  : public Plugin
{
public:
    ObjGainPlugin (PluginCreationInfo info)
        : Plugin (info)
    {
        auto um = getUndoManager();

        gainDb.referTo (state, juce::Identifier ("gainDb"), um, 0.0f);
        pan.referTo    (state, IDs::pan,                    um, 0.0f);

        addAutomatableParameter (gainParam = new ObjGainDbParameter ("gain", TRANS("Gain"), *this, { -96.0f, 40.0f }));
        addAutomatableParameter (panParam  = new ObjPanParameter    ("pan",  TRANS("Pan"),  *this, {  -1.0f,  1.0f }));

        gainParam->attachToCurrentValue (gainDb);
        panParam->attachToCurrentValue (pan);
    }

    ~ObjGainPlugin() override
    {
        notifyListenersOfDeletion();
        gainParam->detachFromCurrentValue();
        panParam->detachFromCurrentValue();
    }

    using Ptr = juce::ReferenceCountedObjectPtr<ObjGainPlugin>;

    static const char* getPluginName()                      { return NEEDS_TRANS("Clip Gain"); }
    static const char* xmlTypeName;

    static juce::ValueTree create()
    {
        juce::ValueTree v (IDs::PLUGIN);
        v.setProperty (IDs::type, xmlTypeName, nullptr);
        return v;
    }

    //==============================================================================
    float getGainDb() const                                 { return gainParam->getCurrentValue(); }
    void  setGainDb (float dB)                              { gainParam->setParameter (juce::jlimit (-96.0f, 40.0f, dB), juce::sendNotification); }

    float getPan() const                                    { return panParam->getCurrentValue(); }
    void  setPan (float p)
    {
        if (p >= -0.005f && p <= 0.005f)
            p = 0.0f;

        panParam->setParameter (juce::jlimit (-1.0f, 1.0f, p), juce::sendNotification);
    }

    //==============================================================================
    juce::String getName() const override                   { return TRANS("Clip Gain"); }
    juce::String getPluginType() override                   { return xmlTypeName; }
    juce::String getShortName (int) override                { return "Gain"; }
    juce::String getSelectableDescription() override        { return getName(); }
    bool shouldMeasureCpuUsage() const noexcept final       { return false; }

    int getNumOutputChannelsGivenInputs (int numInputs) override
    {
        // Relevé au passage : c'est le seul endroit où le graphe nous dit combien de canaux
        // arrivent RÉELLEMENT en amont de ce fader. @see initialise
        numInputChannels = numInputs;
        return juce::jmax (2, numInputs);
    }

    // Un bus audio de chaque côté, sans exigence de nombre de canaux : comme VCA,
    // LevelMeter ou AuxSend. Pur virtuel depuis tracktion 3.5.
    BusLayout getBusses() const override                            { return BusLayout::singlePassThrough(); }

    void initialise (const PluginInitialisationInfo& info) override
    {
        // Source mono : le socle multicanal ne duplique plus la source sur les canaux de
        // destination (le nœud du clip est bâti en discreteChannels(N), N = canaux du fichier).
        // Le buffer est bien élargi à 2 canaux ici — getNumOutputChannelsGivenInputs le déclare —
        // mais le canal droit reste vide, et le clip ne sortait que par la gauche. On recopie
        // donc le gauche à droite AVANT le gain, ce qui centre le mono et rend le pan opérant.
        //
        // Deux sources d'information, dans cet ordre :
        //   • le nombre de canaux que le GRAPHE déclare à l'entrée de ce fader. C'est un fait
        //     dur, disponible à toute profondeur d'imbrication et sans dépendre d'aucune
        //     résolution de clip : `createNodeForPlugin` appelle
        //     `getNumOutputChannelsGivenInputs (incomingChannels)`
        //     (tracktion_EditNodeBuilder.cpp) AVANT de construire le PluginNode, dont le
        //     constructeur déclenche cet `initialise` — l'ordre est garanti, la valeur est là.
        //     Et comme `getBusses()` ne déclare aucun canal requis, rien n'élargit le buffer en
        //     amont : un fichier mono arrive bien ici avec 1 canal ;
        //   • à défaut, la configuration de canaux du clip porteur. Elle reste nécessaire quand
        //     un FX en amont a déjà élargi le buffer à deux canaux dont le droit est vide.
        //
        // Pourquoi le relevé du graphe passe en premier — l'ordre vient d'un bug, mais il se
        // justifie sans lui : `getOwnerClip()` ne résolvait rien dès qu'un clip était enfoui
        // dans DEUX ContainerClips ou plus (grouper deux groupes dans un troisième renvoyait
        // alors tous les monos à gauche), parce que `Plugin::getOwnerClip()` délègue à
        // `findClipForID (Edit&, EditItemID)`, qui ne descendait QU'UN niveau de container.
        // Corrigé dans le moteur vendored le 2026-08-13 (`engine-patches/3.5/0027`) : la
        // recherche est désormais récursive, et le second test redevient fiable à toute
        // profondeur. Il reste second : le graphe dit ce qui ENTRE vraiment dans ce fader, le
        // clip ne dit que ce qu'il y avait à la source.
        //
        // Un ContainerClip est EXCLU du second test : un bus (groupe ou aux) n'a pas de fichier
        // source, sa « configuration de canaux » ne dit rien de ce qui le traverse — s'y fier
        // repliait le stéréo d'un groupe sur son canal gauche.
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
        // Premier bloc : on prend le niveau demandé tel quel. Sans ça, un objet réduit au silence
        // pendant que le transport était à l'arrêt repartirait de son ancien niveau — la rampe
        // n'avance qu'au fil des blocs, donc elle se jouerait ENTIÈREMENT au démarrage de la
        // lecture, et on entendrait le son qu'on croyait coupé.
        smoothedGainL.setCurrentAndTargetValue (smoothedGainL.getTargetValue());
        smoothedGainR.setCurrentAndTargetValue (smoothedGainR.getTargetValue());
        smoothedGain.setCurrentAndTargetValue  (smoothedGain.getTargetValue());
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

            if (sourceIsMono && numChans > 1)
                buffer->copyFrom (1, fc.bufferStartSample, *buffer, 0, fc.bufferStartSample,
                                  fc.bufferNumSamples);

            smoothedGainL.applyGain (buffer->getWritePointer (0, fc.bufferStartSample), fc.bufferNumSamples);

            if (numChans > 1)
            {
                smoothedGainR.applyGain (buffer->getWritePointer (1, fc.bufferStartSample), fc.bufferNumSamples);

                // > 2 canaux : on applique le gain mono (sans pan) au reste
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
        copyPropertiesToCachedValues (v, gainDb, pan);

        for (auto* p : getAutomatableParameters())
            p->updateFromAttachedValue();
    }

    //==============================================================================
    juce::CachedValue<float> gainDb, pan;
    AutomatableParameter::Ptr gainParam, panParam;

    /// Temps de lissage des changements de gain (anti-zipper).
    double rampSeconds = 0.05;
    /// Lissage de la COUPURE (mute, solo, silence composé). Le temps anti-zipper est calibré pour
    /// un fader qu'on bouge à la main : appliqué à une coupure, il la rend audible — c'est très
    /// exactement « le son continue quelques millisecondes après le solo ». Assez court pour ne
    /// rien laisser passer, assez long pour ne pas claquer.
    double muteRampSeconds = 0.005;

private:
    juce::SmoothedValue<float> smoothedGainL, smoothedGainR, smoothedGain;
    double currentSampleRate = 44100.0;
    /// La rampe courante est-elle la rampe de coupure ? Évite de reconfigurer à chaque bloc.
    bool   rampIsFast = false;
    bool sourceIsMono = false;   // relevé à l'initialise (voir applyToBuffer)
    /// Canaux vus en entrée par le graphe, relevés à la construction du nœud. -1 = jamais
    /// interrogé (le fader n'est pas dans un graphe) → l'initialise s'en remet au clip porteur.
    int  numInputChannels = -1;

    void updateTargets (bool updateMonoGain)
    {
        const float dB = gainParam->getCurrentValue();
        const float g  = dB <= -96.0f ? 0.0f : dbToGain (dB);

        // Une coupure se lisse en quelques millisecondes, un mouvement de fader en cinquante.
        // @see muteRampSeconds. On ne reconfigure que sur CHANGEMENT de régime : `reset` coûte
        // une division par voie, et surtout il faut y remettre la valeur courante (voir plus bas).
        const bool wantFast = (g == 0.0f);
        if (wantFast != rampIsFast)
        {
            rampIsFast = wantFast;
            const double seconds = wantFast ? muteRampSeconds : rampSeconds;
            setRampPreservingValue (smoothedGainL, currentSampleRate, seconds);
            setRampPreservingValue (smoothedGainR, currentSampleRate, seconds);
            setRampPreservingValue (smoothedGain,  currentSampleRate, seconds);
        }

        // Position de fader unité (= gain 1.0) → on récupère les facteurs de pan
        // purs, qu'on multiplie ensuite par notre gain dB.
        float panL = 1.0f, panR = 1.0f;
        getGainsFromVolumeFaderPositionAndPan (decibelsToVolumeFaderPosition (0.0f),
                                               panParam->getCurrentValue(),
                                               getDefaultPanLaw(), panL, panR);

        smoothedGainL.setTargetValue (g * panL);
        smoothedGainR.setTargetValue (g * panR);

        if (updateMonoGain)
            smoothedGain.setTargetValue (g);
    }

    /// Change la longueur de rampe SANS déplacer le niveau courant. `SmoothedValue::reset` recale
    /// d'office la valeur courante sur la cible — au milieu d'une rampe, ce serait un saut, donc
    /// un clic. On la remet donc en place, puis on réarme la cible avec la nouvelle longueur.
    static void setRampPreservingValue (juce::SmoothedValue<float>& sv, double sampleRate, double seconds)
    {
        const float current = sv.getCurrentValue();
        const float target  = sv.getTargetValue();
        sv.reset (sampleRate, seconds);
        sv.setCurrentAndTargetValue (current);
        sv.setTargetValue (target);
    }

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ObjGainPlugin)
};

inline const char* ObjGainPlugin::xmlTypeName = "objGain";

}} // namespace tracktion { inline namespace engine }
