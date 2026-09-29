//
//  OBJLoudness.h
//  objekat
//
//  The signal half of a loudness measurement (ITU-R BS.1770-4 / EBU R128): K-weighting, energy
//  per 100 ms sub-block, and true peak. Plain C, header only, no JUCE, no Tracktion — which is the
//  whole point of it being here and not in OBJEngineCore.mm: there is ONE implementation, called
//  by the export's tap (OBJExportTap, on the render thread) AND by tools/test_loudness.swift
//  (`swiftc -import-objc-header`), so that what the tests measure is what the app measures.
//
//  What lives elsewhere: the gating, the momentary / short-term windows, the integrated value and
//  the loudness range are ARITHMETIC ON THE SUB-BLOCKS, and they are `Export/LoudnessAnalysis.swift`.
//  This file only makes the sub-blocks. Every one carries two numbers:
//
//    • energy — the weighted mean square of the K-weighted signal over the sub-block, summed over
//      the channels (BS.1770 equation 1 without its −0.691 + 10·log10). A 400 ms block is the mean
//      of four consecutive sub-blocks (75 % overlap), a 3 s window the mean of thirty.
//    • true peak — the largest |sample| of the 4× oversampled UNWEIGHTED signal, linear, all
//      channels (BS.1770-4 Annex 2).
//
//  MEMORY. `objloud_create` is the only allocation, and it is made once (in the tap's `reset`,
//  which runs on the main thread before the render starts); `objloud_process` never allocates, never
//  locks and never calls anything that could — it runs inside the render thread's block loop.
//
//  K-WEIGHTING is computed FOR THE ACTUAL SAMPLE RATE. BS.1770 tabulates the two biquads at 48 kHz
//  only; their analogue prototypes (a high shelf at 1681.97 Hz, +4 dB; a 2nd-order high pass at
//  38.135 Hz) are recovered here and bilinear-transformed at `fs`, which reproduces the tabulated
//  48 kHz coefficients to the last digit (asserted in the test) and is what libebur128 does at
//  any other rate. Running the 48 kHz coefficients on 44.1 kHz audio would move the shelf by
//  ~0.1 LU and the high-pass corner by 10 %.
//
//  TRUE PEAK uses the 48-tap polyphase FIR of BS.1770-4 Annex 2 (4 phases × 12 taps). Annex 2 is
//  written for 48 kHz and up, and asks for a 4× oversampling; below 48 kHz the same filter simply
//  works at a lower absolute cut-off. Oversampling above ~96 kHz would need less, and the reading
//  stays an upper bound there, never an under-estimate that matters.
//
//  CHANNEL WEIGHTS. Every channel weighs 1.0 (stereo, mono, dual mono). For a 5-channel bed the
//  4th and 5th (Ls, Rs) weigh 1.41; for six channels the 4th is the LFE and is left out of the sum.
//  The render is always stereo (`canRenderInMono = false`), so this is provision, not a feature.
//

#ifndef OBJLoudness_h
#define OBJLoudness_h

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define OBJLOUD_MAX_CHANNELS   8
#define OBJLOUD_TP_TAPS        12
#define OBJLOUD_TP_PHASES      4
/// One sub-block lasts this long. 400 ms momentary blocks are 4 of them, the 3 s short-term
/// window 30 — hence a 75 % overlap of the gating blocks, exactly as BS.1770 asks.
#define OBJLOUD_SUBBLOCK_SECONDS 0.1

typedef struct {
    double b0, b1, b2, a1, a2;
} OBJLoudBiquad;

