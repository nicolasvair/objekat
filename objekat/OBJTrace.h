//
//  OBJTrace.h
//  objekat
//
//  The PLUGIN TRACE: what a plugin does to ONE precise signal, frozen so that the session
//  stays portable on a machine where the plugin is absent.
//
//      y[n] = g[n] · x[n] + d[n]
//
//  This header carries the data model (two run-length encoded signals plus a header), the
//  on-disk format, and the arithmetic that turns a pair of captures into a trace. It knows
//  nothing about tracktion: the capture lives in OBJTraceProbePlugin, the restitution in
//  OBJTracePlaybackPlugin, and the orchestration in OBJEngineCore.
//
//  The authority for all of it is `docs/objekat-capture-trace.md`. Where a comment here says
//  "the spec", that is the file it means.
//

#pragma once

#include <juce_core/juce_core.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <type_traits>
#include <vector>

namespace objtrace {

//==============================================================================
// Constants — the spec's, gathered here so there is ONE place they live.

/// Under this, two float32 renders are the same render. Serves twice, and deliberately as the
/// SAME number: the determinism verdict on the null test between the two B passes, and the
/// "exact" tier of the validation report.
static constexpr double kExactDbfs = -250.0;

/// Between this and `kExactDbfs`, a validation residual is acceptable but worth reporting.
static constexpr double kAcceptableDbfs = -120.0;

/// Default ceiling on |g| before the excess tips into the additive term. @see computeTrace.
static constexpr double kDefaultGMax = 64.0;

/// Default input gate: below it a ratio means nothing, so g is forced to 1 and everything
/// goes to d. @see computeTrace.
static constexpr double kDefaultXMinDbfs = -100.0;

/// Two runs of non-default samples closer than this are merged into one segment. A segment
/// header costs 16 bytes, about two float64 samples; below that the encoding loses on bytes as
/// well as on lookup cost, and a pathological alternation would produce a segment table with
/// millions of one-sample entries.
static constexpr uint64_t kDefaultMergeGap = 16;

/// A level of exactly zero has no decibel value. This is the floor we report instead, low
/// enough to read as "nothing at all" next to `kExactDbfs`.
static constexpr double kSilenceDbfs = -400.0;

//==============================================================================
/** A level in dBFS, with a floor rather than -infinity. */
inline double toDbfs (double magnitude) noexcept
{
    return magnitude > 0.0 ? std::max (kSilenceDbfs, 20.0 * std::log10 (magnitude))
                           : kSilenceDbfs;
}

/** Peak and RMS of a difference, in dBFS. Both are reported everywhere the spec asks for a
    residual: a peak alone hides a steady low-level hum, an RMS alone hides a single click. */
struct Residual
{
    double peakDbfs = kSilenceDbfs;
    double rmsDbfs  = kSilenceDbfs;

    /// The verdict of the validation report's three tiers, and of the determinism test.
    bool isExact()      const noexcept { return peakDbfs < kExactDbfs; }
    bool isAcceptable() const noexcept { return peakDbfs < kAcceptableDbfs; }
};

/** The residual of `a - b`, over `numSamples` of each. */
inline Residual nullTest (const float* a, const float* b, size_t numSamples) noexcept
{
    double peak = 0.0, sumSquares = 0.0;

    for (size_t i = 0; i < numSamples; ++i)
    {
        const double diff = (double) a[i] - (double) b[i];
        peak = std::max (peak, std::abs (diff));
        sumSquares += diff * diff;
    }

    Residual r;
    r.peakDbfs = toDbfs (peak);
    r.rmsDbfs  = toDbfs (numSamples > 0 ? std::sqrt (sumSquares / (double) numSamples) : 0.0);
    return r;
}

//==============================================================================
/** One of the trace's two signals — `g` or `d` — stored as SEGMENTS over an exact default.

    On a typical trace `g[n]` is exactly 1 over long stretches (silences, passages below a
    compressor's threshold) and `d[n]` is 0 everywhere outside the gated zones. Stored flat, a
    trace costs 8 bytes per sample per channel, most of it spent writing ones and zeros: a
    stereo minute at 48 kHz is 92 MB of which the overwhelming majority carries no information.

    The comparison against the default is EXACT (`== 1.0`, `== 0.0`), never approximate: a
    tolerance would be lossy compression, and this format's whole point is exactness. It costs
    nothing in practice, because the values that compress are the ones the arithmetic ASSIGNS
    — the gate's `g = 1`, the deterministic branch's `d = 0` — and not ones we hope will land
    on a round number.
*/
struct Signal
{
    struct Segment
    {
        uint64_t start  = 0;   ///< first sample covered
        uint64_t length = 0;   ///< how many
        uint64_t offset = 0;   ///< where its samples begin in `data`
    };

