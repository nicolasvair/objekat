//
//  OBJSampleRatePolicy.h
//  objekat
//
//  What to do about the sound card's own sample rate, decided from two numbers and a list — the
//  rate the card is ALREADY running at, and the rates it offers. Plain C++17, header only, no JUCE,
//  no Tracktion: there is ONE implementation, called by OBJEngineCore.mm (`applySampleRatePolicy`)
//  AND by tools/test_sample_rate_policy.cpp, so what the test asserts is what the app decides.
//
//  WHY. OBJEKAT used to IMPOSE a rate: Settings.xml re-asserted `audioDeviceRate` at launch and
//  `setOutputDevice:` carried the OLD card's rate over to the new one — and a CoreAudio rate change
//  is not local, it changes the card for every application on the machine. The app now ADOPTS what
//  the card runs at, and touches it only when that rate is unusable for us.
//
//    adopt           the card's rate is within [22050 ; 192000] and is one the card lists (± 1 Hz;
//                    an empty list cannot contradict it): keep it, change nothing.
//    fallback        it is not (out of range, absent from the list, or unknown) but the card lists
//                    at least one rate within range: move to the best of those — 48000, else 44100,
//                    else the one NEAREST TO 48000 (a tie goes to the lower one). The reference is
//                    48000 and not the device's own rate on purpose: a 384 kHz card whose list is
//                    {88.2, 176.4, 384} lands on 88.2 (the gentlest for the CPU and the disk), not
//                    on 176.4, which is merely "nearest to 384".
//    outOfRangeKept  nothing the card lists is within range (a 8/16 kHz-only device…): there is
//                    nothing better to move to, so its rate is KEPT (`rate` = the card's rate, or
//                    the list's first entry when the card's own is unknown).
//    unknown         neither a rate nor a list: nothing to decide on, `rate` = 0.
//
//  The export keeps its own, distinct rate (`ExportSettings.sampleRate`) — this is about what the
//  CARD runs at, never about what a file is rendered at.
//

#ifndef OBJSampleRatePolicy_h
#define OBJSampleRatePolicy_h

#include <cmath>
#include <vector>

enum class OBJRateDecisionKind { adopt = 0, fallback = 1, outOfRangeKept = 2, unknown = 3 };

struct OBJRateDecision {
    OBJRateDecisionKind kind = OBJRateDecisionKind::unknown;
    double rate = 0;   // the rate the card should run at (for `unknown`: 0)
};

namespace objratepolicy {

constexpr double kMinRate = 22050.0;
constexpr double kMaxRate = 192000.0;
constexpr double kPreferredRate = 48000.0;
constexpr double kSecondRate = 44100.0;
constexpr double kTolerance = 1.0;   // Hz — a CoreAudio rate read back as 48000.4 is still 48000

inline bool inRange(double r) { return r >= kMinRate && r <= kMaxRate; }

inline bool near(double a, double b) { return std::fabs(a - b) <= kTolerance; }

} // namespace objratepolicy

inline OBJRateDecision objDecideSampleRate(double deviceRate, const std::vector<double>& available)
{
    using namespace objratepolicy;
    OBJRateDecision d;

    // 1. The card's own rate, when it is usable.
    if (deviceRate > 0 && inRange(deviceRate)) {
        bool listed = available.empty();
        for (double a : available) if (near(a, deviceRate)) { listed = true; break; }
        if (listed) { d.kind = OBJRateDecisionKind::adopt; d.rate = deviceRate; return d; }
    }

    // 2. Something in range to move to.
    std::vector<double> usable;
    for (double a : available) if (a > 0 && inRange(a)) usable.push_back(a);
    if (!usable.empty()) {
        d.kind = OBJRateDecisionKind::fallback;
        for (double a : usable) if (near(a, kPreferredRate)) { d.rate = a; return d; }
        for (double a : usable) if (near(a, kSecondRate))    { d.rate = a; return d; }
        double best = usable.front();
        for (double a : usable) {
            const double da = std::fabs(a - kPreferredRate), db = std::fabs(best - kPreferredRate);
            if (da < db || (da == db && a < best)) best = a;
        }
        d.rate = best;
        return d;
    }

    // 3. Nothing usable on offer: keep what we have.
    if (deviceRate > 0)         { d.kind = OBJRateDecisionKind::outOfRangeKept; d.rate = deviceRate; return d; }
    if (!available.empty())     { d.kind = OBJRateDecisionKind::outOfRangeKept; d.rate = available.front(); return d; }

    // 4. Nothing at all.
    d.kind = OBJRateDecisionKind::unknown;
    d.rate = 0;
    return d;
}

#endif /* OBJSampleRatePolicy_h */
