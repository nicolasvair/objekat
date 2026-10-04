import Foundation
import Compression

// MARK: - FX link bins whose members do not sound alike (F4, 4 October 2026)
//
// The members of an FX link are separate engine instances that are SUPPOSED to hold one state —
// the bin's. Files saved by builds before the FX link state fixes (patches 0035/0036, the
// user-origin gate) can carry bins whose members disagree: one member reset to factory values by
// a late plugin notification, a definition that followed whichever member spoke first. Opening
// such a file never repairs it silently (the user's rule): the bin is DETECTED here, the alert
// offers a repair (@see `EditViewModel.askFXLinkDivergenceRepair`), and the repair is one undo.
//
// COMPARING STATES. A raw chunk comparison is useless: two members that sound exactly alike
// differ in their chunks (Pro-Q 4 writes the instance's name at the end of its chunk; TDR Prism
// numbers its instances, `instance="TDR Prism (12)"`). So a state is DECODED down to what the
// plugin plays, per plugin, and anything this file cannot decode is NOT compared — no false
// positive, at the price of not seeing a divergence there:
//   • FabFilter Pro-Q 4 (`aumf,FQ4p,FabF`): the 576 floats of `FabFilterPluginState` (offset 12) —
//     band settings and the switches the host cannot see ("Spectral");
//   • Voxengo PHA-979 (`aufx,1565,Vxng`): the numeric records of `VoxPluginState` (zlib stream) —
//     its AU "data" block is all zeros and says nothing;
//   • any other Audio Unit whose state is a plist with a "data" block: the AU's own parameter
//     list (scope, element, count, then (id, float32) big-endian) — Weiss Deess, Pro-C 2,
//     TDR Prism, ValhallaRoom…;
//   • anything else (VST3, an AU with no "data"): not compared.
// Measured on the user's projects (4 October 2026): CHANTS DE MARIAGE 3N4 → the SHUSH bin's Weiss
// Deess, 2 members of 16; 3M, TEST MEGA CPU and three other projects → nothing.
//
// PURE: no engine, no `L()`, no AppKit. The states are handed in by a closure — the file's
// (`stateXML`, at load) or the live instances' (the API's `fxlink.divergences`).

enum FXLinkDivergence {

    /// Which state a repair lays on the members that differ.
    enum Reference: String {
        /// The definition's (the bin's registry): what a new member is born with.
        case definition
        /// The state most attached members share; the definition takes it too. A tie goes to the
        /// definition's state if it is among the tied ones, otherwise to the earliest member's.
        case majority
    }

    struct Member: Equatable {
        let hostID: UUID
        let hostName: String
        let blockID: UUID
        let instanceID: UUID
        /// Same decoded state as the definition.
        let matchesDefinition: Bool
        /// Index of the member's state class (0 = the largest; ties: definition's class, then the
        /// earliest member).
        let stateClass: Int
    }

    /// One definition plugin of one bin whose attached members do not all decode to the
    /// definition's state.
    struct Detail: Equatable {
        let linkID: UUID
        let linkName: String
        let definitionID: UUID
        let pluginName: String
        /// Every ATTACHED member holding an instance of this definition, in project order.
        let members: [Member]
        /// The definition's state matches the largest class of members.
        let definitionInMajority: Bool
        var divergentFromDefinition: [Member] { members.filter { !$0.matchesDefinition } }
        var majority: [Member] { members.filter { $0.stateClass == 0 } }
    }

    /// One state to lay: an instance (its host and block, for the model) or a definition.
    struct Fix: Equatable {
        enum Target: Equatable {
            case instance(hostID: UUID, blockID: UUID, instanceID: UUID)
            case definition(linkID: UUID, definitionID: UUID)
        }
        let target: Target
        /// The full PLUGIN tree to give the target: the target's own tree with the reference's
        /// `state` (and `programNum`) transplanted — never another plugin's identity.
        let stateXML: String
    }

    // MARK: Detection

