// The sample-rate policy (`objekat/Shared/OBJSampleRatePolicy.h`), asserted with no card and no
// screen: what the app does about the device's own rate is decided by ONE pure function, and this
// is its table.
//
//     clang++ -std=c++17 -I objekat/Shared tools/test_sample_rate_policy.cpp -o /tmp/srp && /tmp/srp
//
// Exit: 0 if every assertion passes, 1 otherwise.

#include "OBJSampleRatePolicy.h"
#include <cstdio>
#include <string>
#include <vector>

static int total = 0;
static std::vector<std::string> fails;

static void check(const std::string& label, bool ok, const std::string& detail = "")
{
    ++total;
    if (ok) std::printf("ok    %s\n", label.c_str());
    else { fails.push_back(label); std::printf("FAIL  %s  %s\n", label.c_str(), detail.c_str()); }
}

static const char* name(OBJRateDecisionKind k)
{
    switch (k) {
        case OBJRateDecisionKind::adopt:          return "adopt";
        case OBJRateDecisionKind::fallback:       return "fallback";
        case OBJRateDecisionKind::outOfRangeKept: return "outOfRangeKept";
        case OBJRateDecisionKind::unknown:        return "unknown";
    }
    return "?";
}

static void expect(const std::string& label, double deviceRate, const std::vector<double>& list,
                   OBJRateDecisionKind kind, double rate)
{
    const auto d = objDecideSampleRate(deviceRate, list);
    char buf[160];
    std::snprintf(buf, sizeof buf, "got %s %.1f, wanted %s %.1f", name(d.kind), d.rate, name(kind), rate);
    check(label, d.kind == kind && std::fabs(d.rate - rate) < 1e-9, buf);
}

