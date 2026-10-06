// BridgeScope (`Shared/BridgeScope.swift`) — the bridge's scope, cycle and rank rules, asserted with
// no screen against the SAME case table the Python mirror reads (tools/fixtures/
// bridge_scope_cases.json). Ids in the table are short names; they are mapped here to deterministic
// UUIDs, in order of first appearance.
//
//     swiftc -parse-as-library objekat/Shared/BridgeScope.swift tools/test_bridge_scope.swift \
//         -o /tmp/bs && /tmp/bs [path/to/bridge_scope_cases.json]
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

/// Short names → deterministic UUIDs ("00000000-0000-0000-0000-" + 12 hex digits of a counter).
final class Names {
    private var map: [String: UUID] = [:]
    private var reverse: [UUID: String] = [:]

    func id(_ name: String) -> UUID {
        if let u = map[name] { return u }
        let u = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", map.count + 1))!
        map[name] = u
        reverse[u] = name
        return u
    }

    func name(_ id: UUID) -> String { reverse[id] ?? id.uuidString }
}

func decodeNodes(_ raw: [[String: Any]], _ names: Names) -> [BridgeScope.Node] {
    raw.map { n in
        BridgeScope.Node(id: names.id(n["id"] as! String),
                         kind: BridgeScope.Kind(rawValue: n["kind"] as! String)!,
                         parent: (n["parent"] as? String).map { names.id($0) },
                         stem: (n["stem"] as? String).map { names.id($0) })
    }
}

func decodeRoutes(_ raw: [[String: Any]], _ names: Names) -> [BridgeScope.Route] {
    raw.map { r in
        let c = r["consumer"] as! [String: Any]
        let who = names.id(c["id"] as! String)
        let consumer: BridgeScope.Consumer = (c["kind"] as! String) == "sidechain" ? .sidechain(plugin: who) : .auxInput(sender: who)
        return BridgeScope.Route(source: names.id(r["source"] as! String), host: names.id(r["host"] as! String), consumer: consumer)
    }
}

func byName(_ d: [UUID: Int], _ names: Names) -> [String: Int] {
    var out: [String: Int] = [:]
    for (k, v) in d { out[names.name(k)] = v }
    return out
}

func expectedInts(_ any: Any?) -> [String: Int] {
    var out: [String: Int] = [:]
    for (k, v) in (any as? [String: Any] ?? [:]) { out[k] = (v as! NSNumber).intValue }
    return out
}

@main
enum BridgeScopeTest {
  static func main() {
    let path: String
    if CommandLine.arguments.count > 1 {
        path = CommandLine.arguments[1]
    } else {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        path = here.appendingPathComponent("fixtures/bridge_scope_cases.json").path
    }
    guard let data = FileManager.default.contents(atPath: path),
          let table = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cases = table["cases"] as? [[String: Any]] else {
        print("FAIL  cannot read the case table at \(path)")
        exit(1)
    }

    for c in cases {
        let label = c["name"] as! String
        let names = Names()
        let nodes = decodeNodes(c["nodes"] as! [[String: Any]], names)
        let routes = decodeRoutes(c["routes"] as! [[String: Any]], names)
        let expect = c["expect"] as! [String: Any]
        let plan = BridgeScope.plan(nodes: nodes, routes: routes)

        var refused: [String: String] = [:]
        for (i, why) in plan.refused { refused[String(i)] = why.rawValue }
        var wantRefused: [String: String] = [:]
        for (k, v) in (expect["refused"] as? [String: Any] ?? [:]) { wantRefused[k] = v as? String }

        var readers: [String: Int] = [:]
        for (i, r) in plan.readerRanks { readers[String(i)] = r }

        let got: [(String, Bool)] = [
            ("refused", refused == wantRefused),
            ("rootRanks", byName(plan.rootRanks, names) == expectedInts(expect["rootRanks"])),
            ("auxRanks", byName(plan.auxRanks, names) == expectedInts(expect["auxRanks"])),
            ("innerRanks", byName(plan.innerRanks, names) == expectedInts(expect["innerRanks"])),
            ("stemRanks", byName(plan.stemRanks, names) == expectedInts(expect["stemRanks"])),
            ("readerRanks", readers == expectedInts(expect["readerRanks"])),
            ("taps", byName(plan.taps, names) == expectedInts(expect["taps"])),
        ]
        let bad = got.filter { !$0.1 }.map { $0.0 }
        check(label, bad.isEmpty, "differs on: \(bad.joined(separator: ", "))")

        for q in (c["candidates"] as? [[String: Any]] ?? []) {
            let host = names.id(q["host"] as! String)
            let replacing = (q["replacing"] as? NSNumber)?.intValue
            let result = BridgeScope.candidates(host: host, nodes: nodes, routes: routes, replacing: replacing)
            var gotC: [String: String] = [:]
            for r in result { gotC[names.name(r.id)] = r.refusal?.rawValue ?? "-" }
            var wantC: [String: String] = [:]
            for (k, v) in (q["expect"] as! [String: Any]) { wantC[k] = (v as? String) ?? "-" }
            check("\(label) / candidates for \(q["host"] as! String) (replacing \(replacing.map(String.init) ?? "nil"))",
                  gotC == wantC, "got \(gotC), wanted \(wantC)")
        }
    }

    print("\n\(total) assertions, \(fails.count) failed")
    print(fails.isEmpty ? "ALL PASS" : "FAILED")
    exit(fails.isEmpty ? 0 : 1)
  }
}