    double defaultValue = 0.0;
    std::vector<Segment> segments;
    std::vector<double>  data;        ///< the segments' samples, concatenated in order

    /// True when the signal never departs from its default — what `multiplicative_only` means
    /// in the file rather than only in a flag.
    bool isConstant() const noexcept        { return segments.empty(); }

    uint64_t storedSamples() const noexcept { return (uint64_t) data.size(); }

    /// Bytes this signal occupies on disk. @see write.
    uint64_t byteSize() const noexcept
    {
        return 8 + 4 + (uint64_t) segments.size() * 16 + (uint64_t) data.size() * 8;
    }

    //==========================================================================
    /** Reads one sample. Sequential access is O(1) amortised through `cursor`, which is what
        the restitution node does; a random read costs a binary search. */
    double at (uint64_t n) const noexcept
    {
        if (segments.empty())
            return defaultValue;

        // Sequential fast path: the segment the last call landed in, or the next one.
        if (cursor < segments.size())
        {
            const auto& s = segments[cursor];
            if (n >= s.start && n < s.start + s.length)
                return data[(size_t) (s.offset + (n - s.start))];

            if (n >= s.start + s.length && cursor + 1 < segments.size())
            {
                const auto& next = segments[cursor + 1];
                if (n < next.start)
                    return defaultValue;             // in the gap before the next segment
                if (n < next.start + next.length)
                {
                    ++cursor;
                    return data[(size_t) (next.offset + (n - next.start))];
                }
            }
        }

        // Anything else: locate the last segment starting at or before `n`.
        auto it = std::upper_bound (segments.begin(), segments.end(), n,
                                    [] (uint64_t v, const Segment& s) { return v < s.start; });
        if (it == segments.begin())
            return defaultValue;

        --it;
        cursor = (size_t) std::distance (segments.begin(), it);
        return (n < it->start + it->length) ? data[(size_t) (it->offset + (n - it->start))]
                                            : defaultValue;
    }

    /// Puts the sequential cursor back to the start. To be called before replaying from zero.
    void rewind() const noexcept { cursor = 0; }

private:
    mutable size_t cursor = 0;
};

//==============================================================================
/** Run-length encodes a flat signal against `defaultValue`.

    `mergeGap` absorbs the short gaps: two runs separated by fewer than that many default
    samples become one segment, those samples stored verbatim. @see kDefaultMergeGap.
*/
inline Signal encodeSignal (const std::vector<double>& flat,
                            double defaultValue,
                            uint64_t mergeGap = kDefaultMergeGap)
{
    Signal sig;
    sig.defaultValue = defaultValue;

    const uint64_t n = (uint64_t) flat.size();
    uint64_t i = 0;

    while (i < n)
    {
        // Skip to the next departure from the default.
        while (i < n && flat[(size_t) i] == defaultValue)
            ++i;
        if (i >= n)
            break;

        const uint64_t start = i;
        uint64_t end = i;   // one PAST the last non-default sample seen so far

        while (i < n)
        {
            if (flat[(size_t) i] != defaultValue)
            {
                end = i + 1;
                ++i;
                continue;
            }

            // A run of defaults: absorb it only if it is short enough to be worth it.
            uint64_t gapStart = i;
            while (i < n && flat[(size_t) i] == defaultValue)
                ++i;
            if (i >= n || (i - gapStart) >= mergeGap)
                break;
        }

        Signal::Segment seg;
        seg.start  = start;
        seg.length = end - start;
        seg.offset = (uint64_t) sig.data.size();
        sig.data.insert (sig.data.end(),
                         flat.begin() + (ptrdiff_t) start,
                         flat.begin() + (ptrdiff_t) end);
        sig.segments.push_back (seg);
    }

    return sig;
}

/** The inverse, for the validation pass and for tests: a flat signal of `numSamples`. */
inline std::vector<double> decodeSignal (const Signal& sig, uint64_t numSamples)
{
    std::vector<double> flat ((size_t) numSamples, sig.defaultValue);

    for (const auto& s : sig.segments)
        for (uint64_t k = 0; k < s.length && s.start + k < numSamples; ++k)
            flat[(size_t) (s.start + k)] = sig.data[(size_t) (s.offset + k)];

    return flat;
}

//==============================================================================
/** Everything the file says about itself. Serialised as JSON — a trace outlives the version of
    the app that wrote it, and a reader with no source at hand must be able to say what it holds. */
struct Header
{
    // Identity
    std::string slotID;             ///< the plugin slot this trace belongs to (ObjectPlugin.id)
    std::string pluginName;
    std::string pluginIdentifier;   ///< the AU/VST3 identifier of the plugin traced
    std::string pluginFormat;
    std::string pluginVersion;

