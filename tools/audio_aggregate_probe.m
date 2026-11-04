// audio_aggregate_probe.m — the CoreAudio side of the aggregate probe and of the audio state guard.
//
//   clang -fobjc-arc -O2 -framework Foundation -framework CoreAudio tools/audio_aggregate_probe.m -o probe
//
// Two jobs, one binary (built on demand by tools/audio_state_guard.py):
//
//   * `state` / `set-rate` / `set-buffer` / `set-default`: read and write what the guard keeps
//     (every card's nominal rate and buffer size, the three system defaults). Property queries only:
//     no device is opened, so no microphone prompt and no Bluetooth profile switch.
//   * `run`: build a PRIVATE aggregate (kAudioAggregateDeviceIsPrivateKey) out of named sub-devices,
//     drive it for a while next to plain IOProcs on the same cards, and print one JSON document:
//     the layout the system gave it (which stream first, how many channels), the rates before and
//     after, the channel order proved with tones, the latency by loop, the continuity of a sine
//     (discontinuities, overload notifications, ActualSampleRate), and what happens when the
//     aggregate is destroyed while it serves as the input.
//
// The aggregate is the one the engine will build (plan "audio input on another card"): a private
// aggregate by UID, the OUTPUT sub-device is the master clock, the INPUT sub-device is drift
// compensated. NEVER the JUCE combiner.
//
// Nothing here makes a sound the user can hear unless the caller asks `--aout tones|sine` on an
// audible card: the probe driver (tools/probe_aggregate_real_cards.py) only does that on virtual
// cards (BlackHole, Muse), and sends silence to the speakers.

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <math.h>
#include <unistd.h>

// ───────────────────────────────── CoreAudio helpers ─────────────────────────────────

static AudioObjectPropertyAddress addr(AudioObjectPropertySelector sel, AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain };
    return a;
}

static NSArray<NSNumber *> *allDevices(void)
{
    AudioObjectPropertyAddress a = addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz) != noErr || sz == 0) return @[];
    AudioObjectID *ids = malloc(sz);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids) != noErr) { free(ids); return @[]; }
    NSMutableArray *r = [NSMutableArray array];
    for (UInt32 i = 0; i < sz / sizeof(AudioObjectID); i++) [r addObject:@(ids[i])];
    free(ids);
    return r;
}

static NSString *cfStr(AudioObjectID o, AudioObjectPropertySelector s)
{
    CFStringRef r = NULL;
    UInt32 sz = sizeof(r);
    AudioObjectPropertyAddress a = addr(s, kAudioObjectPropertyScopeGlobal);
    if (AudioObjectGetPropertyData(o, &a, 0, NULL, &sz, &r) != noErr || !r) return nil;
    return CFBridgingRelease(r);
}

static NSString *devUID(AudioObjectID d)  { return cfStr(d, kAudioDevicePropertyDeviceUID); }
static NSString *devName(AudioObjectID d) { return cfStr(d, kAudioObjectPropertyName); }

static AudioObjectID deviceByUID(NSString *uid)
{
    AudioObjectPropertyAddress a = addr(kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal);
    CFStringRef q = (__bridge CFStringRef) uid;
    AudioObjectID out = kAudioObjectUnknown;
    UInt32 sz = sizeof(out);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(q), &q, &sz, &out) != noErr) return kAudioObjectUnknown;
    return out;
}

/// Channels per stream on one side, in stream order (the order of the AudioBufferList).
static NSArray<NSNumber *> *streamChannels(AudioObjectID d, AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyStreamConfiguration, scope);
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(d, &a, 0, NULL, &sz) != noErr || sz < sizeof(UInt32)) return @[];
    AudioBufferList *l = malloc(sz);
    NSMutableArray *r = [NSMutableArray array];
    if (AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, l) == noErr)
        for (UInt32 i = 0; i < l->mNumberBuffers; i++) [r addObject:@(l->mBuffers[i].mNumberChannels)];
    free(l);
    return r;
}

static int channelCount(AudioObjectID d, AudioObjectPropertyScope scope)
{
    int n = 0;
    for (NSNumber *c in streamChannels(d, scope)) n += c.intValue;
    return n;
}

static Float64 nominalRate(AudioObjectID d)
{
    Float64 r = 0; UInt32 sz = sizeof(r);
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
    if (AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &r) != noErr) return 0;
    return r;
}

static Float64 actualRate(AudioObjectID d)
{
    Float64 r = 0; UInt32 sz = sizeof(r);
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyActualSampleRate, kAudioObjectPropertyScopeGlobal);
    if (AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &r) != noErr) return 0;
    return r;
}

static BOOL setNominalRate(AudioObjectID d, Float64 r)
{
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
    return AudioObjectSetPropertyData(d, &a, 0, NULL, sizeof(r), &r) == noErr;
}

static UInt32 bufferFrames(AudioObjectID d)
{
    UInt32 r = 0, sz = sizeof(r);
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal);
    if (AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &r) != noErr) return 0;
    return r;
}

static BOOL setBufferFrames(AudioObjectID d, UInt32 n)
{
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal);
    return AudioObjectSetPropertyData(d, &a, 0, NULL, sizeof(n), &n) == noErr;
}

static UInt32 u32Prop(AudioObjectID d, AudioObjectPropertySelector s, AudioObjectPropertyScope scope)
{
    UInt32 r = 0, sz = sizeof(r);
    AudioObjectPropertyAddress a = addr(s, scope);
    if (AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &r) != noErr) return 0;
    return r;
}

static NSString *fourcc(UInt32 v)
{
    char c[5] = { (char)(v >> 24), (char)(v >> 16), (char)(v >> 8), (char) v, 0 };
    return [NSString stringWithUTF8String:c];
}

static NSString *transportName(AudioObjectID d)
{
    return fourcc(u32Prop(d, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal));
}

