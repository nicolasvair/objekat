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

#pragma once

#include <tracktion_engine/tracktion_engine.h>
#include <mach/mach_time.h>
#include <atomic>
#include <vector>

struct OBJAudioProbeEntry { uint64_t hostTime; float peak; float cpu; int numSamples; };

class OBJAudioProbe : public juce::AudioProcessor
{
public:
    explicit OBJAudioProbe (tracktion::engine::DeviceManager& dm) : deviceManager (dm)
    {
        entries.resize (capacity);
    }

    void reset()                        { writeIndex.store (0); }

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
    void prepareToPlay (double, int) override                       {}
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
    // OBJ_AUDIO_PROBE_MUTE : mesurer sans rien envoyer aux haut-parleurs (bancs automatiques).
    const bool muteAfterMeasuring = getenv ("OBJ_AUDIO_PROBE_MUTE") != nullptr;
};