    /// The bins' definitions whose attached members disagree with the definition or with each
    /// other. `state(p)` gives the state to read for an instance (the file's or the live one);
    /// a definition is always read off its own `stateXML`.
    static func details(items: [SoundObject], stems: [Stem], fxLinks: [FXLink],
                        state: (ObjectPlugin) -> String?) -> [Detail] {
        // Every attached block, with its host, in project order (objects with groups walked down,
        // then buses).
        var blocks: [(hostID: UUID, hostName: String, block: ObjectPlugin)] = []
        func walkChain(_ chain: [ObjectPlugin], hostID: UUID, hostName: String) {
            for p in chain {
                if let fb = p.fxBlock {
                    if !fb.isDetached { blocks.append((hostID, hostName, p)) }
                } else if p.rack != nil {
                    for v in p.childSeries { walkChain(v, hostID: hostID, hostName: hostName) }
                }
            }
        }
        func walk(_ arr: [SoundObject]) {
            for o in arr {
                walkChain(o.plugins, hostID: o.id, hostName: o.displayName)
                if case .group(let children, _) = o.kind { walk(children) }
            }
        }
        walk(items)
        for s in stems { walkChain(s.plugins, hostID: s.id, hostName: s.name) }

        var out: [Detail] = []
        for link in fxLinks {
            let linkBlocks = blocks.filter { $0.block.fxBlock?.linkID == link.id }
            for d in link.plugins {
                guard let defState = comparable(identifier: d.identifier, stateXML: d.stateXML) else { continue }
                var raw: [(hostID: UUID, hostName: String, blockID: UUID, inst: ObjectPlugin, value: Value)] = []
                for b in linkBlocks {
                    for inst in b.block.fxBlock?.plugins ?? [] where inst.effectiveLinkGroupID == d.id {
                        // A member whose state cannot be read says nothing: not compared.
                        guard let v = comparable(identifier: inst.identifier, stateXML: state(inst)) else { continue }
                        raw.append((b.hostID, b.hostName, b.block.id, inst, v))
                    }
                }
                guard !raw.isEmpty else { continue }
                // Classes of equal states, in first-seen order, then ranked.
                var reps: [Value] = []
                var counts: [Int] = []
                var classOf: [Int] = []
                for r in raw {
                    if let k = reps.firstIndex(where: { $0.matches(r.value) }) {
                        counts[k] += 1; classOf.append(k)
                    } else {
                        reps.append(r.value); counts.append(1); classOf.append(reps.count - 1)
                    }
                }
                let defClass = reps.firstIndex(where: { $0.matches(defState) })
                let order = reps.indices.sorted { a, b in
                    if counts[a] != counts[b] { return counts[a] > counts[b] }
                    if a == defClass { return true }
                    if b == defClass { return false }
                    return a < b
                }
                let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
                let members = raw.enumerated().map { i, r in
                    Member(hostID: r.hostID, hostName: r.hostName, blockID: r.blockID, instanceID: r.inst.id,
                           matchesDefinition: r.value.matches(defState), stateClass: rank[classOf[i]] ?? 0)
                }
                guard members.contains(where: { !$0.matchesDefinition }) || reps.count > 1 else { continue }
                out.append(Detail(linkID: link.id, linkName: link.name, definitionID: d.id,
                                  pluginName: d.name, members: members,
                                  definitionInMajority: defClass.map { rank[$0] == 0 } ?? false))
            }
        }
        return out
    }

    // MARK: Repair

