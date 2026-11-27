import AppKit

/// Plugin editor windows reopen WHERE THEY WERE.
///
/// Closing an editor used to forget everything about it: the next one was born centred by the engine
/// (and cascaded below the others), so a window set beside the plugin one works with had to be put
/// back by hand — every time, and above all after a project-tab switch, which closes every editor
/// (@see `closeAllPluginEditors`). The frame is recorded as the window goes away and handed back as
/// it comes again, native (the engine asks, @see `OBJEngineCore setPluginEditorPlacementProvider:`)
/// and built-in (`openBuiltInPluginEditor` asks itself) alike.
///
/// What is remembered is the window's TOP-LEFT corner, in screen coordinates: the screen follows
/// from it, and a corner survives an editor whose size changed (@see `EditorFramePlacement`). The
/// memory lives as long as the process — it is a matter of the working session's layout, not of
/// the project's file — and is keyed by the plugin's id, so a plugin that is back (a tab returned
/// to) finds its place, and an unknown one is simply centred as before.
///
/// **Interplay with the mosaic** (@see `EditorTiling`): editors opened TOGETHER are laid by the
/// mosaic, and the mosaic wins — a plugin of the batch under way is not restored from memory (the
/// batch would then be laid over by the very positions it is about to replace, or worse, a window
/// restored first and the rest tiled around a stale hole). Where the mosaic puts it is what is
/// remembered at the next close, like any other position. An editor opened ALONE, or from a batch
/// that is over, goes back to its own place.
extension EditViewModel {

    /// Records where an editor window was at the moment it left. `frame` is the NSWindow frame
    /// (AppKit coordinates).
    func rememberEditorFrame(pluginID: UUID, frame: CGRect) {
        guard frame.width > 1, frame.height > 1 else { return }
        editorTopLefts[pluginID] = CGPoint(x: frame.minX, y: frame.maxY)
    }

    /// The origin a window of `size` should take to reopen where it closed, brought back into a
    /// screen that is there now; nil when it has no place to go back to (never opened, headless) or
    /// when the mosaic is about to place it.
    func rememberedEditorOrigin(pluginID: UUID, size: CGSize) -> CGPoint? {
        guard hasInterface, let topLeft = editorTopLefts[pluginID] else { return nil }
        if let tiling = editorTiling, tiling.pending.contains(pluginID),
           ProcessInfo.processInfo.systemUptime - tiling.startedAt <= EditorTiling.batchLifetime {
            return nil
        }
        let areas = NSScreen.screens.map(\.visibleFrame)
        guard !areas.isEmpty else { return nil }
        return EditorFramePlacement.origin(topLeft: topLeft, size: size, visibleFrames: areas)
    }

    /// Hands the engine the two doors of the memory (called when the engine is attached).
    func wireEditorFrameMemory() {
        engine?.setPluginEditorPlacementProvider { [weak self] key, size, origin in
            MainActor.assumeIsolated {
                guard let self, let id = UUID(uuidString: key),
                      let o = self.rememberedEditorOrigin(pluginID: id, size: size) else { return false }
                origin.pointee = o
                return true
            }
        }
        engine?.setPluginEditorFrameRecorder { [weak self] key, frame in
            MainActor.assumeIsolated {
                guard let self, let id = UUID(uuidString: key) else { return }
                self.rememberEditorFrame(pluginID: id, frame: frame)
            }
        }
    }
}
