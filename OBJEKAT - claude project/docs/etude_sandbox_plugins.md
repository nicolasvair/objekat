# Étude — Sandbox des plugins (hébergement hors processus)

> Statut : ÉTUDE, rien codé. Date : 2026-10-18. Base : `main` @ 46d35cca.
> Objet : décider SI et COMMENT isoler les plugins AU/VST3 dans des processus séparés, pour
> (1) qu'un plugin qui plante ne tue plus OBJEKAT, (2) sortir le travail des plugins du thread
> principal de l'app.

---

## 1. Ce qui existe aujourd'hui (constat dans le code)

Tout plugin vit **dans le processus de l'app** :

| Aspect | Où | Thread |
|---|---|---|
| Instanciation AUv2 | JUCE `AudioComponentInstanceNew` (in-process) | principal (Opal : 2,4 s ; UADx : jusqu'à 275 s de licence) |
| Instanciation AUv3 | JUCE `AudioComponentInstantiate(…, LoadOutOfProcess)` | **déjà hors processus** (Apple) |
| Instanciation VST3 | JUCE, dylib chargée dans l'app | principal |
| Traitement audio | `ExternalPlugin` → `pi->processBlock` dans le `PluginNode` | fil audio + workers Tracktion (cœurs P) |
| Éditeur natif | `OBJPluginEditorWindow` (JUCE `DocumentWindow`) + bande Sidechain SwiftUI + cadre couleur + relais clavier | principal |
| État (chunk) | `getStateInformation` / ré-affirmation `OBJPendingStateReassert` | principal (suspend le traitement) |
| Link | `OBJParamMirror` (AutomatableParameter) + `OBJProcessorWatcher` (AudioProcessorListener) | principal + async |
| VU par plugin | mesure dans `PluginNode::process` (patch 0042) | fil audio, côté hôte |
| Sidechain | bus d'entrée du plugin + `OBJBridgeTap/Send` dans le graphe | fil audio |
| ARA / Melodyne | `ARADocumentController` partagé, le plugin lit l'audio de l'hôte par callbacks | principal + fils ARA |
| Rendus (export, consolidé, freeze, preview) | clone d'Edit → nouvelles instances (`OBJRenderPluginFilter`) | fil de rendu |
| Consigne | `OBJParkedPlugin` garde le `Ptr` vivant 20 s | — |
| Scan | AU par `AudioComponentFindNext` (sans instancier), VST3 par Info.plist ; `findAllTypesForFile` seulement pour lire l'ARA des VST3 | principal |

Conséquences : un plugin qui fait `EXC_BAD_ACCESS` dans son `processBlock`, son GUI ou son
`setState` emporte l'app (et le projet non sauvé). Un plugin lent à charger ou à dessiner gèle
la timeline.

### Point d'injection trouvé — sans patch moteur

Tracktion crée toutes les instances externes via `PluginManager::pluginFormatManager` :
- chemin synchrone : `PluginManager::createPluginInstance` (un `std::function` remplaçable) ;
- chemin asynchrone (AUv3) : `pluginFormatManager.createPluginInstanceAsync` direct.

Les deux passent par un `juce::AudioPluginFormat`. **On peut retirer les formats « AudioUnit » et
« VST3 » par défaut et enregistrer à la place des formats enveloppes portant LE MÊME NOM**, qui
rendent un `juce::AudioPluginInstance` *proxy*. `te::ExternalPlugin`, le graphe, l'automation, les
VU, la consigne, la sauvegarde (`state` base64) continuent de marcher sans le savoir : ils parlent
à un `AudioPluginInstance` comme avant. Les noms de format et identifiants ne changent pas → les
projets existants s'ouvrent tels quels, et on peut basculer sandbox on/off par plugin.

---

## 2. Architecture proposée

```
┌──────────────────────── OBJEKAT.app (hôte) ─────────────────────────┐
│ Tracktion Edit / graphe                                              │
│   PluginNode → te::ExternalPlugin → OBJRemotePluginInstance (proxy)  │
│                                        │  params proxies, bus, latence│
│ OBJSandboxManager (thread principal) ──┤  politique de regroupement   │
│   • lance/surveille les hôtes          │  watchdog, redémarrage        │
│   • cache du dernier état connu        │                               │
└────────────────────────────────────────┼──────────────────────────────┘
          contrôle : XPC / mach (async)   │   audio : mémoire partagée +
                                          │   sémaphore (temps réel)
┌─────────────── objekat-plughost (N processus) ───────────────────────┐
│ main thread : instanciation, GUI natif, getState/setState            │
│ 1 fil de rendu par instance (rejoint le workgroup audio de l'hôte)   │
│ JUCE AudioPluginFormatManager « vrai » (AU in-process, VST3)         │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.1 Les trois canaux

1. **Contrôle (asynchrone, thread principal)** — XPC (ou mach messages) : `load(desc, state)`,
   `prepare(sr, block, layout)`, `getState`, `setState`, `openEditor`, `closeEditor`,
   notifications remontantes (`paramChanged`, `latencyChanged`, `gestureBegin/End`,
   `editorResized`, `crashed`). Jamais d'appel bloquant depuis le thread principal de l'app :
   le proxy répond depuis un **cache** (dernier état, dernière latence, valeurs de params).

2. **Audio (temps réel)** — un bloc de mémoire partagée par instance :
   `[entête : numéro de bloc, nb échantillons, transport/playhead, changements de params
   horodatés] [buffers entrée (+ sidechain)] [MIDI] [buffers sortie]`. Le fil Tracktion qui
   exécute le `PluginNode` écrit, signale (sémaphore mach / `os_sync_wait_on_address`), attend
   la réponse avec une **échéance**. Pas de malloc, pas de lock, pas d'XPC dans ce chemin.

3. **GUI** — l'éditeur natif tourne dans le processus hôte de plugin (c'est le point clé pour le
   thread principal). Voir §4.5 pour la fenêtre.

### 2.2 Proxy côté app (`OBJRemotePluginInstance : juce::AudioPluginInstance`)

- `processBlock` → aller-retour mémoire partagée (§2.1-2).
- Paramètres : `AudioProcessorParameter` proxies construits depuis la liste rendue au chargement ;
  `setValue` côté app → empilé dans le bloc suivant ; changement côté plugin (GUI) → notification
  → `sendValueChangedMessageToListeners` → **Link, automation write, badges marchent tels quels**.
- `getStateInformation` : rend le dernier état mis en cache (rafraîchi après chaque geste, à la
  sauvegarde, avant un rendu) ; `setStateInformation` : asynchrone + accusé.
- `getLatencySamples`, bus/layouts, `acceptsMidi`, `hasEditor` : cachés.
- `createEditor` : rend un `AudioProcessorEditor` vide qui pilote la fenêtre distante (§4.5).

### 2.3 Hôte de plugin (`objekat-plughost`)

Petit exécutable (même équipe de signature, hardened runtime, mêmes entitlements que l'app :
`disable-library-validation`, etc.), embarqué dans `objekat.app/Contents/Helpers/`. JUCE seul
(pas Tracktion). Une instance = un fil de rendu dédié qui rejoint le **workgroup audio** de
l'app (`os_workgroup` partagé par port mach) pour rester sur les cœurs P et dans la même
échéance que le fil audio.

### 2.4 Politique de regroupement (décision clé pour OBJEKAT)

OBJEKAT a beaucoup plus d'instances qu'un DAW à pistes (FX par objet, jusqu'à 40 par objet,
centaines d'objets). **1 processus par instance est exclu** (mémoire : ~20–60 Mo de base par
processus + le framework du plugin ; temps de lancement). Modes possibles (Bitwig a les mêmes) :

| Mode | Isolation | Coût |
|---|---|---|
| A. Tous dans un seul hôte | protège l'app, pas les autres plugins | minimal |
| B. Un hôte par **fabricant/bundle** | un plugin qui plante n'emporte que ses frères | modéré, défaut probable |
| C. Un hôte par **instance** | maximale | réservé aux plugins marqués « instables » |
| D. In-process | aucune | zéro, pour plugins de confiance / ARA / perf |

Proposition : **B par défaut, D forcé pour ARA, C/D réglable par plugin** (mémorisé dans le
catalogue, avec promotion automatique en C après un crash).

---

## 3. « Sortir les plugins du thread principal ? » — réponse

**Oui, en grande partie, et c'est probablement le gain le plus perceptible au quotidien** :

| Travail de plugin sur le main thread aujourd'hui | Avec sandbox |
|---|---|
| Chargement (Opal 2,4 s, UADx licence jusqu'à 275 s) | sur le main thread **de l'hôte** ; l'app continue, carte « chargement… » |
| Dessin des GUI lourdes (analyseurs, UAD) | dans l'autre processus : la timeline ne saccade plus |
| `getState` / `setState` (suspend le traitement) | asynchrone, servi depuis le cache |
| Ré-affirmation d'état (AU non initialisés) | se règle dans l'hôte, invisible côté app |

Ce que ça ne change PAS : le traitement audio n'est déjà pas sur le thread principal. Et il n'y a
**pas** d'alternative in-process : un GUI AU/VST3 doit tourner sur le thread principal *de son
processus* — la seule façon de le décoller du nôtre, c'est un autre processus.

---

## 4. Cas limites et interactions avec l'existant (à discuter)

### 4.1 Temps réel et latence
- **Coût IPC** : un aller-retour réveil/attente ≈ quelques dizaines de µs par instance et par bloc.
  ×300 instances à 128 échantillons (2,9 ms) = significatif. D'où le regroupement **et** un
  traitement par lots : un hôte peut traiter en un seul aller-retour *toute la chaîne* d'un objet
  (ses FX consécutifs sandboxés au même hôte) au lieu d'un aller-retour par FX.
- **Retard de l'hôte** : si la réponse ne vient pas dans l'échéance, deux politiques :
  1. *attendre* → le bloc entier de l'app peut décrocher (comme in-process, mais sans crash) ;
  2. *ne jamais attendre* : pipeline avec **1 bloc de latence** déclarée au PDC → jamais de
     décrochage global, mais +1 bloc sur chaque plugin sandboxé (gênant au jeu MIDI live).
  Choix à faire (voir questions).
- Le multi-cœur Tracktion est conservé : chaque worker qui attend un hôte libère son cœur, et
  chaque instance a son propre fil de rendu dans l'hôte.

### 4.2 Crash d'un hôte
- Détection : port mort (XPC invalidé) ou fil de rendu muet au-delà de N blocs (watchdog).
- Côté audio : le proxy sort du **silence** (ou bypass = entrée→sortie, à choisir) dès le bloc
  suivant ; aucun pointeur vers le plugin mort côté app → rien à nettoyer en urgence.
- Côté UI : carte synoptique en état « planté », badge sur l'objet, fenêtre éditeur fermée.
- Reprise : relancer l'hôte, recharger les instances avec **le dernier état en cache**, ré-appliquer
  l'automation. Perte possible = réglages faits dans le GUI depuis le dernier rafraîchissement du
  cache (d'où rafraîchir après chaque fin de geste).
- Crash **au chargement** → plugin marqué suspect, proposé en mode C, ou désactivé.
- Crash en boucle → arrêter de relancer après K tentatives.

### 4.3 Link (`OBJParamMirror`, `OBJProcessorWatcher`, resync de chunk)
Fonctionne si les proxies de params émettent les mêmes notifications. Mais la garde anti-écho
repose sur des fenêtres temporelles (1000 ms, 600 ms…) : l'IPC ajoute du délai → à revalider.
Le resync de chunk à la fermeture d'éditeur devient : `getState` asynchrone sur l'instance
source → `setState` asynchrone sur les liées.

### 4.4 ARA / Melodyne — **exception obligatoire**
Le `DocumentController` ARA partage des pointeurs et le plugin lit l'audio de l'hôte par
callbacks synchrones : impossible à transporter simplement. Le SDK ARA ne prévoit d'IPC que pour
les **AUv3** (app extension), et la bibliothèque IPC n'est même pas dans notre copie du SDK.
→ Les plugins ARA (Melodyne VST3/AUv2) restent **in-process** (mode D forcé).

### 4.5 Fenêtre d'éditeur
Aujourd'hui : fenêtre JUCE dans l'app, bande Sidechain SwiftUI dessous, cadre couleur
d'identité, relais clavier vers la timeline, flottante/pas flottante vs explorateur.
Avec le GUI dans un autre processus, trois options :
- **(a) La fenêtre appartient à l'hôte** (Bitwig, Reaper). Simple et robuste. Perdu ou à refaire :
  la bande Sidechain (→ panneau séparé dans l'app, ou dans l'inspecteur), le relais clavier
  (→ via IPC : l'hôte renvoie les touches non consommées), l'ordre des fenêtres (une fenêtre
  d'un autre processus ne peut pas être « enfant » des nôtres ; le niveau flottant reste réglable).
  Le cadre couleur peut être dessiné par l'hôte (on lui passe la couleur).
- **(b) Vue distante incrustée dans une fenêtre de l'app** : pas d'API publique macOS pour
  incruster une NSView d'un autre processus (hors `requestViewController` des AUv3, et
  `CALayerHost`/`CAContext` privés). API privée → risque de casse à chaque macOS.
- **(c) Hybride** : (a) pour VST3/AUv2, et pour les AUv3 la vue distante Apple officielle.
Proposition : **(a)**, quitte à repenser la place de la bande Sidechain.

### 4.6 Sidechain
Les bus d'entrée supplémentaires passent dans le bloc mémoire partagée (taille fixée au
`prepare`). Le graphe (`OBJBridgeTap/Send`) ne change pas. Changement de layout = `prepare`
asynchrone + le plugin est en bypass pendant la transition.

### 4.7 Rendus hors temps réel (export, consolidé, freeze, preview)
Le clone de rendu instancie de nouveaux plugins → nouvelles instances dans les hôtes. Plus lent
au départ (lancement), mais sans risque : un plugin qui plante pendant un export n'emporte plus
l'app (l'export échoue proprement avec le nom du coupable). Blocs plus grands en offline → coût IPC
négligeable. Avant tout rendu, flush de l'état de la source (déjà fait aujourd'hui par
`forcePluginStatesForRenderClone`, à faire passer par l'IPC).

### 4.8 Consigne (`OBJParkedPlugin`) et onglets
Inchangée côté app (on garde le proxy, donc l'instance distante). Les plugins des onglets
inactifs « gardés sans échéance » coûtent de la mémoire **dans les hôtes** et plus dans l'app ;
on pourrait même suspendre leur hôte.

### 4.9 Instruments (VSTi) et MIDI
MIDI horodaté dans le bloc partagé. Le cas sensible est le jeu live (latence §4.1, option 2).

### 4.10 Transport / tempo
`AudioPlayHead` (position, tempo, en lecture, boucle) recopié à chaque bloc dans l'entête.
Les plugins synchronisés au tempo fonctionnent sans changement.

### 4.11 Scan
Gain immédiat et isolé : le seul appel de scan qui instancie vraiment (`findAllTypesForFile` sur
les VST3 pour lire l'ARA) peut se faire dans un hôte jetable → un VST3 qui plante au scan ne tue
plus l'app. (Tracktion offre déjà `canScanPluginsOutOfProcess`.)

### 4.12 Licences / protections (iLok, UAD, Waves…)
Certains plugins vérifient le processus qui les charge (nom, signature, sandbox). Risque réel
qu'un plugin refuse de tourner dans `objekat-plughost`, ou demande une nouvelle autorisation.
À tester plugin par plugin sur la machine (UADx, Soundtoys, FabFilter, Melodyne…).

### 4.13 Bonus : pont Rosetta
Un hôte compilé x86_64 permettrait d'utiliser des plugins **Intel seulement** sur Apple Silicon.
Même mécanique, gratuit une fois le sandbox fait.

### 4.14 Built-in Tracktion et plugins maison (`ObjGain`, `OBJGainStage`, bridges…)
Restent in-process : ce sont notre code, sans risque, et ils sont collés au graphe.

---

## 5. Plan par étapes (proposition, chaque étape livrable seule)

0. **Spike de faisabilité (1–2 jours)** : un hôte minimal + proxy pour UN effet VST3 et UN AU,
   mesurer l'aller-retour à 64/128/256 échantillons, ×50 instances, avec et sans workgroup.
   Vérifier qu'un `kill -9` de l'hôte → silence, pas de crash. Tester UADx/Soundtoys (licences).
1. **Scan isolé** (§4.11) — petit, utile tout de suite.
2. **Proxy + hôte, mode A (un seul hôte)**, fenêtre (a), sans Link ni sidechain, derrière un
   réglage « sandbox (expérimental) » par plugin.
3. Crash/reprise (§4.2), cache d'état, UI d'état planté.
4. Modes B/C, promotion automatique, réglages par plugin dans le catalogue.
5. Sidechain, Link, rendus offline, MIDI/VSTi.
6. Optionnel : traitement par lot de chaîne, pont Rosetta.

---

## 6. Questions pour toi

1. **Priorité** : le but n°1 est-il *ne plus planter* ou *ne plus geler l'UI* (chargement,
   GUI lourdes) ? Ça change l'ordre des étapes (le gel concerne surtout UADx/Opal).
2. **Latence vs décrochage** (§4.1) : préfères-tu +1 bloc de latence sur les plugins sandboxés
   (jamais de décrochage global) ou zéro latence ajoutée (un plugin lent peut faire décrocher
   tout le son, comme aujourd'hui, mais sans crash) ? Ou réglable ?
3. **Défaut** : sandbox activé par défaut pour tous les AU/VST3, ou opt-in par plugin au début ?
4. **Regroupement** : un hôte par fabricant (B) te convient comme défaut ?
5. **Fenêtre** (§4.5) : acceptes-tu des fenêtres de plugin appartenant à un autre processus
   (option a), et où mettre la bande Sidechain dans ce cas ?
6. **Après un crash** : silence ou bypass (son sec) pour le plugin mort ?
7. **ARA in-process** : OK que Melodyne reste non protégé ?
8. Y a-t-il des **plugins précis qui plantent** chez toi aujourd'hui ? Ce seraient les cobayes du spike.
