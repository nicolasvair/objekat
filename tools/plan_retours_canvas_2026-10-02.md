# Retours du 2 octobre 2026 sur la timeline Canvas — diagnostic et plan de correction

Branche `feat/canvas-selected-clips`, HEAD `f24773db`. Comparaison de référence :
l'archive « du 30/09 » (`/Applications/objekat.app`, identique octet pour octet à
`historique builds/objekat 2026-09-30 23-40-30.app`, a priori `5aa4e40d`) contre l'archive
`objekat 2026-10-02 11-14-19.app` (HEAD). Attention : entre les deux, il n'y a pas que la
migration Canvas (E0→E8, base `0dfe06bf`). Toute la branche `feat/ui-2026-10-01` y est aussi,
dont les crossfades à poignée débordante et suiveurs (`cff0b3a6`, `3a2666ee`, `b6f8dcb9`).

Méthode : lecture du code, `git diff` / `git blame`, et un test Swift pur pour D. Aucune app
lancée, aucun bench, aucune capture d'écran. Aucun code applicatif n'a été modifié.

Ordre de priorité :
1. **D** : perte de matière au relâché ;
2. **C** : geste manquant, petit et sûr ;
3. **A** : performance, à mesurer avant et après ;
4. **B** : aucun changement de code trouvé, il faut enquêter.

---

## D — Dépôt d'un clip dans un groupe imbriqué : écrase « comme sur A »  (PRIORITÉ 1)

### Cause

`objekat/Timeline/TimelineView+DragHandler.swift`, au relâché du déplacement (vers les
lignes 1322-1473) :

```swift
if let sgID = state.sourceGroupID,
   let sgDL = viewModel.laneEntries.first(where: { $0.item.id == sgID })?.displayLane {
    grabbedFinalAbsDL = sgDL + 1 + grabbedAnchor.lane + dl      // ~l.1328
} else {
    grabbedFinalAbsDL = displayLane(for: grabbedAnchor.lane) + dl
}
```

