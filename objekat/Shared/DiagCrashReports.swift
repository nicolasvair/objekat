//
//  DiagCrashReports.swift
//  objekat
//
//  Au RELANCEMENT, prépare en silence le dossier d'un crash : ce que le journal disait juste avant,
//  le rapport système (.ips) du même processus, les logs système, et un summary.md qui dit l'essentiel.
//
//  Le crash lui-même n'écrit presque rien (@see OBJDiagLog.c : une ligne CRASH et des adresses) ;
//  tout le travail coûteux — retrouver le .ips, symboliser la pile, interroger `log show` — se fait
//  ici, dans le processus SUIVANT, en arrière-plan, sans jamais alerter l'utilisateur. C'est à lui
//  de dire « regarde le dernier crash » ; LATEST.md et tools/diag_latest.py font le reste.
//
//  UNE SESSION EST MORTE quand son méta dit clean_exit:false ET que son pid ne tourne plus (ou
//  qu'un autre processus a repris ce pid depuis). Le marqueur `<session>.reported`, créé en
//  O_EXCL, dit qu'une instance s'en est chargée : deux instances qui se relancent en même temps ne
//  la signalent pas deux fois.
//

import Foundation

nonisolated enum DiagCrashReports {

    // MARK: - État

    private static let lock = NSLock()
    nonisolated(unsafe) private static var inFlight: Set<String> = []

    static func isInFlight(base: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.contains(base)
    }

    /// Combien de rapports sont encore en préparation dans ce processus.
    static var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return inFlight.count
    }

    // MARK: - Détection (synchrone, avant le moteur)

    /// Cherche les sessions mortes et lance, pour chacune, la préparation de son rapport en
    /// arrière-plan. Rapide : lit quelques petits fichiers méta. Renvoie le nombre de sessions prises.
    @discardableResult
    static func scanAtLaunch(root: URL, ipsWait: Double) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: DiagStore.sessionsDirectory(root).path) else { return 0 }
        var claimed = 0
        for entry in DiagStore.sessions(in: root) {
            guard let meta = DiagStore.meta(forBase: entry.base, in: root),
                  (meta["clean_exit"] as? Bool) == false else { continue }
            let pid = Int32((meta["pid"] as? Int) ?? 0)
            let start = (meta["start_epoch"] as? Double) ?? 0
            if DiagStore.isProcessAlive(pid: pid, sessionStart: start) { continue }
            // La prise : atomique, une seule instance gagne.
            let marker = DiagStore.sessionsDirectory(root).appendingPathComponent("\(entry.base).reported")
            let fd = open(marker.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd < 0 { continue }
            close(fd)
            lock.lock(); inFlight.insert(entry.base); lock.unlock()
            claimed += 1
            let thread = Thread {
                Builder(root: root, base: entry.base, meta: meta, ipsWait: ipsWait).run()
                lock.lock(); inFlight.remove(entry.base); lock.unlock()
            }
            thread.name = "objekat.diag.crashreport"
            thread.qualityOfService = .utility
            thread.start()
        }
        return claimed
    }

    // MARK: - Lecture du dernier rapport (diag.status)

    /// Le dernier dossier de crash du disque (le nom commence par la date), ou nil.
    static func lastCrash(root: URL) -> [String: Any]? {
        let dir = DiagStore.crashesDirectory(root)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        for name in names.filter({ !$0.hasPrefix(".") }).sorted(by: >) {
            let folder = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
                  var meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            meta["dir"] = folder.path
            return meta
        }
        return nil
    }

    // MARK: - La préparation d'un rapport

    struct Builder {
        let root: URL
        let base: String
        let meta: [String: Any]
        let ipsWait: Double

        var pid: Int { (meta["pid"] as? Int) ?? 0 }
        var startEpoch: Double { (meta["start_epoch"] as? Double) ?? 0 }
        var sessions: URL { DiagStore.sessionsDirectory(root) }

        func run() {
            let fm = FileManager.default
            let logURL = sessions.appendingPathComponent("\(base).log")
            let rotated = sessions.appendingPathComponent("\(base).log.1")

            // 1. Le journal : la fin, dans l'ordre.
            let ended = ((try? logURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate) ?? Date()
            var lines: [String] = []
            for url in [rotated, logURL] {
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false)
                        .map(String.init))
                }
            }
            if lines.last == "" { lines.removeLast() }
            let tail = Self.tailOf(lines)
            let crashLines = tail.filter { $0.contains(" CRASH ") }
            let journalSignal = Self.signalName(in: crashLines)
            let sawExit = tail.contains { $0.contains(" EXIT ") }

            // 2. Le rapport système du même pid : le temps qu'il apparaisse.
            var ips: (url: URL, header: [String: Any], body: [String: Any])?
            let deadline = Date().addingTimeInterval(max(0, ipsWait))
            repeat {
                ips = Self.findIPS(pid: pid, since: startEpoch - 5)
                if ips != nil { break }
                if ipsWait <= 0 { break }
                Thread.sleep(forTimeInterval: 1.0)
            } while Date() < deadline

            let ipsException = ips?.body["exception"] as? [String: Any]
            let signal = journalSignal
                ?? (ipsException?["signal"] as? String)
                ?? "ABNORMAL"

            // 3. Le dossier.
            let crashesDir = DiagStore.crashesDirectory(root)
            try? fm.createDirectory(at: crashesDir, withIntermediateDirectories: true)
            let stamp = Diag.fileStamp(ended)
            var folder = crashesDir.appendingPathComponent("\(stamp)_\(signal)", isDirectory: true)
            var n = 2
            while fm.fileExists(atPath: folder.path) {
                folder = crashesDir.appendingPathComponent("\(stamp)_\(signal)-\(n)", isDirectory: true)
                n += 1
            }
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

            let abnormal = (signal == "ABNORMAL")
            var info: [String: Any] = [
                "session": base, "pid": pid, "signal": signal,
                "abnormal": abnormal, "ips_found": ips != nil,
                "ended": ISO8601DateFormatter().string(from: ended),
                "version": meta["version"] ?? "?", "build": meta["build"] ?? "?",
                "project": meta["project"] ?? NSNull(),
                "complete": false,
            ]
            Self.writeJSON(info, to: folder.appendingPathComponent("meta.json"))
            try? tail.joined(separator: "\n").appending("\n")
                .write(to: folder.appendingPathComponent("journal.log"), atomically: true, encoding: .utf8)
            if let ips { try? fm.copyItem(at: ips.url, to: folder.appendingPathComponent(ips.url.lastPathComponent)) }

            // 4. Les logs système (longs : en dernier, délai borné).
            let oslog = folder.appendingPathComponent("oslog.txt")
            Self.runOSLog(pid: pid, from: Date(timeIntervalSince1970: startEpoch),
                          to: ended.addingTimeInterval(30), output: oslog)

            // 5. Le résumé.
            let summaryLine = Self.oneLineSummary(signal: signal, abnormal: abnormal, crashLines: crashLines,
                                                  ips: ips?.body, sawExit: sawExit)
            let text = Self.summaryText(folder: folder, meta: meta, signal: signal, abnormal: abnormal,
                                        ended: ended, tail: tail, crashLines: crashLines, ips: ips,
                                        ipsFileName: ips?.url.lastPathComponent, oneLine: summaryLine)
            try? text.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)

            info["summary"] = summaryLine
            info["complete"] = true
            Self.writeJSON(info, to: folder.appendingPathComponent("meta.json"))
            DiagStore.writeLatest(root: root, kind: abnormal ? "arrêt anormal" : "crash (\(signal))",
                                  time: ended, folder: folder, summary: summaryLine)
        }

        // MARK: Journal

        /// 15 minutes avant la dernière ligne, 3000 lignes au plus.
        static func tailOf(_ lines: [String]) -> [String] {
            var lastSeconds: Double?
            for line in lines.reversed() {
                if let s = seconds(of: line) { lastSeconds = s; break }
            }
            var kept = lines
            if let last = lastSeconds {
                if let first = lines.firstIndex(where: { (seconds(of: $0) ?? -1) >= last - 900 }) {
                    kept = Array(lines[first...])
                }
            }
            return Array(kept.suffix(3000))
        }

        /// `15:02:11.123 +12.345 API …` → 12.345
        static func seconds(of line: String) -> Double? {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[1].hasPrefix("+") else { return nil }
            return Double(parts[1].dropFirst())
        }

        static func signalName(in crashLines: [String]) -> String? {
            for line in crashLines {
                guard let r = line.range(of: "signal SIG") else { continue }
                let rest = line[line.index(r.lowerBound, offsetBy: 7)...]
                let name = rest.prefix { $0.isLetter || $0.isNumber }
                if !name.isEmpty { return String(name) }
            }
            // Une exception ObjC non rattrapée finit par un abort() : la ligne SIGABRT suit ; sans elle,
            // on le dit quand même plutôt que d'appeler ça « anormal ».
            if crashLines.contains(where: { $0.contains("objc_exception") }) { return "SIGABRT" }
            return nil
        }

        // MARK: Rapport système

        static func findIPS(pid: Int, since: Double) -> (url: URL, header: [String: Any], body: [String: Any])? {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
            let processName = ProcessInfo.processInfo.processName
            let candidates = urls.filter { $0.pathExtension == "ips" && $0.lastPathComponent.hasPrefix(processName) }
                .compactMap { url -> (URL, Date)? in
                    guard let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate, m.timeIntervalSince1970 >= since else { return nil }
                    return (url, m)
                }
                .sorted { $0.1 > $1.1 }
            for (url, _) in candidates {
                guard let parsed = parseIPS(url), (parsed.body["pid"] as? Int) == pid else { continue }
                return (url, parsed.header, parsed.body)
            }
            return nil
        }

        /// Un .ips : une première ligne JSON (en-tête), puis le corps JSON.
        static func parseIPS(_ url: URL) -> (header: [String: Any], body: [String: Any])? {
            guard let data = try? Data(contentsOf: url), let nl = data.firstIndex(of: 0x0A) else { return nil }
            guard let header = try? JSONSerialization.jsonObject(with: data[..<nl]) as? [String: Any],
                  let body = try? JSONSerialization.jsonObject(with: data[data.index(after: nl)...]) as? [String: Any]
            else { return nil }
            return (header, body)
        }

        // MARK: os_log

        static func runOSLog(pid: Int, from: Date, to: Date, output: URL) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let header = "# log show --predicate 'processIdentifier == \(pid)' --start '\(f.string(from: from))'"
                + " --end '\(f.string(from: to))' --style compact\n"
            try? header.write(to: output, atomically: true, encoding: .utf8)
            let result = DiagStore.run("/usr/bin/log",
                                       ["show", "--predicate", "processIdentifier == \(pid)",
                                        "--start", f.string(from: from), "--end", f.string(from: to),
                                        "--style", "compact"],
                                       timeout: 30, outputFile: output)
            if result.timedOut, let h = try? FileHandle(forWritingTo: output) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data("\n# (interrompu : délai de 30 s dépassé)\n".utf8))
                try? h.close()
            }
        }

        // MARK: Résumé

        static func oneLineSummary(signal: String, abnormal: Bool, crashLines: [String],
                                   ips: [String: Any]?, sawExit: Bool) -> String {
            if abnormal {
                return "arrêt anormal sans rapport système (kill -9, forcer à quitter, coupure…)"
            }
            var parts = ["\(signal)"]
            if let exception = ips?["exception"] as? [String: Any] {
                if let type = exception["type"] as? String { parts.append(type) }
                if let sub = exception["subtype"] as? String { parts.append(sub) }
            }
            if let line = crashLines.first(where: { $0.contains("objc_exception") }),
               let r = line.range(of: "objc_exception") {
                parts.append(String(line[r.lowerBound...].prefix(200)))
            }
            if let top = topFrameDescription(ips) { parts.append("dans " + top) }
            return parts.joined(separator: " — ")
        }

        static func topFrameDescription(_ body: [String: Any]?) -> String? {
            guard let body, let threads = body["threads"] as? [[String: Any]],
                  let idx = body["faultingThread"] as? Int, idx >= 0, idx < threads.count,
                  let frames = threads[idx]["frames"] as? [[String: Any]] else { return nil }
            for frame in frames.prefix(8) {
                if let symbol = frame["symbol"] as? String { return symbol }
            }
            return nil
        }

        static func summaryText(folder: URL, meta: [String: Any], signal: String, abnormal: Bool, ended: Date,
                                tail: [String], crashLines: [String],
                                ips: (url: URL, header: [String: Any], body: [String: Any])?,
                                ipsFileName: String?, oneLine: String) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            var out = "# \(abnormal ? "Arrêt anormal" : "Crash \(signal)") — \(f.string(from: ended))\n\n"
            out += "\(oneLine)\n\n"
            out += "## Processus\n\n"
            out += "- OBJEKAT \(meta["version"] ?? "?") (\(meta["build"] ?? "?")), pid \(meta["pid"] ?? "?"),"
            out += " démarré \(meta["start"] ?? "?")\n"
            if let startEpoch = meta["start_epoch"] as? Double {
                let duration = max(0, ended.timeIntervalSince1970 - startEpoch)
                out += "- Durée de la session : \(Int(duration / 60)) min \(Int(duration) % 60) s\n"
            }
            out += "- Projet : \((meta["project"] as? String) ?? "(aucun)")"
            if let path = meta["project_path"] as? String { out += " — \(path)" }
            out += "\n- macOS : \(meta["macos"] ?? "?")\n"
            out += "- Mode : \((meta["headless"] as? Bool) == true ? "headless" : "fenêtré")\n\n"

            if abnormal {
                out += "## Ce qu'on sait\n\nLe journal ne se termine ni par `CRASH` ni par `EXIT`, et aucun rapport "
                out += "système n'a été trouvé pour ce pid : le processus a été tué sans prévenir "
                out += "(kill -9, « forcer à quitter », coupure de courant, mémoire…). "
                out += "Le journal ci-dessous est tout ce qu'on a.\n\n"
            } else {
                out += "## Exception\n\n"
                if let body = ips?.body {
                    if let exception = body["exception"] as? [String: Any] {
                        out += "- Type : \(exception["type"] ?? "?") / \(exception["signal"] ?? "?")"
                        if let sub = exception["subtype"] as? String { out += " — \(sub)" }
                        out += "\n"
                    }
                    if let termination = body["termination"] as? [String: Any] {
                        out += "- Terminaison : \(termination["namespace"] ?? "?") \(termination["indicator"] ?? "")\n"
                    }
                    if let asi = body["asi"] as? [String: Any] {
                        for (key, value) in asi.sorted(by: { $0.key < $1.key }) {
                            if let list = value as? [String] {
                                for line in list.prefix(6) { out += "- \(key) : \(line)\n" }
                            }
                        }
                    }
                } else {
                    out += "- Aucun rapport système (.ips) trouvé pour ce pid : le résumé repose sur le journal.\n"
                }
                for line in crashLines { out += "- Journal : `\(line)`\n" }
                out += "\n"

                if let body = ips?.body {
                    out += "## Pile du thread fautif (20 premières frames)\n\n"
                    let frames = symbolizedFrames(of: body, thread: nil, limit: 20)
                    out += frames.isEmpty ? "(aucune frame dans le rapport)\n\n"
                        : "```\n" + frames.joined(separator: "\n") + "\n```\n\n"
                    if let last = body["lastExceptionBacktrace"] as? [[String: Any]], !last.isEmpty {
                        out += "## Pile de l'exception Objective-C\n\n```\n"
                        out += symbolizedFrames(of: body, frames: last, limit: 20).joined(separator: "\n")
                        out += "\n```\n\n"
                    }
                }
            }

            out += "## Dernières actions avant la fin\n\n```\n"
            let before = tail.filter { !$0.contains(" CRASH ") }.suffix(15)
            out += before.joined(separator: "\n")
            out += "\n```\n\n"
            out += "## Fichiers de ce dossier\n\n"
            out += "- `journal.log` — la fin du journal (15 min, 3000 lignes au plus)\n"
            out += "- `oslog.txt` — logs système du processus (`log show`)\n"
            if let ipsFileName { out += "- `\(ipsFileName)` — le rapport système complet\n" }
            out += "- `meta.json`\n"
            return out
        }

        // MARK: Symbolisation

        /// Les `limit` premières frames du thread fautif (ou de `frames`), une ligne chacune.
        static func symbolizedFrames(of body: [String: Any], thread: Int?, limit: Int) -> [String] {
            guard let threads = body["threads"] as? [[String: Any]] else { return [] }
            let idx = thread ?? (body["faultingThread"] as? Int ?? 0)
            guard idx >= 0, idx < threads.count,
                  let frames = threads[idx]["frames"] as? [[String: Any]] else { return [] }
            return symbolizedFrames(of: body, frames: frames, limit: limit)
        }

        static func symbolizedFrames(of body: [String: Any], frames: [[String: Any]], limit: Int) -> [String] {
            let images = body["usedImages"] as? [[String: Any]] ?? []
            let shown = Array(frames.prefix(limit))

            // Les frames sans symbole : atos, une fois par image.
            var resolved: [Int: String] = [:]
            var byImage: [Int: [(frame: Int, address: UInt64)]] = [:]
            for (i, frame) in shown.enumerated() where frame["symbol"] == nil {
                guard let imageIndex = frame["imageIndex"] as? Int, imageIndex >= 0, imageIndex < images.count,
                      let offset = (frame["imageOffset"] as? NSNumber)?.uint64Value,
                      let base = (images[imageIndex]["base"] as? NSNumber)?.uint64Value else { continue }
                byImage[imageIndex, default: []].append((i, base &+ offset))
            }
            for (imageIndex, entries) in byImage {
                let image = images[imageIndex]
                guard let path = image["path"] as? String, FileManager.default.fileExists(atPath: path),
                      !path.hasPrefix("/System/"), !path.hasPrefix("/usr/lib/"),
                      let base = (image["base"] as? NSNumber)?.uint64Value else { continue }
                let arch = (image["arch"] as? String) ?? "arm64"
                let args = ["-arch", arch, "-o", path, "-l", "0x" + String(base, radix: 16)]
                    + entries.map { "0x" + String($0.address, radix: 16) }
                let result = DiagStore.run("/usr/bin/atos", args, timeout: 25)
                let outputLines = result.output.split(separator: "\n", omittingEmptySubsequences: false)
                for (k, entry) in entries.enumerated() where k < outputLines.count {
                    let text = String(outputLines[k])
                    if !text.isEmpty, !text.hasPrefix("0x") { resolved[entry.frame] = text }
                }
            }

            var lines: [String] = []
            for (i, frame) in shown.enumerated() {
                let imageIndex = frame["imageIndex"] as? Int ?? -1
                let imageName = (imageIndex >= 0 && imageIndex < images.count)
                    ? (images[imageIndex]["name"] as? String ?? "?") : "?"
                let offset = (frame["imageOffset"] as? NSNumber)?.uint64Value ?? 0
                var what: String
                if let symbol = frame["symbol"] as? String {
                    let loc = (frame["symbolLocation"] as? NSNumber)?.intValue ?? 0
                    what = "\(symbol) + \(loc)"
                    if let file = frame["sourceFile"] as? String, let line = frame["sourceLine"] as? Int {
                        what += " (\(file):\(line))"
                    }
                } else if let atos = resolved[i] {
                    what = atos
                } else {
                    what = "0x" + String(offset, radix: 16)
                }
                let padded = imageName.count >= 28 ? imageName : imageName + String(repeating: " ", count: 28 - imageName.count)
                lines.append("#\(i)\(i < 10 ? " " : "") \(padded) \(what)")
            }
            return lines
        }

        // MARK: JSON

        static func writeJSON(_ object: [String: Any], to url: URL) {
            guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                         options: [.sortedKeys, .prettyPrinted]) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
