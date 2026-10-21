//
//  OBJPluginProbe.h
//  objekat
//
//  What OBJEKAT does AROUND a plugin, through the probe of engine patch 0045
//  (`te::Plugin::ObjProbe`, called by PluginNode::process just before and just after the plugin):
//
//    • the TRIMS — an input gain before the plugin and an output gain after it, in dB, the pair the
//      editor bar's coupled gesture moves (+n in / −n out) — and the COMPENSATION, a third gain after
//      the output trim, which the gain match sets and nothing else (the coupled gesture keeps it).
//      Ramped over one block at every change, so a gesture never clicks. Applied live AND in a
//      render (an export must sound like what was heard), never in bypass (the patch only calls a
//      probe while the plugin really processes — a bypass bypasses its trims with it).
//    • the MEASUREMENT for the gain match — taken only while the plugin really processes (never in
//      OBJEKAT's bypass, never while its own bypass parameter is on) — the K-weighted energy (ITU-R BS.1770, the K-weighting of
//      OBJLoudness.h, so the bar and the export's loudness speak the same unit) of what ENTERS the
//      plugin before its input trim, and of what LEAVES it AFTER its output trim and before the
//      compensation (so the match compensates what the trims did too). Only while the
//      app asked for it (the editor bar is open) and never during an offline render. Sub-blocks of
//      ~100 ms go into a ring the main thread reads without a lock.
//
//  Ownership. The engine side keeps one `OBJProbeState` per plugin KEY (the model's id), shared
//  with the probe installed on whatever instance currently carries that key: an instance rebuilt
//  (an undo that reloads, a chain recompiled) gets a new probe on the SAME state, so its trims hold.
//  A render clone gets a probe on a COPY of the gains, measuring nothing.
//
//  Audio thread: no lock, no allocation, nothing that could. The K-weighting coefficients are
//  recomputed (plain arithmetic) when the sample rate changes.
//

#pragma once

#include <atomic>
#include <memory>
#include <cmath>
#include "Shared/OBJLoudness.h"

/// The shared half: written by the main thread (gains, measurement on/off), read by the probe;
/// written by the probe (the ring), read by the main thread.
struct OBJProbeState {
    std::atomic<float> inGain  { 1.0f };      // linear
    std::atomic<float> outGain { 1.0f };      // linear
    std::atomic<float> compGain { 1.0f };     // linear, after outGain (the gain match's)
    std::atomic<bool>  measuring { false };
    /// The plugin's OWN bypass is on (its bypass parameter — a VST3's kIsBypass, an AU's BypassEffect —,
    /// read by the main thread, @see OBJEngineCore `refreshProbeBypass:`). OBJEKAT's bypass needs no flag:
    /// patch 0045 does not call the probe at all then. Either way the block is NOT measured, so the gain
    /// match's window holds only moments the plugin really processed.
    std::atomic<bool>  pluginBypassed { false };
    /// Bumped by the main thread to throw away what was accumulated (measurement switched on).
    std::atomic<uint32_t> resetGeneration { 0 };

    static constexpr int ringSize = 128;      // 12.8 s of 100 ms sub-blocks
    std::atomic<double> energyIn  [ringSize];
    std::atomic<double> energyOut [ringSize];
    /// How many sub-blocks were ever written (the next index is `written % ringSize`).
    std::atomic<uint64_t> written { 0 };

    OBJProbeState() {
        for (int i = 0; i < ringSize; ++i) { energyIn[i].store(0.0); energyOut[i].store(0.0); }
    }

    bool isNeutral() const noexcept {
        return inGain.load(std::memory_order_relaxed) == 1.0f
            && outGain.load(std::memory_order_relaxed) == 1.0f
            && compGain.load(std::memory_order_relaxed) == 1.0f;
    }
};

/// The engine's probe. One per plugin INSTANCE (the patch installs it once and keeps it as long
/// as the instance lives), holding the key's shared state.
class OBJPluginProbe final : public tracktion::engine::Plugin::ObjProbe {
public:
    /// `measures` false for a render clone: it applies the gains and never feeds the ring.
    OBJPluginProbe(std::shared_ptr<OBJProbeState> s, bool measures)
        : state(std::move(s)), canMeasure(measures) {
        // Start AT the target: an instance born mid-session (a rebuild) or a render clone must not
        // fade its trims in from unity over its first block.
        currentIn  = state->inGain.load();
        currentOut = state->outGain.load();
        currentComp = state->compGain.load();
    }

