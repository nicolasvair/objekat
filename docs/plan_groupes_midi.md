# Plan : groupes MIDI, écoute par les Entrées, FX et instruments d'entrée

Base : `main` @ `7525022f`, moteur @ `3ce916aa05e`, format de session 35, dernier patch 0048.
Statut : plan validé par l'utilisateur le 2026-10-30. Seul changement demandé : suppression de l'instrument dormant et de toute gestion des anciens projets (§2.3). Question low-latency reportée au merge de la branche. Avancement : E0 à E12 faites (un commit par étape sur `main`, rien poussé) ; reste la validation à l'écran et à l'oreille. Les numéros de ligne sont ceux de `7525022f`.

Vocabulaire du plan :
- **Clip vide** : clip MIDI sans instrument propre (`isMIDI && instruments.isEmpty`).
- **Hôte** : le premier groupe ancêtre d'un clip vide qui porte un instrument actif.
- **Hôte d'entrée** : une entrée qui porte une chaîne (FX ou instrument), adressée par un UUID stable.

---

## 1. Ce que le code confirme ou corrige dans le brief

| Affirmation | Verdict |
|---|---|
| Un VSTi écrit son buffer (`OBJEngineCore.mm:3481`) | Confirmé. `ExternalPlugin` ne prend pas l'audio d'entrée s'il est synthé. |
| `setInstrument` passe par `userPluginListForKey` | Confirmé (3681, 3741). Le moteur sait déjà poser un instrument sur un groupe. |
| Garde-fou dans `syncInstruments` (:389) | Confirmé. |
| `applyAudibilityToEngine` :322, fader -96 dB | Confirmé. Le silence d'un **sous-groupe** agit aussi en fader et ne coupe donc pas le MIDI qui le traverse : le mute natif du clip doit tenir compte des ancêtres (E3). |
| `midiTakeObject` :218 copie l'instrument | Confirmé. |
| Note-off gérés par MidiNode/LoopingMidiNode | **Partiellement faux.** `wasMute` n'est jamais remis à false au démute, dans les deux nœuds : à partir du 2e mute, plus de note-off (note collée). Candidat 0049a. Le mute lui-même est lu en temps réel (`LiveClipLevel`). |
| `createNodeForMidiClip` | Un clip en secondes passe par **MidiNode**. Les note-offs de clip supprimé en cours de lecture n'existent que pour LoopingMidiNode (`CombiningNode` 476-497). |
| Rendus : faders propres (4872-4994) | Confirmé pour le mode contenu. **Ajout** : les ancêtres sont désactivés dans `renderObjectToFileAsync` (4907-4909), donc rendre seul un clip vide perd l'instrument de l'hôte → silence. |
| « Patchs 0047/0048 non publiés » (récap) | **Périmé.** `objekat-patches-3.5` et `objekat-record-0048` sont à `3ce916aa05e` sur le fork. Le gitlink est bon, rien à rattraper. |
| Instance temporaire `editor` à retirer | Confirmé : devient inutile. |
| Enregistrement pris avant la piste cachée | Confirmé. FX sur la piste = écoute seule. |

Pièges supplémentaires trouvés (absents du brief) :

1. **Aux dans un groupe à instrument.** `createAuxReturns` somme le retour dans le container, l'instrument l'écrase. Un aux est donc interdit comme l'audio.
2. **FX externe sur un clip vide.** `ExternalPlugin` efface le buffer MIDI après traitement (1523-1537) : un FX peut manger les notes avant l'hôte. Griser ne suffit pas, il faut le désactiver côté moteur.
3. **Timestamps et sous-blocs.** `PluginNode` découpe en sous-blocs si le plugin demande de l'automation (259-260, 273) et ne remet pas les timestamps MIDI. Une courbe de volume sur un clip vide ou un sous-groupe peut avancer les notes. À prouver (P9).
4. **Note tenue à la sortie d'une fenêtre.** `ContainerClipNode` fait un early return hors plage : si une note enfant dépasse la borne, pas de note-off. À prouver (P4).
5. **Groupe sans enfant = pas de nœud** (`createNodeForContainerClip`, `clips.isEmpty`). L'instrument n'est pas préparé : l'ouverture de son éditeur retombe sur le piège Devil-Loc malgré `ensureContextAllocated` (`_doOpenEditorForKey`, 9555). Cas courant : zone neuve vide.
6. **Clones de rendu.** `state.createCopy()` (4584, 5226) copie aussi les pistes cachées. Avec des plugins dessus, chaque rendu les réinstancierait. Il faut les retirer du clone. En rendu direct sur l'Edit vivant, il faut prouver que l'entrée n'est pas imprimée.
7. **Queue d'instrument.** La fenêtre `ObjWindowFade` suit l'étendue : même un groupe infini coupe au dernier enfant. V1 : limite assumée et écrite, identique à un clip MIDI aujourd'hui.

---

## 2. Règles retenues

### 2.1 Sous-groupe (à valider)

> **Les notes d'un clip vide remontent jusqu'au premier groupe ancêtre qui porte un instrument. Sans ancêtre à instrument, elles sont muettes.**

C'est le comportement naturel du moteur, sans routage à écrire. Conséquences :

- Sous le groupe à instrument, tout le **sous-arbre** ne contient que des clips vides et des sous-groupes sans instrument.
- Le mute ou solo d'un sous-groupe coupe ses notes via le mute natif des clips.
- Le fader, le pan, les FX d'un sous-groupe sous hôte sont sans effet, donc grisés comme ceux d'un clip vide.
- Un groupe sans instrument peut contenir un sous-groupe à instrument à côté d'audio : ce sous-groupe rend de l'audio.

### 2.2 Refus

Unité pure `objekat/SoundObject/GroupInstrumentRule.swift`, seule source de la règle :

```swift
enum GroupInstrumentRefusal { case audioChild, auxChild, childWithInstrument, consolidatedChild, audioInput, insideInstrumentGroup }
GroupInstrumentRule.refusal(adding: [SoundObject], toChain: [SoundObject]) -> GroupInstrumentRefusal?  // chain = cible puis ses ancêtres
GroupInstrumentRule.refusal(puttingInstrumentOn: SoundObject, ancestors: [SoundObject]) -> GroupInstrumentRefusal?
GroupInstrumentRule.host(of:ancestors:) -> UUID?
GroupInstrumentRule.midiSilenced(...)
```

Refusé dans un groupe à instrument, à toute profondeur : clip audio, instance consolidée, aux, enfant avec instrument, sous-groupe qui en contient un, source audio d'enregistrement.
Refusé aussi : poser un instrument sur un groupe dont le sous-arbre contient l'un de ceux-là, ou **sous** un groupe qui a déjà un instrument.