static NSArray<NSNumber *> *availableRates(AudioObjectID d)
{
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal);
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(d, &a, 0, NULL, &sz) != noErr || sz == 0) return @[];
    AudioValueRange *v = malloc(sz);
    NSMutableArray *r = [NSMutableArray array];
    if (AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, v) == noErr)
        for (UInt32 i = 0; i < sz / sizeof(AudioValueRange); i++) {
            if (v[i].mMinimum == v[i].mMaximum) [r addObject:@(v[i].mMinimum)];
            else { [r addObject:@(v[i].mMinimum)]; [r addObject:@(v[i].mMaximum)]; }
        }
    free(v);
    return r;
}

static AudioObjectID defaultDevice(AudioObjectPropertySelector s)
{
    AudioObjectID r = kAudioObjectUnknown; UInt32 sz = sizeof(r);
    AudioObjectPropertyAddress a = addr(s, kAudioObjectPropertyScopeGlobal);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, &r) != noErr) return kAudioObjectUnknown;
    return r;
}

static void emit(id obj)
{
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj
                                                options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                  error:nil];
    fwrite(d.bytes, 1, d.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static NSDictionary *describeDevice(AudioObjectID d)
{
    // Latencies as CoreAudio reports them: what a callback's data is late by, per side.
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    m[@"uid"] = devUID(d) ?: @"";
    m[@"name"] = devName(d) ?: @"";
    m[@"transport"] = transportName(d);
    m[@"in_channels"] = @(channelCount(d, kAudioObjectPropertyScopeInput));
    m[@"out_channels"] = @(channelCount(d, kAudioObjectPropertyScopeOutput));
    m[@"in_streams"] = streamChannels(d, kAudioObjectPropertyScopeInput);
    m[@"out_streams"] = streamChannels(d, kAudioObjectPropertyScopeOutput);
    m[@"rate"] = @(nominalRate(d));
    m[@"buffer"] = @(bufferFrames(d));
    m[@"rates"] = availableRates(d);
    m[@"in_latency"] = @(u32Prop(d, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput));
    m[@"out_latency"] = @(u32Prop(d, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput));
    m[@"in_safety"] = @(u32Prop(d, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput));
    m[@"out_safety"] = @(u32Prop(d, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput));
    return m;
}

static NSDictionary *fullState(void)
{
    NSMutableArray *devs = [NSMutableArray array];
    for (NSNumber *n in allDevices()) [devs addObject:describeDevice(n.unsignedIntValue)];
    NSMutableDictionary *def = [NSMutableDictionary dictionary];
    def[@"input"]  = devUID(defaultDevice(kAudioHardwarePropertyDefaultInputDevice)) ?: @"";
    def[@"output"] = devUID(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)) ?: @"";
    def[@"system"] = devUID(defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)) ?: @"";
    return @{ @"devices": devs, @"defaults": def };
}

// ───────────────────────────────── the run ─────────────────────────────────

#define MAXCH 64
#define MAXIMP 4096

typedef struct {
    // static configuration
    int    aggIn, aggOut;          // channels of the aggregate
    int    wCh;                    // channels of the plain writer device (output side)
    int    rCh;                    // channels of the plain reader device (input side)
    int    wmode;                  // 0 none, 1 tones, 2 sine ch0, 3 impulse ch0
    int    aoutMode;               // 0 silence, 1 tones on every channel, 2 sine on aoutCh
    int    aoutCh;
    int    watch;                  // aggregate input channel watched for continuity (-1 none)
    double sineHz;                 // 1000

    // live
    _Atomic(double) wRate;         // rate the writer must use now
    _Atomic(double) aggRate;       // rate of the aggregate's callbacks (nominal)
    _Atomic(int)    stop;
    _Atomic(unsigned long long) aggCalls, wCalls, rCalls;
    _Atomic(unsigned long long) aggInDisc, aggOutDisc, wDisc;
    _Atomic(unsigned long long) glitches;
    _Atomic(unsigned long long) frames;     // frames seen on the watched input
    _Atomic(unsigned long long) minFrames, maxFrames;

    // writer state (audio thread of the writer)
    double wPhase[MAXCH];
    double wLastSample; int wHave;
    unsigned long long wSampleCount;
    unsigned long long nextImpulse;
    // aggregate output state
    double aPhase[MAXCH];

    // captured aggregate input (for tone analysis), planar
    float *capIn;  unsigned long long capInFrames, capInFill;
    float *capR;   unsigned long long capRFrames, capRFill;

    // continuity detector on the watched channel
    double x1, x2, c; int detInit; unsigned long long detN;
    double lastGlitchT[32]; int nGlitch;
    double maxResidual;
    double watchPeak;
    double aggInLast; int aggInHave; double aggInPrevFrames;
    double aggOutLast; int aggOutHave; double aggOutPrevFrames;
    double wLast; int wHaveT; double wPrevFrames;

    // latency by loop
    uint64_t impHost[MAXIMP]; _Atomic(int) nImp;
    double   latMs[MAXIMP];   int nLat;
    int      impArmed;        // detection arming: re-armed after each match
    double   hostTickNs;      // ns per host tick
    uint64_t t0Host;
} Ctx;

static Ctx C;

static inline double hostNs(uint64_t t) { return (double) t * C.hostTickNs; }

/// Writes `v` to global channel `ch` of a list of buffers (interleaved inside each buffer).
static inline void putSample(AudioBufferList *l, int ch, UInt32 frame, float v)
{
    int base = 0;
    for (UInt32 b = 0; b < l->mNumberBuffers; b++) {
        int n = (int) l->mBuffers[b].mNumberChannels;
        if (ch < base + n) {
            float *p = (float *) l->mBuffers[b].mData;
            UInt32 frames = l->mBuffers[b].mDataByteSize / (sizeof(float) * (UInt32) n);
            if (frame < frames) p[(size_t) frame * (size_t) n + (size_t)(ch - base)] = v;
            return;
        }
        base += n;
    }
}

static inline UInt32 listFrames(const AudioBufferList *l)
{
    if (!l || l->mNumberBuffers == 0) return 0;
    UInt32 n = l->mBuffers[0].mNumberChannels ?: 1;
    return l->mBuffers[0].mDataByteSize / (sizeof(float) * n);
}

