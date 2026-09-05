import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main inspector (bottom panel, horizontal columns)
//
// A single object: ONE column, the vertical signal view, which absorbs every attribute.
// Speed / semitones / bpm / reverse live in the 'audio file' rectangle at the head;
// volume / pan / mute in the 'clip' rectangle; the sends and the 'infinite' option have
// joined the signal view (departures at the foot near the stems, infinite at the head near
// the source). A multiple selection keeps its summary column.

struct ObjectInspectorView: View {
    var viewModel: EditViewModel

    // Multiple selection: each slider's current position (the source of truth for computing
    // the delta) plus a 'relative mode' flag frozen at the moment of the selection.
    @State private var relVolume: Double = 0
    @State private var relPan: Double = 0
    @State private var relSemis: Double = 0
    @State private var volRelative: Bool = false
    @State private var panRelative: Bool = false
    @State private var speedRelative: Bool = false

    // Sends in a multiple selection: the slider's current position and the 'relative' flag
    // per aux (the key being the auxID), the same logic as relVolume/volRelative.
    @State private var relSend: [UUID: Double] = [:]
    @State private var sendRelative: [UUID: Bool] = [:]

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if viewModel.selectedIDs.count > 1 {
                    multiSelectionContent
                } else if let id = viewModel.selectedID,
                          let obj = viewModel.find(id: id) {
                    singleObjectColumns(id: id, obj: obj)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // The old stem panel (overall management: create / rename / colour / delete) was
            // removed here — it will be rehoused elsewhere (see the other prompt). Commented out, not deleted.
            // Divider()
            // stemsColumn
            //     .frame(width: 220)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - A single object: columns side by side

    private func singleObjectColumns(id: UUID, obj: SoundObject) -> some View {
        // Scrolling on both axes: the vertical signal view can exceed the dock's height (with many
        // plugins) → one has to be able to get down to the 'clip' and 'stems' areas.
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            pluginsSynopticColumn(id: id, obj: obj)
        }
    }

    /// The dB label of a send level (-∞ at the floor).
    private func sendLevelString(_ db: Float) -> String {
        db <= sendMinDb ? "-∞ dB" : "\(Int(db.rounded())) dB"
    }

    // MARK: - Plugins column

