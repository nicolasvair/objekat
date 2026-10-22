//
//  CompatModifiers.swift
//  objekat
//
//  Small presentation modifiers that are newer than macOS 12. Each is a no-op below its system:
//  nothing breaks, the look just stays the system's default.
//
//  - `formStyle(.grouped)`               : macOS 13 (the preferences form keeps the system look)
//  - `scrollContentBackground(.hidden)`  : macOS 13 (the comment editor keeps an opaque background)
//
//  To delete when the deployment target is >= 13.
//

import SwiftUI

extension View {
    @ViewBuilder
    func groupedFormStyleCompat() -> some View {
        if #available(macOS 13, *), !CompatPolicy.forceLegacy {
            formStyle(.grouped)
        } else {
            self
        }
    }

    @ViewBuilder
    func hiddenScrollBackgroundCompat() -> some View {
        if #available(macOS 13, *), !CompatPolicy.forceLegacy {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}
