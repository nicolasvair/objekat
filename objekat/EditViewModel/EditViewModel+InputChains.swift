import Foundation

// MARK: - FX on an audio input, an instrument on a MIDI input (docs/plan_groupes_midi.md, E9)
//
// The model (`InputChains`) is the project's; the ENGINE holds a chain only while it is wanted — the input is HEARD, or
// the chain is OPEN (an editor, a popover, a script): a project with five input instruments does not load five
// instruments. Mounting = registering the host id with the engine (`OBJEngineCore.registerAudioInputHost` /
// `registerMidiInputHost`) and compiling the chain; unmounting = capturing the live states into the model, then
// unregistering. `syncInputChains` is the one function that decides, and it is idempotent: every event that can change
// the answer (monitor on/off, a card or a MIDI device that comes or goes, a load, a tab return, an undo) calls it.
//
// The ordinary plugin pipeline reaches a host through `chainPlugins` / `updateChainPlugins` (third case, after the
// stems), so `plugin.*`, the synoptic and the editors need nothing new. A MIDI host holds an INSTRUMENT
// (`inputChains.midi[…].instrument`, reached through the `input.*` doors) and, after it, audio FX (`.plugins`, the
// ordinary FX list: instrument first on the engine's hidden track, then the FX compiled behind it).

extension EditViewModel {

    enum InputHostKind: Equatable {
        case audio(key: String)
        case midi(deviceID: String)
    }

    // MARK: Lookup

    func inputHostKind(_ hostID: UUID) -> InputHostKind? {
        if let k = inputChains.audioKey(ofHost: hostID) { return .audio(key: k) }
        if let k = inputChains.midiKey(ofHost: hostID) { return .midi(deviceID: k) }
        return nil
    }

    func isInputHost(_ id: UUID) -> Bool { inputChains.contains(host: id) }

    /// The host of a card input, nil when it has no chain record yet.
    func audioInputHostID(_ ref: InputRef) -> UUID? { inputChains.audio[ref.key]?.hostID }

    /// The key of the MIDI chain that stands for `device`: its own id, else a chain remembered under another id
    /// that resolves to it (the same rule as a zone's input).
    func midiChainKey(for device: MidiInputInfo) -> String? {
        if inputChains.midi[device.id] != nil { return device.id }
        return inputChains.midi.first { _, chain in
            MidiInputResolver.resolve(chain.input, in: midiInputs)?.id == device.id
        }?.key
    }

    func midiInputHostID(_ device: MidiInputInfo) -> UUID? {
        midiChainKey(for: device).flatMap { inputChains.midi[$0]?.hostID }
    }

    /// The host of a card input; an empty chain record is made when there is none (not written until it holds something).
    @discardableResult
    func ensureAudioInputHost(_ ref: InputRef) -> UUID {
        if let h = audioInputHostID(ref) { return h }
        let h = UUID()
        inputChains.audio[ref.key] = InputChain(hostID: h, plugins: [])
        return h
    }

    @discardableResult
    func ensureMidiInputHost(_ device: MidiInputInfo) -> UUID {
        if let h = midiInputHostID(device) { return h }
        let h = UUID()
        inputChains.midi[device.id] = MidiInputChain(hostID: h, input: device.ref, instrument: nil)
        return h
    }

    // MARK: Chain access (what `chainPlugins` / `updateChainPlugins` fall back on)

    /// The FX of a host (a MIDI host's come AFTER its instrument); nil when `hostID` is no input host.
    func inputChainPlugins(_ hostID: UUID) -> [ObjectPlugin]? {
        if let k = inputChains.audioKey(ofHost: hostID) { return inputChains.audio[k]?.plugins }
        if let k = inputChains.midiKey(ofHost: hostID) { return inputChains.midi[k]?.plugins }
        return nil
    }

    @discardableResult
    func updateInputChainPlugins(_ hostID: UUID, _ f: (inout [ObjectPlugin]) -> Void) -> Bool {
        if let k = inputChains.audioKey(ofHost: hostID), var chain = inputChains.audio[k] {
            f(&chain.plugins)
            Self.settlingChannelPicks(&chain.plugins)
            inputChains.audio[k] = chain
            isDirty = true
            return true
        }
        if let k = inputChains.midiKey(ofHost: hostID), var chain = inputChains.midi[k] {
            f(&chain.plugins)
            Self.settlingChannelPicks(&chain.plugins)
            inputChains.midi[k] = chain
            isDirty = true
            return true
        }
        return false
    }

