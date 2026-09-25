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

    // Pan, and pan alone, anchors its gesture: the range being ±1, the selection saturates in one
    // flick, and a delta compounded on the stored value would leave the objects stuck at the edge
    // with their spread lost. Taken at each `onBegin` — the start of a drag, or one arrow press.
    @State private var panAnchors: [UUID: Float] = [:]
    @State private var panOrigin: Double = 0

    // Sends in a multiple selection: the slider's current position and the 'relative' flag
    // per aux (the key being the auxID), the same logic as relVolume/volRelative.
    @State private var relSend: [UUID: Double] = [:]
    @State private var sendRelative: [UUID: Bool] = [:]
    /// The wav-BPM field of a multiple selection: the shared base, empty when they differ.
    @State private var multiBaseBPMText: String = ""
    /// The target-BPM box has been moved during this selection: every sound now shares it, so it
    /// shows a value rather than '≠'.
    @State private var multiTargetTouched: Bool = false
    /// The selection's volumes / pans right after the box's OWN last write: a change that lands on
    /// exactly this is the box's echo, anything else came from elsewhere and is read back.
    @State private var volOwnWrite: [UUID: Float]? = nil
    @State private var panOwnWrite: [UUID: Float]? = nil
    /// A send box's gesture: every level as it stood at the start, and the box's value then.
    @State private var sendAnchors: [UUID: Float] = [:]
    @State private var sendOrigin: Double = 0

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
    //
    // The same reading as a single object, top to bottom: WHAT is selected (the items, drawn as
    // small blocks of the timeline — colour, corners, glyph, name), then the zones of the signal
    // view in their own order — audio file, clip mix, sends, stems — with the same controls and
    // the same gestures. What differs is only what a batch needs: the 'rel.' badge when the values
    // differ (a delta preserving the differences), and a zone that does not make sense for every
    // item is simply absent (the audio file needs a selection of sounds only).

    private var multiSelectionContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("inspector.selection.count", selectedObjects.count))
                    .font(.caption).foregroundStyle(.secondary)
                selectionItems
                    .padding(.bottom, 4)
                if !selectedSounds.isEmpty && selectedSounds.count == selectedObjects.count {
                    multiAudioFileZone
                }
                multiClipZone
                if !viewModel.selectionSendAuxes().isEmpty { multiSendsZone }
                multiStemsZone
            }
            .padding(12)
            .frame(width: multiColumnWidth, alignment: .topLeading)
        }
        // (Re)initialises the slider positions on every change of selection:
        // the shared value if it is uniform (absolute mode), otherwise 0 (relative mode).
        .onAppear { refreshMultiBaselines() }
        .onChange(of: viewModel.selectedIDs) { _, _ in refreshMultiBaselines() }
        // What moves the values from ELSEWHERE — v/p + ↑/↓, the wheel, the Pan tool, an undo —
        // is read back into the boxes; the boxes' own writes are recognised and left alone.
        .onChange(of: volumeSignature) { old, new in resyncVolume(old, new) }
        .onChange(of: panSignature) { old, new in resyncPan(old, new) }
    }

    /// The width of the single multiple-selection column: the signal view's own zone width and a
    /// little more, so the zones read at the size they have for one object.
    private let multiColumnWidth: CGFloat = 280

    // MARK: Items

    /// The items flow and wrap, a block each; what they are worth is in the tooltip.
    private var selectionItems: some View {
        ItemFlowLayout(spacing: 4) {
            ForEach(selectedObjects) { obj in
                itemBlock(obj)
                    .help(itemValueSummary(obj) + (itemSendSummary(obj).map { "\n" + $0 } ?? ""))
            }
        }
    }

    /// One item, drawn as its timeline block is: a white base under the stem (or custom) colour at
    /// the SELECTED opacity, the block's border, its corners (square-ish for a sound or a MIDI
    /// clip, round for a group or an aux — `blockCornerRadius`, scaled to a 22 px block), then the
    /// kind glyph and the name, black, red for a missing file.
    /// Click = this one alone; ⌘-click = out of (or into) the selection — the timeline's own rule.
    private func itemBlock(_ obj: SoundObject) -> some View {
        let color = obj.customColor ?? viewModel.stemColor(for: obj.id)
        let round = obj.blockCornerRadius >= 20
        let shape = RoundedRectangle(cornerRadius: round ? 9 : 3)
        let missing = viewModel.isMissing(obj)
        return HStack(spacing: 4) {
            Image(systemName: ObjectKindIcon.name(for: obj,
                                                  isOpenConsolidate: viewModel.isInConsolidateEditStack(obj.id)))
                .font(.system(size: 10, weight: .bold))
                .blockIconStyle(missingFile: missing)
            Text(obj.displayName)
                .font(.system(size: 11, weight: .medium))
                .blockNameStyle(missingFile: missing)
                .lineLimit(1).truncationMode(.middle)
            // Always laid out, shown only when muted: a mute must not reflow the whole bunch.
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 8)).foregroundStyle(Color.black.opacity(0.5))
                .opacity(obj.isMuted ? 1 : 0)
        }
        .padding(.horizontal, round ? 8 : 5)
        .frame(height: 22)
        .background(shape.fill(color.opacity(0.55)))
        .background(shape.fill(Color.white))
        .overlay(shape.strokeBorder(color.opacity(0.9), lineWidth: 1.5))
        .contentShape(shape)
        .onTapGesture {
            viewModel.select(obj.id, additive: NSEvent.modifierFlags.contains(.command))
        }
    }

    // MARK: Zones (the signal view's, @see AudioFileZoneView / ClipMixZoneView / SendsZoneView / StemsZoneView)

    /// A zone's frame: the signal view's rounded rectangle, dashed for a branch (the sends).
    private func zone<C: View>(dashed: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : [])))
    }

    private func zoneTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
    }

    /// The 'rel.' badge: the box moves every value by the same delta, the differences are kept.
    @ViewBuilder
    private func relBadge(_ relative: Bool) -> some View {
        if relative {
            Text(L("inspector.badge.relative"))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)))
                .help(L("inspector.badge.relative.help"))
        }
    }

    /// A toggle pill of the signal view (loop / reverse): on = accent, off = grey, and a MIXED
    /// selection half-lit — the click then turns it on for everyone.
    private func pill(_ text: String, on: Bool?, action: @escaping () -> Void) -> some View {
        let lit = on ?? false
        return Button(action: action) {
            Text(text)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(lit ? Color.white : Color.secondary)
                .padding(.horizontal, 6).frame(height: 16)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(lit ? Color.accentColor
                          : (on == nil ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18))))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.35)))
        }
        .buttonStyle(.plain)
    }

    // 'audio file': shown only when EVERY item is a sound — a group, an aux or a MIDI clip has
    // no file to speed up, reverse or give a tempo.
    private var multiAudioFileZone: some View {
        let sounds = selectedSounds
        return zone {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) {
                    zoneTitle(L("synoptic.audioFile"))
                    relBadge(speedRelative)
                    Spacer(minLength: 0)
                    pill(L("synoptic.reverse.label"), on: uniformReversed) {
                        let target = !(uniformReversed ?? false)
                        viewModel.edit {
                            for o in sounds where o.isReversed != target {
                                viewModel.updateReversed(id: o.id, reversed: target)
                            }
                        }
                    }
                    .help(uniformReversed == nil ? L("inspector.reverse.mixed")
                          : (uniformReversed! ? L("synoptic.reverse.on") : L("synoptic.reverse.off")))
                }
                HStack(spacing: 6) {
                    DragValueBox(
                        value: relSemis,
                        format: { v in
                            speedRelative ? String(format: "×%.2f", pow(2.0, v / 12.0))
                                          : String(format: "%.2f×", pow(2.0, v / 12.0))
                        },
                        range: -48...48, pointsPerStep: 6, snap: false, width: 52, keyStep: 1,
                        parse: { Double($0.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "×", with: "").replacingOccurrences(of: "x", with: "")).map { 12 * log2(max(1e-6, $0)) } },
                        help: L("help.drag.speed"),
                        onBegin: { viewModel.pushUndo() },
                        onChange: { new in
                            applySpeedDeltaSemis(new - relSemis)
                            relSemis = new
                        },
                        onReset: { resetSpeedSelected() }
                    )
                    DragValueBox(
                        value: relSemis,
                        format: { v in
                            let r = v.rounded()
                            if abs(v - r) < 0.05 { return r == 0 ? "0 st" : String(format: "%+.0f st", r) }
                            return String(format: "%+.1f st", v)
                        },
                        range: -48...48, pointsPerStep: 6, snap: true, width: 48, keyStep: 1,
                        help: L("help.drag.semitones"),
                        onBegin: { viewModel.pushUndo() },
                        onChange: { new in
                            applySpeedDeltaSemis(new - relSemis)
                            relSemis = new
                        },
                        onReset: { resetSpeedSelected() }
                    )
                    Spacer(minLength: 0)
                    multiBPMFields(sounds)
                }
            }
        }
    }

    /// The wav's BPM → the target BPM, as for one object. The wav field SETS every sound's base
    /// (empty = clears it); the target puts EVERY sound on that tempo (speed = target / base) —
    /// the batch's most useful gesture, aligning takes of different tempos at once. It needs a base
    /// on every sound, a dash otherwise; mixed targets read '≠' until moved.
    @ViewBuilder
    private func multiBPMFields(_ sounds: [SoundObject]) -> some View {
        TextField(text: $multiBaseBPMText) { Text(verbatim: uniformBaseBPM == nil && sounds.contains { $0.baseBPM != nil } ? "≠" : "—") }
            .frame(width: max(22, CGFloat(max(2, multiBaseBPMText.count)) * 6.2 + 6))
            .multilineTextAlignment(.center)
            .font(.system(size: 10, design: .monospaced))
            .textFieldStyle(.plain)
            .padding(.horizontal, 3).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.45)))
            .onSubmit { commitMultiBaseBPM(sounds) }
            .help(L("synoptic.wavBPM"))
        Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
        let bases = sounds.compactMap { o in o.baseBPM.flatMap { $0 > 0 ? $0 : nil } }
        if bases.count == sounds.count, let first = sounds.first, let firstBase = first.baseBPM {
            DragValueBox(
                value: firstBase * first.speedRatio,
                format: { uniformTargetBPM == nil && !multiTargetTouched ? "≠" : TempoText.display(TempoText.rounded($0)) },
                range: 20...400, pointsPerStep: 2, width: 38,
                keyStep: 1, fineKeyStep: 0.1, coarseKeyStep: 10,
                fitsContent: true,
                parse: { TempoText.parse($0) },
                help: L("help.drag.bpm"),
                onBegin: { viewModel.pushUndo(); multiTargetTouched = true },
                onChange: { new in
                    let target = TempoText.rounded(new)
                    for o in sounds { if let b = o.baseBPM, b > 0 { viewModel.updateSpeed(id: o.id, ratio: target / b) } }
                    refreshSpeedBaseline()
                },
                onReset: { resetSpeedSelected() }
            )
        } else {
            Text(verbatim: "—")
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 38, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)))
        }
        Text(verbatim: "bpm").font(.system(size: 9)).foregroundStyle(.secondary)
            .fixedSize().layoutPriority(1)
    }

    private func commitMultiBaseBPM(_ sounds: [SoundObject]) {
        let t = multiBaseBPMText.trimmingCharacters(in: .whitespaces)
        let bpm: Double? = t.isEmpty ? nil : TempoText.parse(t).flatMap { $0 > 0 ? $0 : nil }
        guard t.isEmpty || bpm != nil else { syncMultiBaseBPMText(); return }
        viewModel.edit { for o in sounds { viewModel.updateBaseBPM(id: o.id, bpm: bpm) } }
        syncMultiBaseBPMText()
    }

    private func syncMultiBaseBPMText() {
        multiBaseBPMText = uniformBaseBPM.map { TempoText.display($0) } ?? ""
    }

    // 'clip' (the mix): pan, volume and mute on one line, as for one object.
    private var multiClipZone: some View {
        zone {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 3) { Text(L("inspector.field.pan")).font(.system(size: 9)).foregroundStyle(.secondary); relBadge(panRelative) }
                        multiPanBox
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 3) { Text(L("inspector.field.volume")).font(.system(size: 9)).foregroundStyle(.secondary); relBadge(volRelative) }
                        HStack(spacing: 4) {
                            multiVolumeBox
                            multiMuteButton
                        }
                    }
                }
            }
        }
    }

    private var multiVolumeBox: some View {
        DragValueBox(
            value: relVolume,
            format: { v in
                if volRelative { return v <= -96 ? "-∞" : String(format: "%+.0f dB", v) }
                return v <= -96 ? "-∞ dB" : String(format: "%.0f dB", v)
            },
            // Relative: at most +40 dB up per gesture (already enormous), enough down to take
            // anything to −∞; each object is clamped on its own.
            range: volRelative ? -136...40 : -96...40, pointsPerStep: 6, snap: true, width: 56, keyStep: 1,
            help: L("help.drag.volume"),
            // Touching the control: the fader becomes the 'future automation' row of EVERY object
            // in the batch, without any value having to move.
            onTouch: { for id in viewModel.selectedIDs { viewModel.recordAutomationTouch(id, .volume) } },
            onBegin: { viewModel.pushUndo() },
            onChange: { new in
                viewModel.adjustVolumeDB(Float(new - relVolume))
                relVolume = new
                volOwnWrite = volumeSignature
            },
            onReset: {
                viewModel.edit { viewModel.resetVolumeSelected() }
                relVolume = 0; volRelative = false
            }
        )
    }

    /// The mute of the whole selection: lit when every item is muted, half-lit when some are.
    private var multiMuteButton: some View {
        let muted = selectedObjects.filter(\.isMuted).count
        let all = !selectedObjects.isEmpty && muted == selectedObjects.count
        return Button { viewModel.edit { viewModel.toggleMuteSelected() } } label: {
            Image(systemName: all ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(all ? Color.white : (muted > 0 ? Color.red : Color.secondary))
                .frame(width: 20, height: 18)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(all ? Color.red : (muted > 0 ? Color.red.opacity(0.18) : Color.secondary.opacity(0.18))))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.35)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("common.mute"))
    }

    private var multiPanBox: some View {
        DragValueBox(
            value: relPan,
            format: { p in
                // The RELATIVE mode shows a travel, not a position — but in the SAME unit as
                // the absolute one, and as the direct entry, which parses a percentage
                // (`parse` below divides by 100). It read `-0.50` where one types 50 and
                // where the row above says `+3 dB`: a unit shown in one place and hidden in
                // the other is a number one has to translate before trusting it.
                if panRelative {
                    let pct = Int((p * 100).rounded())
                    return pct == 0 ? "0%" : String(format: "%+d%%", pct)
                }
                return abs(p) < 0.01 ? "C" : (p < 0 ? "L \(Int((-p*100).rounded()))%" : "R \(Int((p*100).rounded()))%")
            },
            // keyStep = the DETENT itself (@see EditViewModel+Pan): the arrows walk the
            // tenths rather than halving them.
            range: panRelative ? -2...2 : -1...1, pointsPerStep: 80, snap: false, width: 52, keyStep: 0.1,
            parse: { Double($0.replacingOccurrences(of: ",", with: ".")).map { $0 / 100 } },
            help: L("help.drag.pan"),
            onTouch: { for id in viewModel.selectedIDs { viewModel.recordAutomationTouch(id, .pan) } },
            onBegin: {
                viewModel.pushUndo()
                panAnchors = viewModel.panSnapshot()
                panOrigin = relPan
            },
            onChange: { new in
                // The box's own value is brought onto the detent BEFORE it is shown, or the
                // display would read 13 % over a model that the gesture has put on 10 %:
                // `relPan` is a local accumulator, nothing reads the objects back into it
                // during a drag. Quantising it does not compound — DragValueBox works from
                // the travel since the gesture's start, never from the value it last wrote.
                let stepped = Double(EditViewModel.detentedPan(Float(new)))
                viewModel.applyPanDelta(Float(stepped - panOrigin), from: panAnchors)
                relPan = stepped
                panOwnWrite = panSignature
            },
            onReset: {
                viewModel.edit { viewModel.resetPanSelected() }
                relPan = 0; panRelative = false
            }
        )
    }

    // 'aux' (the sends, dashed: a branch leaving the trunk): one row per aux the selection
    // overlaps, the signal view's row shape — arrow, name, level, power.
    private var multiSendsZone: some View {
        zone(dashed: true) {
            VStack(alignment: .leading, spacing: 4) {
                zoneTitle(L("synoptic.zone.aux"))
                ForEach(viewModel.selectionSendAuxes()) { aux in
                    multiSendRow(aux)
                }
            }
        }
    }

    private func multiSendRow(_ aux: SoundObject) -> some View {
        let rel = sendRelative[aux.id] ?? false
        let auxLabel = aux.label ?? L("aux.defaultLabel", Int(aux.startTime.rounded()))
        let ids = viewModel.selectedSenders(toAux: aux.id)
        let enabledCount = ids.filter { viewModel.isSendEnabled(from: $0, to: aux.id) }.count
        let allOn = !ids.isEmpty && enabledCount == ids.count
        return HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabledCount > 0 ? Color.accentColor : Color.secondary.opacity(0.6))
                .frame(width: 14)
            Text(auxLabel)
                .font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(enabledCount > 0 ? .primary : .secondary)
            relBadge(rel)
            Spacer(minLength: 4)
            DragValueBox(
                value: relSend[aux.id] ?? Double(sendMinDb),
                format: { v in
                    if rel { return String(format: "%+.0f dB", v) }
                    return sendLevelString(Float(v))
                },
                // Relative: the whole span in both directions, so a send at −∞ can be brought up
                // to 0 dB by the same travel that takes another from −6 to its +6 ceiling — each
                // send is clamped on its own, from where it stood when the gesture began.
                range: rel ? -Double(sendMaxDb - sendMinDb)...Double(sendMaxDb - sendMinDb)
                           : Double(sendMinDb)...Double(sendMaxDb),
                pointsPerStep: 6, snap: true, width: 52, keyStep: 1,
                help: L("help.drag.send"),
                onBegin: {
                    viewModel.pushUndo()
                    sendAnchors = Dictionary(uniqueKeysWithValues:
                        viewModel.selectedSendersWithFreeLevel(toAux: aux.id)
                            .map { ($0, viewModel.sendLevel(from: $0, to: aux.id)) })
                    sendOrigin = relSend[aux.id] ?? (rel ? 0 : Double(sendMinDb))
                },
                onChange: { new in
                    if rel {
                        // From the ANCHORS, never from the stored values: a send pinned at +6 by
                        // the way up comes back to where it was on the way down.
                        let d = Float(new - sendOrigin)
                        for (id, a) in sendAnchors { viewModel.setSendLevel(from: id, to: aux.id, levelDb: a + d) }
                    } else {
                        viewModel.setSendLevelSelected(toAux: aux.id, levelDb: Float(new))
                    }
                    relSend[aux.id] = new
                },
                onReset: {
                    viewModel.edit { viewModel.setSendLevelSelected(toAux: aux.id, levelDb: sendMinDb) }
                    relSend[aux.id] = Double(sendMinDb); sendRelative[aux.id] = false
                }
            )
            .opacity(enabledCount > 0 ? 1 : 0.5)
            Button {
                viewModel.edit { viewModel.setSendEnabledSelected(toAux: aux.id, enabled: !allOn) }
            } label: {
                let tint: Color = enabledCount > 0 ? Color.accentColor : Color.secondary
                Image(systemName: "power")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(tint.opacity(allOn ? 0.18 : 0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(tint.opacity(allOn ? 0.45 : 0.25),
                                      style: StrokeStyle(lineWidth: 1, dash: allOn || enabledCount == 0 ? [] : [2, 2])))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("common.mute"))
        }
        .frame(height: SynopticLayout.sendRowH)
    }

    // 'stems': the destination, one menu. The background takes the current stem's colour; a mixed
    // selection shows 'Multiple values' on a neutral background. Each item is prefixed with its
    // keyboard shortcut number (1 = Main, 2 = the 2nd stem…).
    private var multiStemsZone: some View {
        let current = uniformStemID                                   // nil = mixed values
        let isMain  = current != nil && current == viewModel.mainStemID
        let stemObj = current.flatMap { id in viewModel.stems.first { $0.id == id } }
        let tint: Color = current == nil ? Color.secondary : (stemObj?.color ?? .secondary)
        let label: String = current == nil ? L("inspector.stem.mixedValues")
                                            : (isMain ? L("stem.main.name") : (stemObj?.name ?? "—"))
        return zone {
            HStack(spacing: 8) {
                zoneTitle(L("synoptic.zone.stems"))
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
    }

    private func itemValueSummary(_ o: SoundObject) -> String {
        // When automated, volume and pan are worth what their curve plays at the playback position:
        // that is what one hears, and the static setting no longer says anything (@see
        // EditViewModel.liveAutomationValue).
        let v = viewModel.liveAutomationValue(.volume, on: o.id) ?? o.volume
        let p = viewModel.liveAutomationValue(.pan,    on: o.id) ?? o.pan
        let vol = v <= -96 ? "-∞" : "\(Int(v.rounded()))dB"
        let pan = abs(p) < 0.01 ? "C" : (p < 0 ? "L\(Int(-p*100))" : "R\(Int(p*100))")
        if !o.isClip { return "\(vol) · \(pan)" }
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

    // MARK: - Multiple-selection helpers

    private var selectedObjects: [SoundObject] {
        viewModel.selectedIDs
            .compactMap { viewModel.find(id: $0) }
            .sorted { $0.startTime < $1.startTime }
    }

    /// The SOUNDS of the selection — the audio clips, the only objects with a file to play faster,
    /// to reverse or to give a tempo. A group, an aux or a MIDI clip is left out of the speed.
    private var selectedSounds: [SoundObject] {
        selectedObjects.filter(\.isClip)
    }

    private var selectedClipIDs: [UUID] {
        selectedSounds.map(\.id)
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
        let vals = selectedSounds.map(\.speedRatio)
        guard let f = vals.first, vals.allSatisfy({ abs($0 - f) < 1e-6 }) else { return nil }
        return 12 * log2(f)
    }

    /// true / false when every sound agrees, nil when they differ (the pill then half-lit).
    private var uniformReversed: Bool? {
        let vals = selectedSounds.map(\.isReversed)
        guard let f = vals.first, vals.allSatisfy({ $0 == f }) else { return nil }
        return f
    }

    private var uniformBaseBPM: Double? {
        let vals = selectedSounds.map(\.baseBPM)
        guard let f = vals.first, let v = f, vals.allSatisfy({ $0 == f }) else { return nil }
        return v
    }

    /// The tempo every sound plays at (base × speed), nil if they differ or one has no base.
    private var uniformTargetBPM: Double? {
        let vals = selectedSounds.map { o in o.baseBPM.map { TempoText.rounded($0 * o.speedRatio) } }
        guard let f = vals.first, let v = f, vals.allSatisfy({ $0 == f }) else { return nil }
        return v
    }

    /// After the target BPM has moved every speed: the speed boxes read the new state.
    private func refreshSpeedBaseline() {
        if let s = uniformSemis { relSemis = s; speedRelative = false }
        else { relSemis = 0; speedRelative = true }
    }

    private var volumeSignature: [UUID: Float] {
        Dictionary(uniqueKeysWithValues: selectedObjects.map { ($0.id, $0.volume) })
    }

    private var panSignature: [UUID: Float] {
        Dictionary(uniqueKeysWithValues: selectedObjects.map { ($0.id, $0.pan) })
    }

    /// The volumes moved and the box did not do it (v + ↑/↓, the wheel, an undo…): a shared value
    /// is shown as it is; differing values keep the box relative and add what the FIRST item
    /// travelled — the same delta the keyboard gave everyone. A change of selection is left to
    /// `refreshMultiBaselines`.
    private func resyncVolume(_ old: [UUID: Float], _ new: [UUID: Float]) {
        guard Set(old.keys) == Set(new.keys), new != volOwnWrite else { return }
        if let v = uniformVolume { relVolume = Double(v); volRelative = false; return }
        if volRelative, let ref = selectedObjects.first?.id, let a = old[ref], let b = new[ref] {
            relVolume += Double(b - a)
        } else {
            relVolume = 0; volRelative = true
        }
    }

    /// @see resyncVolume — the same reading for the pan.
    private func resyncPan(_ old: [UUID: Float], _ new: [UUID: Float]) {
        guard Set(old.keys) == Set(new.keys), new != panOwnWrite else { return }
        if let p = uniformPan { relPan = Double(p); panRelative = false; return }
        if panRelative, let ref = selectedObjects.first?.id, let a = old[ref], let b = new[ref] {
            relPan += Double(b - a)
        } else {
            relPan = 0; panRelative = true
        }
    }

    private func refreshMultiBaselines() {
        if let v = uniformVolume { relVolume = Double(v); volRelative = false }
        else { relVolume = 0; volRelative = true }

        if let p = uniformPan { relPan = Double(p); panRelative = false }
        else { relPan = 0; panRelative = true }

        volOwnWrite = nil; panOwnWrite = nil
        refreshSpeedBaseline()
        syncMultiBaseBPMText()
        multiTargetTouched = false

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

/// The blocks of a large selection, flowing left to right and wrapping — a row per block would
/// push the zones out of the dock past a dozen items.
private struct ItemFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (i, p) in rows.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y),
                              proposal: ProposedViewSize(rows.sizes[i]))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews)
        -> (origins: [CGPoint], sizes: [CGSize], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = [], sizes: [CGSize] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for sv in subviews {
            var sz = sv.sizeThatFits(.unspecified)
            sz.width = min(sz.width, width)
            if x > 0, x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            origins.append(CGPoint(x: x, y: y)); sizes.append(sz)
            x += sz.width + spacing; rowH = max(rowH, sz.height); maxX = max(maxX, x - spacing)
        }
        return (origins, sizes, maxX, y + rowH)
    }
}
