#ifndef OBJEngineCore_h
#define OBJEngineCore_h

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>   // NSEvent : @see setPluginKeyFallback:

// Données de transfert Swift → C++. Zéro type JUCE/Tracktion visible en Swift.
@interface OBJSoundObjectData : NSObject
@property (nonatomic, strong) NSString* filePath;
@property (nonatomic) double startTime;   // secondes dans l'Edit
@property (nonatomic) double duration;    // 0 = longueur réelle du fichier
@property (nonatomic) float  volume;      // gain en dB (-96 … +40 ; -96 = silence/mute)
@property (nonatomic) float  pan;         // -1.0 – +1.0
@property (nonatomic) double fadeIn;        // secondes (0 = pas de fade)
@property (nonatomic) double fadeOut;       // secondes (0 = pas de fade)
@property (nonatomic) double sourceOffset;  // offset dans le fichier source (point I Sonothèque, 0 = début)
@property (nonatomic) NSInteger lane;       // lane timeline : donnée d'AFFICHAGE. Le moteur ne
                                            // s'en sert que comme clé d'allocation de piste, via
                                            // la politique du pool (@see trackSlotForKey:).
@end

@interface OBJEngineCore : NSObject

/// Coupe l'ouverture de la carte son pour TOUTE instance créée ensuite (`--no-audio`).
/// À poser avant la première construction : c'est `init` qui ouvre le périphérique.
+ (void)setAudioDisabled:(BOOL)disabled;

// Edit live — muté incrémentalement, jamais reconstruit
- (void)addSoundObject:(OBJSoundObjectData*)data withID:(NSString*)uuid;
- (void)removeSoundObjectWithID:(NSString*)uuid;
// loopRangeStart/loopRangeEnd : bornes IN/OUT de la boucle en SECONDES FICHIER (repère
// sourceOffset), ignorées si loopEnabled=NO. @see [[loop-item-plan]]
- (void)updatePosition:(double)startTime duration:(double)duration sourceOffset:(double)sourceOffset loopEnabled:(BOOL)loopEnabled loopRangeStart:(double)loopRangeStart loopRangeEnd:(double)loopRangeEnd forID:(NSString*)uuid;
- (void)updateVolume:(float)volume pan:(float)pan forID:(NSString*)uuid;
- (void)updateFadeIn:(double)fadeIn fadeOut:(double)fadeOut forID:(NSString*)uuid;
- (void)updateIsReversed:(BOOL)reversed forID:(NSString*)uuid;
- (void)updateSpeedRatio:(double)ratio forID:(NSString*)uuid;
// Change la lane d'un objet top-level : son clip passe sur la piste porteuse de la lane cible
// (le clip et ses plugins survivent au déplacement). Sans effet pour un enfant de groupe, qui
// vit dans le container de son groupe et non sur une piste.
- (void)setLane:(NSInteger)lane forID:(NSString*)uuid;

// MARK: - MIDI
// addMidiClip : crée un ContainerClip dont l'unique enfant est un clip MIDI, posé comme tout
//   objet sur la piste de sa lane (ou dans le container de son groupe). Même chaîne qu'un clip
//   audio — fader ObjGain + fenêtre/fade — l'instrument en tête. `data.filePath`/`sourceOffset`
//   sont ignorés, `data.lane` non. L'instrument et les FX s'ajoutent ensuite via setInstrument /
//   compileUserRack.
// setMidiNotes : remplace les notes du clip MIDI. Chaque dict : @{@"pitch":@int (0-127),
//   @"start":@double, @"length":@double (en BEATS), @"velocity":@int (0-127)}.
// setInstrument : insère l'instrument virtuel en TÊTE de la chaîne du container (index 0).
//   pluginInfo : @{@"identifier":…, @"format":…, @"name":…, @"pluginKey":… (id d'instance)}.
//   Remplace l'instrument courant. Retourne le pluginKey enregistré (éditeur/params) ou nil.
// removeInstrumentForObjectID : retire l'instrument (index 0) s'il existe.
- (void)addMidiClip:(OBJSoundObjectData*)data withID:(NSString*)uuid;
- (void)setMidiNotes:(NSArray<NSDictionary*>*)notes forID:(NSString*)uuid;
// setMidiLoop : le motif de notes entre [startBeats, endBeats] (BEATS — le clip MIDI convertit
// lui-même via le tempo de l'édit) se répète tant que la fenêtre de l'objet le dépasse.
// `enabled=NO` désactive. @see [[loop-item-plan]]
- (void)setMidiLoop:(BOOL)enabled startBeats:(double)startBeats endBeats:(double)endBeats forID:(NSString*)uuid;
- (NSString* _Nullable)setInstrument:(NSDictionary*)pluginInfo
                          forObjectID:(NSString*)uuid
                             stateXML:(NSString* _Nullable)stateXML;
- (void)removeInstrumentForObjectID:(NSString*)uuid;

// Outil Ciseaux — retourne YES si le split a réussi
// Le clip original est raccourci à [origStart, splitTime].
// Un nouveau clip [splitTime, origEnd] est créé sous newID avec le bon offset fichier.
- (BOOL)splitSoundObjectWithID:(NSString*)uuid
                        atTime:(double)splitTime
                         newID:(NSString*)newID;