    /// The instrument of a MIDI host.
    func inputInstrument(_ hostID: UUID) -> ObjectPlugin? {
        inputChains.midiKey(ofHost: hostID).flatMap { inputChains.midi[$0]?.instrument }
    }

    // MARK: Is it heard / open

    /// Whether the card input is heard through the mix right now (the engine owns this).
    func isInputHeard(_ ref: InputRef) -> Bool { monitoredInputs.contains(ref) }

    /// The MIDI devices heard through an instrument (the engine owns this).
    var heardMidiDeviceIDs: Set<String> { Set(engine?.midiInputMonitors() ?? []) }

    func isMidiInputHeard(_ device: MidiInputInfo) -> Bool { heardMidiDeviceIDs.contains(device.id) }

    /// The hosts that should be alive on the engine right now.
    private func wantedInputHosts() -> Set<UUID> {
        var wanted = openInputHosts.filter { isInputHost($0) }
        for ref in monitoredInputs {
            if let c = inputChains.audio[ref.key], !c.isEmpty { wanted.insert(c.hostID) }
        }
        let heard = heardMidiDeviceIDs
        for chain in inputChains.midi.values where chain.instrument != nil {
            if let d = resolvedMidiInput(chain.input), heard.contains(d.id) { wanted.insert(chain.hostID) }
        }
        // An editor open on one of its plugins holds a chain mounted: closing a popover must not take the window away.
        for host in mountedInputHosts where isInputHost(host) && hasOpenEditor(host) { wanted.insert(host) }
        wanted.formUnion(editorHeldInputHosts.values.filter { isInputHost($0) })
        return wanted
    }

    private func hasOpenEditor(_ host: UUID) -> Bool {
        (Self.flattenLeaves(inputChainPlugins(host) ?? []) + (inputInstrument(host).map { [$0] } ?? []))
            .contains { isPluginEditorOpen(plug: $0) }
    }

    /// An editor is about to open on a plugin of `host`: the chain is mounted now and stays so until that editor closes.
    /// Nothing for a host that is not an input's (and nothing without an interface: no editor will come).
    func holdInputHost(_ host: UUID, forEditorOf plugin: UUID) {
        guard hasInterface, isInputHost(host) else { return }
        editorHeldInputHosts[plugin] = host
        syncInputChains()
    }

