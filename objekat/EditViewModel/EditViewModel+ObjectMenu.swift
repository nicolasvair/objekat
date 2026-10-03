import Foundation

// MARK: - The object menu — what it OFFERS, and what each entry APPLIES TO
//
// The right click on an object's body and the right click inside a time selection ON an object
// offer the SAME entries (group, consolidate, deconsolidate, colour, scripts, FX link…). What
// differs is the SCOPE they apply to:
//
//   • `.objects` — the selection (the clicked object, selected by the click, or the multiple
//     selection it already belonged to). The functions are the ones the menu always called.
//   • `.zone`    — the time selection: only the part of the objects inside the traced range. The
//     objects are first ISOLATED on the range's bounds (@see `isolateTimeSelection`), then the
//     action applies to the pieces that fall inside.
//
// The list is built here and nowhere else — a pure function of the model — so that the AppKit
// menu (`TimelineKeyHandler`) and the command API (`selection.context_click`,
// `selection.context_action`) read the SAME entries, and a script can assert what a menu offers
// with no screen. Titles are the interface's own words (`L()`); the machine's names are
// `ObjectMenuAction.apiName`.

/// What an entry of the object menu applies to.
enum ObjectActionScope: Equatable {
    /// The objects selected (the menu's object included, the click having selected it).
    case objects(Set<UUID>)
    /// The time selection: the part of the objects inside the traced range, and nothing else.
    case zone(TimeSelection)

    var isZone: Bool {
        if case .zone = self { return true }
        return false
    }
}

/// One thing the object menu can do.
nonisolated enum ObjectMenuAction: Equatable {
    case disbandGroup
    /// A group → one consolidated object.
    case consolidateGroup
    /// A lone clip → a consolidated object (the clip is wrapped in a one-item group first).
    case consolidateClip
    /// N strictly identical clips → ONE definition, N linked instances (objects scope only).
    case consolidateLinked
    /// One INDEPENDENT consolidated object per eligible element.
    case consolidateEach
    case deconsolidate
    /// Clips → one group: the selection, or, in `.zone` scope, the range (`createGroupFromTimeSelection`).
    case groupSelection
    /// An aux clip over the range (zone scope, no object under the point).
    case createAux
    /// A MIDI clip over the range (zone scope, no object under the point).
    case createMidiClip
    /// A custom colour (nil = the stem's).
    case setColor(Int?)
    /// The objects come to share ONE bin of plugins.
    case createFXLink
    /// An installed script declared for the object context.
    case runScript(plugin: UUID, entry: Int)
    /// Informational and greyed: an object render is under way.
    case baking

    /// The machine's name (`selection.context_action`, `selection.context_click`'s `entries`).
    /// `set_color` and `run_script` carry their argument beside the name.
    var apiName: String {
        switch self {
        case .disbandGroup:       return "disband_group"
        case .consolidateGroup:   return "consolidate_group"
        case .consolidateClip:    return "consolidate_clip"
        case .consolidateLinked:  return "consolidate_linked"
        case .consolidateEach:    return "consolidate_each"
        case .deconsolidate:      return "deconsolidate"
        case .groupSelection:     return "group_selection"
        case .createAux:          return "create_aux"
        case .createMidiClip:     return "create_midi_clip"
        case .setColor:           return "set_color"
        case .createFXLink:       return "create_fx_link"
        case .runScript:          return "run_script"
        case .baking:             return "baking"
        }
    }
}

/// One entry of the menu: the action, its words, and whether it can be chosen right now.
struct ObjectMenuEntry: Equatable {
    let action: ObjectMenuAction
    let title: String
    var isEnabled: Bool = true
    var toolTip: String? = nil
    /// `setColor(nil)` only: the stem's colour is the current one.
    var isChecked: Bool = false
    /// `setColor(nil)` only: the clicked object's own colour, for the palette that follows it.
    var currentColorIndex: Int? = nil
}

extension EditViewModel {

    // MARK: What the menu offers