// Bus de stem — FolderTrack par stem
// createStemBus  : crée un FolderTrack pour le stem (appel unique à l'init du stem).
// disbandStemBus : remonter les membres au top-level et supprimer le FolderTrack.
// assignObjects:toStemID: : déplace les AudioTracks des objets dans le FolderTrack du stem.
// moveObject:fromStemID:toStemID: : réaffecte un objet d'un stem à un autre (nil = Main).
- (void)createStemBus:(NSString*)stemID;
- (void)disbandStemBus:(NSString*)stemID memberIDs:(NSArray<NSString*>*)memberIDs;
- (void)assignObjects:(NSArray<NSString*>*)objectIDs toStemID:(NSString*)stemID;
- (void)moveObject:(NSString*)objectID
       fromStemID:(NSString* _Nullable)oldStemID
         toStemID:(NSString* _Nullable)newStemID;

// Mixer (increment 1) : VU + gain des stems et du master (sortie générale).
// audioLevelForStem / audioLevelForMaster : niveau 0..1 (RMS -60..0 dB), à poller pour le VU.
// setStemGain / setMasterGain : niveau de bus en dB (mastering = plugins sur le master).
- (float)audioLevelForStem:(NSString*)stemID;
- (void)setStemGain:(float)dB stemID:(NSString*)stemID;
- (float)audioLevelForMaster;
- (void)setMasterGain:(float)dB;

// Routage du bus vers le Main (master). YES = sortie du FolderTrack vers le device par défaut
// (sommé dans le Main, défaut) ; NO = sortie détachée (le bus ne contribue plus au Main ; son VU,
// pris en amont dans le pluginList du folder, reste lisible). Sans effet sur le Main lui-même.
- (void)setStemRouteToMain:(BOOL)routeToMain stemID:(NSString*)stemID;

// Pas de mute de bus ici : muter un stem se fait objet par objet, en poussant -96 dB sur leurs
// faders (EditViewModel+Audibility). Couper la sortie du FolderTrack laissait les taps d'envoi
// de ses objets — prélevés en fin de chaîne, donc en amont du bus — continuer d'alimenter les
// aux : la réverbe d'un stem muté sonnait encore dans le Main.

// INC 2 — chaîne FX par bus : le rack user d'un stem (FolderTrack) ou du master se compile
// via compileUserRackForObjectID: en passant l'UUID du stem (ou la clé du Main). Déclare quelle
// clé représente le Main → userPluginListForKey: la route sur getMasterPluginList().
- (void)setMasterStemKey:(NSString*)mainStemID;

// Groupes audio — modèle FolderTrack submix (refactor « 1 clip = 1 track, groupe = bus »).
// Un groupe = un FolderTrack submix SANS position timeline (identité timeline = pur modèle Swift).
// Ses enfants sont des AudioTracks normaux (créés par addSoundObject) déplacés DANS le folder ;
// un sous-groupe = un FolderTrack déplacé DANS le folder parent (imbrication native Tracktion).
//   createGroupFolder        : crée le FolderTrack submix (bus FX/gain) du groupe.
//   assignObject:toGroupFolder: déplace la piste de l'objet (clip OU sous-groupe) dans le folder.
//   disbandGroupFolder       : remonte les membres directs au parent du folder, puis le supprime.
//   removeGroupFolder        : supprime le folder (les descendants doivent être retirés avant).
- (void)createGroupFolder:(NSString*)groupID;
- (void)createGroupFolder:(NSString*)groupID lane:(NSInteger)lane;
- (void)assignObject:(NSString*)objectID toGroupFolder:(NSString*)groupID;
- (void)disbandGroupFolder:(NSString*)groupID memberIDs:(NSArray<NSString*>*)memberIDs;
- (void)removeGroupFolder:(NSString*)groupID;
// Fenêtre + fades du groupe (bornes [start,end] + fadeIn/fadeOut en secondes edit) →
// plugin ObjWindowFade en fin de chaîne du folder. Gate non-destructif + fade post-bus.
// `loopEnabled` : le motif entre [loopStart,loopEnd] (secondes EDIT ABSOLUES, même repère que
// start/end — c'est celui du ContainerClip) se répète tant que [start,end] le dépasse, au lieu
// de laisser du silence — sans objet pour un groupe infini (pas de fenêtre). @see [[loop-item-plan]]
- (void)updateGroupWindow:(NSString*)groupID
                    start:(double)startSecs
                      end:(double)endSecs
                   fadeIn:(double)fadeInSecs
                  fadeOut:(double)fadeOutSecs
              loopEnabled:(BOOL)loopEnabled
                loopStart:(double)loopStartSecs
                  loopEnd:(double)loopEndSecs;