Chaque raison a une clé i18n `groupInstrument.refused.*`. L'exposition passe par une seule fonction `refuseGroupInstrument(_:)` : `notify` (toast, journalisé en headless) plus `invalid_state` avec `details.reason` côté API.

### 2.3 Anciens projets : aucune gestion (décision utilisateur, 2026-10-30)

Il n'existe aucun projet avec enregistrement MIDI. Pas de migration, pas d'avertissement, pas d'instrument « dormant », pas de commande `instrument.activate`. Une prise dans un groupe à instrument est **toujours un clip vide**. Un fichier qui violerait quand même la règle n'est pas traité : la règle s'applique aux gestes et à l'API, pas à la lecture du fichier.

### 2.4 Mute

- Mute natif pour **tous** les clips vides. Un clip avec instrument garde son fader, comportement byte-identique.
- Silence MIDI effectif : `isSilenced(clip)` OU un groupe entre le clip et l'hôte exclu est silencé (hors `soloRootAncestors`).
- Partout où un fader est forcé dans un clone, la propriété mute du `te::MidiClip` l'est aussi.

### 2.5 FX et mix d'un clip vide

- Volume, pan, fades, FX, envois grisés dans l'UI. Pas de conversion en vélocité.
- FX d'un clip vide, et d'un sous-groupe sous hôte : compilés mais **désactivés côté moteur** (état poussé `p.isEnabled && !passif`). Le modèle garde le choix de l'utilisateur.

### 2.6 Persistance des entrées

Nouvelle clé sœur `ProjectDocument.inputChains`, fichier `objekat/SoundObject/InputChains.swift`. Pas dans `RecordInputsConfig` : cette unité reste Foundation pure, compilée seule par `tools/test_record_inputs_codable.swift`.

```swift
struct InputChain: Codable, Equatable { var hostID: UUID; var plugins: [ObjectPlugin] }
struct MidiInputChain: Codable, Equatable { var hostID: UUID; var input: MidiInputRef; var instrument: ObjectPlugin? }
struct InputChains: Codable, Equatable {
    var audio: [String: InputChain]      // par InputRef.key, comme les noms
    var midi: [String: MidiInputChain]   // par id, résolu par MidiInputResolver à la lecture
}
```

| Cas | Comportement |
|---|---|
| Changement d'onglet | Capture des états dans `projectDocument`, chaînes démontées puis remontées par `applyProjectDocument*`. Consigne plugin réutilisée (`insertResolvedPlugin`). |
| État d'écoute | Non sauvé, reste moteur et survit au changement d'onglet (inchangé). L'entrée entendue prend la chaîne du projet actif. |
| Carte qui change | `syncInputChains` depuis `syncInputMonitors`. Clés par numéro de canal, comme les noms. |
| Entrée disparue | Chaîne gardée, dormante. Revient si l'entrée revient. |
| Paire défaite | Chaîne gardée sous sa clé `"1-2"`, comme les noms. Repaire = retrouvée. |
| Entrée MIDI ailleurs | Résolue par id puis nom unique, sinon dormante. |
| Coût | **Montage paresseux** : une chaîne n'est instanciée que si l'entrée est entendue ou la chaîne ouverte. Un projet avec cinq instruments d'entrée ne les charge pas. |
| Undo | Dans le snapshot, comme les stems (`EditViewModel+UndoRedo.swift:181`). |

---

## 3. Étapes (chacune compile, un commit par étape)

Chaque étape : build Debug sans nouveau warning, plus les tests indiqués. `git add` ciblé uniquement : ne jamais inclure `Resources/InfoPlist.xcstrings` ni les docs non suivis.

### E0. Preuve moteur

Aucun code de production.

- `objekat/CommandAPI/Commands+Debug*` (famille `debug.*` existante, `#if DEBUG`) : `debug.mount_instrument {id, ...}` appelle directement `engine.setInstrument`, `debug.midi_mute {id, muted}` idem.
- `objekat/OBJEngineCore.{h,mm}` : `setMidiClipMuted:forID:` (`_midiClipMap[key]->setMuted`) et sa relecture.
- `tools/scenario_group_midi_proof.py` : cas P1 à P13 (section 5).

Sortie : tableau de verdict dans le message de commit. L'architecte relit avant E1.

### E1. Patch moteur 0049 (si prouvé)

`tracktion_engine/`, branche `objekat-group-midi-0049` depuis `3ce916aa05e`. Contenu possible, chaque point seulement si son test échoue :

- (a) `MidiNode`, `LoopingMidiNode` : remettre `wasMute` à false au démute.
- (b) `ContainerClipNode` : note-off à la sortie de fenêtre, au dernier bloc actif.
- (c) `PluginNode` : remettre les timestamps MIDI après sous-blocs.
- (d) `createNodeForContainerClip` : si besoin, garder un nœud pour un container vide à plugins. Alternative hors moteur en E4.

Livrables : `engine-patches/3.5/0049-*.patch`, `tools/rebuild-engine.sh`, `tools/publish-engine-forks.sh`, gitlink réaligné, commit dédié du gitlink. La publication est un push sur le fork : la faire valider par l'utilisateur. Relancer P1-P13.

### E2. Règle pure

- `objekat/SoundObject/GroupInstrumentRule.swift`, `tools/test_group_instrument_rule.swift`.
- Pas de câblage. Couvre tous les refus, la profondeur, `host`, `midiSilenced`.

### E3. Mute natif et silence effectif

