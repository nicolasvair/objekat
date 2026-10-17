import Foundation

// MARK: - The model as `ProjectFileUsage` sees it

extension SoundObject {
    /// This object reduced to what decides which FILES it reads (@see `ProjectFileUsage.Ref`):
    /// an instance of a consolidated object names its definition (and the wave it plays), a clip
    /// its path, a group its children. An aux and a MIDI clip read no file.
    var fileUsageRef: ProjectFileUsage.Ref {
        var path: String?
        var children: [ProjectFileUsage.Ref] = []
        switch kind {
        case .clip(let fp, _, _, _, _): path = fp
        case .group(let kids, _): children = kids.map(\.fileUsageRef)
        case .aux, .midiClip: break
        }
        return ProjectFileUsage.Ref(consolidateID: consolidateID, filePath: path, children: children)
    }
}