// AUX — returns temporels génériques (objet « reçoit-seulement »), INTERNES à un groupe.
// createAux        : ContainerClip marqué bus d'aux ; il ne joue pas de contenu, il somme les
//                    envois qui le visent, puis passe sa chaîne de FX et ses fades.
// updateAuxWindow  : bornes [start,end] + fadeIn (entrée) / fadeOut (queue, sortie).
// removeAux        : supprime le container aux ET les envois qui le visaient.
// addSend/removeSend/setSendLevel : ObjAuxSendPlugin en fin de chaîne de l'émetteur (donc
//                    post-fader et post-fenêtre : ce qu'on entend est ce qu'on envoie).
//
// PORTÉE : émetteur et aux doivent être FRÈRES. Deux fratries : enfants directs d'un même
// ContainerClip (le retour est monté dans le graphe local du groupe), ou tous deux TOP-LEVEL
// (le retour est monté à la racine de l'Edit, au-dessus de la somme des pistes). Franchir la
// frontière d'un container reste impossible — c'en est une, dans les deux sens. Tout appel
// hors de ces cas est refusé (et journalisé une fois). @see EditViewModel.canRouteSend
- (void)createAux:(NSString*)auxID lane:(NSInteger)lane;
- (void)createAux:(NSString*)auxID;   // compat : lane 0
- (void)updateAuxWindow:(NSString*)auxID
                  start:(double)startSecs
                    end:(double)endSecs
                 fadeIn:(double)fadeInSecs
                fadeOut:(double)fadeOutSecs;
- (void)removeAux:(NSString*)auxID;
- (void)addSend:(NSString*)senderID toAux:(NSString*)auxID levelDb:(float)levelDb;
- (void)removeSend:(NSString*)senderID toAux:(NSString*)auxID;
- (void)setSendLevel:(NSString*)senderID toAux:(NSString*)auxID levelDb:(float)levelDb;

// MARK: - Bake — rendu offline
// Rend la sortie complète du sous-mix d'un groupe (FolderTrack + sous-pistes : dry, bus FX,
// returns d'aux internes) dans un fichier wave, EN TÂCHE DE FOND : rendu sur une COPIE de l'Edit
// (rôle forRendering → ne touche jamais le graphe live), via EditRenderer async sur son propre
// thread. La lecture et l'édition continuent normalement pendant le rendu. `completion` est
// appelé sur le main thread avec YES/NO une fois le wave écrit (ou en cas d'échec). Le détach/
// bypass se font sur la copie (jetée à la fin) — l'Edit live est intact, rien à restaurer.
- (void)renderGroupToFileAsync:(NSString*)groupID
                      filePath:(NSString*)filePath
                         start:(double)startSecs
                           end:(double)endSecs
                    completion:(void(^)(BOOL ok))completion;

// Bake d'un CLIP simple (tâche de fond) : rend sa chaîne de FX user en un wave, en bypassant son
// fader (ObjGain) et en neutralisant ses fades natifs (gardés live sur le clip baké). Même
// mécanique de fond (copie d'Edit) que le bake de groupe. `completion` sur le main thread.
- (void)renderClipToFileAsync:(NSString*)clipID
                     filePath:(NSString*)filePath
                        start:(double)startSecs
                          end:(double)endSecs
                   completion:(void(^)(BOOL ok))completion;

// MARK: - Capture de trace — geler ce qu'un plugin fait à UN signal
//
// Une session cesse d'être portable dès qu'elle s'appuie sur un AudioUnit : ouverte sur une
// autre machine, le plugin manque et le mix n'est plus le mix. Capturer une TRACE enregistre ce
// que le plugin fait à CE signal précis, sous forme affine et échantillon par échantillon —
//
//     y[n] = g[n] · x[n] + d[n]
//
// — de sorte qu'on puisse le restituer sans lui. Exact par construction pour tout traitement
// déterministe, tant que l'entrée reste la même.
//
// LA PROCÉDURE tient en deux ou trois rendus offline, dans le même contexte de graphe, à la même
// fréquence et avec la même taille de bloc :
//   • la passe B (signal réel) DEUX FOIS, puis le null test entre les deux. C'est lui qui décide
//     de la suite, et c'est pourquoi il passe avant tout le reste ;
//   • plugin déterministe → passe A (entrée nulle) pour obtenir `d_free`, la composante que le
//     plugin produit tout seul — un SIGNAL complet, pas une constante : ronflement, dérive
//     lente, bruit de fond ;
//   • plugin non déterministe → PAS de passe A et rien à soustraire. La réalisation captée sur
//     du silence serait un autre tirage : la soustraire ajouterait du bruit au lieu d'en
//     retirer. On fige une performance, et le rapport le dit.
//
// `regionStart`/`regionEnd` sont les bornes de l'objet, en secondes d'edit. `preRoll` (2 s au
// moins) laisse les détecteurs et les cellules de lissage se stabiliser ; `tail` (5 s au moins)
// laisse sortir les queues et les releases longs.
//
// `options` (facultatif) : @{@"g_max": @64.0, @"x_min_db": @(-100.0), @"merge_gap": @16}.
//
// `completion` est appelé sur le thread principal avec un rapport. `ok` = NO porte `error` et
// `message` ; `ok` = YES porte le chemin du fichier, le `status` de validation
// (exact / acceptable / problem), les résidus mesurés et les drapeaux du format. Une capture à
// la fois : un appel pendant qu'une autre tourne est refusé (`error` = "busy").
- (void)capturePluginTrace:(NSString*)pluginKey
                  objectID:(NSString*)objectID
               regionStart:(double)regionStart
                 regionEnd:(double)regionEnd
                   preRoll:(double)preRollSecs
                      tail:(double)tailSecs
                  filePath:(NSString*)filePath
                   options:(NSDictionary* _Nullable)options
                completion:(void(^)(NSDictionary* report))completion
                NS_SWIFT_UI_ACTOR;

