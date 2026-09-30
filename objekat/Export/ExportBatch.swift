import Foundation

// A REGIONS export is a batch: one render per selected region, run one after the other. This is
// its state — declarative, nothing rendered here. The machinery is `EditViewModel+ExportRegions`.
//
// Each region is an ordinary export job (`ExportJob`, the engine path of the IN–OUT scope with an
// imposed range); the batch is what sits ABOVE them: which one is running, what became of the
// previous ones, and whether the hand asked to stop.

struct ExportBatch: Equatable {

    /// One region to render, frozen at the launch: the regions may be renamed, moved or deleted
    /// while the batch runs, and the files must be those that were announced.
    struct Target: Equatable, Identifiable {
        var id: UUID              // the region's marker id
        var regionName: String    // as typed — may be empty
        var fileBase: String      // the file's name, without extension (@see RegionExportNaming)
        var start: Double
        var end: Double
    }

    enum Outcome: Equatable {
        case pending
        case running
        case done
        case failed(String)
        /// Stopped by the hand, or never started because the batch was stopped.
        case cancelled
    }

    var targets: [Target]
    var outcomes: [Outcome]
    /// The settings every region is rendered with (format, rate, depth, folder…).
    var settings: ExportSettings
    /// Index of the region being rendered, or `targets.count` once the batch is over.
    var current: Int = 0
    var cancelRequested: Bool = false

    init(targets: [Target], settings: ExportSettings) {
        self.targets = targets
        self.outcomes = Array(repeating: .pending, count: targets.count)
        self.settings = settings
    }

    var total: Int { targets.count }
    /// True until the last region has ended (or the rest has been given up).
    var isActive: Bool { current < targets.count }
    var currentTarget: Target? { current < targets.count ? targets[current] : nil }

    func url(for target: Target) -> URL {
        settings.folder.appendingPathComponent(target.fileBase)
            .appendingPathExtension(settings.format.fileExtension)
    }

    var doneCount: Int { outcomes.filter { $0 == .done }.count }
    var failedCount: Int {
        outcomes.filter { if case .failed = $0 { return true } else { return false } }.count
    }
    var cancelledCount: Int { outcomes.filter { $0 == .cancelled }.count }

    /// The files actually written, in order.
    var writtenURLs: [URL] {
        zip(targets, outcomes).filter { $0.1 == .done }.map { url(for: $0.0) }
    }

    /// 0…1 over the whole batch, given the progress of the region under way.
    func overallProgress(currentRegion progress: Double) -> Double {
        guard total > 0 else { return 0 }
        if !isActive { return 1 }
        return (Double(current) + min(1, max(0, progress))) / Double(total)
    }
}