typedef struct OBJLoudness {
    double        sampleRate;
    int           channels;
    int           subblockLength;              // samples per sub-block (rounded)
    OBJLoudBiquad shelf;
    OBJLoudBiquad highpass;
    double        weight[OBJLOUD_MAX_CHANNELS];
    // Transposed direct form II states of the two biquads, per channel.
    double        shelfZ[OBJLOUD_MAX_CHANNELS][2];
    double        highZ[OBJLOUD_MAX_CHANNELS][2];
    // The four phases of the true-peak FIR, laid out once in `objloud_create`.
    double        tp[OBJLOUD_TP_PHASES][OBJLOUD_TP_TAPS];
    // The last 12 samples of each channel, newest first, for the true-peak FIR.
    double        history[OBJLOUD_MAX_CHANNELS][OBJLOUD_TP_TAPS];
    // The sub-block being filled.
    int           filled;
    double        energyAccumulator;           // Σ over samples and channels of weight · z²
    double        peakAccumulator;             // largest |oversampled sample| so far, linear
    int           emitted;                     // index of the next sub-block
    // Whole-stream true peak, kept apart from the sub-blocks for readers that want one number.
    double        truePeakMax;
} OBJLoudness;

typedef void (*OBJLoudnessEmit)(void* context, int subblockIndex, double energy, float truePeak);

// MARK: - K-weighting

/// The two biquads of the K-weighting filter, for `sampleRate`. At 48000 they are the coefficients
/// printed in BS.1770-4 (Tables 1 and 2). The high-pass is b = [1, −2, 1], normalised by the
/// same a0 as its denominator, exactly as the standard writes it.
static inline void objloud_kweighting(double sampleRate, OBJLoudBiquad* shelf, OBJLoudBiquad* highpass) {
    const double pi = 3.14159265358979323846;
    {   // Stage 1 — the head-related high shelf.
        const double f0 = 1681.974450955533;
        const double G  = 3.999843853973347;
        const double Q  = 0.7071752369554196;
        const double K  = tan(pi * f0 / sampleRate);
        const double Vh = pow(10.0, G / 20.0);
        const double Vb = pow(Vh, 0.4996667741545416);
        const double a0 = 1.0 + K / Q + K * K;
        shelf->b0 = (Vh + Vb * K / Q + K * K) / a0;
        shelf->b1 = 2.0 * (K * K - Vh) / a0;
        shelf->b2 = (Vh - Vb * K / Q + K * K) / a0;
        shelf->a1 = 2.0 * (K * K - 1.0) / a0;
        shelf->a2 = (1.0 - K / Q + K * K) / a0;
    }
    {   // Stage 2 — the RLB high-pass.
        const double f0 = 38.13547087602444;
        const double Q  = 0.5003270373238773;
        const double K  = tan(pi * f0 / sampleRate);
        const double a0 = 1.0 + K / Q + K * K;
        highpass->b0 = 1.0;
        highpass->b1 = -2.0;
        highpass->b2 = 1.0;
        highpass->a1 = 2.0 * (K * K - 1.0) / a0;
        highpass->a2 = (1.0 - K / Q + K * K) / a0;
    }
}

// MARK: - True-peak FIR (BS.1770-4 Annex 2)

/// Phases 0 and 1 as printed in the annex; 2 and 3 are their time reversals (the 48-tap prototype
/// is symmetric), which `objloud_create` lays out rather than this file storing a second copy that
/// could drift from the first.
static const double objloud_tp_phase01[2][OBJLOUD_TP_TAPS] = {
    {  0.0017089843750,  0.0109863281250, -0.0196533203125,  0.0332031250000,
      -0.0594482421875,  0.1373291015625,  0.9721679687500, -0.1022949218750,
       0.0476074218750, -0.0266113281250,  0.0148925781250,  0.0083007812500 },
    { -0.0291748046875,  0.0292968750000, -0.0517578125000,  0.0891113281250,
      -0.1665039062500,  0.4650878906250,  0.7797851562500, -0.2003173828125,
       0.1015625000000, -0.0582275390625,  0.0330810546875, -0.0189208984375 },
};

static inline double objloud_tp_coefficient(int phase, int tap) {
    return phase < 2 ? objloud_tp_phase01[phase][tap]
                     : objloud_tp_phase01[3 - phase][OBJLOUD_TP_TAPS - 1 - tap];
}

// MARK: - Life cycle

