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
        fadeInCurve.referTo (state, juce::Identifier ("fadeInCv"), um, 0);
        fadeOutCurve.referTo(state, juce::Identifier ("fadeOutCv"),um, 0);
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
    /// La FORME d'un fondu, en regard de sa longueur. Codes miroir de `FadeCurve.engineCode`
    /// côté Swift — figés une fois pour toutes : ils s'écrivent dans l'état du plugin, donc
    /// dans les projets enregistrés.
    enum Curve { linear = 0, convex = 1, concave = 2, sCurve = 3, sCurveInverse = 4 };

    /// Le gain (0…1) à une PROGRESSION `a` (0 = silence, 1 = plein niveau). Un fondu sortant lit
    /// la même famille à l'envers, si bien qu'« bombé » désigne la courbe au-dessus de la
    /// diagonale des deux côtés.
    ///
    /// Formes closes, jamais de points : une courbe s'évalue par échantillon. Les trois formes
    /// simples sont celles de `AudioFadeCurve` de Tracktion (quart de sinusoïde plutôt que
    /// logarithme : un log part à −∞ en zéro et se ferait borner arbitrairement, là où la
    /// sinusoïde atteint exactement 0 et 1 à ses bords pour le même creux à l'oreille). Les deux
    /// S sont le MÊME mélange des deux autres, poids échangés — `sCurveInverse` est de nous,
    /// Tracktion n'en porte qu'un des deux.
    static inline float curveGain (int curve, float a) noexcept
    {
        a = juce::jlimit (0.0f, 1.0f, a);
        const float q = a * juce::MathConstants<float>::halfPi;
        switch (curve)
        {
            case convex:        return std::sin (q);
            case concave:       return 1.0f - std::cos (q);
            case sCurve:        return (1.0f - a) * (1.0f - std::cos (q)) + a * std::sin (q);
            case sCurveInverse: return a * (1.0f - std::cos (q)) + (1.0f - a) * std::sin (q);
            case linear:
            default:            return a;
        }
    }

    /// Fenêtre = bornes du groupe (secondes edit) + durées de fade (secondes).
    void setWindow (double startSecs, double endSecs, double fadeInSecs, double fadeOutSecs)
    {
        windowStart = startSecs;
        windowEnd   = juce::jmax (startSecs, endSecs);
        fadeIn      = juce::jmax (0.0, fadeInSecs);
        fadeOut     = juce::jmax (0.0, fadeOutSecs);
    }

    /// Les FORMES, posées à part des longueurs : tous les sites qui déplacent ou redimensionnent
    /// un objet reposent la fenêtre (@see setWindowForKey:), et n'ont rien à dire de la forme —
    /// la laisser à `setWindow` l'aurait remise à zéro à chaque geste.
    void setCurves (int curveIn, int curveOut)
    {
        fadeInCurve  = curveIn;
        fadeOutCurve = curveOut;
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
        copyPropertiesToCachedValues (v, windowStart, windowEnd, fadeIn, fadeOut,
                                      fadeInCurve, fadeOutCurve);
    }

    //==============================================================================
    juce::CachedValue<double> windowStart, windowEnd, fadeIn, fadeOut;
    juce::CachedValue<int>    fadeInCurve, fadeOutCurve;

private:
    float envelopeGain (double t, double ws, double we) const
    {
        if (t < ws || t >= we) return 0.0f;
        float g = 1.0f;
        const double fi = fadeIn, fo = fadeOut;
        // `a` est la PROGRESSION du fondu, 0 = silence et 1 = plein niveau, des deux côtés : le
        // fondu sortant lit le temps qui lui RESTE. Une seule famille de formules pour les deux
        // bords, et « bombé » veut dire la même chose sur l'un comme sur l'autre.
        if (fi > 0.0 && t < ws + fi)   g *= curveGain (fadeInCurve,  (float) ((t - ws) / fi));
        if (fo > 0.0 && t > we - fo)   g *= curveGain (fadeOutCurve, (float) ((we - t) / fo));
        return juce::jlimit (0.0f, 1.0f, g);
    }

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ObjWindowFadePlugin)
};

inline const char* ObjWindowFadePlugin::xmlTypeName = "objWindowFade";

}} // namespace tracktion { inline namespace engine }
