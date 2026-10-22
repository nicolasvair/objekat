# Plan — OBJEKAT sur macOS 12 / Intel (MacBook Air 2017)

Branche `feat/macos12-intel`, dépôt `objekat-macos12` (clone APFS). Rédigé le 2026-10-22 par l'architecte,
**rien n'est codé**. Plan d'implémentation + plan de test minimal pour l'agent exécutant.

Objectif : `objekat.app` universel (arm64 + x86_64), cible de déploiement **macOS 12.0**, qui se lance
et fonctionne sur un MacBook Air 2017 (Intel, macOS 12.7.6), avec un comportement **inchangé sur macOS 14+**
partout où c'est possible (`if #available` qui garde l'API native, repli seulement en dessous).

---

## 0. Ce que l'étude a établi (faits mesurés, pas des suppositions)

### 0.1 Côté C/C++/ObjC++ : rien à faire

- Build d'essai **Release, x86_64, `MACOSX_DEPLOYMENT_TARGET=12.0`** (réglages passés en ligne de commande,
  aucun fichier touché) : les **53 unités C/C++/ObjC++** (27+ TU JUCE/Tracktion, `OBJEngineCore.mm`,
  LAME, harfbuzz/sheenbidi…) compilent **sans erreur**. Seul le Swift échoue (attendu).
- **Aucun** avertissement `-Wunguarded-availability` dans le code ObjC++ (le projet est en
  `CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE`, donc un appel à une API > 12 non gardé aurait
  été signalé). Avertissements présents = dépréciations JUCE déjà connues (`getType`, `createEditorIfNeeded`).
- Les API privées sont résolues au runtime (`dlsym` pour `CGWindowListCreateImage`,
  `CGEventSetWindowLocation`) → pas de symbole manquant au lancement sur 12.
- **Aucune modification du moteur Tracktion ni de `engine-patches/` n'est nécessaire** pour x86_64.

### 0.2 Côté build : pourquoi le dernier build n'était qu'arm64

Le target `objekat`, configuration **Release**, a `ONLY_ACTIVE_ARCH = YES` (pbxproj, bloc
`DA7F47922FBA52C2004F3E72 /* Release */`). Un build Release depuis Xcode/xcodebuild ne produit donc que
l'arch de la machine. (`tools/release.sh` contourne en archivant chaque arch séparément avec
`ARCHS=… ONLY_ACTIVE_ARCH=NO`.) → passer ce réglage à `NO` suffit pour un universel.

### 0.3 Côté Swift : la liste RÉELLE des erreurs, Observation levée

Méthode : copie des sources Swift dans le scratchpad, Observation neutralisée mécaniquement, puis
`swiftc -typecheck -continue-building-after-errors` ciblant `x86_64-apple-macos12.0` avec les mêmes
réglages que le target (Swift 5, `-default-isolation MainActor`, `MemberImportVisibility`,
`InferIsolatedConformances`, `NonisolatedNonsendingByDefault`, bridging header). Itéré en neutralisant
chaque catégorie jusqu'à **zéro erreur** (5 tours) pour faire tomber les erreurs masquées.
Contre-vérifié à `macos15.6` (la couche compat prototypée ne casse rien sur 15).

Hors Observation, il reste **~200 erreurs**, toutes de disponibilité, réparties ainsi :

