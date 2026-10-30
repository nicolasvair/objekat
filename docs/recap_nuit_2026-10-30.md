# Récap de la nuit du 30 octobre 2026

Rien n'a été poussé. Aucun patch moteur n'a été publié sur le fork.

## Ce qui est sur `main` (merge `7525022f`)

`feat/audio-recording` est fusionnée entière : lots 1 à 3, enregistrement MIDI, patchs moteur 0047 et 0048.

### 1. Bug « le rec se coupe après un bloc »

**Cause trouvée.** Appuyer sur rec fait deux choses dans le même tour du thread principal :
- armer la destination ;
- lancer `transport.record()`.

Tracktion vérifie ensuite l'armement de façon asynchrone, un tour plus tard. Il trouve alors la destination déjà en train d'enregistrer et l'arrête.
- **Thread principal en retard de plus de ~10 ms** (build Debug lancé depuis Xcode, SwiftUI qui redessine) : un clip existe déjà, rien ne redémarre. Résultat : un fichier de 512 échantillons, et le transport continue.
- **Sinon** : la prise redémarre, mais perd 1 à 4 blocs au début.

Les « bonnes » prises de ta session de test étaient donc en fait des prises redémarrées. Le TimeReference BWAV de tes fichiers le confirme.

**Correctif : patch moteur `0048`.** Une destination armée ET déjà en train d'enregistrer n'est plus arrêtée.
- Branche locale `objekat-record-0048` @ `3ce916aa05e`, non publiée.
- Le prochain numéro libre est **0049**.

**Durcissements ajoutés :**
- **H2** : un changement de carte n'arrête plus la prise que si la carte a VRAIMENT changé. Avant, n'importe quel broadcast suffisait, par exemple un rescan de la liste MIDI.
- **H3** : un clic dans la timeline ou dans la liste ne déplace plus la tête du moteur pendant une prise. Seul le caret bouge. Les gestes voulus terminent toujours la prise : ⌥-clic dans la règle, retour à zéro.
- **H4** : le rattachement au workgroup se fait avant de collecter les entrées.

**Trace permanente.** Des lignes `[REC] +ms` apparaissent dans la console.

**Mesure sur la carte virtuelle :**
- **Avant** : un retard de 60 ms (à froid) ou de 30 ms (en punch-in) coupait la prise.
- **Après** : toutes les prises sont complètes, avec un seul start et un seul stop.
- **Calibration** : 0 échantillon d'erreur à toutes les tailles de buffer, avec un retard simulé de 0 ou 100 ms.

### 2. Lot UI

- Les entrées stéréo sont au-dessus des mono, partout.
- ⌘R renomme une entrée ou un stem. Le clic ne renomme plus.
- Les lignes Entrées ont le style de la liste d'objets / du Finder : séparateurs entre les lignes, lignes un peu plus hautes.
- Les VU-mètres occupent au plus 40 % de la largeur.

### 3. Enregistrement MIDI (format de session 35, sans patch moteur)

Choix pris :
- **Liste et glisser-déposer**
  - La section « Entrées MIDI » est au-dessus des entrées de la carte, même quand la carte est fermée.
  - « All MIDI Ins » est en tête de liste. Chaque ligne a une barre de vélocité.
  - Le glisser-déposer marche comme pour l'audio.
  - Une sélection mixte crée une lane par source, MIDI d'abord.
  - Pas de renommage des entrées MIDI en v1.
- **Zones et instrument**
  - Une zone MIDI = un groupe, avec UNE source.
  - Chaque zone a son instrument, choisi dans le bloc Entrée du synoptique : Choisir / Ouvrir l'éditeur / Retirer.
  - Quand la zone est armée, on entend l'instrument (écoute automatique).
  - L'instrument est copié dans chaque prise.
  - Une zone sans instrument enregistre quand même : prise muette, avec un avertissement discret (triangle orange).
  - L'éditeur de l'instrument d'une zone désarmée s'ouvre sur une instance temporaire, libérée à la fermeture de la fenêtre.
- **Prises**
  - Les prises sont des clips MIDI enfants, la plus récente en haut, en mode mute ou ajout comme l'audio, avec un seul undo.
- **Contenu enregistré**
  - Le sustain (CC 64) est replié dans la durée des notes. Les autres CC et le pitch-bend sont ignorés.
  - Pas de quantification.
  - Pas de note jouée = pas de prise.
  - Pas d'export .mid.
  - La latence de sortie est compensée : la note est calée sur le son ENTENDU (−8,6 ms mesuré sur la carte virtuelle).
- **Copier-coller entre projets** : la source de la zone devient vide, l'instrument de la zone est gardé.

