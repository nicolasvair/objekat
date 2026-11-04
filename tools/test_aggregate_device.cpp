// The pure half of the private aggregate (`objekat/Shared/OBJAggregateDevice.h`): the channel windows
// by list order, the masking of our own name, the no-combiner guard. With `--live` it also builds a
// real aggregate out of the system's default output and a microphone-capable card and checks the
// windows against what the HAL shows (property queries and creation only: no IO, no microphone
// prompt), then destroys it.
//
//     clang++ -std=c++17 -I objekat/Shared tools/test_aggregate_device.cpp \
//         -framework CoreAudio -framework CoreFoundation -o /tmp/tad && /tmp/tad [--live]
//
// Exit: 0 if every assertion passes, 1 otherwise.

#include "OBJAggregateDevice.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace objaggregate;

static int total = 0;
static std::vector<std::string> fails;

static void check(const std::string& label, bool ok)
{
    ++total;
    if (!ok) { fails.push_back(label); std::printf("  FAIL %s\n", label.c_str()); }
}

int main(int argc, char** argv)
{
    const Card speakers  { "spk", "Speakers", 0, 2 };
    const Card mic       { "mic", "Microphone", 1, 0 };
    const Card interface { "itf", "Interface", 8, 8 };     // a card with both sides
    const Card blackhole { "bh", "BlackHole", 16, 16 };

    // Windows: the input card is listed first, the output card (the master) second.
    auto w = window(speakers, mic);
    check("speakers + mic: the input window starts at 0", w.inFirst == 0 && w.inCount == 1);
    check("speakers + mic: the output window is the speakers' (the mic has no outputs)", w.outFirst == 0 && w.outCount == 2);
    check("speakers + mic: valid", w.valid);

    w = window(interface, mic);
    check("interface + mic: inputs are the mic's alone, at 0", w.inFirst == 0 && w.inCount == 1);
    check("interface + mic: outputs are the whole of the interface's", w.outFirst == 0 && w.outCount == 8);

    w = window(speakers, interface);
    check("the input card's own outputs sit BEFORE the output window", w.outFirst == 8 && w.outCount == 2);
    check("... and its inputs are all of the input window", w.inFirst == 0 && w.inCount == 8);

    w = window(interface, blackhole);
    check("blackhole in, interface out: J = 16", w.outFirst == 16 && w.outCount == 8 && w.inFirst == 0 && w.inCount == 16);

    check("no input channel: invalid", !window(speakers, speakers).valid);
    check("no output channel: invalid", !window(mic, mic).valid);

    check("expected inputs", expectedInputs(interface, mic) == 9);
    check("expected outputs", expectedOutputs(interface, blackhole) == 24);
    check("sub-device list order: input first", subDeviceUIDs(speakers, mic) == std::vector<std::string>({ "mic", "spk" }));

    // Names.
    const std::string n = makeName(123, 4);
    check("our name is ours", isOurs(n));
    check("a user's card is not", !isOurs("MacBook Pro Speakers") && !isOurs("") && !isOurs("OBJEKAT"));
    check("two serials, two names and two UIDs", makeName(1, 1) != makeName(1, 2) && makeUID(1, 1) != makeUID(1, 2));
    check("the UID never looks like the name", makeUID(1, 1) != makeName(1, 1));
    check("masking removes ours, keeps order",
          withoutOurs({ "A", n, "B", makeName(5, 6) }) == std::vector<std::string>({ "A", "B" }));
    check("masking an empty list", withoutOurs({}).empty());

    // The guard.
    check("same name: no combiner", !wouldCombine(n, n));
    check("two names: combiner", wouldCombine("Speakers", "Microphone"));
    check("no input: no combiner", !wouldCombine("Speakers", ""));
    check("no output: no combiner", !wouldCombine("", "Microphone"));

    if (argc > 1 && std::strcmp(argv[1], "--live") == 0) {
        // The built-in output and any card with inputs but no outputs, or else BlackHole as the input.
        AudioObjectPropertyAddress a { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        UInt32 size = 0;
        AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size);
        std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, ids.data());
        Card out, in;
        bool haveOut = false, haveIn = false;
        for (AudioObjectID id : ids) {
            std::string uid, name;
            if (!detail::stringProp(id, kAudioDevicePropertyDeviceUID, uid)) continue;
            Card c;
            if (!describe(uid, c) || isOurs(c.name)) continue;
            if (!haveOut && c.outputChannels > 0 && c.inputChannels == 0) { out = c; haveOut = true; }
            else if (!haveIn && c.inputChannels > 0 && c.uid != out.uid) { in = c; haveIn = true; }
        }
        if (haveOut && haveIn) {
            std::string err;
            Live h = create(out, in, 1, err);
            check("live: the aggregate is created (" + err + ")", (bool) h);
            if (h) {
                const Window win = window(out, in);
                check("live: the HAL shows the sum of the inputs", detail::channels(h.id, kAudioObjectPropertyScopeInput) == expectedInputs(out, in));
                check("live: the HAL shows the sum of the outputs", detail::channels(h.id, kAudioObjectPropertyScopeOutput) == expectedOutputs(out, in));
                check("live: the window fits the aggregate", win.inFirst + win.inCount <= detail::channels(h.id, kAudioObjectPropertyScopeInput));
                std::string listedName;
                check("live: the aggregate carries our name", detail::stringProp(h.id, kAudioObjectPropertyName, listedName) && isOurs(listedName));
                destroy(h);
                check("live: destroyed", !h);
                // The HAL retires a destroyed aggregate asynchronously: allow it a moment.
                Card gone;
                bool still = true;
                for (int i = 0; i < 40 && still; ++i) {
                    still = describe(makeUID((int) getpid(), 1), gone);
                    if (still) usleep(50 * 1000);
                }
                check("live: gone from the system", !still);
            }
            std::printf("  live: %s (%d out) + %s (%d in)\n", out.name.c_str(), out.outputChannels, in.name.c_str(), in.inputChannels);
        } else {
            std::printf("  live: no suitable pair of cards, skipped\n");
        }
    }

    std::printf("%d/%d assertions passed\n", total - (int) fails.size(), total);
    return fails.empty() ? 0 : 1;
}
