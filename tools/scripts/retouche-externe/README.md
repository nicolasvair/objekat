# External edit (retouche-externe)

Right click an object → **Scripts ▸ Edit in external audio editor…**

1. The object is **rendered into a new 24-bit wav** — *just the object*: its own plugins, gain and pan,
   fades, window and speed (its content, for a group), but **not** its parent group's chain, the master chain,
   aux or sends — at the **sample rate of the original's source file** (for a group whose files have several rates, a
   small panel asks which one; 48 kHz if there is no audio file, e.g. MIDI) (**mono** for a mono file, **stereo** for a stereo file or a mixed group) in `<project>/samples/retouches/` (or `~/Library/Application Support/Objekat/Retouches/` for an unsaved project).
2. It opens in your audio editor. **The first time, a macOS chooser asks which one**; the choice is kept in
   `config.json` next to the script. **Scripts ▸ Choose the audio editor…** changes it.
3. A small panel waits. Save in the editor, then **Validate**: the file comes back on a new row at the same
   instant (inside the same group when the object belongs to one), named “<name> (retouched)”, and the original is **muted** (not deleted — ⌘Z or un-mute to go back).
   **Cancel** leaves the session untouched.

Install: copy this folder into `~/Library/Application Support/Objekat/Plugins/`, then Scripts ▸ Reload.
Needs only the system Python 3 (standard library). Select ONE object.

The retouched file is laid back at the same start with no plugin, gain or fade of its own (they are already in
the file), so it comes back at the same level and the same place as the original sounded alone — whatever the
group above it and the master do to it afterwards, they do once, as they did for the original.

Limits: the object is put in direct solo during the render (a mute or another solo cannot silence it); an existing
solo is restored afterwards.