    // Render context
    double   sampleRate   = 0.0;
    int      numChannels  = 0;      ///< channels the capture saw
    int      storedChannels = 0;    ///< 1 when `linked`, else `numChannels`
    int      blockSize    = 0;

    // Span
    double   regionStart  = 0.0;    ///< seconds, in the timeline
    double   regionEnd    = 0.0;
    double   tailSeconds  = 0.0;
    double   preRollSeconds = 0.0;  ///< the pre-roll actually applied
    uint64_t numSamples   = 0;      ///< region + tail, per channel

    // Alignment
    int      latencySamples = 0;        ///< the plugin's declared latency, compensated
    double   correlationLagSamples = 0; ///< measured by cross-correlation; should be a whole number
    bool     fractionalLatency = false; ///< the measured lag is not a whole number of samples

    // Arithmetic
    double   gMax = kDefaultGMax;
    double   xMinDbfs = kDefaultXMinDbfs;
    uint64_t mergeGap = kDefaultMergeGap;

    // Flags
    bool multiplicativeOnly = false;  ///< d is zero everywhere: not stored
    bool linked             = false;  ///< every channel is bit-identical: one stored
    bool nonDeterministic   = false;  ///< the plugin holds randomness; one performance is frozen
    bool pluginWasBypassed  = false;  ///< traced while bypassed: g == 1, d == 0. Almost certainly a mistake.
    bool hasAutomation      = false;  ///< the plugin carries automation over the span

    // Measurements
    Residual determinismY;          ///< y1 - y2: the plugin's own randomness
    Residual determinismX;          ///< x1 - x2: everything UPSTREAM of it
    Residual validation;            ///< g·x + d - y, read back THROUGH the file
    /// The fingerprint of x, for invalidation. Empty when the x null test failed: there is then
    /// no stable input to take the hash of, and staleness can no longer be detected.
    std::string inputHash;

