import AppKit
import Foundation

// MARK: - The computer keyboard as a MIDI input
//
// The « Computer Keyboard » input is an ordinary MIDI input of the engine (a Tracktion virtual device, created once
// at launch and always listed — @see OBJEngineCore `sendComputerKeyboardNote:`): it can be armed, recorded, given an
// instrument and heard like any other. What is specific to it is only WHO FEEDS IT, and that is this file: while the
// MODE is on, the key monitor (`TimelineKeyHandler`) hands every keyDown to `computerKeyboardKeyDown`, which asks
// the pure `ComputerKeyboardMap.route` what to do with it and, for a note, sends it to the device.
//
// The mode is a flag of the app and never touches the device: switching it must not change the engine's device list,
// since a change destroys and rebuilds every input instance (a live monitor, a recording). It is off at launch, it
// survives a tab switch, it is not saved and not in the undo.
//
// Every way a key can be left down without its keyUp ever reaching the monitor ends in `allNotesOff()`: the mode
// switched off, the app losing focus, ⌘ appearing, the monitor removed, a tab switch. A note-off is always read from
// `computerKeyboardHeld` — filled at the press — never recomputed from the octave of the moment.

extension EditViewModel {

    /// The octave the keys play in, written the way the piano roll writes it (base 60 → "C4").
    var computerKeyboardOctaveName: String { ComputerKeyboardMap.octaveName(computerKeyboardOctave) }

    /// Turns the mode on or off. Off lets every sounding note go first.
    func setComputerKeyboardMode(_ on: Bool) {
        guard on != computerKeyboardOn else { return }
        if !on { allNotesOff() }
        computerKeyboardOn = on
    }

    func toggleComputerKeyboardMode() { setComputerKeyboardMode(!computerKeyboardOn) }

    /// Sets the base note under `q` (a multiple of 12 within 0…108). false when it is out of range.
    @discardableResult
    func setComputerKeyboardOctave(_ base: Int) -> Bool {
        guard ComputerKeyboardMap.octaveRange.contains(base), base % ComputerKeyboardMap.octaveStep == 0 else { return false }
        computerKeyboardOctave = base
        return true
    }

    /// The ONE entry of a keyDown, for the key monitor and for the `midi.keyboard.key` command alike: it asks the
    /// pure router, then does what it says. The caller reads the answer to know whether the key is consumed
    /// (`.passThrough` is the only answer that leaves it to the rest of the app).
    @discardableResult
    func computerKeyboardKeyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool) -> ComputerKeyboardMap.Decision {
        let decision = ComputerKeyboardMap.route(keyCode: keyCode, flags: flags, isRepeat: isRepeat,
                                                 modeOn: computerKeyboardOn, held: computerKeyboardHeld,
                                                 octave: computerKeyboardOctave)
        switch decision {
        case .noteOn(let code, let note):
            computerKeyboardHeld[code] = note
            engine?.sendComputerKeyboardNote(note, velocity: ComputerKeyboardMap.velocity, on: true)
        case .octave(let base):
            computerKeyboardOctave = base
        case .passThrough, .swallow:
            break
        }
        return decision
    }

    /// A keyUp: turns off the note that key started, if any. true when it did (the key was ours). Independent
    /// of the mode: a key pressed while the mode was on is released whatever happened since.
    @discardableResult
    func computerKeyboardKeyUp(keyCode: UInt16) -> Bool {
        guard let note = ComputerKeyboardMap.noteToRelease(keyCode: keyCode, held: computerKeyboardHeld) else { return false }
        computerKeyboardHeld[keyCode] = nil
        engine?.sendComputerKeyboardNote(note, velocity: 0, on: false)
        return true
    }

    /// Lets every sounding note go. Idempotent, and cheap when nothing sounds (it is called on every ⌘ appearing).
    func allNotesOff() {
        guard !computerKeyboardHeld.isEmpty else { return }
        let notes = Set(computerKeyboardHeld.values)
        computerKeyboardHeld = [:]
        for note in notes.sorted() { engine?.sendComputerKeyboardNote(note, velocity: 0, on: false) }
    }
}