static inline int listChannels(const AudioBufferList *l)
{
    int n = 0;
    if (l) for (UInt32 b = 0; b < l->mNumberBuffers; b++) n += (int) l->mBuffers[b].mNumberChannels;
    return n;
}

static void zeroList(AudioBufferList *l)
{
    if (!l) return;
    for (UInt32 b = 0; b < l->mNumberBuffers; b++)
        if (l->mBuffers[b].mData) memset(l->mBuffers[b].mData, 0, l->mBuffers[b].mDataByteSize);
}

static inline double toneHz(int i) { return 250.0 + 90.0 * i; }

// The aggregate's callback: captures the input, checks the clocks, feeds the glitch detector, writes
// the output (silence, tones or a sine).
static OSStatus aggIO(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in,
                      const AudioTimeStamp *inT, AudioBufferList *out, const AudioTimeStamp *outT, void *client)
{
    if (atomic_load(&C.stop)) { zeroList(out); return noErr; }
    atomic_fetch_add(&C.aggCalls, 1);
    const double fs = atomic_load(&C.aggRate);

    const UInt32 nin = listFrames(in);
    if (in && inT && nin > 0) {
        if (C.aggInHave && fabs((inT->mSampleTime - C.aggInLast) - C.aggInPrevFrames) > 0.5) atomic_fetch_add(&C.aggInDisc, 1);
        C.aggInLast = inT->mSampleTime; C.aggInPrevFrames = nin; C.aggInHave = 1;
        unsigned long long mn = atomic_load(&C.minFrames), mx = atomic_load(&C.maxFrames);
        if (mn == 0 || nin < mn) atomic_store(&C.minFrames, nin);
        if (nin > mx) atomic_store(&C.maxFrames, nin);

        // capture all input channels (planar), until full
        if (C.capIn && C.capInFill < C.capInFrames) {
            const int nch = listChannels(in);
            UInt32 take = (UInt32) fmin((double) nin, (double)(C.capInFrames - C.capInFill));
            int base = 0;
            for (UInt32 b = 0; b < in->mNumberBuffers; b++) {
                int n = (int) in->mBuffers[b].mNumberChannels;
                const float *p = (const float *) in->mBuffers[b].mData;
                for (int c = 0; c < n && base + c < nch && base + c < C.aggIn; c++)
                    for (UInt32 f = 0; f < take; f++)
                        C.capIn[(size_t)(base + c) * C.capInFrames + C.capInFill + f] = p[(size_t) f * (size_t) n + (size_t) c];
                base += n;
            }
            C.capInFill += take;
        }

        // sine continuity on the watched channel
        if (C.watch >= 0 && C.watch < listChannels(in)) {
            int base = 0;
            for (UInt32 b = 0; b < in->mNumberBuffers; b++) {
                int n = (int) in->mBuffers[b].mNumberChannels;
                if (C.watch < base + n) {
                    const float *p = (const float *) in->mBuffers[b].mData;
                    const int off = C.watch - base;
                    for (UInt32 f = 0; f < nin; f++) {
                        const double x = p[(size_t) f * (size_t) n + (size_t) off];
                        if (fabs(x) > C.watchPeak) C.watchPeak = fabs(x);
                        if (!C.detInit) { C.x2 = C.x1 = x; C.c = 2.0 * cos(2.0 * M_PI * C.sineHz / fs); C.detInit = 1; C.detN = 0; }
                        else {
                            const double pred = C.c * C.x1 - C.x2;
                            const double r = x - pred;
                            C.detN++;
                            const double warm = fs * 1.5;              // let the resampler and the start settle
                            if (C.detN > warm) {
                                const double ar = fabs(r);
                                if (ar > C.maxResidual) C.maxResidual = ar;
                                if (ar > 0.03) {
                                    atomic_fetch_add(&C.glitches, 1);
                                    int k = C.nGlitch;
                                    if (k < 32) { C.lastGlitchT[k] = hostNs(inT->mHostTime - C.t0Host) / 1e9; C.nGlitch++; }
                                }
                            } else {
                                // adapt the recurrence coefficient while settling (normalised LMS)
                                const double den = C.x1 * C.x1 + 1e-9;
                                C.c += 0.05 * r * C.x1 / den;
                            }
                            C.x2 = C.x1; C.x1 = x;
                        }
                    }
                    break;
                }
                base += n;
            }
            atomic_fetch_add(&C.frames, nin);

            // impulse detection (latency by loop): first sample above 0.5 after a quiet stretch
            if (atomic_load(&C.nImp) > 0) {
                int nimp = atomic_load(&C.nImp);
                base = 0;
                for (UInt32 b = 0; b < in->mNumberBuffers; b++) {
                    int n = (int) in->mBuffers[b].mNumberChannels;
                    if (C.watch < base + n) {
                        const float *p = (const float *) in->mBuffers[b].mData;
                        const int off = C.watch - base;
                        for (UInt32 f = 0; f < nin; f++) {
                            if (fabsf(p[(size_t) f * (size_t) n + (size_t) off]) > 0.5f && C.nLat < MAXIMP) {
                                const double tIn = hostNs(inT->mHostTime) + (double) f / fs * 1e9;
                                // the last impulse written before tIn
                                double best = -1;
                                for (int i = nimp - 1; i >= 0; i--) {
                                    const double tw = hostNs(C.impHost[i]);
                                    if (tw <= tIn + 2e6) { best = tIn - tw; break; }
                                }
                                if (best >= 0 && best < 400e6) C.latMs[C.nLat++] = best / 1e6;
                                f += (UInt32)(fs * 0.1);                   // skip the rest of this impulse
                            }
                        }
                        break;
                    }
                    base += n;
                }
            }
        }
    }

    // output side
    if (out) {
        zeroList(out);
        const UInt32 nout = listFrames(out);
        if (outT && nout > 0) {
            if (C.aggOutHave && fabs((outT->mSampleTime - C.aggOutLast) - C.aggOutPrevFrames) > 0.5) atomic_fetch_add(&C.aggOutDisc, 1);
            C.aggOutLast = outT->mSampleTime; C.aggOutPrevFrames = nout; C.aggOutHave = 1;
        }
        const int nch = listChannels(out);
        if (C.aoutMode == 1) {
            for (int ch = 0; ch < nch && ch < MAXCH; ch++) {
                const double step = 2.0 * M_PI * toneHz(ch) / fs;
                for (UInt32 f = 0; f < nout; f++) { putSample(out, ch, f, (float)(0.2 * sin(C.aPhase[ch]))); C.aPhase[ch] += step; if (C.aPhase[ch] > 2*M_PI) C.aPhase[ch] -= 2*M_PI; }
            }
        } else if (C.aoutMode == 2 && C.aoutCh < nch) {
            const double step = 2.0 * M_PI * C.sineHz / fs;
            for (UInt32 f = 0; f < nout; f++) { putSample(out, C.aoutCh, f, (float)(0.5 * sin(C.aPhase[0]))); C.aPhase[0] += step; if (C.aPhase[0] > 2*M_PI) C.aPhase[0] -= 2*M_PI; }
        }
    }
    return noErr;
}

