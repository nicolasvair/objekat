import Foundation

// MARK: - Presets (OBJEKAT's library, and the plugin's own programs)

/// The `preset.*` family. A preset belongs to a plugin TYPE (format + identifier), not to a project:
/// the library is shared by every session (@see PluginPresetLibrary — under `--no-recent` /
/// `--headless` it is a folder of the process's own, unless `--preset-library=PATH` names one).
/// Every command names a live plugin (`plugin`, an instance id: objects, instruments, sends and
/// stems alike) and acts on its type's presets. `preset.load` is the only one that touches the
/// project (one undo point, propagated to the instances actively linked to it); the others write
/// the library only, so they push no undo point.
extension CommandRegistry {

    private func presetError(_ e: Error) -> CommandError {
        switch e as? EditViewModel.PresetError {
        case .unknownPlugin?:   return CommandError(code: .not_found, message: "unknown plugin")
        case .noState?:         return CommandError(code: .invalid_state, message: "the plugin has no live state (still loading?)")
        case .notFound(let n)?: return CommandError(code: .not_found, message: "no preset named '\(n)'")
        case .library(let m)?:  return CommandError(code: .engine_error, message: "preset library: \(m)")
        case nil:               return CommandError(code: .engine_error, message: String(describing: e))
        }
    }

    private func presetStatusJSON(_ s: PluginPresetStatus?) -> JSONValue {
        guard let s else { return .null }
        return .object(["name": .string(s.name), "factory": .bool(s.isFactory), "modified": .bool(s.isModified)])
    }

    func registerPresetCommands() {

        register("preset.library",
                 summary: "Where the preset library of this process lives.",
                 params: [],
                 undo: .none) { _ in
            .object(["root": .string(PluginPresetLibrary.shared.root.path)])
        }

        register("preset.list",
                 summary: "A plugin's presets (its type's), its type's default, its own factory programs and what its title bar says.",
                 params: [ParamSpec("plugin", "uuid", "A live plugin (instance id).")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("plugin")
            guard let t = vm.presetTarget(id) else { throw self.presetError(EditViewModel.PresetError.unknownPlugin) }
            return .object([
                "plugin": .string(id.uuidString),
                "host": .string(t.hostID.uuidString),
                "identifier": .string(t.plugin.identifier),
                "format": .string(t.plugin.formatName),
                "presets": .array(vm.presets(for: id).map { .string($0.name) }),
                "default": vm.defaultPresetName(for: id).map { .string($0) } ?? .null,
                "factory": .array(vm.factoryPrograms(for: id).map { .string($0) }),
                "status": self.presetStatusJSON(vm.pluginPresetStatus[id])
            ])
        }

        register("preset.save",
                 summary: "Stores the plugin's live state as a preset of its type (overwrites one of that name).",
                 params: [ParamSpec("plugin", "uuid", "A live plugin."),
                          ParamSpec("name", "string", "The preset's name (trimmed, not empty).")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("plugin")
            do {
                let saved = try vm.savePreset(pluginID: id, name: try p.string("name"))
                return .object(["name": .string(saved.name), "status": self.presetStatusJSON(vm.pluginPresetStatus[id])])
            } catch { throw self.presetError(error) }
        }

        register("preset.load",
                 summary: "Lays a preset (by `name`) or one of the plugin's own programs (by `factory` index) on the plugin and on every instance actively linked to it. One undo point.",
                 params: [ParamSpec("plugin", "uuid", "A live plugin."),
                          ParamSpec("name", "string", required: false, "An OBJEKAT preset of its type."),
                          ParamSpec("factory", "int", required: false, "Index into `preset.list`'s `factory`.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("plugin")
            do {
                if let i = try p.optionalInt("factory") {
                    try vm.loadFactoryProgram(pluginID: id, index: i)
                } else {
                    try vm.loadPreset(pluginID: id, name: try p.string("name"))
                }
                return .object(["status": self.presetStatusJSON(vm.pluginPresetStatus[id])])
            } catch let e as CommandError { throw e }
            catch { throw self.presetError(error) }
        }

        register("preset.delete",
                 summary: "Deletes a preset of the plugin's type (and the default with it, if it was the default).",
                 params: [ParamSpec("plugin", "uuid", "A live plugin."),
                          ParamSpec("name", "string", "The preset.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            do { try vm.deletePreset(pluginID: try p.uuid("plugin"), name: try p.string("name")) }
            catch { throw self.presetError(error) }
            return .object([:])
        }

        register("preset.set_default",
                 summary: "Names the default preset of the plugin's type (laid on every FRESH insertion of it); `name: null` clears it.",
                 params: [ParamSpec("plugin", "uuid", "A live plugin."),
                          ParamSpec("name", "string|null", required: false, "The preset; absent or null clears.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("plugin")
            var name: String? = nil
            if let v = p.raw["name"], v != .null { name = try p.string("name") }
            do { try vm.setDefaultPreset(pluginID: id, name: name) }
            catch { throw self.presetError(error) }
            return .object(["default": vm.defaultPresetName(for: id).map { .string($0) } ?? .null])
        }
    }
}
