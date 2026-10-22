//
//  CompatPolicy.swift
//  objekat
//
//  One switch for the whole compat layer. In a DEBUG build, the environment variable
//  `OBJ_FORCE_LEGACY_UI=1` makes every `if #available(macOS N, *), !CompatPolicy.forceLegacy`
//  take its FALLBACK branch even on a recent macOS. It exists to exercise on a development Mac the
//  paths that only a macOS 12 machine would otherwise run (key press hub, scroll bridge, tap and
//  hover fallbacks...). In Release it is a constant `false`: the native branches are taken
//  whenever the system has them, and nothing is read from the environment.
//
//  A build compiled with the condition `OBJ_FORCE_LEGACY_BUILD` (xcodebuild override
//  `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) OBJ_FORCE_LEGACY_BUILD'`) always takes the
//  fallbacks, in Release too: a full-speed app to judge the macOS 12 rendering on a recent Mac.
//
//  To delete when the deployment target is raised.
//

import Foundation

enum CompatPolicy {
    #if OBJ_FORCE_LEGACY_BUILD
    static let forceLegacy: Bool = true
    #elseif DEBUG
    static let forceLegacy: Bool = ProcessInfo.processInfo.environment["OBJ_FORCE_LEGACY_UI"] == "1"
    #else
    static let forceLegacy: Bool = false
    #endif
}
