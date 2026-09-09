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
        // Le PLI par défaut est PLEIN : un état qui porte une forme sans dire de combien vient
        // de la première version de la fonctionnalité, où la forme était tout ou rien — et c'est
        // à plein pli qu'il a été entendu. Sur un plugin neuf la forme vaut `linear`, donc ce 1
        // ne courbe rien.
        fadeInAmount.referTo (state, juce::Identifier ("fadeInAmt"), um, 1.0f);
        fadeOutAmount.referTo(state, juce::Identifier ("fadeOutAmt"),um, 1.0f);
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
    /// La FAMILLE d'un fondu : de quel côté il quitte la droite. De COMBIEN il la quitte est à
    /// part (`fadeInAmount` / `fadeOutAmount`), et les deux ensemble font une forme. Codes miroir
    /// de `FadeShape.engineCode` côté Swift — figés une fois pour toutes : ils s'écrivent dans
    /// l'état du plugin, donc dans les projets enregistrés.
    enum Curve { linear = 0, convex = 1, concave = 2, sCurve = 3, sCurveInverse = 4 };

    /// Le pli au BOUT de la course, en exposant. Miroir de `FadeCurve.maxExponent` côté Swift.
    static constexpr float maxExponent = 8.0f;

    /// L'exposant que vaut un pli `amount` (0…1) : 1 (la droite) … `maxExponent`. Géométrique et
    /// non proportionnel — c'est ce que l'œil et l'oreille lisent comme une progression régulière.
    /// À calculer UNE fois par bloc, jamais par échantillon (@see applyToBuffer).
    static inline float bendExponent (float amount) noexcept
    {
        return std::pow (maxExponent, juce::jlimit (0.0f, 1.0f, amount));
    }

    /// Le gain (0…1) à une PROGRESSION `a` (0 = silence, 1 = plein niveau), pour un pli donné en
    /// EXPOSANT `p` ≥ 1 (1 = la droite, et plus il est grand plus c'est courbé). Un fondu sortant
    /// lit la même famille à l'envers, si bien qu'« bombé » désigne la courbe au-dessus de la
    /// diagonale des deux côtés. Miroir de `FadeShape.gain(_:exponent:)` côté Swift.
    ///
    /// Formes closes, jamais de points : une courbe s'évalue par échantillon. Une PUISSANCE plutôt
    /// que le quart de sinusoïde du début : `a^p` est toute une famille là où la sinusoïde était
    /// une forme unique, si bien que le pli a où aller — le pli de la sinusoïde tient maintenant
    /// dans le premier tiers de la course, et le reste de la course continue de courber. Elle
    /// garde ce qui faisait préférer la sinusoïde au logarithme : elle atteint exactement 0 et 1 à
    /// ses bords, sans borne arbitraire du côté du silence. Et `a^p` / `a^(1/p)` sont des reflets
    /// exacts l'un de l'autre dans la diagonale, ce que la paire de sinusoïdes n'était pas.
    ///
    /// Les deux S sont la « gain function » classique : la même puissance sur chaque moitié, la
    /// seconde retournée. Continue et C¹ au milieu (les deux moitiés y ont la pente `p`), ce qui
    /// évite l'angle à mi-course.
    static inline float curveGain (int curve, float p, float a) noexcept
    {
        a = juce::jlimit (0.0f, 1.0f, a);
        if (curve == linear || p <= 1.0f) return a;
        // Les deux familles qui COMMENCENT par se retenir prennent l'exposant tel quel ; les deux
        // autres prennent son inverse — c'est ce qui fait des paires des reflets exacts.
        const bool  hollow = (curve == concave || curve == sCurve);
        const float e = hollow ? p : 1.0f / p;
        if (curve == convex || curve == concave)
            return std::pow (a, e);
        return a < 0.5f ? 0.5f * std::pow (2.0f * a, e)
                        : 1.0f - 0.5f * std::pow (2.0f - 2.0f * a, e);
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
    /// `amountIn` / `amountOut` (0…1) disent de COMBIEN, la forme disant de quel côté.
    void setCurves (int curveIn, float amountIn, int curveOut, float amountOut)
    {
        fadeInCurve   = curveIn;
        fadeOutCurve  = curveOut;
        fadeInAmount  = juce::jlimit (0.0f, 1.0f, amountIn);
        fadeOutAmount = juce::jlimit (0.0f, 1.0f, amountOut);
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

        // Les deux exposants UNE fois par bloc : `std::pow` par échantillon pour une valeur qui ne
        // change pas d'un échantillon à l'autre serait payer la forme au prix du fondu.
        const float pIn  = bendExponent (fadeInAmount);
        const float pOut = bendExponent (fadeOutAmount);

        for (int i = 0; i < n; ++i)
        {
            const double t = blockStart + i * dt;
            const float  g = envelopeGain (t, ws, we, pIn, pOut);
            if (g == 1.0f) continue;
            for (int c = 0; c < numChans; ++c)
                buffer->getWritePointer (c, fc.bufferStartSample)[i] *= g;
        }
    }

    void restorePluginStateFromValueTree (const juce::ValueTree& v) override
    {
        copyPropertiesToCachedValues (v, windowStart, windowEnd, fadeIn, fadeOut,
                                      fadeInCurve, fadeOutCurve, fadeInAmount, fadeOutAmount);
    }

    //==============================================================================
    juce::CachedValue<double> windowStart, windowEnd, fadeIn, fadeOut;
    juce::CachedValue<int>    fadeInCurve, fadeOutCurve;
    juce::CachedValue<float>  fadeInAmount, fadeOutAmount;

private:
    float envelopeGain (double t, double ws, double we, float pIn, float pOut) const
    {
        if (t < ws || t >= we) return 0.0f;
        float g = 1.0f;
        const double fi = fadeIn, fo = fadeOut;
        // `a` est la PROGRESSION du fondu, 0 = silence et 1 = plein niveau, des deux côtés : le
        // fondu sortant lit le temps qui lui RESTE. Une seule famille de formules pour les deux
        // bords, et « bombé » veut dire la même chose sur l'un comme sur l'autre.
        if (fi > 0.0 && t < ws + fi)   g *= curveGain (fadeInCurve,  pIn,  (float) ((t - ws) / fi));
        if (fo > 0.0 && t > we - fo)   g *= curveGain (fadeOutCurve, pOut, (float) ((we - t) / fo));
        return juce::jlimit (0.0f, 1.0f, g);
    }

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ObjWindowFadePlugin)
};

inline const char* ObjWindowFadePlugin::xmlTypeName = "objWindowFade";

}} // namespace tracktion { inline namespace engine }
