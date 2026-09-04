import AppKit
import SwiftUI

// An EXPLICIT entry point, in place of `@main` on `objekatApp`.
//
// With no argument, the SwiftUI app starts exactly as before: `objekatApp.main()` is what the
// `@main` attribute used to call for us. With `--headless`, no scene is instantiated and we
// enter a run loop with no window — see HeadlessRunner for why AppKit is still required.
//
// This file MUST be called main.swift: it is the only name where Swift accepts top-level code,
// and its presence in turn demands that `objekatApp` no longer carry `@main` (two entry points
// would be a compile error).

let launchArguments = LaunchArguments.process

// Before any view: `Bundle` freezes the language on the first text asked of it, and a window
// already built does not get retranslated.
Localization.applyLaunchOverride(launchArguments)

// Before the engine is built: it is `-[OBJEngineCore init]` that opens the audio device.
OBJEngineCore.setAudioDisabled(launchArguments.noAudio)

if launchArguments.headless {
    MainActor.assumeIsolated { HeadlessRunner.run(launchArguments) }
} else {
    objekatApp.main()
}
