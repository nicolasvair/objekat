# Consolidé : en sortir, répercuter ou créer une variante — plan validé (2026-11-19)

Plan de l'agent archi, **validé par l'utilisateur** le 2026-11-19 : toutes les recommandations
ci-dessous sont acceptées (Q1–Q13), vocabulaire **variante A**.

Ajout de l'utilisateur à la validation : « il faut aussi gérer les liens entre objets qui sont les
mêmes — juste adapter ce qui existe déjà ». Interprétation retenue : les **traits de lien violets**
entre exemplaires d'un même consolidé (`Shared/LinkVisuals.swift`, `LinkOverlay.drawStar(color:
.soundObject)`, armé par la sélection d'un exemplaire relié, membres =
`placementIDs(forConsolidate:excluding:)` ou équivalent actuel) doivent suivre le nouveau modèle :
après une variante, l'exemplaire forké n'est plus relié aux autres (il est relié aux exemplaires de
D′ s'il y en a) ; les exemplaires imbriqués comptent comme dans le comptage de la boîte. Adapter
l'existant, pas de nouveau visuel.

## Demande d'origine
3 usages du consolidé : wav créatif (aucun lien) ; économie de ressources (contenu partagé, les
modifs de l'intérieur se propagent ; pan/vol via FX link) ; variante (pas de lien, les modifs ne se
propagent pas). Un exemplaire fermé se manipule comme un wav (vitesse, plugins), on peut toujours
l'ouvrir ; à la fermeture : répercuter / nouvel objet ; réglage en haut du synoptique :
Demander / Répercuter / Nouvel objet. Wording à rendre beaucoup plus concis.

## État des lieux (main f4c5ad09)
- Marche déjà sur un exemplaire fermé : FX propres, mix, fenêtre, fondus, envois, stem, automation
  (niveau instance, format 26) ; couleur + nom synchronisés. Coupe OK. Vitesse/inversion acceptées
  par le modèle (`updateSpeed`/`updateReversed`, EditViewModel.swift:1910/:2057 ; inspecteur
  ObjectInspectorView.swift:662-670 ; API object.set_speed/set_reversed).
- Ouvrir : double-clic (EditViewModel+CanvasClick.swift:79-83) → `openConsolidate`
  (EditViewModel+Consolidate.swift:802). Fermer : `closeConsolidate` (:921), propage à tous
  (:1112-1117), pas de recalcul si inchangé (:950-957). Dé-consolider : `deconsolidate` (:1598).
- **Bloque** :
  1. Synoptique : zone audio absente pour un exemplaire (SynopticBoundView.swift:102-111), pilule
     Contenu à sa place par if/else exclusif (SynopticView.swift:131-134).
  2. Ouvrir/fermer perd vitesse + inversion de l'exemplaire ouvert : ouverture multiplie la fenêtre
     par la vitesse, contenu à 1 (ConsolidateInstanceStage.swift:84-96) ; `closedInstance` écrit
     speedRatio 1, isReversed false (:116-125) ; idem fermeture sans modif via
     `cancelConsolidateEdit(keepingInstanceLevel:)` (EditViewModel+Consolidate.swift:1157-1163).
     Les autres exemplaires gardent leur vitesse (ConsolidateRealign.swift:54-59).
  3. Pas d'issue « variante » : fermer = propager. Dé-consolider donne un groupe et perd la vitesse
     aussi (:1594-1595).
  4. Remplacer fichier / ARA / choix de canaux refusés aux exemplaires (Commands+Object.swift:573,
     ARAEligibility.swift:67, EditViewModel+ChannelMode.swift:29) : cohérent, NE PAS lever.

## Incréments (un commit au moins par incrément)

**INC 0 — débloquer**
- 0a. Synoptique : afficher la zone audio d'un exemplaire (vitesse, BPM, inversion, boucle ; sans
  choix de canaux ni ARA) À CÔTÉ de la pilule Contenu (SynopticBoundView.swift:105,
  SynopticView.swift:131, SynopticLayout = un rectangle de plus).
- 0b. Vitesse + inversion survivent à ouverture/fermeture : `instanceSpeed`/`instanceReversed` dans
  `ConsolidateEditSession` (lus sur `originalPlacement`) ; dans `closedInstance`, rendre la vitesse
  d'origine (durée, fondus, automation, marqueurs, boucle divisés par la vitesse ; offset en
  secondes SOURCE — convention project_offset_convention) ; inversion remise avec `mirroredInTime`
  pour l'automation ; vérifier `realignedInstance`. En session l'exemplaire ouvert s'entend à
  vitesse 1 et à l'endroit (accepté v1). Dé-consolider : garder aussi la vitesse si c'est simple,
  sinon le signaler.

**INC 1 — réglage dans le modèle**
- `closeMode: ask | propagate | variant` sur `ConsolidateDefinition` (portée = objet), décodage
  tolérant, défaut `ask`. Le reporter aux 3 sites qui reconstruisent une définition champ par champ
  (EditViewModel+Consolidate.swift:409, :696, :1098). CrossProjectImport.swift:108 copie la struct
  entière (OK).
- `SessionSchema.formatVersion` 37 → 38 + texte `_readme`.
- API `consolidate.set_close_mode {id, mode}` (avec point d'undo) ; `close_mode` + `instance_count`
  dans consolidate.list / consolidate.state. Docs API à jour.

**INC 2 — fermer en variante**
- `closeConsolidate(mode:)`, branche `variant` : même rendu, nouveau sidecar, nouvelle définition D′
  (nouvel id, révision 1, nom « Nom 2 » incrémenté, recopié sur le libellé de l'exemplaire pour que
  la synchro des noms ne renomme pas l'original ; même closeMode ; dependsOn recalculé) ;
  exemplaire remis sur D′ ; PAS de `propagateConsolidateUpdate` ni `markConsolidateResynced` ; les
  autres retrouvent D via `restoreLiveMirrors`. Fermeture sans modif = pas de fork.
- Undo en un seul point (snapshotWithSessionCancelled, :1093, :1199-1207 ; l'instantané contient
  consolidateDefinitions).
- Imbriqué : enfant forké pendant que le parent est ouvert → le contenu du parent pointe sur D′.
- API `consolidate.edit_commit {mode?}` ; sans mode et closeMode == ask (avec d'autres exemplaires)
  → `invalid_state` « mode required ». Jamais de modale depuis une commande.
- Miroirs live : coupés en mode variant, actifs en ask/propagate.
- **Liens** : adapter les traits violets (voir en tête).

**INC 3 — boîte « Demander »**
- Dans `closeConsolidate`, après le test « inchangé », avant `teardownLiveMirroring`, si closeMode
  == ask ET d'autres exemplaires existent (placementIDs(forConsolidate:excluding:) + définitions
  dont dependsOn contient D). Zéro autre → répercute sans question. Trois boutons, pas de case
  « ne plus demander ». Annuler = la session reste ouverte, aucun point d'undo.

**INC 4 — UI et vocabulaire**
- Sélecteur 3 positions en haut du synoptique, à côté de la pilule Contenu, visible ouvert ou fermé.
- Vocabulaire variante A, unifié sur exemplaire / instance / instancia :

| Où | FR | EN | ES |
|---|---|---|---|
| Sélecteur | Modifications | Edits | Cambios |
| Positions | Demander · Partout · Variante | Ask · Everywhere · Variant | Preguntar · En todas · Variante |
| Infobulle Partout | Rouvrir puis valider met à jour tous les exemplaires. | Reopening and closing updates every instance. | Reabrir y cerrar actualiza todas las instancias. |
| Infobulle Variante | Rouvrir puis valider crée un nouvel objet ; les autres exemplaires ne changent pas. | Reopening and closing creates a new object; the other instances stay as they are. | Reabrir y cerrar crea un objeto nuevo; las demás instancias no cambian. |
| Boîte, titre | Appliquer les modifications de « %@ » ? | Apply the changes to “%@”? | ¿Aplicar los cambios de «%@»? |
| Boîte, texte | %d autres exemplaires utilisent ce contenu. | %d other instances use this content. | %d instancias más usan este contenido. |
| Boutons | Partout · Nouvelle variante · Annuler | Everywhere · New variant · Cancel | En todas · Nueva variante · Cancelar |
| Pilule | Contenu : %@ | Content: %@ | Contenido: %@ |
| Infobulle Consolider | Fige en un son ; double-clic pour le rouvrir. | Freezes into a sound; double-click to reopen it. | Congela en un sonido; doble clic para reabrirlo. |

  `%d` via pluriels du String Catalog. `docs/glossary.md` à jour. `tools/i18n/xcstrings.py check`
  + `orphans`. Menu « Consolider / Dé-consolider » inchangé.

**Pas maintenant** : « Convertir en son » (Q9).

## Plan de test (headless : --headless --api --no-audio --no-recent)
Nouveau `tools/scenario_consolidate_variant.py` (modèle : scenario_consolidate_instance_level.py) :
1. Zone audio : vitesse 2 + inversion sur exemplaire fermé acceptées ; rendu moitié de durée.
2. Vitesse/inversion à travers une session (avec et sans modif) : vitesse, durée, offset, rendu
   identiques (RMS) ; autres exemplaires gardent leur vitesse.
3. Réglage : 3 valeurs ; save/réouverture conserve, formatVersion 38 ; fichier 37 → ask ; survit
   aux 3 sites de reconstruction.
4. Variante : 3 exemplaires, ouvrir le 1, gain de A, edit_commit variant → 2 définitions, le 1 sur
   D′ rév. 1, 2 et 3 sur D inchangés (révision + rendu), le 1 sonne différemment, aucune cascade.
5. Partout : les 3 changent.
6. Demander : edit_commit sans mode → invalid_state, session ouverte ; exemplaire unique → passe.
7. Undo/redo variante : un ⌘Z → D′ disparaît, le 1 lié à D et fermé ; ⌘⇧Z → D′ revient ; un seul
   point d'undo.
8. Imbrication : B contient un exemplaire de A ; ouvrir B, ouvrir A, fermer A en variante, fermer B
   → dependsOn de B contient D′ ; exemplaires de A au premier niveau intacts.
9. Inter-onglets : collé dans un autre onglet → nouvelle déf avec close_mode variant.
10. Liens : membres du lien violet d'un exemplaire forké = exemplaires de D′ seulement (via l'API
    si exposé, sinon test Swift sur la fonction de membres).
Swift : étendre tools/test_consolidate_realign.swift (aller-retour vitesse/inversion
consolidateStage → closedInstance).
Non-régression (chaque suite sur sa propre instance headless) : scenario_consolidate.py,
scenario_consolidate_instance_level.py, scenario_cross_paste.py, scenario_tabs.py,
scenario_families.py, smoke.jsonl, contrôle i18n, aucune fenêtre sur le pid headless.
À l'écran (utilisateur) : sélecteur, boîte, zone audio à côté de la pilule, traits de lien.