    double capturedAt = 0.0;        ///< seconds since 1970
};

//==============================================================================
/** A whole trace: the header plus, per stored channel, its two signals. */
struct Trace
{
    Header header;
    std::vector<Signal> g;   ///< one per stored channel
    std::vector<Signal> d;   ///< empty when `multiplicativeOnly`
};

//==============================================================================
// The on-disk format.
//
//   "OBJTRACE" (8 bytes) · uint32 formatVersion · uint32 headerJsonLength · headerJson
//   then, per stored channel: signal g, then signal d (only if !multiplicativeOnly)
//   a signal being: double defaultValue · uint32 numSegments
//                   · numSegments × { uint64 start; uint64 length; }
//                   · double × (the segments' total length), in segment order
//
// Little-endian throughout. Both architectures OBJEKAT ships (arm64, x86_64) are
// little-endian; a big-endian reader would have to swap, and the magic is there to tell it
// which file it is looking at.

static constexpr uint32_t kFormatVersion = 1;
static constexpr char     kMagic[8] = { 'O','B','J','T','R','A','C','E' };

/// The extension of a trace file beside the session.
inline const char* fileExtension() { return ".objtrace"; }

//==============================================================================
inline juce::var headerToVar (const Header& h)
{
    auto* o = new juce::DynamicObject();

    o->setProperty ("slot_id",           juce::String (h.slotID));
    o->setProperty ("plugin_name",       juce::String (h.pluginName));
    o->setProperty ("plugin_identifier", juce::String (h.pluginIdentifier));
    o->setProperty ("plugin_format",     juce::String (h.pluginFormat));
    o->setProperty ("plugin_version",    juce::String (h.pluginVersion));

    o->setProperty ("sample_rate",     h.sampleRate);
    o->setProperty ("num_channels",    h.numChannels);
    o->setProperty ("stored_channels", h.storedChannels);
    o->setProperty ("block_size",      h.blockSize);

    o->setProperty ("region_start",     h.regionStart);
    o->setProperty ("region_end",       h.regionEnd);
    o->setProperty ("tail_seconds",     h.tailSeconds);
    o->setProperty ("pre_roll_seconds", h.preRollSeconds);
    o->setProperty ("num_samples",      (juce::int64) h.numSamples);

    o->setProperty ("latency_samples",         h.latencySamples);
    o->setProperty ("correlation_lag_samples", h.correlationLagSamples);
    o->setProperty ("fractional_latency",      h.fractionalLatency);

    o->setProperty ("g_max",     h.gMax);
    o->setProperty ("x_min_db",  h.xMinDbfs);
    o->setProperty ("merge_gap", (juce::int64) h.mergeGap);

    o->setProperty ("multiplicative_only", h.multiplicativeOnly);
    o->setProperty ("linked",              h.linked);
    o->setProperty ("non_deterministic",   h.nonDeterministic);
    o->setProperty ("plugin_was_bypassed", h.pluginWasBypassed);
    o->setProperty ("has_automation",      h.hasAutomation);

    o->setProperty ("determinism_y_peak_db", h.determinismY.peakDbfs);
    o->setProperty ("determinism_y_rms_db",  h.determinismY.rmsDbfs);
    o->setProperty ("determinism_x_peak_db", h.determinismX.peakDbfs);
    o->setProperty ("determinism_x_rms_db",  h.determinismX.rmsDbfs);
    o->setProperty ("validation_peak_db",    h.validation.peakDbfs);
    o->setProperty ("validation_rms_db",     h.validation.rmsDbfs);

    o->setProperty ("input_hash",  juce::String (h.inputHash));
    o->setProperty ("captured_at", h.capturedAt);

    return juce::var (o);
}

inline Header headerFromVar (const juce::var& v)
{
    Header h;
    if (auto* o = v.getDynamicObject())
    {
        auto str = [o] (const char* k) { return o->getProperty (k).toString().toStdString(); };
        auto dbl = [o] (const char* k, double dflt) {
            auto p = o->getProperty (k); return p.isVoid() ? dflt : (double) p; };
        auto igr = [o] (const char* k, int dflt) {
            auto p = o->getProperty (k); return p.isVoid() ? dflt : (int) p; };
        auto flg = [o] (const char* k) { return (bool) o->getProperty (k); };

        h.slotID           = str ("slot_id");
        h.pluginName       = str ("plugin_name");
        h.pluginIdentifier = str ("plugin_identifier");
        h.pluginFormat     = str ("plugin_format");
        h.pluginVersion    = str ("plugin_version");

        h.sampleRate     = dbl ("sample_rate", 0.0);
        h.numChannels    = igr ("num_channels", 0);
        h.storedChannels = igr ("stored_channels", h.numChannels);
        h.blockSize      = igr ("block_size", 0);

        h.regionStart     = dbl ("region_start", 0.0);
        h.regionEnd       = dbl ("region_end", 0.0);
        h.tailSeconds     = dbl ("tail_seconds", 0.0);
        h.preRollSeconds  = dbl ("pre_roll_seconds", 0.0);
        h.numSamples      = (uint64_t) std::max (0.0, dbl ("num_samples", 0.0));

        h.latencySamples        = igr ("latency_samples", 0);
        h.correlationLagSamples = dbl ("correlation_lag_samples", 0.0);
        h.fractionalLatency     = flg ("fractional_latency");

        h.gMax     = dbl ("g_max", kDefaultGMax);
        h.xMinDbfs = dbl ("x_min_db", kDefaultXMinDbfs);
        h.mergeGap = (uint64_t) std::max (1.0, dbl ("merge_gap", (double) kDefaultMergeGap));

        h.multiplicativeOnly = flg ("multiplicative_only");
        h.linked             = flg ("linked");
        h.nonDeterministic   = flg ("non_deterministic");
        h.pluginWasBypassed  = flg ("plugin_was_bypassed");
        h.hasAutomation      = flg ("has_automation");

        h.determinismY.peakDbfs = dbl ("determinism_y_peak_db", kSilenceDbfs);
        h.determinismY.rmsDbfs  = dbl ("determinism_y_rms_db",  kSilenceDbfs);
        h.determinismX.peakDbfs = dbl ("determinism_x_peak_db", kSilenceDbfs);
        h.determinismX.rmsDbfs  = dbl ("determinism_x_rms_db",  kSilenceDbfs);
        h.validation.peakDbfs   = dbl ("validation_peak_db",    kSilenceDbfs);
        h.validation.rmsDbfs    = dbl ("validation_rms_db",     kSilenceDbfs);

        h.inputHash  = str ("input_hash");
        h.capturedAt = dbl ("captured_at", 0.0);
    }
    return h;
}

//==============================================================================
namespace detail {

template <typename T>
inline void put (juce::MemoryOutputStream& out, T value)
{
    static_assert (std::is_trivially_copyable_v<T>, "raw write");
    out.write (&value, sizeof (T));
}

template <typename T>
inline bool take (juce::MemoryInputStream& in, T& value)
{
    return in.read (&value, (int) sizeof (T)) == (int) sizeof (T);
}

inline void writeSignal (juce::MemoryOutputStream& out, const Signal& s)
{
    put<double> (out, s.defaultValue);
    put<uint32_t> (out, (uint32_t) s.segments.size());

    for (const auto& seg : s.segments)
    {
        put<uint64_t> (out, seg.start);
        put<uint64_t> (out, seg.length);
    }

    if (! s.data.empty())
        out.write (s.data.data(), s.data.size() * sizeof (double));
}

inline bool readSignal (juce::MemoryInputStream& in, Signal& s)
{
    uint32_t numSegments = 0;
    if (! take (in, s.defaultValue) || ! take (in, numSegments))
        return false;

    s.segments.clear();
    s.segments.reserve (numSegments);

    uint64_t total = 0;
    for (uint32_t i = 0; i < numSegments; ++i)
    {
        Signal::Segment seg;
        if (! take (in, seg.start) || ! take (in, seg.length))
            return false;
        seg.offset = total;
        total += seg.length;
        s.segments.push_back (seg);
    }

    s.data.assign ((size_t) total, 0.0);
    if (total > 0 && in.read (s.data.data(), (int) (total * sizeof (double)))
                        != (int) (total * sizeof (double)))
        return false;

    s.rewind();
    return true;
}

} // namespace detail

//==============================================================================
/** Serialises a whole trace. */
inline juce::MemoryBlock serialise (const Trace& t)
{
    juce::MemoryBlock block;
    juce::MemoryOutputStream out (block, false);

    out.write (kMagic, sizeof (kMagic));
    detail::put<uint32_t> (out, kFormatVersion);

    const auto json = juce::JSON::toString (headerToVar (t.header), true);
    const auto utf8 = json.toRawUTF8();
    const auto len  = (uint32_t) std::strlen (utf8);
    detail::put<uint32_t> (out, len);
    out.write (utf8, len);

    for (size_t c = 0; c < t.g.size(); ++c)
    {
        detail::writeSignal (out, t.g[c]);
        if (! t.header.multiplicativeOnly && c < t.d.size())
            detail::writeSignal (out, t.d[c]);
    }

    out.flush();
    return block;
}

/** Reads one back. Returns false — leaving `t` untouched — on anything that is not a trace
    file this version understands. */
inline bool deserialise (const void* data, size_t numBytes, Trace& t)
{
    if (data == nullptr || numBytes < sizeof (kMagic) + 8)
        return false;

    juce::MemoryInputStream in (data, numBytes, false);

    char magic[sizeof (kMagic)] = {};
    if (in.read (magic, (int) sizeof (magic)) != (int) sizeof (magic)
        || std::memcmp (magic, kMagic, sizeof (kMagic)) != 0)
        return false;

    uint32_t version = 0, headerLength = 0;
    if (! detail::take (in, version) || version > kFormatVersion)
        return false;
    if (! detail::take (in, headerLength))
        return false;

    std::string json ((size_t) headerLength, '\0');
    if (headerLength > 0 && in.read (json.data(), (int) headerLength) != (int) headerLength)
        return false;

    Trace loaded;
    loaded.header = headerFromVar (juce::JSON::parse (juce::String::fromUTF8 (json.c_str(),
                                                                             (int) headerLength)));

    const int channels = std::max (1, loaded.header.storedChannels);
    for (int c = 0; c < channels; ++c)
    {
        Signal g;
        if (! detail::readSignal (in, g))
            return false;
        loaded.g.push_back (std::move (g));

        if (! loaded.header.multiplicativeOnly)
        {
            Signal d;
            if (! detail::readSignal (in, d))
                return false;
            loaded.d.push_back (std::move (d));
        }
    }

    t = std::move (loaded);
    return true;
}

inline bool writeToFile (const Trace& t, const juce::File& file)
{
    const auto block = serialise (t);
    return file.replaceWithData (block.getData(), block.getSize());
}

inline bool readFromFile (const juce::File& file, Trace& t)
{
    juce::MemoryBlock block;
    if (! file.existsAsFile() || ! file.loadFileAsData (block))
        return false;
    return deserialise (block.getData(), block.getSize(), t);
}

//==============================================================================
/** The fingerprint of the input signal, for invalidation.

    A hash of the float32 samples exactly as they were captured — that is what "the same input"
    means here, and hashing anything reconstructed would only measure our own arithmetic.

    FNV-1a rather than a cryptographic digest, and written out by hand rather than pulled from
    juce_cryptography: the module is not among those OBJEKAT compiles, and adding a whole module
    to hash a buffer would be a poor trade. Nothing here defends against a forged trace — this
    only has to notice that the signal upstream is no longer the one that was captured, and two
    64-bit passes with different offsets make an accidental collision a non-event.
*/
inline std::string fingerprint (const float* const* channels, int numChannels, uint64_t numSamples)
{
    constexpr uint64_t prime = 0x100000001b3ull;
    uint64_t a = 0xcbf29ce484222325ull;   // the canonical FNV-1a offset basis
    uint64_t b = 0x9e3779b97f4a7c15ull;   // a second basis: the same bytes, a different walk

    for (int c = 0; c < numChannels; ++c)
    {
        const auto* bytes = reinterpret_cast<const unsigned char*> (channels[c]);
        const size_t numBytes = (size_t) numSamples * sizeof (float);

        for (size_t i = 0; i < numBytes; ++i)
        {
            a = (a ^ bytes[i]) * prime;
            b = (b ^ (uint64_t) (bytes[i] + (unsigned char) (i & 0xff))) * prime;
        }
    }

    char out[33] = {};
    std::snprintf (out, sizeof (out), "%016llx%016llx",
                   (unsigned long long) a, (unsigned long long) b);
    return std::string (out);
}

//==============================================================================
/** Cross-correlation of `x` and `y` around lag 0, over a window chosen for its transients.

    What it is FOR is worth stating, because it is not what a first reading suggests. The affine
    model is exact at every sample WHATEVER the alignment — g and d are solved from the same
    pair (x[n], y[n]), so `g·x + d` reproduces `y` even if `y` was captured half a sample late.
    A misalignment therefore does not break the reconstruction; what it breaks is the trace's
    QUALITY: `g` stops being near 1 and starts swinging over orders of magnitude, the clamp
    tips everything into `d`, the run-length encoding finds nothing to compress and the file
    grows by a factor of ten. So this measurement is a diagnostic on the capture's health, and
    the reason to refuse is economy and conditioning, not correctness.

    Returns the lag, in samples, at which y best matches x — fractional through a parabolic fit
    on the three points around the integer peak.
*/
inline double correlationLag (const float* x, const float* y, uint64_t numSamples, int maxLag = 256)
{
    if (x == nullptr || y == nullptr || numSamples < 64 || maxLag < 1)
        return 0.0;

    // The search has to fit inside the buffer with room on BOTH sides, and the arithmetic below
    // is unsigned: `numSamples - maxLag` on a region shorter than the search would wrap to an
    // enormous number and walk off the end. A quarter of the length leaves the window something
    // to correlate over.
    maxLag = (int) std::min<uint64_t> ((uint64_t) maxLag, numSamples / 4);
    if (maxLag < 1)
        return 0.0;

    // Centre the window on the strongest transient of x: a steady tone correlates equally well
    // at every lag, and would make the measurement meaningless.
    const uint64_t window = std::min<uint64_t> (numSamples, 8192);
    uint64_t centre = numSamples / 2;
    double bestSlope = 0.0;

    for (uint64_t i = 1; i < numSamples; ++i)
    {
        const double slope = std::abs ((double) x[i] - (double) x[i - 1]);
        if (slope > bestSlope) { bestSlope = slope; centre = i; }
    }

    const uint64_t half  = window / 2;
    const uint64_t start = (centre > half + (uint64_t) maxLag) ? centre - half : (uint64_t) maxLag;
    const uint64_t end   = std::min (numSamples - (uint64_t) maxLag, start + window);
    if (end <= start)
        return 0.0;

    auto correlationAt = [&] (int lag)
    {
        double sum = 0.0;
        for (uint64_t i = start; i < end; ++i)
            sum += (double) x[i] * (double) y[(uint64_t) ((int64_t) i + lag)];
        return sum;
    };

    int    bestLag = 0;
    double best    = -std::numeric_limits<double>::max();
    for (int lag = -maxLag; lag <= maxLag; ++lag)
    {
        const double c = std::abs (correlationAt (lag));
        if (c > best) { best = c; bestLag = lag; }
    }

    if (bestLag <= -maxLag || bestLag >= maxLag)
        return (double) bestLag;

    // Parabolic interpolation on the peak and its two neighbours: a sub-sample estimate is what
    // tells an internally oversampled plugin from a well-behaved one.
    const double left  = std::abs (correlationAt (bestLag - 1));
    const double right = std::abs (correlationAt (bestLag + 1));
    const double denom = left - 2.0 * best + right;
    const double delta = (denom != 0.0) ? 0.5 * (left - right) / denom : 0.0;

    return (double) bestLag + std::clamp (delta, -0.5, 0.5);
}

//==============================================================================
/** Turns one channel's captures into its two signals.

    `dFree` may be null — that is the non-deterministic mode, where pass A is deliberately NOT
    run: the realisation captured on silence would be a different draw from the one in pass B,
    and subtracting it would ADD a second source of noise instead of removing one. The noise
    then rides in the numerator and gets frozen into `g`, which is the point.

    The branches, in order, each sample falling in exactly one:

      |x| < xMin  → GATE.  g = 1, d = num - x.
                    This is where a plugin produces signal out of silence: noise, a tail, hum.
                    Without the gate, g has to explode to represent it and the clamp below tips
                    the whole thing into d anyway — the right answer, reached by accident,
                    through absurd intermediate values.
      |num/x| > gMax → CLAMP. g = ±gMax, d = num - g·x.
      otherwise      → g = num/x, d = dFree (or 0).
*/
inline void computeChannel (const float* y, const float* x, const float* dFree,
                            uint64_t numSamples,
                            double gMax, double xMin,
                            std::vector<double>& gOut, std::vector<double>& dOut)
{
    gOut.assign ((size_t) numSamples, 1.0);
    dOut.assign ((size_t) numSamples, 0.0);

    for (uint64_t n = 0; n < numSamples; ++n)
    {
        const double xn   = (double) x[n];
        const double free = dFree != nullptr ? (double) dFree[n] : 0.0;
        const double num  = (double) y[n] - free;

        // A plugin that emits a NaN or an infinity poisons everything downstream of it: the
        // ratio becomes NaN, the run-length encoding cannot compare it against its default
        // (NaN equals nothing, not even itself), the read-back check reports a mismatch that is
        // not one, and the restitution would replay the NaN into the mix for ever. We refuse to
        // carry it: g = 1 and d = 0 makes the trace transparent at that sample, which is the
        // one honest answer to a value that means nothing.
        if (! std::isfinite (num) || ! std::isfinite (xn))
        {
            gOut[(size_t) n] = 1.0;
            dOut[(size_t) n] = 0.0;
            continue;
        }

        if (std::abs (xn) < xMin)
        {
            gOut[(size_t) n] = 1.0;
            dOut[(size_t) n] = num - xn;
            continue;
        }

        const double ratio = num / xn;

        if (! std::isfinite (ratio) || std::abs (ratio) > gMax)
        {
            const double clamped = std::copysign (gMax, ratio);
            gOut[(size_t) n] = clamped;
            dOut[(size_t) n] = num - clamped * xn;
            continue;
        }

        gOut[(size_t) n] = ratio;
        dOut[(size_t) n] = free;
    }
}

} // namespace objtrace