// Avancement de la capture en cours (0…1, toutes passes confondues), 0 si aucune.
- (float)traceCaptureProgress;

// YES tant qu'une capture est en cours.
- (BOOL)isCapturingTrace;

// Demande l'arrêt de la capture en cours. Le completion arrive avec `error` = "cancelled".
- (void)cancelTraceCapture;

// L'en-tête d'une trace posée sur le disque, sans charger ses données. Sert au modèle Swift à
// afficher l'état d'un slot tracé et à vérifier sa péremption (`input_hash`). nil si le fichier
// est absent ou n'est pas une trace lisible par cette version.
- (NSDictionary* _Nullable)readTraceHeader:(NSString*)filePath;

// La RESTITUTION ne s'installe pas par une méthode à elle : elle passe par la compilation de
// chaîne comme n'importe quel plugin. Une entrée de `compileUserRackForObjectID:tree:` qui porte
// @"tracePath" produit un nœud de trace au lieu d'un plugin — même clé, même place, même bypass,
// même ordre. @see resolvedPluginTreeForInfo:stateXML:

// MARK: - Export — rendu du MIX COMPLET
//
// Rend la sortie générale de l'Edit — toutes les pistes, tous les bus de stems, chaîne de
// mastering et fader master compris — dans un wave. Aucune liste blanche de clips ni de pistes :
// on veut TOUT ce qui sonne.
//
// DEUX RÉGIMES, choisis par `onEditCopy` — c'est le seul vrai arbitrage de cet export :
//
//   • YES — COPIE. On clone l'Edit en rôle forRendering et on rend le clone ; la lecture et
//     l'édition continuent pendant ce temps. Prix à payer : le clone INSTANCIE tous les AU du
//     projet sur le thread principal avant de rendre la main. Un bake s'en tire en ne chargeant
//     que sa chaîne (@see OBJRenderPluginFilter) ; un export ne le peut pas — il rend justement
//     tout le reste. Sur un projet chargé en AU, c'est plusieurs secondes d'interface figée
//     AVANT même que le rendu commence. (Optimisation identifiée et pas encore faite : borner ce
//     chargement aux clips que la fenêtre IN-OUT fait sonner — voir le commentaire détaillé sur
//     la branche `onEditCopy` dans OBJEngineCore.mm.)
//
//   • NO — DIRECT. On rend l'Edit VIVANT, avec les plugins déjà instanciés : le rendu démarre
//     immédiatement. En échange, l'Edit est retiré du device manager le temps du rendu (la
//     lecture s'arrête et reprend à la fin) et le projet ne doit PAS être modifié pendant ce
//     temps — le graphe de rendu lit les mêmes objets que l'éditeur. À l'appelant de le dire à
//     l'utilisateur ; le moteur, lui, ne verrouille rien.
//
// Dans les deux cas le rendu lui-même tourne sur son propre thread : avancement et annulation
// fonctionnent pareil.
//
// `sampleRate` est la fréquence de RENDU (le graphe entier tourne à cette fréquence, plugins
// compris) et `bitDepth` vaut 16, 24 ou 32 (32 = flottant). `dithering` est indépendant de la
// profondeur — c'est un choix, pas une conséquence : bruit de dispersion ajouté avant la
// quantification pour casser la distorsion de troncature. Sans effet en 32 bits flottant, où
// rien n'est quantifié.
// `completion` est appelé sur le main thread : `ok` = NO porte un message d'erreur lisible
// (échec d'écriture, projet muet, ou « Cancelled » après cancelExport).
//
// Un seul export à la fois : un appel pendant qu'un export tourne est refusé (completion NO).
//
// NS_SWIFT_UI_ACTOR déclare ce que fait déjà l'implémentation : le completion est marshalé sur
// le thread principal (juce::MessageManager::callAsync). Sans cette annotation, Swift importe
// le bloc comme non isolé et refuse d'y toucher au view-model.
- (void)exportMixToFileAsync:(NSString*)filePath
                       start:(double)startSecs
                         end:(double)endSecs
                  sampleRate:(double)sampleRate
                    bitDepth:(NSInteger)bitDepth
                   dithering:(BOOL)dithering
                  onEditCopy:(BOOL)onEditCopy
                  completion:(void(^)(BOOL ok, NSString* _Nullable errorMessage))completion
                  NS_SWIFT_UI_ACTOR;

// Avancement de l'export en cours (0…1), 0 si aucun. À poller pour une barre de progression.
- (float)exportProgress;

// YES tant qu'un export est en cours (rendu lancé, completion pas encore appelée).
- (BOOL)isExporting;

// Demande l'arrêt de l'export en cours. Le completion sera appelé avec ok=NO et le message
// « Cancelled » ; le fichier partiellement écrit est à effacer par l'appelant.
- (void)cancelExport;

// Plugins VST3/AU — rack par objet sonore
// availablePlugins : liste des plugins connus (scan préalable ou cache)
// Chaque dict : @{@"name":…, @"manufacturer":…, @"identifier":…, @"format":…}
- (NSArray<NSDictionary*>*)availablePlugins;

// hasCachedPlugins : YES si un cache UserDefaults existe (evite un scan au démarrage)
- (BOOL)hasCachedPlugins;

