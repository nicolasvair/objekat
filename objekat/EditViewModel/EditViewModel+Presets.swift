import Foundation

// MARK: - Presets: OBJEKAT's own, beside the plugin's
//
// A preset is a plugin's FULL state (`getPluginStateXML`, the same thing `ObjectPlugin.stateXML`
// holds and an undo puts back), stored once per plugin TYPE in a library shared by every project
// (@see PluginPresetLibrary). Four things are done with it here, and nowhere else:
//
//   • a FRESH insertion starts on its type's default preset (`freshPlugin`) — the browser, the
//     signal view's "+", `plugin.add`, an instrument, a plugin added to a bin. Never a copy, a
//     paste, a duplicate, a link, a load: those carry a state of their own, which wins;
//   • loading one lays it on the LIVE instance (`applyPluginStateXML`, no reload, no rebuild), and on
//     every instance ACTIVELY linked to it — a link is a promise that the instances sound alike;
//   • saving one stores the live state, the instance's own attributes taken out (@see PresetStateXML);
//   • the plugin's own programs (its factory presets) are offered beside them, read-only.
//
// The name shown in the editor's title bar (`pluginPresetStatus`) is transient: it says what was
// loaded or saved in THIS session, and a "•" once a parameter moved since. It is not written into
// the project (a reopened project shows no name: the state is what was saved, the name is history).

/// What the editor's title bar says about a plugin's preset.
struct PluginPresetStatus: Equatable {
    var name: String
    /// A factory program of the plugin rather than one of OBJEKAT's presets.
    var isFactory: Bool = false
    /// A parameter moved since it was loaded or saved.
    var isModified: Bool = false
}

extension EditViewModel {

    // MARK: Identity

    func presetKey(of p: ObjectPlugin) -> PluginPresetKey {
        PluginPresetKey(formatName: p.formatName, identifier: p.identifier)
    }

    /// A plugin as freshly inserted: a new id and its type's DEFAULT preset as starting state, if one
    /// is set. The default is read from the library at every insertion (a few file reads, never on a
    /// drawing path), so a default set a minute ago applies to the next plugin.
    func freshPlugin(_ a: AvailablePlugin) -> ObjectPlugin {
        let key = PluginPresetKey(formatName: a.formatName, identifier: a.identifier)
        var p = ObjectPlugin(id: UUID(), name: a.name, manufacturer: a.manufacturer,
                             identifier: a.identifier, formatName: a.formatName)
        if let state = PluginPresetLibrary.shared.defaultState(for: key) {
            p.stateXML = state
            if let name = PluginPresetLibrary.shared.defaultPresetName(for: key) {
                pluginPresetStatus[p.id] = PluginPresetStatus(name: name)
            }
        }
        return p
    }

    /// Where a plugin lives: the host whose chain (or instrument slot, or send) carries it, and the
    /// plugin itself. Objects at any depth, then the buses.
    func presetTarget(_ pluginID: UUID) -> (hostID: UUID, plugin: ObjectPlugin)? {
        if let r = allPluginRefs().first(where: { $0.plugin.id == pluginID }) { return (r.objectID, r.plugin) }
        for s in stems {
            if let p = Self.flattenLeaves(s.plugins).first(where: { $0.id == pluginID }) { return (s.id, p) }
        }
        return nil
    }

    /// The live state of a plugin, as a preset would store it. nil if the engine has no instance.
    func presetLiveState(_ pluginID: UUID) -> String? {
        guard let xml = engine?.getPluginStateXML(pluginID.uuidString), !xml.isEmpty else { return nil }
        return PresetStateXML.stripped(xml)
    }

    // MARK: Reading

    func presets(for pluginID: UUID) -> [PluginPreset] {
        guard let t = presetTarget(pluginID) else { return [] }
        return PluginPresetLibrary.shared.presets(for: presetKey(of: t.plugin))
    }

    func defaultPresetName(for pluginID: UUID) -> String? {
        guard let t = presetTarget(pluginID) else { return nil }
        return PluginPresetLibrary.shared.defaultPresetName(for: presetKey(of: t.plugin))
    }

    /// The plugin's own programs ([] for a built-in, an instance still loading, a plugin with none).
    func factoryPrograms(for pluginID: UUID) -> [String] {
        engine?.pluginProgramNames(pluginID.uuidString) ?? []
    }

    // MARK: Writing the library

    enum PresetError: Error, Equatable {
        case unknownPlugin
        case noState
        case notFound(String)
        case library(String)
    }

    /// Stores the plugin's live state under `name` (overwriting a preset of that name). The title
    /// bar then names it, unmodified.
    @discardableResult
    func savePreset(pluginID: UUID, name: String) throws -> PluginPreset {
        guard let t = presetTarget(pluginID) else { throw PresetError.unknownPlugin }
        guard let state = presetLiveState(pluginID) ?? t.plugin.stateXML.flatMap(PresetStateXML.stripped)
        else { throw PresetError.noState }
        do {
            let p = try PluginPresetLibrary.shared.save(name: name, stateXML: state,
                                                        key: presetKey(of: t.plugin), pluginName: t.plugin.name)
            setPresetStatus(PluginPresetStatus(name: p.name), on: pluginID, withLinked: true)
            return p
        } catch let e as PluginPresetLibrary.LibraryError {
            throw PresetError.library(String(describing: e))
        }
    }

    func deletePreset(pluginID: UUID, name: String) throws {
        guard let t = presetTarget(pluginID) else { throw PresetError.unknownPlugin }
        do { try PluginPresetLibrary.shared.delete(name: name, key: presetKey(of: t.plugin)) }
        catch PluginPresetLibrary.LibraryError.notFound(let n) { throw PresetError.notFound(n) }
        catch { throw PresetError.library(String(describing: error)) }
    }

