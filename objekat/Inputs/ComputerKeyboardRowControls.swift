import SwiftUI

/// The controls of the « Computer Keyboard » row of the Inputs tab: the mode (the keys play notes) and the octave they
/// play in, as the strip's LEADING COLUMN (in place of the keys glyph). A view of its own, kept apart from
/// `MidiInputsSection.row` so that reshaping the rows only has to say WHERE it goes, not what it holds. All the state
/// is the view-model's (`computerKeyboardOn`, `computerKeyboardOctave`); this is now the only button that drives them
/// (the transport bar has none since 4 November 2026), `midi.keyboard.set` being the machine's door.
struct ComputerKeyboardRowControls: View {
    @Bindable var viewModel: EditViewModel

    private var range: ClosedRange<Int> { ComputerKeyboardMap.octaveRange }

    /// The tooltips name the REAL letters on this machine's layout (AZERTY, QWERTY…), read through the watcher so
    /// they follow a change of layout. The notes in the order of the keyboard's pitches.
    private var noteKeysText: String {
        let watcher = KeyboardLayoutWatcher.shared
        return ComputerKeyboardMap.noteOffsets.sorted { $0.value < $1.value }
            .map { watcher.label(forKeyCode: $0.key).lowercased() }
            .joined(separator: " ")
    }
    private var octaveDownKeyText: String {
        KeyboardLayoutWatcher.shared.label(forKeyCode: ComputerKeyboardMap.octaveDownKeyCode).lowercased()
    }
    private var octaveUpKeyText: String {
        KeyboardLayoutWatcher.shared.label(forKeyCode: ComputerKeyboardMap.octaveUpKeyCode).lowercased()
    }

    var body: some View {
        let on = viewModel.computerKeyboardOn
        // A vertical column (the strip's leading column, `InputRowStyle.leadingWidth` wide): the mode as a BUTTON that
        // reads as one — filled with the accent when on, a pale chip with a border when off — and under it the
        // octave selector. SwiftUI buttons take their click, so the strip's own tap does not fire from them.
        VStack(spacing: 3) {
            Button {
                viewModel.toggleComputerKeyboardMode()
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 15))
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .frame(width: 46, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(on ? Color.accentColor : Color.secondary.opacity(0.18)))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.secondary.opacity(0.5), lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("inputs.keyboard.toggle.help", noteKeysText, octaveDownKeyText, octaveUpKeyText))

            HStack(spacing: 0) {
                Button { step(-1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 8, weight: .semibold))
                        .frame(width: 12, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.computerKeyboardOctave <= range.lowerBound)
                .help(L("inputs.keyboard.octave.down.help", octaveDownKeyText))

                Text(verbatim: viewModel.computerKeyboardOctaveName)
                    .font(.system(size: 9, design: .monospaced))
                    .frame(minWidth: 22)

                Button { step(1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        .frame(width: 12, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.computerKeyboardOctave >= range.upperBound)
                .help(L("inputs.keyboard.octave.up.help", octaveUpKeyText))
            }
            .foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }

    private func step(_ octaves: Int) {
        viewModel.setComputerKeyboardOctave(viewModel.computerKeyboardOctave + octaves * ComputerKeyboardMap.octaveStep)
    }
}