    /// The entries the object menu offers for a click on `clicked` (nil: an empty lane), in the
    /// order the menu shows them. A pure read of the model — nothing is selected, cut or moved.
    ///
    /// The branches are the menu's own, in its own order: a group (dissolve, consolidate), a
    /// consolidated instance (deconsolidate), no object but a range (wrap in a group, aux clip,
    /// MIDI clip), clips (group, consolidate), then — for any object under the point — the scripts,
    /// the colour and, on a multiple scope, the FX link. In `.zone` scope two entries have no
    /// meaning and are left out: 'Consolidate as N linked instances' (identity of whole objects)
    /// and the relink block (a path is repaired for the object, not for a passage — it is built by
    /// the menu, not listed here).
    func objectMenuEntries(clicked: LaneEntry?, scope: ObjectActionScope) -> [ObjectMenuEntry] {
        var out: [ObjectMenuEntry] = []
        let item = clicked?.item

        // The objects the menu is about, and how many: the selection, or what the range crosses.
        let targetIDs: [UUID]
        switch scope {
        case .objects(let ids):  targetIDs = Array(ids)
        case .zone(let sel):     targetIDs = timeSelectionTargets(sel).map(\.item.id)
        }
        let count = targetIDs.count

        func consolidateEachEntry() -> ObjectMenuEntry? {
            let eligible: [UUID]
            switch scope {
            case .objects:
                eligible = consolidateTargets()
            case .zone(let sel):
                eligible = timeSelectionTargets(sel).map(\.item).filter {
                    ($0.isGroup || $0.isClip || $0.isMIDI) && !$0.isConsolidateInstance && !$0.isInfiniteBus
                }.map(\.id)
            }
            guard eligible.count >= 2, consolidateFolder != nil else { return nil }
            guard !eligible.contains(where: { isBaking($0) }) else { return nil }
            return ObjectMenuEntry(action: .consolidateEach,
                                   title: L("menu.context.consolidateEach", eligible.count))
        }
        func consolidateLinkedEntry() -> ObjectMenuEntry? {
            guard !scope.isZone, let n = uniformClipSelectionForConsolidate() else { return nil }
            return ObjectMenuEntry(action: .consolidateLinked,
                                   title: L("menu.context.consolidateLinked", n))
        }
        func bakingEntry() -> ObjectMenuEntry {
            ObjectMenuEntry(action: .baking, title: L("menu.context.baking"), isEnabled: false)
        }

        if let item, item.isGroup {
            let baking = isBaking(item.id)
            out.append(ObjectMenuEntry(action: .disbandGroup, title: L("menu.context.disbandGroup"),
                                       isEnabled: !baking))   // the subtree is locked during the bake
            if baking {
                out.append(bakingEntry())
            } else if count >= 2 {
                // 'Consolidate' of a MULTIPLE scope: as N linked instances if it is an identical
                // copy-paste, otherwise one independent object per element (or nothing).
                if let linked = consolidateLinkedEntry() { out.append(linked) }
                if let each = consolidateEachEntry() { out.append(each) }
            } else {
                out.append(ObjectMenuEntry(action: .consolidateGroup,
                                           title: L("menu.context.consolidate"),
                                           toolTip: L("menu.context.consolidate.help")))
            }
        } else if let item, item.isConsolidateInstance {
            // OPENING a consolidated object goes through the double click; the menu only keeps
            // 'Deconsolidate'. It stays possible while a parent is open.
            out.append(ObjectMenuEntry(action: .deconsolidate, title: L("menu.context.deconsolidate"),
                                       isEnabled: !isBaking(item.id),
                                       toolTip: L("menu.context.deconsolidate.help")))
        } else if item == nil, scope.isZone {
            // No object under the point, a range: what the range has always offered.
            out.append(ObjectMenuEntry(action: .groupSelection, title: L("menu.context.wrapInGroup")))
            out.append(ObjectMenuEntry(action: .createAux, title: L("menu.context.createAuxClip")))
            out.append(ObjectMenuEntry(action: .createMidiClip, title: L("menu.context.createMidiClip")))
        } else if scopeHoldsGroupableObject(scope, clicked: item) {
            switch scope {
            case .objects:
                out.append(ObjectMenuEntry(
                    action: .groupSelection,
                    title: count == 1 ? L("menu.context.groupClip") : L("menu.context.groupSelection", count)))
            case .zone:
                out.append(ObjectMenuEntry(action: .groupSelection, title: L("menu.context.wrapInGroup")))
            }
            // 'Create a consolidated object' on a clip: a consolidated object is ALWAYS a group
            // (a design decision) → the clip is wrapped in a one-item group first.
            if let clip = item, clip.isClip || clip.isMIDI, !clip.isConsolidateInstance {
                if isBaking(clip.id) {
                    out.append(bakingEntry())
                } else if count >= 2 {
                    if let linked = consolidateLinkedEntry() { out.append(linked) }
                    if let each = consolidateEachEntry() { out.append(each) }
                } else {
                    out.append(ObjectMenuEntry(action: .consolidateClip,
                                               title: L("menu.context.consolidate"),
                                               toolTip: L("menu.context.consolidate.help")))
                }
            }
        }

        guard let item else { return out }

        // Third-party scripts declared for an OBJECT context: they have no business in the bar's
        // Scripts menu (nothing to hand it there), so this is their only door.
        for plugin in ScriptPluginRegistry.shared.plugins where !plugin.objectEntries.isEmpty {
            let entries = plugin.objectEntries
            for (i, entry) in entries.enumerated() {
                let title = entries.count > 1 ? "\(plugin.displayName) — \(entry.title)" : plugin.displayName
                out.append(ObjectMenuEntry(action: .runScript(plugin: plugin.id, entry: i), title: title,
                                           isEnabled: plugin.isAvailable,
                                           toolTip: plugin.unavailableReason ?? plugin.manifest.description))
            }
        }

        // A custom colour (a clip / MIDI clip / group / aux), independent of the stem: it paints
        // the scope. The entry is 'stem colour'; the palette it comes with is the menu's.
        out.append(ObjectMenuEntry(action: .setColor(nil), title: L("menu.context.stemColor"),
                                   isChecked: item.colorIndex == nil,
                                   currentColorIndex: item.colorIndex))

        // 'Create an FX link' — the very last entry, on a MULTIPLE scope the clicked object belongs
        // to (or, in `.zone` scope, that the range crosses): the objects come to share ONE bin of
        // plugins. Offered only when one of them has plain plugins to make the bin of.
        let belongs: Bool
        switch scope {
        case .objects(let ids): belongs = ids.contains(item.id)
        case .zone:             belongs = true
        }
        if count >= 2, belongs, canCreateFXLinkFromObjects(targetIDs) {
            out.append(ObjectMenuEntry(action: .createFXLink, title: L("fxlink.menu.create")))
        }
        return out
    }