- `EditViewModel+Audibility.swift` : `pushMix`, `pushMixTree`, `applyAudibilityToEngine` poussent `setMidiClipMuted` pour les clips vides. Tout changement de silence d'un groupe doit descendre l'arbre.
- `OBJEngineCore.mm` : `OBJForcedFader` (4873-4895, 4976-5001) porte aussi le mute natif, avec l'id de `_midiClipMap` et non celui du container.
- Rechargement : pousser l'état après création du clip, `engine.addMidiClip` compris.
- Vérifier que `setMuted` ne reconstruit pas le graphe et n'ouvre pas de transaction parasite (`Edit.cpp:140`).
- Test : `scenario_midi_mute.py` (M1-M6).
- Écart constaté (E3) : M1-M5 passent (mute natif == suppression du clip, bit à bit, 0 reconstruction de graphe). M6 (rendu contenu d'un groupe consolidé, solo vivant ignoré) ne peut pas tourner avant E4/E6 : l'instrument de groupe n'est qu'un montage debug sur le container vivant, le sidecar n'a aucun plugin et le re-bake de l'ouverture échoue. Le scénario l'affiche SKIP ; à rejouer à E6. Le premier `consolidate.make` (renderGroup, état vivant) n'écarte pas un solo vivant : comportement préexistant pour tous les clips, hors périmètre.

### E4. Instrument monté sur le container, fin de l'écoute auto, prises vides, format 36

Commit unique, car ces changements ne tiennent pas séparément : monter l'instrument sans retirer celui de la piste cachée ferait double son.

- `EditViewModel+Plugins.swift` : retirer la garde :389. `setInstrument`, `removeInstrument` suivent le chemin commun, branches `canHaveZoneInstrument` retirées (:418, :429).
- `EditViewModel+Groups.swift` : `syncAddGroup` appelle `syncInstruments` avant la chaîne (:104).
- `EditViewModel+RecordMidi.swift` :
  - supprimer `keepZoneInstrumentState`, `openZoneInstrumentEditor`, `releaseZoneInstrumentEditor`, `setZoneInstrument`, `removeZoneInstrument`, `editingMidiZoneIDs`, `activeMidiZoneIDs`.
  - `syncMidiZones` n'envoie que `{zone, device}`.
  - `midiTakeObject` : prise toujours vide quand le groupe porte un instrument (l'instrument n'est plus jamais copié dans une prise).
- `OBJEngineCore.mm` : `struct OBJMidiZoneTrack`, `setMidiZones`, `syncMidiZoneMonitors`, `dropMidiZoneInstrument` sans instrument. Piste cachée gardée pour capter, monitor `off` si la capture le permet, sinon `on` sans instrument (qui est muet).
- `_doOpenEditorForKey` : préparer le plugin d'un container sans nœud (voir piège 5).
- `EditViewModel+UndoRedo.swift` : garder le retrait de `instruments` de la comparaison de groupe (:332), mais pousser le delta dans `pushPatch` : pas de reconstruction de tout le groupe pour un état d'instrument.
- `EditViewModel+RecordZones.swift` : `applyRecordSource` n'efface plus l'instrument à la perte de la source (:168).
- `CommandAPI/Commands+Plugins.swift:1468` : `instrument.set`, `instrument.remove` sur tout groupe. `object.get` : `instrument_state`, `instrument_host`, `engine_midi_muted`.
- `CommandAPI/Commands+RecordMidi.swift` : `zones[].live` requalifié.
- `SessionSchema.swift` : format 36, notice `zoneInstruments` réécrite (:292). Clé disque inchangée. Scénarios qui figent le format mis à jour (`scenario_markers`, `scenario_families`, `scenario_input_monitor`, etc. : `grep`).
- `tools/scenario_midi_record.py` : adapter les lignes 275, 324, 507.
- Vérifier l'absence d'écoute d'objet côté audio : déjà le cas (armement = monitor `off`), à garder par test.

### E5. Portes de refus

Une garde dans la primitive quand elle existe (`addChild`, `canAccept…`), sinon à l'entrée du geste, **avant** `pushUndo` :

- Grouper : `createGroupFromTimeSelection`, `createGroup(from:)`, `createGroupFromSelection`, `createGroup(from:in:)`, `makeSubgroup`.
- Déplacer : `reparentToGroup`, `reparentChildBetweenGroups`, `altReparentChildBetweenGroups`, `altCopyChildrenInGroup`, `EditViewModel+MoveDrop`.
- Coller : `paste`, `pastePlacement`, `duplicateSelected`, `pasteCrossProjectPlan` (`CrossProjectImport` plan refusé en bloc).
- Insérer : `FolderImport`, `placeClip`, `sessionDropTarget`, drop audio/fichier, aux créé dans un groupe, `Consolidate` (instance posée dans un hôte).
- Instrument : `transferInstrument` (:470-506), `recordSourceRefused` (`rec.assign`, `rec.drop`).
- `Bake`, `Explode`, `disbandGroup` : dissoudre un hôte dans un hôte parent reste impossible par la règle ; dissoudre un hôte à la racine rend ses clips muets, comportement cohérent, sans refus.
- Rappel : une porte acceptée partiellement (multi-sélection) refuse **tout le geste**, pas seulement les éléments fautifs.

Test : `scenario_group_instrument_doors.py` (D1-D16).

**Réalisé (E5) et écarts au plan.**

- Une seule règle (`GroupInstrumentRule`), une seule porte d'entrée côté vue-modèle (`EditViewModel+GroupInstrument.swift` : `refusesAdding`, `refusesPlacing`, `refusesInstrument`, `refusesAudioInput`, `refusesDropEntries`). Un refus note l'événement (`groupInstrumentRefusal`), prévient (`notify`, journalisé en headless) et rend la main **sans avoir rien touché**.
- Côté API, `CommandRegistry.execute` est enveloppé : tout geste qui a été refusé répond `invalid_state` avec `details.reason` (nom du refus), même quand le handler se plaignait d'autre chose après coup (`instrument.set` ne trouvant pas d'instrument). Le bus `.bus` retire le point d'undo comme pour tout geste sans effet ; `edit { }` fait de même quand un refus a eu lieu et que `items` n'a pas bougé.
- Portes posées : `reparentToGroup`, `reparentChildBetweenGroups`, `altCopyChildrenInGroup`, pré-contrôle de `commitMoveDrop` (avant `pushUndo`, couvre le glisser et le ⌥-glisser entre groupes), `paste`, `pasteCrossProjectPlan` (avant tout enregistrement de définitions/FX link), `moveTranslatedItems`, `placeTranslatedFragments`, `createAuxFromTimeSelection`, `placeDropEntries` (+ contrôle avant le `pushUndo` du drop), `object.add`, `setInstrument`, `transferInstrument`, `assignRecordSource`, `dropRecordSources`.
- **Pas de porte, et pourquoi** : grouper (les quatre `createGroup*`, `makeSubgroup`) ne change jamais de conteneur : le nouveau groupe naît dans le conteneur de ses membres, ou à la racine s'ils y sont. `duplicateSelected` duplique dans le conteneur d'origine : un contenu déjà valide le reste. Création d'un clip MIDI (un clip vide est bienvenu), prises, `GroupHeal`, coupe, `disbandGroup` : idem. `Bake`/`Explode` n'entrent pas dans un groupe.
- Le ⌥-glisser d'un objet de la **racine** vers une ligne de groupe ne fait jamais entrer la copie dans le groupe (elle atterrit à la racine : comportement existant, non modifié) ; le chemin qui entre est celui depuis un autre groupe, testé en D18.
- Test : `scenario_group_instrument_doors.py`, 87 assertions : D1-D13 + D15 + D17 (glisser) + D18 (⌥-glisser depuis un autre groupe), contrôles D14 (un clip vide entre, UN point d'undo, undo le rend) et D16 (groupe à instrument dans un groupe ordinaire). Non couvert faute de porte scriptable : l'import de dossier par le Finder (même fonction `placeDropEntries`, testée par construction), le cross-paste d'onglets (même `refusesAdding(targets:)`).
- i18n : 7 clés (`groupInstrument.refused.title` + 6 raisons) en fr/en/es ; formulations provisoires, à relire.

### E6. Rendus et consolidation

- `renderObjectToFileAsync` : garder l'instrument de l'hôte actif dans le clone quand on rend un clip vide ou un sous-groupe.
- `EditViewModel+ConsolidateGuards.swift` : refuser de consolider un clip vide ou un sous-groupe sous hôte (le wave violerait la règle).
- Consolider un groupe à instrument : instrument cuit dans le contenu, restauré à l'ouverture. Vérifier `freshPlugins` et `freshInstruments` dans `EditViewModel+Bake.swift`.
- `CrossProjectImport`, `copiedInstruments` : instruments de groupe copiés avec ids neufs.

**Réalisé (E6) et écarts au plan.**

- `renderChainForKey` repère l'instrument de l'hôte (premier ancêtre qui en porte un, via `_instrumentMap`) ; le clone de `renderObjectToFileAsync` rend transparents les ancêtres **sauf** cet instrument. Testé : `object.render_isolated` d'un clip vide et d'un sous-groupe rend les notes de l'hôte (M8).
- Consolidation : `refusesConsolidating` (raison `consolidatedChild`) refuse un clip vide ou un sous-groupe sous un hôte, dans `consolidate(groupID:)`, `consolidateClip`, la commande `consolidate.make` (avant la création du job) ; `consolidateTargets` les écarte (le menu ne les propose pas).
- Consolider un groupe à instrument : rien à changer. Le sidecar (`contentRoot`, `capturedPluginStates`) porte déjà `instruments` (clé `zoneInstruments` pour un groupe), l'instance n'en porte pas, l'ouverture rematérialise la racine avec son instrument et le re-bake le rejoue : M6, réactivé, passe (A audible malgré un solo vivant ailleurs, B mute du modèle). Seule retouche de test : le plancher de queue `TAIL` pour le silence de B (la réverbération du DLS survit entre deux rendus d'une même instance).
- `freshPlugins` (`EditViewModel+Bake`) et `CrossProjectImport.cloneObject` copiaient déjà les instruments de tout objet avec ids neufs. **Trouvé en route** : `derivedCopy` a `instruments: []` par défaut, donc la copie / le collage / la coupe d'un GROUPE perdait son instrument. Ajouté `instruments: copiedInstruments(of:)` aux six sites de groupe (`makeCopy`, fragment de zone de temps, coupe d'un sous-groupe, coupe à fenêtre, moitiés gauche et droite d'un groupe) ; testé pour la copie (M8, duplication d'un hôte : ses clips sont hébergés par la copie).

