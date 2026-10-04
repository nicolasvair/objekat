// The audio bridge's pure core (`tracktion_ObjBridgeCore.h`), asserted with no engine and no screen:
// the ring that carries a key from a tap to its readers, and the latency arithmetic. The design is
// in docs/plan_sidechain.md (§4, §5.2).
//
//     clang++ -std=c++17 -Wall -Wextra -Werror -I tracktion_engine/modules/tracktion_engine/plugins tools/test_bridge_core.cpp -o /tmp/bc && /tmp/bc
//
// Exit: 0 if every assertion passes, 1 otherwise.

#include "tracktion_ObjBridgeCore.h"
#include <cstdio>
#include <string>
#include <vector>

using namespace tracktion::engine::objbridge;

static int total = 0;
static std::vector<std::string> fails;

static void check (const std::string& label, bool ok, const std::string& detail = "")
{
    ++total;
    if (ok) std::printf ("ok    %s\n", label.c_str());
    else { fails.push_back (label); std::printf ("FAIL  %s  %s\n", label.c_str(), detail.c_str()); }
}

// A block whose sample i holds `base + i`, so that every stream sample has a distinct value.
static std::vector<float> ramp (float base, int n)
{
    std::vector<float> v ((size_t) n);
    for (int i = 0; i < n; ++i) v[(size_t) i] = base + (float) i;
    return v;
}

static void put (Ring& r, int64_t start, int n, bool force = false)
{
    // The value at stream sample s is s + 1 on the left, -(s + 1) on the right (never 0).
    auto l = ramp ((float) start + 1.0f, n);
    std::vector<float> rt (l.size());
    for (size_t i = 0; i < l.size(); ++i) rt[i] = -l[i];
    const float* src[2] = { l.data(), rt.data() };
    r.write (start, n, src, 2, force);
}

struct Got { std::vector<float> l, r; Ring::ReadResult res; };

static Got get (const Ring& r, int64_t start, int n)
{
    Got g;
    g.l.assign ((size_t) n, 99.0f);
    g.r.assign ((size_t) n, 99.0f);
    float* dst[2] = { g.l.data(), g.r.data() };
    g.res = r.read (start, n, dst, 2);
    return g;
}

static bool exact (const Got& g, int64_t start, int from, int to)   // [from, to) holds s + 1 / -(s + 1)
{
    for (int i = from; i < to; ++i)
        if (g.l[(size_t) i] != (float) (start + i + 1) || g.r[(size_t) i] != -(float) (start + i + 1))
            return false;
    return true;
}

static bool zero (const Got& g, int from, int to)
{
    for (int i = from; i < to; ++i)
        if (g.l[(size_t) i] != 0.0f || g.r[(size_t) i] != 0.0f)
            return false;
    return true;
}

