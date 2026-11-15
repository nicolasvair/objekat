//
//  DiagIssueReport.swift
//  objekat
//
//  « Signaler un problème » : un dossier `issues/<date>_<heure>/` rassemblé À LA DEMANDE de la
//  main (menu OBJEKAT ▸ Diagnostic ▸ Signaler un problème…, ou la commande `diag.mark`). Rien ici
//  ne part tout seul : c'est le geste explicite de quelqu'un qui a vu quelque chose tourner mal.
//
//      note.txt      ce que la personne a écrit (facultatif)
//      state.json    l'état : projet, sélection, transport, carte son, onglets, annulation, éditeurs
//      journal.log   la fin du journal de la session (15 min, 3000 lignes au plus)
//      oslog.txt     les logs système du processus (`log show`)
//
//  Une ligne `ISSUE` est écrite dans le journal AVANT de rassembler quoi que ce soit : si la
//  collecte elle-même plante, le journal le dit.
//

import AppKit

@MainActor
enum DiagIssueReport {

    // MARK: - Le dossier

    /// Rassemble le dossier et renvoie son chemin. `copyToClipboard` : la porte de la main (le menu) ;
    /// un script n'a pas à toucher au presse-papiers de la personne qui travaille.
    @discardableResult
    static func collect(note: String, copyToClipboard: Bool) async -> URL? {
        let root = Diag.rootDirectory
        DiagStore.ensureDirectories(root)
        DiagStore.writeReadmeIfNeeded(root)
        let now = Date()
        Diag.log(.issue, "problème signalé : \(Diag.truncated(note.isEmpty ? "(sans note)" : note, 300))")

        let fm = FileManager.default
        let issues = DiagStore.issuesDirectory(root)
        let stamp = Diag.fileStamp(now)
        var folder = issues.appendingPathComponent(stamp, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = issues.appendingPathComponent("\(stamp)-\(n)", isDirectory: true)
            n += 1
        }
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return nil }

        try? (note.isEmpty ? "(aucune note)\n" : note + "\n")
            .write(to: folder.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        // Le journal : la fin de la session courante (et du fichier tourné, s'il y en a un).
        var journalLines: [String] = []
        if let current = Diag.currentLogURL {
            for url in [URL(fileURLWithPath: current.path + ".1"), current] {
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    journalLines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false)
                        .map(String.init))
                }
            }
            if journalLines.last == "" { journalLines.removeLast() }
        }
        let tail = journalLines.isEmpty ? ["# (journal éteint : aucune ligne disponible)"]
            : DiagCrashReports.Builder.tailOf(journalLines)
        try? (tail.joined(separator: "\n") + "\n")
            .write(to: folder.appendingPathComponent("journal.log"), atomically: true, encoding: .utf8)

        // L'état.
        let state = await collectState()
        if let data = try? JSONSerialization.data(withJSONObject: state,
                                                  options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: folder.appendingPathComponent("state.json"), options: .atomic)
        }

        // Les logs système : borné à 30 s, hors du fil principal.
        let pid = Int(getpid())
        let from = now.addingTimeInterval(-600)
        let oslog = folder.appendingPathComponent("oslog.txt")
        await Task.detached {
            DiagCrashReports.Builder.runOSLog(pid: pid, from: from, to: Date().addingTimeInterval(5),
                                              output: oslog)
        }.value

        let summary = note.isEmpty ? "problème signalé (sans note)" : "problème signalé : \(Diag.truncated(note, 200))"
        DiagStore.writeLatest(root: root, kind: "problème signalé", time: now, folder: folder, summary: summary)
        if copyToClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(folder.path, forType: .string)
        }
        return folder
    }

    /// L'état, par les commandes de l'API elles-mêmes : un seul chemin de lecture, donc ce que Claude
    /// lira ici est ce qu'il lirait en interrogeant l'app.
    private static func collectState() async -> [String: Any] {
        var state: [String: Any] = [:]
        for name in ["app.info", "project.get_state", "selection.get", "transport.state", "audio.status"] {
            if let value = try? await CommandRegistry.shared.execute(name: name, params: CommandParams()),
               let data = try? JSONEncoder().encode(value),
               let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                state[name] = object
            } else {
                state[name] = "indisponible"
            }
        }
        if let vm = CommandContext.shared.viewModel {
            state["annulation"] = ["undo": vm.undoStack.count, "redo": vm.redoStack.count]
            state["editeurs_plugin_ouverts"] = vm.builtInEditorWindows.count
        }
        if let workspace = CommandContext.shared.workspace {
            state["onglets"] = workspace.tabs.map { tab in
                ["id": tab.id.uuidString, "nom": workspace.displayName(for: tab),
                 "actif": tab.id == workspace.activeTabID] as [String: Any]
            }
        }
        state["version"] = "\(Diag.versionString) (\(Diag.buildString))"
        state["macos"] = ProcessInfo.processInfo.operatingSystemVersionString
        return state
    }

    // MARK: - La porte de la main (menu)

    /// L'alerte avec le champ de note, puis le dossier, puis un mot de confirmation.
    static func askAndCollect() {
        let alert = NSAlert()
        alert.messageText = L("diag.issue.title")
        alert.informativeText = L("diag.issue.info")
        alert.addButton(withTitle: L("diag.issue.send"))
        alert.addButton(withTitle: L("common.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 72))
        field.placeholderString = L("diag.issue.placeholder")
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let note = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            guard let folder = await collect(note: note, copyToClipboard: true) else { return }
            let done = NSAlert()
            done.messageText = L("diag.issue.done.title")
            done.informativeText = L("diag.issue.done.info", folder.path)
            done.alertStyle = .informational
            done.runModal()
        }
    }

    /// Ouvre le dossier des journaux dans le Finder (il est créé au besoin).
    static func openFolder() {
        let root = Diag.rootDirectory
        DiagStore.ensureDirectories(root)
        NSWorkspace.shared.open(root)
    }
}