Pour un objet qui est ENFANT d'un groupe, on reconstruit la ligne d'affichage finale à partir
de la lane **modèle** (`grabbedAnchor.lane`). Mais dans `buildLaneEntries`, un enfant est
affiché à `parent.displayLane + 1 + lane + extraAbove`, où `extraAbove` est la hauteur des
sous-groupes OUVERTS (et des piano-rolls / bandes d'automation) posés au-dessus de lui dans
le même groupe. Ce calcul l'ignore. Toute la chaîne du relâché travaille donc sur une ligne
décalée de `extraAbove` vers le haut :

- `groupDropEntry` (le groupe ouvert le plus profond qui contient la ligne) trouve un groupe
  de PLUS HAUT NIVEAU que celui que montre l'aperçu, ou aucun ;
- avec aucun groupe → **éjection à la racine** : `resolveOverlaps` à la racine troue ou coupe
  **A entier**, d'où le « comme si on avait déposé sur A » ;
- avec le groupe source → `updateLane(anchor.lane + dl)` mélange un delta d'AFFICHAGE et une
  lane MODÈLE ;
- dans les appels de reparent, `grabbedChildLane: grabbedFinalAbsDL - gDL - 1` est un
  décalage d'affichage passé comme lane modèle. Il dérive de la hauteur des sous-groupes
  ouverts au-dessus de la cible.

L'aperçu, lui, est juste : `previewOffset` (~l.1623) dessine à `entry.displayLane + dl`.
C'est le relâché qui diverge de ce que l'œil a vu.

**Pourquoi « un groupe dans C a l'air OK »** : le défaut ne dépend pas du type d'objet mais
de la POSITION de la source. Un objet déplacé depuis la racine ne passe pas par ce calcul
(son chemin `displayLane(for:)` est correct). Un groupe testé depuis la racine marche donc,
et un clip qui vient de l'intérieur de A ou de B, sous un sous-groupe ouvert, échoue. Le test
pur le confirme : un groupe FERMÉ enfant de A, placé sous B, échoue exactement comme un clip.

### Régression ou défaut préexistant ?

**Défaut préexistant** (blame : juin 2026, refactor FolderTrack), donc pas une régression de
la migration Canvas. Deux niveaux d'imbrication suffisent. Trois niveaux le rendent fréquent :
la source est presque toujours sous un sous-groupe ouvert.

### Reproduction pure (fait)

`tools/test_nested_drop_target.swift` recopie `buildLaneEntries`, `occupiedLanes` et la
résolution du relâché, dans sa version actuelle et dans sa version corrigée.

Exécution : `swiftc -parse-as-library tools/test_nested_drop_target.swift -o /tmp/nd && /tmp/nd`,
résultat **ALL PASS**.

Scène, A ⊃ B ⊃ C, tous ouverts :

| Ligne | Contenu |
|---|---|
| 0 | A |
| 1 | B |
| 2 | C |
| 3 | Z (C, lane 0) |
| 4 | ligne de dépôt de C |
| 5 | Y (B, lane 1) |
| 6 | ligne de dépôt de B |
| 7 | X (A, lane 1) |
| 8 | ligne de dépôt de A |
| 9 | T (racine) |

| Geste | Aperçu (attendu) | Code actuel | Effet |
|---|---|---|---|
| T (racine) → ligne de dépôt de C | C, lane 1 | C, lane 1 | OK |
| X (enfant de A) dl −3 → ligne de dépôt de C | C, lane 1 | **éjecté à la racine, lane 0** | A écrasé |
| X dl −4 → ligne de Z | C, lane 0 | **éjecté à la racine, lane 0** | A écrasé |
| Y (enfant de B) dl −1 → C | C, lane 1 | déplacé dans B, lane 0 | **C écrasé** |
| Y dl −2 → C | C, lane 0 | reparenté dans A, lane 0 | **B écrasé** |
| T → ligne de dépôt de B | B, lane 2 | B, lane 4 | dérive de la hauteur de C |
| X dl −1 → ligne de dépôt de B | B, lane 2 | déplacé dans A, lane 0 | **B écrasé** |
| Groupe fermé G enfant de A, sous B, → C | C | éjecté | même défaut qu'un clip |
| Groupe racine H → C | C | C | OK |

Réponse à « B marche-t-il ? » : un dépôt dans B échoue aussi dès que la source est un enfant
de A, ou dès que C est ouvert au-dessus de la lane visée (dérive). Il ne marche que depuis la
racine et sans sous-groupe ouvert au-dessus de la cible.

### Correctif (à appliquer)

Fichiers : `TimelineView+DragHandler.swift`, éventuellement un nouveau
`objekat/Shared/MoveDropResolution.swift`.

1. **Ligne finale = ligne d'affichage saisie + delta.** Au démarrage du déplacement
   (~l.910-934), stocker `grabbedDisplayLane = hitDL` (déjà calculé l.633) dans
   `MoveDragState`. Au relâché :
   `grabbedFinalAbsDL = state.grabbedDisplayLane + dl`.
   Les deux branches ci-dessus disparaissent.
2. **Lane enfant de la cible = conversion affichage → modèle.** Dans les trois appels
   `reparentToGroup`, `reparentChildBetweenGroups` et `altReparent`, remplacer
   `grabbedChildLane: grabbedFinalAbsDL - gDL - 1` par
   `viewModel.baseLaneForDisplay(grabbedFinalAbsDL, inParent: target.id)`.
   Cette fonction existe déjà (`EditViewModel+Markers.swift` ~l.321-367, avec son inverse
   `displayLane(forBase:inParent:)`).
3. **Déplacement dans le groupe source.** Calculer
   `newLane = baseLaneForDisplay(row, inParent: sgID)` puis `dlModel = newLane - anchor.lane`,
   et appliquer `updateLane(a.lane + dlModel)` à chaque ancre. N'éjecter que si
   `groupDropEntry == nil`.
4. **Éjection.** Lane racine = `viewModel.baseLaneForDisplay(row)`, la version racine de
   `EditViewModel+Clipboard.swift` ~l.32-56, au lieu de « la lane de l'entrée posée sur
   cette ligne ».
5. **Copie ⌥** (`altCopyChildrenInGroup` avec `dl`) : même conversion.
6. **(Recommandé)** Extraire la résolution « (ligne saisie, dl, entrées) → cible + lane
   modèle » dans une fonction pure `MoveDropResolution.resolve(...)` qu'appellent le relâché
   ET l'aperçu, pour qu'ils ne puissent plus diverger. Faire de `test_nested_drop_target.swift`
   son test unitaire, en remplaçant la copie locale `fixed` par le vrai fichier compilé à côté.

Risques à couvrir :
- sélection multiple d'enfants répartis de part et d'autre d'un sous-groupe ouvert : chaque
  ancre garde son écart MODÈLE, le delta modèle étant calculé sur l'objet saisi ;
- vérifier que le chemin translate / `placeClip` du déplacement simple de groupe ne réutilise
  pas le même calcul ;
- `commentAnchor` applique le même `dl` brut : à aligner ;
- `resolveOverlaps` reste la bonne politique une fois la cible juste. Rien à changer là.

### Tests

- Pur : `tools/test_nested_drop_target.swift` (déjà commité). Après le correctif, il doit
  tester le vrai code de `MoveDropResolution`.
- API headless : bâtir A ⊃ B ⊃ C (`group.create`, `group.open`), poser X dans A sous B, puis
  rejouer chaque ligne du tableau via la porte qui simule le relâché (s'il n'y en a pas,
  ajouter `debug.move_drop {id, dl, dt}` en DEBUG, qui appelle la même fonction pure). Après
  chaque geste, vérifier par `object.list` le parent, la lane, et qu'**A, B et C gardent leur
  durée et leurs enfants**.
- À l'écran (utilisateur) : le cas rapporté, puis les mêmes gestes avec C fermé (doit déjà
  marcher) et ouvert.

