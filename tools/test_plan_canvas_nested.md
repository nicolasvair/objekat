# Plan de test — timeline Canvas × groupes imbriqués (branche `feat/canvas-selected-clips`)

Rédigé le 2026-10-02 par l'architecte, pour l'agent de test. Base testée : HEAD `7b1b1df2` + le commit
qui ajoute ce plan (`view.snapshot`, `tools/scenario_canvas_nested.py`).
Budget : **≤ 2 h**, dont ~25 min de marge. Chaque bloc ≤ 10 min. **On rapporte, on ne corrige pas.**

---

## 0. Ce qui a changé par rapport aux deux plans d'origine

Le plan de l'utilisateur (3–4 niveaux, drag entre niveaux, crops, perfs, scénarios inédits, peu de
variations) et le plan du premier agent (représentation / drags / outils / cas limites) ont été
fusionnés. Voici ce qui a été modifié :

| Point d'origine | Décision | Raison |
|---|---|---|
| « bus infini DANS un groupe » | **remplacé** par un GROUPE infini top-level (G8) contenant un aux | Impossible par conception : un aux infini dans un groupe est refusé (« an infinite bus is top level only »). |
| « crossfade traversant un niveau » | **remplacé** par crossfade entre frères dans un groupe ouvert profond + un drag qui fait sortir l'un des deux | `CrossfadePartnerFinder` (E8) apparie par conteneur. Une paire à cheval sur deux niveaux n'existe pas. Le vrai risque est la paire en cache pendant un drag qui reparente. |
| Comparaison à pps 5 / 50 / 400 × clair / sombre × scrolls | **réduit** : 3 pps × 3 sélections, plus un viewport défilé, en clair seulement | Le sombre est invérifiable : `cacheDisplay` rend selon l'apparence courante, et forcer le sombre change un réglage système. |
| Comparer à « l'ancienne version » pour le visuel | **réservé à la perf de navigation** (archive `/Applications/objekat.app`) ; le visuel se compare **dans le même build** (Canvas vs `debug.force_rich_*`) | L'archive n'a ni `input.drag`, ni `debug.*`, ni `view.snapshot`. Une référence avec drag existe, mais elle coûte un build (§6, optionnel). |
| Peu de variations | **1 geste par risque**, 9 drags + 4 ciblés | Chaque test vise une ligne de code nommée en §2. |
| Pas de capture d'écran | **`view.snapshot`** (Debug), méthode `cache` | Validé : la méthode `window` rend une image vide (1 couleur) ; `cache` et `layer` montrent le Canvas. |
| Ajouts | hit-test en zone masquée, composite profond (chargement des formes d'onde), drag de crossfade dans un groupe ouvert, undo en UNE étape, modèle intact avant le release | Ces risques manquaient dans les deux plans (§2). |

---

## 1. Préconditions (bloquantes) — T0, 10 min

1. **Écran réveillé et déverrouillé, app au premier plan.** `input.drag` refuse avec
   `invalid_state: the timeline's window is not key` sinon. **C'est arrivé à chaque essai de
   l'architecte** : la fenêtre n'était pas key, et `open objekat.app` n'a pas suffi. Le drag n'a donc
   **pas été validé de bout en bout**. Avant tout drag :
   ```sh
   caffeinate -u -t 7200 &          # écran éveillé pendant la session
   open build/dd/Build/Products/Debug/objekat.app   # ramène l'instance au premier plan
   ./objekat_cli.py --socket /tmp/cc501/t.sock input.selftest   # doit répondre ok
   ```
   Si `input.selftest` ou le premier drag reste en `invalid_state` après 2 essais : **arrêter les
   §4–§5 et le signaler**. Le plan B est structurel (§3 + census + modèle seulement).
2. Build Debug (incrémental, ~10 s) :
   `xcodebuild -project objekat.xcodeproj -scheme objekat -configuration Debug -derivedDataPath build/dd build`
3. Lancer en **mode UI** (jamais `--headless` : rien n'y est dessiné) :
   `build/dd/Build/Products/Debug/objekat.app/Contents/MacOS/objekat --api --no-recent --no-audio --socket=/tmp/cc501/t.sock &`
4. Construire la scène (≈ 1 min) et vérifier le census :
   `python3 tools/scenario_canvas_nested.py /tmp/cc501/t.sock build --scene /tmp/cc501/nested/scene.json`
   Attendu après ouverture : `max_group_depth` 3, `clips_canvas` 10, `groups_canvas` 8,
   `groups_rich` 1 (le groupe infini G8), `group_bands_canvas` 6.
5. Vérifier une capture : `view.snapshot {"path":"/tmp/cc501/nested/t0.png"}`. Il faut
   `distinct_colors` > 50 et `dominant_fraction` < 0,9. Ouvrir le PNG (Read) et y reconnaître des
   blocs et des formes d'onde.

**Rappels sur l'API (pièges déjà rencontrés)**
- `object.add.lane` est une lane **d'affichage** : avec un groupe ouvert au-dessus, l'objet
  atterrit DEDANS.
- `object.list` et `object.get` ne voient que les objets de lanes visibles ; un enfant d'un groupe
  fermé donne `not_found`. Pour l'arbre complet : `project.get_state` → `items[*].kind.children`.
- `object.set_mute` prend `{"ids":[…],"muted":true}`.
- `view.snapshot` existe en Debug seulement ; utiliser la méthode `cache` (défaut).
- Le ⌥ ne peut pas être synthétisé : utiliser `debug.set_opt_held {"held":true}` avant le drag.

## 2. Scène et carte des risques

La scène (`scenario_canvas_nested.py build`) contient, sur 4 niveaux :

```
G1 (ouvert) ─ A1 ⨯ A2 (crossfade 0,5 s)
           └ G2 (ouvert, recadré à 4 s, B1 dépasse jusqu'à 7 s → masque hors-plage)
               ├ B1
               ├ L1 (groupe BOUCLÉ, muet, fermé) ─ B2
               └ G3 (ouvert, couleur 9) ─ C1 (couleur 5, fades bombés)
                                         ├ G4 (fermé) ─ D1, D2 (MIDI)
                                         └ X1 (aux)
G5 (0..2 s) ─ N1 (start −2 s), G6 (−2 s) ─ N2 (−2 s)       ← temps négatifs
G8 (INFINI) ─ E1, E2 (aux)
P1 (clip racine)    G9 (fermé) ─ Q1, Q2
```

Un fichier wav distinct par profondeur (`depth0..4.wav`), pour voir quelles formes d'onde sont
chargées.

Risques classés (★★★ = plausible et grave). La colonne « Test » renvoie aux §3–§5.

| # | Risque | Où | Test |
|---|---|---|---|
| R1 ★★★ | Le release d'un drag entre niveaux reparente mal, ou laisse un modèle partiel ; l'undo demande plusieurs étapes | `TimelineView+DragHandler.swift` ~1300–1440 (`groupDropEntry`, garde `droppedOnOwnSubtree` l.1334, `reparentChildBetweenGroups` `EditViewModel+Groups.swift:739`, `ejectFromGroup` :688, `reparentToGroup` :641) | D1, D2, D3 |
| R2 ★★★ | L'aperçu Canvas diverge de l'aperçu riche pendant un trim / resize / fade d'un enfant profond (géométrie E7) | `BlockPreviewGeometry.swift` ; `previewOffset` DragHandler l.1599 | D4, D5, D6, D9 |
| R3 ★★★ | Un crossfade dans un groupe ouvert est tiré en temps ABSOLU alors que `openCrossfade` (`EditViewModel+Crossfade.swift:353`) travaille dans le temps du conteneur → fade décalé de `absStart` du parent. **Probablement un des « bugs de groupes imbriqués » de l'ancienne version** | `TimelineView+CrossfadeDrag.swift:453`, DragHandler l.1045 | C1 |
| R4 ★★ | Paires de crossfade (cache E8) figées pendant un drag qui sort A2 de G1 : voile ou couture fantôme au release | `CrossfadePartnerFinder`, `rebuildLaneEntries` `EditViewModel.swift:950` | D7 |
| R5 ★★ | Partition : un bloc part en riche sans raison, ou un groupe ouvert profond est mal classé | `partitionVisibleBlocks` `TimelineView.swift:2771`, `groupRichReason` :2976, `clipRichReason` :3048 | §3, census |
| R6 ★★ | Composite d'un groupe fermé à plusieurs niveaux sans formes d'onde profondes : `ensureWaveformsLoaded` (:3105) et `.onAppear` riche ne chargent que les enfants clips DIRECTS | `GroupWaveformView.swift:82` (`expand`) | W1 |
| R7 ★★ | Hit-test : l'index E4 rend le PREMIER du modèle, alors que le dessin met le sélectionné au-dessus → un clic dans un chevauchement vise un autre objet que celui vu ; le survol d'une zone masquée vise l'enfant caché | `EditViewModel+LaneEntryIndex.swift:19` (cache validé par le seul `count`), `sendClipHits` DragHandler l.2027 (ordre changé en 3bdbb0b5) | H1 |
| R8 ★★ | Fantômes ⌥ : construits depuis `laneEntries` en `displayLane 0` + `dy`, groupe forcé fermé → mauvais Y pour un enfant profond, ou un groupe ouvert dont le fantôme montre ses enfants | `altGhostsLayer` `TimelineView.swift:3624`, `altDragGhosts` DragHandler l.1644 | A1 |
| R9 ★ | Masques hors-plage et bandes d'un groupe ouvert déplacé : ils ne suivent pas l'aperçu (vrai dans les DEUX régimes, donc probablement préexistant) | `rangeMasksCanvas` `TimelineView.swift:2163` | D3 (observer, ne pas classer en régression) |
| R10 ★ | Temps négatifs : enfant à −2 s dessiné ou tiré au mauvais endroit | `buildLaneEntries` `EditViewModel.swift:1011` | D8, §3 |
| R11 ★ | Culling vertical par paliers de 512 px : scintillement de la frange haute en remontant | `refreshCullWindow` `TimelineView.swift:4815` | **invérifiable** sans écran (§7) ; perf §5 seulement |

## 3. Représentation — Canvas vs riche, 10 min

```sh
python3 tools/scenario_canvas_nested.py /tmp/cc501/t.sock snap --scene /tmp/cc501/nested/scene.json --out /tmp/cc501/nested/snap
```

Le script prend pps 5 / 50 / 400 × sélections `none` / `mixed` (A1, C1, G3) / `deepchild` (B1), en
Canvas puis avec `debug.force_rich_blocks`. Il fait la même chose pour les outils Volume / Pan / Aux
(`tool.set`, Canvas vs `debug.force_rich_tools`), plus un viewport défilé (`scrolled_mid`). Il
écrit `*_canvas.png`, `*_rich.png`, `*_diff.png` (rouge = écart > 24/255) et `snap_report.json`
(fraction de pixels différents, bbox).

**Critères.**
- `diff_fraction` ≤ 0,5 % : OK.
- Au-delà : ouvrir les 3 PNG (Read) et nommer l'élément fautif (z-order, couleur, fade, composite,
  bande, masque, libellé, bord ou halo de sélection, motif de boucle, damier aux).
- Avec `force_rich_blocks`, seuls les clips **sélectionnés**, les blocs de groupe et les bandes
  changent de régime ; un écart sur un clip non sélectionné est donc suspect.
- L'antialiasing des libellés donne quelques pixels isolés : ce n'est pas une anomalie si la bbox
  fait moins de 3 px de haut.

**À regarder à l'œil sur `t50_none_canvas.png`.**
- Le masque du recadrage de G2 sur la fin de B1.
- La couture du crossfade A1 / A2.
- G4 fermé avec le composite de D1 + D2.
- L1 bouclé, muet et grisé.
- X1 / E2 en damier.
- N1 / N2 coupés au bord gauche (temps négatif).
- G8 (infini) en bande pleine largeur.

Le census accompagne chaque capture (`perf.census.regimes`). Critère : `rich_reasons` vide sans
sélection ni outil (hors `infinite` pour G8).

## 4. Gestes réels — 35 min

```sh
python3 tools/scenario_canvas_nested.py /tmp/cc501/t.sock drag --scene /tmp/cc501/nested/scene.json --out /tmp/cc501/nested/drag
# un sous-ensemble : --only D1,D4
```

Pour chaque cas, le script suit cette séquence :
1. Rouvrir la scène et faire `view.reveal` sur la cible.
2. Trouver la zone avec `input.hover` + `view.state.hover` (zone ET id doivent correspondre, sinon
   `ERROR zone not found` : à rapporter, c'est déjà un résultat sur le hit-test).
3. Lancer `input.drag {…, "release": false}`.
4. Sous le geste, relever `rich_reasons` et vérifier que **le modèle est inchangé** (le
   `project.get_state.items` doit être identique à celui d'avant).
5. Prendre la capture Canvas vs `debug.force_rich_previews` et calculer le diff.
6. Faire `input.release`, relever le diff de l'arbre et prendre une capture.
7. Faire **un seul** `edit.undo` : l'arbre doit être **identique** à celui d'avant.

| Cas | Geste | Attendu après release |
|---|---|---|
| D1 | C1 (niv. 3) déplacé de 60 px et +2 lanes | C1 change de parent ou de lane comme le désigne `groupDropEntry` (groupe ouvert le plus profond contenant la lane) ; temps absolu += 60/pps |
| D2 | B1 posé sur la ligne de G9 **fermé** | B1 sort de G2 (un groupe fermé n'accueille pas : vérifier `parent`) ; aucun objet perdu |
| D3 | G2 (groupe contenant des groupes) déplacé de 80 px | Tout le sous-arbre G2 se décale de 80/pps, profondeurs inchangées. **Pendant l'aperçu** : enfants, bandes et masques ne suivent pas (R9). C'est à noter, mais non bloquant si c'est identique en riche |
| D4 | C1 trimLeft +25 px | début +25/pps, fin fixe, offset source + (25/pps × vitesse) |
| D5 | C1 resizeRight −30 px | fin −30/pps, début fixe |
| D6 | G3 trimLeft +30 px | la fenêtre de G3 se rétrécit, les enfants ne bougent pas en absolu |
| D7 | A2 (en crossfade avec A1) déplacé de 40 px | la paire suit ou se défait proprement ; aucun voile résiduel sur la capture d'après ; fades cohérents |
| D8 | N1 (start −2 s) déplacé de 50 px | start = −2 + 50/pps, rien n'est clampé à 0 |
| D9 | C1 fadeIn +20 px | fadeIn = 20/pps, rien d'autre ne change |

**Critères communs.**
- Modèle inchangé pendant le drag.
- Diff Canvas / riche de l'aperçu ≤ 0,5 %.
- Undo en UNE étape revient à l'identique.
- Aucun objet perdu (compte total d'objets constant).

Ajouts ciblés (5 min chacun, à la main via `objekat_cli.py`, en reprenant les helpers du script) :

- **A1 — ⌥-copie d'un enfant profond.**
  - Étapes : `debug.set_opt_held {"held":true}`, drag de C1 de 60 px avec `release:false`, puis
    `view.snapshot`.
  - Pendant le drag : le fantôme doit être à la lane de C1 + dy, pas en lane 0 (R8).
  - Après le release : une copie avec un id neuf ; l'original intact ; un seul undo retire la
    copie.
  - Recommencer avec G3 (groupe ouvert) : le fantôme doit apparaître comme un groupe fermé.
  - Remettre `held:false` à la fin.
- **C1 — drag de crossfade dans un groupe ouvert (R3).**
  - Étapes : sur G2 ouvert, `object.move` de B1 pour qu'il touche un frère (ou utiliser A1 / A2
    dans G1 si G1 commence à > 0 s) ; décaler G1 de +3 s avant le test, sinon absolu = relatif et
    le bug reste invisible. Puis survoler la couture, tirer de 30 px et relâcher.
  - Critère : la couture du crossfade est sous le curseur. `fadeOut` et `fadeIn` valent 30/pps,
    centrés sur le point tiré. Un décalage égal au `startTime` du parent signe R3 (bug
    **préexistant**, à reproduire aussi sur l'archive si possible, en clic manuel par
    l'utilisateur).
- **H1 — hit-test (R7).**
  - Survoler (`input.hover` + `view.state.hover`) :
    - le milieu de la partie masquée de B1 (entre 4 s et 7 s, hors de la fenêtre de G2) : attendu
      `hovered_id` = G2 ou rien, **jamais B1** ;
    - un point de chevauchement entre deux objets dont l'un est sélectionné : attendu = celui
      dessiné au-dessus. Sinon, c'est l'écart connu, à consigner sans plus.
- **W1 — composite profond (R6).**
  - Étapes : fermer G1 (`group.expand {"id":…,"expanded":false}`),
    relancer l'app, rouvrir la scène, `wait_idle`, puis lire `perf.waveforms`.
  - Critère : `depth3.wav` et `depth4.wav` (D1 sous G4 sous G3 sous G2) sont chargés, et la
    capture de G1 fermé montre de l'énergie sur toute la plage de G2 / G3.
  - Comparer avec `debug.force_rich_blocks` : si les deux régimes omettent la même chose, c'est
    préexistant.

**Parité projet** (5 min) : `python3 tools/scenario_parity_project.py /tmp/cc501/t.sock`. Critère :
les sections A / B sont identiques avec le switch A/B.

## 5. Perf scroll / zoom — 25 min (Release)

**Protocole.**
- Build Release : `-configuration Release`, même `-derivedDataPath build/dd`.
- Lancer en mode UI avec `--no-audio`, sous `caffeinate -u`, app au premier plan, mains hors du
  trackpad. Un pas `contaminated` est rejoué.
- Fenêtre de même taille pour A et B : `debug.resize_window` n'existe qu'en Debug ; en Release,
  vérifier `view.state` (`viewport`) et noter la taille.
- Même session, à la suite, l'une après l'autre (jamais en parallèle).

**Étapes.**
1. Scène : `scenario_canvas_nested.py <sock> perf-scene --pieces 480 --out /tmp/cc501/perf`.
   - Si `debug.*` manque en Release, construire la scène avec l'instance Debug.
   - Résultat : `perf_nested_480.objekat`, ~480 clips en paires et trios de groupes, tous
     dépliés, sur 3 niveaux.
2. **B (Canvas, Release HEAD)** : ouvrir `--project=<…>/perf_nested_480.objekat`, puis
   `bench_navigation.py <sock> --label canvas --out canvas.json`.
3. **A (archive pré-migration)** : `/Applications/objekat.app` (Release du 30 septembre, avec
   `view.*`, `input.scroll`/`zoom` et `perf.frames`), même projet. Commande :
   `bench_navigation.py <sock> --label archive --out archive.json`.
   - Si l'archive refuse le fichier (format), le signaler et comparer seulement à
     `debug.force_rich_blocks` dans un build Debug (moins représentatif).
4. `bench_navigation.py --compare archive.json canvas.json`.

**Seuils d'alerte.** Un écart est réel s'il dépasse le bruit d'une deuxième passe (refaire B une
fois).
- **Régression** : fps médian du zoom horizontal < archive × 0,8, OU p95 de frame > archive × 1,5,
  OU fps < 30 au zoom à 480 objets. Référence mémoire : 14,5 fps / p95 159 ms à 480 objets plats
  AVANT migration.
- **Gain attendu** : ≥ archive sur scroll et zoom.
- `perf.census` en fin de B : `clips_rich` ≈ 0 et `groups_rich` ≈ 0 sans sélection ;
  `foreach_layers` ne doit pas croître avec N.

## 6. Référence pré-migration avec drag (OPTIONNEL, si marge > 25 min)

La branche `ref/pre-canvas-api` = `0dfe06bf` (pré-migration) + `tool.set`/`view.state.hover` +
`input.drag`. Elle n'a **pas** `view.snapshot` ni `debug.force_rich_*` ; elle n'a pas été buildée.

```sh
git worktree add /tmp/cc501/refwt ref/pre-canvas-api
git -C /tmp/cc501/refwt cherry-pick <commit de ce plan>   # pour view.snapshot + le script (conflits : garder la version du commit)
rmdir /tmp/cc501/refwt/tracktion_engine && ln -s "$PWD/tracktion_engine" /tmp/cc501/refwt/tracktion_engine   # moteur identique
xcodebuild -project /tmp/cc501/refwt/objekat.xcodeproj -scheme objekat -configuration Debug -derivedDataPath /tmp/cc501/ref-dd build   # 10–20 min, LANCER EN ARRIÈRE-PLAN AU T0
```

Usage : rejouer **D1, D2, D7 et C1** sur la référence. Si l'anomalie existe aussi, elle est
**préexistante** ; sinon c'est une **régression Canvas**. Ne lancer ce build qu'en arrière-plan
dès le T0 ; s'il échoue, abandonner sans y passer de temps. Supprimer le worktree à la fin.

## 7. Invérifiable sans écran (à dire, ne pas inventer)

- Apparence **sombre** et clair/sombre basculé en cours de session.
- **Scintillement** et frames intermédiaires : culling `cullScrollY` en remontant, snap vertical
  animé, bord des paliers de 512 px. `view.snapshot` ne voit qu'une image stable.
- Le **ressenti** de fluidité (les fps mesurent le rendu, pas la latence perçue du geste réel).
- Curseurs (I-beam, trim directionnels) et cheatsheets.
- L'archive pour les gestes : elle n'a pas `input.drag`. La comparaison des gestes passe par §6,
  ou par l'utilisateur à la main.
- Ce que montre la méthode `cache` n'est pas garanti identique au compositeur (elle ignore
  d'éventuelles couches Metal) ; `window` est vide sur cette machine.

## 8. Ordre, temps et règle d'arrêt

| Ordre | Bloc | Temps |
|---|---|---|
| 1 | T0 préconditions + build + scène + 1 capture (+ build ref §6 en arrière-plan si choisi) | 10 min |
| 2 | §4 D1, D2, D3 (R1, le plus grave) | 12 min |
| 3 | §4 C1 (crossfade dans un groupe ouvert, R3) | 5 min |
| 4 | §4 D4–D9 | 15 min |
| 5 | §4 A1, H1, W1 | 15 min |
| 6 | §3 représentation | 10 min |
| 7 | Parité projet | 5 min |
| 8 | §5 perf Release A/B | 25 min |
| — | marge | ~20 min |
| | **Total** | **≤ 2 h** |

**Règles d'arrêt.**
- Un **crash**, une **perte d'objet** ou un undo qui ne revient pas à l'identique : arrêter le
  bloc. Consigner (commande, arbre avant / après, capture), puis passer au bloc suivant **sur
  une scène rechargée**.
- **Deux crashs** : arrêter la session et rapporter.
- **`invalid_state` (fenêtre non key)** persistant après 2 essais : sauter §4, faire §3, la
  parité et §5.
- Un bloc qui dépasse son temps × 1,5 : l'abandonner, le noter et passer au suivant.

**Pour chaque anomalie.**
1. La reproduire une fois.
2. Comparer avec le régime riche (même build). Si l'écart est identique dans les deux régimes, ce
   n'est pas le Canvas : c'est un bug du modèle ou des gestes, préexistant ou non. Pour trancher,
   utiliser la §6.
3. Sauvegarder un cas minimal dans `tools/canvas_nested_cases/<id>.py` (scène + geste + critère).
4. **Ne rien corriger.**

**Fin de session** : tuer toutes les instances (`pkill -f "socket=/tmp/cc501/"`), retirer
`caffeinate`, `git worktree remove` si §6. Ne rien pousser.
