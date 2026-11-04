//
//  OBJInputCardPolicy.h
//  objekat
//
//  What to do when the INPUT card is not the output card: two decisions taken from numbers, no card
//  and no JUCE. Plain C++17, header only; ONE implementation, called by OBJEngineCore.mm and by
//  tools/test_input_card_policy.cpp, so what the test asserts is what the app decides.
//
//  1. THE FREQUENCY (`objDecideInputRate`). The OUTPUT card decides the project's rate (the
//     sample-rate policy, OBJSampleRatePolicy.h); the input card ALIGNS on it, or the choice is
//     REFUSED with a message — never the other way round, never a silent resampling the user did not
//     ask for. A card already at that rate is left alone; one that offers it is asked to move to it
//     (a CoreAudio nominal rate is the card's, for every application — the same cost as the output's);
//     one that does not offer it is refused.
//
//  2. THE BLUETOOTH MICROPHONE (`OBJBluetoothInputMachine`). Opening the microphone of a Bluetooth
//     headset flips it from music (A2DP) to the call profile (HFP): CoreAudio retires and republishes
//     its devices and changes its rate, a few hundred ms later, in bursts. An aggregate built DURING
//     that would hold devices that are about to vanish. So a Bluetooth input goes through a state
//     machine: closed -> stabilising -> open | failed. In `stabilising` a throw-away IOProc has been
//     started on the microphone to PROVOKE the switch (the engine does that, not this file) and the
//     machine waits for the system to be CALM — no change of the device list, of the rate or of the
//     channel counts for `calm` seconds — then says "open now". A system that never calms down is
//     given up on at `cap` seconds (failed, with the message the interface shows). Every change
//     noticed while stabilising postpones the end of the wait; the cap does not move.
//
//  3. A CARD THAT IS GONE (`OBJAbsenceJudge`). A card that leaves the list is not necessarily gone: a
//     Bluetooth headset republishes its devices when its profile changes, a USB hub blinks. Absence is
//     judged BY UID, and only once the list has been STABLE for `stable` seconds: a UID missing from a
//     list that is still moving is `undecided`, never `absent`.
//
//  The machines know time only through the `now` they are handed (seconds, any origin), so the test
//  drives them with a fake clock.
//

#ifndef OBJInputCardPolicy_h
#define OBJInputCardPolicy_h

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

// MARK: Frequency

enum class OBJInputRateKind { already = 0, align = 1, refuse = 2 };

struct OBJInputRateDecision {
    OBJInputRateKind kind = OBJInputRateKind::refuse;
    double rate = 0;     // the rate the input card should run at (the output's), 0 for a refusal
};

/// `outputRate`: what the output card runs at. `inputRate`: what the input card runs at now (0 =
/// unknown). `available`: the rates it offers (empty = unknown, which cannot contradict).
inline OBJInputRateDecision objDecideInputRate(double outputRate, double inputRate, const std::vector<double>& available)
{
    OBJInputRateDecision d;
    if (outputRate <= 0) return d;                                   // nothing to align on: refuse
    constexpr double tol = 1.0;
    if (inputRate > 0 && std::fabs(inputRate - outputRate) <= tol) {
        d.kind = OBJInputRateKind::already; d.rate = outputRate; return d;
    }
    bool offered = available.empty();
    for (double a : available) if (std::fabs(a - outputRate) <= tol) { offered = true; break; }
    if (offered) { d.kind = OBJInputRateKind::align; d.rate = outputRate; }
    return d;
}

// MARK: Bluetooth

enum class OBJBluetoothInputState { closed = 0, stabilising = 1, open = 2, failed = 3 };

/// What the engine must do after `poll`.
enum class OBJBluetoothAction { none, openNow, giveUp };

struct OBJBluetoothInputMachine {
    double calm = 1.0;       // seconds without a change before the aggregate is built
    double cap  = 6.0;       // seconds after which a system that never calms down is given up on

    OBJBluetoothInputState state = OBJBluetoothInputState::closed;

    /// The user asked to open the Bluetooth input (from closed, or again after a failure).
    void request(double now)
    {
        if (state == OBJBluetoothInputState::stabilising || state == OBJBluetoothInputState::open) return;
        state = OBJBluetoothInputState::stabilising;
        started_ = lastChange_ = now;
    }

    /// The system changed something that matters (device list, rate, channel counts). Only counts
    /// while stabilising: a change while open is the engine's other watchers' business.
    void noteChange(double now)
    {
        if (state == OBJBluetoothInputState::stabilising) lastChange_ = now;
    }

    OBJBluetoothAction poll(double now)
    {
        if (state != OBJBluetoothInputState::stabilising) return OBJBluetoothAction::none;
        if (now - lastChange_ >= calm) return OBJBluetoothAction::openNow;
        if (now - started_ >= cap)     { state = OBJBluetoothInputState::failed; return OBJBluetoothAction::giveUp; }
        return OBJBluetoothAction::none;
    }

    /// The aggregate was built and opened.
    void opened()  { if (state == OBJBluetoothInputState::stabilising) state = OBJBluetoothInputState::open; }
    /// Building or opening it failed after `openNow`.
    void failed()  { if (state == OBJBluetoothInputState::stabilising) state = OBJBluetoothInputState::failed; }
    /// The inputs were closed (by the user, by a change of card, by the card going away).
    void close()   { state = OBJBluetoothInputState::closed; }

    /// Seconds since the request, for a message that says how long it has been waiting.
    double waited(double now) const { return state == OBJBluetoothInputState::stabilising ? now - started_ : 0; }

private:
    double started_ = 0, lastChange_ = 0;
};

// MARK: Absence

enum class OBJPresence { present, absent, undecided };

struct OBJAbsenceJudge {
    double stable = 1.0;     // seconds the list must not have changed before a missing UID is "absent"

    /// The UIDs of the cards the system lists right now (any order).
    void note(std::vector<std::string> uids, double now)
    {
        std::sort(uids.begin(), uids.end());
        if (!seen_ || uids != last_) { last_ = std::move(uids); changedAt_ = now; seen_ = true; }
    }

    OBJPresence verdict(const std::string& uid, double now) const
    {
        if (!seen_) return OBJPresence::undecided;
        if (std::binary_search(last_.begin(), last_.end(), uid)) return OBJPresence::present;
        return now - changedAt_ >= stable ? OBJPresence::absent : OBJPresence::undecided;
    }

private:
    std::vector<std::string> last_;
    double changedAt_ = 0;
    bool seen_ = false;
};

#endif /* OBJInputCardPolicy_h */