Questions à poser à l'utilisateur pour confirmer le scénario : d'où venait le clip (racine,
A ou B) ? Y avait-il un sous-groupe ouvert au-dessus de lui ? Qu'est-ce qui a été écrasé (A
coupé ou troué, B) ? Le clip a-t-il fini à la racine ? Le groupe qui « marche » venait-il de
la racine ? L'aperçu était-il au bon endroit pendant le drag ?

---

## C — La bande de marqueurs ne sélectionne pas de temps au glisser  (PRIORITÉ 2)

### Cause

`TimelineView+DragHandler.swift`, `handleCanvasDrag` (~l.508-519) envoie tout drag démarré
dans la bande vers `handleMarkerBandDrag` (~l.2162). Or celui-ci **sort sans rien faire** si
`markerBandZone(at: start) == nil`, c'est-à-dire sur un espace vide. Le clic sur le vide
(`TimelineView+TapHandler.swift` ~l.24-37, `handleMarkerBandTap` ~l.714, puis
`handleMarkBandClick` dans `EditViewModel+Markers.swift` ~l.633) ne fait que désélectionner les
annotations : il ne déplace pas le curseur, contrairement à la règle (`moveCursorFromRuler`,
`TimelineView.swift` ~l.2632).

### Régression ou défaut préexistant ?

**Préexistant** : la bande n'a jamais eu ce geste. Le seul diff de `MarkerBandView` sur la
période est le passage de la sélection à un `Set`. C'est une demande nouvelle, pas une
régression.

### Correctif

Pas de nouveau geste SwiftUI : on garde le DragGesture racine unique.

