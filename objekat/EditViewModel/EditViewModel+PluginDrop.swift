import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Receiving a dragged plugin, wherever it is let go of
//
// A plugin card leaves the signal view carrying a `PluginDragPayload`, and there are now TWO
// places it can land: a timeline object, and a bus's strip in the toolbar. What happens on
// arrival is the same thing in both — the same three gestures, the same single undo point, the
// same fate for the selection — so it is written ONCE here rather than at each door. The two
// callers differ only in how they name the host: the timeline resolves it from the drop's
// position, a strip already knows which bus it is.

/// The pasteboard side of it: recognising the payload, and getting it off the provider.
enum PluginDrop {

    /// A plugin payload travels as `public.plain-text` — an undeclared custom type is not
    /// instantiated by the pasteboard at all. Text and NOT a file is what identifies it before
    /// anything is decoded; the Finder's drags carry a `fileURL` beside their text.
    nonisolated static func carries(_ p: NSItemProvider) -> Bool {
        p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            && !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }

    /// What the CURSOR must say while a plugin drag hovers a target that accepts it: a bare drag
    /// MOVES, so no badge, and ⌥ as well as ⌘ COPY, so a '+'. One definition because the two
    /// doors must not drift — a gesture that reads '+' over a timeline object and nothing over a
    /// bus's strip is a gesture one stops trusting, and the convenience `.onDrop` answers `.copy`
    /// to everything, which is how the strip came to badge a move.
    ///
    /// ⌘ is a COPY here as it is on the timeline: what makes it a LINK is said by the badge the
    /// target draws, not by the operation — AppKit's `.link` draws an arrow that means an alias.
    static func operation(for flags: NSEvent.ModifierFlags) -> DropOperation {
        (flags.contains(.option) || flags.contains(.command)) ? .copy : .move
    }

    /// Reads the payload and lays it down on the host `host()` names.
    ///
    /// The modifiers are read HERE, synchronously, and carried into the closure: the provider's
    /// load is asynchronous, and by the time it answers the hand has let go of ⌥ or ⌘ — reading
    /// them on arrival would make the gesture depend on how long a pasteboard took.
    static func receive(_ provider: NSItemProvider, in viewModel: EditViewModel,
                        host: @escaping @MainActor () -> UUID?) {
        guard carries(provider) else { return }
        let flags = NSEvent.modifierFlags
        // The drop is made: the drag in flight is over (@see PluginDragSession).
        PluginDragSession.shared.end()
        provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
            guard let data,
                  let payload = try? JSONDecoder().decode(PluginDragPayload.self, from: data)
            else { return }
            Task { @MainActor in
                guard let targetID = host() else { return }
                viewModel.acceptPluginDrop(payload, on: targetID, modifiers: flags)
            }
        }
    }
}

// MARK: - What a drop would DO — one resolver for the cursor, the band and the drop itself

/// Where a drop lands in the TARGET host's chain.
enum PluginDropSite: Equatable {
    /// An object under the timeline's cursor, or a bus's strip: the host as a whole — the end of
    /// its root series.
    case hostEnd
    /// A precise place of the signal view: a series (the root, a parallel branch, an FX link's
    /// block) and the index in it where the card would be inserted.
    case series(SeriesLocation, index: Int)
}

