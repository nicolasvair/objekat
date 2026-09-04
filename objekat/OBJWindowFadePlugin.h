//
//  OBJWindowFadePlugin.h
//  objekat
//
//  Enveloppe « fenêtre + fade » de groupe, posée en DERNIER dans la plugin-list
//  du FolderTrack submix d'un groupe (après l'ObjGain de bus).
//
//  Modèle folder : un groupe est un FolderTrack SANS bornes temporelles ; ses
//  enfants jouent toute leur étendue. Ce plugin restitue le « fenêtrage » que
//  l'ancien ContainerClip offrait gratuitement :
//   - coupe la sortie du bus hors de [windowStart, windowEnd] (bornes du groupe),
//   - applique fadeIn au bord gauche et fadeOut au bord droit.
//  Non-destructif (ré-élargir les bornes révèle l'audio à nouveau) et POST-bus
//  (le fade inclut les returns/reverb du groupe). Le temps d'edit absolu de
//  chaque bloc vient de PluginRenderContext::editTime.
//
//  Paramètres pilotés par le modèle Swift (pas de knobs utilisateur), donc pas
//  d'AutomatableParameter : on les recalcule depuis le modèle à chaque
//  create/move/resize/fade et au chargement de projet.
//

#pragma once

#include <tracktion_engine/tracktion_engine.h>

namespace tracktion { inline namespace engine {

//==============================================================================
class ObjWindowFadePlugin  : public Plugin
{
public:
    ObjWindowFadePlugin (PluginCreationInfo info)
        : Plugin (info)
    {
        auto um = getUndoManager();
        windowStart.referTo (state, juce::Identifier ("winStart"), um, 0.0);
        windowEnd.referTo   (state, juce::Identifier ("winEnd"),   um, 0.0);
        fadeIn.referTo      (state, juce::Identifier ("fadeIn"),   um, 0.0);
        fadeOut.referTo     (state, juce::Identifier ("fadeOut"),  um, 0.0);
    }

    ~ObjWindowFadePlugin() override                         { notifyListenersOfDeletion(); }

    using Ptr = juce::ReferenceCountedObjectPtr<ObjWindowFadePlugin>;

    static const char* getPluginName()                      { return NEEDS_TRANS("Group Window"); }
    static const char* xmlTypeName;

    static juce::ValueTree create()
    {
        juce::ValueTree v (IDs::PLUGIN);
        v.setProperty (IDs::type, xmlTypeName, nullptr);
        return v;
    }

    //==============================================================================
    /// Fenêtre = bornes du groupe (secondes edit) + durées de fade (secondes).
    void setWindow (double startSecs, double endSecs, double fadeInSecs, double fadeOutSecs)
    {
        windowStart = startSecs;
        windowEnd   = juce::jmax (startSecs, endSecs);
        fadeIn      = juce::jmax (0.0, fadeInSecs);
        fadeOut     = juce::jmax (0.0, fadeOutSecs);
    }

    //==============================================================================
    juce::String getName() const override                   { return TRANS("Group Window"); }
    juce::String getPluginType() override                   { return xmlTypeName; }
    juce::String getShortName (int) override                { return "Window"; }
    juce::String getSelectableDescription() override        { return getName(); }
    bool shouldMeasureCpuUsage() const noexcept final       { return false; }

    int getNumOutputChannelsGivenInputs (int numInputs) override    { return juce::jmax (2, numInputs); }

    // Un bus audio de chaque côté, sans exigence de nombre de canaux : comme VCA,
    // LevelMeter ou AuxSend. Pur virtuel depuis tracktion 3.5.
    BusLayout getBusses() const override                            { return BusLayout::singlePassThrough(); }

    void initialise (const PluginInitialisationInfo&) override {}
    void deinitialise() override {}

    void applyToBuffer (const PluginRenderContext& fc) override
    {
        if (! isEnabled())
            return;

        SCOPED_REALTIME_CHECK

        auto* buffer = fc.destBuffer;
        if (buffer == nullptr || fc.bufferNumSamples <= 0)
            return;

        const double ws = windowStart, we = windowEnd;

        // Fenêtre non définie / dégénérée → pass-through (jamais de silence accidentel
        // avant que updateGroupWindow: n'ait posé les vraies bornes).
        if (we <= ws)
            return;

        const double blockStart = fc.editTime.getStart().inSeconds();
        const double blockEnd   = fc.editTime.getEnd().inSeconds();

        // Bloc entièrement hors fenêtre → silence rapide.
        if (blockEnd <= ws || blockStart >= we)
        {
            buffer->clear (fc.bufferStartSample, fc.bufferNumSamples);
            return;
        }

        const int    n  = fc.bufferNumSamples;
        const double dt = (blockEnd - blockStart) / juce::jmax (1, n);
        const int numChans = buffer->getNumChannels();

        for (int i = 0; i < n; ++i)
        {
            const double t = blockStart + i * dt;
            const float  g = envelopeGain (t, ws, we);
            if (g == 1.0f) continue;
            for (int c = 0; c < numChans; ++c)
                buffer->getWritePointer (c, fc.bufferStartSample)[i] *= g;
        }
    }

    void restorePluginStateFromValueTree (const juce::ValueTree& v) override
    {
        copyPropertiesToCachedValues (v, windowStart, windowEnd, fadeIn, fadeOut);
    }

    //==============================================================================
    juce::CachedValue<double> windowStart, windowEnd, fadeIn, fadeOut;

private:
    float envelopeGain (double t, double ws, double we) const
    {
        if (t < ws || t >= we) return 0.0f;
        float g = 1.0f;
        const double fi = fadeIn, fo = fadeOut;
        if (fi > 0.0 && t < ws + fi)   g *= (float) ((t - ws) / fi);
        if (fo > 0.0 && t > we - fo)   g *= (float) ((we - t) / fo);
        return juce::jlimit (0.0f, 1.0f, g);
    }

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ObjWindowFadePlugin)
};

inline const char* ObjWindowFadePlugin::xmlTypeName = "objWindowFade";

}} // namespace tracktion { inline namespace engine }
