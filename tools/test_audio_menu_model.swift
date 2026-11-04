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
        func branches(_ st: AudioMenuState) -> [TreePickerNode] {
            AudioMenuModel.sections(st, labels: labels)[0].nodes
        }
        let secs = AudioMenuModel.sections(s, labels: labels)
        check("one untitled section", secs.count == 1 && secs[0].id == "audio" && secs[0].title == nil)
        let br = branches(s)
        check("four branches, in order", br.map(\.id) == ["branch.output", "branch.input", "branch.rate", "branch.buffer"], "\(br.map(\.id))")
        check("they are branches, never choosable", br.allSatisfy { $0.role == .branch && !$0.isChoosable })
        check("branch names are the labels", br.map(\.name) == ["Output", "Input", "Rate", "Buffer"])
        check("details: card, same input card, rate, buffer",
              br.map(\.detail) == ["Muse", "Same card as the output", "48 kHz", "512 — 10.7 ms"], "\(br.map(\.detail))")
        check("the open card is ticked, only it", br[0].children.map(\.checked) == [false, true])
        check("output children keep their ids", br[0].children.map(\.id) == ["out:Speakers", "out:Muse"])
        check("the rate is ticked", br[2].children.map(\.checked) == [false, true, false])
        check("useful buffers only", br[3].children.map(\.id) == ["buf:64", "buf:512"])
        check("the buffer is ticked", br[3].children.map(\.checked) == [false, true])
        check("no note: no branch starts open", br.allSatisfy { !$0.startsOpen })
        check("the section is not foldable", !secs[0].collapsible)
        check("buffer label has ms", br[3].children[1].name == "512 — 10.7 ms", br[3].children[1].name)
        let folded = TreePickerModel.seed(secs, opensCheckedBranches: false)
        check("the popover opens on four folded lines", folded.nodes.isEmpty, "\(folded.nodes)")

        // a current buffer outside the list is kept
        s.currentBufferSize = 96
        check("current exotic buffer kept and ticked",
              branches(s)[3].children.filter(\.checked).map(\.id) == ["buf:96"])
        check("... and the detail names it", branches(s)[3].detail == "96 — 2.0 ms", "\(String(describing: branches(s)[3].detail))")
        // exotic device with no power of two
        check("no power of 2: whole list", AudioMenuModel.usefulBufferSizes([14, 96], current: 0) == [14, 96])
        check("nothing at all: nothing", AudioMenuModel.usefulBufferSizes([], current: 0).isEmpty)

        // note under the rates: inside its branch, which starts open
        s.sampleRateNote = "moved"
        let rateBranch = branches(s)[2]
        check("a note closes the rates and is not choosable",
              rateBranch.children.last?.role == .note && rateBranch.children.last?.isChoosable == false)
        check("the rate note opens its branch", rateBranch.startsOpen)
        check("... and seed opens it even with the checked-branch rule off",
              TreePickerModel.seed(AudioMenuModel.sections(s, labels: labels), opensCheckedBranches: false).nodes == ["branch.rate"])

        // nothing open
        let none = branches(AudioMenuState())
        check("no card: output and input stay, no rate, no buffer",
              none.map(\.id) == ["branch.output", "branch.input"])
        check("no outputs: a note child, and the detail says none",
              none[0].children.map(\.role) == [.note] && none[0].children[0].name == "none" && none[0].detail == "none")
        check("no rate known: no detail guessed", branches(AudioMenuState(sampleRates: [44100]))[2].detail == nil)

        // ids round trip, names with colons and decimals
        check("output id round trip", AudioMenuModel.action(forID: AudioMenuModel.outputID("A: B")) == .output("A: B"))
        check("rate id round trip", AudioMenuModel.action(forID: AudioMenuModel.rateID(44100)) == .sampleRate(44100))
        check("fractional rate round trip", AudioMenuModel.action(forID: AudioMenuModel.rateID(22050.5)) == .sampleRate(22050.5))
        check("buffer id round trip", AudioMenuModel.action(forID: AudioMenuModel.bufferID(256)) == .buffer(256))
        check("unknown id", AudioMenuModel.action(forID: "rate.note") == nil && AudioMenuModel.action(forID: "rate:x") == nil)
        check("rate formatting", AudioMenuModel.formatRate(44100) == "44.1 kHz" && AudioMenuModel.formatRate(48000) == "48 kHz")

        // The input branch: « same card » first and ticked by default, then the other cards by UID.
        var t = AudioMenuState(outputDevices: ["Muse"], currentOutput: "Muse",
                               inputCards: [AudioMenuInputCard(uid: "uid-A", name: "Scarlett"),
                                            AudioMenuInputCard(uid: "uid-B", name: "Scarlett")])
        var ins = branches(t)[1]
        check("input branch is titled Input", ins.name == "Input" && ins.detail == "Same card as the output")
        check("same card first, ticked by default",
              ins.children.map(\.name) == ["Same card as the output", "Scarlett", "Scarlett"]
              && ins.children.map(\.checked) == [true, false, false], "\(ins.children.map(\.checked))")
        check("two cards with one name stay distinct rows", Set(ins.children.map(\.id)).count == 3)
        t.currentInput = "uid-B"
        ins = branches(t)[1]
        check("a chosen card is the one ticked, and names the branch",
              ins.children.map(\.checked) == [false, false, true] && ins.detail == "Scarlett")
        t.currentInput = "uid-gone"
        ins = branches(t)[1]
        check("a choice no card carries ticks nothing (the engine resets it)", ins.children.allSatisfy { !$0.checked })
        check("... and the detail falls back on the default", ins.detail == "Same card as the output")
        t.inputNote = "switching"
        ins = branches(t)[1]
        check("a note closes the input rows and is not choosable",
              ins.children.last?.role == .note && ins.children.last?.isChoosable == false)
        check("the input note opens its branch", ins.startsOpen)
        check("branch ids match no action", AudioMenuModel.action(forID: "branch.input") == nil
              && AudioMenuModel.action(forID: "branch.output") == nil)
        check("same-card id means nil", AudioMenuModel.action(forID: AudioMenuModel.inputID(nil)) == .input(nil))
        check("input id round trip (a UID with colons)", AudioMenuModel.action(forID: AudioMenuModel.inputID("AppleUSB:1-2:xyz")) == .input("AppleUSB:1-2:xyz"))
        check("input ids never meet the other prefixes",
              AudioMenuModel.action(forID: AudioMenuModel.outputID("in:x")) == .output("in:x"))

        print("\n\(total - fails.count)/\(total) assertions passed")
        exit(fails.isEmpty ? 0 : 1)
    }
}
