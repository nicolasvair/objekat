//
//  DiagLog.swift
//  objekat
//
//  Le journal de diagnostic : de quoi comprendre, APRÈS COUP, ce que l'app faisait quand elle a
//  planté ou quand quelque chose a mal tourné. Pensé pour être lu par Claude : un fichier texte,
//  une ligne par évènement, une session = un fichier.
//
//  CE QUE C'EST ET CE QUE CE N'EST PAS
//    • Désactivé par défaut (préférence `pref.diagnosticLog`, menu OBJEKAT ▸ Diagnostic). Désactivé,
//      un appel de `Diag.log` ne coûte que la lecture d'un entier : le message n'est même pas construit.
//    • Ce n'est pas un enregistreur de session : il ne dit pas tout, il dit ce qui change l'état
//      (gestes, commandes, transport, projet, plugins, carte son) — de quoi reconstituer le chemin.
//    • Il n'alerte jamais et ne prépare rien : l'app ÉCRIT (le journal, la ligne CRASH, le méta de
//      session) ; tout ce qui se lit après coup — sessions mortes, rapport système .ips, logs
//      système — est fait par `tools/diag_latest.py`, lancé à la main quand l'utilisateur dit
//      « regarde le dernier crash ».
//
//  LA PARTIE C (Shared/OBJDiagLog.c) fait le travail qui doit survivre à un crash : écriture,
//  rotation, gestionnaires de signaux. Ici, tout ce qui a droit à Foundation : dossiers, méta,
//  exceptions Objective-C.
//
//  ⚠️ JAMAIS depuis le thread audio. `Diag.log` prend un verrou et fait un write().
//
//  Les fichiers et leur lecture : ~/Library/Logs/Objekat/README.md (écrit au premier lancement),
//  docs/command_api.md (« Journal de diagnostic »), tools/diag_latest.py.
//

import Foundation
import AppKit
import CoreAudio

