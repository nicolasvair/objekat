import Foundation

// MARK: - Solo (the listening filter)

/// The `solo.*` family — the CONFIRMED solo layer, which is what the inspector's solo button
/// writes (@see EditViewModel.toggleSoloHold). The temporary layer is not reachable from here, and
/// on purpose: it belongs to the "s" key being HELD, and a script holds no key — a layer laid with
/// nothing to release it would outlive the command that made it (@see EditViewModel+Solo).
///
/// Before this family nothing headless could put a solo on at all, so nothing about solo could be
/// asserted with no screen — neither what it silences nor, above all, what it lets through. The
/// answer carries `opened_windows`: the groups (and the auxes they host) whose engine window a
/// direct solo is holding open right now, the half of the rule that no fader shows
/// (@see EditViewModel.soloOpensWindow). Undo policy `.none` throughout: a solo is a listening
/// state, outside `items`, outside the undo, never saved.
extension CommandRegistry {

    /// What is soloed, what is heard, and which windows the solo holds open. The lists are sorted
    /// so that two reads of one state answer the same bytes.
    private func soloJSON(_ vm: EditViewModel) -> JSONValue {
        func ids<S: Sequence>(_ s: S) -> JSONValue where S.Element == UUID {
            .array(s.map(\.uuidString).sorted().map { .string($0) })
        }
        let opened = vm.allObjectsFlat.filter { vm.soloOpensWindow(of: $0) }.map(\.id)
        return .object([
            "active": .bool(vm.hasAnySolo),
            "confirmed": ids(vm.soloedIDs),
            "stems": ids(vm.soloedStemIDs),
            "temporary": vm.tempSoloRoots.map { ids($0) } ?? .null,
            "audible": ids(vm.soloAudibleObjectIDs),
            "opened_windows": ids(opened),
        ])
    }

    func registerSoloCommands() {

        register("solo.get",
                 summary: "The solo state: the confirmed and temporary roots, the soloed stems, "
                        + "the audible closure, and the windows a direct solo holds open.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            return self.soloJSON(vm)
        }

        register("solo.set",
                 summary: "Puts objects into the confirmed solo, or takes them out of it — the "
                        + "inspector's solo button, for several objects at once. A direct solo is "
                        + "heard whatever the mutes say, and past its groups' windows.",
                 params: [ParamSpec("ids", "array<uuid>", required: false,
                                    "Target objects; default = current selection."),
                          ParamSpec("on", "bool", required: false,
                                    "true = soloed (default), false = un-soloed.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let targets = try CommandAdapters.targetIDs(p, in: vm)
            let on = try p.bool("on", or: true)
            // Through the button's own door, one object at a time, and only for an object whose
            // CONFIRMED state differs — the temporary layer ("s" held) is not this family's to
            // touch; `solo.clear` is what empties it.
            for id in targets where vm.soloedIDs.contains(id) != on {
                vm.toggleSoloHold(objectID: id)
            }
            return self.soloJSON(vm)
        }

        register("solo.clear",
                 summary: "Turns every solo off, confirmed and temporary (what Esc does).",
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            vm.clearAllSolo()
            return self.soloJSON(vm)
        }
    }
}
