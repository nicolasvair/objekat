# External edit (retouche-externe)

Right click an object → **Scripts ▸ Edit in external audio editor…**

1. The object is **rendered into a new 24-bit / 48 kHz wav** (its chain, fades and window included) in
   `<project>/samples/retouches/` (or `~/Library/Application Support/Objekat/Retouches/` for an unsaved project).
2. It opens in your audio editor. **The first time, a macOS chooser asks which one**; the choice is kept in
   `config.json` next to the script. **Scripts ▸ Choose the audio editor…** changes it.
3. A small panel waits. Save in the editor, then **Validate**: the file comes back on a new row at the same
   instant (inside the same group when the object belongs to one), named “<name> (retouched)”, and the original is **muted** (not deleted — ⌘Z or un-mute to go back).
   **Cancel** leaves the session untouched.

Install: copy this folder into `~/Library/Application Support/Objekat/Plugins/`, then Scripts ▸ Reload.
Needs only the system Python 3 (standard library). Select ONE object.

Limits: the render goes through the master (bus and master effects are in the file) — the only full-render
door of the API; an existing solo is restored afterwards.