// scanPlugins : scan async VST3+AU, appelle completion sur le main thread avec la liste
// Sauvegarde automatiquement le résultat dans UserDefaults.
- (void)scanPluginsWithCompletion:(void(^)(NSArray<NSDictionary*>*))completion;

// clearPluginCache : supprime le cache UserDefaults (force un nouveau scan au prochain lancement)
- (void)clearPluginCache;

// addPlugin:toObjectID : insère le plugin dans le rack de l'objet.
// Retourne un identifiant d'instance (pluginKey) ou nil si échec.
- (NSString* _Nullable)addPlugin:(NSDictionary*)pluginInfo toObjectID:(NSString*)uuid;

// addPlugin:toObjectID:stateXML : variante avec restauration d'état.
// Si stateXML est non nil et représente un ValueTree "PLUGIN" valide, le plugin est
// recréé directement depuis cet arbre (round-trip Tracktion : params built-in +
// state binaire externe restaurés). Sinon, comportement identique à addPlugin:toObjectID:.
- (NSString* _Nullable)addPlugin:(NSDictionary*)pluginInfo
                      toObjectID:(NSString*)uuid
                        stateXML:(NSString* _Nullable)stateXML;

// getPluginStateXML : état complet du plugin sérialisé en XML (params built-in +
// state binaire externe), ou nil si le plugin est introuvable. À sauvegarder dans
// le projet et à repasser à addPlugin:toObjectID:stateXML: à l'ouverture.
- (NSString* _Nullable)getPluginStateXML:(NSString*)pluginKey;

// removePlugin:fromObjectID : retire le plugin (par pluginKey = ObjectPlugin.id.uuidString)
- (void)removePlugin:(NSString*)pluginKey fromObjectID:(NSString*)uuid;

// setPlugin:enabled:forObjectID : bypass/unbypass
- (void)setPlugin:(NSString*)pluginKey enabled:(BOOL)enabled forObjectID:(NSString*)uuid;

// movePlugin:toIndex:forObjectID : réordonne le plugin dans la chaîne.
// toIndex = index final dans le tableau modifié (après retrait de la position source).
- (void)movePlugin:(NSString*)pluginKey toIndex:(int)toIndex forObjectID:(NSString*)uuid;

// Diagnostic : log tous les AU/VST3 trouvés (dossiers + scan JUCE) dans la console Xcode
- (void)diagnosticScanPlugins;

// ÉTAPE 2 — compilateur déclaratif : (re)construit en UN SEUL RackType toute la chaîne FX
// user de l'objet à partir de l'arbre passé (source de vérité = modèle Swift). Réconcilie
// les Plugin::Ptr par id (réutilise/crée/retire), puis reconstruit toutes les connexions.
// Chaque entrée de `tree` :
//   feuille : @{@"id":…, @"kind":@"plugin", @"identifier":…, @"format":…, @"name":…,
//              @"stateXML":… (optionnel), @"enabled":@(BOOL)}
//   bloc // : @{@"kind":@"rack", @"voices":@[ @[<entrées série>], … ]}
// Retourne la liste des pluginKeys NON RÉSOLUS (introuvables) — le caller les retire du modèle.
- (NSArray<NSString*>*)compileUserRackForObjectID:(NSString*)uuid
                                             tree:(NSArray<NSDictionary*>*)tree
                                        chainInDb:(float)chainInDb
                                       chainOutDb:(float)chainOutDb;

// Niveau audio mesuré (0..1) à la sortie d'un plugin du rack (vu-mètre par carte synoptique).
- (float)audioLevelForPluginKey:(NSString*)pluginKey forObjectID:(NSString*)uuid;

// Gain dB d'une voie parallèle (ObjGain de fin de voie), ajusté à chaud (sans recompiler).
- (void)setVoiceGain:(float)dB forBlockID:(NSString*)blockID voiceIndex:(int)vi objectID:(NSString*)uuid;

// Gain dB de début (output:NO) / fin (output:YES) de chaîne, ajusté à chaud (sans recompiler).
// Retourne NO si le rack n'existe pas encore (objet sans chaîne jamais compilé).
- (BOOL)setChainGain:(float)dB output:(BOOL)isOutput objectID:(NSString*)uuid;

// Paramètres AUTOMATABLES d'un plugin — built-in Tracktion comme AU/VST : c'est
// `getAutomatableParameters()` qui répond, et il vaut pour les deux familles. L'ordre du tableau
// EST l'index attendu par `setPluginParam:index:`.
//
// Deux pièges pour l'appelant :
//  • un plugin EXTERNE dont l'instance n'est pas encore chargée (chargement asynchrone) répond une
//    liste VIDE — ce n'est pas « ce plugin n'a pas de paramètres », c'est « pas encore » ; ne pas
//    mettre ce résultat en cache (@see pluginInstanceState:) ;
//  • `minValue`/`maxValue` sont dans l'UNITÉ RÉELLE du paramètre. Les externes sont normalisés
//    0…1 par Tracktion, mais un built-in ne l'est PAS (une fréquence va de 30 à 18000). Toute
//    valeur poussée est bornée sur cette plage côté moteur.
// Chaque dict : @{@"name":…, @"paramID":…, @"value":@float, @"minValue":@float, @"maxValue":@float, @"valueAsString":…}
- (NSArray<NSDictionary*>*)getPluginParams:(NSString*)pluginKey;
- (void)setPluginParam:(NSString*)pluginKey index:(int)index value:(float)value;

