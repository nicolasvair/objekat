# Consolidé — retours d'essai du 2026-11-20 : plan validé

Diagnostic + plan de l'agent archi (base main 03547ff8), **validé par l'utilisateur le 2026-11-20 :
toutes les recommandations Q1–Q9 acceptées**, y compris la correction de la perte « entrée puis
annulation » (Q9).

## Retours d'origine (verbatim)
« pas besoin de montrer l'option "demander / partout / variante" si une seule occurence... soit on
enlève soit on grise ; il faudrait l'option à cocher "mémoriser" dans la boite de dialogue qui va set
le sélecteur sur partout ou variante ; j'importe un son, je le consolide, j'ouvre la consolidation,
j'essaie d'importer un autre son dans l'objet en cours d'édition depuis zone finder ou timeline, ça ne
fonctionne pas, il ne se passe rien au lâcher du drag n drop, pareil en copier coller ; si je
sélectionne un groupe de 2 objets, que je conso le groupe, mais aucun traitement ni volume ni rien
sur le groupe --> pas besoin du groupe intermédiaire, si volume /pan uniquement, on répercute ce
volume et pan sur l'objet consolidé ; dans le groupe conso en cours d'édition, je ne peux pas non plus
drag n drop un objet vers l'extérieur de l'objet consolidé, refus, en revanche je peux supprimer »

## Décisions
- Q1 : avec un seul exemplaire, **griser TOUT le sélecteur** (3 segments), valeur stockée surlignée
  mais atténuée, une seule infobulle (« Un seul exemplaire : les modifications s'appliquent
  toujours. » — FR/EN/ES), closeMode stocké conservé, API set_close_mode toujours permise.
- Q2 : case « Mémoriser » / "Remember" / "Recordar" (NSAlert suppressionButton).
- Q3 : un seul ⌘Z annule fermeture + mémorisation → écrire closeMode dans finishCloseConsolidate
  APRÈS closeSessionUndo et AVANT la construction de D′. Rien si rendu raté ou Annuler.
- Q4 : Partout + Mémoriser → propagate ; Variante + Mémoriser → variant sur D, D′ hérite.
- Q5 : ajouter un son à un contenu « clip seul » l'ENVELOPPE dans une nouvelle racine de groupe A′
  neutre (contentRootID devient var, miroirs reposés) ; PAS d'agrandissement auto de l'exemplaire
  (décision existante). + correctif 3a dans tous les cas : ne jamais toucher le moteur ni pousser
  d'undo si la cible n'est pas un groupe.
- Q6 : groupe neutre → option A (masqué à l'affichage en session, enfants remontés sous l'étage,
  A reste dans le modèle) ET option B (deconsolidate aplatit A neutre : un seul niveau). Pas de
  format, rien à migrer.
- Q7 : neutralité = groupe non infini, aucun plugin/étage de gain/instrument/ARA, volume 0, pan 0,
  non muet, fondus 0, pas d'envoi, pas d'automation, pas de boucle, fenêtre = bakeSpan des enfants,
  pas d'entrée d'enregistrement ; les MARQUEURS de G empêchent la neutralité, les commentaires non.
  Évaluée en direct.
- Q8 : sortie du contenu = option (a′) : sortie autorisée (.eject / .root / .reparent sortant) ; la
  session note les sortis (copie d'origine) et les entrés (parent, lane, start d'origine) ; Annuler
  remet les sortis dans le contenu et les entrés à leur place d'origine.
- Q9 : corriger la perte « objet glissé DANS le contenu puis annulation/⌘Z = objet disparu » (couvert
  par a′). Écrire d'abord le test qui constate le bug.

## Diagnostic (fichiers:lignes, main 03547ff8)
Voir le rapport archi ; repères principaux :
- Sélecteur : SynopticView.swift:795-796, :821/:824 ; consolidateVariantAvailable
  EditViewModel+Consolidate.swift:197-199 ; effectiveCloseMode :265-270 ; question :1083-1084.
