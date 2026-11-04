// The input card's policy (`objekat/Shared/OBJInputCardPolicy.h`): the frequency rule and the
// Bluetooth state machine, asserted with no card and a fake clock.
//
//     clang++ -std=c++17 -I objekat/Shared tools/test_input_card_policy.cpp -o /tmp/tcp && /tmp/tcp
//
// Exit: 0 if every assertion passes, 1 otherwise.

#include "OBJInputCardPolicy.h"
#include <cstdio>
#include <string>
#include <vector>

static int total = 0;
static std::vector<std::string> fails;
static void check(const std::string& label, bool ok)
{
    ++total;
    if (!ok) { fails.push_back(label); std::printf("  FAIL %s\n", label.c_str()); }
}

int main()
{
    using K = OBJInputRateKind;
    // Frequency.
    auto d = objDecideInputRate(48000, 48000, { 44100, 48000 });
    check("already at the rate: left alone", d.kind == K::already && d.rate == 48000);
    d = objDecideInputRate(48000, 48000.4, { 48000 });
    check("within a Hz: already", d.kind == K::already);
    d = objDecideInputRate(48000, 44100, { 44100, 48000, 96000 });
    check("offers it: aligns on the output's", d.kind == K::align && d.rate == 48000);
    d = objDecideInputRate(96000, 16000, { 8000, 16000 });
    check("does not offer it: refused", d.kind == K::refuse && d.rate == 0);
    d = objDecideInputRate(48000, 0, {});
    check("unknown list cannot contradict: aligns", d.kind == K::align);
    d = objDecideInputRate(0, 48000, { 48000 });
    check("no output rate: refused", d.kind == K::refuse);
    d = objDecideInputRate(44100, 44100, {});
    check("already, with no list", d.kind == K::already);

    // Bluetooth machine.
    using S = OBJBluetoothInputState;
    using A = OBJBluetoothAction;
    OBJBluetoothInputMachine m;
    check("starts closed", m.state == S::closed);
    check("closed: nothing to do", m.poll(10) == A::none);
    m.noteChange(10);
    check("a change while closed is ignored", m.state == S::closed);

    m.request(100.0);
    check("request: stabilising", m.state == S::stabilising);
    check("not calm yet", m.poll(100.5) == A::none);
    m.noteChange(100.8);
    check("a change postpones the end", m.poll(101.5) == A::none);
    check("calm for a second: open now", m.poll(101.8) == A::openNow);
    check("still stabilising until told", m.state == S::stabilising);
    m.opened();
    check("opened", m.state == S::open);
    check("open: poll says nothing", m.poll(200) == A::none);
    m.request(300);
    check("request while open: nothing changes", m.state == S::open);
    m.close();
    check("close", m.state == S::closed);

    // A system that never calms down.
    OBJBluetoothInputMachine n;
    n.request(0);
    double t = 0; bool opened = false;
    A act = A::none;
    while (t < 20) {
        t += 0.4;
        n.noteChange(t);                      // a burst every 0.4 s, for ever
        act = n.poll(t);
        if (act != A::none) { opened = act == A::openNow; break; }
    }
    check("never calm: given up, not opened", act == A::giveUp && !opened);
    check("given up at the cap (6 s)", t >= 6.0 && t < 6.5);
    check("state is failed", n.state == S::failed);
    check("failed: poll says nothing", n.poll(t + 5) == A::none);
    n.request(t + 10);
    check("a new request after a failure starts over", n.state == S::stabilising && n.waited(t + 10.5) > 0.4);

    // Failure after openNow.
    OBJBluetoothInputMachine f;
    f.request(0);
    check("calm at once enough? no: needs the second", f.poll(0.5) == A::none && f.poll(1.0) == A::openNow);
    f.failed();
    check("failed() after openNow", f.state == S::failed);
    f.close();
    f.failed();
    check("failed() from closed changes nothing", f.state == S::closed);

    // Absence.
    OBJAbsenceJudge j;
    check("nothing seen: undecided", j.verdict("mic", 0) == OBJPresence::undecided);
    j.note({ "spk", "mic" }, 10);
    check("listed: present", j.verdict("mic", 10) == OBJPresence::present);
    j.note({ "spk" }, 20);
    check("just gone: undecided", j.verdict("mic", 20.5) == OBJPresence::undecided);
    check("gone and the list stable for a second: absent", j.verdict("mic", 21.0) == OBJPresence::absent);
    j.note({ "spk" }, 21.5);
    check("the same list again does not restart the wait", j.verdict("mic", 21.5) == OBJPresence::absent);
    j.note({ "spk", "other" }, 22);
    check("a list that moves restarts the wait", j.verdict("mic", 22.5) == OBJPresence::undecided);
    j.note({ "other", "mic", "spk" }, 23);
    check("back in the list (any order): present", j.verdict("mic", 23) == OBJPresence::present);
    check("another UID, same name is another card", j.verdict("mic2", 30) == OBJPresence::absent);

    std::printf("%d/%d assertions passed\n", total - (int) fails.size(), total);
    return fails.empty() ? 0 : 1;
}