    /// What a repair lays, for `details` as detected with the same `state` closure. `.definition`:
    /// every member not matching the definition receives the definition's state. `.majority`:
    /// every member outside the largest class receives the state of that class's first member,
    /// and so does the definition when it is outside it. Empty when everything already agrees.
    static func repairPlan(_ details: [Detail], reference: Reference,
                           items: [SoundObject], stems: [Stem], fxLinks: [FXLink],
                           state: (ObjectPlugin) -> String?) -> [Fix] {
        let instances = instanceIndex(items: items, stems: stems)
        var fixes: [Fix] = []
        for d in details {
            guard let link = fxLinks.first(where: { $0.id == d.linkID }),
                  let def = link.plugins.first(where: { $0.id == d.definitionID }) else { continue }
            let refXML: String?
            let targets: [Member]
            switch reference {
            case .definition:
                refXML = def.stateXML
                targets = d.divergentFromDefinition
            case .majority:
                guard let lead = d.majority.first, let inst = instances[lead.instanceID] else { continue }
                refXML = state(inst)
                targets = d.members.filter { $0.stateClass != 0 }
                if !d.definitionInMajority, let ref = refXML, let own = def.stateXML {
                    fixes.append(Fix(target: .definition(linkID: d.linkID, definitionID: d.definitionID),
                                     stateXML: transplantingState(from: ref, into: own)))
                }
            }
            guard let ref = refXML, !ref.isEmpty else { continue }
            for m in targets {
                let own = instances[m.instanceID].flatMap { state($0) ?? $0.stateXML } ?? ref
                fixes.append(Fix(target: .instance(hostID: m.hostID, blockID: m.blockID, instanceID: m.instanceID),
                                 stateXML: transplantingState(from: ref, into: own)))
            }
        }
        return fixes
    }

    /// Every plugin of the project by id (chains, racks, blocks; objects, groups, buses).
    private static func instanceIndex(items: [SoundObject], stems: [Stem]) -> [UUID: ObjectPlugin] {
        var out: [UUID: ObjectPlugin] = [:]
        func walkChain(_ chain: [ObjectPlugin]) {
            for p in chain {
                out[p.id] = p
                if let fb = p.fxBlock { walkChain(fb.plugins) }
                else if p.rack != nil { for v in p.childSeries { walkChain(v) } }
            }
        }
        func walk(_ arr: [SoundObject]) {
            for o in arr {
                walkChain(o.plugins)
                if case .group(let children, _) = o.kind { walk(children) }
            }
        }
        walk(items)
        for s in stems { walkChain(s.plugins) }
        return out
    }

    /// `target`'s PLUGIN tree carrying `source`'s `state` and `programNum` attributes: the state
    /// moves, the identity (`id`, `enabled`, the layout) stays the target's. `target` unchanged if
    /// `source` has no state attribute.
    static func transplantingState(from source: String, into target: String) -> String {
        var out = target
        for attr in ["state", "programNum"] {
            guard let value = attribute(attr, in: source) else { continue }
            if let r = attributeRange(attr, in: out) {
                out.replaceSubrange(r, with: value)
            }
        }
        return out
    }

    private static func attributeRange(_ name: String, in xml: String) -> Range<String.Index>? {
        // ` name="…"` — preceded by whitespace so that `state` never matches `base64:state`.
        guard let open = xml.range(of: "\\s\(name)=\"", options: .regularExpression) else { return nil }
        guard let close = xml[open.upperBound...].firstIndex(of: "\"") else { return nil }
        return open.upperBound..<close
    }

    private static func attribute(_ name: String, in xml: String) -> String? {
        attributeRange(name, in: xml).map { String(xml[$0]) }
    }

    // MARK: Report

