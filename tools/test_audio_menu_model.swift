// The pure half of the audio menu (`Shared/AudioMenuModel.swift`): its rows, its ticks, what a click means.
//
//     swiftc -parse-as-library ../objekat/Shared/TreePickerPopover.swift ../objekat/Shared/AudioMenuModel.swift \
//         test_audio_menu_model.swift -o /tmp/amm && /tmp/amm
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

func L(_ key: String, _ arguments: CVarArg...) -> String { key }

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) } else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

@main struct Main {
    static func main() {
        let labels = AudioMenuLabels(output: "Output", input: "Input", sameInputCard: "Same card as the output", sampleRate: "Rate", buffer: "Buffer", noOutputDevice: "none")
        var s = AudioMenuState(outputDevices: ["Speakers", "Muse"], currentOutput: "Muse",
                               sampleRates: [44100, 48000, 88200], currentSampleRate: 48000,
                               bufferSizes: [14, 64, 96, 512, 4096], currentBufferSize: 512)
        let secs = AudioMenuModel.sections(s, labels: labels)
        check("four sections", secs.map(\.id) == ["output", "input", "rate", "buffer"])
        check("the open card is ticked, only it", secs[0].nodes.map(\.checked) == [false, true])
        check("the rate is ticked", secs[2].nodes.map(\.checked) == [false, true, false])
        check("useful buffers only", secs[3].nodes.map(\.id) == ["buf:64", "buf:512"])
        check("the buffer is ticked", secs[3].nodes.map(\.checked) == [false, true])
        check("sections are not foldable", secs.allSatisfy { !$0.collapsible })
        check("buffer label has ms", secs[3].nodes[1].name == "512 — 10.7 ms", secs[3].nodes[1].name)

        // a current buffer outside the list is kept
        s.currentBufferSize = 96
        check("current exotic buffer kept and ticked",
              AudioMenuModel.sections(s, labels: labels)[3].nodes.filter(\.checked).map(\.id) == ["buf:96"])
        // exotic device with no power of two
        check("no power of 2: whole list", AudioMenuModel.usefulBufferSizes([14, 96], current: 0) == [14, 96])
        check("nothing at all: nothing", AudioMenuModel.usefulBufferSizes([], current: 0).isEmpty)

        // note under the rates
        s.sampleRateNote = "moved"
        let withNote = AudioMenuModel.sections(s, labels: labels)[2].nodes
        check("a note closes the rates and is not choosable", withNote.last?.role == .note && withNote.last?.isChoosable == false)

        // nothing open
        let none = AudioMenuModel.sections(AudioMenuState(), labels: labels)
        check("no card: the output section stays, with its empty text",
              none.map(\.id) == ["output", "input"] && none[0].nodes.isEmpty && none[0].emptyText == "none")

        // ids round trip, names with colons and decimals
        check("output id round trip", AudioMenuModel.action(forID: AudioMenuModel.outputID("A: B")) == .output("A: B"))
        check("rate id round trip", AudioMenuModel.action(forID: AudioMenuModel.rateID(44100)) == .sampleRate(44100))
        check("fractional rate round trip", AudioMenuModel.action(forID: AudioMenuModel.rateID(22050.5)) == .sampleRate(22050.5))
        check("buffer id round trip", AudioMenuModel.action(forID: AudioMenuModel.bufferID(256)) == .buffer(256))
        check("unknown id", AudioMenuModel.action(forID: "rate.note") == nil && AudioMenuModel.action(forID: "rate:x") == nil)
        check("rate formatting", AudioMenuModel.formatRate(44100) == "44.1 kHz" && AudioMenuModel.formatRate(48000) == "48 kHz")

        // The input section: « same card » first and ticked by default, then the other cards by UID.
        var t = AudioMenuState(outputDevices: ["Muse"], currentOutput: "Muse",
                               inputCards: [AudioMenuInputCard(uid: "uid-A", name: "Scarlett"),
                                            AudioMenuInputCard(uid: "uid-B", name: "Scarlett")])
        var ins = AudioMenuModel.sections(t, labels: labels)[1]
        check("input section is titled and not foldable", ins.title == "Input" && !ins.collapsible)
        check("same card first, ticked by default",
              ins.nodes.map(\.name) == ["Same card as the output", "Scarlett", "Scarlett"]
              && ins.nodes.map(\.checked) == [true, false, false], "\(ins.nodes.map(\.checked))")
        check("two cards with one name stay distinct rows", Set(ins.nodes.map(\.id)).count == 3)
        t.currentInput = "uid-B"
        ins = AudioMenuModel.sections(t, labels: labels)[1]
        check("a chosen card is the one ticked", ins.nodes.map(\.checked) == [false, false, true])
        t.currentInput = "uid-gone"
        ins = AudioMenuModel.sections(t, labels: labels)[1]
        check("a choice no card carries ticks nothing (the engine resets it)", ins.nodes.allSatisfy { !$0.checked })
        t.inputNote = "switching"
        ins = AudioMenuModel.sections(t, labels: labels)[1]
        check("a note closes the input rows and is not choosable", ins.nodes.last?.role == .note && ins.nodes.last?.isChoosable == false)
        check("same-card id means nil", AudioMenuModel.action(forID: AudioMenuModel.inputID(nil)) == .input(nil))
        check("input id round trip (a UID with colons)", AudioMenuModel.action(forID: AudioMenuModel.inputID("AppleUSB:1-2:xyz")) == .input("AppleUSB:1-2:xyz"))
        check("input ids never meet the other prefixes",
              AudioMenuModel.action(forID: AudioMenuModel.outputID("in:x")) == .output("in:x"))

        print("\n\(total - fails.count)/\(total) assertions passed")
        exit(fails.isEmpty ? 0 : 1)
    }
}
