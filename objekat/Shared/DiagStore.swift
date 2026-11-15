//
//  DiagStore.swift
//  objekat
//
//  Les dossiers du journal de diagnostic : leur arborescence, leur README (pour Claude), leur
//  entretien (rotation par nombre et par poids), LATEST.md, et deux petits outils partagés par les
//  rapports de crash et de problème (« ce pid tourne-t-il encore ? », lancer un processus avec un
//  délai maximal).
//
//      ~/Library/Logs/Objekat/
//          README.md                       ← ce que contient ce dossier, et comment le lire
//          LATEST.md                       ← le dernier crash OU problème : type, heure, chemin, résumé
//          sessions/<date>_<heure>_pid<N>.log (+ .log.1) et .meta.json
//          crashes/<date>_<heure>_<SIGNAL>/    summary.md, journal.log, meta.json, *.ips, oslog.txt
//          issues/<date>_<heure>/              note.txt, state.json, journal.log, oslog.txt
//

import Foundation

nonisolated enum DiagStore {

    // MARK: - Arborescence

    static func sessionsDirectory(_ root: URL) -> URL { root.appendingPathComponent("sessions", isDirectory: true) }
    static func crashesDirectory(_ root: URL) -> URL { root.appendingPathComponent("crashes", isDirectory: true) }
    static func issuesDirectory(_ root: URL) -> URL { root.appendingPathComponent("issues", isDirectory: true) }
    static func latestFile(_ root: URL) -> URL { root.appendingPathComponent("LATEST.md") }

    static func ensureDirectories(_ root: URL) {
        let fm = FileManager.default
        for dir in [root, sessionsDirectory(root), crashesDirectory(root), issuesDirectory(root)] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - README

    /// Rédigé à chaque changement de version du texte : un dossier de journaux doit s'expliquer
    /// seul à celui (Claude) qui l'ouvre sans rien savoir de l'app.
    private static let readmeStamp = "<!-- objekat-diag-readme 2 -->"

    static func writeReadmeIfNeeded(_ root: URL) {
        let url = root.appendingPathComponent("README.md")
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing.contains(readmeStamp) { return }
        let text = """
        \(readmeStamp)
        # Journaux de diagnostic OBJEKAT

        Ce dossier est écrit par OBJEKAT quand son journal de diagnostic est allumé (menu OBJEKAT ▸
        Diagnostic ▸ Journal de diagnostic, ou `--diag-log` en ligne de commande).

        ## Par où commencer

        1. Lire **LATEST.md** : le dernier crash ou problème signalé (type, heure, dossier, résumé).
        2. Ouvrir le dossier qu'il indique, **summary.md d'abord** (exception, signal, pile du thread
           fautif symbolisée, dernières actions), puis `journal.log`.
        3. `python3 tools/diag_latest.py` (dans le dépôt) fait ces trois lectures d'un coup ;
           `python3 tools/diag_latest.py --list 10` liste les dix derniers rapports.

        ## Arborescence

        - `sessions/<date>_<heure>_pid<N>.log` — le journal d'une session (un fichier par lancement
          où le journal était allumé). Au-delà de 20 Mo : `.log.1` (le précédent), un nouveau `.log`.
          `.meta.json` : pid, début, version, projet, `clean_exit` (false tant que la session vit ou
          si elle est morte sans prévenir).
        - `crashes/<date>_<heure>_<SIGNAL>/` — un crash, préparé AU RELANCEMENT suivant :
          `summary.md`, `journal.log` (la fin du journal : 15 minutes, 3000 lignes au plus),
          `meta.json`, le rapport système `*.ips` du même pid, `oslog.txt` (les logs système du
          processus). Un dossier `…_ABNORMAL` est un arrêt sans rapport système (kill -9,
          « forcer à quitter », coupure de courant) : le journal est alors tout ce qu'il y a.
        - `issues/<date>_<heure>/` — un problème signalé à la main (menu Diagnostic ▸ Signaler un
          problème…, ou la commande `diag.mark`) : `note.txt`, `state.json` (état du projet, sélection,
          transport, onglets, carte son, profondeur d'annulation), `journal.log`, `oslog.txt`.

        ## Format d'une ligne du journal

            HH:MM:SS.mmm +secondes CAT   message

        `+secondes` = temps écoulé depuis le début de la session. Les identifiants d'objet sont
        raccourcis à 8 caractères. Catégories : PROJ (projet, onglets), KEY (raccourcis), MENU,
        MOUSE (clics, molette), EDIT (un point d'annulation posé : fonction, fichier:ligne), UNDO,
        API (commandes : une ligne `nom {paramètres}` à l'appel, puis `nom → ok|erreur … durée` au retour ; une commande qui plante reste la dernière ligne), TRANS (transport), PLUG
        (plugins), AUDIO (carte son), TE (messages du moteur Tracktion/JUCE), DLG (dialogues),
        ISSUE (problème signalé), CRASH (la ou les dernières lignes d'un crash), EXIT (fin de session).

        Une session qui s'arrête sur une ligne `CRASH` a planté ; sur `EXIT`, elle s'est terminée
        normalement (ou a reçu SIGTERM/SIGINT d'un autre processus) ; sur autre chose, elle a été
        tuée sans prévenir.

        Rotation : 30 sessions et 300 Mo au plus ; 50 derniers dossiers `crashes/` et `issues/`.
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Entretien

    struct SessionFiles {
        var base: String
        var urls: [URL] = []
        var bytes: Int64 = 0
        var newest = Date.distantPast
    }

    /// Les sessions du dossier, regroupées par nom de base (`<date>_<heure>_pid<N>`).
    static func sessions(in root: URL) -> [SessionFiles] {
        let dir = sessionsDirectory(root)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return [] }
        var byBase: [String: SessionFiles] = [:]
        for url in urls {
            let name = url.lastPathComponent
            guard let base = baseName(of: name) else { continue }
            var entry = byBase[base] ?? SessionFiles(base: base)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            entry.urls.append(url)
            entry.bytes += Int64(values?.fileSize ?? 0)
            if let m = values?.contentModificationDate, m > entry.newest { entry.newest = m }
            byBase[base] = entry
        }
        return Array(byBase.values)
    }

    /// `2026-11-15_150211_pid123.log.1` → `2026-11-15_150211_pid123`.
    static func baseName(of fileName: String) -> String? {
        for suffix in [".meta.json", ".log.1", ".log", ".reported"] where fileName.hasSuffix(suffix) {
            return String(fileName.dropLast(suffix.count))
        }
        return nil
    }

    /// Lit le méta d'une session (nil si absent ou illisible).
    static func meta(forBase base: String, in root: URL) -> [String: Any]? {
        let url = sessionsDirectory(root).appendingPathComponent("\(base).meta.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    static let maxSessions = 30
    static let maxTotalBytes: Int64 = 300 * 1024 * 1024
    static let maxReportFolders = 50

    /// Garde 29 sessions (la nouvelle fait la trentième) et 300 Mo, les plus récentes d'abord.
    /// Ne touche JAMAIS une session vivante (une autre instance écrit dedans) ni une session morte
    /// dont le rapport se prépare encore.
    static func prune(_ root: URL) {
        let fm = FileManager.default
        var all = sessions(in: root).sorted { $0.newest > $1.newest }   // récentes d'abord
        var kept: [SessionFiles] = []
        var total: Int64 = 0
        for entry in all {
            let protected = isProtected(entry, root: root)
            if protected {
                kept.append(entry); total += entry.bytes
                continue
            }
            if kept.count < maxSessions - 1, total + entry.bytes <= maxTotalBytes {
                kept.append(entry); total += entry.bytes
            } else {
                for url in entry.urls { try? fm.removeItem(at: url) }
            }
        }
        all.removeAll()
        pruneReportFolders(crashesDirectory(root))
        pruneReportFolders(issuesDirectory(root))
    }

    private static func isProtected(_ entry: SessionFiles, root: URL) -> Bool {
        if DiagCrashReports.isInFlight(base: entry.base) { return true }
        guard let meta = meta(forBase: entry.base, in: root),
              (meta["clean_exit"] as? Bool) == false else { return false }
        let pid = Int32((meta["pid"] as? Int) ?? 0)
        let start = (meta["start_epoch"] as? Double) ?? 0
        if isProcessAlive(pid: pid, sessionStart: start) { return true }
        // Morte sans rapport terminé : le relancement va la traiter (ou la reprendre).
        let reported = sessionsDirectory(root).appendingPathComponent("\(entry.base).reported")
        return reportMarkerState(reported) != .done
    }

    // MARK: - Marqueur « rapport pris / terminé »

    enum MarkerState: Equatable { case absent, claimed(pid: Int32, at: Double), done }

    static func reportMarkerState(_ marker: URL) -> MarkerState {
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else {
            return fm_exists(marker) ? .claimed(pid: 0, at: 0) : .absent
        }
        if text.hasPrefix("done") { return .done }
        var pid: Int32 = 0
        var at = 0.0
        for part in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            if part.hasPrefix("pid=") { pid = Int32(part.dropFirst(4)) ?? 0 }
            if part.hasPrefix("at=") { at = Double(part.dropFirst(3)) ?? 0 }
        }
        return .claimed(pid: pid, at: at)
    }

    /// Prend le rapport d'une session morte. Vrai si CETTE instance le prépare : le marqueur n'existait
    /// pas, ou il datait d'une instance morte avant la fin du travail.
    static func claimReport(marker: URL) -> Bool {
        func create() -> Bool {
            let fd = open(marker.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd < 0 { return false }
            let text = "claimed pid=\(getpid()) at=\(Date().timeIntervalSince1970)\n"
            _ = text.withCString { write(fd, $0, strlen($0)) }
            close(fd)
            return true
        }
        if create() { return true }
        switch reportMarkerState(marker) {
        case .done: return false
        case .absent: return create()
        case .claimed(let pid, let at):
            // Vivante : quelqu'un s'en occupe. Morte (ou marqueur illisible) : on reprend.
            if pid > 0, isProcessAlive(pid: pid, sessionStart: at) { return false }
            try? FileManager.default.removeItem(at: marker)
            return create()
        }
    }

    static func markReportDone(marker: URL) {
        try? "done\n".write(to: marker, atomically: true, encoding: .utf8)
    }

    private static func fm_exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private static func pruneReportFolders(_ dir: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let folders = names.filter { !$0.hasPrefix(".") }.sorted()      // le nom commence par la date
        guard folders.count > maxReportFolders else { return }
        for name in folders.prefix(folders.count - maxReportFolders) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - LATEST.md

    private static let latestLock = NSLock()
    /// L'heure du dernier rapport inscrit dans LATEST.md par CE processus. Les rapports d'un
    /// relancement sont préparés en parallèle et finissent dans le désordre (surtout quand aucun
    /// .ips n'arrive : tous attendent le délai complet) ; le dernier à finir ne doit pas pour
    /// autant prendre la place d'un rapport plus récent.
    nonisolated(unsafe) private static var latestWrittenTime: Date?

    static func writeLatest(root: URL, kind: String, time: Date, folder: URL, summary: String) {
        latestLock.lock(); defer { latestLock.unlock() }
        if let written = latestWrittenTime, time < written { return }
        latestWrittenTime = time
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let text = """
        # Dernier rapport OBJEKAT

        - Type : \(kind)
        - Heure : \(f.string(from: time))
        - Dossier : \(folder.path)
        - Résumé : \(summary.replacingOccurrences(of: "\n", with: " "))
        - À lire : `summary.md` d'abord (crash), `note.txt` puis `state.json` (problème), puis `journal.log`.

        Voir aussi `README.md` (ce dossier) et `tools/diag_latest.py` (dépôt).
        """
        try? text.write(to: latestFile(root), atomically: true, encoding: .utf8)
    }

    // MARK: - Processus

    /// Le pid tourne-t-il encore, et est-ce bien le même processus ? Un pid réutilisé démarre
    /// APRÈS la session qu'on examine : on compare l'heure de lancement du processus à celle
    /// de la session.
    static func isProcessAlive(pid: Int32, sessionStart: Double) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 && errno == ESRCH { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        if sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 {
            let tv = info.kp_proc.p_un.__p_starttime
            let launched = Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
            return launched <= sessionStart + 5
        }
        return true   // EPERM et consorts : il existe, on ne le déclare pas mort
    }

    struct ProcessResult {
        var status: Int32
        var timedOut: Bool
        var output: String
    }

    /// Lance un exécutable, attend au plus `timeout` secondes (puis le termine). Si `outputFile`
    /// est donné, la sortie y est ÉCRITE au fil de l'eau (et reste, même tronquée par le délai) ;
    /// sinon elle est rendue en `output`.
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval,
                    outputFile: URL? = nil) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        var handle: FileHandle?
        let pipe = Pipe()
        if let outputFile {
            if !FileManager.default.fileExists(atPath: outputFile.path) {
                FileManager.default.createFile(atPath: outputFile.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: outputFile)
            _ = try? handle?.seekToEnd()
            process.standardOutput = handle
        } else {
            process.standardOutput = pipe
        }
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch {
            try? handle?.close()
            return ProcessResult(status: -1, timedOut: false, output: "")
        }
        var collected = Data()
        // La sortie est lue PENDANT que le processus tourne (un tube plein le bloquerait).
        var timedOut = false
        if outputFile == nil {
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                collected = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            if done.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                _ = done.wait(timeout: .now() + 2)
            }
            _ = group.wait(timeout: .now() + 2)
        } else {
            if done.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                _ = done.wait(timeout: .now() + 2)
            }
            try? handle?.close()
        }
        let text = String(data: collected, encoding: .utf8) ?? ""
        return ProcessResult(status: process.isRunning ? -1 : process.terminationStatus,
                             timedOut: timedOut, output: text)
    }
}