// The plain writer: a device we drive directly, into which the test signal is played.
static OSStatus writerIO(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in,
                         const AudioTimeStamp *inT, AudioBufferList *out, const AudioTimeStamp *outT, void *client)
{
    if (!out) return noErr;
    zeroList(out);
    if (atomic_load(&C.stop)) return noErr;
    atomic_fetch_add(&C.wCalls, 1);
    const UInt32 nout = listFrames(out);
    const double fs = atomic_load(&C.wRate);
    if (outT && nout > 0) {
        if (C.wHaveT && fabs((outT->mSampleTime - C.wLast) - C.wPrevFrames) > 0.5) atomic_fetch_add(&C.wDisc, 1);
        C.wLast = outT->mSampleTime; C.wPrevFrames = nout; C.wHaveT = 1;
    }
    const int nch = listChannels(out);
    if (C.wmode == 1) {
        for (int ch = 0; ch < nch && ch < MAXCH; ch++) {
            const double step = 2.0 * M_PI * toneHz(ch) / fs;
            for (UInt32 f = 0; f < nout; f++) { putSample(out, ch, f, (float)(0.2 * sin(C.wPhase[ch]))); C.wPhase[ch] += step; if (C.wPhase[ch] > 2*M_PI) C.wPhase[ch] -= 2*M_PI; }
        }
    } else if (C.wmode == 2) {
        const double step = 2.0 * M_PI * C.sineHz / fs;
        for (UInt32 f = 0; f < nout; f++) { putSample(out, 0, f, (float)(0.5 * sin(C.wPhase[0]))); C.wPhase[0] += step; if (C.wPhase[0] > 2*M_PI) C.wPhase[0] -= 2*M_PI; }
    } else if (C.wmode == 3) {
        const unsigned long long period = (unsigned long long)(fs * 0.5);
        for (UInt32 f = 0; f < nout; f++) {
            if (C.wSampleCount + f == C.nextImpulse) {
                putSample(out, 0, f, 0.9f);
                int k = atomic_load(&C.nImp);
                if (k < MAXIMP && outT) {
                    C.impHost[k] = outT->mHostTime + (uint64_t)((double) f / fs * 1e9 / C.hostTickNs);
                    atomic_store(&C.nImp, k + 1);
                }
                C.nextImpulse += period;
            }
        }
    }
    C.wSampleCount += nout;
    return noErr;
}

// The plain reader: records the inputs of a device (the loop of the aggregate's tones).
static OSStatus readerIO(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in,
                         const AudioTimeStamp *inT, AudioBufferList *out, const AudioTimeStamp *outT, void *client)
{
    if (out) zeroList(out);
    if (atomic_load(&C.stop) || !in || !C.capR) return noErr;
    atomic_fetch_add(&C.rCalls, 1);
    const UInt32 n = listFrames(in);
    if (C.capRFill >= C.capRFrames) return noErr;
    UInt32 take = (UInt32) fmin((double) n, (double)(C.capRFrames - C.capRFill));
    int base = 0;
    for (UInt32 b = 0; b < in->mNumberBuffers; b++) {
        int nc = (int) in->mBuffers[b].mNumberChannels;
        const float *p = (const float *) in->mBuffers[b].mData;
        for (int c = 0; c < nc && base + c < C.rCh; c++)
            for (UInt32 f = 0; f < take; f++)
                C.capR[(size_t)(base + c) * C.capRFrames + C.capRFill + f] = p[(size_t) f * (size_t) nc + (size_t) c];
        base += nc;
    }
    C.capRFill += take;
    return noErr;
}

/// Power of `x[0..n)` at `hz` (Goertzel), normalised by the window so a unit sine gives ~0.25.
static double goertzel(const float *x, unsigned long long n, double hz, double fs)
{
    const double w = 2.0 * M_PI * hz / fs, cw = 2.0 * cos(w);
    double s0 = 0, s1 = 0, s2 = 0;
    for (unsigned long long i = 0; i < n; i++) { s0 = x[i] + cw * s1 - s2; s2 = s1; s1 = s0; }
    const double p = s1 * s1 + s2 * s2 - cw * s1 * s2;
    return p / ((double) n * (double) n);
}