    /// 'Group the clip / the selection' is offered: in `.objects` scope when the selection holds a
    /// clip or a MIDI clip that is not a consolidated instance (an empty lane, a clip's menu); in
    /// `.zone` scope when the object under the point is one.
    private func scopeHoldsGroupableObject(_ scope: ObjectActionScope, clicked: SoundObject?) -> Bool {
        func groupable(_ o: SoundObject) -> Bool { (o.isClip || o.isMIDI) && !o.isConsolidateInstance }
        switch scope {
        case .objects(let ids):
            return ids.contains { id in find(id: id).map(groupable) ?? false }
        case .zone:
            return clicked.map(groupable) ?? false
        }
    }

    // MARK: What an entry does

    /// Performs an entry of the object menu. `clickedID` is the object under the point (nil on an
    /// empty lane).
    ///
    /// `.objects` scope calls the functions the menu always called, unchanged. `.zone` scope —
    /// the zone-only variants live in `EditViewModel+ObjectMenuZone` — is for the range with no
    /// object under the point here (wrap, aux clip, MIDI clip), the rest isolating the objects
    /// first.
    func performObjectMenuAction(_ action: ObjectMenuAction, clickedID: UUID?,
                                 scope: ObjectActionScope) async {
        switch scope {
        case .objects(let ids):
            await performObjectMenuAction(action, clickedID: clickedID, selectedIDs: ids)
        case .zone(let sel):
            await performZoneMenuAction(action, clickedID: clickedID, selection: sel)
        }
    }

    /// The `.objects` scope: the functions the menu has always called.
    private func performObjectMenuAction(_ action: ObjectMenuAction, clickedID: UUID?,
                                         selectedIDs ids: Set<UUID>) async {
        switch action {
        case .disbandGroup:
            if let id = clickedID { disbandGroup(id: id) }
        case .consolidateGroup:
            if let id = clickedID { consolidate(groupID: id) }
        case .consolidateClip:
            if let id = clickedID { consolidateWrappingClip(clipID: id) }
        case .consolidateLinked:
            consolidateSelectionAsLinkedInstances()
        case .consolidateEach:
            await consolidateEachInSelection()
        case .deconsolidate:
            if let id = clickedID { deconsolidate(placementID: id) }
        case .groupSelection:
            createGroupFromSelection(ids)
        case .createAux, .createMidiClip, .baking:
            break   // zone scope only / informational
        case .setColor(let index):
            // It paints the whole selection if the object under the cursor is part of it,
            // otherwise that object alone — the same convention as 'Group the selection'.
            let targets: Set<UUID>
            if let id = clickedID, !(ids.contains(id) && ids.count > 1) { targets = [id] } else { targets = ids }
            setObjectColor(ids: targets, colorIndex: index)
        case .createFXLink:
            _ = createFXLinkFromObjects(Array(ids))
        case .runScript(let pluginID, let entryIndex):
            let target: [UUID]
            if let id = clickedID { target = ids.contains(id) ? Array(ids) : [id] } else { target = Array(ids) }
            runObjectScript(pluginID: pluginID, entryIndex: entryIndex, objectIDs: target)
        }
    }

    /// Launches an object-context script on `objectIDs`; a failure to START is reported, a failure
    /// of the script itself is reported by the registry when the process ends.
    func runObjectScript(pluginID: UUID, entryIndex: Int, objectIDs: [UUID]) {
        guard let plugin = ScriptPluginRegistry.shared.plugins.first(where: { $0.id == pluginID }),
              entryIndex < plugin.objectEntries.count else { return }
        let entry = plugin.objectEntries[entryIndex]
        if let error = ScriptPluginRegistry.shared.run(plugin, entry: entry, objectIDs: objectIDs) {
            notify(L("script.run.failed", entry.title), error)
        }
    }
}
