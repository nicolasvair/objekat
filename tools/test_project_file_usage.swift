// Which files of a project folder does anything still read? — the arithmetic, asserted with no screen.
//
// `ProjectFileUsage` touches no disk and no model: the sidecar reader and the file listing are
// INJECTED, and the model is reduced to `Ref`. Every case below therefore runs on in-memory data.
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/ProjectFileUsage.swift test_project_file_usage.swift \
//         -o /tmp/tpfu && /tmp/tpfu
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

typealias U = ProjectFileUsage
typealias Ref = ProjectFileUsage.Ref
typealias Def = ProjectFileUsage.DefInfo

let folder = URL(fileURLWithPath: "/Users/n/Projects/P")

func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

func listed(_ rels: [(String, Int64)]) -> [U.Listed] { rels.map { U.Listed(rel: $0.0, size: $0.1) } }

/// A sidecar reader backed by a dictionary keyed by definition id.
func reader(_ table: [UUID: Ref]) -> (Def) -> Ref? { { table[$0.id] } }

func usage(_ items: [Ref], _ defs: [Def], _ sidecars: [UUID: Ref]) -> (U.Closure, U.Usage) {
    let dict = Dictionary(uniqueKeysWithValues: defs.map { ($0.id, $0) })
    let c = U.closure(items: items, defs: dict, readSidecar: reader(sidecars))
    return (c, U.usage(of: c, defs: dict, folder: folder))
}

func ids(_ list: [U.Candidate]) -> Set<String> { Set(list.map(\.id)) }

