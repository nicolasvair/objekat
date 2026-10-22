//
//  CompatSymbols.swift
//  objekat
//
//  Some SF Symbols are newer than macOS 12 (`dial.low`, `dial.medium`, …): `Image(systemName:)`
//  would draw nothing for them. The test is made at RUN time, so a system that has the symbol
//  shows the original one and only an older one falls back.
//  To delete when the deployment target is >= 13.
//

import SwiftUI
import AppKit

enum CompatSymbols {
    /// `name` if this system has the symbol, else `fallback`.
    static func name(_ name: String, fallback: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : fallback
    }
}

extension Image {
    init(compatSystemName name: String, fallback: String) {
        self.init(systemName: CompatSymbols.name(name, fallback: fallback))
    }
}