### Tests passés

- `scenario_midi_record` : 73/73.
- `scenario_record` : 543/544.
  - Le seul échec est le contrôle Settings.xml.
  - Une instance graphique de l'app, lancée vers 0h30, a réécrit `~/Library/objekat/Settings.xml` : sortie BlackHole 16ch → Muse Recording, 44,1 → 48 kHz.
  - Ce n'est pas un agent. Je n'y ai pas touché. **À vérifier de ton côté.**

## Monitoring faible latence, étape 1 : branche `feat/low-latency-monitoring` (NON fusionnée)

- Worktree : `../objekat-lowlat`.
- 6 commits, de `e7046257` à `ac22a94b`.
- Aucun patch moteur.

### Choix pris

- **Une carte intermédiaire « maison »** enveloppe CoreAudio et garde le nom de type « CoreAudio ».
  - Elle ouvre la vraie carte à une petite taille H (ex. 32).
  - Tracktion continue de voir la taille de session S (ex. 512).
- **Mode direct (par défaut)** : quand H = 0 ou H ≥ S. C'est exactement le comportement d'aujourd'hui.
- **Mode file** : quand H < S.
  - Un thread de session temps réel calcule la session en avance, avec un pré-remplissage de 2S.
  - Il a son propre intervalle de workgroup CoreAudio. JUCE ne donne pas le workgroup de la carte, d'où l'API privée `makeRealAudioWorkgroup`, risque accepté.
- **Écoute des entrées** : elle est mixée dans le callback de la vraie carte, APRÈS Main.
  - Elle ne passe donc plus par les FX ni le volume de Main, même en mode direct.
  - Les pistes cachées restent seulement pour les entrées ARMÉES, pour l'enregistrement.
- **Latences annoncées à Tracktion** : entrée = latence matérielle d'entrée ; sortie = latence matérielle de sortie + file. La calibration d'enregistrement reste juste.
- **Taille retenue** : la plus grande taille offerte par la carte qui reste ≤ au réglage et < S. Par exemple, 48 demandé donne 32.
- **Réglages** : `objMonitorBufferSize` dans Settings.xml (jamais sous carte virtuelle), et la variable d'env `OBJ_MONITOR_HW_BUFFER` pour les tests.
- **UI** :
  - Menu clé à molette : le réglage de buffer devient « Buffer de la session ».
  - Nouveau sélecteur dessous : « Écoute des entrées ».
  - L'état s'affiche « 512 · écoute 32 ».
- **API** : `audio.set_hardware_buffer_size`, `audio.lowlatency.status|debug_stall|mark`, `audio.output_level`.

### Mesures (carte virtuelle, Debug, S = 512, H = 32)

- **Latence d'écoute** = latence matérielle aller-retour seule (224 images). L'écoute ne paie plus le buffer de session.
- **Calibration d'enregistrement** : 0 échantillon d'erreur en direct ET en file, pour 512/32, 512/64, 256/64 et 1024/32, à froid et en punch-in.
- **Coupures** : aucune au repos. Un retard de 300 ms provoque des coupures, puis tout récupère.
- **Démarrage du play** : +12 ms en mode file.
- **Export** : identique dans les deux modes.
- **Tests** : `scenario_low_latency` 170/170, `scenario_record` 544/544, `scenario_input_monitor` 67/67 (en direct et à H = 32).

## À tester ce matin

1. **Bug de la prise coupée**, sur `main` :
   - Depuis Xcode sur BlackHole, faire 10 cycles rec/stop rapides, en filtrant la console sur `[REC]`.
   - Puis lancer la calibration réelle :
     ```
     python3 tools/calib_record_device.py
     ```
2. **À l'œil** : l'onglet Entrées (stéréo au-dessus, séparateurs, VU à 40 %), ⌘R sur une entrée et sur un stem.
3. **MIDI** :
   - Entrées MIDI en haut de l'onglet Entrées.
   - Glisser une entrée MIDI pour créer une zone, choisir l'instrument, l'entendre une fois armée.
   - Enregistrer, puis vérifier les prises.
   - Ouvrir l'éditeur d'instrument sur une zone désarmée.
4. **Monitoring faible latence**, sur la branche `feat/low-latency-monitoring` :
   - Avec l'Apollo, mettre « Écoute des entrées » à 32 ou 64.
   - Écouter : craquements ? latence ressentie ?
   - En Release, sous charge.
   - Vérifier le sélecteur dans le menu.

Les décisions à remettre en cause en priorité : l'écoute après Main sans les FX de Main ; les +12 ms au démarrage du play.