1. Dans `handleCanvasDrag`, avant la branche de la bande :
   ```swift
   if rulerSelectionDrag == nil, markerBandDrag == nil,
      markerBandContains(value.startLocation),
      markerBandZone(at: value.startLocation) == nil,
      !markerLaneHeaderContains(value.startLocation) {
       handleRulerDrag(value, phase: phase); return
   }
   ```
   La branche existante `if rulerSelectionDrag != nil || rulerBandContains(...)` capte ensuite
   les frames suivantes, puisque `rulerSelectionDrag` est armé. Tout le reste est réutilisé
   tel quel : snap, ⇧ qui étend la sélection de base, `RulerSelection.range`,
   `setTimeSelectionFromRuler`, `selectInDisplayLanes` puis curseur au relâché, plage nulle
   qui efface la sélection et ramène le curseur.
2. `markerLaneHeaderContains(p)` : vrai si `p.x - scrollOffsetX` tombe dans l'en-tête de ligne
   ÉPINGLÉ (pastille `dotXRange` 1...22, nom jusqu'à environ 132 px ; on réutilise la largeur
   que déclare `MarkerLaneHeaderView`, `MarkerBandView.swift` ~l.279). Ainsi la pastille
   (clic droit couleur), le double-clic de renommage et le TextField restent intacts.
3. Clic simple sur le vide de la bande, sans modificateur : désélectionner les marques
   (comportement actuel) PUIS `moveCursorFromRuler(x)`, comme la règle. Avec ⇧ ou ⌘ : garder
   le comportement actuel.
4. Ce qui ne change pas : drag d'une marque (verrou d'axe), crop de région, ⇧ / ⌘ sur une
   marque, double-clic de renommage, menu clic droit (moniteur). `followsScroll` exclut déjà
   la règle et la bande.

Risque : une région longue couvre beaucoup de largeur, et on ne peut pas commencer une
sélection par-dessus. C'est voulu, car `markerBandZone` répond « région » et c'est la région
qui se déplace. Le drag doit partir d'un vide, ou de la règle.

### Tests

- Pur : extraire la décision dans `Shared/MarkerBandGesture.swift`
  (`route(zoneHit: Bool, inHeader: Bool, dragInFlight: …) -> .ruler | .mark | .none`) et
  écrire `tools/test_marker_band_gesture.swift` : vide → ruler, marque → mark, en-tête →
  none, drag déjà en cours → inchangé.
- Non-régression : `scenario_markers.py` (toutes les portes marqueurs), `smoke.jsonl`.
- À l'écran (utilisateur) : glisser sur le vide d'une ligne de marqueurs (la bande grise de
  la règle doit apparaître), ⇧-glisser pour étendre, cliquer sur le vide pour déplacer le
  curseur, et vérifier que glisser une marque la déplace toujours.

---

## A — Lag sur la représentation des crossfades  (PRIORITÉ 3, mesurer d'abord)

### Constat

Le dessin des crossfades a changé de nature avec la migration Canvas, et le drag de
crossfade a changé de coût le 01/10 (avec les suiveurs). Les deux ne sont PAS dans l'archive
du 30/09. Hypothèses, de la plus probable à la moins probable :

**A1. Drag de crossfade (surtout multiple) : écritures modèle non regroupées.**
- `TimelineView+CrossfadeDrag.swift`, `handleCrossfadeDrag`, appelle POUR CHAQUE zone
  (la saisie + les suiveurs depuis `3a2666ee`) et à CHAQUE frame :
  - `openCrossfade` (`EditViewModel+Crossfade.swift` ~l.353), qui fait `updateTrim` ×2,
    `updateFadeOut` et `updateFadeIn` ;
  - puis `updateFadeCurve` ×2, et éventuellement `updateTrim` / `updateFadeIn`.
- Chaque écriture déclenche `items.didSet`, d'où :
  - un `rebuildLaneEntries` en O(N) ;
  - l'invalidation de `crossfadePartnersCache`, `crossfadeZoneIndexCache`, `findIndex`,
    `itemsExtentCache` et `laneEntryIndexCache` ;
  - une poussée moteur.
