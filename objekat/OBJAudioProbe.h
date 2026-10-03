//
//  OBJAudioProbe.h
//  objekat
//
//  DIAGNOSTIC — n'est installé que si OBJ_AUDIO_PROBE est dans l'environnement.
//  Posé en « global output processor » du DeviceManager Tracktion : il voit le mix FINAL,
//  bloc par bloc, sur le thread audio. Il note l'heure de chaque rappel, le pic du bloc et la
//  charge CPU que Tracktion compare à `cpuLimitBeforeMuting` — de quoi distinguer un rappel en
//  retard (thread audio bloqué) d'un bloc rendu silencieux (graphe, mute CPU…).
//
//  `computeStats()` (commande `perf.audio_probe` action "stats") résume ce qui a été enregistré
//  depuis `reset` : charge CPU moyenne/p99/max (celle que Tracktion compare à son seuil de
//  coupure), RAPPELS EN RETARD (écart entre deux rappels > 1,5× la durée du bloc — le thread
//  audio n'a pas été rendu à temps) et BLOCS COUPÉS (cpu > 0,98 : au-delà, Tracktion efface le
//  bloc suivant). Voir tools/cpu_threads.py pour la vue par thread du processus.
//

#pragma once

#include <tracktion_engine/tracktion_engine.h>
#include <mach/mach_time.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <map>
#include <vector>

struct OBJAudioProbeEntry { uint64_t hostTime; float peak; float cpu; int numSamples; };

/// Résumé d'une fenêtre d'enregistrement (@see OBJAudioProbe::computeStats).
struct OBJAudioProbeStats
{
    uint64_t blocks = 0;
    double   seconds = 0;           // durée couverte (somme des blocs)
    double   cpuMean = 0, cpuP99 = 0, cpuMax = 0;
    uint64_t lateCallbacks = 0;     // écart au rappel précédent > 1,5× la durée du bloc
    double   maxGapMs = 0;          // le plus grand écart observé
    uint64_t mutedBlocks = 0;       // cpu > cpuLimit : Tracktion coupe le bloc suivant
    double   sampleRate = 0;
    int      blockSize = 0;         // taille de bloc la plus fréquente de la fenêtre
};

class OBJAudioProbe : public juce::AudioProcessor
{
public:
    explicit OBJAudioProbe (tracktion::engine::DeviceManager& dm) : deviceManager (dm)
    {
        entries.resize (capacity);
    }

    void reset()                        { writeIndex.store (0); }

    /// Seuil de coupure CPU de Tracktion (DeviceManager::cpuLimitBeforeMuting, 0,98 par défaut).
    static constexpr float cpuMuteLimit = 0.98f;

    /// Résume les blocs enregistrés depuis `reset`. Calculé sur le thread APPELANT (pas l'audio) à
    /// partir d'une copie : coût O(n log n) sur au plus `capacity` blocs.
    OBJAudioProbeStats computeStats() const
    {
        OBJAudioProbeStats st;
        st.sampleRate = sampleRate.load();
        if (st.sampleRate <= 0) st.sampleRate = deviceManager.getSampleRate();   // sonde installée après l'ouverture
        const auto blocks = snapshot();
        if (blocks.empty() || st.sampleRate <= 0) return st;

        mach_timebase_info_data_t tb; mach_timebase_info (&tb);
        auto toMs = [&] (uint64_t ticks) { return (double) ticks * tb.numer / tb.denom / 1.0e6; };

        std::vector<float> cpus; cpus.reserve (blocks.size());
        double cpuSum = 0;
        std::map<int, uint64_t> sizeHistogram;
        for (size_t i = 0; i < blocks.size(); ++i)
        {
            const auto& b = blocks[i];
            const double blockMs = 1000.0 * b.numSamples / st.sampleRate;
            st.seconds += blockMs / 1000.0;
            cpus.push_back (b.cpu);
            cpuSum += b.cpu;
            st.cpuMax = std::max (st.cpuMax, (double) b.cpu);
            if (b.cpu > cpuMuteLimit) ++st.mutedBlocks;
            ++sizeHistogram[b.numSamples];
            if (i > 0)
            {
                const double gapMs = toMs (b.hostTime - blocks[i - 1].hostTime);
                st.maxGapMs = std::max (st.maxGapMs, gapMs);
                if (gapMs > 1.5 * blockMs) ++st.lateCallbacks;
            }
        }
        st.blocks = blocks.size();
        st.cpuMean = cpuSum / (double) blocks.size();
        std::sort (cpus.begin(), cpus.end());
        st.cpuP99 = cpus[std::min (cpus.size() - 1, (size_t) std::ceil (0.99 * (double) cpus.size()) - 1)];
        uint64_t best = 0;
        for (auto& [size, n] : sizeHistogram)
            if (n > best) { best = n; st.blockSize = size; }
        return st;
    }

    /// Copie de ce qui a été écrit depuis `reset` (au plus `capacity` blocs — les plus anciens
    /// sont alors perdus).
    std::vector<OBJAudioProbeEntry> snapshot() const
    {
        const auto n = writeIndex.load();
        std::vector<OBJAudioProbeEntry> out;
        const uint64_t first = n > capacity ? n - capacity : 0;
        for (uint64_t i = first; i < n; ++i)
            out.push_back (entries[(size_t) (i % capacity)]);
        return out;
    }

    const juce::String getName() const override                     { return "OBJAudioProbe"; }
    void prepareToPlay (double sr, int) override                    { sampleRate.store (sr); }
    void releaseResources() override                                {}
    double getTailLengthSeconds() const override                    { return 0; }
    bool acceptsMidi() const override                               { return false; }
    bool producesMidi() const override                              { return false; }
    juce::AudioProcessorEditor* createEditor() override             { return nullptr; }
    bool hasEditor() const override                                 { return false; }
    int getNumPrograms() override                                   { return 1; }
    int getCurrentProgram() override                                { return 0; }
    void setCurrentProgram (int) override                           {}
    const juce::String getProgramName (int) override                { return {}; }
    void changeProgramName (int, const juce::String&) override      {}
    void getStateInformation (juce::MemoryBlock&) override          {}
    void setStateInformation (const void*, int) override            {}

    void processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer&) override
    {
        float peak = 0;
        for (int c = 0; c < buffer.getNumChannels(); ++c)
            peak = std::max (peak, buffer.getMagnitude (c, 0, buffer.getNumSamples()));
        const auto i = writeIndex.load (std::memory_order_relaxed);
        entries[(size_t) (i % capacity)] = { mach_absolute_time(), peak,
                                             (float) deviceManager.getCpuUsage(), buffer.getNumSamples() };
        writeIndex.store (i + 1, std::memory_order_release);
        if (muteAfterMeasuring)
            buffer.clear();
    }

private:
    static constexpr uint64_t capacity = 1 << 16;
    tracktion::engine::DeviceManager& deviceManager;
    std::vector<OBJAudioProbeEntry> entries;
    std::atomic<uint64_t> writeIndex { 0 };
    std::atomic<double> sampleRate { 0 };
    // OBJ_AUDIO_PROBE_MUTE : mesurer sans rien envoyer aux haut-parleurs (bancs automatiques).
    const bool muteAfterMeasuring = getenv ("OBJ_AUDIO_PROBE_MUTE") != nullptr;
};
