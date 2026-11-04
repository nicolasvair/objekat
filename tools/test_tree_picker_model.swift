// The pure half of the tree picker (`Shared/TreePickerPopover.swift`): what is choosable, what opens
// at first sight, how wide the list must be. No view is built.
//
//     swiftc -parse-as-library ../objekat/Shared/TreePickerPopover.swift test_tree_picker_model.swift -o /tmp/tpm && /tmp/tpm
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

/// The view reads one catalogue key (`L`); the pure half does not, so a stub stands in for it.
func L(_ key: String, _ arguments: CVarArg...) -> String { key }

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) } else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

@main struct Main {
    static func main() {
        // roles
        let choice = TreePickerNode(id: "a", name: "A")
        let refused = TreePickerNode(id: "r", name: "R", disabledReason: "because")
        let head = TreePickerNode.header("h", "Output")
        let note = TreePickerNode.note("n", "text")
        check("a plain row is choosable", choice.isChoosable)
        check("a refused row is not, and keeps its reason", !refused.isChoosable && refused.disabledReason == "because")
        check("a header is not choosable", !head.isChoosable && head.role == .header && !head.selectable)
        check("a note is not choosable", !note.isChoosable && note.role == .note)
        check("selectable false makes a choice unchoosable", !TreePickerNode(id: "x", name: "X", selectable: false).isChoosable)

        // containsChecked / contains(under:)
        let deep = TreePickerNode(id: "g", name: "G", children: [
            TreePickerNode(id: "g1", name: "G1", children: [TreePickerNode(id: "g11", name: "G11", checked: true)]),
            TreePickerNode(id: "g2", name: "G2")])
        check("containsChecked sees a ticked grandchild", deep.containsChecked)
        check("contains(under:) finds the grandchild", TreePickerNode.contains("g11", under: deep))
        check("contains(under:) does not find itself", !TreePickerNode.contains("g", under: deep))
        check("contains(under:) does not find a stranger", !TreePickerNode.contains("zz", under: deep))

        // seed: the groups on the path to the ticked row, the sections that are open or hold it
        let none = TreePickerSection(id: "none", nodes: [TreePickerNode(id: "none", name: "None")])
        let stems = TreePickerSection(id: "stems", title: "Stems", nodes: [TreePickerNode(id: "s1", name: "S1", checked: true)], initiallyOpen: false)
        let stems2 = TreePickerSection(id: "stems2", title: "Stems", nodes: [TreePickerNode(id: "s2", name: "S2")], initiallyOpen: false)
        let objects = TreePickerSection(id: "objects", title: "Objects", nodes: [deep], initiallyOpen: true)
        let seed = TreePickerModel.seed([none, stems, stems2, objects])
        check("seed opens the groups that lead to the ticked row", seed.nodes == ["g", "g1"], "\(seed.nodes)")
        check("seed does not open a group with nothing ticked", !seed.nodes.contains("g2"))
        check("seed opens an initially open section", seed.sections.contains("objects"))
        check("seed opens a folded section that holds the ticked row", seed.sections.contains("stems"))
        check("seed leaves a folded section with nothing ticked folded", !seed.sections.contains("stems2"))

        // width
        let measure: (String) -> CGFloat = { CGFloat($0.count) * 6 }
        let one = TreePickerSection(id: "o", title: "T", nodes: [TreePickerNode(id: "a", name: "abcd")])
        check("widest = a depth-1 row under a titled section",
              TreePickerModel.widest([one], measure: measure) == TreePickerModel.rowWidth(textWidth: 24, depth: 1))
        let untitled = TreePickerSection(id: "u", nodes: [TreePickerNode(id: "a", name: "abcd")])
        check("an untitled section starts at depth 0",
              TreePickerModel.widest([untitled], measure: measure) == TreePickerModel.rowWidth(textWidth: 24, depth: 0))
        let nested = TreePickerSection(id: "n", title: "T", nodes: [TreePickerNode(id: "a", name: "a", children: [
            TreePickerNode(id: "b", name: "a very much longer name")])])
        check("folded children count toward the width, one level deeper",
              TreePickerModel.widest([nested], measure: measure) == TreePickerModel.rowWidth(textWidth: 23 * 6, depth: 2))
        check("no section, no width", TreePickerModel.widest([], measure: measure) == 0)

        // branches: a row that only opens and closes
        let kid = TreePickerNode(id: "k", name: "K", checked: true)
        let br = TreePickerNode.branch("br", "Output", detail: "Muse", children: [kid])
        check("a branch is not choosable, not selectable, role branch",
              !br.isChoosable && !br.selectable && br.role == .branch && br.detail == "Muse" && !br.startsOpen)
        check("a branch sees a ticked child", br.containsChecked)
        let br2 = TreePickerNode.branch("br2", "Rate", detail: nil, startsOpen: true,
                                        children: [TreePickerNode(id: "r1", name: "48 kHz")])
        let br3 = TreePickerNode.branch("br3", "Buffer", detail: "512", children: [TreePickerNode(id: "b1", name: "512")])
        let menu = TreePickerSection(id: "audio", nodes: [br, br2, br3])
        let both = TreePickerModel.seed([menu])
        check("default: a branch holding a ticked row opens, and a startsOpen one", both.nodes == ["br", "br2"], "\(both.nodes)")
        let folded = TreePickerModel.seed([menu], opensCheckedBranches: false)
        check("opensCheckedBranches false: only startsOpen branches open", folded.nodes == ["br2"], "\(folded.nodes)")
        let inner = TreePickerNode(id: "grp", name: "Group", children: [TreePickerNode(id: "leaf", name: "Leaf", checked: true)])
        let withGroup = TreePickerSection(id: "w", nodes: [.branch("brg", "B", detail: nil, children: [inner])])
        check("a group inside a branch still opens on its ticked row",
              TreePickerModel.seed([withGroup], opensCheckedBranches: false).nodes == ["grp"])

        // toggled
        let sib = ["br", "br2", "br3"]
        check("toggled opens a closed branch",
              TreePickerModel.toggled("br", expanded: [], siblings: sib, accordion: true) == ["br"])
        check("toggled closes an open one",
              TreePickerModel.toggled("br", expanded: ["br"], siblings: sib, accordion: true).isEmpty)
        check("accordion: opening one closes its siblings",
              TreePickerModel.toggled("br3", expanded: ["br", "br2"], siblings: sib, accordion: true) == ["br3"])
        check("accordion leaves what is not a sibling",
              TreePickerModel.toggled("br3", expanded: ["br", "grp"], siblings: sib, accordion: true) == ["br3", "grp"])
        check("no accordion: the siblings stay open",
              TreePickerModel.toggled("br3", expanded: ["br", "br2"], siblings: sib, accordion: false) == ["br", "br2", "br3"])

        // width counts the detail
        let withDetail = TreePickerSection(id: "d", nodes: [.branch("b", "abcd", detail: "xy", children: [])])
        check("widest counts a branch's detail after a 12 pt gap",
              TreePickerModel.widest([withDetail], measure: measure) == TreePickerModel.rowWidth(textWidth: 24 + 12 + 12, depth: 0))
        let wideChild = TreePickerSection(id: "e", nodes: [.branch("b", "ab", detail: "x", children: [
            TreePickerNode(id: "c", name: "a child that is much longer than the line")])])
        check("a folded branch's children still count",
              TreePickerModel.widest([wideChild], measure: measure) == TreePickerModel.rowWidth(textWidth: 41 * 6, depth: 1))

        print("\n\(total - fails.count)/\(total) assertions passed")
        exit(fails.isEmpty ? 0 : 1)
    }
}