    private func pluginsSynopticColumn(id: UUID, obj: SoundObject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SynopticBoundView(viewModel: viewModel, objectID: id, scrolls: false)

            HStack(spacing: 12) {
                if !obj.plugins.isEmpty {
                    Button {
                        viewModel.diagnosticPluginStates(objectID: id)
                    } label: {
                        Label(L("inspector.diagnostic"), systemImage: "ant.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Multiple selection

    private var multiSelectionContent: some View {
        // A single column: the selected sounds at the top, the settings (mix, stem, sends)
        // underneath. Vertical scrolling only.
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                selectionListColumn
                Divider()
                multiMixColumn
                Divider()
                multiStemSelector
                if !viewModel.selectionSendAuxes().isEmpty {
                    Divider()
                    multiSendsColumn
                }
            }
            .padding(12)
            .frame(width: multiColumnWidth, alignment: .topLeading)
        }
        // (Re)initialises the slider positions on every change of selection:
        // the shared value if it is uniform (absolute mode), otherwise 0 (relative mode).
        .onAppear { refreshMultiBaselines() }
        .onChange(of: viewModel.selectedIDs) { _, _ in refreshMultiBaselines() }
    }

    /// The width of the single multiple-selection column: a little wider than the single-object
    /// columns so as to give the 'label … box' rows some air.
    private let multiColumnWidth: CGFloat = 260

    // Left column: the list of clips / groups concerned plus their values.
    private var selectionListColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("inspector.selection.count", selectedObjects.count))
                .font(.caption).foregroundStyle(.secondary)

            ForEach(selectedObjects) { obj in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(viewModel.stemColor(for: obj.id).opacity(0.8))
                            .frame(width: 8, height: 8)
                        Image(systemName: isGroup(obj) ? "rectangle.3.group" : "waveform")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                        Text(obj.displayName)
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                    }
                    Text(itemValueSummary(obj))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 14)
                    if let sends = itemSendSummary(obj) {
                        Text(sends)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.tail)
                            .padding(.leading, 14)
                    }
                }
            }
        }
    }

    private func itemValueSummary(_ o: SoundObject) -> String {
        // When automated, volume and pan are worth what their curve plays at the playback position:
        // that is what one hears, and the static setting no longer says anything (@see
        // EditViewModel.liveAutomationValue).
        let v = viewModel.liveAutomationValue(.volume, on: o.id) ?? o.volume
        let p = viewModel.liveAutomationValue(.pan,    on: o.id) ?? o.pan
        let vol = v <= -96 ? "-∞" : "\(Int(v.rounded()))dB"
        let pan = abs(p) < 0.01 ? "C" : (p < 0 ? "L\(Int(-p*100))" : "R\(Int(p*100))")
        if isGroup(o) { return "\(vol) · \(pan)" }
        return "\(vol) · \(pan) · " + String(format: "×%.2f", o.speedRatio)
    }

    /// An object's active send levels, e.g. '→ Reverb −10 · Delay −8'. nil if there are none.
    private func itemSendSummary(_ o: SoundObject) -> String? {
        let parts: [String] = viewModel.overlappingAuxes(for: o.id).compactMap { aux in
            guard let e = o.sends.first(where: { $0.auxID == aux.id }), e.enabled else { return nil }
            let lvl = e.levelDb <= sendMinDb ? "−∞" : "\(Int(e.levelDb.rounded()))"
            return "\(aux.label ?? "Aux") \(lvl)"
        }
        return parts.isEmpty ? nil : "→ " + parts.joined(separator: " · ")
    }

    // Stem: a compact 'batch' assignment selector. The background takes the current stem's
    // colour (a visual identity consistent with the stem bar). If the selection is mixed, the
    // button shows 'Multiple values' on a neutral background. Each item of the menu is prefixed
    // with its keyboard shortcut number (1 = Main, 2 = the 2nd stem…).
    private var multiStemSelector: some View {
        let current = uniformStemID                                   // nil = mixed values
        let isMain  = current != nil && current == viewModel.mainStemID
        let stemObj = current.flatMap { id in viewModel.stems.first { $0.id == id } }
        // The Main has a colour like the other buses (the accent blue by default, recolourable):
        // only a MIXED selection stays neutral.
        let tint: Color = current == nil ? Color.secondary : (stemObj?.color ?? .secondary)
        let label: String = current == nil ? L("inspector.stem.mixedValues")
                                            : (isMain ? L("stem.main.name") : (stemObj?.name ?? "—"))
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("inspector.section.stem")).font(.caption.weight(.bold)).foregroundStyle(.secondary)

            Menu {
                ForEach(Array(viewModel.stems.enumerated()), id: \.element.id) { idx, stem in
                    let itemIsMain = stem.id == viewModel.mainStemID
                    let prefix = idx < 9 ? "\(idx + 1)  " : ""
                    let name = itemIsMain ? L("stem.main.name") : stem.name
                    // A `String` and not a literal: the literal would be a `LocalizedStringKey`,
                    // and Xcode's extraction would harvest the "%@%@" of the interpolation.
                    let title = "\(prefix)\(name)"
                    Button {
                        viewModel.edit { viewModel.assignStemSelected(stemID: stem.id) }
                    } label: {
                        if current == stem.id { Label(title, systemImage: "checkmark") }
                        else { Text(verbatim: title) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.caption)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).frame(height: 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.22)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(0.5)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    // A unified Volume / Pan / Speed / Semitones column.
    //
    // Relative 'batch' editing (one delta applied to the whole selection) but through the SAME
    // graphical boxes as the single-object inspector (DragValueBox): drag ↑/↓, arrow keys, direct
    // typing, double click = reset. The 'rel.' badge signals that the differences between objects
    // are preserved (relative mode) rather than one absolute value shared.
    private var multiMixColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("inspector.section.settings")).font(.caption.weight(.bold)).foregroundStyle(.secondary)

            // Volume plus grouped mute (mute = a toggle over the whole selection).
            batchRow(L("inspector.field.volume"), relative: volRelative) {
                HStack(spacing: 6) {
                    DragValueBox(
                        value: relVolume,
                        format: { v in
                            if volRelative { return v <= -96 ? "-∞" : String(format: "%+.0f dB", v) }
                            return v <= -96 ? "-∞ dB" : String(format: "%.0f dB", v)
                        },
                        range: -96...40, pointsPerStep: 6, snap: true, width: 56, keyStep: 1,
                        help: L("help.drag.volume"),
                        // Touching the control: the fader becomes the 'future automation' row of EVERY object
                        // in the batch, without any value having to move.
                        onTouch: { for id in viewModel.selectedIDs { viewModel.recordAutomationTouch(id, .volume) } },
                        onBegin: { viewModel.pushUndo() },
                        onChange: { new in
                            viewModel.adjustVolumeDB(Float(new - relVolume))
                            relVolume = new
                        },
                        onReset: {
                            viewModel.edit { viewModel.resetVolumeSelected() }
                            relVolume = 0; volRelative = false
                        }
                    )
                    Toggle(isOn: Binding(
                        get: { !selectedObjects.isEmpty && selectedObjects.allSatisfy(\.isMuted) },
                        set: { _ in viewModel.edit { viewModel.toggleMuteSelected() } }
                    )) { Text(verbatim: "M") }
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .tint(.red)
                    .frame(width: 24)
                }
            }

            batchRow(L("inspector.field.pan"), relative: panRelative) {
                DragValueBox(
                    value: relPan,
                    format: { p in
                        if panRelative { return abs(p) < 0.01 ? "0" : String(format: "%+.2f", p) }
                        return abs(p) < 0.01 ? "C" : (p < 0 ? "L \(Int(-p*100))%" : "R \(Int(p*100))%")
                    },
                    range: -1...1, pointsPerStep: 80, snap: false, width: 56, keyStep: 0.05,
                    parse: { Double($0.replacingOccurrences(of: ",", with: ".")).map { $0 / 100 } },
                    help: L("help.drag.pan"),
                    onTouch: { for id in viewModel.selectedIDs { viewModel.recordAutomationTouch(id, .pan) } },
                    onBegin: { viewModel.pushUndo() },
                    onChange: { new in
                        viewModel.adjustPanSelected(Float(new - relPan))
                        relPan = new
                    },
                    onReset: {
                        viewModel.edit { viewModel.resetPanSelected() }
                        relPan = 0; panRelative = false
                    }
                )
            }

            Divider().padding(.vertical, 2)

            // Speed / semitones: disabled if a group is part of the selection
            // (the same boxes as the 'audio file' area of the single-object inspector).
            Group {
                batchRow(L("inspector.field.speed"), relative: speedRelative) {
                    DragValueBox(
                        value: relSemis,
                        format: { String(format: "%.2f×", pow(2.0, $0 / 12.0)) },
                        range: -48...48, pointsPerStep: 6, snap: false, width: 56, keyStep: 1,
                        parse: { Double($0.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "×", with: "").replacingOccurrences(of: "x", with: "")).map { 12 * log2(max(1e-6, $0)) } },
                        help: L("help.drag.speed"),
                        onBegin: { viewModel.pushUndo() },
                        onChange: { new in
                            applySpeedDeltaSemis(new - relSemis)
                            relSemis = new
                        },
                        onReset: { resetSpeedSelected() }
                    )
                }

                batchRow(L("inspector.field.semitones"), relative: speedRelative) {
                    DragValueBox(
                        value: relSemis,
                        format: { v in
                            let r = v.rounded()
                            if abs(v - r) < 0.05 { return r == 0 ? "0 st" : String(format: "%+.0f st", r) }
                            return String(format: "%+.1f st", v)
                        },
                        range: -48...48, pointsPerStep: 6, snap: true, width: 56, keyStep: 1,
                        help: L("help.drag.semitones"),
                        onBegin: { viewModel.pushUndo() },
                        onChange: { new in
                            applySpeedDeltaSemis(new - relSemis)
                            relSemis = new
                        },
                        onReset: { resetSpeedSelected() }
                    )
                }
            }
            .opacity(selectionHasGroup ? 0.4 : 1)
            .disabled(selectionHasGroup)
            // `helpIf` and not `help`: an empty tooltip on this Group would override those of the
            // Speed / Semitones boxes it contains. @see helpIf
            .helpIf(selectionHasGroup ? L("inspector.speed.disabledByGroup") : nil)
        }
    }

    /// One row of a 'batch' setting: the label (+ a 'rel.' badge if relative) on the left, the box on the right.
    private func batchRow<C: View>(_ label: String, relative: Bool,
                                   @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            if relative {
                Text(L("inspector.badge.relative"))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)))
                    .help(L("inspector.badge.relative.help"))
            }
            Spacer(minLength: 8)
            control()
        }
    }

    // Sends column: one checkbox plus one graphical box per aux overlapping the selection.
    // Relative if the levels differ from one object to another (preserving the differences), absolute otherwise.
    private var multiSendsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("inspector.section.sends")).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            ForEach(viewModel.selectionSendAuxes()) { aux in
                let rel = sendRelative[aux.id] ?? false
                let auxLabel = aux.label ?? L("aux.defaultLabel", Int(aux.startTime.rounded()))
                batchRow(auxLabel, relative: rel) {
                    HStack(spacing: 6) {
                        Toggle(noLabel, isOn: Binding(
                            get: {
                                let ids = viewModel.selectedSenders(toAux: aux.id)
                                return !ids.isEmpty && ids.allSatisfy { viewModel.isSendEnabled(from: $0, to: aux.id) }
                            },
                            set: { on in viewModel.edit { viewModel.setSendEnabledSelected(toAux: aux.id, enabled: on) } }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()

                        DragValueBox(
                            value: relSend[aux.id] ?? Double(sendMinDb),
                            format: { v in
                                if rel { return v <= Double(sendMinDb) ? "−∞" : String(format: "%+.0f dB", v) }
                                return sendLevelString(Float(v))
                            },
                            range: Double(sendMinDb)...Double(sendMaxDb),
                            pointsPerStep: 6, snap: true, width: 56, keyStep: 1,
                            help: L("help.drag.send"),
                            onBegin: { viewModel.pushUndo() },
                            onChange: { new in
                                let old = relSend[aux.id] ?? Double(sendMinDb)
                                if rel { viewModel.adjustSendLevelSelected(toAux: aux.id, deltaDb: Float(new - old)) }
                                else   { viewModel.setSendLevelSelected(toAux: aux.id, levelDb: Float(new)) }
                                relSend[aux.id] = new
                            },
                            onReset: {
                                viewModel.edit { viewModel.setSendLevelSelected(toAux: aux.id, levelDb: sendMinDb) }
                                relSend[aux.id] = Double(sendMinDb); sendRelative[aux.id] = false
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Multiple-selection helpers

    private var selectedObjects: [SoundObject] {
        viewModel.selectedIDs
            .compactMap { viewModel.find(id: $0) }
            .sorted { $0.startTime < $1.startTime }
    }

    private var selectionHasGroup: Bool {
        selectedObjects.contains { isGroup($0) }
    }

    private var selectedClipIDs: [UUID] {
        selectedObjects.filter { !isGroup($0) }.map(\.id)
    }

    private func isGroup(_ o: SoundObject) -> Bool {
        if case .group = o.kind { return true }
        return false
    }

    /// Applies a pitch delta (in semitones) to each clip of the selection,
    /// multiplicatively so as to preserve the speed differences between items.
    private func applySpeedDeltaSemis(_ dSemis: Double) {
        guard dSemis != 0 else { return }
        let factor = pow(2.0, dSemis / 12.0)
        for id in selectedClipIDs {
            if let o = viewModel.find(id: id) {
                viewModel.updateSpeed(id: id, ratio: o.speedRatio * factor)
            }
        }
    }

    private func resetSpeedSelected() {
        viewModel.edit { for id in selectedClipIDs { viewModel.updateSpeed(id: id, ratio: 1.0) } }
        relSemis = 0; speedRelative = false
    }

    // MARK: - Shared values (uniform → absolute mode, otherwise → relative mode at 0)

    private var uniformVolume: Float? {
        let vals = selectedObjects.map(\.volume)
        guard let f = vals.first, vals.allSatisfy({ $0 == f }) else { return nil }
        return f
    }

    private var uniformPan: Float? {
        let vals = selectedObjects.map(\.pan)
        guard let f = vals.first, vals.allSatisfy({ $0 == f }) else { return nil }
        return f
    }

    /// The stem shared by the whole selection (nil if mixed) — used to tick the current strip.
    /// `stemID == nil` on an object ⇒ Main, so we normalise before comparing.
    private var uniformStemID: UUID? {
        let ids = selectedObjects.map { $0.stemID ?? viewModel.mainStemID }
        guard let f = ids.first, ids.allSatisfy({ $0 == f }) else { return nil }
        return f
    }

    private var uniformSemis: Double? {
        let vals = selectedObjects.filter { !isGroup($0) }.map(\.speedRatio)
        guard let f = vals.first, vals.allSatisfy({ abs($0 - f) < 1e-6 }) else { return nil }
        return 12 * log2(f)
    }

    private func refreshMultiBaselines() {
        if let v = uniformVolume { relVolume = Double(v); volRelative = false }
        else { relVolume = 0; volRelative = true }

        if let p = uniformPan { relPan = Double(p); panRelative = false }
        else { relPan = 0; panRelative = true }

        if let s = uniformSemis { relSemis = s; speedRelative = false }
        else { relSemis = 0; speedRelative = true }

        relSend.removeAll(); sendRelative.removeAll()
        for aux in viewModel.selectionSendAuxes() {
            let levels = viewModel.selectedSenders(toAux: aux.id)
                .map { viewModel.sendLevel(from: $0, to: aux.id) }
            if let f = levels.first, levels.allSatisfy({ $0 == f }) {
                relSend[aux.id] = Double(f); sendRelative[aux.id] = false
            } else {
                relSend[aux.id] = 0; sendRelative[aux.id] = true
            }
        }
    }

    // MARK: - No selection

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(L("inspector.empty"))
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