/// `nonisolated` : appelé depuis n'importe quel thread (serveur de commandes, rappels du moteur).
nonisolated enum Diag {

    // MARK: - Catégories

    enum Category: String {
        case proj = "PROJ"      // ouverture / sauvegarde / nouveau / onglets
        case key = "KEY"        // raccourcis clavier
        case menu = "MENU"      // entrées de menu
        case mouse = "MOUSE"    // clics, molette, pincement
        case edit = "EDIT"      // point d'annulation posé (pushUndo) : qui, où
        case undo = "UNDO"      // annuler / rétablir
        case api = "API"        // commande de l'API
        case trans = "TRANS"    // lecture / arrêt / enregistrement
        case plug = "PLUG"      // plugins : ajout, éditeur, chargement d'état
        case audio = "AUDIO"    // carte son
        case te = "TE"          // messages du moteur (Tracktion / JUCE)
        case dlg = "DLG"        // dialogues
        case issue = "ISSUE"    // problème signalé
        case crash = "CRASH"    // la dernière ligne d'un crash (écrite par le gestionnaire)
        case exit = "EXIT"      // fin de session
    }

    // MARK: - Écrire

    static var isEnabled: Bool { objdiag_enabled() != 0 }

    /// Le message est un `@autoclosure` : journal éteint, rien n'est construit.
    @inline(__always)
    static func log(_ category: Category, _ message: @autoclosure () -> String) {
        guard objdiag_enabled() != 0 else { return }
        objdiag_log(category.rawValue, message())
    }

    /// Un problème signalé à la main : une ligne `ISSUE "note"`. Faux si le journal est éteint.
    @discardableResult
    static func mark(note: String) -> Bool {
        guard isEnabled else { return false }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        log(.issue, "\"" + trimmed.replacingOccurrences(of: "\"", with: "\\\"") + "\"")
        return true
    }

    // MARK: - Aides de mise en forme

    /// `15:02:11.123 +12.345 API …` → 12.345 (les secondes de session ; nil pour une ligne d'en-tête).
    static func seconds(ofLine line: String) -> Double? {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[1].hasPrefix("+") else { return nil }
        return Double(parts[1].dropFirst())
    }

    /// Les identifiants sont raccourcis à 8 caractères : assez pour se repérer, peu pour lire.
    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    private static let uuidPattern = try! NSRegularExpression(
        pattern: "([0-9A-Fa-f]{8})-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")

    /// Raccourcit tous les UUID d'un texte (« 3F2A…-…-… » → « 3F2A… »).
    static func shortenIDs(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return uuidPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
    }

    /// `objekat/EditViewModel+Cut.swift` → `EditViewModel+Cut.swift` (`#fileID`).
    static func fileName(_ file: StaticString) -> Substring {
        let text = "\(file)"
        if let slash = text.lastIndex(of: "/") { return text[text.index(after: slash)...] }
        return Substring(text)
    }

    /// Coupe à `limit` caractères, avec une ellipse.
    static func truncated(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    // MARK: - Configuration du lancement

    nonisolated(unsafe) private(set) static var launchArguments = LaunchArguments.process

    static var isHeadless: Bool { launchArguments.headless }

    /// Racine des dossiers : `--diag-dir=` (les tests) ou `~/Library/Logs/Objekat`.
    static var rootDirectory: URL {
        if let custom = launchArguments.diagDir {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Objekat", isDirectory: true)
    }

    /// Faut-il allumer le journal au lancement ? En fenêtré : la préférence OU `--diag-log`.
    /// En `--headless` : `--diag-log` SEUL — la préférence d'un utilisateur ne fait pas écrire
    /// ses journaux par une instance de test.
    static func shouldStartAtLaunch(preference: Bool) -> Bool {
        launchArguments.diagLog || (!launchArguments.headless && preference)
    }

    // MARK: - Session

    private static let lock = NSLock()
    nonisolated(unsafe) private static var metaBase: [String: Any] = [:]
    nonisolated(unsafe) private static var sessionLogURL: URL?

    /// Le journal de la session en cours, nil si éteint.
    static var currentLogURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return isEnabled ? sessionLogURL : nil
    }

    private static func isoString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f.string(from: date)
    }

    static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: date)
    }

    static var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    static var buildString: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// Le nom de la carte de sortie par défaut du système, lu AVANT que le moteur existe. C'est
    /// une indication d'en-tête (la carte réellement ouverte arrive en ligne AUDIO).
    private static func defaultOutputDeviceName() -> String {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr, device != 0 else { return "?" }
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &name) == noErr,
              let value = name?.takeRetainedValue() else { return "?" }
        return value as String
    }

    private static func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                     options: [.sortedKeys, .prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Ouvre une session. Sans effet si une est déjà ouverte. Renvoie vrai si le journal est allumé.
    @discardableResult
    static func start() -> Bool {
        if isEnabled { return true }
        let root = rootDirectory
        DiagStore.ensureDirectories(root)
        DiagStore.writeReadmeIfNeeded(root)
        DiagStore.prune(root)

        let now = Date()
        let pid = getpid()
        let base = "\(fileStamp(now))_pid\(pid)"
        let logURL = DiagStore.sessionsDirectory(root).appendingPathComponent("\(base).log")
        let metaURL = DiagStore.sessionsDirectory(root).appendingPathComponent("\(base).meta.json")

        var meta: [String: Any] = [
            "pid": Int(pid),
            "start": isoString(now),
            "start_epoch": now.timeIntervalSince1970,
            "version": versionString,
            "build": buildString,
            "headless": launchArguments.headless,
            "log": logURL.lastPathComponent,
            "macos": ProcessInfo.processInfo.operatingSystemVersionString,
            "clean_exit": false,
        ]
        meta["project"] = NSNull()
        lock.lock(); metaBase = meta; sessionLogURL = logURL; lock.unlock()

        let header = "# OBJEKAT \(versionString) (\(buildString)) pid=\(pid) start=\(isoString(now)) "
            + "macOS \(ProcessInfo.processInfo.operatingSystemVersionString) "
            + "device=\"\(defaultOutputDeviceName())\" headless=\(launchArguments.headless ? 1 : 0)"
        let maxBytes = launchArguments.diagMaxMB.map { UInt64($0 * 1024 * 1024) } ?? 0
        meta["clean_exit"] = false
        let unclean = jsonString(meta)
        meta["clean_exit"] = true
        let clean = jsonString(meta)

        let status = objdiag_open(logURL.path, metaURL.path, unclean, clean, header, maxBytes)
        guard status == 0 else {
            NSLog("[DIAG] journal impossible à ouvrir (%d) : %@", Int(status), logURL.path)
            return false
        }
        installExceptionHandler()
        if !launchArguments.headless {
            Task { @MainActor in DiagInputMonitor.installIfNeeded() }
        }
        return true
    }

    /// Ferme la session proprement (ligne EXIT, méta clean_exit:true).
    static func stop(reason: String) {
        objdiag_close(reason)
    }

    /// Le projet ouvert, pour le méta (les dossiers de crash le disent d'emblée).
    static func setProject(name: String?, path: String?) {
        guard isEnabled else { return }
        lock.lock()
        metaBase["project"] = name ?? NSNull()
        metaBase["project_path"] = path ?? NSNull()
        var meta = metaBase
        lock.unlock()
        meta["clean_exit"] = false
        let unclean = jsonString(meta)
        meta["clean_exit"] = true
        objdiag_update_meta(unclean, jsonString(meta))
    }

    // MARK: - Exceptions Objective-C

    nonisolated(unsafe) private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?
    nonisolated(unsafe) private static var exceptionObserver: NSObjectProtocol?

    /// Notre gestionnaire. Une constante, pour pouvoir reconnaître qu'il est (ou n'est plus) en place.
    private static let uncaughtHandler: @convention(c) (NSException) -> Void = { exception in
        Diag.recordUncaught(exception)
        Diag.previousExceptionHandler?(exception)
    }

    /// Vrai si le gestionnaire d'exceptions en place est le nôtre (diagnostic des tests).
    static var exceptionHandlerIsOurs: Bool { isOurs(NSGetUncaughtExceptionHandler()) }

    private static func isOurs(_ handler: (@convention(c) (NSException) -> Void)?) -> Bool {
        guard let handler else { return false }
        return unsafeBitCast(handler, to: UnsafeRawPointer.self)
            == unsafeBitCast(uncaughtHandler, to: UnsafeRawPointer.self)
    }

    /// Une exception non rattrapée tue le processus par un abort() : la signal-handler écrit la
    /// ligne CRASH, mais seule cette porte-ci sait le NOM et la RAISON de l'exception, et la pile
    /// Objective-C qui y mène. Chaînée : l'éventuel gestionnaire précédent est rappelé ensuite.
    ///
    /// ⚠️ AppKit remplace le gestionnaire quand l'application finit de se lancer (constaté : installé
    /// dans `main.swift`, il n'était plus appelé à l'exécution). On le repose donc à la fin du
    /// lancement, toujours chaîné devant celui d'AppKit.
    static func installExceptionHandler() {
        let current = NSGetUncaughtExceptionHandler()
        if !isOurs(current) {
            previousExceptionHandler = current
            NSSetUncaughtExceptionHandler(uncaughtHandler)
        }
        if exceptionObserver == nil {
            exceptionObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: nil) { _ in
                installExceptionHandler()
                DispatchQueue.main.async { installExceptionHandler() }
            }
        }
    }

    static func recordUncaught(_ exception: NSException) {
        guard isEnabled else { return }
        objdiag_log("CRASH", "objc_exception name=\(exception.name.rawValue) "
                    + "reason=\(exception.reason ?? "?")")
        for (i, frame) in exception.callStackSymbols.prefix(40).enumerated() {
            objdiag_log("CRASH", "objc_stack #\(i) \(frame)")
        }
    }
}
