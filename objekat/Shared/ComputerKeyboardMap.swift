import AppKit

// MARK: - The computer keyboard as a MIDI input (table + routing, PURE)
//
// The « Computer Keyboard » MIDI input (Ableton's way) turns the letter keys into notes. This file holds
// the two things that need no engine and no view-model, so they can be asserted with no screen
// (tools/test_computer_keyboard_map.swift):
//
//  - the TABLE: a PHYSICAL keyCode → a semitone offset above the base note. Keys are named by keyCode and
//    not by character, for the reason written in CLAUDE.md (« what a key MEANS and what it TYPES are two
//    different questions »): the layout of the plan is the AZERTY one (the home row q s d f g h j k l m is
//    the white keys, the row above z e · t y u · o p the black ones), and keyCodes keep it on any layout.
//  - the DECISION (`route`): what the key monitor does with a keyDown — let it through, swallow it, play a
//    note, move the octave. The monitor and the `midi.keyboard.key` API command both call it, which is what
//    lets a headless test prove the very routing the hand uses.
//
// Why the note-off goes through a table filled at the PRESS (`held`: keyCode → the note really sent) and not
// through a recomputation at the release: `w` / `x` move the octave while a key may still be down, and
// recomputing would turn off a note that was never turned on — the one that was would hang for ever.

enum ComputerKeyboardMap {

    /// The velocity of every note: a computer key has none to give.
    static let velocity = 100

    /// The lowest key (`q`) at the start: MIDI 60, which our piano roll names C4 (`PianoRollView`).
    static let defaultOctave = 60
    /// The range of the base note: 0 … 108, one octave (12) per step. 108 + 16 = 124 keeps every key ≤ 127.
    static let octaveRange = 0...108
    static let octaveStep = 12

    /// The octave keys, by physical keyCode: `w` goes down, `x` goes up.
    static let octaveDownKeyCode: UInt16 = 6
    static let octaveUpKeyCode: UInt16 = 7

    /// keyCode → semitones above the base note. C q 0 · C# z 13 · D s 1 · D# e 14 · E d 2 · F f 3 · F# t 17 ·
    /// G g 5 · G# y 16 · A h 4 · A# u 32 · B j 38 · C+1 k 40 · C#+1 o 31 · D+1 l 37 · D#+1 p 35 · E+1 m 41.
    static let noteOffsets: [UInt16: Int] = [
        0: 0, 13: 1, 1: 2, 14: 3, 2: 4, 3: 5, 17: 6, 5: 7, 16: 8, 4: 9, 32: 10, 38: 11,
        40: 12, 31: 13, 37: 14, 35: 15, 41: 16,
    ]

    /// The modifiers that turn the computer keyboard OFF for a key: ⌘ ⌃ ⌥ ⇧. Not `flags.isEmpty` — caps lock,
    /// fn and the arrows' stamp are not a hand holding a modifier (CLAUDE.md, « An arrow key is NEVER bare »).
    static let heldModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    /// What the monitor must do with one keyDown.
    enum Decision: Equatable {
        /// Not ours: the key follows the path it always had.
        case passThrough
        /// Ours, and nothing to do: a repeat, a key already down, an octave at its limit. Consumed, so that
        /// the tool or the zoom it would otherwise trigger does not fire (and AppKit does not beep).
        case swallow
        /// Play `note` and remember it under `keyCode` (the table `held`).
        case noteOn(keyCode: UInt16, note: Int)
        /// The octave moves: the new base note.
        case octave(Int)
    }

    /// The decision for a keyDown. `held` is the table keyCode → note filled by the previous `.noteOn`s,
    /// `octave` the current base note (the one under `q`).
    ///
    /// Mode off → never ours. A modifier among ⌘ ⌃ ⌥ ⇧ → never ours (it is how a tool key stays reachable
    /// while the mode is on: ⇧S, ⇧F…). Only the keys of the table and `w` / `x` are ours.
    static func route(keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool, modeOn: Bool,
                      held: [UInt16: Int], octave: Int) -> Decision {
        guard modeOn, flags.intersection(heldModifiers).isEmpty else { return .passThrough }
        if let offset = noteOffsets[keyCode] {
            // A repeat is swallowed whether the note is held or not: a key pressed under ⇧ then freed of it
            // repeats as a bare key that never had a note-on — it must not become a tool.
            if isRepeat || held[keyCode] != nil { return .swallow }
            let note = octave + offset
            return (0...127).contains(note) ? .noteOn(keyCode: keyCode, note: note) : .swallow
        }
        if keyCode == octaveDownKeyCode || keyCode == octaveUpKeyCode {
            if isRepeat { return .swallow }
            let next = octave + (keyCode == octaveUpKeyCode ? octaveStep : -octaveStep)
            return octaveRange.contains(next) ? .octave(next) : .swallow
        }
        return .passThrough
    }

    /// The note to turn off when `keyCode` is released: the one fixed at the press, nil when that key was
    /// not holding any. Independent of the mode and of the octave on purpose.
    static func noteToRelease(keyCode: UInt16, held: [UInt16: Int]) -> Int? {
        held[keyCode]
    }

    /// The name of the key's octave as the piano roll writes it: base 60 → "C4", 0 → "C-1", 108 → "C8".
    static func octaveName(_ octave: Int) -> String {
        "C\(octave / octaveStep - 1)"
    }
}
