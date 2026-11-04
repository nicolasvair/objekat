import SwiftUI

/// The controls of the « Computer Keyboard » row of the Inputs tab: the mode (the keys play notes) and the octave they
/// play in. A view of its own, kept apart from `MidiInputsSection.row` so that reshaping the rows (the inputs become
/// rectangles) only has to say WHERE it goes, not what it holds. All the state is the view-model's
/// (`computerKeyboardOn`, `computerKeyboardOctave`); this row is now the only button that drives them (the transport bar
/// has none since 4 November 2026), `midi.keyboard.set` being the machine's door.
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
        HStack(spacing: InputRowStyle.controlSpacing) {
            Button {
                viewModel.toggleComputerKeyboardMode()
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 11))
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .help(L("inputs.keyboard.toggle.help", noteKeysText, octaveDownKeyText, octaveUpKeyText))

            Spacer(minLength: 4)

            Button { step(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold)).frame(width: 14)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.computerKeyboardOctave <= range.lowerBound)
            .help(L("inputs.keyboard.octave.down.help", octaveDownKeyText))

            Text(verbatim: viewModel.computerKeyboardOctaveName)
                .font(.system(size: 10, design: .monospaced))
                .frame(minWidth: 26)

            Button { step(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 14)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.computerKeyboardOctave >= range.upperBound)
            .help(L("inputs.keyboard.octave.up.help", octaveUpKeyText))
        }
        .foregroundStyle(on ? Color.primary : Color.secondary)
    }

    private func step(_ octaves: Int) {
        viewModel.setComputerKeyboardOctave(viewModel.computerKeyboardOctave + octaves * ComputerKeyboardMap.octaveStep)
    }
}
