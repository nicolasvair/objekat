// The description of the sound card's input channels (`objekat/Shared/OBJInputLayout.h`), asserted
// with no card and no screen: which devices the engine is told about (one mono per channel, one
// stereo per neighbouring pair — 2N - 1) and which of them are enabled is ONE pure function, and
// this is its table.
//
//     clang++ -std=c++17 -I objekat/Shared tools/test_input_layout.cpp -o /tmp/il && /tmp/il
//
// Exit: 0 if every assertion passes, 1 otherwise.

#include "OBJInputLayout.h"
#include <cstdio>
#include <string>
#include <vector>

using namespace objinput;

static int total = 0;
static std::vector<std::string> fails;

static void check(const std::string& label, bool ok, const std::string& detail = "")
{
    ++total;
    if (ok) std::printf("ok    %s\n", label.c_str());
    else { fails.push_back(label); std::printf("FAIL  %s  %s\n", label.c_str(), detail.c_str()); }
}

static std::string show(const std::vector<Device>& v)
{
    std::string s;
    for (const auto& d : v) {
        s += std::to_string(d.first);
        if (d.count == 2) s += "-" + std::to_string(d.first + 1);
        s += d.enabled ? "+ " : "- ";
    }
    return s;
}

static int countEnabled(const std::vector<Device>& v)
{
    int n = 0;
    for (const auto& d : v) n += d.enabled ? 1 : 0;
    return n;
}

