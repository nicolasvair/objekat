# Plan — ARA / Melodyne sur les objets audio

Statut : PLAN, rien n'est codé (2026-10-08). Base : `main` à `65f76eb8`, moteur fork à `1508f752f62`
(`objekat-bridge-0037`). Prochain patch moteur libre : **0038**.

Branches proposées :
- dépôt objekat : `feature/ara-melodyne` (depuis `main`) ;
- fork moteur `tracktion_engine/` : `objekat-ara-0038` (depuis `1508f752f62`), puis fast-forward de
  `objekat-patches-3.5` au merge, publication par `tools/publish-engine-forks.sh`, gitlink réaligné.

---

## 0. Ambiguïtés qui changent l'architecture (à trancher AVANT l'étape 4)

Je ne les tranche pas en silence. Pour chacune : l'option que je recommande, et ce que l'autre coûte.

> **RÉPONSES DE L'UTILISATEUR (2026-10-08)** — elles l'emportent sur les « recommandé » ci-dessous.
> - **Q1** : le ⌘Z d'OBJEKAT ne touche JAMAIS les retouches Melodyne (option recommandée) ; l'archive ne
>   sert qu'à la recréation (retrait / suppression / collage annulés).
> - **Q2** : PAS de jumelage AU → VST3. Seul Melodyne VST3 sert de source ARA ; Melodyne AU reste un
>   plugin normal, non-ARA (ni détection par tag ARA des AU, ni résolution de jumeau).
> - **Q3** : une instance par objet, on mesure (option recommandée).
> - **Q4** : accepté tel quel en v1 (pas d'audition transport arrêté garantie).
> - **Q5** : boucles refusées en v1 sur un objet Melodyne et sur un groupe en boucle qui en contient un.
> - **Consolidé** : un objet consolidé ne peut PAS porter Melodyne.

**Q1 — Le ⌘Z d'OBJEKAT annule-t-il des retouches faites dans Melodyne ?**
Aujourd'hui, `currentSnapshot()` relit l'état de TOUS les plugins à chaque `pushUndo`, et
`applySnapshot` recrée tout objet dont l'état diffère. Appliqué tel quel à l'archive ARA :
« je déplace un objet, je retouche 20 notes dans Melodyne, ⌘Z » ramènerait l'objet ET effacerait les
20 notes (un ⌘⇧Z les rendrait). Dans ce cas, le ⌘Z annule plus que le geste qu'on vient de faire.
- **(b) recommandé** : le ⌘Z d'OBJEKAT ne touche JAMAIS aux retouches d'un objet dont la source
  Melodyne est vivante : c'est l'historique de Melodyne (son propre ⌘Z, dans sa fenêtre) qui les
  gère. L'archive du snapshot ne sert qu'à RECRÉER une source absente : annuler la suppression de
  Melodyne ou de l'objet, annuler un collage, etc. Concrètement, l'égalité différentielle ignore
  `araSource.archive` quand l'identifiant du plugin source est le même des deux côtés, et un objet
  recréé pour une autre raison reprend l'archive VIVANTE capturée juste avant sa destruction.
- (a) : on ne fait rien de spécial (même règle que les autres plugins). Ça ne coûte rien à coder,
  mais on peut perdre des retouches sans s'en apercevoir.

**Q2 — Melodyne AU.** L'hôte ARA de Tracktion ne sait charger que du **VST3**
(`tracktion_ARAPluginFactory.h:318-347` : seul `"VST3"` a une fabrique). Melodyne est installé en
AU (`Melodyne.component`, tag `ARA`) ET en VST3 (5.4.2).
- **Recommandé** : l'entrée AU de Melodyne dans le « + » d'un objet audio est routée vers sa jumelle
  VST3 (même nom, même éditeur). L'utilisateur choisit « Melodyne » sans se soucier du format. Si
  aucune jumelle VST3 n'existe, l'entrée est grisée avec sa raison.
- L'alternative, c'est-à-dire écrire la fabrique AU dans le patch moteur, demande nettement plus de
  travail moteur (la propriété `kAudioUnitProperty_ARAFactory`, l'instanciation AUv2 sur le thread
  principal, les pièges AU déjà connus). Je la garde pour plus tard.

**Q3 — Une instance Melodyne par objet.** Dans la conception de Tracktion, chaque clip ARA possède
SA propre instance de plugin (toutes liées au même document ARA). Une voix coupée en 40 morceaux
donne donc 40 instances (mémoire, temps d'instanciation au chargement, CPU). La v1 garde ce modèle
natif (c'est ce que (C) suppose : une modification par région, clonée à la copie). L'étape 3
**mesure** le coût (RSS et temps de chargement pour 1, 10 et 40 objets). Si c'est rédhibitoire, il
faudra une v2 avec une instance par séquence, ce qui serait une refonte de la partie ARA de
Tracktion. À valider : est-ce acceptable de commencer ainsi ?

**Q4 — L'écoute de Melodyne transport arrêté (clic sur une note dans son éditeur).** Le patch B
(ci-dessous) fait passer le nœud ARA par le `CombiningNode`, comme tout clip : c'est ce qui le rend
audible dans un groupe et le soumet aux rangs du pont audio. Contrepartie probable : Melodyne n'est
rendu que lorsque la tête de lecture est dans la fenêtre de l'objet (± head/tail). L'aperçu d'une
note cliquée, transport arrêté hors de l'objet, risque donc d'être muet. Tracktion évitait ça en
sommant les nœuds ARA au niveau de la piste, en dehors de tout, mais ce chemin ne marche ni dans un
groupe ni avec le pont.
- **Recommandé** : accepter en v1. Si l'oreille de l'utilisateur dit que c'est gênant : tant que
  l'éditeur ARA d'un objet est ouvert, on marque ce clip « toujours actif » (un drapeau lu par le
  `CombiningNode`, petit patch).

**Q5 — Les boucles.** `ARANode` lit la tête de lecture de l'EDIT, pas celle, locale et repliée,
d'un container. Un objet Melodyne dans un groupe EN BOUCLE ne suivrait donc pas le repli.
**Recommandé pour la v1** : refuser la boucle sur un objet Melodyne, refuser d'ajouter Melodyne
dans un groupe en boucle, et refuser de mettre en boucle un groupe qui contient un objet Melodyne.
Le patch D (le nœud ARA suit le `ProcessState` local) est reporté à l'étape 11. Cela prolonge la
décision 6 : « Melodyne possède le temps ».

**Q6 — La fixture « retouchée » (pour les tests).** Aucune API hôte ne permet de modifier une note
Melodyne par script. Pour PROUVER automatiquement que les retouches survivent (sauvegarde, copie,
consolidation, onglets), il faut **une fois** un projet témoin où l'utilisateur a monté une note de
+7 demi-tons à la main. Le scénario mesure ensuite la hauteur de l'export (220 Hz → 329,6 Hz).
Recommandé : ce projet vit HORS du dépôt (`~/Library/Application Support/Objekat/test-fixtures/ara_retouched/`,
l'archive est une donnée propriétaire de Melodyne), et le bloc correspondant passe en SKIP s'il est
absent.

### Choix mineurs pris (l'option la plus simple, à contester si besoin)
- Melodyne ne se pose que sur un **objet audio** (`.clip`). Sur un groupe, un aux, un objet MIDI ou
  un stem, ou sur une **instance consolidée** (décision 5), l'entrée ARA du « + » est grisée avec sa
  raison. On ne propose pas Melodyne en insert non-ARA (mode « transfert »).
- À l'ajout : refus (avec raison) si vitesse ≠ 1, objet inversé, boucle active, fichier manquant, ou
  compressé sans proxy décodable (à vérifier, voir étape 7). On refuse plutôt que de « remettre à
  zéro » : rien ne change derrière le dos de l'utilisateur.
- Un objet porte **une seule** source ARA. Choisir Melodyne sur un objet qui en a déjà une → refus
  « déjà une source » (pas de remplacement implicite).
- **Pas de bypass** de la source en v1 : la carte n'a pas d'interrupteur, on retire Melodyne pour
  revenir au fichier brut.
- La carte Melodyne **ne se glisse pas** sur un autre objet (pas de déplacer / ⌥ / ⌘) : on ne copie
  qu'avec l'objet entier.
- **Jamais de link** : la source ARA n'a ni `linkGroupID` ni bac FX ; `rewireLinkGroups` et les
  liens FX ne la voient pas.
- L'**éditeur spectral** et toute opération qui REMPLACE le fichier source de l'objet sont grisés sur
  un objet Melodyne (l'archive serait réappliquée à un autre audio). Le relink d'un fichier manquant
  reste permis : c'est le même audio à un autre endroit.
- La forme d'onde reste celle du **fichier source** (décision 2 : aucun indicateur). Une retouche
  temporelle dans Melodyne n'y apparaît pas. C'est une limite connue, notée pour plus tard.

---

## 1. Ce que la lecture du code confirme ou corrige dans le constat

Confirmé :
- `TRACKTION_ENABLE_ARA 0` (`modules/tracktion_engine/tracktion_engine.h:96`). Tout le code ARA est
  derrière ce drapeau : `plugins/ARA/*` (4631 lignes), `playback/graph/tracktion_ARANode.*`,
  `AudioClipBase` (setupARA, captureARAStateToValueTree, tearDownARA, getARAProxy), `Edit::getARADocument`.
- L'ARA est le MODE DE LECTURE du clip : `timeStretchMode == TimeStretcher::ara` +
  `araPluginDescription`. L'instance Melodyne (un `ExternalPlugin` HORS de toute plugin-list,
  `ARAPluginFactory::createPlugin`) remplace la lecture du fichier.
- Trou **A** : `createNodeForAudioClip` (`tracktion_EditNodeBuilder.cpp:489-501`) renvoie
  l'`ARANode` brut, donc ni plugin-list du clip ni fondu. Or toute la chaîne propre d'un objet
  (ObjChannelMode, trims, FX, ObjGain, ObjWindowFade, tap du pont) vit sur la plugin-list du CLIP
  (`installObjectChainTail`, `OBJEngineCore.mm:2442`).
- Trou **B** : l'ARA n'est bâti que par `createARAClipsNode` (l.1427), appelé depuis `createClipsNode`
  (l.1466) au niveau d'une PISTE. `createNodeForClip` (l.1174) passe `includeARA=false` : dans un
  `ContainerClip` (groupe), l'objet Melodyne est donc muet. Au passage, même en tête de piste, le
  nœud ARA est sommé À CÔTÉ du nœud de rang (`applyBridgeRank`, l.1462) : il échappe au pont 0037
  (rangs, égalisation de latence de lane, `getHead/getTail`).
- Le « patch local Objekat » `AudioClipBase::getHead/getTail` (`AudioClipBase.cpp:1194`) ajoute déjà
  la marge ARA à celle de la chaîne. Il est fait pour le cas où le nœud ARA est dans le `CombiningNode` :
  le patch B s'appuie dessus.

Corrigé ou ajouté (non vu dans le constat initial) :
1. **Trou C, un crash, pas seulement du silence.** `PlaybackRegionWrapper` déréférence
   `audioClip.getTrack()->itemID` (`tracktion_ARAWrapperInterfaces.h:1548, 1576`) et
   `willCreatePlaybackRegionOnTrack(clip.getTrack())` (l.455). Or `Clip::getTrack()` renvoie
   `nullptr` pour un clip dans un `ContainerClip` (`tracktion_Clip.cpp:331`, déjà contourné côté app
   par `objOwningTrack`, `OBJEngineCore.mm:2273`). Corriger B sans corriger C ferait planter tout
   groupe qui contient un objet Melodyne. Autre conséquence : le `trackID` d'une région est figé à sa
   création, donc un objet qui change de piste du pool (`setLane:`) ou entre dans un groupe
   (`moveClipToOwner`) garde une séquence de régions périmée.
2. **Persistance par objet : le mécanisme existe déjà.** `AudioClipBase::captureARAStateToValueTree()`
   écrit dans l'arbre du clip une archive PARTIELLE (celle de SA source et de SA modification,
   `storeObjectsForCopy`) : `araArchive` (base64), `araArchiveSourceID`, `araArchiveModID` et
   `araDocumentArchiveID`. `setupARA()` la consomme ensuite via `restoreARAArchiveForPaste`, qui
   transpose les identifiants archivés vers les identifiants courants. C'est exactement l'unité qu'il
   faut à notre modèle : une archive par objet, qui voyage avec lui (sauvegarde, presse-papiers,
   onglets, undo). Le document global `ARADOCUMENT` de l'Edit est **ignoré** : notre projet n'est pas
   l'Edit XML.
3. **Le scan d'OBJEKAT ne sait pas ce qui est ARA.** `scanPluginsWithCompletion:` (`OBJEngineCore.mm`
   ~l.5420) fabrique des `PluginDescription` sans charger les binaires, donc `hasARAExtension` est
   toujours faux et `PluginManager::getARACompatiblePlugDescriptions()` renvoie une liste vide. La
   vraie description vient de `findAllTypesForFile` (déjà fait par `resolvedPluginTreeForInfo:` pour
   VST3, l.7322 ; on ne l'appelle jamais sur un AU, c'est un piège connu). Avec `JUCE_PLUGINHOST_ARA=1`,
   le scan JUCE d'un VST3 renseigne `hasARAExtension`. Pour l'affichage du « + », on ne charge rien :
   le tag `ARA` des AU (`AVAudioUnitComponent.allTagNames`, sans instancier) marque le produit ; un
   VST3 est candidat si sa jumelle AU porte le tag ou si son `moduleinfo.json` déclare une classe
   `"ARA Main Factory Class"` (Melodyne VST3 n'a pas de `moduleinfo.json`).
4. **Les rendus passent par un CLONE d'Edit** (`_edit->state.createCopy()` + `loadEditFromState(forRendering)`,
   `OBJEngineCore.mm:3700, 4086`) : bake/consolidation, export, `object.render_isolated`. Deux
   problèmes :
   (i) l'arbre live du clip ne porte PAS l'archive (setupARA la retire après restauration), donc le
   clone ouvrirait un Melodyne VIERGE. Il faut tamponner l'archive dans la copie d'arbre avant de la
   charger ;
   (ii) `OBJRenderPluginFilter::wants` (`OBJEngineCore.mm:53`) refuse tout plugin sans clip ni piste
   parent, et l'`ExternalPlugin` ARA est justement sans parent. Le filtre bloquerait donc Melodyne
   dans un bake ciblé → consolidation muette.
   Le graphe du clone est bâti sur le thread principal (`callBlocking`, `tracktion_Renderer.cpp:47, 149`) :
   `setupARA` y est donc légal.
5. **Pas de SelectionManager Tracktion côté OBJEKAT** : `AudioClipBase::selectionStatusChanged` ne
   sera jamais appelé. Le focus de l'éditeur sur l'objet sélectionné passe donc par un appel explicite
   à `ARAFileReader::notifyViewSelection()`.
6. **Les fenêtres.** `ARAFileReader::showPluginWindow()` passe par la fenêtre Tracktion
   (`showWindowExplicitly`/`UIBehaviour`), qu'OBJEKAT n'utilise pas. L'éditeur Melodyne s'ouvre avec
   NOTRE `OBJPluginEditorWindow` (`_doOpenPluginEditor:`, l.~7020), sur l'instance
   `clip->getARAProxy()->getPlugin()`. Le test « UI visible » de Tracktion
   (`pi->getActiveEditor()->isShowing()`) marche avec notre fenêtre.
7. **Le transport demandé par Melodyne** (`requestStartPlayback` & co.,
   `tracktion_ARAWrapperFunctions.h:126-155`) appelle directement `TransportControl::play/stop/setPosition/setLoopRange`.
   Ça contourne le transport Swift (son état, sa boucle) : il faut un crochet (patch E).
8. **Prérequis du SDK.** Tracktion demande ARA SDK **≥ 2.3** (`BREAKING-CHANGES.md:487`). Il inclut
   `ARA_API/ARAVST3.h` et `ARA_Library/Dispatch/ARAHostDispatch.h`. JUCE (`JUCE_PLUGINHOST_ARA=1`)
   compile `ARA_Library/Dispatch/ARAHostDispatch.cpp` via `juce_ARAHosting.cpp` et veut
   `ARADebug.c` dans SA propre unité (`juce_audio_processors_headless_ara.cpp`).
9. **Licence.** L'ARA SDK est sous Apache-2.0, compatible (dans un sens) avec l'AGPLv3 du projet.
   NOTICE doit le mentionner.
10. **La lecture ARA est en temps EDIT.** Les régions se calculent sur la position du clip MOTEUR
    (`getPlaybackRegionProperties`, `ARAWrapperInterfaces.h:1627`) : début = `pos.getStart()`,
    début en temps de modification = `pos.getOffset()`. La convention « temps négatif » est donc
    respectée sans rien faire : `OBJEngineCore` traduit déjà la tête sous zéro en offset sur le clip
    moteur, et la région suit le clip moteur. Avec vitesse = 1 imposée (décision 6),
    `sourceOffset` (en secondes source) = offset de modification, sans conversion.

---

## 2. Architecture cible

```
Modèle Swift (SoundObject)                     Pont (OBJEngineCore)                    Moteur (Tracktion, fork + 0038)
───────────────────────────                    ─────────────────────                   ───────────────────────────────
araSource: ARASource?                          setARASource:archive:forObjectID:  →    clip.araPluginDescription = desc VST3 résolue
  .plugin  : ObjectPlugin (id, nom,            (état d'archive tamponné dans            clip.state[araArchive*] = archive
             identifier VST3, couleur)          l'arbre du clip AVANT setupARA)         clip.setTimeStretchMode(ara) ; setupARA(true)
  .archive : ARAArchive? (base64,              captureARAArchiveForObjectID:      ←    ARAFileReader::storeARAArchiveForCopy + IDs
             sourceID, modID, docArchiveID,    isARAArchiveStale (ChangeListener  ←    ARAFileReader::contentHasChanged (sendChangeMessage)
             octets)                            sur le proxy)
                                               removeARASourceForObjectID:        →    mode disabled, description vidée, props araArchive* retirées
                                               open/closeARAEditor…               →    OBJPluginEditorWindow(araProxy->getPlugin())
                                               notifyARASelection:                →    ARAFileReader::notifyViewSelection()
                                               araStatus/araAnalysedNotes         ←    isAnalysingContent / getAnalysedMIDISequence
                                               (rendus) objStampARAArchives(clone) →   arbre copié + filtre de rendu corrigé

Graphe (après 0038) : clip ARA → ARANode → plugin-list du clip (ObjChannelMode, trims, FX, ObjGain, ObjWindowFade, tap)
                      → FadeInOut → CombiningNode de la piste OU du container (rangs du pont, latence de lane, head/tail)
```

Présentation (décision 1) : dans le synoptique, la **zone « fichier audio »** de tête (celle de
vitesse / st / bpm / inversion / LR-L-R-C) reçoit un **emplacement source** sous ses contrôles. Il
fonctionne comme l'emplacement instrument de la zone MIDI (`SynopticLayout.instrumentSlot`,
`SynopticView.midiZoneView`) : une carte Melodyne fixe, toujours en tête, non déplaçable, au-dessus
du trim d'entrée et des FX. La flèche du signal part du fichier, traverse Melodyne puis descend dans
la chaîne. Le « + » de la chaîne propose Melodyne comme les autres plugins ; choisi sur un objet
audio, il atterrit dans cet emplacement (le « + » ne sait pas qu'il existe un emplacement à part).
Un double-clic sur la carte ouvre la fenêtre Melodyne, focalisée sur l'objet. On la retire comme
une carte FX (✕ / ⌫, un undo). Une roue discrète tourne sur la carte pendant l'analyse
(`isAnalysingContent`). Tant que la carte est là, vitesse / st / bpm / inversion / boucle de la zone
sont grisés avec une info-bulle « Melodyne gère le temps et la hauteur ».

Fraîcheur de l'archive : le moteur marque l'objet « archive périmée » à chaque notification de
contenu ARA (retouche, fin d'analyse). Swift ne relit l'archive (`storeObjectsForCopy`) que si elle
est périmée, et **toujours au même endroit** : `capturedPluginStates(_:)`
(`EditViewModel+Project.swift:605`). C'est par là que passent déjà sauvegarde, snapshot d'undo,
presse-papiers (`withCapturedPluginStates`), consolidation (sidecar `_objectstate.json`), parking
d'onglet et copie inter-projets. Un seul crochet couvre donc tous ces chemins.

---

## 3. Étapes

Règle générale : chaque étape compile en Debug, et `smoke.jsonl` passe à la fin de chacune. Une
étape qui touche le moteur produit le patch 0038 (amendé, pas empilé) et l'exporte aussitôt dans
`engine-patches/3.5/`.

### Étape 0 — Spike de compilation (SDK + drapeaux, rien d'autre)  · risque : MOYEN

Fichiers :
- SDK : deux sous-modules dans un dossier racine `ARA_SDK/` : `ARA_SDK/ARA_API` →
  `github.com/Celemony/ARA_API`, `ARA_SDK/ARA_Library` → `github.com/Celemony/ARA_Library`, tous deux
  au tag de la release **2.3.0** (ou la dernière 2.x si 2.3 n'existe pas en tag séparé). On ne met PAS
  le méta-dépôt `ARA_SDK` (exemples lourds, sous-modules imbriqués). Repli si les sous-modules gênent
  le clone : copie embarquée des deux dossiers (comme `lame-3.100/`), avec leurs `LICENSE.txt`.
- `objekat.xcodeproj/project.pbxproj` :
  - `HEADER_SEARCH_PATHS` (niveau projet, Debug l.~205 et Release l.~270) : ajouter `"$(SRCROOT)/ARA_SDK"`.
  - `GCC_PREPROCESSOR_DEFINITIONS` (cible, Debug l.~308 et Release l.~399) : ajouter
    `"JUCE_PLUGINHOST_ARA=1"` et `"TRACKTION_ENABLE_ARA=1"`.
- `objekat/JUCEModules/juce_audio_processors_headless_ara_impl.mm` (nouveau, si l'édition de liens
  réclame `ARADebug`) : `#include <juce_audio_processors_headless/juce_audio_processors_headless_ara.cpp>`.
  Le dossier est un groupe synchronisé (`PBXFileSystemSynchronizedRootGroup`), il est donc pris
  automatiquement.
- `NOTICE` : mention ARA SDK (Celemony, Apache-2.0) et « ARA Audio Random Access » marque de
  Celemony. `INSTALL.md` : `git submodule update --init --recursive` couvre le SDK.

Vérification :
1. `xcodebuild -project objekat.xcodeproj -scheme objekat -configuration Debug build`, puis
   `-configuration Release`.
2. Compter les `warning:` (référence ~1551 en Debug) : aucun nouveau warning sur nos fichiers. Ceux
   des en-têtes ARA sont tolérés s'ils sont listés.
3. `smoke.jsonl` + `scenario_families.py` sur l'instance compilée : le drapeau seul ne doit rien
   changer (aucun clip n'est en mode ARA).

**Critère d'arrêt.** On s'arrête et on rend compte, sans corriger plus loin, si :
- le code ARA de Tracktion ne compile pas avec nos 37 patchs après des corrections TRIVIALES
  (include, `override`, signature dérivée de nos patchs locaux comme `getHead/getTail`) totalisant
  plus d'environ 50 lignes de moteur, ou si une incompatibilité de version du SDK demande de
  modifier `ARAWrapperInterfaces.h` en profondeur ;
- ou l'édition de liens échoue sur des symboles du SDK qu'aucun TU JUCE n'apporte (signe d'une
  intégration CMake-only de Tracktion) ;
- ou `JUCE_PLUGINHOST_ARA=1` casse le chargement VST3/AU existant (smoke ou families rouges).
Dans les trois cas, le rapport donne le premier message d'erreur et l'option de repli (SDK 2.1 /
2.2, ou ARA via JUCE seul sans Tracktion). Coût estimé si tout va bien : 1 à 2 h.

### Étape 1 — Détection et résolution de Melodyne  · risque : FAIBLE

- `OBJEngineCore.mm`
  - `availablePlugins` : ajouter `@"isARA"`, VST3 SEULEMENT (Q2 : un AU n'est jamais ARA). Sans charger
    le module : `moduleinfo.json` déclare `"ARA Main Factory Class"`, OU, quand il n'y a pas de
    `moduleinfo.json` (cas de Melodyne), la chaîne `ARA Main Factory` figure dans l'exécutable (lecture
    mappée, mémorisée par bundle). C'est un indicateur d'AFFICHAGE : l'autorité reste `resolveARAPluginInfo`.
  - nouveau `- (NSDictionary* _Nullable)resolveARAPluginInfo:(NSDictionary*)pluginInfo;` : VST3 seulement →
    `findAllTypesForFile` (JAMAIS sur un AU), en exigeant `hasARAExtension` ; un AU répond nil.
    Renvoie `{identifier, format:"VST3", name, manufacturer}` ou nil.
  - DEBUG : `debug.ara_probe {identifier, format}` → `{has_ara, resolved_identifier, factory_archive_id}`.
    On charge le module (`ARAPluginFactory::getInstance`), ce qui donne l'ID d'archive de document
    de la fabrique.
- `SoundObject.swift` : `AvailablePlugin.isARA: Bool = false`, lu dans `availablePlugin(from:)`
  (`EditViewModel+Plugins.swift:123`).
- Fait quand : en headless, `plugin.list_available` montre Melodyne VST3 avec `ara: true` (Melodyne AU : `false`),
  `debug.ara_probe` répond `has_ara: true`, et aucune fenêtre n'apparaît (CGWindowList vide).

### Étape 2 — Patch moteur 0038 (A + B + C + E)  · risque : ÉLEVÉ (le cœur)

Branche du fork `objekat-ara-0038` depuis `1508f752f62`. Un seul commit
`feat(ara): l'objet Melodyne joue sa chaîne, dans un groupe, dans le pont`. Exporté en
`engine-patches/3.5/0038-feat-ara-…patch` (`git format-patch -1`), avec une entrée dans
`engine-patches/3.5/README.md`. Commentaires « Patch local Objekat — 0038 » comme ailleurs.

**A — La source passe par la chaîne du clip** (`playback/graph/tracktion_EditNodeBuilder.cpp`,
`createNodeForAudioClip(AudioClipBase&, EditItemID, EditTimeRange, bool, const CreateNodeParams&, ClipRole)`, l.480) :
```cpp
std::unique_ptr<Node> node;

if (clip.isUsingARA())
{
    if (! includeARA)  return {};
    if (! clip.setupARA (true))  return {};
    jassert (clip.getARAProxy() != nullptr);
    // Patch local Objekat — 0038 : l'ARANode est la SOURCE ; il suit la même queue que la lecture
    // d'un fichier (plugins du clip, puis fondu), au lieu de sortir nu.
    node = makeNode<ARANode> (clip, playHeadState.playHead, params.forRendering);
}
else
{
    clip.tearDownARA();
    … (corps actuel qui construit `node` depuis le fichier, inchangé) …
}

// Plugins  (inchangé)        → createPluginNodeForList (*pluginList, …)
// FadeInOut (inchangé)       → createFadeNodeForClip (…)
return node;
```
Plus, dans `ARANode::getNodeProperties()` (`tracktion_ARANode.cpp`) : `props.nodeID` dérivé de
`clip.itemID` (hash avec une constante « ara »), pour que le graphe reconnaisse le nœud d'une
reconstruction à l'autre, comme un `WaveNodeRealTime`.

**B — La source est un clip comme les autres** (même fichier) :
- `createNodeForClip` (l.1174) : `return createNodeForAudioClip (*audioClip, true, params, role);`.
  L'ARA entre ainsi dans `createNodeForClips`, donc dans le `CombiningNode` de la piste OU du
  container, avec rangs, latence de lane, head/tail et `allowedClips`.
- `createClipsNode` (l.1466) : supprimer l'appel à `createARAClipsNode` (la fonction devient
  `[[maybe_unused]]` ou disparaît), sinon le clip serait joué deux fois.
- `createNodeForContainerClip`, branche `USE_DYNAMIC_OFFSET_CONTAINER_CLIP` (désactivée, 0005) :
  rien à faire.

**C — Clip dans un container : pas de `getTrack()` nul** (`plugins/ARA/tracktion_ARAWrapperInterfaces.h`) :
```cpp
// Patch local Objekat — 0038 : un clip dans un ContainerClip n'a pas de piste directe
// (Clip::getTrack() == nullptr) ; sa séquence de régions est celle de la piste qui porte
// le container le plus extérieur. Même règle que objOwningTrack côté app.
static Track* getOwningTrackForARA (Clip& c)
{
    Clip* cl = &c;
    while (cl != nullptr)
    {
        if (auto t = cl->getTrack())  return t;
        cl = dynamic_cast<ContainerClip*> (cl->getParent());
    }
    return nullptr;
}
```
- `PlaybackRegionWrapper` (l.~1548 et ~1576) : `trackID (getOwningTrackForARA (audioClip)->itemID)`
  devient un appel gardé. Si la piste est nulle, aucune région n'est créée, `initialise` renvoie
  false, et `setupARA` échoue proprement (pas de crash). Même chose pour
  `doc.willCreatePlaybackRegionOnTrack (…)`.
- `ARAFileReader.cpp`, `internalUpdateContent` (l.678) : si la piste propriétaire courante diffère de
  `playbackRegions[0]->trackID`, on reconstruit les régions (`rebuildPlaybackRegions()`), comme on le
  fait déjà quand la disposition de boucle a changé (`playbackRegionLayoutMatches`). On ajoute la
  comparaison de piste à ce test.
- l.1133 (migration d'identifiants) : utiliser aussi `getOwningTrackForARA`.

**E — Le transport demandé par le plugin passe par l'hôte** (`plugins/ARA/tracktion_ARAFileReader.h`
+ `tracktion_ARAWrapperFunctions.h`) :
```cpp
// Patch local Objekat — 0038 : l'hôte peut intercepter les requêtes de transport d'un plugin ARA
// (play/stop/position/boucle) au lieu de laisser le plugin piloter TransportControl directement.
struct ARAHostTransportHook
{
    enum class Kind { start, stop, setPosition, setCycleRange, enableCycle };
    // Renvoie true si l'hôte a traité la requête (le comportement natif est alors sauté).
    static inline std::function<bool (Kind, double, double)> handler;
};
```
Dans chaque `request…` : `if (ARAHostTransportHook::handler && ARAHostTransportHook::handler (kind, a, b)) return;`,
dans la lambda exécutée sur le thread principal.

(D — le nœud ARA suit le `ProcessState` local d'un container en boucle — est reporté à l'étape 11.)

Vérification de l'étape : build Debug + Release. Le reste se vérifie aux étapes 3 et 5 par le
scénario. Re-export du patch après chaque correction.

### Étape 3 — Le pont OBJEngineCore  · risque : ÉLEVÉ

`OBJEngineCore.h` / `.mm`, section `// MARK: - ARA (source Melodyne)` :
```objc
/// Pose une source ARA sur un objet audio. nil = succès ; sinon la RAISON (machine, anglais).
/// `archive` : nil ou {data (base64), sourceID, modID, docArchiveID}. Échec ⇒ le clip reste en
/// lecture fichier (mode disabled) : l'objet sonne SEC, il ne devient jamais muet.
- (NSString* _Nullable)setARASource:(NSDictionary*)pluginInfo
                            archive:(NSDictionary* _Nullable)archive
                        forObjectID:(NSString*)uuid NS_SWIFT_NAME(setARASource(_:archive:forObjectID:));
- (void)removeARASourceForObjectID:(NSString*)uuid;
- (NSDictionary* _Nullable)captureARAArchiveForObjectID:(NSString*)uuid;   // + @"bytes", @"ms"
- (BOOL)isARAArchiveStaleForObjectID:(NSString*)uuid;
- (NSDictionary*)araStatusForObjectID:(NSString*)uuid;   // valid, analysing, regions, mode, plugin
- (NSArray<NSDictionary*>*)araAnalysedNotesForObjectID:(NSString*)uuid; // pitch, start, duration
- (void)openARAEditorForObjectID:(NSString*)uuid sourceKey:(NSString*)key colorHex:(NSInteger)c;
- (void)closeARAEditorForObjectID:(NSString*)uuid;
- (void)notifyARASelection:(NSArray<NSString*>*)objectIDs;
@property (nonatomic, copy, nullable) void (^onARAContentChanged)(NSString* _Nonnull objectID);
@property (nonatomic, copy, nullable) void (^onARATransportRequest)(NSInteger kind, double a, double b);
```
Points d'implémentation :
- `setARASource:` : vérifie que la clé est dans `_clipMap`, que le fichier existe (sinon
  `jassert(file.existsAsFile())` dans `ARAClipPlayer`), vitesse 1 et pas d'inversion. Résout la
  description (étape 1). Ordre imposé : (1) tamponner `araArchive`, `araArchiveSourceID`,
  `araArchiveModID` et `araDocumentArchiveID` dans `clip->state` ; (2) `clip->araPluginDescription = desc`
  AVANT le mode (sinon, à la reconstruction async, `setupARA` sans description prendrait
  `getDefaultInstance`) ; (3) `clip->setTimeStretchMode(ara)` ; (4) `clip->setupARA(true)`
  synchrone ; (5) en cas d'échec : retour à `disabled`, props retirées, raison renvoyée ;
  (6) `ensureContextAllocated` si le contexte n'est pas actif (piège AU/JUCE : unité non préparée) ;
  (7) inscrire un `juce::ChangeListener` (struct C++ `OBJARAWatcher`) sur `clip->getARAProxy()` →
  `_araStale.insert(key)` + `onARAContentChanged`. `configureFreshClip` et la règle « sans
  time-stretch » restent vrais pour tout clip SANS source.
- `removeARASourceForObjectID:` : fermer d'abord l'éditeur ARA (piège `~AudioProcessor` avec éditeur
  ouvert), retirer le watcher, puis `setTimeStretchMode(disabled)`, vider `araPluginDescription`,
  retirer les props `araArchive*` posées par `tearDownARA`, puis `updateProxyUse`.
- `closeEditorsAndPurgePluginsForObjectID:` (l.2995) : fermer aussi l'éditeur ARA. On l'appelle déjà
  avant toute suppression d'objet (`removeSoundObjectWithID:`) et au parking d'onglet.
- `captureARAArchiveForObjectID:` : `proxy->storeARAArchiveForCopy()` + les trois identifiants →
  base64. Efface `_araStale` et mesure la durée (log `[PERF] ara capture`).
- Éditeur : `_doOpenPluginEditor` est généralisé avec un résolveur d'`ExternalPlugin*` (FX : `_pluginMap` ;
  ARA : `clip->getARAProxy()->getPlugin()`), clé de fenêtre = id du plugin source. Après ouverture :
  `notifyViewSelection()`. Le lien d'état (`seedLinkStateBaseline`, `syncLinkedStateFrom`) est
  sauté pour une clé ARA.
- `ARAHostTransportHook::handler` est installé dans `init`. Il appelle `onARATransportRequest` et
  renvoie true si le bloc existe ; sinon il ne fait rien.
- Mesures à journaliser dès cette étape (elles nourrissent Q3) : durée de `setARASource:` (première
  instance = chargement du module, suivantes), RSS avant/après.

Fait quand : une commande DEBUG temporaire `debug.ara_set {id, identifier}` pose Melodyne, puis
`object.render_isolated` sur l'objet sort un signal non muet. Ce test passe en haut niveau et dans
un groupe (après le patch 0038).

### Étape 4 — Modèle Swift + format de session 20  · risque : FAIBLE

- `SoundObject/SoundObject.swift` :
```swift
struct ARAArchive: Codable, Equatable {
    var data: String              // base64 de storeObjectsForCopy — l'ÉTAT Melodyne, pas d'audio
    var sourceID: String          // araArchiveSourceID (hash du fichier à la capture)
    var modificationID: String    // araArchiveModID
    var documentArchiveID: String // ID de la fabrique (com.celemony.ara…)
    var bytes: Int                // taille décodée, pour les rapports et les tests
}
struct ARASource: Codable, Equatable {
    var plugin: ObjectPlugin      // id unique, nom, identifier VST3, couleur ; jamais linké
    var archive: ARAArchive?      // nil = jamais capturée (analyse fraîche au prochain chargement)
}
```
  `SoundObject.araSource: ARASource? = nil`, au NIVEAU SUPÉRIEUR comme `channelMode` et pour la même
  raison (les ~20 sites de construction de `.clip`), avec la même règle : tout site qui reconstruit
  un clip champ par champ doit le porter (`derivedCopy` le fait, avec un id de plugin NEUF). Le
  `Codable` explicite de `SoundObject` (l.1126) ajoute la clé avec `decodeIfPresent`.
- `EditViewModel/SessionSchema.swift` : `formatVersion = 20` ; le `_readme` mentionne `araSource`
  (archive opaque ; un id de plugin neuf pour toute copie). Un format 19 s'ouvre sans source.
- `SoundObject/PluginIDUniqueness.swift` + `PluginIDReport.swift` : l'id de `araSource.plugin` entre
  dans le recensement et la réparation (sinon deux objets copiés à la main partageraient une
  instance).
- `EditViewModel+Plugins.swift` : `missingPluginNames(in:)` / `collectPluginRefs` incluent la source.
- Pure et testable : `Shared/ARAEligibility.swift`, sur le modèle de `BridgeScope.swift`. Fonction
  `static func refusal(for object: SoundObject, ancestors: [SoundObject], isConsolidatedInstance: Bool) -> ARARefusal?`,
  avec la table de cas `tools/fixtures/ara_eligibility_cases.json` : pas un `.clip`, instance
  consolidée, vitesse ≠ 1, inversé, boucle, ancêtre en boucle, déjà une source, fichier manquant.

### Étape 5 — View-model : ajouter, retirer, synchroniser, capturer  · risque : ÉLEVÉ

Nouveau fichier `EditViewModel/EditViewModel+ARA.swift` :
- `func setARASource(objectID: UUID, available: AvailablePlugin) -> ARARefusal?` : `ARAEligibility` →
  `pushUndo()` → modèle → `syncARASource` → `pop` si le moteur refuse. Remonte la raison.
- `func removeARASource(objectID: UUID)` : `pushUndo()` (qui capture l'archive périmée, donc l'undo
  restaure les retouches) → modèle `nil` → `engine.removeARASource`.
- `func syncARASource(_ object: SoundObject)` : appelé à la FIN de `engineAddClip(_:lane:)`
  (`EditViewModel.swift` ~l.1880). Tous les chemins qui (re)créent un clip moteur passent par là :
  `syncAdd`, enfants de `syncAddGroup` (`+Groups.swift:74, 187`), split (`+Clipboard.swift:789`),
  consolidation (`+Consolidate.swift:739…1510`), chevauchements (`+Overlaps.swift:333`). Si la
  source n'est pas installée : log + l'objet sonne sec, le modèle et l'archive sont INTACTS (la
  sauvegarde les réécrit à l'identique).
- Chargement de projet (`EditViewModel+ProjectLoad.swift`) : les poses ARA vont dans la phase
  différée des compilations, comme les instruments, sous `_bulkLoadInhibitor`. La progression les
  compte.
- Capture : dans `capturedPluginStates(_:)` (`EditViewModel+Project.swift:605`),
  `if let s = obj.araSource { o.araSource = capturingARA(obj.id, s) }`. `capturingARA` ne relit que si
  `engine.isARAArchiveStale(forObjectID:)` OU `archive == nil`. Ça couvre la sauvegarde, `currentSnapshot`,
  `withCapturedPluginStates` (presse-papiers, consolidation, parking d'onglet) et
  `itemsWithCapturedPluginStates`.
- Copies dans le même projet : `copiedARASource(of:) -> ARASource?` (id de plugin neuf, même archive,
  JAMAIS de lien). Appelé partout où `copiedPlugins(of:)` / `copiedInstruments(of:)` le sont (paste,
  duplicate, split, ⌥-drag de zone). Pour le split, la moitié droite reçoit l'archive capturée sur
  l'objet d'origine AVANT la coupe : (C) les deux moitiés partagent les retouches puis divergent.
- Undo (Q1 option b) : dans `applySnapshot` (`+UndoRedo.swift:129`), l'égalité différentielle
  compare les objets avec `araSource.archive` neutralisé quand `araSource.plugin.id` est identique
  des deux côtés (helper `comparableForUndo()`). Un objet recréé dont la source vit encore reprend
  l'archive VIVANTE (capturée dans `live`). `pushPatch` ne touche jamais à la source.
- `onARAContentChanged` → `isDirty = true`. Si une session d'édition consolidée est ouverte : même
  déclencheur que `onConsolidateEditParamChanged` (aperçu temps réel des placements).
- `onARATransportRequest` → `play()` / `stop()` / `seek(to:)` du VM ; requêtes de boucle ignorées
  en v1 (le transport Swift reste maître).
- Gardes (décision 6 + Q5) : `updateSpeed(id:ratio:)` (`EditViewModel.swift:1632`),
  `updateReversed(id:reversed:)` (l.1519), la mise en boucle d'un objet et d'un groupe
  (`toggleLoopMode` l.710 et la commande `object.set_loop`), l'entrée « Spectral edit… » des
  Scripts, et le remplacement de fichier source. Tous renvoient un refus avec raison, sans toucher
  au modèle.
- Sélection : quand la sélection change et qu'un éditeur ARA est ouvert,
  `engine.notifyARASelection(selectedIDs)`.

### Étape 6 — API de commande  · risque : FAIBLE

`CommandAPI/Commands+Plugins.swift` + nouveau `CommandAPI/Commands+ARA.swift` :
- `plugin.add` : si `available.isARA` et que l'hôte est un objet audio → `setARASource`. La réponse
  porte `"slot": "ara_source"` ; un refus devient `invalid_state` avec la raison (au lieu du test
  `after.count > before.count`, faux pour ce slot).
- `plugin.list` : la source apparaît en tête avec `"slot":"ara_source"`. `plugin.remove` sur son id
  → `removeARASource`. `plugin.toggle` / `plugin.move` / `plugin.copy` / `plugin.link` / `plugin.drop`
  sur son id → `invalid_state` (« ARA source »).
- `plugin.list_available` : champ `ara`.
- `object.ara.status {id}` → `{has_source, plugin, engine_valid, analysing, regions, archive_bytes, archive_stale}`.
- `object.ara.wait_analysis {id, timeout}` (job asynchrone, `Quiescence`-like).
- `object.ara.capture {id}` → `{bytes, ms}` (force la capture dans le modèle ; undo `.none`).
- `object.ara.notes {id}` → notes analysées `[pitch, start, duration]` (le témoin de persistance).
- DEBUG `debug.ara_probe` (étape 1), `debug.ara_report` → nombre d'instances ARA, RSS, objets périmés.
- `object.set_speed` / `object.set_reversed` / `object.set_loop` : refus `invalid_state` sous source ARA.
- `docs/command_api.md` : section « Une source ARA (Melodyne) ». Aucune commande n'ouvre d'éditeur.

### Étape 7 — Rendus : consolidation, export, rendu isolé via Melodyne  · risque : MOYEN

`OBJEngineCore.mm` :
- `static void objStampARAArchives(te::Edit& live, juce::ValueTree& stateCopy)` : pour chaque clip
  live `isUsingARA()` (balayage PROFOND, comme `objAllPluginsDeep`), on capture
  `storeARAArchiveForCopy` et on écrit les quatre props `araArchive*` sur l'arbre homologue de la
  copie (même `EditItemID`). Retirer aussi l'enfant `ARADOCUMENT` de la copie : on ne garde qu'une
  source de vérité, les archives par clip. Appelé dans les DEUX chemins de clone (l.~3700 bake/rendu
  ciblé, l.~4086 export), juste après `createCopy()`.
- `OBJRenderPluginFilter::wants` : un `ExternalPlugin` SANS parent dont la description a
  `hasARAExtension` est accepté (il ne peut appartenir qu'à un clip ARA du clone ; le clip lui-même
  est filtré par `allowedClips` en amont via le graphe).
- `ARANode::isReadyToProcess` attend la fin d'analyse en rendu offline. Avec une archive restaurée,
  l'analyse est déjà là. On mesure le délai (log) et on vérifie que le rendu ne bloque pas
  indéfiniment si Melodyne n'est pas autorisé (sous licence) : timeout de rendu existant.
- Formats compressés (MP3/FLAC, `needsCachedProxy`) : vérifier qu'`ARAClipPlayer` lit l'original. Si
  ce n'est pas le cas, l'éligibilité refuse « fichier compressé ».
- Fait quand : `consolidate.make` sur un objet Melodyne écrit un wave dans `samples/consolidate`
  (dossier courant de consolidation) dont le RMS et la hauteur égalent le rendu live (et, avec la
  fixture Q6, la hauteur RETOUCHÉE).

### Étape 8 — Onglets et copier-coller inter-projets  · risque : MOYEN

- `SoundObject/CrossProjectImport.swift`, `cloneObject` (l.257) : `no.araSource` = id de plugin neuf,
  archive copiée telle quelle (elle vient du presse-papiers, figée par `withCapturedPluginStates` à
  la copie — même règle « jamais lire le moteur de la cible »). Le média copié dans la cible change
  le hash de fichier : `restoreObjectsForPaste` transpose `sourceID`, rien à faire.
- `Workspace` / `EditViewModel+Tabs.swift` : au parking, `closeARAEditor` pour chaque objet ARA (déjà
  couvert via `closeEditorsAndPurgePluginsForObjectID:` si le parking démonte les objets). Les
  instances ARA ne vont PAS en consigne (elles appartiennent au clip, pas à une plugin-list) : au
  retour, elles sont ré-instanciées depuis l'archive. Mesurer le coût du retour d'onglet avec 10
  objets Melodyne.

### Étape 9 — Interface  · risque : MOYEN (rien vérifiable sans écran)

- `Inspector/Synoptic/SynopticLayout.swift` : `audioZone` gagne un `araSlot: CGRect?` (même calcul
  que `instrumentSlot`, l.565), et la hauteur de zone augmente quand un slot est présent.
- `Inspector/Synoptic/SynopticView.swift` : `SynopticAudioFile` gagne `araSource: SynopticPlugin?`,
  `araAnalysing: Bool` et `araLocksTime: Bool`. `AudioFileZoneView` dessine la carte (nom, couleur,
  ✕, roue d'analyse) ; double-clic → `actions.openARAEditor`. Les contrôles speed / st / bpm /
  reverse / loop sont désactivés avec l'info-bulle `synoptic.ara.timeLocked`. Les flèches du
  synoptique passent par la carte.
- `Inspector/PluginRackView.swift` (`PluginPickerPopover`) : entrée ARA grisée avec sa raison
  (`ARARefusal.localizedKey`) quand l'hôte n'est pas éligible ; « Melodyne (AU) » est routé vers la
  VST3 (Q2).
- `EditViewModel+Plugins.swift`, `addPlugin(objectID:available:)` (l.301) : bifurcation
  `if available.isARA { if let r = setARASource(...) { présenter r } ; else ouvrir l'éditeur ARA ; return }`.
  Ouverture d'éditeur à l'ajout, comme un plugin : gardée par `hasInterface`.
- `Resources/Localizable.xcstrings` : clés symboliques en fr/en/es (`synoptic.ara.source`,
  `synoptic.ara.analysing`, `synoptic.ara.timeLocked`, `ara.refusal.*`). `tools/i18n/xcstrings.py check`
  doit répondre propre.
- Pas de pastille sur la timeline, pas de notes (décision 2).

### Étape 10 — Documentation et mémoire  · risque : NUL

`OBJEKAT - claude project/docs/architecture_decisions.md` (ARA = source du clip, pas un insert ;
archive par objet ; Q1–Q5 tranchées), `command_api.md`, `glossary.md` (source ARA, archive),
`CLAUDE.md` (état + pièges : ordre description→mode, filtre de rendu, `getTrack()` nul, une instance
par objet), `INSTALL.md`, `NOTICE`, `engine-patches/3.5/README.md` (0038), mémoire
`project_ara_melodyne_study.md` → état réel.

### Étape 11 — Plus tard (hors v1)

D : `ARANode` devient un `TracktionEngineNode` qui lit le `ProcessState` local, ce qui rend les
groupes en boucle possibles (puis on lève les refus de Q5). Fabrique ARA AU. Réponse de Q4 si
l'oreille la réclame. Instance unique par séquence (Q3) si les mesures l'exigent. Glisser la carte
source. Notes Melodyne en surimpression. Forme d'onde du rendu Melodyne.

---

## 4. Patch 0038 — récapitulatif

| Part | Fichier (fork) | Fonction | Effet |
|---|---|---|---|
| A | `playback/graph/tracktion_EditNodeBuilder.cpp` | `createNodeForAudioClip(…)` l.480 | ARANode → plugins du clip → fondu |
| A | `playback/graph/tracktion_ARANode.cpp` | `getNodeProperties()` | `nodeID` stable dérivé du clip |
| B | `playback/graph/tracktion_EditNodeBuilder.cpp` | `createNodeForClip` l.1174, `createClipsNode` l.1466 | ARA dans le CombiningNode (piste ET container), plus de somme hors rang |
| C | `plugins/ARA/tracktion_ARAWrapperInterfaces.h` | `PlaybackRegionWrapper` ctors, `willCreatePlaybackRegionOnTrack` | piste propriétaire via les containers ; pas de nullptr |
| C | `plugins/ARA/tracktion_ARAFileReader.cpp` | `internalUpdateContent`, migration l.1133 | régions reconstruites si la piste propriétaire change |
| E | `plugins/ARA/tracktion_ARAFileReader.h`, `tracktion_ARAWrapperFunctions.h` | `PlaybackControllerFunctions::request*` | crochet hôte pour le transport |

Ce qui ne change PAS : le patch local `getHead/getTail` (gardé tel quel, désormais effectif), 0037.
Le tap du pont est sur la plugin-list du clip, donc en aval de Melodyne après A : une source
Melodyne peut servir de clé de sidechain sans rien de plus.

---

## 5. Plan de test

### 5.1 Tests autonomes (sans app)
- `tools/test_ara_eligibility.swift` + `tools/fixtures/ara_eligibility_cases.json` (compile :
  `swiftc -parse-as-library objekat/Shared/ARAEligibility.swift objekat/SoundObject/SoundObject.swift … tools/test_ara_eligibility.swift`).
  Une assertion par cas : clip OK ; groupe, aux, MIDI et stem refusés ; instance consolidée refusée ;
  vitesse 1,07 et 0,5 refusées ; inversé refusé ; boucle refusée ; enfant d'un groupe en boucle (à
  n'importe quelle profondeur) refusé ; déjà une source refusé ; fichier manquant refusé.
- `tools/test_ara_model.swift` : aller-retour Codable d'`ARASource` (archive de 2 Mo de base64
  aléatoire, octets identiques) ; une session format 19 se décode sans `araSource` ; `derivedCopy`
  porte la source avec un id de plugin NEUF ; `PluginIDUniqueness` détecte deux sources de même id
  et les répare.
- `tools/test_cross_project_import.swift` (existant, étendu) : un objet avec source → id neuf,
  archive identique octet pour octet, aucun lien ; un groupe contenant un objet Melodyne → la source
  de l'enfant est clonée. Les 37 assertions existantes restent vertes.

### 5.2 Scénario API `tools/scenario_ara.py`
Sur le modèle de `scenario_channel_mode.py` : SA propre instance
`--headless --api --no-recent --language=en --socket=…`, une passe avec `--no-audio` (sections
A–N), plus une passe SANS `--no-audio` pour la section F (le pont lit l'horloge du périphérique).
Sortie : 0 tout passe, 1 échec, 2 mauvais usage, **3 SKIP** si Melodyne VST3 est absent.
Signaux générés par le script (WAV 24 bits 48 kHz) : `sine220.wav` (10 s, −12 dBFS), `sine1k.wav`,
`melody30.wav` (30 s : notes de 0,5 s sur une gamme, léger vibrato, 2 % de bruit) et `melody180.wav`
(3 min). Tout export est relu en 24 bits. La hauteur est mesurée par FFT (pic, interpolation
parabolique), le RMS en dBFS.

| # | Section | Assertions concrètes |
|---|---|---|
| A | Détection | `plugin.list_available` contient Melodyne VST3 avec `ara:true` ; `debug.ara_probe` → `has_ara:true`, `factory_archive_id` non vide |
| B | Pose | `plugin.add {host: clip220, name:"Melodyne"}` → `slot:"ara_source"` ; `plugin.list` montre la source en tête ; `object.ara.status` → `engine_valid:true` ; `object.ara.wait_analysis` < 120 s ; `object.ara.notes` ≥ 1 note de pitch 57 (A3 = 220 Hz) |
| C | Audible | `object.render_isolated` : RMS > −40 dBFS ; \|RMS − RMS_sans_Melodyne\| ≤ 1,5 dB ; hauteur 220 Hz ± 1 % |
| D | Chaîne APRÈS la source (trou A) | volume −12 dB → RMS −12 ± 0,5 dB ; filtre passe-bas intégré à 200 Hz sur `sine1k` → chute ≥ 15 dB ; fondu d'entrée de 1 s → RMS des 100 premières ms < RMS central − 20 dB ; objet raccourci à droite → silence (< −90 dBFS) après la fin ; channel mode `l` sur source stéréo appliqué |
| E | Groupe (trous B + C) | grouper l'objet → `export.run` : RMS ≈ C (± 1,5 dB), pas de crash ; groupe imbriqué sur 2 niveaux idem ; dégrouper idem ; changer la lane d'un objet (changement de piste du pool) → toujours audible, `regions == 1` |
| F | Pont 0037 (sans `--no-audio`) | objet Melodyne comme CLÉ de sidechain d'un `OBJKeyProbe` (même montage que `scenario_sidechain.py`) → la sonde lit une clé non nulle ; `debug.bridge_report` montre le tap ; objet Melodyne dans un groupe à rang ≠ 0 audible |
| G | Sauvegarde / rechargement | `project.save` → le JSON contient `araSource.archive.data` non vide, `bytes > 0`, `formatVersion == 20` ; réouverture → `engine_valid:true`, même id de plugin, `object.ara.notes` IDENTIQUES (pitch, début ± 1 ms), rendu post-reload : \|ΔRMS\| < 0,5 dB et corrélation > 0,99 avec le rendu d'avant |
| H | Undo | `plugin.remove` (source) → rendu ≈ référence sèche ; `undo` → source revenue, `engine_valid`, notes identiques ; `redo` → retirée ; supprimer l'objet puis `undo` → source revenue ; politique Q1(b) : `object.ara.capture`, déplacer l'objet, `undo` → l'archive vivante n'est PAS remplacée (même `bytes`, même sha de `data` relu) |
| I | Copier / dupliquer / couper | copy+paste, `object.duplicate`, coupe au milieu → chaque morceau a sa source, ids distincts, `debug.plugin_id_audit` = 0, chacun audible, hauteur 220 Hz, `regions == 1` par objet |
| J | Consolidation (décisions 3 + 5) | `consolidate.make` sur l'objet → wave dans `samples/consolidate` : RMS ≈ C, hauteur 220 Hz ; `plugin.add Melodyne` sur l'instance consolidée → `invalid_state` (raison « consolidated »), aucun changement de modèle |
| K | Refus | `plugin.add Melodyne` sur MIDI, groupe, aux, stem, objet à vitesse 1,5, objet inversé, objet en boucle → `invalid_state` ; source posée : `object.set_speed`, `object.set_reversed`, `object.set_loop` → `invalid_state`, modèle inchangé ; groupe contenant un objet Melodyne : `object.set_loop` refusé |
| L | Onglets | `tab.open` d'un 2ᵉ projet, copier l'objet Melodyne en A, coller en B (via `save_as` + `tab.open`, comme `scenario_cross_paste.py`) → source présente en B, id neuf, rendu B ≈ C ; aller-retour d'onglet ×3 → A `engine_valid`, notes identiques, rendu inchangé ; temps de retour d'onglet journalisé |
| M | Taille de l'archive (décision 4) | `melody30` et `melody180` : analyse terminée → `object.ara.capture` → octets et ms ; sauvegarde → delta de taille du JSON ; tableau imprimé (octets bruts, base64, octets/min, ms de capture). Pas de seuil bloquant : avertissement si > 2 Mo pour 3 min (pour décider d'un éventuel déport dans `samples/`) |
| N | Plugin manquant | projet fixture dont la source pointe vers un VST3 inexistant → chargement OK, objet audible SEC (≈ référence), `project.save` réécrit `araSource` à l'identique (sha de `data` égal) |
| O | Coût (Q3) | 1, 10 et 40 objets Melodyne (copies) : temps de `project.load` et RSS (`debug.ara_report`), journalisés ; durée de `pushUndo` avec 40 objets dont 1 périmé |
| P | Fixture retouchée (Q6, SKIP si absente) | projet témoin `+7 demi-tons` : hauteur export = 329,6 Hz ± 1 % ; tient après rechargement, copier-coller, coupe (les DEUX moitiés), consolidation, collage inter-onglets, undo de suppression ; après retrait de la source, retour à 220 Hz |
| Z | Fin | `CGWindowListCopyWindowInfo` filtré sur le pid headless → liste vide (Melodyne peut afficher une fenêtre d'autorisation : à détecter ici) ; `debug.plugin_id_audit` = 0 |

### 5.3 Non-régression (une instance fraîche par suite)
Build Debug et Release (warnings comparés à la référence ~1551, zéro nouveau sur nos lignes) ;
`smoke.jsonl` ; `scenario_families.py` ; `scenario_markers.py` ; `scenario_plugin_state_undo.py` ;
`scenario_plugin_selection.py` ; `scenario_export_preview.py` ; `scenario_fxlink.py` ;
`scenario_consolidate.py` ; `scenario_tabs.py` ; `scenario_cross_paste.py` ;
`scenario_channel_mode.py` ; `scenario_relink.py` ; `scenario_sidechain.py` et
`scenario_bridge_latency.py` (sans `--no-audio`, en Debug : ils couvrent le chemin
`createNodeForClips` que B modifie) ; `test_bridge_core.cpp` ; `test_bridge_scope.swift` ;
`test_cross_project_import.swift` ; `tools/i18n/xcstrings.py check` ; perf : `bench_groups.py`
avant/après (B appelle `createNodeForAudioClip(…, true, …)` pour tous les clips audio, sans effet
attendu sur un clip non ARA, mais on le mesure).

### 5.4 Ce que seul l'utilisateur peut valider (écran / oreille)
- Le SON d'une vraie retouche : hauteur, timing, formants, sans clic aux bords de l'objet ni aux
  coupes.
- La fenêtre Melodyne : elle s'ouvre au double-clic et à l'ajout, montre l'objet sélectionné, suit
  la sélection, se ferme proprement (suppression, retrait, onglet, fermeture de projet), sans crash.
- La carte « source » dans le synoptique : place, flèches, roue d'analyse, ✕, contrôles grisés et
  leurs info-bulles, picker grisé avec la bonne raison, dans les trois langues.
- Les boutons de transport de Melodyne : play/stop/position pilotent bien le transport d'OBJEKAT
  (patch E), et l'interface d'OBJEKAT suit.
- Q4 : l'écoute d'une note cliquée transport arrêté.
- Le ressenti CPU / mémoire avec 10 à 40 objets Melodyne, le temps de retour d'onglet, le
  chargement d'un vrai projet.
- La forme d'onde qui ne reflète pas les retouches (limite connue, à confirmer comme acceptable).
- La fixture Q6 (une fois).

---

## 6. Risques par étape

| Étape | Risque | Pourquoi | Parade |
|---|---|---|---|
| 0 | Moyen | version du SDK vs code Tracktion 3.5 ; TU `ARADebug.c` ; JUCE ARA + nos patchs JUCE écartés (`pending/0004`, `0010`) | critère d'arrêt explicite ; repli SDK 2.x |
| 1 | Faible | AU jamais instancié ; seul le VST3 est chargé, à la demande | `debug.ara_probe` |
| 2 | **Élevé** | graphe : ARA dans le CombiningNode (gating, head/tail, latence), conteneurs, régions | sections C/D/E/F du scénario + non-régression pont |
| 3 | **Élevé** | instanciation synchrone sur le thread principal ; ordre description→mode ; éditeur et destruction (pièges AU) ; Melodyne et licence en headless | ordre imposé ; fermeture d'éditeur avant toute destruction ; contrôle de fenêtre |
| 4 | Faible | règle « champ top-level » à respecter partout | `derivedCopy` + test modèle |
| 5 | **Élevé** | fraîcheur de l'archive et politique d'undo (Q1) ; nombre de sites de recréation | un seul crochet de capture ; un seul crochet de pose (`engineAddClip`) ; section H |
| 6 | Faible | contrat `plugin.add` modifié pour un slot | tests API |
| 7 | Moyen | clone de rendu sans archive / filtre de rendu ; analyse bloquante offline | section J + fixture P |
| 8 | Moyen | ré-instanciation au retour d'onglet ; coût | section L, mesures |
| 9 | Moyen | rien de vérifiable sans écran | liste 5.4 |
| 11 | — | hors v1 | — |

Estimation brute : étapes 0–1 ≈ 0,5 j ; 2–3 ≈ 2 j ; 4–6 ≈ 1,5 j ; 7–8 ≈ 1 j ; 9 ≈ 1 j ;
tests et docs ≈ 1 j. Le chemin critique, c'est l'étape 0 (compile ou pas), puis E/G du scénario
(groupe et rechargement).

---

## 7. Journal d'exécution (7–8 octobre 2026)

Branches : app `feature/ara-melodyne` (rien poussé), moteur `objekat-ara-0038` (`efff893e684`, rien poussé).

| Étape | Commit app | Résultat |
|---|---|---|
| 0 | `059ab285` | SDK ARA 2.3.0 et drapeaux, Debug + Release : compile |
| 1 | `6956e97c` | détection et résolution (`isARA`, `resolveARAPluginInfo`, `debug.ara_probe`) |
| 2 | `7261e81c` | patch moteur 0038 (A + B + C + E) |
| 3 | `9f8c3f2e` | pont `OBJEngineCore` |
| 4 | `6fe350a4` | modèle `ARASource`, format 20, règles d'éligibilité |
| 5–6 | `673a7b5c` | view-model et API de commande |
| 7–8 | `c975e816` | rendus via Melodyne (bake / export sur clone), onglets, copier-coller inter-projets |
| 9 | `e98077b2` | interface |
| 10 | (ce commit) | documentation |

`tools/scenario_ara.py` : 131 OK (sections A à O et Z). Non-régression verte (dont
`test_cross_project_import.swift` 43/43, `test_ara_model.swift`, `test_ara_eligibility.swift`).

### Écarts au plan

1. **Étape 1 / Q2** : pas de jumelage AU vers VST3 (réponse de l'utilisateur). Seul le VST3 est source.
   L'idée « marquer un VST3 candidat grâce à son jumeau AU » n'est donc pas faite.
2. **Étape 9, le « + »** : le plan routait l'entrée ARA dans `addPlugin(objectID:available:)`. Fait
   autrement : une section « Source ARA (Melodyne) » SÉPARÉE dans `PluginPickerPopover`, qui appelle
   `addARASourceFromPicker` ; le chemin des FX n'est pas touché (aucun risque de régression sur le
   « + » ordinaire). Le contrôle du « + » des instruments MIDI n'a pas la section.
3. **Étape 9, la carte** : pas de `araSlot` ni de carte glissable ; la source est une LIGNE de la zone
   « fichier audio » (nom = ouvre l'éditeur, roue pendant l'analyse, croix = retire), la zone gagne
   23 pt de hauteur. Vitesse, st, bpm, reverse et boucle sont verrouillés (`synoptic.ara.timeLocked`).
4. **Étape 9, la détection** : le scan de l'app ne charge JAMAIS un binaire VST3 (il lit l'Info.plist),
   donc `hasARAExtension` n'y est pas connu. Choix B + C de l'architecte : pré-filtre sur fichiers
   (`moduleinfo.json`, sinon la chaîne « ARA Main Factory » dans l'exécutable), confirmation au
   placement par `resolveARAPluginInfo` dans le processus. Faux positifs connus : RX, Ozone, Trash,
   WaveShell. Un faux positif est REFUSÉ avec une raison (`ara.refusal.pluginNotARA`) et mémorisé pour la
   session (`araDisprovedIdentifiers`). Non fait : la sonde en processus enfant (option A).
5. **Preuve du chemin Melodyne** : sans retouche, Melodyne rend l'audio tel quel, ni le RMS ni la hauteur ne
   prouvent quoi que ce soit. La preuve est sa SIGNATURE : un fondu de sortie des ~2,4 dernières ms au
   taux natif du fichier (44100 Hz), absent d'un rendu sec et à 48 kHz.
6. **Bug trouvé en route** : la moitié droite d'un clip coupé n'avait pas de source (corrigé : `syncARASource`
   explicite dans `+Cut.swift`).

### Mesures (Debug, `scenario_ara.py`, sections M et O)

| Signal | Analyse | Archive | base64 | Capture | Par minute |
|---|---|---|---|---|---|
| mélodie 30 s | 0,1 s | 325 873 o | 434 505 o | 35 ms | 651 746 o |
| mélodie 3 min | 1,2 s | 1 791 563 o | 2 388 759 o | 208 ms | 597 188 o |

| N objets | Chargement | RSS | Instances | JSON |
|---|---|---|---|---|
| 1 | 0,06 s | 3646 Mo | 1 | 448 Ko |
| 10 | 0,66 s | 3795 Mo | 10 | 4,4 Mo |
| 40 | 2,74 s | 4430 Mo | 40 | 17,9 Mo |

`pushUndo` avec 40 sources : aucune périmée 1 ms ; une périmée 40 ms ; toutes périmées 1491 ms
(40 captures). Soit ~20 Mo et ~70 ms par objet.

### Reste (voir 5.4) : tout ce qui demande un écran ou une oreille

L'interface (picker, ligne ARA, verrous, messages), l'éditeur Melodyne à l'écran, le ressenti, Q4,
la fixture Q6. Choix laissés à l'utilisateur : (a) faux positif du pré-filtre = refus (actuel) ou repli
vers un insert FX ordinaire ; (b) sonde en processus enfant (A) si le refus gêne.
