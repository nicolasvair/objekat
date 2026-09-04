# Glossary FR → EN → ES

OBJEKAT's vocabulary, settled once and for all. It holds for the interface's three languages
AND for the code: a `soundObject` in Swift, an "objet sonore" on screen and a `sound object` in
English must name the same thing, otherwise the documentation stops being readable.

The rule is the **calque**: the project's own vocabulary is followed rather than that of a
commercial DAW. A sound object is not a "clip", a sound library is not a "browser" — those
words would carry habits that are not OBJEKAT's.

The French column comes first because that is where the vocabulary was born; it is the
source, not a translation.

## Concepts

| French | English | Spanish | note |
|---|---|---|---|
| objet sonore | sound object | objeto sonoro | the central concept: a baked content laid down in N instances |
| définition | definition | definición | the recorded content, shared by every instance |
| exemplaire | instance | ejemplar | one occurrence of a definition in the timeline |
| baker / baké | bake / baked | renderizar / renderizado | the render that freezes a sub-tree into a wave |
| sonothèque | sound library | sonoteca | the audio file browser |
| groupe | group | grupo | a submix; a container clip, not a folder of tracks |
| dissoudre un groupe | ungroup | desagrupar | the only departure from the calque: "disband" is not said in an interface |
| fenêtre (d'un objet) | window | ventana | its bounds, which also cut its effect chain |
| bus infini | infinite bus | bus infinito | an aux or a group that runs the length of the project |
| stem | stem | stem | an output bus; unchanged, the word is already English |
| envoi | send | envío | goes up towards an aux, never down |
| aux | aux | aux | the object that only receives sends |
| zone temporelle | time selection | selección temporal | the selection in time, independent of the objects |
| repères IN / OUT | IN / OUT markers | marcas IN / OUT |  |
| bande (d'automation) | (automation) lane | lane (de automatización) | `lane` is already the model's word |
| lane (rangée du modèle) | lane | lane | a row index, NOT the displayed row |
| piste | track | pista | in the Tracktion sense; the interface speaks of lanes |
| matière | material | contenido | what an object's window lets you see |
| curseur noir | playhead | cabezal | the playback cursor |
| coupe | cut | corte | the tool, and the gesture |
| aimantation | snap | snap / imantado |  |
| grille temporelle | time grid | rejilla temporal |  |
| vitesse / demi-tons | speed / semitones | velocidad / semitonos |  |
| lecture inversée | reverse playback | reproducción invertida |  |
| boucle | loop | loop |  |
| solo tenu / temporaire | held / temporary solo | solo mantenido / temporal |  |
| lever un solo | clear a solo | levantar un solo |  |
| délier / relier | unlink / link | desvincular / vincular | for linked plugin instances |
| détacher | detach | separar | for an instance being made independent |
| réglages | settings | ajustes |  |
| carte son | audio device | tarjeta de sonido |  |
| fréquence d'échantillonnage | sample rate | frecuencia de muestreo |  |
| latence / taille du buffer | latency / buffer size | latencia / tamaño del búfer |  |

## What does not get translated

- The API's command names and their arguments: they are already in English and form a
  contract. Their descriptions and their error messages are in English **and are never
  localised** — a script must not depend on the language of the machine that hosts it.
- The keys of the session file (`.objekat.json`): changing them would break existing projects.
- The names of the folders created on disk (`samples/`, `objects/`, `waveforms/`, `Objekat/`).
- The tool labels (`Edit`, `Vol.`, `Pan`, `Aux`, `Cut`): their INITIAL is the shortcut's
  key. Translating the word would move the letter, and the shortcut would no longer be readable in the name.
- The units: dB, dBFS, Hz, kHz, ms, st, %, BPM.