int main()
{
    // ---- construction
    {
        Ring a (2, 1000), b (7, 1), c (0, 4096), d (2, 0);
        check ("capacity rounds up to a power of two", a.getCapacity() == 1024);
        check ("capacity already a power of two is kept", c.getCapacity() == 4096);
        check ("degenerate capacity is still usable", d.getCapacity() >= 2 && (d.getCapacity() & (d.getCapacity() - 1)) == 0);
        check ("numChannels clamped to 2", b.getNumChannels() == 2);
        check ("numChannels clamped to 1", c.getNumChannels() == 1);
    }

    // ---- read before any write
    {
        Ring r (2, 1024);
        auto g = get (r, 0, 64);
        check ("read before any write: zeros", zero (g, 0, 64));
        check ("read before any write: nothing covered", g.res.framesCovered == 0 && ! g.res.torn);
        check ("latestEnd is 0 before any write", r.getLatestEnd() == 0);
    }

    // ---- exact write / read
    {
        Ring r (2, 1024);
        put (r, 1000, 256);
        auto g = get (r, 1000, 256);
        check ("exact read: every frame", exact (g, 1000, 0, 256));
        check ("exact read: covered", g.res.framesCovered == 256 && ! g.res.torn);
        check ("latestEnd after one write", r.getLatestEnd() == 1256);
        auto h = get (r, 1100, 64);
        check ("read inside a block", exact (h, 1100, 0, 64) && h.res.framesCovered == 64);
    }

    // ---- delayed read across a block boundary and across the ring wrap
    {
        Ring r (2, 512);
        int64_t s = 100;
        for (int b = 0; b < 12; ++b) { put (r, s, 128); s += 128; }    // 1536 frames: wraps the ring 3 times
        // reader at stream sample s (the next block), delay 200: [s - 200, s - 72) spans two written blocks.
        auto g = get (r, s - 200, 128);
        check ("delayed read across a block boundary and the wrap", exact (g, s - 200, 0, 128) && g.res.framesCovered == 128);
        auto h = get (r, s - 512, 128);
        check ("read exactly capacity back is still valid", exact (h, s - 512, 0, 128));
        auto k = get (r, s - 513, 128);
        check ("one frame past the capacity reads zero there, valid after",
               k.l[0] == 0.0f && k.r[0] == 0.0f && exact (k, s - 513, 1, 128) && k.res.framesCovered == 127);
    }

    // ---- contiguous sub-ranges: ONE run
    {
        Ring r (2, 1024);
        put (r, 5000, 100);
        put (r, 5100, 60);
        put (r, 5160, 96);
        auto g = get (r, 5000, 256);
        check ("contiguous sub-ranges read as one", exact (g, 5000, 0, 256) && g.res.framesCovered == 256);
        check ("contiguous sub-ranges: latestEnd", r.getLatestEnd() == 5256);
    }

    // ---- a gap starts a new run; the gap reads zero
    {
        Ring r (2, 1024);
        put (r, 0, 100);
        put (r, 150, 100);               // gap [100, 150)
        auto g = get (r, 0, 250);
        check ("gap reads zero", zero (g, 100, 150));
        check ("both sides of the gap are intact", exact (g, 0, 0, 100) && exact (g, 0, 150, 250));
        check ("gap: covered excludes the gap", g.res.framesCovered == 200);
    }

    // ---- forceNewRun splits a contiguous write
    {
        Ring r (2, 1024);
        put (r, 0, 100);
        put (r, 100, 100, true);         // contiguous but forced: same data, two runs
        auto g = get (r, 0, 200);
        check ("forceNewRun: data still reads through", exact (g, 0, 0, 200) && g.res.framesCovered == 200);
        // prove it IS a second run: five forced writes keep at most four of them
        Ring q (2, 4096);
        for (int i = 0; i < 5; ++i) put (q, i * 100, 100, true);
        auto h = get (q, 0, 500);
        check ("forceNewRun splits: more than 4 runs drops the oldest", zero (h, 0, 100) && exact (h, 0, 100, 500));
    }

    // ---- more than 4 runs drops the oldest
    {
        Ring r (2, 8192);
        for (int i = 0; i < 6; ++i) put (r, (int64_t) i * 200, 100);   // six runs separated by gaps
        auto g = get (r, 0, 1100);
        bool oldestGone = zero (g, 0, 200);                            // runs 0 and 1 are gone
        bool newestKept = exact (g, 0, 400, 500) && exact (g, 0, 600, 700) && exact (g, 0, 800, 900) && exact (g, 0, 1000, 1100);
        check ("5th/6th run drops the two oldest", oldestGone && newestKept);
        check ("six gapped runs: four kept", g.res.framesCovered == 400);
    }

    // ---- an overwritten region reads zero
    {
        Ring r (2, 256);
        for (int b = 0; b < 10; ++b) put (r, (int64_t) b * 64, 64);    // 640 frames into 256
        auto g = get (r, 0, 640);
        check ("older than latestEnd - capacity reads zero", zero (g, 0, 640 - 256));
        check ("the last capacity frames are intact", exact (g, 0, 640 - 256, 640));
        check ("overwritten: covered", g.res.framesCovered == 256);
    }

    // ---- a block longer than the ring keeps its tail
    {
        Ring r (2, 128);
        put (r, 1000, 300);
        auto g = get (r, 1000, 300);
        check ("oversized block: head overwritten, tail kept", zero (g, 0, 172) && exact (g, 1000, 172, 300));
    }

    // ---- a run that starts before an older run's end drops it (stream time never goes back)
    {
        Ring r (2, 1024);
        put (r, 1000, 100);
        put (r, 500, 100);               // earlier than the old run's end
        auto g = get (r, 500, 100);
        auto h = get (r, 1000, 100);
        check ("backward run: new data readable", exact (g, 500, 0, 100));
        check ("backward run: the run it contradicts is gone", zero (h, 0, 100));
        check ("backward run: latestEnd follows the newest", r.getLatestEnd() == 600);
    }

    // ---- mono source duplicated; channels beyond the ring's ignored; extra dest channels zeroed
    {
        Ring r (2, 256);
        auto m = ramp (1.0f, 64);
        const float* src1[1] = { m.data() };
        r.write (0, 64, src1, 1, false);
        auto g = get (r, 0, 64);
        bool dup = true;
        for (int i = 0; i < 64; ++i) dup = dup && g.l[(size_t) i] == (float) (i + 1) && g.r[(size_t) i] == (float) (i + 1);
        check ("a mono source fills both channels", dup);

        Ring one (1, 256);
        auto a = ramp (1.0f, 32), b = ramp (-1.0f, 32);
        const float* src2[2] = { a.data(), b.data() };
        one.write (0, 32, src2, 2, false);
        std::vector<float> l (32, 7.0f), rr (32, 7.0f), x (32, 7.0f);
        float* dst[3] = { l.data(), rr.data(), x.data() };
        auto res = one.read (0, 32, dst, 3);
        bool ok = res.framesCovered == 32;
        for (int i = 0; i < 32; ++i) ok = ok && l[(size_t) i] == (float) (i + 1) && rr[(size_t) i] == 0.0f && x[(size_t) i] == 0.0f;
        check ("1-channel ring: channel 0 kept, destination channels beyond it zeroed", ok);

        Ring two (2, 256);
        auto c0 = ramp (1.0f, 32), c1 = ramp (100.0f, 32), c2 = ramp (500.0f, 32);
        const float* src3[3] = { c0.data(), c1.data(), c2.data() };
        two.write (0, 32, src3, 3, false);
        auto g2 = get (two, 0, 32);
        check ("source channels beyond the ring's are ignored", g2.l[5] == 6.0f && g2.r[5] == 105.0f);

        std::vector<float> d0 (32, 7.0f);
        float* only[1] = { d0.data() };
        auto r1 = two.read (0, 32, only, 1);
        check ("a mono destination reads channel 0", r1.framesCovered == 32 && d0[5] == 6.0f);
    }

    // ---- null / empty guards
    {
        Ring r (2, 256);
        r.write (0, 0, nullptr, 0, false);
        check ("a zero-length write does nothing", r.getLatestEnd() == 0);
        r.write (0, 16, nullptr, 0, false);
        auto g = get (r, 0, 16);
        check ("a write with no source writes silence (and covers)", zero (g, 0, 16) && g.res.framesCovered == 16);
        auto h = get (r, 0, 0);
        check ("a zero-length read covers nothing", h.res.framesCovered == 0 && ! h.res.torn);
    }

    // ---- declaredLatency
    check ("declaredLatency: key younger", declaredLatency (1500, 1000) == 1500);
    check ("declaredLatency: key older", declaredLatency (0, 1000) == 1000);
    check ("declaredLatency: cached -1 means unknown", declaredLatency (480, -1) == 480);
    check ("declaredLatency: both zero", declaredLatency (0, 0) == 0);

    // ---- resolve
    {
        auto r = resolve (1500, 1500, true, 1000);   // key younger: the worked example's 500
        check ("resolve younger key: delay = L_d - L_s", r.delay == 500 && r.status == ReaderStatus::aligned && r.alignmentError == 0);

        r = resolve (0, 1000, true, 1000);           // key older, X = L_s
        check ("resolve older key: delay 0, aligned", r.delay == 0 && r.status == ReaderStatus::aligned && r.alignmentError == 0);

        r = resolve (0, 0, true, 960);               // declared from an unknown cache, true age higher
        check ("resolve late: X < L_s", r.status == ReaderStatus::late && r.delay == 0 && r.alignmentError == 960);

        r = resolve (0, 1500, true, 1000);           // cached age dropped from 1500 to 1000
        check ("resolve over-declared: X > max(L_d, L_s)", r.status == ReaderStatus::overDeclared && r.delay == 500 && r.alignmentError == 0);

        r = resolve (1200, 1200, true, 1000);        // X is the reference's own: NOT over-declared
        check ("resolve: declared equal to L_d is not over-declared", r.status == ReaderStatus::aligned && r.delay == 200);

        r = resolve (300, 1000, false, 0);
        check ("resolve source absent", r.status == ReaderStatus::sourceAbsent && r.delay == 0 && r.alignmentError == 0);

        r = resolve (0, 0, true, 0);
        check ("resolve: no latency anywhere", r.status == ReaderStatus::aligned && r.delay == 0);
    }

    // ---- requiredRingCapacity
    {
        auto pow2 = [] (int v) { return v > 0 && (v & (v - 1)) == 0; };
        check ("requiredRingCapacity: minimum 4 x block (512 -> 2048)", requiredRingCapacity (0, 512) == 2048);
        check ("requiredRingCapacity: delay dominates (960 + 1024 -> 2048)", requiredRingCapacity (960, 512) == 2048);
        check ("requiredRingCapacity: delay dominates (5000, 512 -> 8192)", requiredRingCapacity (5000, 512) == 8192);
        check ("requiredRingCapacity: exact power of two is kept (1024 + 2 x 512 = 2048)", requiredRingCapacity (1024, 512) == 2048);
        check ("requiredRingCapacity: one over doubles (1025 -> 4096)", requiredRingCapacity (1025, 512) == 4096);
        bool allPow2 = true, enough = true;
        for (int block : { 1, 32, 100, 480, 512, 1024, 4096 })
            for (int delay : { 0, 1, 480, 960, 48000, 96001 })
            {
                const int c = requiredRingCapacity (delay, block);
                allPow2 = allPow2 && pow2 (c);
                enough = enough && c >= delay + 2 * block && c >= 4 * block;
            }
        check ("requiredRingCapacity sweep: powers of two, never too small", allPow2 && enough);
        check ("requiredRingCapacity: nonsense input stays sane", requiredRingCapacity (-5, 0) >= 4);
    }

    // ---- scaleCachedAge
    check ("scaleCachedAge 44.1 -> 48 k rounds", scaleCachedAge (1000, 44100.0, 48000.0) == 1088);
    check ("scaleCachedAge 48 -> 44.1 k rounds", scaleCachedAge (1088, 48000.0, 44100.0) == 1000);
    check ("scaleCachedAge same rate is the identity", scaleCachedAge (777, 48000.0, 48000.0) == 777);
    check ("scaleCachedAge unknown rate gives -1", scaleCachedAge (1000, 0.0, 48000.0) == -1);
    check ("scaleCachedAge unknown age stays -1", scaleCachedAge (-1, 48000.0, 96000.0) == -1);
    check ("scaleCachedAge 0 stays 0", scaleCachedAge (0, 44100.0, 96000.0) == 0);

    // ---- reader/ring round trip with a delay: what the alignment rule promises
    {
        // A tap whose block at stream sample s is read with D back must return the material of s - D.
        Ring r (2, (int) requiredRingCapacity (480, 256));
        int64_t s = 0;
        bool ok = true;
        for (int b = 0; b < 40; ++b)
        {
            put (r, s, 256);
            if (s >= 480) { auto g = get (r, s - 480, 256); ok = ok && exact (g, s - 480, 0, 256); }
            s += 256;
        }
        check ("tap then reader with D = 480 over 40 blocks: sample-exact", ok);
    }

    std::printf ("\n%d assertions, %zu failed\n", total, fails.size());
    for (auto& f : fails) std::printf ("  FAILED: %s\n", f.c_str());
    return fails.empty() ? 0 : 1;
}
