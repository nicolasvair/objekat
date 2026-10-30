// Does the output device carry its own inputs? (`objekat/Shared/OBJCoreAudioProbe.h`) The verdict is
// a PURE function of a list of device descriptions, so the AirPods case (one name, an output-only
// device and an input-only device), several devices of one name and the rest are asserted with no
// card. With `--live` the program also lists what the system declares and the verdict for each
// output device: read-only (property queries, no device is opened, no microphone prompt).
//
//     clang++ -std=c++17 -I objekat/Shared tools/test_coreaudio_probe.cpp \
//         -framework CoreAudio -framework CoreFoundation -o /tmp/cap && /tmp/cap [--live]
//
// Exit: 0 if every assertion passes, 1 otherwise.

#include "OBJCoreAudioProbe.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace objcoreaudio;

static int total = 0;
static std::vector<std::string> fails;

static void check(const std::string& label, bool ok)
{
    ++total;
    if (!ok) { fails.push_back(label); std::printf("  FAIL %s\n", label.c_str()); }
}

static const char* name(Ownership o)
{
    switch (o) {
        case Ownership::ownInputs:      return "ownInputs";
        case Ownership::separateInputs: return "separateInputs";
        case Ownership::noInputs:       return "noInputs";
        case Ownership::noSuchOutput:   return "noSuchOutput";
    }
    return "?";
}

int main(int argc, char** argv)
{
    // An interface with inputs and outputs on ONE device: fine.
    check("interface: own inputs",
          classify({ { "Scarlett 4i4", 4, 4 } }, "Scarlett 4i4") == Ownership::ownInputs);

    // AirPods: one name, two devices — the speaker (output only) and the microphone (input only).
    const std::vector<DeviceInfo> airpods = { { "AirPods Pro", 2, 0 }, { "AirPods Pro", 0, 1 }, { "MacBook Pro Speakers", 2, 0 } };
    check("AirPods: the inputs are a SEPARATE device", classify(airpods, "AirPods Pro") == Ownership::separateInputs);
    check("AirPods: order of the list does not matter",
          classify({ airpods[1], airpods[2], airpods[0] }, "AirPods Pro") == Ownership::separateInputs);

    // Speakers with no microphone of that name: no inputs at all, nothing owned.
    check("speakers alone: no inputs at all (NOT the AirPods message)",
          classify(airpods, "MacBook Pro Speakers") == Ownership::noInputs);

    // Unknown output.
    check("unknown name: noSuchOutput", classify(airpods, "Nothing") == Ownership::noSuchOutput);
    check("empty list: noSuchOutput", classify({}, "AirPods Pro") == Ownership::noSuchOutput);
    check("an input-only device is not an output", classify({ { "Mic", 0, 2 } }, "Mic") == Ownership::noSuchOutput);

    // Several output-capable devices with the same name: the cautious verdict.
    check("two identical interfaces, both with inputs: own inputs",
          classify({ { "USB Audio", 2, 2 }, { "USB Audio", 2, 2 } }, "USB Audio") == Ownership::ownInputs);
    check("two same-name outputs, one without inputs: separate (cannot tell which one JUCE picks)",
          classify({ { "USB Audio", 2, 2 }, { "USB Audio", 2, 0 } }, "USB Audio") == Ownership::separateInputs);
    check("same name: an input-only twin does not count as output-capable",
          classify({ { "Dock", 2, 2 }, { "Dock", 0, 2 } }, "Dock") == Ownership::ownInputs);

    check("two same-name outputs with no inputs and an input-only twin: separate",
          classify({ { "Pod", 2, 0 }, { "Pod", 2, 0 }, { "Pod", 0, 1 } }, "Pod") == Ownership::separateInputs);
    check("two same-name outputs with no inputs anywhere: no inputs",
          classify({ { "Pod", 2, 0 }, { "Pod", 2, 0 } }, "Pod") == Ownership::noInputs);

    // Padding.
    check("blanks around the name are ignored",
          classify({ { "Scarlett 4i4 ", 4, 4 } }, " Scarlett 4i4") == Ownership::ownInputs);
    check("a different case is a different device", classify({ { "Scarlett", 2, 2 } }, "scarlett") == Ownership::noSuchOutput);

    if (argc > 1 && std::strcmp(argv[1], "--live") == 0) {
        std::printf("\nLive (read-only):\n");
        const auto devices = listDevices();
        for (const auto& d : devices)
            std::printf("  %-40s out %2d  in %2d  -> %s\n", d.name.c_str(), d.outputChannels, d.inputChannels,
                        d.outputChannels > 0 ? name(classify(devices, d.name)) : "(input only)");
        std::printf("  %zu device(s)\n", devices.size());
        check("live: the system lists at least one device", !devices.empty());
    }

    std::printf("%d assertions, %zu failed\n", total, fails.size());
    return fails.empty() ? 0 : 1;
}