/// Allocates and zeroes a measurement. NULL for a sample rate or channel count that means nothing.
static inline OBJLoudness* objloud_create(double sampleRate, int channels) {
    if (!(sampleRate >= 8000.0) || channels < 1) return NULL;
    OBJLoudness* s = (OBJLoudness*) calloc(1, sizeof(OBJLoudness));
    if (!s) return NULL;
    if (channels > OBJLOUD_MAX_CHANNELS) channels = OBJLOUD_MAX_CHANNELS;
    s->sampleRate = sampleRate;
    s->channels   = channels;
    int len = (int) floor(sampleRate * OBJLOUD_SUBBLOCK_SECONDS + 0.5);
    s->subblockLength = len < 1 ? 1 : len;
    objloud_kweighting(sampleRate, &s->shelf, &s->highpass);
    for (int p = 0; p < OBJLOUD_TP_PHASES; ++p)
        for (int k = 0; k < OBJLOUD_TP_TAPS; ++k) s->tp[p][k] = objloud_tp_coefficient(p, k);
    for (int c = 0; c < channels; ++c) {
        double w = 1.0;
        if (channels == 5 && c >= 3) w = 1.41;
        if (channels == 6) { if (c == 3) w = 0.0; else if (c >= 4) w = 1.41; }
        s->weight[c] = w;
    }
    return s;
}

static inline void objloud_destroy(OBJLoudness* s) { free(s); }

// MARK: - Processing

/// Feeds `numSamples` frames — `channels[c]` points at channel c's samples. Each time a sub-block
/// completes, `emit` is called with its index (0, 1, 2 …), its energy and its true peak. The first
/// `numSamples` of the stream are sample 0: blocks must arrive contiguously, which a render does.
/// Nothing here allocates or locks.
static inline void objloud_process(OBJLoudness* s, const float* const* channels, int numSamples,
                                   OBJLoudnessEmit emit, void* context) {
    if (!s || !channels || numSamples <= 0) return;
    const int nch = s->channels;
    const OBJLoudBiquad sh = s->shelf, hp = s->highpass;

    for (int i = 0; i < numSamples; ++i) {
        for (int c = 0; c < nch; ++c) {
            const double x = (double) channels[c][i];

            // True peak, on the raw signal: the newest sample goes in front of the history.
            double* h = s->history[c];
            memmove(h + 1, h, (OBJLOUD_TP_TAPS - 1) * sizeof(double));
            h[0] = x;
            for (int p = 0; p < OBJLOUD_TP_PHASES; ++p) {
                double y = 0.0;
                for (int k = 0; k < OBJLOUD_TP_TAPS; ++k) y += s->tp[p][k] * h[k];
                if (y < 0.0) y = -y;
                if (y > s->peakAccumulator) s->peakAccumulator = y;
            }

            // K-weighting: shelf, then high-pass (transposed direct form II).
            double* zs = s->shelfZ[c];
            const double ys = sh.b0 * x + zs[0];
            zs[0] = sh.b1 * x - sh.a1 * ys + zs[1];
            zs[1] = sh.b2 * x - sh.a2 * ys;
            double* zh = s->highZ[c];
            const double z = hp.b0 * ys + zh[0];
            zh[0] = hp.b1 * ys - hp.a1 * z + zh[1];
            zh[1] = hp.b2 * ys - hp.a2 * z;

            s->energyAccumulator += s->weight[c] * z * z;
        }

        if (++s->filled >= s->subblockLength) {
            const double energy = s->energyAccumulator / (double) s->filled;
            const double peak = s->peakAccumulator;
            if (peak > s->truePeakMax) s->truePeakMax = peak;
            if (emit) emit(context, s->emitted, energy, (float) peak);
            ++s->emitted;
            s->filled = 0;
            s->energyAccumulator = 0.0;
            s->peakAccumulator = 0.0;
        }
    }
}

/// A weighted mean square as LUFS (BS.1770 eq. 2). −infinity for silence.
static inline double objloud_lufs(double energy) {
    return energy > 0.0 ? -0.691 + 10.0 * log10(energy) : -INFINITY;
}

#endif /* OBJLoudness_h */