// MARK: - Automations — courbes de paramètre
//
// Une courbe se pousse ENTIÈREMENT, jamais point par point : le modèle Swift fait foi et
// l'appel REMPLACE ce que le moteur porte. Une liste vide efface donc la courbe, et le
// paramètre reprend de lui-même sa valeur statique (celle du dernier setGainDb/setLevelDb) —
// c'est ainsi qu'on retire une automation, et ainsi qu'on neutralise celle d'un objet réduit au
// silence par un mute/solo, dont le fader doit rester au -96 poussé par updateVolume:.
//
// TEMPS EN SECONDES DE L'EDIT, pas relatif à l'objet : la conversion se fait côté Swift, seul
// endroit où vit le début de l'objet. Elle vaut aussi pour un objet DANS un groupe — le
// ContainerClip d'un groupe porte un offset égal à son début, donc temps local = temps edit
// (@see refreshContainerSpanForKey:), et cela reste vrai à deux niveaux d'imbrication. Corollaire
// à ne pas oublier côté appelant : tout déplacement ou rognage de l'objet impose un nouveau push.
//
// Chaque point : @{@"t":@double (secondes edit), @"v":@float (unité du paramètre),
//                  @"c":@float (courbure du segment sortant, -1…+1)}. Les points doivent être
// TRIÉS par temps croissant.
//
// Pousser une courbe ne reconstruit PAS le graphe audio : c'est une édition de ValueTree, dont
// le moteur ne tire qu'un recalcul différé (10 ms) de l'itérateur d'automation du paramètre.
typedef NS_ENUM(NSInteger, OBJAutomationTarget) {
    OBJAutomationTargetVolume = 0,  // fader ObjGain de l'objet, paramètre « gain » (dB)
    OBJAutomationTargetPan,         // fader ObjGain de l'objet, paramètre « pan » (-1…+1)
    OBJAutomationTargetTrimIn,      // trim d'ENTRÉE de la chaîne user, « gain » (dB)
    OBJAutomationTargetTrimOut,     // trim de SORTIE de la chaîne user, « gain » (dB)
    OBJAutomationTargetSend,        // ObjAuxSend vers `targetKey` (= auxID), « level » (dB)
    OBJAutomationTargetPlugin,      // plugin user `targetKey`, paramètre `paramID`
};

// Silencieux si la cible n'existe pas côté moteur (objet dont le rack n'a jamais été compilé,
// envoi non câblé, plugin retiré) : le modèle fait foi et repoussera quand elle existera.
- (void)setAutomationCurve:(NSArray<NSDictionary*>*)points
                 forObject:(NSString*)uuid
                    target:(OBJAutomationTarget)target
                 targetKey:(NSString* _Nullable)targetKey
                   paramID:(NSString* _Nullable)paramID;

// LINK d'instances de plugin : associe pluginKey à un groupe (groupID). Tant que ≥2
// plugins partagent un groupID, toute modif d'un paramètre automatable de l'un est
// répercutée sur les autres (matching par index — instances du MÊME plugin). Idempotent.
// Doit être (ré)appelé après (re)création des instances (ex. chargement de projet).
- (void)setPluginLinkGroup:(NSString*)pluginKey groupID:(NSString*)groupID;
// Détache pluginKey de son groupe (retire les listeners). À appeler avant destruction.
- (void)clearPluginLinkGroup:(NSString*)pluginKey;

// Rattache pluginKey à un groupe qu'il avait quitté, en ADOPTANT ses réglages : les valeurs
// des paramètres d'un membre encore actif sont recopiées sur lui AVANT que ses propres
// listeners ne soient armés. Sans cette précaution, le rejoignant pousserait ses réglages sur
// tout le groupe au premier paramètre touché — l'inverse de ce qu'on veut d'un retour.
// Sans membre actif (groupe entièrement détaché), il garde ses réglages et rouvre le groupe.
- (void)relinkPluginAdoptingGroup:(NSString*)pluginKey groupID:(NSString*)groupID;

// Éditeur natif du plugin — ouvre une fenêtre DocumentWindow JUCE.
// Ne fait rien pour les plugins Tracktion built-in (pas d'éditeur natif).
// Si la fenêtre est déjà ouverte, la ramène au premier plan.
// colorHex : couleur d'identité de l'instance (0xRRGGBB, @see ObjectPlugin.colorIndex),
// utilisée pour teinter la barre de titre JUCE et le liseret de la fenêtre.
- (void)openPluginEditor:(NSString*)pluginKey colorHex:(NSInteger)colorHex;

// Ferme l'éditeur natif du plugin (si ouvert).
- (void)closePluginEditor:(NSString*)pluginKey;

// L'éditeur natif du plugin a-t-il une fenêtre ouverte ? Ne dit RIEN des éditeurs built-in,
// qui vivent côté Swift (@see EditViewModel.builtInEditorWindows).
- (BOOL)isPluginEditorOpen:(NSString*)pluginKey;

// Fait flotter ou non les éditeurs natifs (niveau « toujours au premier plan »).
// Les éditeurs sont flottants par défaut, pour rester visibles au-dessus de la fenêtre
// principale. Il faut pouvoir les redescendre le temps qu'une UI de l'app doive passer devant
// (l'explorateur de plugins) : un popover AppKit reste au niveau normal, il ne peut pas
// franchir le niveau flottant. Le réglage vaut aussi pour les éditeurs ouverts ensuite.
- (void)setPluginEditorsFloating:(BOOL)floating;

