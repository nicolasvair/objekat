# Plan — enregistrement audio depuis la carte son (branche `feat/audio-recording`)

Statut : PLAN, rien codé. Q10 tranchée : **poignées** (le fichier capte de l'appui rec à l'arrêt,
l'objet est recadré aux bornes du groupe, les bords se tirent dans la matière captée).

## 1. Compréhension

On enregistre DANS des groupes bornés (pas de piste dans objekat). Une entrée (mono, ou paire
stéréo de deux canaux voisins) du device de SORTIE courant est glissée sur la timeline → un groupe
« zone de rec » (ou un groupe existant reçoit l'entrée). On arme des groupes ([ o ] centré), le
bouton rec du transport (grisé sans armement) lance lecture + capture ; à l'arrêt, chaque groupe
armé reçoit une prise = un objet enfant posé SOUS les prises précédentes, qui sont mutées en entier.
Fichier : `samples/rec/<Nom> AAAA-MM-JJ HH-MM-SS.wav`, WAV float 32 bits, taux du device.
Noms et paires vivent dans le projet (format 32 → 33).

### Points ambigus repérés — DÉCISIONS (utilisateur, 2026-10-29)

Toutes les recommandations entre crochets sont VALIDÉES, sauf où « DÉCIDÉ » ou « À TRANCHER » dit
autre chose.

1. **Ouverture des entrées** : ouvrir les canaux d'entrée réveille la demande d'accès au micro et,
   sur un casque Bluetooth, fait basculer en HFP (son dégradé). [Ouverture À LA DEMANDE : bouton
   « Activer les entrées de <device> » dans l'onglet la première fois, puis gardées ouvertes jusqu'au
   changement de device ; jamais d'ouverture/fermeture pendant la lecture (redémarre le device).]
2. **Device sans entrée** (sortie = haut-parleurs intégrés, le micro est un AUTRE device CoreAudio) :
   v1 sans agrégat → onglet vide + message. [OK, c'est le cas le plus fréquent sur un Mac nu : à
   assumer explicitement.]
3. **Clé d'une entrée** : par numéro de canal (indépendant du device) ou par (device, canal) ?
   [Par canal : `InputRef(first: Int, count: 1|2)`. Le nom du device est mémorisé à titre
   indicatif. Un projet ouvert sur une autre carte retombe sur les mêmes numéros.]
4. **Paires chevauchantes** : DÉCIDÉ — 1-2 ET 2-3 peuvent COEXISTER. Une paire n'est pas un
   « appairage » qui consomme ses canaux : c'est une entrée stéréo de plus, déclarée en plus des
   monos. Moteur : rien à changer, tous les devices stéréo voisins sont décrits d'avance et lisent
   leurs canaux indépendamment (`WaveInputDevice.cpp:1784`). Défaut proposé (à confirmer à l'œil) :
   un canal qui appartient à au moins une paire n'a plus sa ligne mono dans l'onglet (« Délier » la
   rend) ; une paire se retire par « Délier » sur SA ligne.
5. **Groupe pointant une entrée qui n'existe plus** (dé-appairage, carte plus petite) : [entrée
   « absente », [ o ] grisé, armement refusé ; l'affectation est conservée.]
6. **Quand muter la prise précédente** : au début du rec ou à l'arrêt ? [À l'ARRÊT, dans le même undo
   que la création de la prise : on entend l'ancienne prise pendant qu'on joue par-dessus, ⌘Z rend
   tout.] Et lesquelles : [tous les enfants non mutés du groupe qui croisent la fenêtre du groupe.]
   Cas limite : une prise entièrement hors fenêtre (point 7) étant
   inaudible, DÉCIDÉ (user) : NE PAS muter les précédentes dans ce cas — sinon le groupe devient muet.
7. **Capture qui ne croise pas la fenêtre du groupe** (rec lancé après la fin du groupe, arrêté avant
   son début) : DÉCIDÉ — l'objet est créé QUAND MÊME, à sa position réelle (toute la capture), donc
   dans la zone grise du groupe, hors fenêtre et inaudible. Pas de toast.
8. **Même entrée sur deux groupes armés** : [UN seul fichier par entrée et par prise, référencé par les
   deux objets — ce qui résout aussi la collision de nom « unique à la seconde ». Deux entrées de même
   nom → suffixe ` (2)`.]
9. **Projet jamais enregistré** (pas de dossier-projet) : [bouton rec grisé, infobulle « enregistrez le
   projet d'abord ».]
10. **Groupes infinis / en boucle / instance de consolidé** : [armement refusé v1 ; drop d'entrée
    refusé dessus.]
11. **Drop sur un clip (pas un groupe)** ou plancher non tenable (objet suivant très proche) :
    [refus (fantôme rouge) si le point de lâcher tombe dans un objet non-groupe ; plancher =
    max(1 s, 24 px) ; si l'objet suivant est plus proche que le plancher → refus.]
12. **Drop dans la sous-lane d'un groupe ouvert** : [zone créée DANS ce groupe (sous-groupe), même
    règle que `placeClip`.]
13. **Persistance de l'armement / undo** : [armement = état de session, NON persisté, hors undo (comme la
    boucle de lecture). Affectation entrée→groupe : persistée, dans l'undo. Noms/paires : persistés,
    hors undo (réglage), projet marqué modifié.]
14. **Rec pendant la lecture** : DÉCIDÉ — appui rec en lecture = punch-in à la volée à la position
    courante ; à l'arrêt, lecture+rec depuis le caret. Raccourci clavier : DÉCIDÉ — ⌘⌥R (provisoire, l'utilisateur le changera peut-être). ⌘R reste
    « renommer » : dans `TimelineKeyHandler.swift:975`, tester ⌥ AVANT la branche ⌘ seule (⌘⌥R
    tombe aujourd'hui dans le renommage). Une ligne en INC 6.
15. **Écoute + solo** : DÉCIDÉ — l'écoute d'une entrée reste audible quel que soit le solo.
16. **Nom par défaut** d'une entrée : [« In 3 » / « In 1-2 » (clé i18n), pas le nom CoreAudio.]

## 2. Architecture

### 2.1 Choix moteur : piste d'entrée cachée PAR ENTRÉE (pas par groupe)

Évalué :
- **A. Piste cachée par groupe armé** (proposition initiale) : N groupes sur la même entrée = N fichiers
  identiques, N chemins d'écoute (doublons audibles), pistes proportionnelles aux groupes.
- **B. Capture maison** (callback JUCE additionnel + écrivain fileté) : zéro piste, mais la
  compensation de latence (entrée + sortie + latence du graphe/PDC) et le calage transport sont à
  refaire et à prouver.
- **C. (retenu) Une AudioTrack cachée par ENTRÉE utilisée** (écoutée OU affectée à un groupe armé),
  cible de son `InputDeviceInstance`. Tracktion fait : compensation de latence (device + graphe,
  `WaveInputDevice.cpp:1107`), écriture fichier filetée, écoute (nœud live, `EditNodeBuilder.cpp:1579`),
  vu-mètre (`InputDevice::levelMeasurer`, `InputDevice.h:68`). Un fichier par entrée par prise ; les
  groupes ne sont touchés qu'à l'arrêt, par les primitives Swift existantes. Aucun enregistrement
  dans un ContainerClip → le piège de l'étendue ne se pose pas.

Faisabilité vérifiée dans le sous-module (aucun patch moteur requis a priori ; si besoin, prochain
numéro = **0047**, `engine-patches/3.5/` s'arrête à 0046) :
- `OBJEngineBehaviour::describeWaveDevices` (`OBJEngineCore.mm:338-360`) fait `if (isInput) return;`
  → à remplacer : un device mono par canal + un stéréo par paire VOISINE (2N−1 devices). Les
  descriptions peuvent se chevaucher : `WaveInputDevice::consumeNextAudioBlock`
  (`tracktion_WaveInputDevice.cpp:1784`) lit `allChannels[ci.indexInDevice]` indépendamment par
  device. Tout étant décrit d'avance, appairer = activer/désactiver des devices, jamais reconstruire
  la liste. N'activer (`DeviceManager::setDeviceEnabled`) que les devices utiles (monos non appairés
  + paires déclarées).
- Ouverture : `initialise(0, 2)` (`OBJEngineCore.mm:2001`) → à la demande, `setup.inputDeviceName =
  outputDeviceName`, `useDefaultInputChannels = false`, `inputChannels.setRange(0, nIn, true)` ;
  à reporter dans `setOutputDevice:` (`:10549`) et `applySampleRatePolicy` (`:10516`).
- Nom/emplacement du fichier : `EngineBehaviour::getFileForNewAudioRecording(Track&, ext)`
  (`tracktion_EngineBehaviour.h:149`) → table piste-cachée → URL préparée par OBJEngineCore avant
  `record`. Format : `WaveInputDevice::setOutputFormat("WAV")` + `setBitDepth(32)` ; JUCE écrit du
  float à 32 bits (`juce_WavAudioFormat.cpp:1600`) — à ASSERTER (tag fmt = 3).
- Rec : `dest->recordEnabled` (`InputDeviceInstance::setRecordingEnabled`) puis
  `TransportControl::record(false)` (`TransportControl.h:90`) ; arrêt `stop(false,false)` (`:97`).
  Résultat : `TransportControl::Listener::recordingFinished(instance, targetID, clips)` (`:362`) →
  lire fichier + origine (`clip.start − offset`), puis RETIRER le clip de la piste cachée (le fichier
  reste) et rendre `[ {inputKey, path, originSecs, lengthSecs, sampleRate} ]` à Swift.
- Écoute : `InputDevice::setMonitorMode(on|off)` (`InputDevice.h:46-54`) par device ; une seule piste
  par entrée → pas de double écoute. Les pistes cachées sont à la racine (Main), HORS `_poolTracks`
  (`trackForSlot:` `:2626`), réutilisées (chaque AudioTrack crée des alias dans Settings.xml, cf.
  `purgeStaleTrackDeviceAliases` `:372`), exclues du recensement, du routage stems, du solo et du
  ramassage des compartiments vides. Rendu/export : `createLiveInputsNode` saute `forRendering`.

À vérifier tôt (INC 1/5) : qu'une piste cachée SANS clip ni écoute ne coûte rien au graphe ; que le
rec ne déclenche pas de reconstruction pathologique ; que `mergeMode` 0 (« add ») laisse les clips
existants tranquilles (il n'y en a pas, on retire chaque prise).

### 2.2 Groupe vide borné
`SoundObject` (`SoundObject.swift:481`) : `startTime`/`duration` + `kind.group(children:)`, enfants en
temps ABSOLU, lane RELATIVE au groupe. `createGroupFromTimeSelection` (`EditViewModel+Groups.swift:234`)
sait déjà créer un groupe borné vide. Moteur : groupe borné → étendue = fenêtre du modèle
(`refreshContainerSpanForKey:` `:2727`) ; container sans enfant → aucun nœud (`:458-474`). Une zone
de rec vide est donc gratuite. Prise = enfant via `addChild` (`:170`).

### 2.3 Modèle et format (33)
- `struct InputRef: Codable, Hashable { first: Int; count: Int }` (0-based, count ∈ {1,2}).
- `struct RecordInputsConfig: Codable { deviceName: String?; pairs: [Int] /*premier canal*/;
  names: [String: String] /*clé "3" ou "1-2"*/ }` → `ProjectDocument.recordInputs`
  (`EditViewModel+Types.swift`) ; validation pure `InputPairing.validate` (voisins, sans doublon, dans le nombre de canaux ;
  chevauchement 1-2 + 2-3 AUTORISÉ) et `InputPairing.visibleInputs(channelCount, pairs)` (liste
  de l'onglet : paires + monos des canaux hors paire).
- `SoundObject.recordInput: InputRef?` au niveau supérieur (groupes seulement), à porter par
  `derivedCopy` (`SoundObject.swift:1249`) ; `CrossProjectImport.plan` le REMET à nil.
- `SessionSchema.formatVersion` 32 → 33 (`SessionSchema.swift:21`) + note de schéma.
- `ConsolidateFolders.audioSubfolders` (`ConsolidateFolders.swift:73`) + `samples/rec` (chemins
  portables). `ProjectFileUsage` / ménage disque : `samples/rec` compté.
- VM (non persisté) : `armedGroupIDs: Set<UUID>`, `recordState: idle | recording(start, takes…)`,
  `inputLevels`, `monitoredInputs: Set<InputRef>` (persisté ? → non, état de session).

### 2.4 Fonctions pures (testables seules)
- `RecordZonePlanner.plan(drop: (time, displayLane), visibleSpanSecs, pps, laneObjects, timeSelection,
  groupUnderCursor) → .create(start,end,lane,parent?) | .assign(groupID) | .refuse(reason)`.
- `RecordTakePlanner.plan(group, capture: (origin, length), file) → (newChild, mutedIDs)` :
  start = max(gStart, origin), end = min(gEnd, origin+length), `sourceOffset = start − origin`
  (secondes source, vitesse 1), lane = max(lane enfants)+1, mutedIDs = enfants audibles croisant la
  fenêtre. Intersection vide → objet créé quand même sur TOUTE la capture (start = origin,
  `sourceOffset = 0`), dans la zone grise du groupe, et (proposé) `mutedIDs = []`.
- `RecordFileNaming.name(inputName, date, taken:)` (assainit `/` `:`, suffixe ` (2)`).

### 2.5 UI
- `LeftPanelTab { objet, liste, sons, entrees }` (`App/ContentView.swift:33`, switch `:83-85`) →
  `Inputs/InputsPanelView.swift` : ligne = n°, VU (lecture 30 Hz d'un tableau de crêtes moteur),
  nom (TextField avec **KeyboardClaim**), bouton écoute ON/OFF ; sélection ⇧-clic de deux voisins →
  « Lier en stéréo » ; « Délier » sur une ligne de paire. Les paires peuvent se chevaucher
  (1-2 et 2-3 listées ensemble). Ligne glissable : `InputDragSession.shared` + `.plainText`
  (même idiome que `PluginDragSession`, `TimelineView.swift:1103-1127`).
- Timeline : `pluginOutcome`-like `inputOutcome` → fantôme de zone (même layout que le plan pur),
  refus rouge. Le **canvas** résout la cible (lane/groupe/sélection), les blocs restent présentation.
- Icône [ o ] centrée sur le groupe affecté : dessinée dans `GroupBlocksCanvas`, hit-test dans le
  canvas (convention canvas/présentation) ; rouge plein = armé ; grisée si entrée absente.
- DÉCIDÉ (user, « un détail ») : un groupe ARMÉ est encadré en ROUGE CLIGNOTANT, et son [ o ]
  clignote aussi — cadence un peu rapide (~2 Hz), en fondu (fade in/out sinusoïdal, pas on/off).
  Contrainte perf : l'animation ne doit PAS invalider le Canvas de la timeline à chaque frame —
  couche dédiée légère (overlay des seuls groupes armés, `TimelineView(.animation)` limité à elle, ou
  `CALayer` + `CABasicAnimation` autoreverse, ~0 CPU) ; rien ne s'anime s'il n'y a aucun groupe armé.
  Si c'est trop lourd, repli : clignotement on/off. Œil : lisibilité, et perf.frames avec 480 objets.
- Transport (`App/TransportView.swift:81-89`) : bouton rec à côté de play, `.disabled(armed.isEmpty
  || projectFolder == nil)`, rouge pulsé pendant le rec.
- `Workspace` : changement d'onglet refusé pendant un rec (comme l'export, `Workspace.swift:408`).

### 2.6 Harnais sans carte son : device virtuel
`--virtual-audio[=in:4,out:2,sr:48000,bs:256,inlat:64,outlat:96]` (`LaunchArguments.swift`) :
un `juce::AudioIODeviceType` « OBJ Virtual » (`OBJVirtualAudioDevice.h`) dont le device appelle le
callback depuis un thread temps réel cadencé (bs/sr). Entrées synthétiques par canal : `sine(f,a)`,
`silence`, `impulse(période)`, `loopback` (= sortie L retardée de inlat+outlat, latences annoncées par
`getInput/OutputLatencyInSamples`). Rend la lecture, le VU, l'écoute et le rec testables en headless,
sans toucher une vraie carte. ⚠️ Ne JAMAIS laisser `saveSettings` écrire « OBJ Virtual » dans
Settings.xml (sinon le prochain lancement normal cherche ce device) : garde sur la sauvegarde ou
Settings dédié en mode virtuel. `--no-audio` reste « aucune entrée ».

### 2.7 API de commandes (`CommandAPI/Commands+Record.swift`)
`audio.virtual.set_input {channel, signal, freq?, amp?}` · `input.list` (ref, nom, VU crête dB,
écoute, paire) · `input.enable` · `input.rename {ref,name}` · `input.pair {first}` /
`input.unpair {first}` · `input.monitor {ref,on}` · `rec.drop {ref, lane, time, visible_secs}`
(passe par `RecordZonePlanner`, comme le geste) · `rec.assign {group, ref}` · `rec.arm {group,on}` ·
`rec.start` / `rec.stop` (rend les prises créées) · `rec.status`. Doc : `docs/command_api.md`.

## 3. Incréments (chacun buildable et testable seul)

| # | Contenu | Fichiers | Risques |
|---|---|---|---|
| 0 | Device virtuel + `--virtual-audio` + `audio.virtual.*` | `OBJVirtualAudioDevice.h` (neuf), `OBJEngineCore.mm` (init `:2001`), `LaunchArguments.swift`, `Commands+Audio.swift` | cadence thread ; pollution Settings.xml |
| 1 | Entrées moteur : ouverture à la demande, `describeWaveDevices` inputs, activation devices, crêtes par canal, snapshot `inputChannels` ; Info.plist `NSMicrophoneUsageDescription` + entitlement `com.apple.security.device.audio-input` (absent de `objekat.entitlements` : sans lui, le Release signé runtime durci n'entend QUE du silence) | `OBJEngineCore.h/.mm` (`:338`, `:10516`, `:10549`), `Info.plist`, `objekat.entitlements`, `Commands+Record.swift` (`input.list/enable`) | coupure audio à l'ouverture ; Bluetooth HFP ; permission refusée |
| 2 | Modèle + format 33 (InputRef, RecordInputsConfig, `recordInput`, `samples/rec`) | `SoundObject.swift`, `EditViewModel+Types.swift`, `SessionSchema.swift`, `ConsolidateFolders.swift`, `CrossProjectImport.swift`, `ProjectFileUsage.swift` | oubli d'un site de copie (règle `derivedCopy`) |
| 3 | Onglet Entrées + écoute (pistes cachées par entrée, `setMonitorMode`) + noms/paires | `ContentView.swift:33`, `Inputs/InputsPanelView.swift` (neuf), `EditViewModel+Record.swift` (neuf), `OBJEngineCore.mm`, i18n | piste cachée vue par recensement/stems/solo/GC ; larsen en écoute micro |
| 4 | Zones de rec : drag→timeline (planner pur), affectation, [ o ] armer, bouton rec grisé | `RecordZonePlanner.swift` (neuf), `TimelineView.swift:1103`, `GroupBlocksCanvas.swift`, `TransportView.swift:81`, `Commands+Record.swift` | hit-test hors canvas ; conflit avec le drop plugin |
| 5 | Enregistrement : rec/stop, nommage via EngineBehaviour, WAV f32, `recordingFinished`, retrait du clip moteur, prises (planner pur, poignées, lane dessous, mute précédentes) en UN undo | `OBJEngineCore.mm` (`:6606` play/stop, `:274` behaviour), `RecordTakePlanner.swift`, `RecordFileNaming.swift`, `EditViewModel+Record.swift`, `Workspace.swift` | latence ; clip moteur créé puis retiré (2 reconstructions) ; stop asynchrone |
| 6 | Finition : prise en cours visible (bande rouge qui grandit), gardes (projet non sauvé, changement de device en rec → arrêt propre en gardant les fichiers, disque plein, fermeture d'onglet), doc, mémoire | divers | — |

## 4. Plan de test

**INC 0** — `scenario_virtual_audio.py` : `audio.status` = « OBJ Virtual », running ; `transport.play`
→ position avance à ±5 % du temps réel ; Settings.xml inchangé (hash avant/après) ; lancement normal
suivant ouvre la vraie carte.

**INC 1** — `scenario_inputs.py` (virtuel 4 in) : `input.list` vide avant `input.enable`, 4 entrées
après ; sine a=0,5 sur 0 → crête ≈ −6 dB (±0,5), silence sur 1 → < −90 dB ; `--no-audio` → liste vide,
pas d'erreur ; changement de taux/buffer → entrées toujours là. `test_input_pairing.swift` (pur : 1-2 + 2-3 acceptés ensemble, doublon/non-voisins/hors canaux
refusés, monos masqués sous une paire).
Œil/oreille : vraie carte (interface multi-entrées), invite micro, AirPods (pas d'activation surprise).

**INC 2** — `test_record_inputs_codable.swift` : aller-retour JSON, lecture d'un format 32 (champs
nil), paires invalides rejetées ; `test_cross_project_import.swift` étendu : `recordInput` remis à
nil ; `test_project_file_usage.swift` : `samples/rec` compté. Non-régression complète.

**INC 3** — `scenario_input_monitor.py` : écoute ON sur sine → vu-mètre master > −20 dB ; OFF → master
silencieux ; même entrée affectée à 2 groupes + écoute ON → niveau master = UNE fois (pas +6 dB) ;
recensement des nœuds inchangé écoute OFF ; renommer/appairer → projet modifié, sauvé/relu identique.
Œil : VU fluide, KeyboardClaim (⌫ dans le champ ne supprime pas l'objet sélectionné).

**INC 4** — `test_record_zone_planner.swift` : 40 % de la vue, butée sur l'objet suivant, plancher,
refus sur un clip, sélection temporelle → bornes exactes, groupe existant → assign, sous-lane de
groupe ouvert → parent, infini/boucle → refus. `scenario_record_zones.py` : `rec.drop` crée un groupe
vide nommé comme l'entrée, 1 undo, 0 nœud moteur ajouté ; `rec.arm` → `rec.status.can_record`.
Œil : fantôme, [ o ] centré lisible à tous zooms, bouton rec grisé/actif.

**INC 5** — `scenario_record.py` (virtuel) :
1. sine 0 → groupe [2 s, 6 s], rec depuis 0, stop à 8 s : fichier `samples/rec/<Nom> <date>.wav`
   existe, en-tête WAV fmt 3 / 32 bits / taux du device, durée ≈ 8 s ; objet = [2, 6], `sourceOffset`
   = 2 s ; le fichier contient la sine dès 0 (poignées).
2. deuxième prise : la première est mutée, la nouvelle est sur la lane +1 ; ⌘Z → retour exact à
   l'état d'avant la prise 2 ; fichier toujours présent.
3. même entrée sur 2 groupes armés → un seul fichier, deux objets.
4. **latence** : `loopback` + clip impulsion à t=1,000 s, rec → l'impulsion captée tombe à 1,000 s
   timeline à ≤ 1 ms (viser ≤ 2 échantillons ; relever l'écart réel) ; refaire avec un plugin à
   latence (`LatencyPlugin`) sur le Main.
5. rec hors fenêtre → objet créé sur toute la capture, hors fenêtre du groupe (zone grise), export du
   groupe silencieux à cet endroit, aucun toast ; les prises précédentes restent audibles.
   5bis. paires 1-2 et 2-3 simultanées, une sine différente sur chaque canal, deux groupes armés →
   deux fichiers stéréo dont le canal commun (2) est identique échantillon par échantillon.
   5ter. rec appuyé pendant la lecture (punch-in) → origine du fichier = position au moment de
   l'appui, à un bloc près. 6. projet non sauvé → `rec.start` refusé.
7. changement d'onglet pendant rec → refusé.
Unitaires : `test_record_take_planner.swift`, `test_record_file_naming.swift`.
Oreille : vraie prise micro/instrument, calage à l'oreille contre un clic joué, pas de glitch au
départ/à l'arrêt, gros projet (stutter ?).

**INC 6** — scénarios de garde (device débranché en rec via virtuel « disparition »), non-régression
complète, build 0 nouveau warning, i18n FR/EN/ES.

## 5. Q10 — tranchée : poignées
Conséquences intégrées : capture de l'appui rec à l'arrêt (punch range Tracktion non utilisé),
recadrage pur dans `RecordTakePlanner`, objet tirable dans la matière ; le container borné coupe
nativement ce qui déborde. Coût : fichiers plus longs que la zone (assumé).
