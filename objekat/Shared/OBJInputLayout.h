//
//  OBJInputLayout.h
//  objekat
//
//  How the sound card's INPUT channels are described to the engine, decided from three things — how
//  many channels the card offers, which of them are open right now, and which neighbouring pairs the
//  user declared as stereo. Plain C++17, header only, no JUCE, no Tracktion: there is ONE
//  implementation, called by OBJEngineCore.mm (`OBJEngineBehaviour::describeWaveDevices`) AND by
//  tools/test_input_layout.cpp, so what the test asserts is what the engine describes.
//
//  WHY EVERYTHING IS DESCRIBED UP FRONT. A recording input is either one channel (mono) or two
//  NEIGHBOURING channels (stereo). The engine reads the description when the card (re)opens, and the
//  descriptions may overlap — a channel can belong to a mono device AND to a stereo one, each device
//  reads `allChannels[indexInDevice]` independently. So every possible device is described once:
//
//      N channels  ->  N mono devices  +  (N - 1) stereo devices  =  2N - 1
//
//  and pairing two channels is only a matter of WHICH ones are enabled — the list itself is never
//  rebuilt around a gesture. Order: the monos first (channel 0..N-1), then the pairs (0-1, 1-2, ...).
//
//  ENABLED means "worth opening": a mono is enabled when its channel is open and it is not part of a
//  declared pair; a stereo device is enabled when it is declared and both its channels are open. A
//  declared pair consumes its two channels: 1-2 or 2-3, never both, so an overlap is resolved in
//  favour of the LOWER one and the other is dropped (`validPairs`).
//

#ifndef OBJInputLayout_h
#define OBJInputLayout_h

#include <algorithm>
#include <vector>

namespace objinput {

struct Device {
    int  first   = 0;      // first channel (0-based) in the card
    int  count   = 1;      // 1 = mono, 2 = stereo (first, first + 1)
    bool enabled = false;
};

/// The declared pairs that can actually exist on a card of `numChannels` channels: each is the FIRST
/// channel of a pair (`first`, `first + 1`), both inside the card, and no two overlap. Sorted
/// ascending, duplicates and overlaps dropped (the lower pair wins).
inline std::vector<int> validPairs(int numChannels, std::vector<int> requested)
{
    std::sort(requested.begin(), requested.end());
    std::vector<int> out;
    int nextFree = 0;                                  // first channel not yet consumed by a pair
    for (int first : requested) {
        if (first < 0 || first + 1 >= numChannels) continue;
        if (first < nextFree) continue;                // shares a channel with the pair before it
        out.push_back(first);
        nextFree = first + 2;
    }
    return out;
}

/// `open[i]` is true when channel i of the card is open (empty = nothing is open). The result is the
/// 2N - 1 devices described above (just the one mono for N == 1, nothing for N <= 0).
inline std::vector<Device> describe(int numChannels, const std::vector<bool>& open,
                                    const std::vector<int>& requestedPairs)
{
    std::vector<Device> out;
    if (numChannels <= 0) return out;

    const std::vector<int> pairs = validPairs(numChannels, requestedPairs);
    auto isOpen = [&](int ch) { return ch >= 0 && ch < (int) open.size() && open[(size_t) ch]; };
    auto isPaired = [&](int ch) {
        return std::any_of(pairs.begin(), pairs.end(), [ch](int f) { return ch == f || ch == f + 1; });
    };

    for (int ch = 0; ch < numChannels; ++ch)
        out.push_back({ ch, 1, isOpen(ch) && !isPaired(ch) });

    for (int first = 0; first + 1 < numChannels; ++first) {
        const bool declared = std::find(pairs.begin(), pairs.end(), first) != pairs.end();
        out.push_back({ first, 2, declared && isOpen(first) && isOpen(first + 1) });
    }
    return out;
}

} // namespace objinput

#endif /* OBJInputLayout_h */
