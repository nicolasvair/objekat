//
//  CompatOnChange.swift
//  objekat
//
//  `onChange(of:initial:_:)` (the 0- and 2-parameter forms) is macOS 14. Before that only the
//  1-parameter `onChange(of:perform:)` exists, which has no old value and no `initial`.
//
//  Naming: a DISTINCT name (`onChangeCompat`), never a shadow of SwiftUI's own — an overload that
//  matches no site makes the type checker blow up on the biggest bodies (TimelineView).
//  To delete when the deployment target is >= 14.
//

import SwiftUI

struct _OnChangeCompat<V: Equatable>: ViewModifier {
    let value: V
    let initial: Bool
    let action: (V, V) -> Void
    @State private var old: V?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if old == nil {
                    old = value
                    if initial { action(value, value) }
                }
            }
            .onChange(of: value) { new in
                let o = old ?? new
                old = new
                action(o, new)
            }
    }
}

extension View {
    /// `onChange(of:initial:_:)`, the (old, new) form.
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, initial: Bool = false,
                                      _ action: @escaping (_ old: V, _ new: V) -> Void) -> some View {
        if #available(macOS 14, *), !CompatPolicy.forceLegacy {
            onChange(of: value, initial: initial, action)
        } else {
            modifier(_OnChangeCompat(value: value, initial: initial, action: action))
        }
    }

    /// `onChange(of:initial:_:)`, the no-parameter form.
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, initial: Bool = false,
                                      _ action: @escaping () -> Void) -> some View {
        if #available(macOS 14, *), !CompatPolicy.forceLegacy {
            onChange(of: value, initial: initial, action)
        } else {
            modifier(_OnChangeCompat(value: value, initial: initial, action: { _, _ in action() }))
        }
    }
}