static NSDictionary *tonesMapping(const float *cap, unsigned long long fill, unsigned long long stride, int nChan,
                                  int nTones, double fs, int toneBase)
{
    // For each captured channel: which tone dominates, and by how much over the runner-up.
    NSMutableArray *rows = [NSMutableArray array];
    unsigned long long n = fill > (unsigned long long)(fs * 0.5) ? fill - (unsigned long long)(fs * 0.5) : 0;   // skip the first half second
    if (n < (unsigned long long)(fs * 0.5)) return @{ @"error": @"not enough audio captured", @"rows": @[] };
    for (int ch = 0; ch < nChan; ch++) {
        const float *x = cap + (size_t) ch * stride + (fill - n);
        double best = 0, second = 0; int bi = -1;
        for (int t = 0; t < nTones; t++) {
            double p = goertzel(x, n, toneHz(toneBase + t), fs);
            if (p > best) { second = best; best = p; bi = t; } else if (p > second) second = p;
        }
        double db = (best > 0 && second > 0) ? 10.0 * log10(best / second) : (best > 1e-9 ? 99.0 : 0.0);
        [rows addObject:@{ @"channel": @(ch), @"tone": @(best > 1e-6 ? bi : -1), @"over_runner_up_db": @(db),
                           @"level_db": @(best > 0 ? 10.0 * log10(best) : -200.0) }];
    }
    return @{ @"rows": rows };
}

static int cmpd(const void *a, const void *b) { double x = *(double *) a, y = *(double *) b; return x < y ? -1 : x > y; }

static NSString *argValue(NSArray<NSString *> *args, NSString *key)
{
    NSUInteger i = [args indexOfObject:key];
    return (i != NSNotFound && i + 1 < args.count) ? args[i + 1] : nil;
}
static NSArray<NSString *> *argValues(NSArray<NSString *> *args, NSString *key)
{
    NSMutableArray *r = [NSMutableArray array];
    for (NSUInteger i = 0; i + 1 < args.count; i++) if ([args[i] isEqualToString:key]) [r addObject:args[i + 1]];
    return r;
}

static NSDictionary *rateSnapshot(NSArray<NSString *> *uids)
{
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (NSString *u in uids) {
        AudioObjectID d = deviceByUID(u);
        if (d != kAudioObjectUnknown) m[u] = @(nominalRate(d));
    }
    return m;
}

/// Puts back the nominal rates a probe run found (the aggregate or a `--rate` preset may have moved them).
static void restoreRates(NSDictionary *before, NSArray<NSString *> *uids)
{
    for (NSString *u in uids) {
        AudioObjectID d = deviceByUID(u);
        double want = [before[u] doubleValue];
        if (d != kAudioObjectUnknown && want > 0 && fabs(nominalRate(d) - want) > 0.5) { setNominalRate(d, want); usleep(300 * 1000); }
    }
}

