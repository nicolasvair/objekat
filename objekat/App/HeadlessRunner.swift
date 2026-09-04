import AppKit

/// Windowless mode.
///
/// "No UI" means NO WINDOW, not no AppKit: JUCE requires an `NSApplication` and its run loop
/// (`initialiseJuce_GUI()` is called in `-[OBJEngineCore init]`, and the engine works through
/// completion blocks posted on the main loop). So we keep the application and merely forbid it
/// to appear (`.prohibited`: no Dock icon, no menu, no window), and instantiate no SwiftUI
/// scene.
@MainActor
enum HeadlessRunner {

    static func run(_ args: LaunchArguments) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // Prepares the app without entering the loop: `NSApp` has to exist before JUCE initialises
        // (hence before the engine is built, which the session does).
        app.finishLaunching()

        let session = ObjekatSession()
        session.start()
        CommandContext.shared.session = session

        // With no window, nobody will click a modal: leaving it on `.ask` would freeze the process
        // at the first warning. `assume_yes` moves things ALONG (which is the point of an automated
        // launch) and the journal keeps what was reported — `app.dialogs` reads it back.
        session.viewModel.dialogPolicy = .assumeYes

        if let path = args.projectPath {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if session.viewModel.loadProject(from: url) {
                FileHandle.standardError.write(Data("[headless] project opened: \(url.path)\n".utf8))
            } else {
                FileHandle.standardError.write(Data("[headless] FAILED to open: \(url.path)\n".utf8))
                exit(2)
            }
        }

        // The API is not automatic: a windowless launch that exposes no socket and runs no script
        // would have no way of being driven — we say so rather than leave an inert process
        // running.
        ObjekatPreferences.shared.applyAPIPreference()
        let serving = CommandServer.shared.isRunning

        if let script = args.execPath {
            // The script runs AFTER entering the loop: the engine posts its work onto it, and a
            // command issued beforehand would never see those completions arrive.
            DispatchQueue.main.async {
                Task { @MainActor in
                    let code = await runScript(at: script, keepAlive: serving)
                    if !serving { exit(code) }
                }
            }
        } else if !serving {
            FileHandle.standardError.write(Data(
                "[headless] neither --api nor --exec: nothing to drive, stopping.\n".utf8))
            exit(2)
        }

        app.run()
        exit(0)
    }

    // MARK: - Running a JSON-lines script

    /// Replays a `.jsonl`: one request per line, `#` for comments, `{DIR}` replaced by the
    /// script's folder (the same convention as `tools/objekat_cli.py`, so that a scenario replays
    /// identically through the socket or through `--exec`).
    /// - Returns: 0 if everything succeeded, 1 as soon as one command failed.
    static func runScript(at path: String, keepAlive: Bool) async -> Int32 {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            FileHandle.standardError.write(Data("[headless] unreadable script: \(url.path)\n".utf8))
            return 2
        }
        let base = url.deletingLastPathComponent().path
        var failed = false

        for (number, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "{DIR}", with: base)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let data = line.data(using: .utf8),
                  let request = try? JSONValue.decode(line: data) else {
                FileHandle.standardError.write(Data(
                    "[headless] line \(number + 1): invalid JSON\n".utf8))
                failed = true
                continue
            }
            let response = await CommandRegistry.shared.handle(request: request)
            if let out = try? response.encodedLine() {
                FileHandle.standardOutput.write(out)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            if response["ok"]?.boolValue != true { failed = true }
        }
        return failed ? 1 : 0
    }
}