    /// Names (nil clears) the default preset of this plugin's TYPE.
    func setDefaultPreset(pluginID: UUID, name: String?) throws {
        guard let t = presetTarget(pluginID) else { throw PresetError.unknownPlugin }
        do {
            try PluginPresetLibrary.shared.setDefault(name: name, key: presetKey(of: t.plugin),
                                                      pluginName: t.plugin.name)
        } catch PluginPresetLibrary.LibraryError.notFound(let n) { throw PresetError.notFound(n) }
        catch { throw PresetError.library(String(describing: error)) }
    }

    // MARK: Laying a preset

    /// Lays preset `name` on the plugin and on every instance actively linked to it. ONE undo point.
    func loadPreset(pluginID: UUID, name: String) throws {
        guard let t = presetTarget(pluginID) else { throw PresetError.unknownPlugin }
        guard let preset = PluginPresetLibrary.shared.preset(named: name, for: presetKey(of: t.plugin))
        else { throw PresetError.notFound(name) }
        pushUndo()
        for target in [t] + activeLinkedInstances(of: pluginID) {
            layState(preset.stateXML, on: target.plugin.id, host: target.hostID)
        }
        setPresetStatus(PluginPresetStatus(name: preset.name), on: pluginID, withLinked: true)
        isDirty = true
    }

    /// Lays the plugin's own program `index`, then carries the state it produced to the linked
    /// instances (a program is the instance's business: only its resulting state can travel).
    func loadFactoryProgram(pluginID: UUID, index: Int) throws {
        guard presetTarget(pluginID) != nil else { throw PresetError.unknownPlugin }
        let names = factoryPrograms(for: pluginID)
        guard names.indices.contains(index) else { throw PresetError.notFound("#\(index)") }
        pushUndo()
        guard engine?.setPluginProgram(pluginID.uuidString, index: Int32(index)) == true else {
            throw PresetError.noState
        }
        quietPresetTouches(pluginID)
        pluginStateRevision[pluginID, default: 0] += 1
        if let state = presetLiveState(pluginID) {
            writeModelState(pluginID, host: presetTarget(pluginID)!.hostID)
            for target in activeLinkedInstances(of: pluginID) {
                layState(state, on: target.plugin.id, host: target.hostID)
            }
        }
        setPresetStatus(PluginPresetStatus(name: names[index], isFactory: true), on: pluginID, withLinked: true)
        isDirty = true
    }

    /// The instances sharing the plugin's ACTIVE link group (a detached member keeps its own sound).
    func activeLinkedInstances(of pluginID: UUID) -> [(hostID: UUID, plugin: ObjectPlugin)] {
        guard let g = presetTarget(pluginID)?.plugin.linkGroupID else { return [] }
        return allPluginRefs()
            .filter { $0.plugin.linkGroupID == g && $0.plugin.id != pluginID }
            .map { (chainHost(holding: $0.plugin.id, on: $0.objectID), $0.plugin) }
    }

    /// `presetXML` fitted to the live instance (its id, bypass, width, window kept), laid on the
    /// engine through the host-aware door, then written into the model.
    private func layState(_ presetXML: String, on pluginID: UUID, host: UUID) {
        let key = pluginID.uuidString
        let live = engine?.getPluginStateXML(key)
        let fitted = live.flatMap { PresetStateXML.adapted(presetXML, toLive: $0) } ?? presetXML
        quietPresetTouches(pluginID)
        _ = engine?.applyPluginStateXML(fitted, forPlugin: key,
                                        forObjectID: engineHostKey(host).uuidString)
        writeModelState(pluginID, host: host, fallback: fitted)
        pluginStateRevision[pluginID, default: 0] += 1
        // A built-in's editor reads the model's cache of its parameters: forget it.
        pluginParamValues = pluginParamValues.filter { ref, _ in
            if case .plugin(let k, _) = ref { return k != pluginID }
            return true
        }
    }

    /// The model's copy of the plugin's state, from the live instance (or `fallback`).
    private func writeModelState(_ pluginID: UUID, host: UUID, fallback: String? = nil) {
        guard let xml = engine?.getPluginStateXML(pluginID.uuidString) ?? fallback else { return }
        if isInstrument(pluginID, of: host) {
            update(id: host) { o in
                o.instruments = o.instruments.map { p in
                    guard p.id == pluginID else { return p }
                    var q = p; q.stateXML = xml; return q
                }
            }
        } else {
            updateChainPlugins(host) { $0 = Self.settingStateXML(pluginID, xml, in: $0) }
        }
    }

    // MARK: The title bar's status

    private func setPresetStatus(_ s: PluginPresetStatus, on pluginID: UUID, withLinked: Bool) {
        pluginPresetStatus[pluginID] = s
        if withLinked { for t in activeLinkedInstances(of: pluginID) { pluginPresetStatus[t.plugin.id] = s } }
    }

    /// Laying a state moves parameters, and the engine reports each move as a touch: those are not
    /// the hand's, so they must not mark the preset modified. The window is generous on purpose — an
    /// AU not yet initialised gets its state re-asserted a moment later (@see schedulePluginStateReassert).
    private func quietPresetTouches(_ pluginID: UUID) {
        presetTouchQuietUntil[pluginID] = Date().addingTimeInterval(1.0)
    }

    /// A parameter of `pluginID` moved under the hand: its preset (if one is named) is now modified.
    func notePresetParamTouched(_ pluginID: UUID) {
        if let until = presetTouchQuietUntil[pluginID] {
            if Date() < until { return }
            presetTouchQuietUntil[pluginID] = nil
        }
        guard var s = pluginPresetStatus[pluginID], !s.isModified else { return }
        s.isModified = true
        pluginPresetStatus[pluginID] = s
    }
}
