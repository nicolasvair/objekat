# Prompt — monitoring faible latence à buffers multiples

> Conclusions de la discussion du 2026-10-29. Ce fichier est un prompt à donner tel quel à une future session
> (agent archi d'abord : compréhension + plan + plan de test, AUCUN code avant validation).

---

## Objectif

Pouvoir faire tourner **la session à un gros buffer** (ex. 512, confortable pour le CPU) et **le monitoring des
entrées à un très petit buffer** (ex. 32 ou 64), avec **une taille de buffer réglable par entrée** (une entrée
avec un gros plugin à 512, les autres à 32).

## Contexte existant (à relire avant tout)

- `objekat/OBJEngineCore.mm`, section `// MARK: Input monitoring` (~l. 11144) et `-syncInputMonitors` :
  aujourd'hui une entrée écoutée = **piste AudioTrack cachée** de l'Edit, ciblée par l'input device, monitor
  mode `on`, gain d'écoute = ObjGain sur cette piste, **sortie vers Main** (donc FX de Main appliqués).
- `objekat/OBJEngineCore.h` (~l. 995–1020) : API `setAudioInputMonitor`, `setAudioInputMonitorGain`,
  `setAudioInputsArmed`, enregistrement.
- `docs/plan_enregistrement_audio.md` : le système de rec actuel. Tracktion enregistre dans la piste cachée et
  fait la compensation de latence (device + graphe).
- `objekat/OBJVirtualAudioDevice.h` : carte son virtuelle déjà utilisée pour les tests headless — précédent
  pour une carte maison sous Tracktion.
- **Monitoring et objets sont complètement dissociés** : on n'écoute dans l'objet qu'APRÈS l'enregistrement.
  Le chemin live ne contient donc AUCUN objet, aucun aux, aucun stem.

## Décisions prises

1. **Rendu anticipé à avance fixe, sans invalidation.** La session est calculée en avance par blocs (ex. 512)
   sur un thread, et placée dans une file. On accepte que potards/édition/transport réagissent avec ~1 bloc
   d'avance : c'est **la même réactivité qu'une session entière à 512 aujourd'hui** (le son entendu à 512 a
   déjà été calculé au callback précédent). Donc PAS de logique d'invalidation de ce qui est en file.
2. **Le monitoring s'ajoute APRÈS Main** : il n'a plus les FX ni le volume de Main. Accepté.
3. **Architecture = carte son intermédiaire, sous Tracktion** (vise zéro patch moteur) :
   ```
   carte réelle (plus petite taille demandée, ex. 32)
     │ callback temps réel
     ├─ sortie = bloc session lu dans la file  +  Σ chemins live
     └─ file ⇄ thread temps réel ── carte VIRTUELLE à 512 ── Tracktion (session + enregistrement)
   ```
   - Tracktion ne voit qu'une carte virtuelle à 512 et tourne comme aujourd'hui.
   - La carte virtuelle **déclare des latences entrée/sortie qui incluent la file**, pour que la compensation
     d'enregistrement de Tracktion reste juste. À VÉRIFIER par mesure en boucle (loopback).
   - Le monitoring ne passe plus par les pistes cachées Tracktion : il est calculé dans le callback réel
     (entrée × gain). Les pistes cachées restent pour l'ENREGISTREMENT (monitor mode `off`).
4. **Abstraction générique « chemin »** = { taille de buffer, thread, file }. La session en est le premier
   cas (512) ; chaque entrée monitorée est un chemin avec SA taille.
   - Chemin à la taille de la carte → calculé directement dans le callback.
   - Chemin plus gros → son propre thread temps réel + file (comme la session). Bonus : répartition multi-cœur.
   - Granularité = **par entrée**, pas par plugin (mélanger dans une chaîne n'apporte rien : la chaîne a la
     latence de son maillon le plus lent).
5. **Threads temps réel obligatoires** : tout thread qui remplit une file (session, entrées à gros buffer)
   doit être rattaché à l'**audio workgroup** Core Audio (`os_workgroup`) de la carte, sinon clics sous charge.
6. **Le callback réel doit rester très léger** (il est réveillé très souvent à 32) : lire les files,
   additionner, calculer seulement les petites chaînes.

## Étapes (dans l'ordre, chacune validée avant la suivante)

1. **Monitoring audio sans FX** : carte virtuelle + file + thread temps réel pour la session ; monitoring
   entrée × gain dans le callback ; latences déclarées ; réglage de la taille de la session (ex. 512) distincte
   de la taille matérielle. Conçu dès le départ avec l'abstraction « chemin ».
2. **FX sur les entrées** : chaîne entrée → FX → gain → sortie dans le chemin live.
   - Fichier enregistré **brut** (avant FX, comme aujourd'hui avant le gain d'écoute). Option « enregistrer
     avec FX » éventuellement plus tard, pas maintenant.
   - Ces plugins sont HORS du graphe Tracktion → les héberger nous-mêmes (JUCE) tout en restant cohérents
     avec synoptique / éditeur / presets. C'est la partie la plus coûteuse.
   - Les plugins à latence (lookahead, phase linéaire) l'ajoutent au monitoring : la montrer à l'écran ?
   - Taille de buffer réglable **par entrée**.
3. **MIDI** : entrée MIDI → instrument (+ FX) → sortie, dans le chemin live.
   - **Deux instances** de l'instrument : celle de monitoring (chemin live) et celle de l'objet (session).
     Copier l'état de l'instrument cible dans l'instance de monitoring à l'armement (même principe que les
     liens de plugins).
   - À VÉRIFIER : Tracktion reçoit le MIDI directement (pas via la carte audio) ; avec la latence déclarée
     plus grande, l'horodatage des notes enregistrées peut se décaler → mesurer comme pour l'audio.

## Plan de test attendu (à préciser par l'archi)

- Alignement des prises audio en loopback (sortie → entrée) : décalage ≤ 1 échantillon, à plusieurs tailles
  session/matériel (512/32, 512/64, 256/64, 1024/32…).
- Alignement des prises MIDI (étape 3).
- Stabilité sous charge : pas de file vide (compteur d'underruns) avec une session lourde et un callback à 32.
- Le monitoring reste audible quel que soit le solo (comme aujourd'hui).
- Transport : play / stop / saut de tête de lecture → délai de démarrage ≈ 1 bloc session, position affichée
  corrigée de l'avance.
- Non-régression complète (scénarios existants, `scenario_*.py`).

## Matériel de l'utilisateur

- **Apollo 8p** (Thunderbolt). Sur Mac le buffer se règle dans le logiciel (pas dans Console) ; plancher
  pratique Core Audio = 32. Lire la vraie liste via JUCE `getAvailableBufferSizes()` sur la machine.
- L'Apollo a déjà un monitoring quasi sans latence avec FX via Console (Realtime UAD Processing, ~2 ms), mais
  limité aux plugins UAD. Notre système vise : plugins non UAD, MIDI / instruments virtuels, cartes sans DSP.

## Points encore ouverts

- Valeurs par défaut (taille session, taille matérielle) et où les régler dans l'UI (onglet Entrées ?).
- Comportement à l'export / bounce (hors temps réel : la file ne sert à rien, court-circuiter).
- Vu-mètres d'entrée : lire avant ou après la chaîne live ?