| Catégorie | Dispo | Sites (fichier:ligne) |
|---|---|---|
| `onChange(of:initial:)` formes 0 / 2 paramètres | 14 | **57 sites** dans ~35 fichiers (voir `grep -rn "\.onChange(of:" objekat`, 59 lignes dont 2 en forme 1 paramètre à laisser) |
| `Duration` / `ContinuousClock` / `Task.sleep(for:)` / `.components` | 13 | `CommandAPI/` : Commands+ARA 54-85, Commands+Audio 148-152, Commands+Helpers 434/438/558, Commands+Runtime 100, Commands+ScriptCanvas 438-448, Commands+ScriptPanel 79-89, Commands+View 126/157/359/418/482/516/629/631/647/683/891/893/935, JobRegistry 105-115, Quiescence 28/95-127 ; `Shared/ScriptCanvasStore 463`, `Shared/ScriptPanelStore 193` |
| `onKeyPress` + type `KeyPress` + `==`/`Hashable` de `KeyEquivalent` | 14 | SynopticZoneViews 148-149/251/535/539 ; TransportView 199/203 ; SoundLibraryView 940/944/949/950 ; SoundObjectListView 146-149 |
| `ScrollPosition` / `.scrollPosition(_:)` / `scrollTo(x:y:)` / `scrollTo(edge:)` / `onScrollGeometryChange` / `ScrollGeometry` / `onScrollPhaseChange` | **15** | TimelineView 76/1130/1133/1141/1151/4977/5006 ; StemStripsToolbarView 56/228/229/248/267/335 |
| `scrollPosition(id:)` + `scrollTargetLayout()` | 14 | SoundLibraryView 928/931 |
| `onTapGesture(count:coordinateSpace:)` (tap AVEC position) | 14 (13 pour la variante `CoordinateSpace`) | **TimelineView 1076** (le clic du canvas !), ExportWaveformView 65 |
| `SpatialTapGesture` | 13 (init avec count 14) | AutomationBandView 251, PianoRollView 210 |
| `onContinuousHover` | 14 (13) | ExportWaveformView 59, AutomationBandView 261/334, PianoRollView 216 |
| `onGeometryChange` | 13 | StemStripsToolbarView 140/224, TransportView 282, WorkspaceTabBar 46 |
| `.coordinateSpace(.named(…))` (`NamedCoordinateSpace`) | 14 | StemStripsToolbarView 199, TransportView 250, WorkspaceTabBar 74 |
| `UnevenRoundedRectangle` | 13 | CustomColorBatch 41/42, GroupBlockView 148/151, GroupBlocksCanvas 268/271, SoundBlockView 156/159 |
| `Text.foregroundStyle` (→ `ctx.resolve`/`ctx.draw` d'un `Text` échoue) | 14 | MarkerBandView 186/220, ObjectMarkersOverlay 148, ScriptOverlayLayer 114, AutomationBandView ~580/808, TimeRulerView 111/135/251/313 |
| `Font.system(_ style:design:weight:)` | 13 | StemStripsToolbarView 585/589/595 |
| `View.strikethrough` (posé après `.lineLimit`) | 13 | StemStripsToolbarView 492/502 |
| `Layout` / `ProposedViewSize` / `callAsFunction` | 13 | ObjectInspectorView 146 (appel), 830-870 (`ItemFlowLayout`) |
| `ViewThatFits` | 13 | FeatureBadgeViews 45 |
| `Grid` / `GridRow` / `gridColumnAlignment` | 13 | ShortcutCheatsheet 240-246 |
| `Path.union` | 14 | ClipEditZonesOverlay 388 |
| `CADisplayLink` (NSView) | 14 | CommandAPI/FrameMeter 22/60 (outil `perf.frames`) |
| `NSHostingView.sizingOptions` | 13 | ScriptCanvasWindow 149 |
| `.windowResizability(.contentMinSize)` | 13 | objekatApp 273 |
| `.formStyle(.grouped)` | 13 | ObjekatPreferences 102 |
| `.scrollContentBackground(.hidden)` | 13 | CommentsOverlay 110 |

Deux pièges découverts en route, **à respecter dans l'implémentation** :

1. **Le « unable to type-check this expression in reasonable time » sur `TimelineView.body` (l. 518)**
   n'est PAS une question de taille : il est causé par `onTapGesture(coordinateSpace: .local)` (l. 1076)
   qui n'a aucune surcharge valide à 12 → le solveur explose. Une fois ce site remplacé, le body passe.
   Corollaire : **toute surcharge compat qui ne matche pas un site fait exploser ce body**. D'où :
   - les helpers compat ont des **noms distincts** (`onChangeCompat`, `onKeyPressCompat`…), jamais un
     shadowing du nom SwiftUI (vérifié : shadower `scrollPosition`/`onScrollGeometryChange` avec un type
     maison fait timeout même à 15.6) ;
   - les 2 sites `onChange` en forme **1 paramètre** (`{ viewportWidth = $0 }` TimelineView 1163,
     `{ currentSelectionCursor = $0 }` TimelineView 1274) restent en `.onChange(of:perform:)` natif
     (dispo macOS 11, simplement déprécié) — les convertir en `onChangeCompat` refait exploser le body.
2. **`KeyEquivalent` n'est `Equatable`/`Hashable` qu'à partir de macOS 14.** En Swift 5 ce n'est qu'un
   *warning* (« this is an error in the Swift 6 language mode »), mais sur macOS 12 la conformance
   n'existe pas au runtime → `press.key == .upArrow`, `switch press.key { case .upArrow: }` et
   `Set<KeyEquivalent>` sont des **crashs/UB potentiels**. La couche compat doit utiliser son propre
   type de touche (comparaison par `character`). Après migration : **zéro** warning
   « conformance of 'KeyEquivalent' » dans le log de build (critère d'acceptation).

Autres constats :
- ViewBuilder à > 10 enfants : OK à 12 (vérifié), pas de travail.
- `MainActor.assumeIsolated` : rétro-déployé, OK.
- Les symboles de chaînes générés (`GeneratedStringSymbols_Localizable.swift`) sont `@available(macOS 13)`
  et ne sont pas utilisés par le code → OK.
- Aucun `Float16`, `#if arch`, `Synchronization`, `isolated deinit` → rien de spécifique x86_64 en Swift.

### 0.4 SF Symbols absents de macOS 12

Audit automatique (noms littéraux du code croisés avec
`/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist`) :
3 symboles réellement utilisés n'existent pas sur 12 (ils s'afficheraient vides, sans crash) :
- `dial.low` (macOS 13) — `Timeline/FXStripOverlayView.swift:95` (`ctx.resolve(Image(systemName:))`)
- `dial.medium` (13) — `Inspector/Synoptic/SynopticPlusPresentation.swift:198`
- `slider.horizontal.below.square.and.square.filled` (13) — `Inspector/PluginPresetMenu.swift:24`

(Les autres « hits » de l'audit — `left`, `right`, `lane`, `tree`, `space`, `clipboard` — sont des chaînes
ordinaires, pas des symboles.) Les noms construits dynamiquement ne sont pas couverts par l'audit : le
repli runtime de §3.8 les couvre de toute façon s'ils passent par lui.

---

## 1. Décisions de détail prises par l'architecte

| # | Décision | Raison |
|---|---|---|
| D1 | Ordre : **Perception d'abord en restant à 15.6**, puis couche compat **toujours à 15.6**, puis bascule à 12.0. | Chaque étape garde un build vert et testable sur cette machine ; la bascule finale ne laisse que la liste §0.3, déjà connue. |
| D2 | Nouveau dossier `objekat/Shared/Compat/` (fichiers listés §3). **Aucune** modif du pbxproj pour ces fichiers (`PBXFileSystemSynchronizedRootGroup`). | Isoler le compat, un seul endroit à supprimer le jour où la cible remonte. |
| D3 | Helpers compat à **noms distincts** suffixés `Compat`, jamais de shadowing de noms SwiftUI. | Piège §0.3-1 (timeout du solveur). |
| D4 | `onChange` : un seul couple de surcharges `onChangeCompat(of:initial:_:)` (0 et 2 paramètres), natif sur 14+. Les 2 sites à 1 paramètre restent natifs. | Prototypé et compilé à 12 et 15.6, `TimelineView.body` passe. |
| D5 | Horloges (`Duration`/`ContinuousClock`/`Task.sleep(for:)`) : remplacées **partout** (pas de `#available`) par `CompatDuration`/`CompatClock`/`Task.compatSleep`. | Code CLI/API uniquement, sémantique identique (horloge monotone `DispatchTime`), garder deux chemins n'apporterait rien. |
| D6 | `onKeyPress` : `onKeyPressCompat(…, focused:)` ; natif sur 14+ ; sur < 14, dispatch depuis le **monitor clavier existant** de `TimelineKeyHandler` (sur le chemin où il laisse passer l'événement), gardé par le focus ET la fenêtre de la vue. Type de touche maison `KeyCompat`. | Le monitor tourne avant la responder chain (cf. KeyboardClaim) : c'est exactement là qu'un `.onKeyPress` natif « reçoit » ce que le monitor laisse passer. Un second monitor indépendant aurait un ordre d'appel non documenté. |
| D7 | Scroll piloté (timeline + barre de stems) : natif sur **15+** ; sur < 15 (donc 12, 13 ET 14), pont AppKit vers le `NSScrollView` sous-jacent (`NSClipView.scroll(to:)` + `reflectScrolledClipView`, `boundsDidChangeNotification`, `will/didEndLiveScrollNotification`). | `ScrollPosition`/`onScrollGeometryChange`/`onScrollPhaseChange` sont macOS 15 : aucun équivalent SwiftUI avant. |
| D8 | Tap avec position (`onTapGesture(coordinateSpace:)`, `SpatialTapGesture`) : natif sur 14+ ; sur < 14 `DragGesture(minimumDistance: 0)` en `simultaneousGesture`, déclenché seulement si la translation finale < 3 pt. | Seul moyen SwiftUI d'avoir une position de clic sur 12 ; le seuil 3 pt est celui du `DragGesture(minimumDistance: 3)` du canvas → partition nette tap/drag. |
| D9 | `onContinuousHover` : natif sur 14+ ; sur < 14 overlay `NSViewRepresentable` à `NSTrackingArea` avec `hitTest → nil` (le motif de `SynopticHoverTracker`, `SynopticView.swift` ~l. 1160, déjà éprouvé dans le projet). | Pas d'API de position de survol SwiftUI sur 12. |
| D10 | `Text.foregroundStyle(Color)` sur les `Text` dessinés dans un `Canvas` → `.foregroundColor(Color)` **sans `#available`**. | Rendu identique pour une `Color` (tous les sites passent une `Color`) ; `foregroundColor` existe depuis 10.15. |
| D11 | `.font(.system(.caption, weight: .semibold))` → `.font(.caption.weight(.semibold))` ; `.strikethrough` déplacé **avant** `.lineLimit` (forme `Text`, 10.15) ; `.coordinateSpace(.named(x))` → `.coordinateSpace(name: x)`. Sans `#available`. | Équivalents exacts. |
| D12 | `windowResizability` : **deux types `App`** (`objekatApp` @available 13, inchangé, et `objekatAppLegacy` pour 12) choisis dans `main.swift`, le contenu commun factorisé. | `SceneBuilder` n'accepte pas `if #available` (vérifié : « closure containing control flow statement cannot be used with result builder 'SceneBuilder' ») et un `body` a un seul type. |
| D13 | Replis **dégradés** acceptés sur 12 : `ItemFlowLayout` → `LazyVGrid(.adaptive)` ; `ViewThatFits` → nom + badges en `HStack` sans arbitrage ; `Grid` → `VStack` de `HStack` à 1ʳᵉ colonne de largeur fixe ; `formStyle(.grouped)`, `scrollContentBackground(.hidden)`, `sizingOptions` → ignorés ; `Path.union` → `addPath` ; `scrollPosition(id:)` de la sonothèque → position non mémorisée entre onglets ; `perf.frames` (FrameMeter) → erreur `unsupported` (outil de banc, UI seulement). | Pas d'équivalent ; rien ne casse. |
| D14 | Perception : `@Perceptible`, `@PerceptionIgnored`, `@Perception.Bindable`, `WithPerceptionTracking`, `withPerceptionTracking` ; version **1.x la plus récente, épinglée exacte** (voir §2). | Décision utilisateur. Sur 14+, Perception délègue à Observation natif → comportement inchangé. |
| D15 | SF Symbols : `Image(compatSystemName:fallback:)` qui teste `NSImage(systemSymbolName:accessibilityDescription:)` au runtime. Replis : `dial.low`/`dial.medium` → `dial.min`, `slider.horizontal.below.square.and.square.filled` → `slider.horizontal.3`. | Sur 14+ le test réussit → symbole d'origine. |

---

## 2. Étapes ordonnées (pour l'agent exécutant)

Règles communes :
- Travailler **uniquement** dans `/Users/nicolasvair/Documents/Xcode/Objekat/objekat-macos12`, branche
  `feat/macos12-intel`. Ne JAMAIS toucher `/Users/nicolasvair/Documents/Xcode/Objekat/objekat`.
- **Un seul DerivedData** pour tous les builds : `-derivedDataPath <scratchpad>/dd`, supprimé à la fin.
  Disque : ~15 Go libres ; un build universel Release complet + SourcePackages tient en ~4-5 Go.
  (Le clone contient aussi `DerivedData/` 937 Mo et `build/` 516 Mo copiés du checkout principal,
  ignorés par git : proposer à l'utilisateur de les supprimer, ne pas le faire d'office.)
- Builds longs en arrière-plan. Commande de base :
  ```
  xcodebuild -project objekat.xcodeproj -scheme objekat -configuration <Debug|Release> \
    -derivedDataPath <dd> -skipMacroValidation -skipPackagePluginValidation build
  ```
  (`-skipMacroValidation` est obligatoire en ligne de commande dès que le macro Perception est là ;
  dans Xcode GUI, l'utilisateur devra cliquer une fois « Trust & Enable » sur `PerceptionMacros`.)
- Un commit par étape (message en anglais, comme le dépôt), build vert à chaque commit.

### Étape 1 — Ajouter swift-perception (cible encore à 15.6)

1. Déterminer la dernière version 1.x : `git ls-remote --tags https://github.com/pointfreeco/swift-perception`
   (garder la plus haute `1.y.z`, pas de 2.x — décision utilisateur). La noter dans le message de commit.
2. Éditer `objekat.xcodeproj/project.pbxproj` (objectVersion 77) — 4 ajouts, IDs hex de 24 caractères
   uniques (vérifier par grep qu'ils n'existent pas) :
   ```
   /* Begin PBXBuildFile section */
       <ID_BF> /* Perception in Frameworks */ = {isa = PBXBuildFile; productRef = <ID_PD> /* Perception */; };
   /* Frameworks phase DA7F47802FBA52C1004F3E72 : files = ( <ID_BF> /* Perception in Frameworks */, ); */
   /* PBXNativeTarget DA7F47822FBA52C1004F3E72 : packageProductDependencies = ( <ID_PD> /* Perception */, ); */
   /* PBXProject DA7F477B2FBA52C1004F3E72 : packageReferences = ( <ID_PR> /* XCRemoteSwiftPackageReference "swift-perception" */, ); */
   /* Begin XCRemoteSwiftPackageReference section */
       <ID_PR> /* XCRemoteSwiftPackageReference "swift-perception" */ = {
           isa = XCRemoteSwiftPackageReference;
           repositoryURL = "https://github.com/pointfreeco/swift-perception";
           requirement = { kind = exactVersion; version = 1.y.z; };
       };
   /* End XCRemoteSwiftPackageReference section */
   /* Begin XCSwiftPackageProductDependency section */
       <ID_PD> /* Perception */ = {
           isa = XCSwiftPackageProductDependency;
           package = <ID_PR> /* XCRemoteSwiftPackageReference "swift-perception" */;
           productName = Perception;
       };
   /* End XCSwiftPackageProductDependency section */
   ```
3. `xcodebuild -resolvePackageDependencies -project objekat.xcodeproj -clonedSourcePackagesDirPath <dd>/SourcePackages`
   → versionner `objekat.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
4. **Spike de compatibilité (bloquant)** : convertir UNE classe (`EditViewModel`, cf. étape 2) et builder
   Debug. Risque à lever : le macro `@Perceptible` dans un module en `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
   + `SWIFT_APPROACHABLE_CONCURRENCY` (conformances isolées inférées). Si le macro produit des erreurs
   d'isolation, **s'arrêter et escalader à l'architecte** (options : version de Perception différente,
   `nonisolated` explicite sur la classe… à trancher avec l'utilisateur).

### Étape 2 — Observation → Perception (cible encore à 15.6)

Inventaire (28 classes) : `AudioDeviceStatus`, `AudioDeviceWatcher` (AudioTitleBar), `AudioOutputDevice`,
`EditViewModel`, `ExportAudition`, `FXStripHoverStore` (FXStripOverlayView), `FinderSlotStore`,
`KeyboardClaim`, `ObjekatPreferences`, `ObjekatSession`, `PluginCategoryStore`, `PluginDropHint`,
`PlusShortcutStore`, `RenderProgressStore` (RenderProgress.swift), `ScriptCanvasModifiers`
(ScriptCanvasWindow), `ScriptCanvasPointer` (ScriptCanvasPlotView), `ScriptCanvasStore`,
`ScriptOverlayStore`, `ScriptPanelStore`, `ScriptPluginRegistry` (ScriptPlugins), `SoundLibraryNode` +
`SoundLibraryViewModel` (SoundLibraryView), `SynopticLevelStore`, `SynopticUIState`,
`TimelineHoverStore`, `TimelineScrollAnchor` (TimelineView), `WaveformCache`, `Workspace`.

2.1 Mécanique (sed acceptable, puis relecture du diff) :
- `import Observation` → `import Perception` ; ajouter `import Perception` à **tout** fichier qui utilise
  ensuite `WithPerceptionTracking`/`Perception.Bindable` (MemberImportVisibility est activé : l'import
  doit être dans le fichier même).
- `@Observable` → `@Perceptible` ; `@ObservationIgnored` → `@PerceptionIgnored`.
- `@Bindable var` → `@Perception.Bindable var` (15 sites : SoundLibraryView 802, DiskUsageFooterView
  18/80, SoundObjectListView 18, StemStripsToolbarView 16/561, TransportView 13/425/569, ContentView 12,
  AudioTitleBar 52, ProjectLoadOverlay 18, ExportRegionPicker 22, ExportProgressBar 24, ExportPanelView 19).
- `withObservationTracking` → `withPerceptionTracking` (ScriptCanvasPlotView 152, ExportAudition 286).

2.2 Envelopper les vues (le vrai travail) — règle :
- Tout `var body: some View` d'une vue qui lit (directement ou via une propriété calculée) une instance
  `@Perceptible` — y compris les singletons `.shared` (`KeyboardClaim.shared`, `ScriptPluginRegistry.shared`,
  `AudioDeviceStatus.shared`, `ObjekatPreferences.shared`…) et l'environnement `\.synopticLevels`
  (SynopticBoundView 544) — devient `var body: some View { WithPerceptionTracking { …corps inchangé… } }`.
  51 fichiers / ~104 bodies concernés (liste : `grep -rlE "var body: some View" objekat | xargs grep -lE "\b(<les 28 classes>)\b"`
  + les vues qui reçoivent `viewModel`/`session`/`workspace` par paramètre). En cas de doute : envelopper
  (coût nul sur 14+, négligeable sur 12).
- Les closures **paresseuses** évaluées hors du body doivent avoir leur propre `WithPerceptionTracking` :
  contenu de `GeometryReader`, lignes de `ForEach` dans `List`/`LazyVStack`/`LazyVGrid`, `.sheet`/
  `.popover`/`.contextMenu`, `ScrollViewReader`.
- `Canvas { ctx, size in … }` : le renderer s'exécute hors body → sur < 14 une lecture d'un objet
  perceptible dedans ne déclenche pas de redessin. Règle : lire les valeurs **dans le body** (`let x = vm.x`)
  avant le `Canvas` et ne capturer que des valeurs. Idem `updateNSView` des `NSViewRepresentable` :
  tout ce qu'ils lisent doit venir des propriétés passées par le body.
- `App`/`Scene`/`.commands { }` (objekatApp 246-432) : envelopper le contenu des `.commands` et le
  `WindowGroup` dans `WithPerceptionTracking` (Perception fournit les conformances `Scene`/`Commands` —
  vérifier dans les sources du package ; sinon extraire les menus dans des `View` enveloppées).
- `@State private var workspace = Workspace()` / `@State private var scripts = ScriptPluginRegistry.shared` :
  inchangé (une `@State` qui tient une référence fonctionne sur 12).

2.3 Build Debug à 15.6 + `tools/smoke.jsonl` (voir §4 T2) : comportement identique attendu (sur 15,
Perception = Observation). Commit.

### Étape 3 — Couche compat `objekat/Shared/Compat/` (cible encore à 15.6)

Chaque fichier : en-tête expliquant le pourquoi + « à supprimer quand la cible ≥ 15 ». Tout code de repli
dans des branches `if #available(macOS N, *) { natif } else { repli }`. Les closures stockées par un
pont AppKit sont **rafraîchies à chaque `updateNSView`** (piège « stale capture »,
cf. `feedback_swiftui_stale_capture` : une closure capturée au `makeNSView` gèle les props du struct).

3.1 `CompatOnChange.swift` — prototype validé (compile à 12 et 15.6) :
```swift
struct _OnChangeCompat<V: Equatable>: ViewModifier {
    let value: V; let initial: Bool; let action: (V, V) -> Void
    @State private var old: V?
    func body(content: Content) -> some View {
        content
            .onAppear { if old == nil { old = value; if initial { action(value, value) } } }
            .onChange(of: value) { new in let o = old ?? new; old = new; action(o, new) }
    }
}
extension View {
    @ViewBuilder func onChangeCompat<V: Equatable>(of value: V, initial: Bool = false,
                                                  _ action: @escaping (_ old: V, _ new: V) -> Void) -> some View {
        if #available(macOS 14, *) { onChange(of: value, initial: initial, action) }
        else { modifier(_OnChangeCompat(value: value, initial: initial, action: action)) }
    }
    @ViewBuilder func onChangeCompat<V: Equatable>(of value: V, initial: Bool = false,
                                                  _ action: @escaping () -> Void) -> some View {
        if #available(macOS 14, *) { onChange(of: value, initial: initial, action) }
        else { modifier(_OnChangeCompat(value: value, initial: initial, action: { _, _ in action() })) }
    }
}
```
3.2 `CompatClock.swift` — `CompatDuration` (Int64 ns, `.milliseconds(Int)`, `<`, `/ → Double`, `ms`),
`CompatInstant` (`DispatchTime.now().uptimeNanoseconds`, `-` → `CompatDuration`), `enum CompatClock { static var now }`,
`extension Task where Success == Never, Failure == Never { static func compatSleep(_ d: CompatDuration) async throws }`
(via `Task.sleep(nanoseconds:)`). Prototype validé.

3.3 `CompatKeyPress.swift` :
- `struct KeyCompat: Hashable, Sendable { let character: Character; static let upArrow, downArrow, leftArrow,
  rightArrow, delete, deleteForward }` construits depuis `KeyEquivalent.x.character` (lire `.character`
  ne requiert pas la conformance Equatable).
- `struct KeyPressCompat { key: KeyCompat; characters: String; modifiers: EventModifiers; phase: Phases;
  struct Phases: OptionSet { down, repeat, up, all }; enum Result { handled, ignored } }`.
- 3 modificateurs (les seules formes utilisées) :
  `onKeyPressCompat(_ key: KeyCompat, focused: Bool, action: () -> Result)`,
  `onKeyPressCompat(keys: Set<KeyCompat>, focused: Bool, phases: = [.down, .repeat], action: (KeyPressCompat) -> Result)`,
  `onKeyPressCompat(phases: = [.down, .repeat], focused: Bool, action: (KeyPressCompat) -> Result)`.
  Prototype des signatures validé : les closures existantes (`press.key == .upArrow`, `switch press.key`,
  `press.modifiers.contains(.command)`, `press.characters.first`) compilent sans changement et sans
  warning de conformance.
- 14+ : `onKeyPress(keys: Set(keys.map { KeyEquivalent($0.character) }), phases:)` natif, conversion
  `KeyPress → KeyPressCompat`, `Result` reconverti. `focused` ignoré.
- < 14 : `KeyPressFallbackHub` (@MainActor, singleton). Le modificateur pose un `.background` d'un
  `NSViewRepresentable` minuscule (`hitTest → nil`) qui, à `updateNSView`, (ré)enregistre dans le hub
  `{ window: weak NSWindow (celle de la vue), focused: Bool, keys, phases, action }` et se désenregistre
  à `dismantleNSView`. `KeyPressCompat` construit depuis `NSEvent` : `characters` =
  `event.charactersIgnoringModifiers` (⚠ ⌫ tape U+007F — `isResetKey` lit déjà le caractère, garder),
  `modifiers` depuis `modifierFlags`, phase depuis `type`/`isARepeat`.
- Branchement : dans `Timeline/TimelineKeyHandler.swift`, envelopper la closure de
  `keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged])` (l. ~1096) :
  `let r = body(event); if #unavailable(macOS 14), let r, r.type != .flagsChanged, KeyPressFallbackHub.shared.dispatch(r) { return nil }; return r`.
  Le hub ne sert que les handlers dont `focused == true` et `window === event.window`. Sur 14+ le hub
  n'est jamais appelé.
- Risque runtime à vérifier sur le Mac cible : sur macOS 12, un clic sur une vue `.focusable()` lui
  donne-t-il le focus ? `DragValueBox` force déjà le focus au tap (`grabKeyFocus`). Si les listes
  (SoundObjectListView 134, SoundLibraryView 932) ne prennent pas le focus au clic sur 12, ajouter
  `listFocused = true` dans leur tap, sous `if #unavailable(macOS 14)`.

3.4 `CompatScroll.swift` (le plus délicat) :
- `struct ScrollPositionCompat` (valeur, en `@State`) : `var _native: Any?` (un `ScrollPosition` sur 15+,
  accessible via une propriété calculée `@available(macOS 15, *) var native: ScrollPosition`) +
  `var request: (x: CGFloat?, y: CGFloat?, edge: Edge?, seq: Int)` pour le repli. `mutating func scrollTo(x:y:)`,
  `scrollTo(edge:)` : 15+ → `native.scrollTo(…)`, sinon `request` avec `seq += 1`.
- `struct ScrollGeometryCompat: Equatable` (`contentOffset`, `contentSize`, `containerSize`, `visibleRect`)
  et `enum ScrollPhaseCompat { idle, tracking, interacting, decelerating, animating }`.
- 15+ : `.scrollViewCompat(position: $pos, onGeometry: …, onPhase: …)` appliqué au `ScrollView`
  → `.scrollPosition($pos.native)` + `.onScrollGeometryChange(for:of:action:)` (mapping
  `ScrollGeometry → ScrollGeometryCompat` dans le transform, `nonisolated` comme aujourd'hui) +
  `.onScrollPhaseChange`. Sur < 15 ce modificateur ne fait rien.
- < 15 : `.scrollContentAnchorCompat(position:, onGeometry:, onPhase:)` posé **sur le contenu** du
  `ScrollView` (en `.background`) : `NSViewRepresentable` qui trouve `enclosingScrollView` (dans
  `viewDidMoveToWindow`), met `contentView.postsBoundsChangedNotifications = true`, observe
  `NSView.boundsDidChangeNotification` (→ `onGeometry`), `NSScrollView.willStartLiveScrollNotification`/
  `didEndLiveScrollNotification` (→ `onPhase` interacting/idle), et à `updateNSView` exécute la
  `request` si `seq` a changé : borne la cible au document (`documentView.frame` – `contentView.bounds.size`),
  `contentView.scroll(to:)` + `scrollView.reflectScrolledClipView(contentView)` ; `edge` → x = 0 ou x max.
  Sur 15+ ce modificateur ne fait rien.
- ⚠ À vérifier au premier essai (log temporaire) : le `documentView` SwiftUI est-il `isFlipped` ? Si non,
  `y = documentHeight - bounds.maxY`. Le contrat attendu = `contentOffset` SwiftUI (origine en haut à gauche).
- ⚠ Le pont rapporte l'offset **synchronement** (avant le natif, qui arrive après le `scrollTo`) : la
  « session de zoom » de TimelineView (commentaire l. 129-140) gèle déjà l'ancre, donc OK ; ne pas
  « corriger » ce code.
- Call sites :
  - `TimelineView` : `@State private var scrollPosition = ScrollPositionCompat()` (l. 76) ; factoriser les
    closures des deux `onScrollGeometryChange` (l. 1133-1149) et de `onScrollPhaseChange` (l. 1151)
    dans des méthodes privées (`scrollXDidChange`, `scrollYDidChange`, `scrollPhaseDidChange`) appelées
    par les deux chemins ; `scrollTo(x:y:)` l. 4976-4977 et 5006 inchangés (passent par le type compat).
  - `StemStripsToolbarView` : l. 56, 228-233 (`StemBarOverflow.init(geometry:)` prend
    `ScrollGeometryCompat`, l. 335), 248 et 267 (`scrollTo(edge:)`). Le contenu `stripsRow` reçoit l'ancre.
- `SoundLibraryView` 928/931 (`scrollTargetLayout` + `scrollPosition(id:)`, 14) : sous
  `if #available(macOS 14, *)` ; repli = rien (position non mémorisée ; le `ScrollViewReader` existant
  continue de suivre `cursorID`). Envelopper via un petit modificateur `rememberTopRowCompat(...)`.

3.5 `CompatGestures.swift` :
- `onLocatedTapCompat(count: Int = 1, coordinateSpace: CoordinateSpace = .local, perform: (CGPoint) -> Void)` :
  14+ → `onTapGesture(count:coordinateSpace:perform:)` natif ; < 14 → `simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace:).onEnded { v in if hypot(v.translation) < 3 { perform(v.location) } })`
  (count > 1 non supporté en repli : aucun site ne l'utilise avec position).
  Sites : TimelineView 1076, ExportWaveformView 65.
- `spatialTapCompat` pour AutomationBandView 251 et PianoRollView 210 : `.gesture(SpatialTapGesture()…)`
  natif sous `#available(macOS 13, *)`, sinon le même repli (ils détectent déjà le double-clic à la main).
- `onContinuousHoverCompat(perform: (HoverPhaseCompat) -> Void)` + `enum HoverPhaseCompat { active(CGPoint), ended }`
  (les `switch` existants restent identiques) : 14+ natif (mapper `HoverPhase`), < 14 overlay tracking-area
  (copier le motif `SynopticHoverTracker` : `.mouseMoved/.mouseEnteredAndExited/.activeInKeyWindow/.inVisibleRect`,
  coordonnées converties en local et retournées en y-haut). Sites : ExportWaveformView 59,
  AutomationBandView 261/334, PianoRollView 216.
- `onGeometryChangeCompat(for:of:action:)` (formes 1 et 2 paramètres d'action) : 13+ natif ; < 13
  `.background(GeometryReader { p in Color.clear.onAppear { action(transform(p)) }.onChange(of: transform(p)) { action($0) } })`.
  Sites : StemStripsToolbarView 140/224, TransportView 282, WorkspaceTabBar 46.

3.6 `CompatShapes.swift` — `UnevenRoundedRectangleCompat: Shape` avec la même signature d'init
(4 rayons, `style: RoundedCornerStyle = .continuous`) : 13+ → `UnevenRoundedRectangle(...).path(in:)`,
< 13 → chemin à arcs circulaires. Sites : CustomColorBatch 41/42, GroupBlockView 148/151,
GroupBlocksCanvas 268/271, SoundBlockView 156/159.

3.7 `CompatLayout.swift` — `ItemFlowLayout` marqué `@available(macOS 13, *)` ; dans
`ObjectInspectorView.selectionItems` extraire le `ForEach` en `@ViewBuilder` et choisir
`ItemFlowLayout(spacing: 4) { chips }` (13+) ou `LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 4)], alignment: .leading, spacing: 4) { chips }`.
`FeatureBadgeViews` 45 : `ViewThatFits` sous `#available(macOS 13, *)`, sinon le `HStack` complet.
`ShortcutCheatsheet` 240-246 : `Grid` sous `#available(macOS 13, *)`, sinon `VStack(alignment: .leading)`
de `HStack { keys.frame(width: 96, alignment: .trailing); label }`.

3.8 `CompatSymbols.swift` — `extension Image { init(compatSystemName: String, fallback: String) }`
(+ variante `String` pour les sites qui renvoient un nom) : `NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : fallback`.
Sites : FXStripOverlayView 95, SynopticPlusPresentation 198, PluginPresetMenu 24 (cf. D15).

Build Debug à 15.6 (rien ne doit avoir changé à l'écran : tous les chemins natifs sont pris). Commit.

### Étape 4 — Migrer les sites (cible encore à 15.6)

Dans l'ordre, build entre chaque groupe :
1. `onChange(of:` → `onChangeCompat(of:` sur les 57 sites à 0/2 paramètres (sed puis remettre à la main
   TimelineView 1163 et 1274 en `.onChange`). Vérifier : `grep -rn "\.onChange(of:" objekat` ne rend plus
   que ces 2 lignes.
2. Horloges (D5) : `Duration` → `CompatDuration`, `ContinuousClock.now` → `CompatClock.now`,
   `Task.sleep(for: X)` → `Task.compatSleep(X)` ; Quiescence 126-127 : `elapsed.components…` → `elapsed.ms`.
   Attention au sed : `\bDuration\b` seulement (ne pas toucher `fileDuration`, `fadeDuration`…).
3. `onKeyPress` → `onKeyPressCompat(…, focused: <FocusState>)` : SynopticZoneViews 251 (`focused`),
   535 (`baseFocused`) ; TransportView 199 (`bpmFocused`) ; SoundLibraryView 940/944/949/950
   (`listFocused`) ; SoundObjectListView 146-149 (`listFocused`). `isResetKey(_ press: KeyPress)` →
   `KeyPressCompat`. Brancher le hub dans TimelineKeyHandler.
4. Scroll (3.4), gestes/hover/géométrie (3.5), formes (3.6), layouts (3.7), symboles (3.8).
5. Petits sites sans `#available` (D10/D11) : `.foregroundStyle(` → `.foregroundColor(` sur les `Text` de
   Canvas listés §0.3 ; StemStripsToolbarView 585/589/595 (`.caption.weight(.semibold)`) et 492/502
   (strikethrough avant lineLimit) ; `.coordinateSpace(.named(x))` → `.coordinateSpace(name: x)`
   (StemStripsToolbarView 199, TransportView 250, WorkspaceTabBar 74 ; les `frame(in: .named(…))` et
   `DragGesture(coordinateSpace: .named(…))` restent tels quels, ils résolvent vers `CoordinateSpace.named`).
6. Gardes simples `if #available` : ClipEditZonesOverlay 388 (`union` sinon `addPath`), ScriptCanvasWindow 149
   (`sizingOptions`), ObjekatPreferences 102 (`formStyle`, via petit modificateur `@ViewBuilder`),
   CommentsOverlay 110 (`scrollContentBackground`), FrameMeter (classe `@available(macOS 14, *)`, la
   commande `perf.frames.*` répond `unsupported` sur < 14 — trouver l'appelant dans `Commands+View.swift`).
7. `windowResizability` (D12) : extraire de `objekatApp` le contenu commun — la vue racine du
   `WindowGroup` (ContentView + `.onAppear`/`.handlesExternalEvents`/`.onOpenURL`) en
   `struct ObjekatMainWindowRoot: View`, et le bloc `.commands { … }` (l. 274-427) en
   `struct ObjekatCommands: Commands` (avec `scriptMenu`/`scriptButton` et les helpers qu'il appelle).
   `objekatApp` (`@available(macOS 13, *)`) garde `.windowResizability(.contentMinSize)` ;
   `objekatAppLegacy` (même état : `@State workspace`, `@NSApplicationDelegateAdaptor`, `@State scripts`)
   sans. `main.swift` : `if #available(macOS 13, *) { objekatApp.main() } else { objekatAppLegacy.main() }`.
   Garder les menus STRICTEMENT identiques (relire le diff des commandes).

Build Debug 15.6 + smoke. Commit.

### Étape 5 — Basculer la cible à 12.0 et l'universel

Dans `project.pbxproj` :
- `MACOSX_DEPLOYMENT_TARGET = 15.6;` → `12.0;` (2 occurrences, configs projet Debug `DA7F478E…` et
  Release `DA7F478F…`).
- Target Release `DA7F47922FBA52C2004F3E72` : `ONLY_ACTIVE_ARCH = YES;` → `NO;`. Ne pas fixer `ARCHS`
  (défaut `ARCHS_STANDARD` = arm64 x86_64). Laisser la config Debug telle quelle.
- Pas d'`LSMinimumSystemVersion` à écrire : `GENERATE_INFOPLIST_FILE = YES` le dérive de la cible
  (vérifier dans l'Info.plist produit : `12.0`).

Builder **Debug** (arm64 seul suffit pour itérer : `-arch arm64`), corriger le résidu (normalement vide :
§0.3 est exhaustif pour l'état du code au 2026-10-22 ; tout nouveau commit sur main depuis devra être
re-vérifié). Critères : 0 erreur ; `grep "conformance of 'KeyEquivalent'" <log>` vide ; pas de nouveau
warning `is only available in macOS` dans le log.

Mettre à jour `README.md` (l. 27, 81) et `INSTALL.md` (l. 11, 15) : cible macOS 12.0, universel.
Commit.

### Étape 6 — Build Release universel + tests (§4)

`xcodebuild … -configuration Release -skipMacroValidation build` (sans `-arch` : universel).
Supprimer `<dd>` à la fin (après avoir copié l'app testée hors du DerivedData si l'utilisateur la veut).

---

## 3. Fichiers touchés (récapitulatif)

- Projet : `objekat.xcodeproj/project.pbxproj` (package, cible 12.0, ONLY_ACTIVE_ARCH Release),
  `objekat.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (nouveau).
- Nouveaux : `objekat/Shared/Compat/CompatOnChange.swift`, `CompatClock.swift`, `CompatKeyPress.swift`,
  `CompatScroll.swift`, `CompatGestures.swift`, `CompatShapes.swift`, `CompatLayout.swift` (ou inline dans
  les vues), `CompatSymbols.swift` ; `objekat/App/ObjekatCommands.swift` (+ racine de fenêtre).
- Perception : les 27 fichiers des 28 classes + ~51 fichiers de vues (WithPerceptionTracking, Bindable).
- Sites de disponibilité : App/{ObjekatPreferences, StemStripsToolbarView, TransportView, WorkspaceTabBar,
  objekatApp, main}, CommandAPI/{Commands+ARA, +Audio, +Helpers, +Runtime, +ScriptCanvas, +ScriptPanel,
  +View, FrameMeter, JobRegistry, Quiescence}, Export/{ExportWaveformView}, Inspector/{ObjectInspectorView,
  ScriptCanvasWindow, PluginPresetMenu, Synoptic/SynopticZoneViews, Synoptic/SynopticPlusPresentation},
  Shared/{FeatureBadgeViews, ScriptCanvasStore, ScriptPanelStore}, SoundObject/{SoundLibraryView,
  SoundObjectListView}, Timeline/{AutomationBandView, ClipEditZonesOverlay, CommentsOverlay,
  CustomColorBatch, FXStripOverlayView, GroupBlockView, GroupBlocksCanvas, MarkerBandView,
  ObjectMarkersOverlay, PianoRollView, ScriptOverlayLayer, ShortcutCheatsheet, SoundBlockView,
  TimeRulerView, TimelineKeyHandler, TimelineView} + les ~35 fichiers à `onChange`.
- Docs : `README.md`, `INSTALL.md`.
- **Non touchés** : `tracktion_engine/`, `engine-patches/`, `ARA_SDK/`, `lame-3.100/`, tout `.mm`/`.h`.

---

## 4. Plan de test (minimal, exécuté après coup)

| # | Test | Commande / critère |
|---|---|---|
| T1 | Build Release universel, cible 12.0, sans erreur | `xcodebuild -project objekat.xcodeproj -scheme objekat -configuration Release -derivedDataPath <dd> -skipMacroValidation build` → `** BUILD SUCCEEDED **` ; 0 ligne `conformance of 'KeyEquivalent'` dans le log |
| T2 | Architectures | `lipo -archs <dd>/Build/Products/Release/objekat.app/Contents/MacOS/objekat` = `x86_64 arm64` |
| T3 | Cible de déploiement embarquée | `/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" …/Contents/Info.plist` = `12.0` ; `vtool -show-build …/MacOS/objekat` (ou `otool -l \| grep -A4 LC_BUILD_VERSION`) → `minos 12.0` pour les deux slices |
| T4 | Lancement UI sans crash (arm64, macOS 15.8 de cette machine) | `open -n …/objekat.app --args --no-recent` ; après 15 s le process est vivant (`pgrep -x objekat`), aucun nouveau rapport dans `~/Library/Logs/DiagnosticReports/objekat*` ; puis le quitter |
| T5 | Non-régression rapide, sans écran, **slice arm64** | `…/MacOS/objekat --headless --api --socket=<scratch>/o.sock --no-recent &` puis `python3 tools/objekat_cli.py --socket <scratch>/o.sock --batch tools/smoke.jsonl` → aucune erreur ; tuer le process |
| T6 | Même smoke, **slice x86_64 via Rosetta** (cette machine est un M1 Pro, Rosetta est installée) | `arch -x86_64 …/MacOS/objekat --headless --api --socket=<scratch>/o86.sock --no-recent &` puis le même `--batch` → aucune erreur. C'est le seul moyen ici d'exécuter réellement le code Intel. |

Non vérifiable sur cette machine (à faire par l'utilisateur sur le MacBook Air 2017, macOS 12.7.6) :
- V1 Lancement réel sur macOS 12 (premier lancement d'un app ad hoc copiée : `xattr -dr com.apple.quarantine objekat.app`,
  ou clic droit ▸ Ouvrir).
- V2 **Filet Perception** : lancer un build **Debug** sur le Mac 12 et surveiller
  `log stream --predicate 'eventMessage CONTAINS[c] "Perceptible state was accessed"'` en parcourant
  timeline, inspecteur, synoptique, sonothèque, export, préférences, menus. Chaque message = une vue à
  envelopper. (Sur 14+, Perception délègue à Observation : ces avertissements N'APPARAISSENT PAS sur la
  machine de dev — le filet n'existe que sur 12/13.)
- V3 Points à l'œil sur 12 : clic/drag dans la timeline (tap vs drag, D8), molette/zoom et scroll piloté
  (pont AppKit, D7 — sens de l'axe y), ↑/↓/⌫/chiffres dans une case de valeur et dans les listes (D6),
  survol automation/piano-roll/export (D9), barre de stems qui défile vers « + ».

---

## 5. Risques

1. **Perception + isolation par défaut MainActor** (Swift 6.2, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
   conformances isolées inférées) : non testé (le package n'a pas été téléchargé pendant l'étude). Spike
   bloquant à l'étape 1.4.
2. **Vues non enveloppées** : sur 12, une vue qui lit un objet perceptible hors `WithPerceptionTracking`
   ne se rafraîchit plus — bug silencieux, invisible sur la machine de dev. Mitigation : règle large
   (§2.2), et V2 obligatoire avant de déclarer « marche sur 12 ».
3. **Pont de scroll AppKit (D7)** : dépend de l'implémentation interne de `ScrollView` macOS (NSScrollView
   + clip view). Robuste en pratique sur 12-14, mais l'axe y (flipped) et le moment où SwiftUI réécrit
   l'offset après un changement de taille du contenu sont à valider à l'écran.
4. **Focus clavier sur 12 (D6)** : `.focusable()` + clic n'a pas exactement la sémantique de 14+ ;
   possible besoin de forcer le focus au tap dans les listes.
5. **Performances** : MacBook Air 2017 = i5 bicœur 1,8 GHz, Intel HD 6000, 8 Go. La timeline Canvas
   descend déjà à ~14,5 fps à 480 objets sur M1 Pro (cf. mémoire `project_view_input_api_plan`) :
   attendre nettement moins sur l'Air. Toujours tester en **Release** (Debug ≈ ×40 plus lent sur certains
   chemins). Ce n'est pas un problème de compatibilité, mais l'utilisateur doit le savoir.
6. **Temps de build** : Perception tire `swift-syntax` (macros) → premier build plus long ;
   l'universel double la compilation C++ (le C++ x86_64 seul a pris ~3 min en Release sur M1 Pro).
7. **`tools/release.sh`** archive déjà chaque arch séparément : à garder tel quel (il produit deux zips),
   ou passer à un seul archive universel plus tard — hors périmètre ; ajouter `-skipMacroValidation` à
   son `xcodebuild archive` (sinon il échouera à cause du macro).

## 6. Ce qui NE PEUT PAS marcher (ou pas pareil) sur macOS 12 / Intel

- **Plugins AU/VST3 arm64-only** : invisibles/inchargeables sur l'Intel (seules les versions x86_64 ou
  universelles se chargent). Idem sous Rosetta (T6).
- **ARA / Melodyne** : le code hôte compile en x86_64 et n'a rien de spécifique à l'arch ; il faut une
  version Intel de Melodyne compatible macOS 12 installée sur l'Air (côté éditeur : Celemony a supporté
  12 sur ses versions 5.x — à vérifier par l'utilisateur pour la version qu'il possède). Les plugins UADx
  exigent eux-mêmes un macOS récent (UA a abandonné 12 sur ses versions récentes) → probablement
  inutilisables.
- **`perf.frames.*`** (banc de fluidité de l'API, `CADisplayLink`) : indisponible < 14 (D13).
- **Replis dégradés visibles** (D13) : flux des puces de sélection en grille, badges sans arbitrage de
  place, aide-mémoire des raccourcis en colonnes fixes, préférences sans style « grouped », éditeur de
  commentaire avec fond opaque, position de la sonothèque non mémorisée entre onglets, coins
  asymétriques en arcs circulaires au lieu de continus, 3 icônes remplacées.
- `windowResizability(.contentMinSize)` absent sur 12 → la fenêtre suit le comportement par défaut de
  macOS 12 (ne pas le « corriger » sans voir l'écran).
- Aucune API système **sans repli** n'a été trouvée : tout le reste a un équivalent ou un repli.
