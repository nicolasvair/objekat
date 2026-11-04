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

        print("\n\(total - fails.count)/\(total) assertions passed")
        exit(fails.isEmpty ? 0 : 1)
    }
}