/// What releasing a plugin drag HERE would do. The single answer the timeline's delegate, a bus's
/// strip and the signal view's cards and cables read for the cursor (`.forbidden` or not) and for
/// the band, and that the drop itself then carries out — so what the hand is told and what happens
/// cannot drift apart.
enum PluginDropOutcome: Equatable {
    // — plain plugins, wherever they come from —
    /// The card(s) leave the source chain for the target's (or reorder inside one chain).
    case move
    /// Independent copies: new identities, no link of any kind.
    case copy
    /// Copies that share the source's link group (the legacy ⌘-link).
    case link
    // — an instance of an FX link, dragged onto another host with ⌘ —
    /// The target JOINS the bin (it gets a block of it, attached): the whole bin, not the one plugin.
    case joinBin(UUID)
    // — a whole bin's block, grabbed by its header —
    /// The block moves: the target joins the bin and the source loses its block (a DETACHED block
    /// travels as it is, local output and all, with fresh instance ids). Within one host it is a reorder.
    case moveBlock
    /// ⌥ / ⌘: the target joins the bin and the source KEEPS its block — every copy of a bin is a link.
    case copyBlock
    // — plugins and FX link blocks —
    /// A plain plugin of the target host moves INTO an attached bin (its instance on this host keeps
    /// its id and becomes a member; every other member gets one).
    case adoptIntoBin(UUID)
    /// An independent copy of the plugin is added to the bin's definition (every member gets one).
    case copyIntoBin(UUID)
    /// An instance of an attached bin let go OUTSIDE it: the plugin leaves the bin for EVERY member
    /// and stays here as a plain one.
    case extractFromBin(UUID)
    /// Nothing happens, and the cursor says so. The reason is for the machine (the API's dry run).
    case refuse(String)

    var isRefusal: Bool { if case .refuse = self { return true } else { return false } }

    /// What the drop LINKS: the ⌘ maillon and the band's linked-copy line are shown for these, and
    /// only these.
    var isLinking: Bool {
        switch self {
        case .link, .joinBin: return true
        default: return false
        }
    }

    /// The cursor's verdict: `.forbidden` for a refusal, a bare MOVE where something is carried over
    /// or reordered, a COPY (the '+') where a copy is made. A link also answers `.copy` — AppKit's own
    /// `.link` draws an alias arrow, which is not what a ⌘ drop means; the band and the maillon say it.
    var operation: DropOperation {
        switch self {
        case .refuse: return .forbidden
        case .move, .moveBlock, .adoptIntoBin, .extractFromBin: return .move
        case .copy, .link, .joinBin, .copyBlock, .copyIntoBin: return .copy
        }
    }

    /// The band's context for this outcome (@see PluginDropHint.Context); `chain` is what a plain
    /// move / copy means where the target is a place of the signal view rather than a host. nil for a
    /// refusal: nothing is promised.
    func hintContext(plainContext: PluginDropHint.Context) -> PluginDropHint.Context? {
        switch self {
        case .refuse: return nil
        case .move, .copy: return plainContext
        case .link, .joinBin: return .host
        case .adoptIntoBin, .copyIntoBin: return .intoBin
        case .extractFromBin: return .outOfBin
        case .moveBlock, .copyBlock: return .blockMove
        }
    }

    /// Why nothing happens — for the command API's dry run; nil when something does.
    var refusalReason: String? { if case .refuse(let why) = self { return why } else { return nil } }

    /// A stable name for the command API (`plugin.drop_at`'s `outcome`).
    var apiName: String {
        switch self {
        case .move: return "move"
        case .copy: return "copy"
        case .link: return "link"
        case .joinBin: return "join_bin"
        case .moveBlock: return "move_block"
        case .copyBlock: return "copy_block"
        case .adoptIntoBin: return "adopt_into_bin"
        case .copyIntoBin: return "copy_into_bin"
        case .extractFromBin: return "extract_from_bin"
        case .refuse: return "refuse"
        }
    }
}

extension EditViewModel {