- Total : environ **6 × K reconstructions O(N) par frame**, puis un redessin complet de tous
  les Canvas.
- Rien n'est enveloppé dans `batchItemsMutation`.
- Origine : préexistant pour K = 1 (une zone), aggravé par `3a2666ee` (K zones).

**A2. Le Canvas des crossfades redessine tout, tout le temps.**
- `crossfadeCanvas()` (`TimelineView.swift` ~l.2216-2228) est UN Canvas de la largeur totale.
- `CrossfadeVeilOverlay.swift` → `crossfadeDrawings()` refait à chaque réévaluation du body
  (palier de scroll de 512 px, écriture modèle, changement de sélection) :
  - `displayedCrossfadeZones` (index + reprojection pendant un drag) ;
  - 2 `find` par zone ;
  - 2 `CrossfadeCurvePath` de **jusqu'à 512 échantillons** chacun, avec un `pow` par
    échantillon (`FadeCurve.gain`, `SoundObject/FadeCurve.swift:46`).
- Avant la migration, chaque zone était une vue SwiftUI : si ses props n'avaient pas changé,
  SwiftUI la comparait et ne la redessinait pas.
- **Régression de la migration** (coût par frame), même si l'ancien chemin n'avait pas de
  culling.

**A3. Coûts annexes.**
- `crossfadeSharedPx(for:)` est appelé deux fois par bloc pour le même objet
  (`TimelineView.swift` ~l.2680-2681 et ~l.3739-3740).
- Le survol de la moitié haute d'un bloc passe par `crossfadeHit` → `fadeHandleOverhang`
  → `selectionZoneHover` à chaque mouvement (nouveau, `cff0b3a6`).

### Correctif proposé (dans l'ordre, chaque étape mesurée)