    /// What "Copy report" puts on the pasteboard (and `project.load_status` returns): the bins at
    /// odds with themselves, member by member. A text for a person or an assistant, like
    /// `PluginIDReport`: ENGLISH, never through `L()`, the same on every machine.
    static func report(filePath: String, details: [Detail]) -> String {
        var out: [String] = []
        out.append("OBJEKAT - FX link members that do not sound alike")
        out.append("=================================================")
        out.append("")
        out.append("File: \(clean(filePath))")
        out.append("")
        out.append("Every member of an FX link is meant to hold the bin's state. In the bins below, some ATTACHED")
        out.append("members decode to another state than the bin's definition (compared on what the plugin plays:")
        out.append("Pro-Q 4 bands, PHA-979 records, the Audio Unit's parameters; other plugins are not compared).")
        out.append("")
        for (n, d) in details.enumerated() {
            out.append("\(n + 1). fx link \"\(clean(d.linkName))\" (\(d.linkID.uuidString)), plugin \"\(clean(d.pluginName))\""
                       + " (definition \(d.definitionID.uuidString))")
            out.append("   \(d.divergentFromDefinition.count) of \(d.members.count) members differ from the definition;"
                       + (d.definitionInMajority ? " the definition holds the majority's state."
                                                 : " the definition is NOT the majority's state."))
            for m in d.members {
                let tag = m.matchesDefinition ? "same " : "DIFF "
                out.append("   \(tag) state #\(m.stateClass + 1)  \"\(clean(m.hostName))\" (\(m.hostID.uuidString)), instance \(m.instanceID.uuidString)")
            }
        }
        out.append("")
        out.append("To repair: reopen the project in OBJEKAT and answer \"Repair\" (the definition's state; tick the box")
        out.append("to take the state most members share instead). One undo puts everything back. State #1 is the")
        out.append("state most members share.")
        return out.joined(separator: "\n") + "\n"
    }

    private static func clean(_ s: String) -> String {
        String(s.map { $0.isNewline || ($0.asciiValue.map { $0 < 0x20 } ?? false) ? " " : $0 })
    }

    // MARK: Decoding

    /// A decoded state, compared with a tolerance (floats saved by different instances).
    enum Value {
        case proQ([Float])
        case pha([String: [Double]])
        case auParams([UInt32: Float])