    /// An editor closed (✕, double click, ...): a chain kept mounted only for it can go. Deferred, since the close can
    /// come from inside an unmount.
    func editorDidClose(plugin: UUID) {
        guard editorHeldInputHosts.removeValue(forKey: plugin) != nil || !mountedInputHosts.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.syncInputChains() }
    }

    /// Holds a chain mounted although nothing is heard through it (an editor or a popover is open; a script asked).
    func openInputHost(_ hostID: UUID) {
        guard isInputHost(hostID) else { return }
        openInputHosts.insert(hostID)
        syncInputChains()
    }

    /// Lets go of it: unmounted unless it is heard.
    func closeInputHost(_ hostID: UUID) {
        guard openInputHosts.remove(hostID) != nil else { return }
        syncInputChains()
    }

    // MARK: The popup of an input's rectangle

    /// The host of the strip `source` stands for, made (empty) if it had none; nil for a MIDI input that is not listed.
    private func inputStripHost(_ source: RecordSource) -> UUID? {
        switch source {
        case .audio(let ref):
            return ensureAudioInputHost(ref)
        case .midi(let ref):
            return MidiInputResolver.resolve(ref, in: midiInputs).map { ensureMidiInputHost($0) }
        }
    }

    /// Runs on every change of `openInputStrip`: the chain behind the popup that closes is let go (unmounted unless it is
    /// heard), the one behind the popup that opens is held mounted for as long as it is open. The one door — a click, a
    /// script (`input.strip`), a tab switch and the panel's disappearance all come through the property.
    func syncOpenInputStripHost() {
        let wanted = openInputStrip.flatMap { inputStripHost($0) }
        if let old = openInputStripHost, old != wanted { closeInputHost(old) }
        openInputStripHost = wanted
        if let wanted { openInputHost(wanted) }
    }

    /// A click on an input's rectangle: opens its popup, closes it, or leaves it (@see InputStripClick).
    func applyInputStripClick(_ source: RecordSource, shift: Bool, command: Bool) {
        openInputStrip = InputStripClick.popupAfter(
            open: openInputStrip, clicked: source,
            action: InputStripClick.popupAction(shift: shift, command: command))
    }

    /// The badges an input's rectangle carries after its name (@see ObjectFeatureBadges): the FX of a card input; the
    /// instrument's FX of a MIDI input (a lone instrument has none).
    func inputStripBadges(_ source: RecordSource) -> [FeatureBadge] {
        switch source {
        case .audio(let ref):
            return ObjectFeatureBadges.badges(forInputChain: inputChains.audio[ref.key]?.plugins ?? [])
        case .midi(let ref):
            guard let device = MidiInputResolver.resolve(ref, in: midiInputs),
                  let chain = midiChainKey(for: device).flatMap({ inputChains.midi[$0] }) else { return [] }
            return ObjectFeatureBadges.badges(forInputChain: chain.plugins,
                                              instruments: chain.instrument.map { [$0] } ?? [])
        }
    }

    // MARK: Mounting

    /// Brings the engine in line with what is wanted: mounts the chains that are heard or open, unmounts the others,
    /// and re-registers the ones whose input came back. Idempotent and cheap when nothing moved.
    func syncInputChains() {
        guard engine != nil else { return }
        let wanted = wantedInputHosts()
        for host in mountedInputHosts.subtracting(wanted) { unmountInputHost(host, capture: true) }
        // A chain forgotten by the model (an undo, a new project) leaves nothing mounted behind.
        for host in mountedInputHosts where !isInputHost(host) { unmountInputHost(host, capture: false) }
        for host in wanted { mountInputHost(host) }
    }

    /// Registers `host` with the engine and compiles its chain once its input is live. A host whose input is absent
    /// stays registered but dormant: the next `syncInputChains` (card or device list changed) tries again.
    func mountInputHost(_ host: UUID) {
        guard let engine, let kind = inputHostKind(host) else { return }
        switch kind {
        case .audio(let key):
            guard let ref = InputChains.inputRef(forKey: key) else { return }
            if mountedInputHosts.contains(host), compiledInputHosts.contains(host),
               engine.inputHostIsLive(host.uuidString) { return }
            mountedInputHosts.insert(host)
            let live = engine.registerAudioInputHost(host.uuidString, first: ref.first, count: ref.count)
            if live {
                // Compiled whatever the chain holds: an empty list also clears what a former mount left behind.
                compileRack(objectID: host)
                compiledInputHosts.insert(host)
            } else {
                compiledInputHosts.remove(host)
            }
        case .midi(let deviceKey):
            guard let chain = inputChains.midi[deviceKey] else { return }
            guard let device = resolvedMidiInput(chain.input) else {
                // The device is not there: nothing to register, the chain waits (dormant).
                if mountedInputHosts.contains(host) { unmountInputHost(host, capture: true) }
                return
            }
            if mountedInputHosts.contains(host), compiledInputHosts.contains(host),
               inputHostDevice[host] == device.id, engine.inputHostIsLive(host.uuidString) { return }
            if let old = inputHostDevice[host], old != device.id { compiledInputHosts.remove(host) }
            mountedInputHosts.insert(host)
            inputHostDevice[host] = device.id
            guard engine.registerMidiInputHost(host.uuidString, device: device.id) else { return }
            if !compiledInputHosts.contains(host) {
                if let inst = chain.instrument { pushInputInstrument(inst, host: host) }
                // The FX are compiled AFTER the instrument: it takes slot 0 of the hidden track, the compile lays
                // the FX behind it. A fresh mount has nothing to clear, so an empty list is not compiled.
                if !chain.plugins.isEmpty { compileRack(objectID: host) }
                if chain.instrument != nil || !chain.plugins.isEmpty { compiledInputHosts.insert(host) }
            }
            // The instrument arrived after the monitor was asked: the engine re-reads its switch.
            if heardMidiDeviceIDs.contains(device.id) { _ = engine.setMidiInputMonitor(true, device: device.id) }
        }
    }

    private func pushInputInstrument(_ inst: ObjectPlugin, host: UUID) {
        guard let engine else { return }
        var info: [String: Any] = ["pluginKey": inst.id.uuidString, "identifier": inst.identifier,
                                   "format": inst.formatName, "name": inst.name]
        if let s = inst.stateXML, !s.isEmpty { info["stateXML"] = s }
        let t0 = CFAbsoluteTimeGetCurrent()
        engine.setInstrument(info, forObjectID: host.uuidString, stateXML: inst.stateXML)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if ms >= 1 { NSLog("[PERF] input instrument \"%@\" instantiated in %.0f ms", inst.name, ms) }
    }

    /// Takes the chain off the engine. `capture`: the live states go back into the model first (a knob turned in an
    /// editor is not lost). The model itself is untouched otherwise, and the project is NOT marked modified.
    func unmountInputHost(_ host: UUID, capture: Bool) {
        guard let engine else { return }
        if capture, compiledInputHosts.contains(host) { captureInputHostStates(host) }
        // The windows first: a built-in editor is ours, a native one the engine closes with the host.
        for plug in Self.flattenLeaves(inputChainPlugins(host) ?? []) + (inputInstrument(host).map { [$0] } ?? [])
        where isPluginEditorOpen(plug: plug) { closePluginEditor(plug: plug) }
        engine.unregisterInputHost(host.uuidString)
        editorHeldInputHosts = editorHeldInputHosts.filter { $0.value != host }
        mountedInputHosts.remove(host)
        compiledInputHosts.remove(host)
        inputHostDevice.removeValue(forKey: host)
    }

    func unmountAllInputHosts(capture: Bool) {
        for host in mountedInputHosts { unmountInputHost(host, capture: capture) }
    }

    // MARK: States

    private func captureInputHostStates(_ host: UUID) {
        switch inputHostKind(host) {
        case .audio(let key):
            guard var chain = inputChains.audio[key], !chain.plugins.isEmpty else { return }
            chain.plugins = capturingPluginStates(chain.plugins)
            if chain != inputChains.audio[key] { inputChains.audio[key] = chain }
        case .midi(let key):
            guard let chain = inputChains.midi[key] else { return }
            let captured = capturingInputChain(chain)
            if captured != chain { inputChains.midi[key] = captured }
        case nil:
            return
        }
    }

    /// A MIDI chain with the live states of its instrument and its FX (what the engine holds), the model's where there are none.
    private func capturingInputChain(_ chain: MidiInputChain) -> MidiInputChain {
        var out = chain
        if var inst = chain.instrument, let xml = engine?.getPluginStateXML(inst.id.uuidString),
           !xml.isEmpty, xml != inst.stateXML {
            inst.stateXML = xml
            out.instrument = inst
        }
        if !chain.plugins.isEmpty { out.plugins = capturingPluginStates(chain.plugins) }
        return out
    }

    /// The chains as a file or an undo point holds them: the live states of the mounted ones captured, the rest as the
    /// model keeps them.
    func inputChainsWithCapturedPluginStates() -> InputChains {
        var out = inputChains
        for host in compiledInputHosts {
            switch inputHostKind(host) {
            case .audio(let key):
                if var chain = out.audio[key], !chain.plugins.isEmpty {
                    chain.plugins = capturingPluginStates(chain.plugins)
                    out.audio[key] = chain
                }
            case .midi(let key):
                if let chain = out.midi[key] { out.midi[key] = capturingInputChain(chain) }
            case nil:
                break
            }
        }
        return out
    }

    /// What `ProjectDocument.inputChains` carries: nothing when there is nothing to write.
    func inputChainsForDocument() -> InputChains? {
        let chains = inputChainsWithCapturedPluginStates().written
        return chains.isEmpty ? nil : chains
    }

    // MARK: The load door

    /// A project opening, a tab restored, a new project: the chains of the document replace the model's. Nothing is
    /// mounted here — `syncInputChains` does it once the load has finished.
    func setInputChains(_ chains: InputChains) {
        unmountAllInputHosts(capture: false)
        // Listening to a MIDI input belongs to the project it was asked in: the engine's Edit outlives it.
        for device in heardMidiDeviceIDs { _ = engine?.setMidiInputMonitor(false, device: device) }
        openInputHosts = []
        if inputChains != chains { inputChains = chains }
    }

    // MARK: Undo

    /// Puts the chains of an undo point back and brings the engine in line: the chains that differ only by the
    /// states of their plugins get those handed back to the live instances; anything else recompiles.
    func restoreInputChains(_ snap: InputChains) {
        let old = inputChains
        inputChains = snap
        for host in mountedInputHosts {
            guard let kind = inputHostKind(host) else { continue }          // gone: `syncInputChains` unmounts it
            switch kind {
            case .audio(let key):
                guard let was = old.audio[key], let now = snap.audio[key], was != now else { continue }
                restoreHostPlugins(host, was: was.plugins, now: now.plugins, sameHost: was.hostID == now.hostID)
            case .midi(let key):
                guard let was = old.midi[key], let now = snap.midi[key], was != now else { continue }
                if was.instrument?.id == now.instrument?.id, was.hostID == now.hostID {
                    if let inst = now.instrument, let xml = inst.stateXML, xml != was.instrument?.stateXML {
                        engine?.applyPluginStateXML(xml, forPlugin: inst.id.uuidString, forObjectID: host.uuidString)
                    }
                    if was.plugins != now.plugins {
                        restoreHostPlugins(host, was: was.plugins, now: now.plugins, sameHost: true)
                    }
                } else {
                    unmountInputHost(host, capture: false)                  // another instrument: remounted below
                }
            }
        }
        syncInputChains()
    }

    /// An undo/redo on a mounted host's FX: plugins that differ only by their states get those handed back to the live
    /// instances; anything else recompiles.
    private func restoreHostPlugins(_ host: UUID, was: [ObjectPlugin], now: [ObjectPlugin], sameHost: Bool) {
        if sameHost, let adopted = Self.adoptingPluginStates(was, now) {
            if adopted == now, Self.monoFolds(was) == Self.monoFolds(now),
               ChannelPicks.places(in: was) == ChannelPicks.places(in: now) {
                for change in Self.changedPluginStates(was, now) {
                    engine?.applyPluginStateXML(change.xml, forPlugin: change.id.uuidString, forObjectID: host.uuidString)
                }
                return
            }
        }
        compileRack(objectID: host)
    }

    // MARK: Editing the MIDI side

    /// Puts `available` as the instrument of a MIDI input (replacing any). One undo point.
    func setInputInstrument(device: MidiInputInfo, available: AvailablePlugin) {
        guard available.isInstrument, engine != nil else { return }
        pushUndo()
        let host = ensureMidiInputHost(device)
        guard let key = inputChains.midiKey(ofHost: host) else { return }
        inputChains.midi[key]?.input = device.ref
        applyInputInstrument(hostID: host, available: available)
    }

    /// The same by the chain's host id (the synoptic's instrument card, the plugin pipeline). One undo point.
    func setInputInstrument(hostID: UUID, available: AvailablePlugin) {
        guard available.isInstrument, engine != nil, inputChains.midiKey(ofHost: hostID) != nil else { return }
        pushUndo()
        applyInputInstrument(hostID: hostID, available: available)
    }

    /// Without the undo point: swaps the instrument of the MIDI chain `hostID` names.
    private func applyInputInstrument(hostID host: UUID, available: AvailablePlugin) {
        // Unmounted first, the live states of the FX captured (they are remounted behind the new instrument).
        if mountedInputHosts.contains(host) { unmountInputHost(host, capture: true) }
        guard let key = inputChains.midiKey(ofHost: host), var chain = inputChains.midi[key] else { return }
        chain.instrument = freshPlugin(available)
        inputChains.midi[key] = chain
        isDirty = true
        syncInputChains()
    }

    /// The same by the chain's host id.
    func removeInputInstrument(hostID: UUID) {
        guard let key = inputChains.midiKey(ofHost: hostID) else { return }
        removeInputInstrument(chainKey: key)
    }

    /// Bypasses (or re-enables) the instrument of a MIDI input: a realtime flag on the live instance and in the model.
    /// One undo point, like an FX's.
    func toggleInputInstrumentEnabled(hostID: UUID, pluginID: UUID) {
        guard let engine, let key = inputChains.midiKey(ofHost: hostID), var chain = inputChains.midi[key],
              var inst = chain.instrument, inst.id == pluginID else { return }
        pushUndo()
        inst.isEnabled.toggle()
        engine.setPlugin(pluginID.uuidString, enabled: inst.isEnabled, forObjectID: hostID.uuidString)
        chain.instrument = inst
        inputChains.midi[key] = chain
        isDirty = true
    }

    /// Takes the instrument off a MIDI input; it stops being heard. One undo point.
    func removeInputInstrument(device: MidiInputInfo) {
        guard let key = midiChainKey(for: device) else { return }
        removeInputInstrument(chainKey: key)
    }

    /// The same by the chain's key: a chain whose device is absent (dormant) is reached this way too.
    func removeInputInstrument(chainKey key: String) {
        guard let was = inputChains.midi[key], was.instrument != nil else { return }
        pushUndo()
        let host = was.hostID
        engine?.setMidiInputMonitor(false, device: resolvedMidiInput(was.input)?.id ?? was.input.id)
        if mountedInputHosts.contains(host) { unmountInputHost(host, capture: true) }   // the FX keep their live states
        guard var chain = inputChains.midi[key] else { return }
        chain.instrument = nil
        inputChains.midi[key] = chain
        isDirty = true
        syncInputChains()
    }

    /// Empties the FX of a MIDI input, its instrument kept (the Inputs tab, on a chain whose device is absent). One undo point.
    func clearMidiInputFX(chainKey key: String) {
        guard let was = inputChains.midi[key], !was.plugins.isEmpty else { return }
        pushUndo()
        let host = was.hostID
        if mountedInputHosts.contains(host) { unmountInputHost(host, capture: false) }
        guard var chain = inputChains.midi[key] else { return }
        chain.plugins = []
        inputChains.midi[key] = chain
        isDirty = true
        syncInputChains()
    }

    /// Empties the FX chain of a card input (the Inputs tab, on a chain whose input is absent). One undo point.
    func clearAudioInputChain(key: String) {
        guard var chain = inputChains.audio[key], !chain.plugins.isEmpty else { return }
        pushUndo()
        let host = chain.hostID
        if mountedInputHosts.contains(host) { unmountInputHost(host, capture: false) }
        chain.plugins = []
        inputChains.audio[key] = chain
        isDirty = true
        syncInputChains()
    }

    /// Hears (or stops hearing) a MIDI input through its instrument. nil on success, otherwise why not.
    func setMidiInputMonitor(_ device: MidiInputInfo, on: Bool) -> String? {
        guard let engine else { return "no engine" }
        if on {
            guard let key = midiChainKey(for: device), let chain = inputChains.midi[key], chain.instrument != nil else {
                return "this MIDI input has no instrument"
            }
            mountInputHost(chain.hostID)                        // the instrument must be there for the engine to accept
            if let why = engine.setMidiInputMonitor(true, device: device.id) { return why }
        } else {
            _ = engine.setMidiInputMonitor(false, device: device.id)
        }
        syncInputChains()
        return nil
    }

    // MARK: Inheritance (a recording zone born from an input — E11)

    /// What a NEW zone takes from the input it is dropped from: a copy of the input's FX (audio), or of its instrument and
    /// the FX behind it (MIDI).
    /// Independent: fresh ids, no parameter link and no FX link (a bin becomes its plugins), the live state when the chain is
    /// mounted and the model's otherwise. The input itself is untouched.
    func inheritedChain(for source: RecordSource) -> InheritedChain {
        switch source {
        case .audio(let ref):
            guard let chain = inputChains.audio[ref.key], !chain.isEmpty else { return .none }
            return InheritedChain(plugins: independentCopies(capturingPluginStates(chain.plugins)))
        case .midi(let ref):
            let key = inputChains.midi[ref.id] != nil ? ref.id
                : resolvedMidiInput(ref).flatMap { midiChainKey(for: $0) }
            guard let key, let chain = inputChains.midi[key], !chain.isEmpty else { return .none }
            let live = capturingInputChain(chain)
            return InheritedChain(plugins: independentCopies(live.plugins),
                                  instrument: live.instrument.flatMap { independentCopies([$0]).first })
        }
    }

    private func independentCopies(_ plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.flatMap { p -> [ObjectPlugin] in
            if p.isChannelPick { return [p.copiedChannelPick()] }
            if let block = p.fxBlock { return independentCopies(block.plugins) }
            if p.isContainer {
                var q = p.mappingChildSeries { independentCopies($0) }
                q.id = UUID()
                return [q]
            }
            var q = p
            q.id = UUID()
            q.linkGroupID = nil
            q.detachedLinkGroupID = nil
            return [q]
        }
    }
}