1. **A1** : envelopper la boucle de frame de `handleCrossfadeDrag` (toutes les zones, toutes
   les écritures) dans `viewModel.batchItemsMutation { … }`. On obtient UN `didSet`, UN
   rebuild et UNE invalidation par frame.
   - Côté moteur : regrouper les poussées de la frame, puis la poussée finale au relâché
     (comme `previewFade`, qui n'écrit que deux doubles dans `ObjWindowFadePlugin`).
   - Risque : un appel du lot qui relit `laneEntries` ou un cache en cours de lot.
     `openCrossfade` relit `crossfadeZone(leftID:rightID:)` après ses écritures, donc vérifier
     que cette lecture ne dépend pas de `laneEntries` reconstruit, ou la sortir du lot.
2. **A2** :
   - plafonner les échantillons d'une courbe à `min(Int(w), 128)` (une courbe `a^p` sur
     128 points est indiscernable à l'œil) ;
   - mettre en cache les paths normalisés (0…1 × 0…1) par `(FadeCurve, nbÉchantillons)`,
     puis les transformer avec un `CGAffineTransform` par zone : plus aucun `pow` en régime
     établi.
3. **A3** : un seul `crossfadeSharedPx` par bloc, avec une variable locale. Dans `crossfadeHit`,
   ne tenter `fadeHandleOverhang` que si l'objet a un partenaire de crossfade
   (`crossfadePartnersCache`), ce qui est déjà le cas d'emploi.

### Tests

- Pur : `tools/test_crossfade_curve_cache.swift`. Le path en cache transformé doit coïncider
  avec le path calculé point par point (écart < 0,5 px) pour les 5 familles × 3 courbures ×
  largeurs 4 / 64 / 900 px.
- Compteur : ajouter au `TimelineRegimeMeter` (ou à `perf.frames`) le nombre de
  `rebuildLaneEntries` par frame de drag. Attendu : 1 après A1, au lieu de 6K.
- Bench (à lancer par l'utilisateur ou hors de sa session) : scène « 300 crossfades » en
  Release, `perf.frames` pendant un scroll horizontal et pendant un drag de crossfade avec 1
  puis 10 zones sélectionnées. Comparer l'archive du 30/09, HEAD, puis HEAD + A1 et
  HEAD + A1 + A2.
- Non-régression : `test_crossfade_grab.swift` 38, `scenario_crossfade_grab.py`.

Question à poser à l'utilisateur : le lag apparaît-il au SCROLL, au SURVOL, ou pendant le
DRAG d'un crossfade ? Avec plusieurs objets sélectionnés ? Cela départage A1, A2 et A3.

---

## B — « La règle BPM n'a plus les mêmes divisions »  (PRIORITÉ 4, enquête)

### Constat

Je n'ai trouvé **aucun changement de code** sur les divisions :

- `objekat/Timeline/TimeRulerView.swift` n'a pas été touché par la migration. Depuis
  `b88fbed3~1`, son seul ajout est `RulerSelectionBand`. Sa logique de divisions est
  inchangée depuis `e5496d78` (10/08, `BarLadder` adaptatif).
- `EditViewModel.gridLevels` (`EditViewModel.swift` ~l.1098-1139) est inchangé.
- Les seuils (`EditViewModel+Types.swift` ~l.205-250 : `bpmGridThresholdPx` 24,
  `gridMajorThresholdPx` 48, `barGhostThresholdPx` 10, `BarLadder` [1,4,8,16,32,64],
  `TimeLadder`) sont inchangés.
- Le Canvas de grille (`TimelineView.swift` ~l.559-593) est identique à l'ancien.
- `git diff 5aa4e40d HEAD` ne touche ni au tempo, ni au chiffrage, ni à `gridMode`,
  `gridLevels` ou `snapGrid`.

### Explications possibles, à départager

1. Un **zoom différent** : le viewport est persisté dans le projet, et les paliers de
   `BarLadder` changent de niveau selon les px par mesure.
2. Un **tempo ou un mode de grille** différents dans le projet ouvert.
3. Le **snap coupé** : la grille passe en pointillés, et en mode temps la règle n'affiche plus
   les lignes de snap.
4. La bande de sélection de règle (`6febe4e0`, déjà dans l'archive) qui recouvre des libellés.
5. Une comparaison avec une version plus ancienne que le 30/09.

Hypothèse non exclue, pour être complet : un `cullScrollX` / `cullViewportWidth` passé à
`TimeRulerView` qui tronquerait les libellés en bord de viewport. À vérifier sur capture.

### Plan

- Demander à l'utilisateur deux captures, archive du 30/09 et HEAD, **même projet, même
  zoom** (lire `view.state` → `pps` dans les deux), plus le tempo et l'état du snap.
- Test pur pour geler le comportement : `tools/test_ruler_divisions.swift`, une table
  `pps → niveaux de gridLevels` (4/4 à 120 BPM et 7/8 à 93 BPM) sur 10 zooms. Si un écart
  est un jour introduit, il cassera ici.
- Pas de correctif tant que la capture comparée n'a pas montré une différence au même `pps`.

---

## Récapitulatif

| Point | Cause | Origine | Gravité | Effort |
|---|---|---|---|---|
| D | ligne finale reconstruite sans `extraAbove` + lane d'affichage passée comme lane modèle (DragHandler ~l.1328 et suivantes) | préexistant (juin 2026) | perte de matière | moyen (1 fichier + 1 module pur) |
| C | `handleMarkerBandDrag` ignore le vide ; le clic sur le vide ne déplace pas le curseur | préexistant (geste jamais fait) | ergonomie | petit |
| A | drag : 6K rebuilds O(N) par frame sans lot (aggravé le 01/10) ; Canvas : 2×512 `pow` par zone à chaque body | migration + 01/10 | performance | petit (A1) à moyen (A2) |
| B | aucun changement de code trouvé | — | à confirmer | enquête |
