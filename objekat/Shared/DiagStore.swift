//
//  DiagStore.swift
//  objekat
//
//  Le dossier du journal de diagnostic : son arborescence, son README (pour Claude) et la rotation
//  des sessions (nombre et poids). Rien d'autre : lire une session morte, c'est `tools/diag_latest.py`.
//
//      ~/Library/Logs/Objekat/
//          README.md                       ← ce que contient ce dossier, et comment le lire
//          sessions/<date>_<heure>_pid<N>.log (+ .log.1) et .meta.json
//

import Foundation

nonisolated enum DiagStore {

    // MARK: - Arborescence

    static func sessionsDirectory(_ root: URL) -> URL { root.appendingPathComponent("sessions", isDirectory: true) }

    static func ensureDirectories(_ root: URL) {
        try? FileManager.default.createDirectory(at: sessionsDirectory(root), withIntermediateDirectories: true)
    }

    // MARK: - README

    /// Réécrit quand la version du texte change : un dossier de journaux doit s'expliquer seul à celui
    /// (Claude) qui l'ouvre sans rien savoir de l'app.
    private static let readmeStamp = "<!-- objekat-diag-readme 3 -->"

    static func writeReadmeIfNeeded(_ root: URL) {
        let url = root.appendingPathComponent("README.md")
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing.contains(readmeStamp) { return }
        let text = """
        \(readmeStamp)
        # Journaux de diagnostic OBJEKAT

        Écrit par OBJEKAT quand son journal est allumé (menu OBJEKAT ▸ Diagnostic, ou `--diag-log`).
        Pour lire : `python3 tools/diag_latest.py` (dans le dépôt) — dernière session anormale ou
        dernier problème signalé, avec la fin du journal et le rapport système (.ips) ;
        `diag_latest.py list` liste les sessions.

        - `sessions/<date>_<heure>_pid<N>.log` : une session. Au-delà de 20 Mo : `.log.1` (le
          précédent) et un nouveau `.log`. 30 sessions et 300 Mo au plus.
        - `sessions/<…>.meta.json` : pid, début, version, projet, `clean_exit` (false tant que la
          session vit, ou si elle est morte sans prévenir).

        Une ligne : `HH:MM:SS.mmm +secondes CAT   message` (`+secondes` depuis le début de session).
        Catégories : PROJ, KEY, MENU, MOUSE, EDIT (point d'annulation : fonction, fichier:ligne),
        UNDO, API (`nom {paramètres}` à l'appel, `nom → ok|erreur … durée` au retour), TRANS, PLUG,
        AUDIO, TE (moteur), DLG, ISSUE (problème signalé), CRASH, EXIT.
        Session finie sur `CRASH` : plantée ; sur `EXIT` : fin normale (ou SIGTERM/SIGINT) ; sur
        autre chose : tuée sans prévenir.
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Rotation

    static let maxSessions = 30
    static let maxTotalBytes: Int64 = 300 * 1024 * 1024

    /// Garde 29 sessions (la nouvelle fait la trentième) et 300 Mo, les plus récentes d'abord.
    static func prune(_ root: URL) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: sessionsDirectory(root), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return }
        struct Session { var urls: [URL] = []; var bytes: Int64 = 0; var newest = Date.distantPast }
        var byBase: [String: Session] = [:]
        for url in urls {
            let name = url.lastPathComponent
            // `2026-11-15_150211_pid123.log.1` → `2026-11-15_150211_pid123`
            guard let suffix = [".meta.json", ".log.1", ".log"].first(where: name.hasSuffix) else { continue }
            let base = String(name.dropLast(suffix.count))
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            var entry = byBase[base] ?? Session()
            entry.urls.append(url)
            entry.bytes += Int64(values?.fileSize ?? 0)
            if let m = values?.contentModificationDate, m > entry.newest { entry.newest = m }
            byBase[base] = entry
        }
        var kept = 0
        var total: Int64 = 0
        for entry in byBase.values.sorted(by: { $0.newest > $1.newest }) {
            if kept < maxSessions - 1, total + entry.bytes <= maxTotalBytes {
                kept += 1; total += entry.bytes
            } else {
                for url in entry.urls { try? fm.removeItem(at: url) }
            }
        }
    }
}