static int runCommand(NSArray<NSString *> *args)
{
    memset(&C, 0, sizeof(C));
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    C.hostTickNs = (double) tb.numer / (double) tb.denom;
    C.sineHz = 1000.0;

    NSArray *subs = argValues(args, @"--sub");           // ordered
    NSString *master = argValue(args, @"--master") ?: subs.firstObject;
    NSArray *drift = argValues(args, @"--drift");
    NSString *writer = argValue(args, @"--writer");
    NSString *reader = argValue(args, @"--reader");
    NSString *wmode = argValue(args, @"--wmode") ?: @"none";
    NSString *aout = argValue(args, @"--aout") ?: @"silence";
    double secs = [argValue(args, @"--secs") doubleValue] ?: 3.0;
    BOOL destroyLive = [args containsObject:@"--destroy-live"];
    BOOL noIO = [args containsObject:@"--no-io"];
    int watchArg = argValue(args, @"--watch") ? [argValue(args, @"--watch") intValue] : -2;
    int aoutCh = [argValue(args, @"--aoutch") intValue];
    NSString *label = argValue(args, @"--label") ?: @"run";

    NSMutableDictionary *res = [NSMutableDictionary dictionary];
    res[@"label"] = label;
    res[@"sub"] = subs; res[@"master"] = master ?: @""; res[@"drift"] = drift;

    // 0. what exists
    NSMutableArray *allUIDs = [NSMutableArray arrayWithArray:subs];
    if (writer && ![allUIDs containsObject:writer]) [allUIDs addObject:writer];
    if (reader && ![allUIDs containsObject:reader]) [allUIDs addObject:reader];
    for (NSString *u in allUIDs) if (deviceByUID(u) == kAudioObjectUnknown) { res[@"error"] = [@"no such device: " stringByAppendingString:u]; emit(res); return 3; }
    res[@"rates_before"] = rateSnapshot(allUIDs);

    // optional pre-set rates: --rate UID=RATE
    for (NSString *kv in argValues(args, @"--rate")) {
        NSArray *p = [kv componentsSeparatedByString:@"="];
        if (p.count == 2) { AudioObjectID d = deviceByUID(p[0]); if (d != kAudioObjectUnknown) setNominalRate(d, [p[1] doubleValue]); }
    }
    usleep(300 * 1000);
    res[@"rates_preset"] = rateSnapshot(allUIDs);

    // 1. the aggregate
    NSMutableArray *subDicts = [NSMutableArray array];
    for (NSString *u in subs)
        [subDicts addObject:@{ @kAudioSubDeviceUIDKey: u, @kAudioSubDeviceDriftCompensationKey: @([drift containsObject:u] ? 1 : 0) }];
    NSString *aggUID = [NSString stringWithFormat:@"org.labelpeche.objekat.probe.%d", getpid()];
    NSDictionary *desc = @{ @kAudioAggregateDeviceNameKey: @"OBJEKAT probe aggregate",
                            @kAudioAggregateDeviceUIDKey: aggUID,
                            @kAudioAggregateDeviceSubDeviceListKey: subDicts,
                            @kAudioAggregateDeviceMasterSubDeviceKey: master ?: subs.firstObject,
                            @kAudioAggregateDeviceIsPrivateKey: @1,
                            @kAudioAggregateDeviceIsStackedKey: @0 };
    AudioObjectID agg = kAudioObjectUnknown;
    uint64_t tCreate = mach_absolute_time();
    OSStatus st = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef) desc, &agg);
    res[@"create_status"] = @(st);
    if (st != noErr || agg == kAudioObjectUnknown) { res[@"error"] = @"AudioHardwareCreateAggregateDevice failed"; emit(res); return 4; }

    // wait until the aggregate is populated
    int expectIn = 0, expectOut = 0;
    for (NSString *u in subs) { AudioObjectID d = deviceByUID(u); expectIn += channelCount(d, kAudioObjectPropertyScopeInput); expectOut += channelCount(d, kAudioObjectPropertyScopeOutput); }
    int waited = 0;
    while (waited < 6000 && (channelCount(agg, kAudioObjectPropertyScopeInput) != expectIn || channelCount(agg, kAudioObjectPropertyScopeOutput) != expectOut)) { usleep(50 * 1000); waited += 50; }
    res[@"ready_ms"] = @(waited);
    res[@"create_ms"] = @((double)(mach_absolute_time() - tCreate) * C.hostTickNs / 1e6);

    NSMutableDictionary *lay = [NSMutableDictionary dictionary];
    lay[@"aggregate"] = describeDevice(agg);
    lay[@"expected_in"] = @(expectIn); lay[@"expected_out"] = @(expectOut);
    {   // the order the system gave the sub-devices
        AudioObjectPropertyAddress a = addr(kAudioAggregateDevicePropertyFullSubDeviceList, kAudioObjectPropertyScopeGlobal);
        CFArrayRef l = NULL; UInt32 sz = sizeof(l);
        if (AudioObjectGetPropertyData(agg, &a, 0, NULL, &sz, &l) == noErr && l) lay[@"full_sub_device_list"] = CFBridgingRelease(l);
        CFStringRef m = NULL; sz = sizeof(m);
        AudioObjectPropertyAddress am = addr(kAudioAggregateDevicePropertyMainSubDevice, kAudioObjectPropertyScopeGlobal);
        if (AudioObjectGetPropertyData(agg, &am, 0, NULL, &sz, &m) == noErr && m) lay[@"main_sub_device"] = CFBridgingRelease(m);
    }
    {   // visible in this process's list?
        BOOL seen = NO;
        for (NSNumber *n in allDevices()) if ([devUID(n.unsignedIntValue) isEqualToString:aggUID]) seen = YES;
        lay[@"listed_in_own_process"] = @(seen);
    }
    // offsets by list order (what the engine will compute)
    {
        int k = 0, ko = 0; NSMutableDictionary *offs = [NSMutableDictionary dictionary];
        for (NSString *u in subs) {
            AudioObjectID d = deviceByUID(u);
            int ci = channelCount(d, kAudioObjectPropertyScopeInput), co = channelCount(d, kAudioObjectPropertyScopeOutput);
            offs[u] = @{ @"in_first": @(k), @"in_count": @(ci), @"out_first": @(ko), @"out_count": @(co) };
            k += ci; ko += co;
        }
        lay[@"offsets_by_list_order"] = offs;
    }
    res[@"layout"] = lay;
    res[@"rates_after_create"] = rateSnapshot(allUIDs);

    C.aggIn = channelCount(agg, kAudioObjectPropertyScopeInput);
    C.aggOut = channelCount(agg, kAudioObjectPropertyScopeOutput);
    atomic_store(&C.aggRate, nominalRate(agg));

    if (noIO) {
        res[@"rates_after_wait"] = rateSnapshot(allUIDs);
        AudioHardwareDestroyAggregateDevice(agg);
        usleep(300 * 1000);
        res[@"rates_after_destroy"] = rateSnapshot(allUIDs);
        restoreRates(res[@"rates_before"], allUIDs);
        emit(res);
        return 0;
    }

    // 2. plain devices, signals, buffers
    AudioObjectID wdev = writer ? deviceByUID(writer) : kAudioObjectUnknown;
    AudioObjectID rdev = reader ? deviceByUID(reader) : kAudioObjectUnknown;
    C.wCh = wdev ? channelCount(wdev, kAudioObjectPropertyScopeOutput) : 0;
    C.rCh = rdev ? channelCount(rdev, kAudioObjectPropertyScopeInput) : 0;
    C.wmode = [wmode isEqualToString:@"tones"] ? 1 : [wmode isEqualToString:@"sine"] ? 2 : [wmode isEqualToString:@"impulse"] ? 3 : 0;
    C.aoutMode = [aout isEqualToString:@"tones"] ? 1 : [aout isEqualToString:@"sine"] ? 2 : 0;
    C.aoutCh = aoutCh;
    atomic_store(&C.wRate, wdev ? nominalRate(wdev) : 48000.0);
    // the aggregate input channel the writer's channel 0 lands on, by list order
    int wFirst = -1;
    if (writer) { int k = 0; for (NSString *u in subs) { if ([u isEqualToString:writer]) { wFirst = k; break; } k += channelCount(deviceByUID(u), kAudioObjectPropertyScopeInput); } }
    C.watch = (watchArg == -2) ? wFirst : watchArg;
    if (C.wmode == 0) C.watch = (watchArg == -2) ? -1 : watchArg;
    C.nextImpulse = (unsigned long long)(atomic_load(&C.wRate) * 0.7);

    const double capSecs = fmin(secs, 6.0) + 1.0;
    C.capInFrames = (unsigned long long)(capSecs * fmax(atomic_load(&C.aggRate), 48000.0) * 1.1);
    if (C.aggIn > 0 && (C.wmode == 1)) C.capIn = calloc((size_t) C.aggIn * C.capInFrames, sizeof(float));
    C.capRFrames = (unsigned long long)(capSecs * fmax(rdev ? nominalRate(rdev) : 48000.0, 48000.0) * 1.1);
    if (rdev && C.rCh > 0) C.capR = calloc((size_t) C.rCh * C.capRFrames, sizeof(float));
    for (int i = 0; i < MAXCH; i++) { C.wPhase[i] = 0; C.aPhase[i] = 0; }

    // listeners: overloads on every device in play, rate changes on the plain devices
    __block unsigned long long overloads = 0;
    NSMutableDictionary *overloadBy = [NSMutableDictionary dictionary];
    NSMutableArray<NSNumber *> *watched = [NSMutableArray arrayWithObject:@(agg)];
    for (NSString *u in allUIDs) [watched addObject:@(deviceByUID(u))];
    for (NSNumber *n in watched) {
        AudioObjectPropertyAddress a = addr(kAudioDeviceProcessorOverload, kAudioObjectPropertyScopeGlobal);
        AudioObjectID d = n.unsignedIntValue;
        AudioObjectAddPropertyListenerBlock(d, &a, dispatch_get_main_queue(), ^(UInt32 c, const AudioObjectPropertyAddress *as) {
            overloads++;
            NSString *k = devUID(d) ?: @"?";
            overloadBy[k] = @([overloadBy[k] intValue] + 1);
        });
    }
    __block int rateChanges = 0;
    if (wdev) {
        AudioObjectPropertyAddress a = addr(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
        AudioObjectAddPropertyListenerBlock(wdev, &a, dispatch_get_main_queue(), ^(UInt32 c, const AudioObjectPropertyAddress *as) {
            atomic_store(&C.wRate, nominalRate(wdev)); rateChanges++;
        });
    }
    {
        AudioObjectPropertyAddress a = addr(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
        AudioObjectAddPropertyListenerBlock(agg, &a, dispatch_get_main_queue(), ^(UInt32 c, const AudioObjectPropertyAddress *as) {
            atomic_store(&C.aggRate, nominalRate(agg)); rateChanges++;
        });
    }

    AudioDeviceIOProcID aggProc = NULL, wProc = NULL, rProc = NULL;
    res[@"agg_ioproc_status"] = @(AudioDeviceCreateIOProcID(agg, aggIO, NULL, &aggProc));
    if (wdev) res[@"writer_ioproc_status"] = @(AudioDeviceCreateIOProcID(wdev, writerIO, NULL, &wProc));
    if (rdev) res[@"reader_ioproc_status"] = @(AudioDeviceCreateIOProcID(rdev, readerIO, NULL, &rProc));

    C.t0Host = mach_absolute_time();
    if (wProc) res[@"writer_start_status"] = @(AudioDeviceStart(wdev, wProc));
    if (rProc) res[@"reader_start_status"] = @(AudioDeviceStart(rdev, rProc));
    OSStatus sa = AudioDeviceStart(agg, aggProc);
    res[@"agg_start_status"] = @(sa);
    atomic_store(&C.aggRate, nominalRate(agg));

    // 3. the run: sample the rates once a second
    double minActual = 1e12, maxActual = 0, minNom = 1e12, maxNom = 0;
    NSMutableDictionary *subActualMin = [NSMutableDictionary dictionary], *subActualMax = [NSMutableDictionary dictionary];
    BOOL destroyed = NO;
    unsigned long long callsAtDestroy = 0, wCallsAtDestroy = 0;
    uint64_t tStart = mach_absolute_time();
    double lastReport = 0;
    while (1) {
        const double el = (double)(mach_absolute_time() - tStart) * C.hostTickNs / 1e9;
        if (el >= secs) break;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
        if (!destroyed) {
            double ar = actualRate(agg), nr = nominalRate(agg);
            if (ar > 0) { minActual = fmin(minActual, ar); maxActual = fmax(maxActual, ar); }
            if (nr > 0) { minNom = fmin(minNom, nr); maxNom = fmax(maxNom, nr); }
            for (NSString *u in subs) {
                double v = actualRate(deviceByUID(u));
                if (v > 0) { subActualMin[u] = @(fmin(subActualMin[u] ? [subActualMin[u] doubleValue] : 1e12, v)); subActualMax[u] = @(fmax([subActualMax[u] doubleValue], v)); }
            }
        }
        if (destroyLive && !destroyed && el >= secs / 2) {
            callsAtDestroy = atomic_load(&C.aggCalls); wCallsAtDestroy = atomic_load(&C.wCalls);
            res[@"rates_before_live_destroy"] = rateSnapshot(allUIDs);
            // the aggregate is destroyed WHILE its IOProc runs: the failure path of the engine (the card
            // that served as the input disappeared, or the engine tears the aggregate down in a hurry)
            OSStatus ds = AudioHardwareDestroyAggregateDevice(agg);
            res[@"live_destroy_status"] = @(ds);
            destroyed = YES;
        }
        if (secs >= 60 && el - lastReport >= 30) {
            lastReport = el;
            fprintf(stderr, "[probe %s] %.0f s  calls=%llu  glitches=%llu  overloads=%llu  inDisc=%llu  outDisc=%llu  actual=%.2f\n",
                    label.UTF8String, el, atomic_load(&C.aggCalls), atomic_load(&C.glitches), overloads,
                    atomic_load(&C.aggInDisc), atomic_load(&C.aggOutDisc), actualRate(agg));
        }
    }
    const double elapsed = (double)(mach_absolute_time() - tStart) * C.hostTickNs / 1e9;
    res[@"rates_during_run"] = rateSnapshot(allUIDs);

    // 4. stop, tear down
    if (destroyed) {
        usleep(500 * 1000);
        res[@"live_destroy"] = @{ @"agg_calls_at_destroy": @(callsAtDestroy), @"agg_calls_after_destroy_1s": @(atomic_load(&C.aggCalls) - callsAtDestroy),
                                  @"writer_calls_still_running": @(atomic_load(&C.wCalls) - wCallsAtDestroy),
                                  @"process_alive": @YES };
    }
    atomic_store(&C.stop, 1);
    if (!destroyed) AudioDeviceStop(agg, aggProc);
    if (wProc) AudioDeviceStop(wdev, wProc);
    if (rProc) AudioDeviceStop(rdev, rProc);
    if (!destroyed) AudioDeviceDestroyIOProcID(agg, aggProc);
    if (wProc) AudioDeviceDestroyIOProcID(wdev, wProc);
    if (rProc) AudioDeviceDestroyIOProcID(rdev, rProc);
    if (!destroyed) AudioHardwareDestroyAggregateDevice(agg);
    usleep(400 * 1000);
    res[@"rates_after_destroy"] = rateSnapshot(allUIDs);
    restoreRates(res[@"rates_before"], allUIDs);

    // 5. results
    NSMutableDictionary *run = [NSMutableDictionary dictionary];
    run[@"seconds"] = @(elapsed);
    run[@"agg_callbacks"] = @(atomic_load(&C.aggCalls));
    run[@"writer_callbacks"] = @(atomic_load(&C.wCalls));
    run[@"agg_in_time_discontinuities"] = @(atomic_load(&C.aggInDisc));
    run[@"agg_out_time_discontinuities"] = @(atomic_load(&C.aggOutDisc));
    run[@"writer_time_discontinuities"] = @(atomic_load(&C.wDisc));
    run[@"overload_notifications"] = @(overloads);
    run[@"overload_by_device"] = overloadBy;
    run[@"rate_change_notifications"] = @(rateChanges);
    run[@"agg_actual_rate_min"] = @(minActual < 1e11 ? minActual : 0); run[@"agg_actual_rate_max"] = @(maxActual);
    run[@"agg_nominal_rate_min"] = @(minNom < 1e11 ? minNom : 0); run[@"agg_nominal_rate_max"] = @(maxNom);
    run[@"sub_actual_rate_min"] = subActualMin; run[@"sub_actual_rate_max"] = subActualMax;
    run[@"frames_min"] = @(atomic_load(&C.minFrames)); run[@"frames_max"] = @(atomic_load(&C.maxFrames));
    if (C.watch >= 0 && (C.wmode == 2 || C.wmode == 1)) {
        NSMutableArray *g = [NSMutableArray array];
        for (int i = 0; i < C.nGlitch; i++) [g addObject:@(C.lastGlitchT[i])];
        run[@"watched_channel"] = @(C.watch);
        run[@"sine_glitches"] = @(atomic_load(&C.glitches));
        run[@"sine_glitch_times_s"] = g;
        run[@"sine_max_residual"] = @(C.maxResidual);
        run[@"watch_peak"] = @(C.watchPeak);
        run[@"sine_frames_checked"] = @(C.detN);
    }
    if (C.wmode == 3 && C.nLat > 0) {
        double *v = malloc(sizeof(double) * (size_t) C.nLat);
        memcpy(v, C.latMs, sizeof(double) * (size_t) C.nLat);
        qsort(v, (size_t) C.nLat, sizeof(double), cmpd);
        run[@"latency_loop_ms"] = @{ @"n": @(C.nLat), @"min": @(v[0]), @"median": @(v[C.nLat / 2]), @"max": @(v[C.nLat - 1]) };
        free(v);
    } else if (C.wmode == 3) run[@"latency_loop_ms"] = @{ @"n": @0 };
    res[@"run"] = run;

    if (C.capIn && C.wmode == 1 && wFirst >= 0)
        res[@"input_order"] = tonesMapping(C.capIn, C.capInFill, C.capInFrames, C.aggIn, C.wCh, fmax(minNom > 1e11 ? atomic_load(&C.aggRate) : minNom, 1.0), 0);
    if (C.capR && C.aoutMode == 1)
        res[@"output_order"] = tonesMapping(C.capR, C.capRFill, C.capRFrames, C.rCh, C.aggOut, rdev ? nominalRate(rdev) : 48000.0, 0);

    free(C.capIn); free(C.capR);
    emit(res);
    return 0;
}

// ───────────────────────────────── main ─────────────────────────────────

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSMutableArray<NSString *> *a = [NSMutableArray array];
        for (int i = 1; i < argc; i++) [a addObject:[NSString stringWithUTF8String:argv[i]]];
        if (a.count == 0) { fprintf(stderr, "usage: probe state | set-rate UID RATE | set-buffer UID N | set-default input|output|system UID | run ...\n"); return 2; }
        NSString *cmd = a[0];
        if ([cmd isEqualToString:@"state"]) { emit(fullState()); return 0; }
        if ([cmd isEqualToString:@"set-rate"] && a.count == 3) {
            AudioObjectID d = deviceByUID(a[1]);
            if (d == kAudioObjectUnknown) { fprintf(stderr, "no such device\n"); return 3; }
            BOOL ok = setNominalRate(d, [a[2] doubleValue]);
            usleep(300 * 1000);
            printf("%s\n", (ok && fabs(nominalRate(d) - [a[2] doubleValue]) < 0.5) ? "ok" : "failed");
            return ok ? 0 : 1;
        }
        if ([cmd isEqualToString:@"set-buffer"] && a.count == 3) {
            AudioObjectID d = deviceByUID(a[1]);
            if (d == kAudioObjectUnknown) { fprintf(stderr, "no such device\n"); return 3; }
            BOOL ok = setBufferFrames(d, (UInt32) a[2].intValue);
            printf("%s\n", ok ? "ok" : "failed");
            return ok ? 0 : 1;
        }
        if ([cmd isEqualToString:@"set-default"] && a.count == 3) {
            AudioObjectID d = deviceByUID(a[2]);
            if (d == kAudioObjectUnknown) { fprintf(stderr, "no such device\n"); return 3; }
            AudioObjectPropertySelector s = [a[1] isEqualToString:@"input"] ? kAudioHardwarePropertyDefaultInputDevice
                                          : [a[1] isEqualToString:@"output"] ? kAudioHardwarePropertyDefaultOutputDevice
                                          : kAudioHardwarePropertyDefaultSystemOutputDevice;
            AudioObjectPropertyAddress pa = addr(s, kAudioObjectPropertyScopeGlobal);
            OSStatus st = AudioObjectSetPropertyData(kAudioObjectSystemObject, &pa, 0, NULL, sizeof(d), &d);
            printf("%s\n", st == noErr ? "ok" : "failed");
            return st == noErr ? 0 : 1;
        }
        if ([cmd isEqualToString:@"run"]) return runCommand([a subarrayWithRange:NSMakeRange(1, a.count - 1)]);
        fprintf(stderr, "unknown command\n");
        return 2;
    }
}