    /// What `payload`, released over `targetID` at `site` with `flags` held, would do. A pure READING —
    /// it changes nothing, so it can be asked on every mouse movement (the cursor and the band) and by a
    /// dry run of the API, and the drop then carries out exactly what it answered.
    ///
    /// The rules, from the decisions on the FX link rework:
    ///  • a PLAIN plugin: nothing = move, ⌥ = independent copy, ⌘ = linked copy (inside one chain ⌘ is a
    ///    plain move: two linked instances in one chain are refused on purpose). Aimed INSIDE an
    ///    attached bin: nothing = adopt it into the bin (only a plain plugin with no manual link), ⌥ = an
    ///    independent copy added to the bin, ⌘ = refused;
    ///  • an INSTANCE of an attached bin: inside its own bin a move reorders the definition; outside it
    ///    (same host), nothing = it leaves the bin for every member and stays here, ⌥ = an independent
    ///    copy, ⌘ = refused; onto ANOTHER host, nothing = refused (a move would empty the bin for this
    ///    host alone), ⌥ = an independent copy, ⌘ = that host joins the bin;
    ///  • a whole BLOCK: nothing = it moves (the target joins the bin, the source loses it), ⌥ / ⌘ = the
    ///    target joins and the source keeps its own; refused if the target already holds the bin, if
    ///    it is the source itself, or aimed inside another block (a bin does not hold a bin);
    ///  • an INSTRUMENT: its slot, on another MIDI object, under the three gestures.
    func pluginDropOutcome(_ payload: PluginDragPayload, toHost targetID: UUID,
                           at site: PluginDropSite = .hostEnd,
                           flags: NSEvent.ModifierFlags) -> PluginDropOutcome {
        let sourceID = payload.sourceObjectID
        let cmd = flags.contains(.command)
        let alt = flags.contains(.option)
        guard let targetChain = chainPlugins(targetID) else { return .refuse("unknown target host") }

        // AN INSTRUMENT lives in its object's slot, not in a chain.
        if isInstrument(payload.pluginID, of: sourceID) {
            guard case .hostEnd = site else { return .refuse("an instrument only goes to an object's instrument slot") }
            guard find(id: targetID)?.isMIDI == true else { return .refuse("the target is not a MIDI object") }
            guard sourceID != targetID else { return .refuse("source and target are the same object") }
            return cmd ? .link : (alt ? .copy : .move)
        }
        guard let sourceChain = chainPlugins(sourceID) else { return .refuse("unknown source host") }
        let sameHost = sourceID == targetID

        // Where the site lands, as far as bins are concerned.
        enum BinSite { case outside, attached(UUID), detachedBlock, unknown }
        let binSite: BinSite = {
            guard case .series(.block(let blockID), _) = site else { return .outside }
            guard let b = Self.findBlock(blockID, in: targetChain), let fb = b.fxBlock else { return .unknown }
            return fb.isDetached ? .detachedBlock : .attached(fb.linkID)
        }()
        if case .unknown = binSite { return .refuse("unknown block at the drop site") }

        // A WHOLE BLOCK, grabbed by its header.
        if let block = Self.findBlock(payload.pluginID, in: sourceChain), let fb = block.fxBlock {
            guard payload.ids.count == 1 else { return .refuse("a block travels alone") }
            switch binSite {
            case .outside: break
            default: return .refuse("a bin does not hold a bin")
            }
            if sameHost {
                if alt || cmd { return .refuse("this host already holds the FX link") }
                guard case .series = site else { return .refuse("source and target are the same host") }
                return .moveBlock
            }
            if Self.fxBlocks(in: targetChain).contains(where: { $0.fxBlock?.linkID == fb.linkID }) {
                return .refuse("the target already holds this FX link")
            }
            guard fxLink(fb.linkID) != nil else { return .refuse("the FX link is no longer in the registry") }
            return (alt || cmd) ? .copyBlock : .moveBlock
        }

        // CARDS: leaves of the source chain.
        let leaves = Self.flattenLeaves(sourceChain)
        let found = payload.ids.compactMap { id in leaves.first { $0.id == id } }
        guard !found.isEmpty, found.count == payload.ids.count else { return .refuse("unknown plugin") }
        let definitions = payload.ids.map { fxDefinition(ofInstance: $0, on: sourceID) }
        let binned = definitions.compactMap { $0 }

        // — instances of an ATTACHED bin —
        if !binned.isEmpty {
            guard binned.count == payload.ids.count else {
                return .refuse("a drag cannot mix an FX link's plugins with plain ones")
            }
            let links = Set(binned.map(\.linkID))
            guard links.count == 1, let linkID = links.first else {
                return .refuse("the plugins belong to different FX links")
            }
            switch binSite {
            case .attached(let siteLink):
                if cmd { return .refuse("⌘ cannot link into an FX link") }
                if siteLink == linkID && sameHost { return alt ? .copyIntoBin(siteLink) : .move }   // reordering its own bin
                if alt { return .copyIntoBin(siteLink) }
                return .refuse("a plugin does not move from one FX link to another")
            case .outside, .detachedBlock:
                if sameHost {
                    if cmd { return .refuse("⌘ cannot link an FX link's plugin") }
                    if alt { return .copy }
                    guard case .series = site else { return .refuse("source and target are the same host") }
                    return .extractFromBin(linkID)
                }
                if cmd {
                    if case .detachedBlock = binSite { return .refuse("a bin does not hold a bin") }
                    if Self.fxBlocks(in: targetChain).contains(where: { $0.fxBlock?.linkID == linkID }) {
                        return .refuse("the target already holds this FX link")
                    }
                    return .joinBin(linkID)
                }
                if alt { return .copy }
                return .refuse("an FX link's plugin does not move to another host (⌥ copies it, ⌘ joins the FX link)")
            case .unknown:
                return .refuse("unknown block at the drop site")
            }
        }

        // — plain plugins (possibly the instances of a DETACHED block, which are plain ones) —
        if case .attached(let siteLink) = binSite {
            if cmd { return .refuse("⌘ cannot link into an FX link") }
            if alt { return .copyIntoBin(siteLink) }
            guard found.allSatisfy(Self.isFXLinkEligible),
                  found.allSatisfy({ Self.enclosingFXBlock(of: $0.id, in: sourceChain) == nil }) else {
                return .refuse("a linked plugin, or one already in a block, cannot join an FX link")
            }
            return .adoptIntoBin(siteLink)
        }
        if sameHost {
            if alt { return .copy }
            guard case .series = site else { return .refuse("source and target are the same host") }
            return .move      // ⌘ inside one chain is a plain move
        }
        return cmd ? .link : (alt ? .copy : .move)
    }