int main()
{
    using K = OBJRateDecisionKind;
    const std::vector<double> std3 = {44100, 48000, 96000};

    // MARK: - adopt: the card's own rate is usable, nothing is touched
    expect("44100 in {44.1,48,96} -> adopt 44100", 44100, std3, K::adopt, 44100);
    expect("48000 in {44.1,48,96} -> adopt 48000", 48000, std3, K::adopt, 48000);
    expect("96000 in {44.1,48,96} -> adopt 96000", 96000, std3, K::adopt, 96000);
    expect("192000 in {44.1..192} -> adopt (upper bound is inclusive)", 192000,
           {44100, 48000, 96000, 192000}, K::adopt, 192000);
    expect("22050 in {22.05,48} -> adopt (lower bound is inclusive)", 22050, {22050, 48000}, K::adopt, 22050);
    expect("48000.4 vs {48000} -> adopt (+-1 Hz)", 48000.4, {48000}, K::adopt, 48000.4);
    expect("47999.6 vs {48000} -> adopt (+-1 Hz, below)", 47999.6, {48000}, K::adopt, 47999.6);
    expect("empty list, 48000 -> adopt (nothing to contradict it)", 48000, {}, K::adopt, 48000);

    // MARK: - fallback: unusable, but something in range is on offer
    expect("384000 in {44.1,48,96,192,384} -> fallback 48000", 384000,
           {44100, 48000, 96000, 192000, 384000}, K::fallback, 48000);
    expect("384000 in {88.2,176.4,384} -> fallback 88200 (nearest to 48000, not to 384000)", 384000,
           {88200, 176400, 384000}, K::fallback, 88200);
    expect("16000 in {16,48} -> fallback 48000", 16000, {16000, 48000}, K::fallback, 48000);
    expect("47000 in {44.1,48} -> fallback 48000 (not listed)", 47000, {44100, 48000}, K::fallback, 48000);
    expect("384000 in {44.1,96,384} -> fallback 44100 (no 48000)", 384000, {44100, 96000, 384000}, K::fallback, 44100);
    expect("0 in {44.1,48} -> fallback 48000 (rate unknown, list known)", 0, {44100, 48000}, K::fallback, 48000);
    expect("384000 in {30,64,384} -> fallback 64000 (nearest to 48000)", 384000, {30000, 64000, 384000}, K::fallback, 64000);
    expect("equidistant from 48000 -> the lower one: {40000,56000} -> 40000", 384000,
           {56000, 40000}, K::fallback, 40000);
    expect("fallback returns the LIST's own value (48000.2)", 384000,
           {48000.2, 384000}, K::fallback, 48000.2);

    // MARK: - outOfRangeKept: nothing usable on offer, keep what we have
    expect("16000 in {16000} -> outOfRangeKept 16000", 16000, {16000}, K::outOfRangeKept, 16000);
    expect("8000 in {8000,16000} -> outOfRangeKept 8000", 8000, {8000, 16000}, K::outOfRangeKept, 8000);
    expect("0 in {16000,8000} -> outOfRangeKept front()=16000", 0, {16000, 8000}, K::outOfRangeKept, 16000);
    expect("16000, empty list -> outOfRangeKept 16000", 16000, {}, K::outOfRangeKept, 16000);
    expect("384000 in {384000} -> outOfRangeKept 384000", 384000, {384000}, K::outOfRangeKept, 384000);

    // MARK: - unknown
    expect("(0, {}) -> unknown 0", 0, {}, K::unknown, 0);
    expect("(-5, {}) -> unknown 0", -5, {}, K::unknown, 0);

    // MARK: - coherence sweep
    {
        const std::vector<std::vector<double>> lists = {
            {}, {16000}, {8000, 16000}, {44100}, {48000}, {44100, 48000, 96000},
            {44100, 48000, 88200, 96000, 176400, 192000}, {88200, 176400, 384000},
            {384000}, {16000, 48000}, {22050, 24000}, {11025, 22050, 32000}};
        const std::vector<double> rates = {-1, 0, 1, 8000, 11025, 16000, 22049, 22050, 32000, 44100,
                                           44100.9, 47000, 48000, 48000.4, 88200, 96000, 100000,
                                           176400, 191999, 192000, 192001, 384000, 768000};
        bool ok = true;
        std::string why;
        for (const auto& list : lists) {
            auto listed = [&](double x) {
                for (double a : list) if (objratepolicy::near(a, x)) return true;
                return false;
            };
            for (double r : rates) {
                const auto d = objDecideSampleRate(r, list);
                char buf[160];
                std::snprintf(buf, sizeof buf, "(%.1f, list#%zu) -> %s %.1f", r, list.size(), name(d.kind), d.rate);
                bool good = true;
                switch (d.kind) {
                    case K::adopt:
                        good = d.rate == r && r > 0 && objratepolicy::inRange(r) && (list.empty() || listed(r));
                        break;
                    case K::fallback:
                        good = listed(d.rate) && objratepolicy::inRange(d.rate);
                        // the decision is a fixed point: asking again from the new rate adopts it
                        good = good && objDecideSampleRate(d.rate, list).kind == K::adopt;
                        break;
                    case K::outOfRangeKept:
                        // nothing on offer is usable (the card's own rate is kept as it is,
                        // even when it is itself in range but absent from a list that is not)
                        good = d.rate > 0;
                        for (double a : list) good = good && !objratepolicy::inRange(a);
                        break;
                    case K::unknown:
                        good = d.rate == 0 && list.empty() && r <= 0;
                        break;
                }
                // an in-range rate on an empty list is never anything but adopt
                if (list.empty() && r > 0 && objratepolicy::inRange(r)) good = good && d.kind == K::adopt;
                if (!good) { ok = false; why += std::string(buf) + "; "; }
            }
        }
        check("sweep: adopt keeps the rate, fallback is listed+in range+idempotent, outOfRange has nothing "
              "better, unknown is empty", ok, why);
    }

    std::printf("\n%d checks, %zu failed\n", total, fails.size());
    return fails.empty() ? 0 : 1;
}