int main()
{
    const std::vector<bool> none;
    auto all = [](int n) { return std::vector<bool>((size_t) n, true); };

    // ---- the 2N - 1 count ------------------------------------------------------------------
    for (int n : { 0, 1, 2, 3, 4, 8, 16, 32 }) {
        const auto d = describe(n, all(n), {});
        const int wanted = n <= 0 ? 0 : 2 * n - 1;
        check("N = " + std::to_string(n) + " -> " + std::to_string(wanted) + " devices",
              (int) d.size() == wanted, "got " + std::to_string(d.size()));
    }
    check("a negative channel count describes nothing", describe(-3, all(4), {}).empty());

    // ---- order: monos first, then the pairs, no duplicates ---------------------------------
    {
        const auto d = describe(4, all(4), {});
        check("order: 4 monos then 3 pairs", show(d) == "0+ 1+ 2+ 3+ 0-1- 1-2- 2-3- ", show(d));
        bool distinct = true;
        for (size_t i = 0; i < d.size(); ++i)
            for (size_t j = i + 1; j < d.size(); ++j)
                if (d[i].first == d[j].first && d[i].count == d[j].count) distinct = false;
        check("no (first, count) is described twice", distinct);
    }

    // ---- nothing open: everything is described, nothing is enabled --------------------------
    {
        const auto d = describe(4, none, {});
        check("nothing open -> still 7 devices", d.size() == 7);
        check("nothing open -> none enabled", countEnabled(d) == 0, show(d));
        const auto p = describe(4, none, { 0 });
        check("nothing open + a declared pair -> none enabled", countEnabled(p) == 0, show(p));
    }

    // ---- everything open, no pair: the N monos --------------------------------------------
    {
        const auto d = describe(4, all(4), {});
        check("all open, no pair -> the 4 monos enabled, no stereo", countEnabled(d) == 4);
        bool monosOnly = true;
        for (const auto& x : d) if (x.enabled && x.count != 1) monosOnly = false;
        check("all open, no pair -> only monos are enabled", monosOnly, show(d));
    }

    // ---- a declared pair consumes its two channels ------------------------------------------
    {
        const auto d = describe(4, all(4), { 0 });
        check("pair 1-2 -> monos 0,1 off, monos 2,3 on, pair 0-1 on", show(d) == "0- 1- 2+ 3+ 0-1+ 1-2- 2-3- ", show(d));
        const auto e = describe(4, all(4), { 1 });
        check("pair 2-3 -> mono 0 on, monos 1,2 off, mono 3 on", show(e) == "0+ 1- 2- 3+ 0-1- 1-2+ 2-3- ", show(e));
        const auto f = describe(4, all(4), { 0, 2 });
        check("two pairs -> only the two stereo devices", show(f) == "0- 1- 2- 3- 0-1+ 1-2- 2-3+ ", show(f));
    }

    // ---- overlap: 1-2 and 2-3 COEXIST (decision 4) -----------------------------------------
    {
        check("validPairs: 1-2 and 2-3 together are both kept",
              validPairs(4, { 1, 0 }) == std::vector<int>({ 0, 1 }));
        check("validPairs: unsorted input comes back sorted", validPairs(4, { 2, 1 }) == std::vector<int>({ 1, 2 }));
        check("validPairs: 0, 1, 2 -> all three", validPairs(4, { 0, 1, 2 }) == std::vector<int>({ 0, 1, 2 }));
        check("validPairs: duplicates collapse", validPairs(4, { 2, 2, 2 }) == std::vector<int>({ 2 }));
        // The plan's case: pairs 0-1 and 1-2 declared together. Both stereo devices are enabled, the
        // three monos they cover are not, the untouched channel 3 keeps its mono.
        const auto d = describe(4, all(4), { 1, 0 });
        check("1-2 and 2-3 declared -> both stereo devices on, monos 0,1,2 off, mono 3 on",
              show(d) == "0- 1- 2- 3+ 0-1+ 1-2+ 2-3- ", show(d));
        // The shared channel is read by BOTH devices: each one's indexInDevice is the card channel
        // itself, so channel 1 (the common one) is the second of the first pair and the first of the
        // second pair.
        const Device& a = d[4];        // pair 0-1
        const Device& b = d[5];        // pair 1-2
        check("the common channel is channel 1 of both devices", a.first + 1 == b.first && a.count == 2 && b.count == 2);
        // Unpairing 0-1 hands monos 0 back; channel 1 stays covered by pair 1-2 so its mono stays off.
        const auto u = describe(4, all(4), { 1 });
        check("pair 0-1 removed, 1-2 kept -> mono 0 back, monos 1,2 still off",
              show(u) == "0+ 1- 2- 3+ 0-1- 1-2+ 2-3- ", show(u));
    }

    // ---- pairs that cannot exist on this card ------------------------------------------------
    {
        check("validPairs: negative first dropped", validPairs(4, { -1 }).empty());
        check("validPairs: the last channel cannot start a pair", validPairs(4, { 3 }).empty());
        check("validPairs: past the end dropped", validPairs(4, { 7 }).empty());
        check("validPairs: a one-channel card has no pair", validPairs(1, { 0 }).empty());
        check("validPairs: a two-channel card has exactly pair 0", validPairs(2, { 0 }) == std::vector<int>({ 0 }));
        const auto d = describe(2, all(2), { 5, 0 });
        check("2 channels, a bogus pair beside the real one -> pair on, monos off", show(d) == "0- 1- 0-1+ ", show(d));
    }

    // ---- a pair needs BOTH channels open ----------------------------------------------------
    {
        std::vector<bool> half { true, false, true, true };
        const auto d = describe(4, half, { 0 });
        check("pair 0-1 declared but channel 1 closed -> the pair is off", d.back().enabled == false && show(d).find("0-1-") != std::string::npos, show(d));
        check("...and its mono 0 stays off too (a pair consumes its channels)", show(d).rfind("0- ", 0) == 0, show(d));
        const auto m = describe(4, half, {});
        check("a closed channel has its mono off", show(m) == "0+ 1- 2+ 3+ 0-1- 1-2- 2-3- ", show(m));
        std::vector<bool> shortOpen { true, true };      // open[] shorter than the card
        const auto s = describe(4, shortOpen, {});
        check("open[] shorter than the card -> the missing channels are closed", countEnabled(s) == 2, show(s));
    }

    // ---- sweep: invariants over many shapes ---------------------------------------------------
    {
        bool ok = true;
        std::string why;
        for (int n = 1; n <= 12 && ok; ++n) {
            for (int mask = 0; mask < 64 && ok; ++mask) {
                std::vector<int> req;
                for (int b = 0; b < 6; ++b) if (mask & (1 << b)) req.push_back(b * 2 - (b & 1));   // a mix of overlaps
                const auto d = describe(n, all(n), req);
                if ((int) d.size() != 2 * n - 1) { ok = false; why = "count n=" + std::to_string(n); break; }
                // every channel is covered at least once; a channel under an enabled STEREO device
                // never also has its mono enabled; a channel under no pair is covered exactly once
                std::vector<int> mono((size_t) n, 0), stereo((size_t) n, 0);
                for (const auto& x : d)
                    if (x.enabled)
                        for (int c = 0; c < x.count; ++c) {
                            if (x.first + c >= n) { ok = false; why = "past the end"; break; }
                            ++(x.count == 1 ? mono : stereo)[(size_t) (x.first + c)];
                        }
                for (int c = 0; c < n; ++c) {
                    const int total = mono[(size_t) c] + stereo[(size_t) c];
                    if (total < 1) { ok = false; why = "channel " + std::to_string(c) + " not covered (n=" + std::to_string(n) + " mask=" + std::to_string(mask) + ")"; }
                    if (mono[(size_t) c] > 0 && stereo[(size_t) c] > 0) { ok = false; why = "channel " + std::to_string(c) + " mono AND stereo"; }
                    if (mono[(size_t) c] > 1) { ok = false; why = "mono counted twice"; }
                }
            }
        }
        check("sweep: with everything open, every channel is covered, a paired one by stereo only, whatever is declared", ok, why);
    }

    std::printf("\n%d checks, %zu failed\n", total, fails.size());
    return fails.empty() ? 0 : 1;
}