    /// Lays a dragged payload down on a chain HOST — a timeline object or a bus, which are the
    /// same thing to a chain (@see chainPlugins). Three gestures, as everywhere a plugin is
    /// dragged: nothing = move, ⌥ = an independent copy, ⌘ = a copy that stays linked.
    ///
    /// @return true if something was laid down.
    @discardableResult
    func acceptPluginDrop(_ payload: PluginDragPayload, on targetID: UUID,
                          modifiers flags: NSEvent.ModifierFlags) -> Bool {
        performPluginDrop(payload, on: targetID, at: .hostEnd, modifiers: flags)
    }

    /// Resolves the drop (@see pluginDropOutcome) and carries out what it answers: ONE undo point for
    /// the gesture, whatever it takes.
    @discardableResult
    func performPluginDrop(_ payload: PluginDragPayload, on targetID: UUID, at site: PluginDropSite,
                           modifiers flags: NSEvent.ModifierFlags) -> Bool {
        let outcome = pluginDropOutcome(payload, toHost: targetID, at: site, flags: flags)
        switch outcome {
        case .refuse:
            return false

        case .move, .copy, .link:
            // AN INSTRUMENT (the MIDI zone): it does not join the target's FX chain — it needs MIDI at
            // its input — but its instrument SLOT. The same three gestures.
            // @see EditViewModel.transferInstrument
            if isInstrument(payload.pluginID, of: payload.sourceObjectID) {
                transferInstrument(sourceObjectID: payload.sourceObjectID,
                                   pluginID: payload.pluginID,
                                   targetObjectID: targetID,
                                   copy: outcome != .move,
                                   linked: outcome == .link)
                return true
            }
            var place: (SeriesLocation, Int)? = nil
            if case .series(let loc, let idx) = site { place = (loc, idx) }
            // Within ONE chain: a reorder (the engine instance is kept) or an independent copy laid at
            // the place, which `transferPlugins` (about two hosts) does not do.
            if payload.sourceObjectID == targetID, let (loc, idx) = place {
                if outcome == .copy {
                    return synopticCopyPlugin(objectID: targetID, pluginID: payload.pluginID, to: loc, at: idx)
                }
                return synopticReorder(objectID: targetID, pluginID: payload.pluginID, to: loc, at: idx)
            }
            // ONE card or a whole SELECTION, the same three gestures either way and the same single
            // undo point: the payload says what it carries (@see PluginDragPayload.ids), the transfer
            // says what it does.
            let mode: PluginTransferMode = outcome == .link ? .link : (outcome == .copy ? .copy : .move)
            // Was it the selection itself that was taken? Asked BEFORE the transfer, which is about to
            // move the ids it names.
            let wasSelection = selectedPluginHostID == payload.sourceObjectID
                && selectedPluginIDs == Set(payload.ids)
            let placed = transferPlugins(payload.ids, from: payload.sourceObjectID,
                                         to: targetID, mode: mode, at: place)
            // A MOVE hands the cards new identities. The selection follows them into the target chain
            // when it WAS the thing dragged; otherwise it named cards that have just left, so it is
            // given up rather than left pointing at nothing — and with it the keyboard goes back to
            // the timeline.
            if mode == .move, !placed.isEmpty {
                if wasSelection {
                    setPluginSelection(Set(placed), host: targetID)
                } else if selectedPluginHostID == payload.sourceObjectID {
                    clearPluginSelection()
                }
            }
            return !placed.isEmpty

        case .joinBin(let linkID):
            var place: (SeriesLocation, Int)? = nil
            if case .series(let loc, let idx) = site { place = (loc, idx) }
            return attachFXLink(linkID, to: targetID, at: place) != nil

        case .moveBlock:
            // Within one host: the block changes place, as one piece.
            if payload.sourceObjectID == targetID, case .series(let loc, let idx) = site {
                return synopticReorder(objectID: targetID, pluginID: payload.pluginID, to: loc, at: idx)
            }
            var place: (SeriesLocation, Int)? = nil
            if case .series(let loc, let idx) = site { place = (loc, idx) }
            let moved = transferFXBlock(blockID: payload.pluginID, from: payload.sourceObjectID, to: targetID,
                                        at: place, copy: false)
            // The block's instances have left the source chain: a selection of them points at nothing.
            if moved, selectedPluginHostID == payload.sourceObjectID { clearPluginSelection() }
            return moved

        case .copyBlock:
            var place: (SeriesLocation, Int)? = nil
            if case .series(let loc, let idx) = site { place = (loc, idx) }
            return transferFXBlock(blockID: payload.pluginID, from: payload.sourceObjectID, to: targetID,
                                   at: place, copy: true)

        case .adoptIntoBin(let linkID):
            guard case .series(_, let idx) = site else { return false }
            // From another host, the plugins first MOVE to the target's chain (new identities, one undo
            // point for the whole gesture), then join the bin there.
            pushUndo()
            var ids = payload.ids
            if payload.sourceObjectID != targetID {
                ids = transferPlugins(payload.ids, from: payload.sourceObjectID, to: targetID,
                                      mode: .move, undo: false)
                if selectedPluginHostID == payload.sourceObjectID { clearPluginSelection() }
            }
            let defs = fxAdoptPlugins(hostID: targetID, pluginIDs: ids, linkID: linkID, at: idx, undo: false)
            // Within one host the instances kept their ids, so a selection still holds; from another host
            // the selection follows the moved plugins (new ids) into the bin.
            if !defs.isEmpty, payload.sourceObjectID != targetID {
                setPluginSelection(Set(ids), host: targetID)
            }
            return !defs.isEmpty

        case .copyIntoBin(let linkID):
            guard case .series(_, let idx) = site, let source = chainPlugins(payload.sourceObjectID) else { return false }
            let leaves = Self.flattenLeaves(source)
            let found = payload.ids.compactMap { id in leaves.first { $0.id == id } }
            return !fxAddPluginCopies(linkID: linkID, of: found, at: idx).isEmpty

        case .extractFromBin:
            guard case .series(let loc, let idx) = site else { return false }
            // The plugins keep their ids (they are plain now), so a selection of them still holds.
            return !fxExtractPlugins(hostID: targetID, pluginIDs: payload.ids, at: (loc, idx)).isEmpty
        }
    }
}