@main
enum ProjectFileUsageTest {
  static func main() {

    // MARK: - closure

    // 1. Re-bake v1 -> v3: only the registry's CURRENT wave (v3) is used, v1 and v2 are not.
    do {
        let d = id(1)
        let defs = [Def(id: d, wave: "Kick_aaaaaaaa_v3.wav")]
        let (c, u) = usage([Ref(consolidateID: d, filePath: "samples/consolidate/Kick_aaaaaaaa_v3.wav")], defs,
                           [d: Ref(children: [Ref(filePath: "/ext/kick.wav")])])
        check("re-bake: the current wave is reached", c.waves == ["Kick_aaaaaaaa_v3.wav"])
        check("re-bake: v3 and its sidecar are marked",
              u.rel.contains("samples/consolidate/Kick_aaaaaaaa_v3.wav")
              && u.rel.contains("samples/consolidate/Kick_aaaaaaaa_v3_objectstate.json"))
        check("re-bake: v1 and v2 are not marked",
              !u.rel.contains("samples/consolidate/Kick_aaaaaaaa.wav")
              && !u.rel.contains("samples/consolidate/Kick_aaaaaaaa_v2.wav"))
        check("re-bake: the source inside the sidecar is reached", c.sourcePaths == ["/ext/kick.wav"])
        check("re-bake: the instance's own path is recorded", c.instancePaths == ["samples/consolidate/Kick_aaaaaaaa_v3.wav"])
    }

    // 2. Nested consolidated object: A sits inside B's sidecar.
    do {
        let a = id(1), b = id(2)
        let defs = [Def(id: a, wave: "A_11111111.wav"), Def(id: b, wave: "B_22222222.wav")]
        let (c, u) = usage([Ref(consolidateID: b)], defs,
                           [b: Ref(children: [Ref(consolidateID: a)]), a: Ref(filePath: "/ext/a.wav")])
        check("nested: both definitions are visited", Set(c.visitedDefinitions) == [a, b])
        check("nested: both waves are used", c.waves == ["A_11111111.wav", "B_22222222.wav"])
        check("nested: the inner source is reached", c.sourcePaths == ["/ext/a.wav"])
        check("nested: no problem", c.problems.isEmpty && !c.uncertain)
        check("nested: inner wave marked", u.rel.contains("samples/consolidate/A_11111111.wav"))
    }

    // 3. Orphan definition: in the registry, named by nobody.
    do {
        let a = id(1), orphan = id(9)
        let defs = [Def(id: a, wave: "A_11111111.wav"), Def(id: orphan, wave: "Z_99999999.wav")]
        let (c, u) = usage([Ref(consolidateID: a)], defs, [a: Ref(filePath: "/ext/a.wav")])
        check("orphan definition: not visited", !c.visitedDefinitions.contains(orphan))
        check("orphan definition: its wave is not marked", !u.rel.contains("samples/consolidate/Z_99999999.wav"))
    }

    // 4. A group's children are walked; an instance's own children are NOT (it reads the baked wave).
    do {
        let d = id(1)
        let defs = [Def(id: d, wave: "D_11111111.wav")]
        let tree = Ref(children: [Ref(filePath: "/ext/one.wav"),
                                  Ref(children: [Ref(filePath: "/ext/two.wav")]),
                                  Ref(consolidateID: d, filePath: "x.wav", children: [Ref(filePath: "/ext/should-not-count.wav")])])
        let (c, _) = usage([tree], defs, [d: Ref()])
        check("group: nested clip paths reached", c.sourcePaths == ["/ext/one.wav", "/ext/two.wav"])
        check("instance: its materialised children are not walked", !c.sourcePaths.contains("/ext/should-not-count.wav"))
    }

    // 5. Unknown definition and missing sidecar.
    do {
        let known = id(1), unknown = id(7)
        let defs = [Def(id: known, wave: "K_11111111.wav")]
        let (c, _) = usage([Ref(consolidateID: unknown), Ref(consolidateID: known)], defs, [:])
        check("unknown definition is reported", c.problems.contains(.unknownDefinition(unknown)))
        check("missing sidecar is reported", c.problems.contains(.sidecarUnavailable(known)))
        check("missing sidecar makes the closure uncertain", c.uncertain)
        check("unknown definition alone is not uncertain",
              !usage([Ref(consolidateID: unknown)], [], [:]).0.uncertain)
    }

    // 6. Cycle in sidecars cannot loop.
    do {
        let a = id(1), b = id(2)
        let defs = [Def(id: a, wave: "A_11111111.wav"), Def(id: b, wave: "B_22222222.wav")]
        let (c, _) = usage([Ref(consolidateID: a)], defs, [a: Ref(consolidateID: b), b: Ref(consolidateID: a)])
        check("cycle: terminates and visits each once", c.visitedDefinitions.count == 2)
    }

    // 7. Uncertain closure marks EVERY definition of the registry.
    do {
        let a = id(1), b = id(2)
        let defs = [Def(id: a, wave: "A_11111111.wav"), Def(id: b, wave: "B_22222222.wav")]
        let (c, u) = usage([Ref(consolidateID: a)], defs, [:])
        check("uncertain: closure flagged", c.uncertain)
        check("uncertain: the other definition's wave is protected too",
              u.rel.contains("samples/consolidate/B_22222222.wav"))
    }

    // 8. The wave is marked in both consolidate/ and objects/ (twin).
    do {
        let d = id(1)
        let (_, u) = usage([Ref(consolidateID: d)], [Def(id: d, wave: "A_11111111.wav")], [d: Ref()])
        check("twin: the legacy place is marked as well", u.rel.contains("samples/objects/A_11111111.wav")
              && u.rel.contains("samples/objects/A_11111111_objectstate.json"))
    }

    // MARK: - sidecarName

    check("sidecarName from a versioned wave", U.sidecarName(forWave: "Kick_aaaaaaaa_v2.wav") == "Kick_aaaaaaaa_v2_objectstate.json")
    check("sidecarName from an unversioned wave", U.sidecarName(forWave: "Kick_aaaaaaaa.wav") == "Kick_aaaaaaaa_objectstate.json")

    // MARK: - relativeMarks

    check("relative path inside the folder",
          U.relativeMarks(of: "samples/sources/a.wav", folder: folder).contains("samples/sources/a.wav"))
    check("absolute path inside the folder becomes relative",
          U.relativeMarks(of: "/Users/n/Projects/P/samples/sources/a.wav", folder: folder).contains("samples/sources/a.wav"))
    check("an external absolute path names nothing of the folder",
          U.relativeMarks(of: "/Volumes/Sons/kick.wav", folder: folder).isEmpty)
    check("an external file whose name looks like ours is not marked",
          U.relativeMarks(of: "/Volumes/Sons/samples.wav", folder: folder).isEmpty)
    check("a path of ANOTHER project's samples/consolidate is redirected to this folder's",
          U.relativeMarks(of: "/Users/n/Other/samples/consolidate/x.wav", folder: folder).contains("samples/consolidate/x.wav"))
    check("consolidate path also marks the objects twin",
          U.relativeMarks(of: "samples/consolidate/x.wav", folder: folder).contains("samples/objects/x.wav"))
    check("/private/tmp and /tmp are one folder",
          U.relativeMarks(of: "/tmp/p/samples/sources/a.wav", folder: URL(fileURLWithPath: "/private/tmp/p")).contains("samples/sources/a.wav"))
    check("dot-dot is folded",
          U.relativeMarks(of: "/Users/n/Projects/P/samples/../samples/sources/a.wav", folder: folder).contains("samples/sources/a.wav"))
    check("a deeper sub-folder of samples is not redirected",
          !U.relativeMarks(of: "/ext/samples/consolidate/deep/x.wav", folder: folder).contains("samples/consolidate/x.wav"))

    // MARK: - universe

    let listing = listed([
        ("samples/consolidate/Kick_aaaaaaaa_v1.wav", 100),
        ("samples/consolidate/Kick_aaaaaaaa_v1_objectstate.json", 1),
        ("samples/consolidate/Kick_aaaaaaaa_v2.wav", 200),
        ("samples/consolidate/Kick_aaaaaaaa_v2_objectstate.json", 2),
        ("samples/objects/Old_bbbbbbbb.wav", 50),
        ("samples/objects/Old_bbbbbbbb_objectstate.json", 1),
        ("samples/sources/cap.wav", 300),
        ("samples/other/alien.wav", 999),
        ("samples/root.wav", 999),
        ("samples/consolidate/deep/inner.wav", 999),
        ("samples/consolidate/.DS_Store", 6),
        ("waveforms/cap.wav.wfc", 10),
        ("waveforms/Kick_aaaaaaaa_v1.wav.wfc", 20),
        ("waveforms/external.wav.wfc", 30),
        ("waveforms/readme.txt", 7),
        ("notes.txt", 5),
        ("Project.objekat", 400),
    ])
    let uni = U.universe(listing: listing)
    check("universe: files outside the four places are never listed",
          !ids(uni).contains("samples/other/alien.wav") && !ids(uni).contains("samples/root.wav")
          && !ids(uni).contains("samples/consolidate/deep/inner.wav") && !ids(uni).contains("notes.txt")
          && !ids(uni).contains("Project.objekat") && !ids(uni).contains("waveforms/readme.txt"))
    check("universe: dot files are never listed",
          !uni.contains { $0.files.contains { $0.hasSuffix(".DS_Store") } })
    let v1 = uni.first { $0.id == "samples/consolidate/Kick_aaaaaaaa_v1.wav" }
    check("universe: a wave carries its sidecar and its own cache",
          v1?.files == ["samples/consolidate/Kick_aaaaaaaa_v1.wav",
                        "samples/consolidate/Kick_aaaaaaaa_v1_objectstate.json",
                        "waveforms/Kick_aaaaaaaa_v1.wav.wfc"])
    check("universe: the unit's size is the sum of its files", v1?.size == 100 + 1 + 20)
    check("universe: sidecars are not candidates of their own",
          !ids(uni).contains("samples/consolidate/Kick_aaaaaaaa_v1_objectstate.json"))
    check("universe: an embedded source is a candidate with its cache",
          uni.first { $0.id == "samples/sources/cap.wav" }?.files.contains("waveforms/cap.wav.wfc") == true)
    check("universe: a cache of nothing in the universe stands alone",
          uni.first { $0.id == "waveforms/external.wav.wfc" }?.kind == .waveformCache)
    check("universe: the legacy wave is kept as legacy",
          uni.first { $0.id == "samples/objects/Old_bbbbbbbb.wav" }?.kind == .legacyWave)
    check("universe: a wave's cache is not listed twice",
          uni.flatMap(\.files).filter { $0 == "waveforms/Kick_aaaaaaaa_v1.wav.wfc" }.count == 1)
    let stray = U.universe(listing: listed([("samples/consolidate/Lost_cccccccc_objectstate.json", 3)]))
    check("universe: a sidecar whose wave is gone is a stray file",
          stray.count == 1 && stray[0].kind == .strayFile && stray[0].size == 3)

    // MARK: - classify: the scenarios of the brief

    // Session v1 uses Kick v2 only (re-baked once). v1 is an orphan, v2 is used, the cache of v1 goes with v1.
    do {
        let d = id(1)
        let defs = [d: Def(id: d, wave: "Kick_aaaaaaaa_v2.wav")]
        let c = U.closure(items: [Ref(consolidateID: d)], defs: defs, readSidecar: { _ in Ref(filePath: "/ext/cap.wav") })
        let session = U.usage(of: c, defs: defs, folder: folder)
        let r = U.classify(universe: uni, session: session, protected: U.Usage(), others: [])
        check("classify: v2 is used", ids(r.used).contains("samples/consolidate/Kick_aaaaaaaa_v2.wav"))
        check("classify: v1 is unused", ids(r.unused).contains("samples/consolidate/Kick_aaaaaaaa_v1.wav"))
        check("classify: the legacy wave nobody reads is unused", ids(r.unused).contains("samples/objects/Old_bbbbbbbb.wav"))
        check("classify: the buckets partition the universe",
              r.used.count + r.protected.count + r.usedElsewhere.count + r.unused.count == uni.count)
        check("classify: unused bytes add up", r.unusedBytes == r.unused.reduce(0) { $0 + $1.size })
    }

    // The orphan cache vs a shared cache: a .wfc is read when its source's BASENAME is named, wherever it is.
    do {
        let d = id(1)
        let defs = [d: Def(id: d, wave: "Kick_aaaaaaaa_v2.wav")]
        let c = U.closure(items: [Ref(consolidateID: d)], defs: defs,
                          readSidecar: { _ in Ref(filePath: "/Volumes/Sons/external.wav") })
        let session = U.usage(of: c, defs: defs, folder: folder)
        let r = U.classify(universe: uni, session: session, protected: U.Usage(), others: [])
        check("cache: the .wfc of an EXTERNAL source in use is used", ids(r.used).contains("waveforms/external.wav.wfc"))
        let r2 = U.classify(universe: uni, session: U.Usage(), protected: U.Usage(), others: [])
        check("cache: with nothing in use the same .wfc is an orphan", ids(r2.unused).contains("waveforms/external.wav.wfc"))
    }

    // Two versions: session vs folder.
    do {
        let d = id(1)
        let defs = [d: Def(id: d, wave: "Kick_aaaaaaaa_v2.wav")]
        let c = U.closure(items: [Ref(consolidateID: d)], defs: defs, readSidecar: { _ in Ref() })
        let session = U.usage(of: c, defs: defs, folder: folder)
        // Version "V1.objekat" still reads Kick v1.
        let d1 = id(1)
        let defs1 = [d1: Def(id: d1, wave: "Kick_aaaaaaaa_v1.wav")]
        let c1 = U.closure(items: [Ref(consolidateID: d1)], defs: defs1, readSidecar: { _ in Ref() })
        let other = U.OtherVersion(name: "V1.objekat", usage: U.usage(of: c1, defs: defs1, folder: folder))
        let r = U.classify(universe: uni, session: session, protected: U.Usage(), others: [other])
        check("two versions: what another version reads is usedElsewhere, not unused",
              r.usedElsewhere.contains { $0.candidate.id == "samples/consolidate/Kick_aaaaaaaa_v1.wav" && $0.usedBy == ["V1.objekat"] })
        check("two versions: usedElsewhere is never in unused", !ids(r.unused).contains("samples/consolidate/Kick_aaaaaaaa_v1.wav"))
        check("two versions: used by the session wins over usedElsewhere", ids(r.used).contains("samples/consolidate/Kick_aaaaaaaa_v2.wav"))
        let rFolderless = U.classify(universe: uni, session: session, protected: U.Usage(), others: [])
        check("session scope with no other version: the same wave is unused",
              ids(rFolderless.unused).contains("samples/consolidate/Kick_aaaaaaaa_v1.wav"))
        check("usedElsewhere bytes are reported", r.usedElsewhereBytes == 121)
    }

    // Several versions hold the same file: all are named.
    do {
        let holder = U.Usage(rel: ["samples/sources/cap.wav"], names: [])
        let r = U.classify(universe: uni, session: U.Usage(), protected: U.Usage(),
                           others: [U.OtherVersion(name: "A.objekat", usage: holder), U.OtherVersion(name: "B.json", usage: holder)])
        check("used by two versions names both",
              r.usedElsewhere.first { $0.candidate.id == "samples/sources/cap.wav" }?.usedBy == ["A.objekat", "B.json"])
    }

    // THE TWO SCOPES. V1 still reads Kick v1, the session (V2) has moved on to v2.
    do {
        let d = id(1)
        let defs = [d: Def(id: d, wave: "Kick_aaaaaaaa_v2.wav")]
        let c = U.closure(items: [Ref(consolidateID: d)], defs: defs, readSidecar: { _ in Ref() })
        let session = U.usage(of: c, defs: defs, folder: folder)
        let defs1 = [d: Def(id: d, wave: "Kick_aaaaaaaa_v1.wav")]
        let c1 = U.closure(items: [Ref(consolidateID: d)], defs: defs1, readSidecar: { _ in Ref() })
        let other = U.OtherVersion(name: "V1.objekat", usage: U.usage(of: c1, defs: defs1, folder: folder))
        let r = U.classify(universe: uni, session: session, protected: U.Usage(), others: [other])
        let v1 = "samples/consolidate/Kick_aaaaaaaa_v1.wav"
        let sess = r.cleanable(in: .session, unreadableVersions: []) ?? []
        let fold = r.cleanable(in: .folder, unreadableVersions: []) ?? []
        check("scopes: Session offers V1's wave, named usedBy=[V1]",
              ids(sess).contains(v1) && r.usedBy(v1) == ["V1.objekat"])
        check("scopes: Folder does NOT offer it", !ids(fold).contains(v1))
        check("scopes: Session is a superset of Folder", ids(fold).isSubset(of: ids(sess)))
        check("scopes: they differ exactly by what another version reads",
              ids(sess).subtracting(ids(fold)) == ids(r.usedElsewhere.map(\.candidate)) && !r.usedElsewhere.isEmpty)
        check("scopes: the orphans come first in Session (the ones ticked by default)",
              Array(sess.prefix(r.unused.count)) == r.unused)
        check("scopes: a pure orphan has no usedBy", r.usedBy("samples/objects/Old_bbbbbbbb.wav").isEmpty)
        check("scopes: what the session reads is in neither", !ids(sess).contains("samples/consolidate/Kick_aaaaaaaa_v2.wav"))
        // An unreadable version: Session still answers (same list), Folder refuses.
        check("scopes: an unreadable version does not stop Session",
              r.cleanable(in: .session, unreadableVersions: ["broken.objekat"]).map(ids) == ids(sess))
        check("scopes: an unreadable version makes Folder refuse (nil)",
              r.cleanable(in: .folder, unreadableVersions: ["broken.objekat"]) == nil)
        // Protected beats usedElsewhere: never offered, in either scope.
        let prot = U.Usage(rel: [v1], names: [])
        let rp = U.classify(universe: uni, session: session, protected: prot, others: [other])
        check("scopes: protected is offered in NEITHER scope",
              !ids(rp.cleanable(in: .session, unreadableVersions: []) ?? []).contains(v1)
              && !ids(rp.cleanable(in: .folder, unreadableVersions: []) ?? []).contains(v1)
              && ids(rp.protected).contains(v1))
        // Nothing read elsewhere: the scopes coincide.
        let r0 = U.classify(universe: uni, session: session, protected: U.Usage(), others: [])
        check("scopes: with no other version the two coincide",
              r0.cleanable(in: .session, unreadableVersions: []).map(ids) == r0.cleanable(in: .folder, unreadableVersions: []).map(ids))
    }

    // Protected roots (clipboard, other tabs, ongoing bake).
    do {
        let protected = U.Usage(rel: ["samples/consolidate/Kick_aaaaaaaa_v1.wav"], names: [])
        let r = U.classify(universe: uni, session: U.Usage(), protected: protected, others: [])
        check("protected: never offered", !ids(r.unused).contains("samples/consolidate/Kick_aaaaaaaa_v1.wav")
              && ids(r.protected).contains("samples/consolidate/Kick_aaaaaaaa_v1.wav"))
    }

    // Sidecar missing in the folder is not the same thing as a missing sidecar in the model: a wave without its
    // sidecar is still a candidate and is still used when the registry names it.
    do {
        let lone = U.universe(listing: listed([("samples/consolidate/N_dddddddd.wav", 10)]))
        let d = id(5)
        let defs = [d: Def(id: d, wave: "N_dddddddd.wav")]
        let c = U.closure(items: [Ref(consolidateID: d)], defs: defs, readSidecar: { _ in nil })
        let r = U.classify(universe: lone, session: U.usage(of: c, defs: defs, folder: folder), protected: U.Usage(), others: [])
        check("missing sidecar on disk: the wave stays used", ids(r.used).contains("samples/consolidate/N_dddddddd.wav"))
    }

    // A source of the closure living in samples/sources (capsule) is used; an unreferenced one is not.
    do {
        let items = [Ref(filePath: "samples/sources/cap.wav")]
        let (_, u) = usage(items, [], [:])
        let r = U.classify(universe: uni, session: u, protected: U.Usage(), others: [])
        check("capsule source in use is used (cache goes with it)",
              ids(r.used).contains("samples/sources/cap.wav") && r.used.first { $0.id == "samples/sources/cap.wav" }?.files.contains("waveforms/cap.wav.wfc") == true)
    }

    // MARK: - Decoding

    let sessionJSON = """
    {"_readme":"x","version":25,"unknownKey":{"a":1},
     "items":[
       {"id":"\(id(100))","name":"c","kind":{"type":"clip","filePath":"/ext/a.wav"}},
       {"id":"\(id(101))","definitionID":"\(id(1))","kind":{"type":"clip","filePath":"samples/consolidate/Kick_aaaaaaaa_v2.wav"}},
       {"id":"\(id(102))","kind":{"type":"group","children":[]}}
     ],
     "objectDefinitions":[{"id":"\(id(1))","name":"K","wave":"Kick_aaaaaaaa_v2.wav","revision":2,"extra":1}]}
    """
    do {
        let s = try U.decodeSession(Data(sessionJSON.utf8))
        check("decode: items read", s.items.count == 3)
        check("decode: the instance carries its definition id", s.items[1].consolidateID == id(1))
        check("decode: the definition is read", s.defs == [Def(id: id(1), wave: "Kick_aaaaaaaa_v2.wav")])
    } catch { check("decode: session parses", false, "\(error)") }

    check("decode: garbage JSON throws", (try? U.decodeSession(Data("not json".utf8))) == nil)
    check("decode: valid JSON without items throws", (try? U.decodeSession(Data("{\"a\":1}".utf8))) == nil)
    check("looksLikeSession: a session", U.looksLikeSession(Data(sessionJSON.utf8)))
    check("looksLikeSession: a package.json is not a session", !U.looksLikeSession(Data("{\"name\":\"x\"}".utf8)))
    check("looksLikeSession: garbage is not a session", !U.looksLikeSession(Data("zzz".utf8)))

    check("verdict: a session", U.verdict(of: Data(sessionJSON.utf8)) == .session)
    check("verdict: other JSON is not a session", U.verdict(of: Data("{\"name\":\"x\"}".utf8)) == .notASession)
    check("verdict: a JSON array is not a session", U.verdict(of: Data("[1]".utf8)) == .notASession)
    check("verdict: truncated JSON is invalid", U.verdict(of: Data("{\"items\":[".utf8)) == .invalid)
    check("verdict: empty data is invalid", U.verdict(of: Data()) == .invalid)

    // Sidecar decoding: the root object of the sidecar is an object, whose clips and instances are walked.
    do {
        let sidecar = """
        {"id":"\(id(200))","kind":{"type":"group","children":[
            {"id":"\(id(201))","kind":{"type":"clip","filePath":"/ext/inner.wav"}},
            {"id":"\(id(202))","definitionID":"\(id(2))","kind":{"type":"clip","filePath":"samples/consolidate/I_bbbbbbbb.wav"}}]}}
        """
        let ref = try U.decodeSidecar(Data(sidecar.utf8))
        let defs = [id(2): Def(id: id(2), wave: "I_bbbbbbbb.wav")]
        let c = U.closure(items: [ref], defs: defs, readSidecar: { _ in Ref() })
        check("sidecar decode: source and nested instance are reached",
              c.sourcePaths == ["/ext/inner.wav"] && c.waves == ["I_bbbbbbbb.wav"])
    } catch { check("sidecar decode parses", false, "\(error)") }

    check("sidecar decode: garbage throws", (try? U.decodeSidecar(Data("[1,2".utf8))) == nil)

    // End to end: decode a session, run the closure and classify.
    do {
        let s = try U.decodeSession(Data(sessionJSON.utf8))
        let defs = Dictionary(uniqueKeysWithValues: s.defs.map { ($0.id, $0) })
        let c = U.closure(items: s.items, defs: defs, readSidecar: { _ in Ref() })
        let r = U.classify(universe: uni, session: U.usage(of: c, defs: defs, folder: folder), protected: U.Usage(), others: [])
        check("end to end: v2 used, v1 unused",
              ids(r.used).contains("samples/consolidate/Kick_aaaaaaaa_v2.wav")
              && ids(r.unused).contains("samples/consolidate/Kick_aaaaaaaa_v1.wav"))
    } catch { check("end to end parses", false, "\(error)") }

    print("\n\(total - fails.count)/\(total) assertions pass")
    if !fails.isEmpty {
        print("FAILED:"); fails.forEach { print("  - " + $0) }
        exit(1)
    }
  }
}