### E7. UI des groupes

- `Inspector/Synoptic/SynopticBoundView.swift` (:83, :255, :353, :356) : carte instrument pour tous les groupes éligibles, via le slot existant du clip MIDI.
- `SynopticLayout.swift`, `SynopticActions.swift` : groupe mixte = slot grisé avec la raison en tooltip.
- `Inspector/Synoptic/SynopticBoundView.swift` (:150) : **les actions d'instrument quittent le bloc Entrée** (Choisir / Ouvrir / Retirer) au profit de cette carte. Une seule porte. Divergence mineure à valider.
- Griser : `mix`, FX, envois, fades du clip vide ; `Timeline` : poignées de fade, outils Volume/Pan. Un indicateur « joué par : <groupe> » remplace le mix dans le synoptique.
- `syncPlugins` : état moteur `enabled` selon 2.5. Tout changement d'hôte resynchronise les sous-groupes.
- Triangle orange d'une zone sans instrument : `host == nil`.
- i18n + `tools/i18n/xcstrings.py check`, `orphans`.

**Réalisé (E7) et écarts au plan.**

- **Carte d'instrument d'un groupe** : le slot du clip MIDI sert aussi aux groupes (hors instance consolidée). `isMIDI` de `SynopticView` signifie désormais « le chef de chaîne est une zone d'instrument ». Un groupe où l'instrument est refusé garde le « + » grisé, la raison de `GroupInstrumentRule` en infobulle (`instrumentSlotRefusalText`).
- **Écart visible, à valider** : pour un groupe, la zone d'instrument REMPLACE la tête de bus (pastille « Source »). L'option « infini » y est reprise en icône `∞` à côté de la boucle (même position que la boucle d'un clip MIDI) ; la liste des envois reçus n'existe que pour un aux, inchangé. Un sous-groupe non éligible à l'infini n'a que la boucle.
- **Bloc Entrée** : le menu d'instrument (Choisir / Ouvrir / Retirer) est supprimé, la hauteur supplémentaire de la zone d'entrée MIDI (`inputZoneMidiExtra`) aussi ; une seule porte, la carte. 5 clés i18n retirées (`synoptic.input.instrument.{choose,edit,help,none,remove}`). La clé `warning` est gardée : triangle orange sur le « + » d'une zone d'enregistrement MIDI sans instrument.
- **Clip vide** : la zone mix remplace volume et pan par « joué par : <hôte> » (orange « aucun instrument » si `host == nil`), mute et solo restent ; la chaîne FX est grisée (opacité) dans le synoptique. 4 clés i18n neuves (`synoptic.mix.playedBy*`, `synoptic.mix.noInstrument*`).
- **Passivité moteur (2.5, P11)** : `compileRack` pousse `enabled && !passif` (`isChainPassive` : clip vide, ou sous-groupe sans instrument sous un hôte). Les bascules à chaud (`togglePluginEnabled`, bascule groupée, sortie de bac FX link) passent par `engineEnabled(_:onHost:)`, sinon un clic réveillerait un FX passif. Le recalcul suit : pose / retrait / transfert d'un instrument, undo/redo (`applySnapshot`) ; un déplacement de groupe reconstruit l'objet, donc le calcul à la volée suffit (testé, U7). Le chargement compile à la volée (aucune passe en plus : la remontée d'ancêtres n'est payée que par une chaîne non vide).
- **Timeline** : un clip vide n'a plus de zone de fondu (`ClipEditZone.resolve(hasFades:)` : le haut des poignées devient sélection de temps), et les outils Volume / Pan l'ignorent (survol, glissé, aperçu Canvas). **Non fait** : les fondus déjà posés restent dessinés (triangle gris), aucun grisé visuel des blocs ; les portes machine (`object.set_volume`, etc.) restent exactes.
- Test : `tools/scenario_group_ui.py`, 17 assertions (U1-U7).
- E4, écarts rattrapés ici : section J de `scenario_midi_record` abandonnée ; `instrument.set` accepte tout groupe éligible ; `object.get` d'un clip MIDI ajoute `instrument_state`, `instrument_host`, `engine_midi_muted`.

### E8. Moteur des entrées

`OBJEngineCore.{h,mm}`, section Input monitoring :

- **Audio** : `userPluginListForKey:` résout un `hostID` d'entrée vers la piste cachée. Ordre `[FX…, ObjGain écoute]`. Isoler dans `applyInputChain:toTrack:` pour faciliter le merge low-lat (section 4).
- **MIDI** : `struct OBJMidiInputTrack {track, deviceID, instrument}`, `_midiInputTracks`, `_monitoredMidiInputs`. `setMidiInputChains:`, `setMidiInputMonitor:device:`, `syncMidiInputMonitors` idempotent, appelé par `midiDevicesChanged`.
- Le device a un `MonitorMode` global : `on` si entendu. Cibles multiples sans `move` (zone + entrée). Interaction à tester : I5, I6.
- Hors `_poolTracks`, census, solo, stems.
- **Clones** : retirer pistes d'entrée et de zone (`stripHiddenTracksFromRenderClone`, 4584, 5226).
- Rendu direct : s'assurer qu'aucune entrée n'est imprimée.

**Réalisé (E8)** : moteur seul, rien d'exposé au modèle (E9). Divergences :
- Les méthodes sont `registerAudioInputHost:first:count:`, `registerMidiInputHost:device:`, `unregisterInputHost:`, `inputHostIsLive:`, `setMidiInputMonitor:device:`, `midiInputMonitors` (et non `setMidiInputChains:`) : un hôte est un id enregistré par Swift, qui le monte seulement tant qu'il est entendu ou ouvert (montage paresseux). La résolution passe par `userPluginListForKey:` (`_audioInputHosts`, `_midiInputTracks`), donc `addPlugin` / `compileUserRack` / `setInstrument` marchent tels quels sur un hôte.
- `stripHiddenTracksFromRenderCopy:` retire pistes d'entrée audio, de zone MIDI et d'entrée MIDI de l'état copié, aux DEUX sites de `createCopy()` (rendu direct et export) ; testé seulement de façon indirecte (I10 reste à faire avec le modèle).
- Porte de debug `debug.input_host` (DEBUG) et `tools/scenario_input_chains.py` (19 assertions, I1-I5 côté moteur : FX monté et entendu, désenregistrement, hôte dormant entrée fermée, instrument MIDI entendu seulement en écoute, refus sans instrument).
- Piège de test : DLSMusicDevice avale la PREMIÈRE note après instanciation (chargement de la banque) ; le scénario amorce avec une note. Pas un défaut de l'hôte.
- Non traité ici : I2 (enregistrement avec FX), I5/I6 (zone armée sur le même device), I7 (carte qui change), qui demandent le modèle ou l'enregistrement.

### E9. Modèle des entrées, persistance, API

- `SoundObject/InputChains.swift`, `tools/test_input_chains_codable.swift`.
- `EditViewModel+Plugins.swift:85,95` : `chainPlugins`, `updateChainPlugins` troisième cas d'hôte ; `leafPlugins`, `hostedPlugin`, `allPluginRefs`.
- `EditViewModel+Project.swift` : `projectDocument` capture les états ; `inputChainsWithCapturedPluginStates()`.
- `EditViewModel+UndoRedo.swift` : snapshot, restauration comme les stems.
- `EditViewModel+Tabs.swift` : `closeAllPluginEditors` (:107) couvre les hôtes d'entrée, démontage au park, remontage à la restauration.
- `SessionSchema.swift` : notice `inputChains`.
- API `Commands+Record.swift`, `Commands+RecordMidi.swift` :
  - `input.host {input|midi}` : rend le `hostID`, puis `plugin.*` marche sans nouvelle famille.
  - `input.set_instrument`, `input.remove_instrument {midi, ...}`.
  - `input.monitor {midi:…}`, refusé sans instrument.
  - `input.list` : `host_id`, `fx_count` ; `input.list.midi_inputs` : `heard`, `instrument`, `dormant`.
  - `rec.drop` : `inherited`.

**Réalisé (E9)** : modèle, persistance, undo, onglets et API. Divergences :
- **Pas de montée de format** : `inputChains` est une clé OPTIONNELLE du format 36 (notice ajoutée à `SessionSchema`), lisible et ignorée par un build antérieur. Lecture indulgente : une chaîne illisible est écartée seule, une section de mauvais type devient vide.
- `ProjectDocument.inputChains` ; `EditViewModel+InputChains.swift` (nouveau) porte tout : `inputChains`, `openInputHosts`, `mountedInputHosts`, `syncInputChains()` (montage paresseux : monté tant qu'il est entendu ou ouvert, sinon démonté après capture des états dans le modèle), `setInputChains` (porte de chargement, appelée aussi par la remise à zéro d'un nouveau projet), `restoreInputChains` (undo : états patchés sans reconstruire si seuls les états diffèrent), `setMidiInputMonitor`. `applyInputChain:toTrack:` n'a PAS été créé : le gain d'écoute reste en ligne dans `syncInputMonitors`.
- API : `input.host {first|midi, open?}` rend `host_id` et monte/démonte ; `plugin.*` marche sur ce `host` et un hôte audio ouvert par `compileRack`/`plugin.*` reste ouvert jusqu'à `input.host {open:false}`. Instruments MIDI : uniquement via `input.set_instrument` / `input.remove_instrument` (`plugin.*` sur un hôte MIDI ne fait que lister / `hostedPlugin`). `input.monitor {midi}` : `invalid_state` sans instrument, `bad_params` pour un non-instrument. `input.list` : `host_id`, `fx_count` ; `input.list.midi_inputs` : `heard`, `instrument`, `host_id`.
- Piège trouvé par le test : l'Edit du moteur survit au projet. Un nouveau projet laissait donc l'écoute MIDI de l'ancien (`_monitoredMidiInputs`) et ses chaînes ; `setInputChains` coupe maintenant toute écoute MIDI et le nouveau projet appelle `setInputChains(InputChains())`.
- Tests : `tools/scenario_input_chains.py` (58 assertions : I1-I6 moteur + M1-M6 via l'API : FX montés / listés, enregistrement non coloré (RMS à 0,1 dB), démontage fermé et non entendu, remontage avec l'état, sauvegarde / réouverture (non monté tant que rien n'est entendu), undo / redo, nouveau projet, instrument MIDI : refus, un point d'undo, écoute, retrait, undo) et `tools/test_input_chains_codable.swift` (12).
- Non traité ici : I7 (carte qui change) et I10 (clone de rendu) restent indirects.

### E10. UI Entrées

- `Inputs/InputsPanelView.swift`, ligne audio : petit bouton « FX » avec compteur, à gauche du haut-parleur. Clic : popover avec `SynopticBoundView` sur le `hostID`, comme le stem (`App/StemStripsToolbarView.swift:641`). Clic droit : mêmes entrées.
- `Inputs/MidiInputsSection.swift`, ligne MIDI : bouton nom de l'instrument (ou « Instrument »). Sans instrument : picker. Avec : ouvre l'éditeur. Clic droit : Changer, Retirer. Haut-parleur à droite, grisé sans instrument. Commentaire d'en-tête réécrit (:14).
- `SynopticBoundView.swift:637` : extraire `pickerSheet` en vue réutilisable (filtre `isInstrument`).
- Dormant : ligne grisée. i18n fr/en/es.

**Réalisé (E10)** : interface de l'onglet Entrées. Divergences et précisions :
- Ligne audio : bouton « FX » (compteur « FX 2 » en accent quand la chaîne n'est pas vide) à gauche du haut-parleur (`Inputs/InputFXButton.swift`). Le clic crée l'hôte si besoin, le MAINTIENT monté (`openInputHost`) et ouvre un popover portant `SynopticBoundView` sur l'id de l'hôte, comme un stem (300 x 360) ; la fermeture du popover le relâche. Pas de clic droit « mêmes entrées » sur le bouton : le menu contextuel de la ligne (appairer / séparer) est resté tel quel.
- **Écart de fond : un éditeur de plugin tient la chaîne montée.** Fermer le popover démontait la chaîne (rien n'est entendu) et fermait donc la fenêtre d'éditeur ouverte depuis une carte. `togglePluginEditor` / `openPluginEditors` appellent `holdInputHost(_:forEditorOf:)` (table plugin vers hôte, `editorHeldInputHosts`), `wantedInputHosts` y ajoute les hôtes qui ont un éditeur ouvert, et la fermeture d'un éditeur (natif : `onEditorVisibilityChanged` ; intégré : rappel du contrôleur) déclenche `editorDidClose(plugin:)` puis `syncInputChains()` différé.
- Ligne MIDI (`MidiInputsSection`) : bouton nom de l'instrument (« Instrument » en bordure orange tant qu'il n'y en a pas) : sans instrument il ouvre le sélecteur, avec il ouvre / ferme l'éditeur de l'instrument ; clic droit : choisir / changer, retirer. Haut-parleur à droite, grisé et inerte sans instrument. En-tête de la section réécrit.
- Sélecteur extrait : `Inspector/Synoptic/PluginPickerSheet.swift` (le `pickerSheet` de `SynopticBoundView` l'appelle maintenant), réutilisé par le bouton d'instrument.
- Dormant : une chaîne MIDI dont le périphérique est absent reste une ligne grisée (nom retenu, nom de l'instrument, clic droit « Retirer l'instrument ») ; une chaîne audio dont l'entrée n'est plus listée (carte plus petite, paire défaite) apparaît dans une section « Entrées absentes » (clic droit « Retirer les effets »). Nouvelles fonctions : `removeInputInstrument(chainKey:)`, `clearAudioInputChain(key:)` (un point d'undo chacune).
- i18n : 13 clés `inputs.*` en fr/en/es (`check` propre, `orphans` inchangé : 3 orphelines antérieures). Le libellé « FX » est littéral.
- **Non vu à l'écran** : aucun pixel de cette étape (popover, bouton, boutons d'instrument, lignes grisées). Aucun scénario ne peut ouvrir un popover ni une fenêtre d'éditeur en headless (`holdInputHost` est inerte sans interface) ; les E9 couvrent le modèle et le montage.

### E11. Héritage

- `EditViewModel+RecordZones.swift`, `dropRecordSources` (:301), cas `.create` : copie de l'instrument de l'entrée MIDI, ou des FX de l'entrée audio, ids neufs, état vivant, sans lien. Le cas `.assign` ne touche à rien.
- Une entrée non montée : copie depuis le `stateXML` du modèle.
- Test : `scenario_input_chains.py` H1-H6.

**Réalisé (E11)** : héritage à la création d'une zone. Précisions et écarts :
- `dropRecordSources`, cas `.create` : `inheritedChain(for:)` (dans `EditViewModel+InputChains.swift`) rend la copie de la chaîne d'une entrée audio (posée dans `zone.plugins` AVANT `placeClip`, l'ajout compile la chaîne comme pour un collage) ou de l'instrument d'une entrée MIDI (posé APRÈS le placement, parce que `refusesInstrument(on:)` a besoin de la zone en place ; un refus ne retire pas la zone, elle naît sans instrument et l'alerte habituelle de la règle des groupes à instrument est donnée). Le cas `.assign` ne touche à rien.
- Copie indépendante : ids neufs, `linkGroupID` / `detachedLinkGroupID` effacés, état vivant si la chaîne est montée et état du modèle sinon (`capturingPluginStates` fait déjà les deux). **Écart** : un bac FX link (`fxBlock`) présent dans la chaîne d'une entrée est copié comme ses plugins à plat, donc détaché (le plan disait « sans lien » sans traiter ce cas).
- API : `rec.drop` répond `inherited` {fx, instrument} pour une zone créée qui a pris quelque chose (`EditViewModel.lastDropInheritance`, remis à zéro à chaque dépôt, lu par la commande) ; absent sinon.
- Tests : `scenario_input_chains.py` H1-H6 (80 assertions en tout), plus `scenario_record_multi_drop` (43) et `scenario_record_zones` (85) relancés puisque le chemin `rec.drop` a changé : verts.

### E12. Docs et clôture

- `OBJEKAT - claude project/docs/command_api.md`, `glossary.md` (clip vide, instrument de groupe, chaîne d'entrée), `architecture_decisions.md`.
- `CLAUDE.md` sections MIDI (2877-2900, 2926).
- `docs/recap` non touché. Retirer `debug.mount_instrument` si plus utile.

**Réalisé (E12)** : documentation et clôture. `command_api.md` (chaînes d'entrée, instruments de groupe, portes de debug), `glossary.md` (clip vide, instrument de groupe, chaîne d'entrée, hôte), `architecture_decisions.md` (règle de groupe, montage paresseux, héritage par copie) et `CLAUDE.md` (paragraphe « MIDI groups and input chains » ; les phrases périmées sur l'instrument de zone joué sur piste cachée, l'instance d'éditeur temporaire et la copie de l'instrument dans chaque prise sont corrigées ; prochain numéro de patch moteur : 0050). Écart : `debug.mount_instrument` est CONSERVÉ (encore utilisé par `scenario_group_midi_proof.py` et `scenario_midi_mute.py`). `docs/recap_nuit_2026-10-30.md` non touché. Aucune chaîne visible ajoutée (i18n inchangé). Rien poussé ; le gitlink de `main` pointe sur le commit moteur local `f0648743dc2` (branche `objekat-group-midi-0049`).

---

## 4. Conséquences pour `feat/low-latency-monitoring`

La branche réécrit `syncInputMonitors` : toute entrée entendue passe par `MonitorMixer` dans le callback de la carte, et la piste cachée ne sert plus qu'aux entrées armées, monitor `off` (lu dans `../objekat-lowlat`, `OBJEngineCore.mm:11425-11560`). **C est incompatible avec ce chemin pour toute entrée à chaîne** : un AU/VST ne se calcule pas dans ce callback.

Le merge doit donc créer **deux chemins** :

| Entrée | Chemin | Latence | FX/volume de Main |
|---|---|---|---|
| Audio sans FX | `MonitorMixer` | matérielle seule | non |
| Audio avec FX | piste cachée, monitor `on` | session + file | **oui** |
| MIDI + instrument | piste cachée, monitor `on` | session + file | **oui** |

Points précis :

1. `buildMonitorGains` ne reçoit que les entrées sans chaîne. Les autres gardent leur piste cachée.
2. `wanted = _armedInputs` devient armées ∪ entendues à chaîne. Le `setMonitorMode(off)` inconditionnel et le `automatic` de la boucle de fin deviennent des décisions par entrée.
3. Le geste d'ajouter un FX change de chemin en cours d'écoute : petit trou, et la latence saute.
4. **En mode file, c'est pire qu'aujourd'hui** : la session calcule en avance avec un pré-remplissage de 2S, donc écoute à chaîne = S + file, et le jeu au clavier MIDI, le cas le plus sensible, subit toute cette latence. Le bénéfice de la branche ne concerne que les entrées brutes.
5. Incohérence audible à trancher avant merge : une entrée avec FX passe par les FX et le volume de Main, pas une entrée sans FX. Option : sortir les pistes d'écoute avant Main (bus dédié).
6. Calculer les chaînes dans un mini-graphe à H, sur thread dédié, serait une autre étape, lourde.

Préparation dès ce plan : `applyInputChain:toTrack:` isolée, et décision « entendu par quel chemin » dans une seule fonction. `scenario_low_latency.py` et `scenario_input_monitor.py` devront couvrir les deux chemins. Conflit de merge certain sur `syncInputMonitors`, `OBJEngineCore.h`, `Commands+Record.swift`, `Localizable.xcstrings`, `command_api.md`.

---

## 5. Plan de test

Commun : headless `--no-recent --language=en`, build fraîche, instance propre par scénario, `--virtual-audio`/`--virtual-midi` selon le cas, aucune fenêtre (`CGWindowListCopyWindowInfo`), export relu en 24 bits. Instrument : `DLSMusicDevice` comme `scenario_midi_record`.

### 5.1 Preuve moteur (`scenario_group_midi_proof.py`)

| Id | Cas | Preuve |
|---|---|---|
| P1 | Groupe à instrument + clip vide | RMS export > seuil. Témoin sans instrument = 0. |
| P2 | Deux niveaux : hôte > sous-groupe > clip vide | RMS, onset identique à P1 à ±1 bloc. |
| P3 | Clip avec instrument seul | Référence : export identique à avant. |
| P4 | Note dépassant la borne du groupe, puis lecture continue | Énergie nulle après la fin de fenêtre + release ; réentrée sans note collée. |
| P5 | Boucle de groupe | Autant d'attaques que de tours, ni collée ni doublée. |
| P6 | Boucle de transport | Idem, lecture en temps réel, niveau de sortie. |
| P7 | Saut de lecture pendant une note | Plus de note après le saut (`isAllNotesOff`). |
| P8 | PDC : hôte + plugin à latence (AUPeakLimiter ou autre latence non nulle, à vérifier via le plugin) à côté d'un clip audio de référence | Onset aligné à ±1 bloc. |
| P9 | Courbe de volume sur clip vide et sur sous-groupe | Onset inchangé par rapport à P1 (timestamps). |
| P10 | Double déclenchement : deux clips vides mêmes notes vs un seul | Niveau cohérent, un clip vide jamais joué deux fois. |
| P11 | FX externe sur clip vide, activé / désactivé | Montre la perte éventuelle de notes, justifie 2.5. |
| P12 | Mute, démute, mute pendant une note en lecture | Pas de note collée au 2e mute (`wasMute`). |
| P13 | Instrument sur groupe vide, ajout d'un clip ensuite | Son à l'export. |

### 5.2 Mute (`scenario_midi_mute.py`)

M1 mute d'une prise vide → RMS 0, autres prises inchangées. M2 solo d'un clip vide → seul entendu. M3 solo d'un autre objet → silence du clip vide. M4 mute d'un sous-groupe et de l'hôte. M5 stem muet. M6 rendu contenu d'un groupe avec solo vivant actif → le fichier ignore le solo, respecte le mute modèle. Plus : compter les reconstructions de graphe pendant un mute, attendu 0.

### 5.3 Portes (`scenario_group_instrument_doors.py`)

D1-D16 : glisser, coller, dupliquer, grouper, sous-grouper, ⌥-copier, importer, cross-paste, aux, instance consolidée, source audio, instrument sur groupe mixte, instrument sous hôte, instrument glissé d'un clip, transfert de sous-groupe, sélection mixte. Pour chacun : `invalid_state` + `details.reason`, modèle **inchangé**, pile d'undo inchangée, notification journalisée.

### 5.4 Enregistrement et écoute

- `scenario_midi_record.py` adapté : armé = **silence** sur le master ; prise avec instrument de groupe = clip vide, 1 undo, audible à l'export ; mode mute et mode ajout ; zone sans instrument .
- Sous-groupe zone sous un hôte.
- Audio : armer n'est pas entendre, assertion conservée dans `scenario_record.py`.

### 5.5 Entrées (`scenario_input_chains.py`, sur cartes virtuelles)

| Id | Cas | Preuve |
|---|---|---|
| I1 | FX AULowpass 100 Hz sur une entrée 2 kHz | Niveau master chute d'au moins 20 dB. |
| I2 | Enregistrer avec ce FX | **RMS du fichier = sans FX, à ±0,1 dB.** |
| I3 | Entrée MIDI + instrument + écoute | Note virtuelle entendue. Sans écoute : silence. |
| I4 | Solo ailleurs, stem muet | Entrées toujours entendues. |
| I5 | Entrée entendue + zone armée, même device | Entendue une fois, prise correcte, pas de double. |
| I6 | Écoute coupée pendant l'enregistrement | Prise intacte. |
| I7 | `scenario` carte qui change, entrée disparue, paire défaite puis refaite, MIDI débranché (`midi.virtual`) | Chaîne gardée, dormante, retrouvée, sans crash. |
| I8 | Onglets : A avec chaîne, B sans, A retour | État plugin identique, écoute maintenue, pas de chaîne de A dans B. |
| I9 | Save, reopen | `inputChains` relue, `plugin.params` identiques. Écoute **non** restaurée. |
| I10 | Export avec entrée entendue et FX | Projet silencieux → export RMS 0. Aucune instanciation parasite (`[PERF]`). |
| I11 | Undo d'un FX d'entrée | Restauré, 1 undo. |
| H1-H6 | Glisser entrée MIDI → copie de l'instrument, ids neufs ; modification d'un côté sans effet sur l'autre ; dépôt sur groupe existant inchangé (FX et instrument) ; entrée audio → FX copiés ; multi-sélection ; entrée non montée | Modèle + `plugin.params`. |

### 5.6 Unitaires

`test_group_instrument_rule.swift`, `test_input_chains_codable.swift`, `test_record_inputs_codable.swift` inchangé, `test_midi_take_planner.swift`.

### 5.7 Non-régression

`smoke.jsonl`, `scenario_midi_record`, `scenario_record` (544), `scenario_record_zones`, `scenario_record_multi_drop`, `scenario_input_monitor` (67), `scenario_inputs`, `scenario_inputs_split_device`, `scenario_families`, `scenario_markers`, `scenario_plugin_selection`, `scenario_plugin_state_undo`, `scenario_consolidate`, `scenario_cross_paste`, `scenario_tabs`, `scenario_export_preview`, `scenario_stem_plugin_state`, `tools/i18n/xcstrings.py check` et `orphans`, tous les `tools/test_*` touchés.
Note : `scenario_record` avait 1 échec lié à `Settings.xml` réécrit par une instance graphique : à ne pas confondre avec une régression.

### 5.8 Vérifiable seulement à l'œil ou à l'oreille

- Ouverture de l'éditeur d'un AU réel (Soundtoys, UADx) sur un groupe vide, sans crash.
- Latence ressentie de l'instrument d'entrée au clavier réel, FX lourds en écoute.
- Queue d'instrument coupée en fin de groupe : acceptable ?
- Clics éventuels au mute/démute d'une note tenue ; pas de ré-attaque au démute d'une note en cours (comportement à accepter).
- Lisibilité : grisés, carte instrument, slot refusé, toasts de refus, popover FX, bouton instrument sur ligne étroite en fr/en/es.
- Glisser-déposer réel avec refus sous la main.
- Fermeture de fenêtres d'éditeur lors d'un changement d'onglet.

---

## 6. Risques

| Risque | Parade |
|---|---|
| E0 révèle un défaut moteur plus large | Arrêt, retour à l'architecte avant E1. |
| Monitor mode global du device MIDI (écoute + capture) | I5, I6. Si `off` bloque la capture : `on` sur cible muette, déjà sans effet. |
| Portes oubliées | Garde dans les primitives, D1-D16, `grep` des 28 fichiers touchant `children`. |
| `setMuted` déclenche une reconstruction | Mesure E3. Sinon mute par gate de plugin ou patch. |
| Plugins dans les clones | Retrait explicite E8, I10. |
| Fuite d'état plugin entre onglets | I8. |
| Sous-blocs (P9) non corrigés | Patch 0049c. |
| Merge low-lat | Section 4, fonctions isolées. |

---

## Reprise (état au 2026-10-30, à lire en premier dans une nouvelle session)

- E0 à E12 FAITES et commitées en local sur `main` (`7f1a9640` à `335d766e`). RIEN n'est poussé.
- Le gitlink de `main` pointe sur `f0648743dc2` (patch 0049, branche locale `objekat-group-midi-0049` de
  `tracktion_engine/`), NON publié sur le fork. Pousser le fork et `main` attend l'accord de l'utilisateur.
- Campagne de non-régression TERMINÉE le 2026-10-30 au soir sur la build de `335d766e`, verte : `scenario_record` 544,
  `scenario_bridge_sends` 1775 (lancé avec `--virtual-audio`, sans `--no-audio`, et `APP_LOG` sur le stderr de l'app),
  `input_monitor` 67, `midi_record` 71, les autres scénarios rc 0, unitaires touchés OK. Le bruit Xcode sur
  `InfoPlist.xcstrings` n'est pas à commiter. Hors chantier : clé vide `""` et 3 orphelins du catalogue, antérieurs.
- Format 35 : fichier fabriqué depuis une sauvegarde 36 (pas de vrai fichier 35 sous la main) : s'ouvre, sonne, se
  réenregistre en 36. Une prise à instrument dans un groupe à instrument s'ouvre sans plantage mais reste muette
  (fichier de test avec un id de plugin dupliqué ; cas exclu par la section 2.3).
- Défaut connu, hors chantier : P5b (note qui traverse la sortie de boucle pas rejouée dès le tour 2). À proposer après.
- Reporté au merge de `feat/low-latency-monitoring` : une entrée à chaîne ne peut pas passer par le mix direct (section 4).
- Rien vu à l'écran ni entendu : voir le rapport de la section 5 (carte instrument de groupe, clips vides grisés,
  popover FX d'une entrée, boutons instrument et écoute d'une entrée MIDI, refus affichés, vrai clavier MIDI).