// YES quand le focus clavier est dans un champ de SAISIE DE TEXTE d'une fenêtre de plugin.
// Il y a deux familles d'éditeurs, donc deux détections — celle-ci ne couvre que la seconde :
//  - vue Cocoa native (AU d'Apple, plugins non-JUCE) : le premier répondant est un NSTextView
//    (un NSTextField passe par son field editor), ce que le monitor clavier voit tout seul ;
//  - GUI JUCE (la plupart des VST3/AU) : toute la fenêtre est UNE NSView, rien de natif n'a le
//    focus — seul JUCE sait quel composant le détient. D'où cette question posée au moteur.
// Sert au monitor clavier de la timeline : pendant une frappe de texte, les lettres appartiennent
// au plugin, pas aux raccourcis d'outils.
- (BOOL)isEditingTextInPluginEditor;

// YES si le focus clavier est dans une fenêtre d'ÉDITEUR DE PLUGIN (quelle qu'elle soit).
//
// Les deux détections ci-dessus sont impuissantes devant une GUI qui traite `keyDown:` elle-même
// dans une NSView opaque, sans champ AppKit ni JUCE à interroger : les UADX, par exemple. Aucun
// hôte ne sait deviner qu'une telle GUI édite du texte — pas plus Ableton que nous. Ce qu'ils
// font, et ce qu'on fait désormais : quand une fenêtre de plugin a le focus, on la laisse servir
// la touche EN PREMIER, et on ne récupère que ce qu'elle n'a pas consommé (@see
// setPluginKeyFallback:). Une saisie dans le plugin ne peut alors plus déclencher un outil.
- (BOOL)isPluginEditorWindowKey;

// Bout de chaîne des fenêtres d'éditeur : appelé pour toute touche qu'une fenêtre de plugin a
// laissée remonter sans la consommer (la GUI native décline, l'événement remonte la chaîne des
// répondants jusqu'à la fenêtre JUCE, qui nous le passe). Le bloc rend YES s'il l'a traitée.
// C'est ce qui rend R/T/V/P/E et Suppr à la timeline pendant qu'un éditeur a le focus.
- (void)setPluginKeyFallback:(BOOL (^ _Nullable)(NSEvent* _Nonnull))handler;

// Notifié quand une fenêtre d'éditeur NATIVE (VST/AU) s'ouvre (isOpen=YES) ou se ferme
// (isOpen=NO, y compris via son bouton de fermeture). pluginKey = ObjectPlugin.id.uuidString.
// Les éditeurs built-in (sheet SwiftUI) ne passent PAS par ici — gérés côté Swift.
@property (nonatomic, copy, nullable) void (^onEditorVisibilityChanged)(NSString * _Nonnull pluginKey, BOOL isOpen);

// Retourne YES si le plugin a un éditeur natif disponible (ExternalPlugin + hasEditor).
- (BOOL)pluginHasEditor:(NSString*)pluginKey;

// MARK: - Écoute des paramètres (objet sonore OUVERT, re-miroir vivant)
//
// Tant qu'un objet sonore est ouvert, on veut reposer ses miroirs dès que l'utilisateur touche un
// FX du contenu édité — y compris les mouvements de knob LIVE dans un éditeur natif/built-in, qui
// ne passent PAS par le modèle Swift. `beginObjectEditParamWatch:` installe un écouteur sur tous
// les params automatables des plugins USER des objets `objectKeys` (exemplaire matérialisé +
// descendants) ; chaque changement de valeur appelle
// `onObjectEditParamChanged` sur le main thread. Les plugins système (ObjGain/ObjWindowFade/VU)
// sont ignorés — leurs params ne représentent pas une modif de contenu (et le VU spammerait).
@property (nonatomic, copy, nullable) void (^onObjectEditParamChanged)(void);
- (void)beginObjectEditParamWatch:(NSArray<NSString*>*)objectKeys;
- (void)endObjectEditParamWatch;
// Pousse l'état courant des plugins surveillés dans leur ValueTree (chunk externe inclus) : à
// appeler juste avant de reposer un miroir ou de baker, pour que la lecture du sous-arbre capture
// les réglages LIVE des plugins externes (dont le state n'est pas synchronisé en continu).
- (void)flushObjectEditPluginStates;

