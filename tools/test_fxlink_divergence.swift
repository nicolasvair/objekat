// `FXLinkDivergence` — the detection of FX link bins whose members do not sound alike, and the
// repair plan (F4, 4 October 2026), asserted with no screen and no engine on REAL project files
// (read only). Run from `tools/`:
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/SoundObject.swift \
//         ../objekat/SoundObject/Automation.swift \
//         ../objekat/SoundObject/AutomationCurveMath.swift \
//         ../objekat/SoundObject/Marker.swift \
//         ../objekat/SoundObject/ConsolidateDefinition.swift \
//         ../objekat/SoundObject/FadeCurve.swift \
//         ../objekat/SoundObject/ComposedName.swift \
//         ../objekat/SoundObject/ChannelMode.swift \
//         ../objekat/SoundObject/FXLink.swift \
//         ../objekat/Shared/ObjekatPalette.swift \
//         ../objekat/Shared/Localization.swift \
//         ../objekat/App/LaunchArguments.swift \
//         ../objekat/SoundObject/FXLinkDivergence.swift \
//         test_fxlink_divergence.swift \
//         -o /tmp/fxdiv && /tmp/fxdiv '<file>=<expected divergent members>' …
//
// Each argument names a project file and the number of attached members expected to differ from
// their definition (0 for a sound project). For every file with divergences, both repair plans
// are applied to the document IN MEMORY (never written) and the detection must then find nothing;
// a second plan on the repaired document must be empty (idempotence).
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

/// The three keys of a project file this test reads (the app's `ProjectDocument` drags the whole
/// view layer in with it).
struct ProjectDocument: Codable {
    var items: [SoundObject]
    var stems: [Stem]?
    var fxLinks: [FXLink]?
}

/// The app's own lives in `EditViewModel+Types.swift`, which the view layer comes with.
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

/// The plan applied to the document's model, as the app's repair does it (instance states in the
/// hosts' blocks, definition states in the registry).
func applying(_ fixes: [FXLinkDivergence.Fix], to doc: ProjectDocument) -> ProjectDocument {
    var doc = doc
    func patchChain(_ chain: [ObjectPlugin], _ byID: [UUID: String]) -> [ObjectPlugin] {
        chain.map { p in
            var q = p
            if let s = byID[p.id] { q.stateXML = s }
            if var fb = q.fxBlock { fb.plugins = patchChain(fb.plugins, byID); q.fxBlock = fb }
            if q.rack != nil { q = q.mappingChildSeries { patchChain($0, byID) } }
            return q
        }
    }
    var byID: [UUID: String] = [:]
    for f in fixes {
        switch f.target {
        case .instance(_, _, let id): byID[id] = f.stateXML
        case .definition(let linkID, let defID):
            if var links = doc.fxLinks, let i = links.firstIndex(where: { $0.id == linkID }),
               let k = links[i].plugins.firstIndex(where: { $0.id == defID }) {
                links[i].plugins[k].stateXML = f.stateXML
                doc.fxLinks = links
            }
        }
    }
    func walk(_ arr: [SoundObject]) -> [SoundObject] {
        arr.map { o in
            var o = o
            o.plugins = patchChain(o.plugins, byID)
            if case .group(let children, let expanded) = o.kind { o.kind = .group(children: walk(children), isExpanded: expanded) }
            return o
        }
    }
    doc.items = walk(doc.items)
    doc.stems = doc.stems.map { $0.map { s in var s = s; s.plugins = patchChain(s.plugins, byID); return s } }
    return doc
}

func divergentCount(_ doc: ProjectDocument) -> (Int, [FXLinkDivergence.Detail]) {
    let d = FXLinkDivergence.details(items: doc.items, stems: doc.stems ?? [], fxLinks: doc.fxLinks ?? [],
                                     state: { $0.stateXML })
    return (d.reduce(0) { $0 + $1.divergentFromDefinition.count }, d)
}

@main
enum FXLinkDivergenceTest {
    static func main() {
        // MARK: transplant keeps the target's identity
        let a = "<PLUGIN type=\"vst\" id=\"12\" enabled=\"1\" programNum=\"-1\" state=\"3.AAA\" base64:state=\"x\"/>"
        let b = "<PLUGIN type=\"vst\" id=\"99\" enabled=\"0\" programNum=\"4\" state=\"5.BBBBBB\"/>"
        let t = FXLinkDivergence.transplantingState(from: b, into: a)
        check("transplant: the state and program move, the id and enabled stay",
              t.contains("id=\"12\"") && t.contains("enabled=\"1\"") && t.contains(" state=\"5.BBBBBB\"")
                && t.contains("programNum=\"4\"") && t.contains("base64:state=\"x\""), t)

        for arg in CommandLine.arguments.dropFirst() {
            guard let eq = arg.lastIndex(of: "="), let expected = Int(arg[arg.index(after: eq)...]) else {
                check("argument \(arg)", false, "expected <file>=<count>"); continue
            }
            let path = String(arg[..<eq])
            let name = (path as NSString).lastPathComponent
            guard let data = FileManager.default.contents(atPath: path),
                  let doc = try? JSONDecoder().decode(ProjectDocument.self, from: data) else {
                check("\(name): readable", false, path); continue
            }
            let (n, details) = divergentCount(doc)
            let what = details.map { "\($0.linkName)/\($0.pluginName) \($0.divergentFromDefinition.count)/\($0.members.count)" }
            check("\(name): \(expected) member(s) differ from their definition", n == expected,
                  "found \(n): \(what)")
            guard n > 0 else { continue }
            for ref in [FXLinkDivergence.Reference.definition, .majority] {
                let plan = FXLinkDivergence.repairPlan(details, reference: ref, items: doc.items,
                                                       stems: doc.stems ?? [], fxLinks: doc.fxLinks ?? [],
                                                       state: { $0.stateXML })
                let fixed = applying(plan, to: doc)
                let (after, rest) = divergentCount(fixed)
                check("\(name): repair (\(ref.rawValue)) lays \(plan.count) state(s), leaves nothing", after == 0 && rest.isEmpty,
                      "left \(after): \(rest.map { $0.linkName })")
                let again = FXLinkDivergence.repairPlan(rest, reference: ref, items: fixed.items,
                                                        stems: fixed.stems ?? [], fxLinks: fixed.fxLinks ?? [],
                                                        state: { $0.stateXML })
                check("\(name): a second repair (\(ref.rawValue)) has nothing to do", again.isEmpty)
            }
        }

        print("\n\(total) assertion(s), \(fails.count) failed")
        exit(fails.isEmpty ? 0 : 1)
    }
}