- Boîte : askConsolidateClose EditViewModel+Dialogs.swift:227-258 (commentaire :220-222 à corriger) ;
  closeConsolidate :1081-1088 ; finishCloseConsolidate closeSessionUndo :1232, D′ :1239-1251 (:1245).
- Ajout : TimelineDropHandler.swift:363 → commitFileDrop EditViewModel+FolderImport.swift:326 (undo
  vide :337) → placeDropEntries → placeClip/addChild (EditViewModel+Clipboard.swift:96-125) ;
  paste() :304 → pastePlacement :69-88 ; addChild EditViewModel+Groups.swift:173-200 ;
  sessionDropTarget EditViewModel+ConsolidateGuards.swift:116-120 ; contentRootID let
  EditViewModel+Consolidate.swift:13 ; consolidateClip :609.
- Groupe neutre : finishConsolidate :817-826 ; ConsolidateContentRoot.swift:72-96 ;
  ConsolidateInstanceStage.swift:73-80 ; deconsolidate :1767 ; buildLaneEntries.
- Sortie : sessionMoveDropGate ConsolidateGuards.swift:110-124 (+ :91-92), Commands+Groups.swift:165-170 ;
  sessionRefusal(.delete) :52-56 ; cancelConsolidateEdit :1321-1330.

## Incréments (≥ 1 commit chacun)
1. Sélecteur grisé entier (renommer variantAvailable → hasOtherInstances ou équivalent ; nouvelle clé
   synoptic.consolidate.closeMode.disabled, retirer …variant.disabled ; glossary).
2. Mémoriser (askConsolidateClose → (mode, remember)? ; closeConsolidate(mode:remember:) ; API
   consolidate.edit_commit {remember?: bool}).
3. Ajout dans un contenu ouvert : 3a garde moteur/undo ; 3b enveloppe A′ par les trois portes (dépôt
   fichier, ⌘V, reparent timeline).
4. Groupe neutre : prédicat pur SoundObject.isNeutralContentRoot (test Swift) ; buildLaneEntries
   masque A neutre en session ; deconsolidate aplatit.
5. Sortie du contenu (a′) + correction de la perte à l'entrée.

## Tests (headless --headless --api --no-audio --no-recent, chaque suite sur sa propre instance)
Étendre tools/scenario_consolidate_variant.py :
1. Sélecteur : champ qui pilote le grisage bascule 1 → 2 exemplaires.
2. Mémoriser : edit_commit {variant, remember:true} → D et D′ variant ; un edit.undo → D′ disparaît
   ET close_mode de D revient ; un seul point d'undo ; remember:false → inchangé ; rendu raté (E17) →
   rien ; fermeture sans modif → rien ; assume_yes journalise « everywhere » sans mémoriser.
3. Ajout : 3a contenu clip seul + debug.file_drop / clipboard.paste → A devient groupe à 2 enfants,
   content_root_id change, edit_commit → wasGroup ; 3b contenu groupe → objet dans A ; 3c reparent
   timeline → étage ; 3d annulation → aucun résidu (modèle ET moteur).
4. Neutre : test Swift du prédicat (neutre / FX / boucle / automation / fondu / marqueur) ; lanes
   exposées par l'API → pas de ligne pour A neutre ; deconsolidate → un seul niveau, RMS identique ;
   anciens projets sans changement de format.
5. Sortie : eject/reparent hors de l'étage autorisés ; sortir puis annuler → contenu intact, pas de
   doublon ; 5c entrer puis annuler → objet revenu à sa place (test écrit AVANT le correctif).
Non-régression : scenario_consolidate.py, scenario_consolidate_instance_level.py,
scenario_consolidate_variant.py, scenario_cross_paste.py, scenario_file_drop_insert.py,
test_nested_drop_target.swift, test_consolidate_content_root.swift, scenario_families.py,
smoke.jsonl, i18n check/orphans, aucune fenêtre sur le pid headless.
À l'écran (utilisateur) : glisser-déposer Finder réel, geste de sortie, sélecteur grisé, case de la
boîte, affichage aplati.