// MARK: - Dernier paramètre TOUCHÉ (éditeur de plugin ouvert)
//
// Sert à la ligne de « future automation » : la bande d'automation d'un objet propose le dernier
// paramètre qu'on a réglé sur lui. Les paramètres pilotés par le modèle Swift (fader, pan, trims,
// envois) se captent côté Swift ; les paramètres d'un plugin, non — un knob tourné dans une GUI
// native AU/VST ne traverse jamais le pont.
//
// PORTÉE VOLONTAIREMENT MINUSCULE, et suffisante : on ne peut toucher un paramètre de plugin que
// par un éditeur OUVERT. On n'écoute donc que les plugins dont l'éditeur est à l'écran — zéro à
// trois à un instant donné — au lieu de poser un écouteur par paramètre de chaque plugin de la
// session (un AU en a des centaines ; c'est exactement le coût que `beginObjectEditParamWatch:`
// s'est refusé). Un plugin sans éditeur ouvert ne peut être touché QUE par le modèle Swift, qui
// sait déjà ce qu'il fait.
//
// Le watch RETIENT le plugin (`Plugin::Ptr`) : ses paramètres restent donc valides même si le
// plugin quitte la chaîne pendant que sa fenêtre vit encore. Appeler `end` reste la règle — c'est
// ce qui rend le plugin ET retire les écouteurs.
//
// « Toucher » = SAISIR, pas dérégler. Deux signaux, et le premier compte le plus : le geste de
// prise (`parameterChangeGestureBegin`, qu'une GUI native émet dès qu'on attrape un knob, avant
// tout mouvement) et le changement de valeur. Attraper un paramètre sans le bouger suffit donc à
// le désigner — sans quoi il faudrait dérégler ce qu'on veut automatiser pour pouvoir l'automatiser.
//
// Les changements dus à la LECTURE d'une courbe sont ignorés (un paramètre déjà automatisé a déjà
// sa ligne : le proposer n'aurait aucun sens, et il se re-signalerait à chaque bloc audio).
//
// La VALEUR accompagne la touche, NORMALISÉE 0…1 sur la plage annoncée du paramètre (même
// convention linéaire que `getPluginParams:` / `setPluginParam:`) : le moteur l'a sous la main à
// cet instant précis, et la redemander plus tard coûterait une requête par image de rendu.
@property (nonatomic, copy, nullable) void (^onPluginParamTouched)(NSString * _Nonnull pluginKey,
                                                                   NSString * _Nonnull paramID,
                                                                   float value01);
- (void)beginPluginParamTouchWatch:(NSString*)pluginKey;
- (void)endPluginParamTouchWatch:(NSString*)pluginKey;

// État de chargement d'un plugin externe :
//   0 = inconnu (clé absente de _pluginMap)
//   1 = en cours de chargement (instance audio pas encore prête)
//   2 = prêt (instance audio active, ou plugin built-in)
//   3 = erreur (loadError non vide)
- (int)pluginInstanceState:(NSString*)pluginKey;

// Message d'erreur de chargement Tracktion (nil si absent ou aucun).
- (NSString* _Nullable)pluginLoadError:(NSString*)pluginKey;

// Diagnostic dlopen d'un bundle VST3 : vérifie existence, architecture, et charge le binaire
// directement pour obtenir l'erreur précise. Résultats dans la console Xcode.
- (void)diagnosVST3Load:(NSString*)bundlePath;

// Diagnostic complet pour un plugin AU ou VST3 :
//   Q1 — Le format est-il enregistré dans le PluginFormatManager ?
//   Q2 — findAllTypesForFile retourne-t-il des types valides ?
//   Q3 — Quel ValueTree ExternalPlugin::create produit-il ?
//   Q4 — PluginFormatManager::createPluginInstance réussit-il directement ?
- (void)diagnosePlugin:(NSString*)identifier format:(NSString*)format name:(NSString*)name;

// Transport
- (void)play;
- (void)stop;
- (void)seekTo:(double)seconds;
- (double)currentPlaybackPosition;
- (BOOL)isCurrentlyPlaying;

// Tempo et signature temporelle
- (double)getTempo;
- (void)setTempo:(double)bpm;                        // remap=YES (compat init)
- (void)setTempo:(double)bpm remap:(BOOL)remap;      // flag explicite
- (double)getClipStartTimeForID:(NSString*)uuid;     // lit position clip dans Tracktion
- (NSInteger)getTimeSigNumerator;
- (NSInteger)getTimeSigDenominator;
- (void)setTimeSig:(NSInteger)numerator denominator:(NSInteger)denominator;

// Loop Tracktion — distinct du mode loop Objekat (loopModeEnabled dans EditViewModel).
// Ces méthodes pilotent uniquement l'état interne du moteur Tracktion.
// Le déclenchement est géré depuis ContentView quand le playhead entre dans la loopRegion.
- (void)setTracktionLoopRegionFrom:(double)start to:(double)end;
- (void)activateTracktionLoop;
- (void)deactivateTracktionLoop;

// Device
- (NSArray<NSString*>*)availableOutputDevices;
- (void)setOutputDevice:(NSString*)name;
// Nom du device de sortie ACTUELLEMENT utilisé par le moteur (nil si aucun device ouvert).
// Sert à initialiser le picker de la toolbar sur la vérité moteur (et non le 1er de la liste).
- (NSString* _Nullable)currentOutputDeviceName;

// Réglages audio avancés du device COURANT (menu « paramètres audio » de la toolbar).
// Fréquence d'échantillonnage et taille du buffer (= latence) proposées/appliquées via
// l'AudioDeviceSetup JUCE. Les listes dépendent du device ouvert ; vides si aucun device.
- (NSArray<NSNumber*>*)availableSampleRates;      // Hz
- (double)currentSampleRate;                       // Hz (0 si aucun device)
- (void)setSampleRate:(double)rate;
- (NSArray<NSNumber*>*)availableBufferSizes;       // frames
- (NSInteger)currentBufferSize;                    // frames (0 si aucun device)
- (void)setBufferSize:(NSInteger)frames;

@end

#endif /* OBJEngineCore_h */