        func matches(_ other: Value) -> Bool {
            switch (self, other) {
            case let (.proQ(a), .proQ(b)):
                return a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= 1e-6 }
            case let (.pha(a), .pha(b)):
                guard Set(a.keys) == Set(b.keys) else { return false }
                return a.allSatisfy { k, va in
                    let vb = b[k] ?? []
                    return va.count == vb.count && zip(va, vb).allSatisfy { abs($0 - $1) <= 1e-6 }
                }
            case let (.auParams(a), .auParams(b)):
                guard Set(a.keys) == Set(b.keys) else { return false }
                return a.allSatisfy { k, v in abs(v - (b[k] ?? .nan)) <= 1e-5 }
            default:
                return false
            }
        }
    }

    /// The comparable reading of a state, nil when this file cannot read it (then it is not
    /// compared at all).
    static func comparable(identifier: String, stateXML: String?) -> Value? {
        guard let xml = stateXML, let encoded = attribute("state", in: xml),
              let chunk = juceBase64Decode(encoded),
              let plist = try? PropertyListSerialization.propertyList(from: chunk, format: nil) as? [String: Any]
        else { return nil }
        let ident = identifier.split(separator: "/").last.map(String.init) ?? identifier
        if ident == "aumf,FQ4p,FabF" {
            guard let blob = plist["FabFilterPluginState"] as? Data, blob.count >= 12 + 576 * 4 else { return nil }
            let bytes = [UInt8](blob)
            return .proQ((0..<576).map { i in
                let o = 12 + i * 4
                let bits = UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
                return Float(bitPattern: bits)
            })
        }
        if ident == "aufx,1565,Vxng" {
            guard let blob = plist["VoxPluginState"] as? Data, let records = phaRecords(blob) else { return nil }
            return .pha(records)
        }
        if let data = plist["data"] as? Data, let params = auParams(data), !params.isEmpty {
            return .auParams(params)
        }
        return nil
    }

    /// JUCE's `MemoryBlock::toBase64Encoding`: "<size>.<chars>", 6 bits per char, little-endian bit
    /// order, its own alphabet.
    static func juceBase64Decode(_ text: String) -> Data? {
        guard let dot = text.firstIndex(of: "."), let size = Int(text[..<dot]), size >= 0 else { return nil }
        let alphabet = Array(".ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+".utf8)
        var lookup = [Int](repeating: -1, count: 256)
        for (i, c) in alphabet.enumerated() { lookup[Int(c)] = i }
        var out = [UInt8]()
        out.reserveCapacity(size)
        var acc = 0, bits = 0
        for c in text[text.index(after: dot)...].utf8 {
            let v = lookup[Int(c)]
            guard v >= 0 else { return nil }
            acc |= v << bits
            bits += 6
            while bits >= 8 {
                out.append(UInt8(acc & 0xFF))
                acc >>= 8
                bits -= 8
            }
        }
        guard out.count >= size else { return nil }
        return Data(out.prefix(size))
    }

    /// The AU "data" block: repeated (scope, element, count) then `count` × (parameter id, float32),
    /// big-endian.
    static func auParams(_ data: Data) -> [UInt32: Float]? {
        let b = [UInt8](data)
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
        }
        var out: [UInt32: Float] = [:]
        var off = 0
        while off + 12 <= b.count {
            let n = Int(u32(off + 8))
            off += 12
            guard n >= 0, off + n * 8 <= b.count else { return nil }
            for _ in 0..<n {
                out[u32(off)] = Float(bitPattern: u32(off + 4))
                off += 8
            }
        }
        return out
    }

    /// PHA-979's records: a zlib stream (after a header of its own) holding
    /// `audio.modMain.<name>` keys, each followed by 4 little-endian u32 (the last = count) and
    /// `count` × (tag u32 = 1, double). The instance and preset names are left out.
    static func phaRecords(_ blob: Data) -> [String: [Double]]? {
        let src = [UInt8](blob)
        guard let z = (0..<max(0, src.count - 1)).first(where: {
            src[$0] == 0x78 && [0x01, 0x5E, 0x9C, 0xDA].contains(src[$0 + 1])
        }) else { return nil }
        let input = Array(src[(z + 2)...])            // raw DEFLATE after the 2-byte zlib header
        var capacity = max(4096, input.count * 16)
        var body: [UInt8] = []
        while capacity <= 1 << 24 {
            var dst = [UInt8](repeating: 0, count: capacity)
            let n = compression_decode_buffer(&dst, capacity, input, input.count, nil, COMPRESSION_ZLIB)
            if n == 0 { return nil }
            if n < capacity { body = Array(dst.prefix(n)); break }
            capacity *= 4
        }
        guard !body.isEmpty else { return nil }

        let key = Array("audio.modMain.".utf8)
        func isNameByte(_ c: UInt8) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || c == 0x5F || c == 0x2E || c == 0x2D
        }
        var names: [(start: Int, end: Int, name: String)] = []
        var i = 0
        while i + key.count < body.count {
            if body[i] == key[0], Array(body[i..<(i + key.count)]) == key {
                var e = i + key.count
                while e < body.count, isNameByte(body[e]) { e += 1 }
                if e > i + key.count {
                    names.append((i, e, String(decoding: body[(i + key.count)..<e], as: UTF8.self)))
                }
                i = e
            } else {
                i += 1
            }
        }
        func u32le(_ o: Int) -> UInt32 {
            UInt32(body[o]) | UInt32(body[o + 1]) << 8 | UInt32(body[o + 2]) << 16 | UInt32(body[o + 3]) << 24
        }
        var out: [String: [Double]] = [:]
        for (k, n) in names.enumerated() {
            if n.name == "instance-name" || n.name == "preset-name" { continue }
            let end = k + 1 < names.count ? names[k + 1].start : body.count
            var vals: [Double] = []
            if n.end + 16 <= end {
                let count = Int(u32le(n.end + 12))
                var off = n.end + 16
                for _ in 0..<max(0, count) {
                    guard off + 12 <= end, u32le(off) == 1 else { break }
                    var bits: UInt64 = 0
                    for j in 0..<8 { bits |= UInt64(body[off + 4 + j]) << (8 * UInt64(j)) }
                    vals.append(Double(bitPattern: bits))
                    off += 12
                }
            }
            out[n.name] = vals
        }
        return out
    }
}