    void objBeforePlugin(juce::AudioBuffer<float>& b, double sampleRate, bool isRendering) noexcept override {
        const int n = b.getNumSamples();
        if (n <= 0) return;
        measuringThisBlock = canMeasure && !isRendering && state->measuring.load(std::memory_order_relaxed)
                          && !state->pluginBypassed.load(std::memory_order_relaxed);
        if (measuringThisBlock) {
            prepare(sampleRate, b.getNumChannels());
            accIn += weightedEnergy(b, zIn);
        }
        applyRamp(b, currentIn, state->inGain.load(std::memory_order_relaxed));
    }

    void objAfterPlugin(juce::AudioBuffer<float>& b, double, bool) noexcept override {
        const int n = b.getNumSamples();
        if (n <= 0) return;
        applyRamp(b, currentOut, state->outGain.load(std::memory_order_relaxed));
        if (measuringThisBlock) {
            accOut += weightedEnergy(b, zOut);
            filled += n;
            if (filled >= subblockLength) {
                const uint64_t w = state->written.load(std::memory_order_relaxed);
                const int slot = (int) (w % OBJProbeState::ringSize);
                state->energyIn [slot].store(accIn  / (double) filled, std::memory_order_relaxed);
                state->energyOut[slot].store(accOut / (double) filled, std::memory_order_relaxed);
                state->written.store(w + 1, std::memory_order_release);
                accIn = accOut = 0.0;
                filled = 0;
            }
        }
        applyRamp(b, currentComp, state->compGain.load(std::memory_order_relaxed));
    }

private:
    static constexpr int maxChannels = OBJLOUD_MAX_CHANNELS;

    std::shared_ptr<OBJProbeState> state;
    const bool canMeasure;
    float currentIn = 1.0f, currentOut = 1.0f, currentComp = 1.0f;

    double preparedRate = 0.0;
    int preparedChannels = 0;
    uint32_t seenGeneration = 0;
    OBJLoudBiquad shelf {}, highpass {};
    double zIn [maxChannels][4] {};
    double zOut[maxChannels][4] {};
    double accIn = 0.0, accOut = 0.0;
    int filled = 0, subblockLength = 4800;
    bool measuringThisBlock = false;

    void prepare(double sampleRate, int channels) noexcept {
        const uint32_t g = state->resetGeneration.load(std::memory_order_relaxed);
        if (sampleRate != preparedRate || channels != preparedChannels || g != seenGeneration) {
            if (sampleRate != preparedRate && sampleRate >= 8000.0)
                objloud_kweighting(sampleRate, &shelf, &highpass);
            preparedRate = sampleRate;
            preparedChannels = channels;
            seenGeneration = g;
            subblockLength = std::max(1, (int) std::floor(sampleRate * OBJLOUD_SUBBLOCK_SECONDS + 0.5));
            for (auto& z : zIn)  for (auto& v : z) v = 0.0;
            for (auto& z : zOut) for (auto& v : z) v = 0.0;
            accIn = accOut = 0.0;
            filled = 0;
        }
    }

    /// Σ over samples and channels of z², z the K-weighted signal (every channel weighs 1: the
    /// chains are mono or stereo).
    double weightedEnergy(const juce::AudioBuffer<float>& b, double (&z)[maxChannels][4]) const noexcept {
        if (preparedRate < 8000.0) return 0.0;
        const int nch = std::min(b.getNumChannels(), maxChannels);
        const int n = b.getNumSamples();
        double sum = 0.0;
        for (int c = 0; c < nch; ++c) {
            const float* x = b.getReadPointer(c);
            double s0 = z[c][0], s1 = z[c][1], h0 = z[c][2], h1 = z[c][3];
            for (int i = 0; i < n; ++i) {
                const double v = (double) x[i];
                const double ys = shelf.b0 * v + s0;
                s0 = shelf.b1 * v - shelf.a1 * ys + s1;
                s1 = shelf.b2 * v - shelf.a2 * ys;
                const double y = highpass.b0 * ys + h0;
                h0 = highpass.b1 * ys - highpass.a1 * y + h1;
                h1 = highpass.b2 * ys - highpass.a2 * y;
                sum += y * y;
            }
            z[c][0] = s0; z[c][1] = s1; z[c][2] = h0; z[c][3] = h1;
        }
        return sum;
    }

    static void applyRamp(juce::AudioBuffer<float>& b, float& current, float target) noexcept {
        if (current == target) {
            if (target != 1.0f) b.applyGain(target);
            return;
        }
        b.applyGainRamp(0, b.getNumSamples(), current, target);
        current = target;
    }
};
