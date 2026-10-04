import SwiftUI

// MARK: - The rows of a script's controls

/// The SwiftUI rows of a script's declared controls (@see ScriptControls), shared by the panel
/// window (`ScriptPanelView`) and the canvas's sidebar. Moved out of `ScriptPanelView` with no change
/// in what is drawn: a bool is a toggle, a number a slider with its value, a choice a menu, a button
/// a button, a section a heading, a progress a bar.
///
/// The form holds no state of its own except what it is given: the controls, their current values,
/// whether the `advanced` ones are shown (`expert`), and two doors back — `set` (a value changed;
/// `coalesced` = true while a slider is being dragged) and `press` (a button). The label column's
/// width is the caller's: a 460 pt panel gives it 200, a 300 pt sidebar less.
struct ScriptControlsForm: View {
    let controls: [ScriptPanelControl]
    let values: [String: JSONValue]
    let expert: Bool
    var labelWidth: CGFloat = 200
    let set: (String, JSONValue, Bool) -> Void
    let press: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.control.id) { row in
                controlRow(row)
            }
        }
    }

    /// A bool that exactly one number is enabled by is drawn INLINE with that number ("a box and a
    /// threshold": the box says whether the criterion counts, the slider how much). Any other bool
    /// is a row of its own.
    private struct Row { let control: ScriptPanelControl; let gate: ScriptPanelControl? }

    private var rows: [Row] {
        var gateUse: [String: Int] = [:]
        for c in controls { if let by = c.enabledBy { gateUse[by, default: 0] += 1 } }
        let inline = Set(gateUse.filter { $0.value == 1 }.keys)
        return controls.compactMap { c in
            if c.advanced, !expert { return nil }
            if c.kind == .bool, inline.contains(c.id) { return nil }
            let gate = c.enabledBy.flatMap { by in controls.first { $0.id == by } }
            return Row(control: c, gate: gate)
        }
    }

    private func isOn(_ id: String) -> Bool { values[id]?.boolValue ?? false }

    @ViewBuilder
    private func controlRow(_ row: Row) -> some View {
        let c = row.control
        switch c.kind {
        case .bool:
            Toggle(isOn: Binding(get: { isOn(c.id) },
                                 set: { set(c.id, .bool($0), false) })) { Text(verbatim: c.label) }
        case .button:
            Button { press(c.id) } label: { Text(verbatim: c.label) }
        case .section:
            // A heading over the rows that follow it: the script's own text, set apart.
            VStack(alignment: .leading, spacing: 3) {
                Divider()
                Text(verbatim: c.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        case .progress:
            // A bar the script drives: a number is a fraction, `null` is "working, no idea how far".
            let fraction = values[c.id]?.doubleValue
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(verbatim: c.label).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let fraction {
                        Text(verbatim: "\(Int((fraction * 100).rounded())) %")
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                if let fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        case .choice:
            // A menu, the script's own labels: a model that is not installed says so in its label.
            HStack(spacing: 8) {
                Text(verbatim: c.label).frame(width: labelWidth, alignment: .leading)
                Picker(selection: Binding(get: { values[c.id]?.stringValue ?? c.options.first?.id ?? "" },
                                          set: { set(c.id, .string($0), false) })) {
                    ForEach(c.options, id: \.id) { o in Text(verbatim: o.label).tag(o.id) }
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        case .number:
            let enabled = row.gate.map { isOn($0.id) } ?? true
            HStack(spacing: 8) {
                if let gate = row.gate, gate.kind == .bool, inlineGate(gate) {
                    Toggle(isOn: Binding(get: { isOn(gate.id) },
                                         set: { set(gate.id, .bool($0), false) })) {
                        Text(verbatim: gate.label)
                    }
                    .frame(width: labelWidth, alignment: .leading)
                } else {
                    Text(verbatim: c.label).frame(width: labelWidth, alignment: .leading)
                }
                Slider(value: Binding(get: { values[c.id]?.doubleValue ?? c.min },
                                      set: { set(c.id, .number($0), true) }),
                       in: c.min...c.max, step: c.step)
                    .disabled(!enabled)
                Text(verbatim: format(values[c.id]?.doubleValue ?? c.min, c))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 64, alignment: .trailing)
                    .foregroundStyle(enabled ? .primary : .secondary)
            }
        }
    }

    private func inlineGate(_ gate: ScriptPanelControl) -> Bool {
        controls.filter { $0.enabledBy == gate.id }.count == 1
    }

    private func format(_ v: Double, _ c: ScriptPanelControl) -> String {
        let digits = c.step >= 1 ? 0 : (c.step >= 0.1 ? 1 : 2)
        let s = String(format: "%.\(digits)f", v)
        return c.unit.isEmpty ? s : s + " " + c.unit
    }
}
