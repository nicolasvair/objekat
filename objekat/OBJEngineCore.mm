//
//  OBJEngineCore.mm
//  objekat
//

#import "OBJEngineCore.h"
#import <AppKit/AppKit.h>   // notifications d'activation de l'app (éditeurs suivant le focus)
#import <AudioUnit/AudioUnit.h>
#include <tracktion_engine/tracktion_engine.h>
#include "OBJGainPlugin.h"
#include "OBJWindowFadePlugin.h"
#include "OBJParallelBlockPlugin.h"
#include "OBJAuxSendPlugin.h"
#include "OBJTrace.h"
#include "OBJTraceProbePlugin.h"
#include "OBJTracePlaybackPlugin.h"
#include <unordered_map>
#include <unordered_set>
#include <set>
#include <string>
#include <vector>
#include <array>
#include <algorithm>
#include <cmath>
#include <functional>
#include <dlfcn.h>

namespace te = tracktion;

// Filtre de chargement des plugins pendant la construction d'un CLONE DE RENDU.
//
// `Edit::EditRole::forRendering` ne vaut que `playDisabled` — il n'implique PAS `pluginsDisabled`
// (c'est `forExporting` qui le porte). Un clone charge donc tous les plugins de l'Edit, alors
// qu'un bake ne rend qu'une piste, détachée à la racine, avec `useMasterPlugins` à faux : tout AU
// hors de la chaîne rendue s'instancie pour rien, sur le thread principal. Mesuré sur une session
// à 6 AU dont un seul servait : 5,9 s des 6,9 s de blocage.
//
// L'état est GLOBAL, et c'est le point d'entrée qui l'impose — `shouldLoadPlugin` ne transporte
// que le plugin. Sa portée reste sûre parce que la construction du clone est synchrone et se fait
// sur le thread principal : tout plugin construit pendant la fenêtre appartient au clone.
struct OBJRenderPluginFilter {
    static inline bool                    active = false;
    static inline std::set<te::EditItemID> allowedClips;
    static inline te::EditItemID           targetTrack;

    // Vrai si ce plugin appartient à la chaîne rendue. On REMONTE jusqu'au premier CLIP ou
    // TRACK — c'est lui le propriétaire. Remonter, et pas se contenter du parent direct, parce
    // qu'un plugin de bloc parallèle vit sous le PLUGIN qui l'héberge et non sous son clip.
    static bool wants(const juce::ValueTree& pluginState) {
        for (auto v = pluginState.getParent(); v.isValid(); v = v.getParent()) {
            if (te::Clip::isClipState(v))
                return allowedClips.count(te::EditItemID::fromID(v)) > 0;
            if (te::TrackList::isTrack(v))
                return te::EditItemID::fromID(v) == targetTrack;
        }
        return false;   // ni clip ni piste au-dessus : hors de ce qu'on rend
    }

    struct Scope {
        Scope(const std::vector<te::EditItemID>& clips, te::EditItemID track) {
            allowedClips.clear();
            allowedClips.insert(clips.begin(), clips.end());
            targetTrack = track;
            // Chaîne VIDE = objet inconnu, et le rendu prend alors toute la piste : on ne filtre
            // pas, faute de savoir ce qui doit sonner. @see renderChainForKey:.
            active = !allowedClips.empty();
        }
        ~Scope() { active = false; allowedClips.clear(); }
    };
};

// Comportement moteur custom : relève les limites par défaut de Tracktion.
// La valeur par défaut maxPluginsOnClip vaut 5 ; comme chaque clip embarque déjà
// un ObjGainPlugin post-FX, l'utilisateur ne pouvait ajouter que 4 plugins avant
// de heurter le jassertfalse dans PluginList::insertPlugin.
struct OBJEngineBehaviour : public te::EngineBehaviour {
    // @see OBJRenderPluginFilter. Hors clonage de rendu, le comportement natif s'applique
    // (`p.edit.shouldLoadPlugins()`), donc le graphe live n'est jamais amputé.
    bool shouldLoadPlugin(te::ExternalPlugin& p) override {
        if (!OBJRenderPluginFilter::active) return te::EngineBehaviour::shouldLoadPlugin(p);
        return OBJRenderPluginFilter::wants(p.state);
    }

    te::EditLimits getEditLimits() override {
        auto limits = te::EngineBehaviour::getEditLimits();
        // Branche containerclip : TOUTE la chaîne d'un objet (trims, FX user, fader, fenêtre)
        // vit désormais sur sa CLIP plugin-list — c'est cette limite-là qui borne le nombre de
        // FX par objet, et non plus celle de la piste. 5 slots système (dont l'instrument d'un
        // objet MIDI, en tête de SA chaîne de clip) + 40 FX utilisateur.
        limits.maxPluginsOnClip    = 45;
        limits.maxPluginsOnTrack   = 20;
        limits.maxNumMasterPlugins = 20;
        return limits;
    }

    // OBJEKAT n'a pas de « clip launcher » (grille de slots à la Ableton) : tout se
    // joue sur la timeline. Or Tracktion emballe CHAQUE piste dans un
    // ArrangerLauncherSwitchingNode chargé d'arbitrer entre les deux, plus un
    // écouteur de minuterie partagée par nœud. Mesuré : 348 nœuds sur 3765 (9 %)
    // pour un arbitrage qui n'a jamais rien à arbitrer. C'est aussi la source de
    // l'assertion « duplicate nodeID » qui pollue la console en Debug.
    bool areClipSlotsEnabled() override { return false; }

    // Appairage des canaux physiques : OBJEKAT est une application STÉRÉO — tout part au main,
    // il n'y a aucune UI de routage multicanal. On décrit donc nous-mêmes les devices wave :
    // des paires L/R consécutives, plus un mono résiduel si la carte a un nombre impair de
    // canaux. Aucune entrée (l'app ne s'enregistre pas).
    //
    // Pourquoi c'est nécessaire, et pas seulement propre :
    // le socle moteur multicanal choisit l'appairage dans cet ordre — describeWaveDevices, puis
    // l'état stocké (AUDIODEVICE_LAYOUT), puis l'ancien format (monoChansOut), puis le défaut.
    // Sans cette surcharge, la migration depuis l'ancien format a converti une vieille
    // préférence « première paire en mono » en deux devices mono sur les canaux 0 et 1. Le
    // device par défaut mémorisé ne résolvant plus, checkDefaultDevicesAreValid retombe sur le
    // PREMIER device activé = le mono canal 0 : le master, pourtant stéréo, ne sortait plus que
    // par la gauche. Et comme le layout est stocké par TYPE de device (« CoreAudio ») et non par
    // carte, changer de carte son ne rebattait rien.
    //
    // En déclarant l'appairage ici, on devient la source autoritaire : l'état stocké n'est plus
    // ni lu ni réécrit (DeviceManager::saveSettings saute l'enregistrement du layout), donc
    // aucune préférence héritée ne peut plus désappairer la sortie.
    bool isDescriptionOfWaveDevicesSupported() override { return true; }

    void describeWaveDevices (std::vector<te::WaveDeviceDescription>& descs,
                              juce::AudioIODevice& device, bool isInput) override
    {
        descs.clear();

        if (isInput)
            return;

        const int numChannels = device.getOutputChannelNames().size();

        for (int i = 0; i < numChannels; ++i) {
            const bool canBeStereo = i + 1 < numChannels;
            descs.push_back (te::WaveDeviceDescription::withNumChannels ({}, (uint32_t) i,
                                                                        canBeStereo ? 2 : 1, true));
            if (canBeStereo) ++i;
        }
    }
};

// Logger JUCE silencieux : capte tout juce::Logger::writeToLog (macro TRACKTION_LOG)
// — sinon Tracktion crache au démarrage la liste des devices MIDI/Wave sur la console.
// Nos propres diagnostics passent par NSLog et ne sont donc pas affectés.
// Alloué une fois et jamais libéré (leak volontaire) pour éviter l'assert
// ~Logger (jassert currentLogger != this) à la fin du process.
struct OBJSilentLogger : public juce::Logger {
    void logMessage(const juce::String&) override {}
};

// Purge des alias de « track input devices » accumulés dans Settings.xml.
//
// Le moteur tracktion v3.2.0 publié écrit, dans InputDevice::setAlias(), une entrée de réglages
// PERMANENTE par device d'entrée de piste — y compris pour les devices virtuels « Track Wave Input »
// / « Track MIDI Input » que le moteur crée pour CHAQUE piste. Comme OBJEKAT crée une piste par
// objet sonore / lane / stem et que la clé est indexée par un compteur monotone
// (« invalid_Track Wave Inputin_<N>_alias »), le fichier grossit à chaque session et n'est jamais
// purgé. Le garde `! isTrackDevice()` n'est arrivé en amont qu'avec le refactor multicanal
// (tracktion 1e1a7d2c097, 27/02/2026) : le sous-module de cette branche l'a, mais rien ne supprime
// les entrées déjà écrites par les versions précédentes.
//
// Or juce::PropertiesFile::loadAsXml() insère via StringPairArray::set(), qui fait un scan linéaire
// des clés déjà chargées : le chargement est O(n²). Mesuré sur une install réelle : 19 282 entrées
// dont 19 224 mortes → 50 s de démarrage (build Debug), tout entières dans le constructeur de
// te::Engine. Après purge : 1,3 s.
//
// On nettoie donc le fichier sur DISQUE, avant de construire le moteur — un nettoyage après coup
// n'accélérerait que le lancement suivant, puisque c'est la construction elle-même qui paie.
static void purgeStaleTrackDeviceAliases() {
    auto file = juce::File::getSpecialLocation(juce::File::userApplicationDataDirectory)
                    .getChildFile("objekat").getChildFile("Settings.xml");
    if (! file.existsAsFile()) return;

    // Pré-filtre texte : évite de parser le XML à chaque démarrage quand il n'y a rien à purger.
    auto text = file.loadFileAsString();
    if (! text.contains("Inputin_")) return;

    auto xml = juce::XmlDocument::parse(text);
    if (xml == nullptr) return;

    int removed = 0;
    for (auto* child = xml->getFirstChildElement(); child != nullptr;) {
        auto* next = child->getNextElement();
        auto name = child->getStringAttribute("name");
        if (name.endsWith("_alias")
            && (name.startsWith("invalid_Track Wave Inputin_")
                || name.startsWith("invalid_Track MIDI Inputin_"))) {
            xml->removeChildElement(child, true);
            ++removed;
        }
        child = next;
    }

    if (removed > 0 && file.replaceWithText(xml->toString()))
        NSLog(@"[OBJ] Settings.xml : %d alias de pistes obsolètes purgés", removed);
}

// Applique gain (dB) + pan sur un ObjGainPlugin déjà repéré (le fader de l'objet).
static void applyGainAndPan(te::Plugin::Ptr fader, float gainDb, float pan);

// Insère le plugin de gain de sortie en DERNIER (post-FX) dans la plugin list.
static te::Plugin::Ptr insertObjGain(te::PluginList& plugins) {
    return plugins.insertPlugin(te::ObjGainPlugin::create(), plugins.size());
}

// ─────────────────────────────────────────────────────────────────────────────
// MODÈLE MOTEUR « containerclip »
//
// Objectif : que le coût du graphe suive ce qui JOUE, pas ce qui EXISTE. Trois
// bascules par rapport au modèle de référence (« 1 objet = 1 AudioTrack, groupe =
// FolderTrack submix, FX dans un RackType ») :
//
//   1. UNE PISTE = UN COMPARTIMENT D'ORDONNANCEMENT, pas une ligne de l'interface.
//      Les objets top-level sont des CLIPS posés sur la piste que leur alloue la
//      politique du pool (`trackSlotForKey:lane:`, `_poolTracks`) ; la chaîne
//      propre à un objet (trims, FX, fader, fenêtre/fades) vit sur sa CLIP
//      plugin-list. La lane, elle, ne dit rien au moteur — @see « Pool de pistes ».
//   2. UN GROUPE = UN ContainerClip posé sur la piste de son compartiment ; ses
//      enfants sont des clips DANS le container, à leur position absolue. La chaîne
//      de bus du groupe vit sur la plugin-list du container. Un AUX et un OBJET MIDI
//      sont eux aussi des ContainerClip — le premier sans enfant (il somme les envois
//      qui le visent), le second avec pour unique enfant son MidiClip et l'instrument
//      en tête de sa chaîne. Tout objet d'Objekat est donc un clip, et un seul.
//   3. CHAÎNE FX SANS RACK. Plus de RackType/RackInstance (le graphe d'un rack est
//      bâti à la racine de l'Edit et relie ses Send/Return par le graphe en cours de
//      transformation — invisible depuis le graphe local d'un container) : les plugins
//      user sont insérés directement dans la plugin-list hôte. Les blocs parallèles du
//      synoptique deviennent des ObjParallelBlockPlugin, une PluginList par branche,
//      que le moteur déplie en SummingNode (voir compileSeries:into:anchor:order:failed:).
//
// Conséquences assumées : les vu-mètres par plugin retournent 0 (ils vivaient dans le rack).
// Les queues de plugin (reverb/delay) sont coupées à la fin du clip, puisque le
// nœud de clip ne produit plus rien au-delà de ses bornes.
// (Les sends/AUX, eux, ne sont plus des no-op : @see « AUX et sends ».)
// ─────────────────────────────────────────────────────────────────────────────

// Étendue du ContainerClip d'un groupe : STRICTEMENT l'union des positions de ses enfants,
// tenue à jour par refreshContainerSpanForKey:. L'offset vaut le début de cette étendue, donc
// temps local = temps edit et les enfants gardent leurs positions ABSOLUES. (Une seule exception :
// sous BOUCLE l'offset se décale de −loopStart pour caler la phase du repli — le temps local reste
// de même nature, il est juste avancé. @see refreshContainerSpanForKey:)
//
// ⚠️ CRITIQUE POUR LES PERFS — ne jamais donner une étendue « infinie » à un container :
//   • le CombiningNode de la piste indexe ses clips par tranches de 8 s et ne traite (ni ne
//     prefetche) que ceux qui croisent le bloc courant. Un container de 24 h atterrit dans les
//     10800 tranches et se retrouve donc traité à CHAQUE bloc — avec tous ses enfants, car
//     DynamicOffsetNode traite ses nœuds internes en bloc.
//   • pire, la construction du graphe l'insère dans ces 10800 tableaux : 38 groupes = ~400 000
//     insertions par reconstruction.
// C'était la cause du stutter dès qu'une session comptait quelques dizaines de groupes.
//
// Étendue d'un container VIDE (créé avant que ses enfants n'y entrent) : minuscule, il ne
// produit de toute façon aucun nœud (createNodeForContainerClip sort si getClips() est vide).
static constexpr double kEmptyContainerSpanSecs = 0.001;

// Fenêtre par défaut d'un ObjWindowFade à la création : grande ouverte, en attendant que le
// modèle pose la vraie. Simple paramètre de plugin, sans effet sur le graphe — à ne pas
// confondre avec l'étendue du container ci-dessus. TOUT objet en porte un, container compris :
// c'est lui qui coupe la queue des FX (et celle de l'instrument d'un objet MIDI) à la fin de
// l'objet, et qui pose les fondus juste avant le point de prélèvement des envois.
// @see installObjectChainTail
static constexpr double kOpenWindowSecs = 86400.0;

// Au-delà, la fenêtre reçue pour un groupe signifie « infini » (le modèle envoie
// EditViewModel.infiniteWindowEnd = 1e9) : le container suit alors ses enfants au lieu de
// prendre des bornes qu'aucune session réelle n'atteint.
static constexpr double kInfiniteWindowThresholdSecs = 1.0e8;

// Index d'insertion d'un plugin user dans une plugin-list hôte : juste AVANT `anchor`
// (le trim de fin de chaîne, ou à défaut le fader), sinon en fin de liste.
static int indexBefore(te::PluginList& plugins, const te::Plugin::Ptr& anchor) {
    if (anchor) {
        int i = plugins.indexOf(anchor.get());
        if (i >= 0) return i;
    }
    return plugins.size();
}

// DÉPLACE `p` juste AVANT `anchor` dans `pl` (en fin de liste si `anchor` est absente).
//
// Le détachement est fait ICI, avant de demander l'index : `PluginList::insertPlugin` relève
// l'index d'arbre de l'ancre PUIS appelle `removeFromParent()`. Quand le plugin déplacé était
// déjà DEVANT l'ancre — le cas normal d'une recompilation — son retrait décale l'ancre d'un cran
// vers la gauche, et le plugin atterrit DERRIÈRE elle. Ce qu'on payait : dans une branche
// parallèle le FX passait derrière son gain de voie (le gain réglait alors son ENTRÉE, d'où « le
// niveau ne fait rien ») ; à la racine, la chaîne user passait derrière trimOut dans l'ordre
// INVERSE du modèle, et l'état alternait correct/inversé à chaque compile.
//
// Détaché d'abord, `insertPlugin` voit l'ancre à sa place définitive et n'a plus rien à retirer.
// L'instance survit au détachement : le Ptr de `_pluginMap` la tient, et le cache de plugins la
// retrouve par identité de ValueTree (état, éditeur ouvert, link préservés).
static void movePluginBefore(te::PluginList& pl, const te::Plugin::Ptr& p,
                             const te::Plugin::Ptr& anchor) {
    if (!p) return;

    p->removeFromParent();
    pl.insertPlugin(p, indexBefore(pl, anchor), nullptr);

    // Un refus d'insertion (limite de plugins, liste qui n'accepte pas ce type) laisserait le
    // plugin détaché, donc muet et invisible : le dire, plutôt que d'y perdre une soirée.
    if (pl.indexOf(p.get()) < 0)
        NSLog(@"[FX] ordre : insertion de '%s' refusée — plugin laissé détaché",
              p->getName().toRawUTF8());
}

// MARK: - Compilateur déclaratif arbre → chaîne LINÉAIRE
//
// L'arbre (source de vérité = modèle Swift) garde sa forme d'origine :
//   feuille : { id, kind:"plugin", identifier, format, name, stateXML?, enabled? }
//   bloc //  : { kind:"rack", voices:[ [<entrées série>], ... ] }
// et il est compilé TEL QUEL : un bloc parallèle devient un ObjParallelBlockPlugin, dont
// chaque branche porte la chaîne série de sa voie et un ObjGain de fin (wetDb). Le moteur le
// déplie en SummingNode { branche… } et égalise les latences entre branches.
// @see ObjParallelBlockPlugin, te::ParallelPluginBlock

namespace {

struct CompileNode;
using CompileSeries = std::vector<CompileNode>;

struct CompileNode {
    bool                       isRack = false;
    // feuille (!isRack)
    std::string                key;        // pluginKey (ObjectPlugin.id)
    bool                       enabled = true;
    NSDictionary*              info = nil;  // identifier/format/name/stateXML (pour la création)
    // bloc parallèle (isRack) — `key` = id du rack-carrier ; `wetDb` = gain dB par voie
    std::vector<CompileSeries> voices;
    std::vector<float>         wetDb;
};

static CompileSeries parseCompileSeries(NSArray<NSDictionary*>* arr);

static CompileNode parseCompileNode(NSDictionary* d) {
    CompileNode n;
    if ([d[@"kind"] isEqualToString:@"rack"]) {
        n.isRack = true;
        n.key = std::string([(d[@"id"] ?: @"") UTF8String]);   // id du bloc → clé des gains de voie
        for (NSArray* v in (NSArray*)d[@"voices"])
            n.voices.push_back(parseCompileSeries(v));
        for (NSNumber* g in (NSArray*)d[@"wetDb"])
            n.wetDb.push_back([g floatValue]);
    } else {
        n.isRack  = false;
        n.key     = std::string([(d[@"id"] ?: @"") UTF8String]);
        n.enabled = d[@"enabled"] ? [d[@"enabled"] boolValue] : YES;
        n.info    = d;
    }
    return n;
}

static CompileSeries parseCompileSeries(NSArray<NSDictionary*>* arr) {
    CompileSeries s;
    for (NSDictionary* d in arr) s.push_back(parseCompileNode(d));
    return s;
}

// Clé du gain de voie (wetDb) d'un bloc parallèle. N'existe pas dans le modèle — c'est un
// plugin que le compilateur pose de lui-même en fin de branche — mais elle DOIT figurer parmi
// les clés attendues, sinon la passe de nettoyage détruirait le gain à chaque recompilation.
static std::string voiceGainKey(const std::string& rackKey, size_t voice) {
    return rackKey + "#wet" + std::to_string(voice);
}

// Toutes les clés que l'arbre demande, récursivement : feuilles, porteurs de blocs parallèles
// et gains de voie.
static void collectCompileKeys(const CompileSeries& s, std::unordered_set<std::string>& out) {
    for (auto& n : s) {
        if (n.key.empty()) continue;
        out.insert(n.key);
        if (!n.isRack) continue;
        for (size_t i = 0; i < n.voices.size(); ++i) {
            out.insert(voiceGainKey(n.key, i));
            collectCompileKeys(n.voices[i], out);
        }
    }
}

}  // namespace

// MARK: - Fenêtre d'éditeur natif de plugin

// Composant intermédiaire entre l'AudioProcessorEditor du plugin et la DocumentWindow.
// INDISPENSABLE : poser l'éditeur directement comme contenu de la fenêtre fait que
// certains plugins (AU/VST3 qui se redimensionnent de façon ASYNCHRONE après l'ouverture)
// s'étendent sur toute la fenêtre et recouvrent la barre de titre (plus de titre ni de
// bouton fermer ; le titre ne réapparaît qu'au resize manuel, qui force un relayout).
// Le wrapper recale toujours l'éditeur dans son repère local (sous la barre de titre) et
// propage les changements de taille de l'éditeur vers la fenêtre, qui conserve sa barre.
// Calque sur AudioProcessorEditorContentComp de l'exemple Tracktion (PluginWindow.h).
struct OBJEditorHolder : public juce::Component {
    std::unique_ptr<juce::AudioProcessorEditor> editor;

    explicit OBJEditorHolder(juce::AudioProcessorEditor* ed) : editor(ed) {
        if (editor) addAndMakeVisible(*editor);
        setSize(juce::jmax(8, editor ? editor->getWidth()  : 0),
                juce::jmax(8, editor ? editor->getHeight() : 0));
    }
    void resized() override {
        if (editor) editor->setBounds(getLocalBounds());
    }
    void childBoundsChanged(juce::Component* c) override {
        if (c == editor.get())
            setSize(juce::jmax(8, editor->getWidth()),
                    juce::jmax(8, editor->getHeight()));
    }
};

// Fenêtre JUCE autonome pour les éditeurs VST3/AU.
// Gère sa propre destruction : le bouton de fermeture appelle onClose,
// qui supprime le unique_ptr dans _editorWindows.
// Relais clavier des fenêtres d'éditeur : @see -setPluginKeyFallback: (OBJEngineCore.h).
// Global et non par-fenêtre — il n'y a qu'un seul destinataire, la timeline.
static BOOL (^gPluginKeyFallback)(NSEvent*) = nil;

struct OBJPluginEditorWindow : public juce::DocumentWindow {
    std::function<void()> onClose;
    juce::Colour accentColour;
    // LookAndFeel dédié à CETTE fenêtre (la barre de titre JUCE ne lit pas la
    // `backgroundColour` du constructeur, elle vient du LookAndFeel actif) — teint la barre de
    // titre avec la couleur d'identité du plugin sans affecter les autres fenêtres/éditeurs.
    std::unique_ptr<juce::LookAndFeel_V4> accentLookAndFeel;

    // Bout de chaîne des répondants. AppKit envoie un keyDown au PREMIER RÉPONDANT ; il ne
    // remonte jusqu'à la fenêtre que si personne en dessous ne l'a voulu. Arriver ici signifie
    // donc exactement une chose : la GUI du plugin a décliné la touche. C'est l'unique façon
    // fiable de distinguer « l'utilisateur tape dans un champ du plugin » de « l'utilisateur
    // veut un raccourci de la timeline » — aucune inspection du plugin ne le dirait, sa vue
    // étant opaque (@see isPluginEditorWindowKey). Les hôtes du marché ne font pas autrement.
    bool keyPressed (const juce::KeyPress&) override {
        if (!gPluginKeyFallback) return false;
        // JUCE ne transporte pas le NSEvent d'origine, mais on est appelé SYNCHRONEMENT depuis
        // le `keyDown:` qui l'a produit : c'est l'événement courant de l'application.
        NSEvent* e = [NSApp currentEvent];
        if (!e || e.type != NSEventTypeKeyDown) return false;
        return gPluginKeyFallback(e) ? true : false;
    }

    OBJPluginEditorWindow(const juce::String& name,
                          juce::AudioProcessorEditor* editor,
                          std::function<void()> closeCb,
                          bool floating,
                          juce::Colour accent)
        : juce::DocumentWindow(name,
                               juce::Colours::darkgrey,
                               juce::DocumentWindow::closeButton,
                               true),
          onClose(std::move(closeCb)),
          accentColour(accent)
    {
        accentLookAndFeel = std::make_unique<juce::LookAndFeel_V4>(juce::LookAndFeel_V4::getDarkColourScheme());
        accentLookAndFeel->getCurrentColourScheme().setUIColour(
            juce::LookAndFeel_V4::ColourScheme::widgetBackground, accentColour.darker(0.45f));
        setLookAndFeel(accentLookAndFeel.get());

        const bool resizable = editor->isResizable();
        // La fenêtre possède le wrapper (qui possède l'éditeur) ; resizeToFit=true pour
        // que les redimensionnements asynchrones du plugin remontent à la fenêtre.
        setContentOwned(new OBJEditorHolder(editor), true);
        setResizable(resizable, false);
        centreWithSize(juce::jmax(400, getWidth()),
                       juce::jmax(200, getHeight()));
        setVisible(true);
        // Premier plan par défaut, mais pas inconditionnel : l'explorateur de plugins doit
        // pouvoir passer devant (cf. setPluginEditorsFloating:).
        setAlwaysOnTop(floating);
    }

    ~OBJPluginEditorWindow() override {
        // Le LookAndFeel dédié se détruit avant le sous-objet Component (ordre C++ : membres
        // avant bases) — le détacher ici évite que Component ne garde un pointeur pendouillant
        // pendant sa propre destruction.
        setLookAndFeel(nullptr);
    }

    // paintOverChildren (pas paint) : l'UI du plugin est un enfant qui se peint PAR-DESSUS le
    // paint() de la fenêtre, quel que soit l'ordre du code — un liseret dessiné dans paint() se
    // retrouve donc recouvert partout où le contenu touche les bords. paintOverChildren est le
    // point d'accroche JUCE prévu pour dessiner par-dessus les enfants une fois peints.
    void paintOverChildren(juce::Graphics& g) override {
        // Cadre fin reprenant la couleur d'identité, tout autour de la fenêtre — même repère
        // visuel que le halo/bordure de la carte dans le synoptique (@see SynopticView).
        g.setColour(accentColour);
        g.drawRect(getLocalBounds(), 2);
    }

    void closeButtonPressed() override {
        if (onClose) onClose();
    }
};

// MARK: - OBJSoundObjectData

@implementation OBJSoundObjectData
@end

static NSString* const kPluginCacheKey = @"OBJPluginListXMLCache";

// MARK: - LINK : mirroir de paramètres entre instances liées

// Écoute tous les paramètres automatables d'un plugin et notifie un callback à chaque
// changement de valeur (index dans la liste des params + nouvelle valeur). Le callback
// tourne sur le message thread (AsyncCaller de Tracktion), jamais sur le thread audio.
struct OBJParamMirror : public te::AutomatableParameter::Listener {
    std::function<void(int, float)>           onChange;
    /// Optionnel : le paramètre vient d'être SAISI (bouton enfoncé sur un knob), avant toute
    /// modification — et même s'il n'y en a aucune. Les GUI natives AU/VST encadrent leurs gestes
    /// (`beginChangeGesture` / `endChangeGesture`), ce que Tracktion relaie ici : c'est le seul
    /// signal qui dise « l'utilisateur s'intéresse à CE paramètre » sans qu'il ait à le dérégler.
    std::function<void(int)>                  onGestureBegin;
    juce::Array<te::AutomatableParameter*>    params;  // bruts : le plugin les possède

    OBJParamMirror(te::Plugin::Ptr plugin, std::function<void(int, float)> cb,
                   std::function<void(int)> gestureCb = {})
        : onChange(std::move(cb)), onGestureBegin(std::move(gestureCb)) {
        for (auto* p : plugin->getAutomatableParameters()) {  // NOLINT — copy intentional
            if (!p) continue;
            params.add(p);
            p->addListener(this);
        }
    }
    ~OBJParamMirror() override {
        for (auto* p : params)
            if (p) p->removeListener(this);
    }
    void curveHasChanged (te::AutomatableParameter&) override {}
    void currentValueChanged (te::AutomatableParameter& param) override {
        const int idx = params.indexOf(&param);
        if (idx >= 0 && onChange) onChange(idx, param.getCurrentValue());
    }
    void parameterChangeGestureBegin (te::AutomatableParameter& param) override {
        const int idx = params.indexOf(&param);
        if (idx >= 0 && onGestureBegin) onGestureBegin(idx);
    }
};

// Écoute un plugin EXTERNE (AU/VST) au niveau de son juce::AudioProcessor. Un OBJParamMirror
// (listener sur te::AutomatableParameter) rate certaines modifs faites dans la GUI native du plugin
// (le plugin ne notifie pas toujours l'AutomatableParameter). L'AudioProcessorListener, lui, reçoit
// `audioProcessorParameterChanged` / `audioProcessorChanged` directement du plugin. Utilisé en plus
// du mirror pendant qu'un objet sonore est ouvert (miroir vivant). Les callbacks peuvent tomber sur un
// thread non-message → on marshale vers le message thread.
struct OBJProcessorWatcher : public juce::AudioProcessorListener {
    juce::AudioProcessor*  processor = nullptr;
    std::function<void()>  onChange;

    OBJProcessorWatcher(juce::AudioProcessor* p, std::function<void()> cb)
        : processor(p), onChange(std::move(cb)) {
        if (processor) processor->addListener(this);
    }
    ~OBJProcessorWatcher() override {
        if (processor) processor->removeListener(this);
    }
    void notify() {
        auto cb = onChange;
        juce::MessageManager::callAsync([cb] { if (cb) cb(); });
    }
    void audioProcessorParameterChanged(juce::AudioProcessor*, int, float) override { notify(); }
    void audioProcessorChanged(juce::AudioProcessor*, const ChangeDetails&) override { notify(); }
};

// Écoute du dernier paramètre TOUCHÉ sur un plugin, le temps que son éditeur soit ouvert. La Ptr
// retenue garde les te::AutomatableParameter écoutés valides même si le plugin quitte la chaîne
// pendant que sa fenêtre vit encore — le mirror ne tient, lui, que des pointeurs bruts.
// L'ordre des membres compte : le mirror est détruit AVANT que la Ptr soit rendue.
struct OBJTouchWatch {
    te::Plugin::Ptr                  plugin;
    std::unique_ptr<OBJParamMirror>  mirror;
};

// Job de bake en tâche de fond : un Edit cloné (rôle forRendering) + son handle de rendu async,
// maintenus vivants jusqu'au callback de fin (qui efface l'entrée sur le main thread).
struct OBJRenderJob {
    std::unique_ptr<te::Edit>                       edit;
    std::shared_ptr<te::EditRenderer::Handle>       handle;
};

// CAPTURE DE TRACE — l'état qui traverse les DEUX OU TROIS passes de rendu.
//
// Une capture n'est pas un rendu, c'est une petite machine à états : passe B, passe B encore,
// null test, puis — et seulement si le plugin s'est révélé déterministe — passe A. Chaque passe
// est un rendu offline complet, sur son propre clone, et rend la main au thread principal entre
// deux. Tout ce que la suite doit retrouver vit donc ici, et pas dans des variables de pile.
//
// @see docs/objekat-capture-trace.md, et -capturePluginTrace:...
struct OBJTraceSession {
    // Ce qu'on trace
    std::string      pluginKey, objectKey;
    te::EditItemID   pluginItemID, hostClipID, trackID;
    std::vector<te::EditItemID> allowed, ancestors;

    // La fenêtre, en secondes d'edit
    double regionStart = 0.0, regionEnd = 0.0;
    double preRoll = 2.0, tail = 5.0;

    // Le contexte de rendu, figé pour toutes les passes (le même graphe, la même fréquence, le
    // même bloc : un plugin dont le comportement dépend du bloc doit voir le même bloc partout).
    double  sampleRate = 44100.0;
    int     blockSize  = 512;
    int64_t numSamples = 0;         // région + queue, par canal
    int64_t regionSamples = 0;      // la région seule — c'est la porte du probe d'entrée

    // Les réglages de l'arithmétique
    double   gMax = objtrace::kDefaultGMax;
    double   xMinDbfs = objtrace::kDefaultXMinDbfs;
    uint64_t mergeGap = objtrace::kDefaultMergeGap;

    // De quoi remplir l'en-tête
    std::string pluginName, pluginIdentifier, pluginFormat, pluginVersion;
    int  latencySamples = 0;
    bool pluginWasBypassed = false;
    bool hasAutomation = false;

    juce::File destFile;

    // Les captures. x2/y2 sont relâchées dès le null test : elles ne servent qu'à lui.
    te::ObjTraceCaptureBufferPtr x1, y1, x2, y2, dFree;

    // Où on en est
    int  passIndex = 0;             // 0 = B1, 1 = B2, 2 = A
    int  numPasses = 3;             // ramené à 2 dès que le plugin se révèle non déterministe
    bool nonDeterministic = false;
    bool cancelled = false;

    objtrace::Residual determinismY, determinismX;
};

// MARK: - OBJEngineCore

// INC 2 — veilleur de latence (PDC à chaud). Un te::Plugin peut changer la latence qu'il rapporte
// (ajout/retrait de FX, ou réglage : EQ phase-linéaire, oversampling d'un limiteur…). Tracktion ne
// reconstruit le graphe que si le plugin *notifie* (audioProcessorChanged) — certains ne le font pas.
// Ce timer relit périodiquement les latences et déclenche un restartPlayback (= réallocation
// complète, comme un reload de projet) dès qu'une latence change → compensation type Ableton.
struct OBJLatencyWatcher : public juce::Timer {
    std::function<void()> onTick;
    void timerCallback() override { if (onTick) onTick(); }
};

// Timer générique à callback (même patron que OBJLatencyWatcher ci-dessus).
struct OBJCallbackTimer : public juce::Timer {
    std::function<void()> onTick;
    void timerCallback() override { if (onTick) onTick(); }
};

// Un plugin externe créé depuis un état sauvé, dont il faut vérifier — et au besoin ré-affirmer —
// l'état une fois l'instance réellement préparée. Voir -schedulePluginStateReassert:fromTree:.
struct OBJPendingStateReassert {
    te::Plugin::Ptr   plugin;
    juce::ValueTree   savedTree;
    juce::MemoryBlock desired;      // chunk binaire attendu (décodé de savedTree)
    juce::String      name;         // pour les logs (l'instance peut disparaître entre-temps)
    int               ticks = 0;
};

static constexpr int kObjStateReassertIntervalMs = 250;
static constexpr int kObjStateReassertMaxTicks   = 40;   // ~10 s avant abandon

// CONSIGNE DE PLUGINS.
//
// Beaucoup de gestes retirent un objet du moteur pour le réajouter aussitôt, identique :
// emballer un clip MIDI dans un groupe pour en faire un objet sonore, matérialiser puis
// refermer une session d'édition, couper/coller, défaire. Chaque aller-retour DÉTRUISAIT les
// plugins de l'objet et les recréait — soit, pour un AU, un chargement complet sur le thread
// principal : 2,4 s mesurées pour un UADx Opal, à chaque geste.
//
// Rien à réécrire côté moteur pour l'éviter : `PluginList::insertPlugin(ValueTree)` passe par
// `PluginCache::getOrCreatePluginFor`, qui rend le plugin DÉJÀ VIVANT dont c'est le state
// (comparaison d'identité de ValueTree) ; et le cache ne libère un plugin que lorsque plus
// personne d'autre ne le tient (`getReferenceCount() == 1`). Il suffit donc de garder un `Ptr`
// le temps de l'aller-retour pour que le même objet — et son instance AU chargée — revienne.
// C'est exactement le principe de `moveClipToOwner` pour les clips, appliqué aux plugins.
//
// Ce qu'on ne peut PAS servir depuis la consigne : une vraie duplication (deux exemplaires
// simultanés = deux instances, c'est de la physique) et le clone de rendu (autre Edit, autre
// graphe). La consigne ne sert qu'un plugin RETIRÉ, une seule fois, à l'identique.
struct OBJParkedPlugin {
    te::Plugin::Ptr   plugin;
    std::string       typeKey;      // desc.createIdentifierString()
    juce::MemoryBlock state;        // chunk au moment du parking — l'identité fonctionnelle
    double            deadlineMs;
};

// Au-delà, l'instance est relâchée : un AU consigné garde sa mémoire et ses ressources, on ne
// le garde donc que le temps d'un aller-retour, pas d'une session.
static constexpr double kObjPluginParkingTtlMs   = 20000.0;
static constexpr int    kObjPluginParkingSweepMs = 2000;

// Lit l'état binaire courant d'une instance, en suspendant le traitement le temps de la lecture
// (même précaution que ExternalPlugin::flushPluginStateToValueTree). Un résultat VIDE signifie que
// le plugin refuse de rendre son état — pour un AU, typiquement parce qu'il n'est pas initialisé.
static juce::MemoryBlock objReadInstanceState(juce::AudioPluginInstance& pi) {
    juce::MemoryBlock mb;
    pi.suspendProcessing(true);
    pi.getStateInformation(mb);
    pi.suspendProcessing(false);
    return mb;
}

// Chunk attendu, décodé de la propriété `state` d'une PLUGIN ValueTree. Vide si elle est absente
// (plugin neuf, ou built-in qui n'a pas d'état binaire) → rien à ré-affirmer.
static juce::MemoryBlock objDesiredStateFromTree(const juce::ValueTree& tree) {
    juce::MemoryBlock mb;
    juce::String encoded = tree.getProperty(juce::Identifier("state")).toString();
    if (encoded.isNotEmpty()) mb.fromBase64Encoding(encoded);
    return mb;
}

// Identifie un MODÈLE de plugin, pas une instance : « cet AU-là ne converge jamais » est une
// propriété du plugin, pas de l'exemplaire qu'on tient. @see forcePluginStatesForRenderClone:.
static std::string objPluginTypeKey(te::ExternalPlugin& ext) {
    return ext.desc.createIdentifierString().toStdString();
}

// Signature de MODÈLE lue sur une PLUGIN ValueTree — `filename` + `uniqueId`, les deux propriétés
// qu'écrit `ExternalPlugin::create` depuis la description. On la lit sur l'ARBRE et non sur la
// description résolue pour que les deux côtés de l'appariement de consigne se comparent sur la
// même source. @see OBJParkedPlugin.
static std::string objPluginTreeTypeKey(const juce::ValueTree& pluginTree) {
    juce::String sig = pluginTree.getProperty(juce::Identifier("filename")).toString()
                     + "|" + pluginTree.getProperty(juce::Identifier("uniqueId")).toString();
    return sig.toStdString();
}

// Vrai si ce plugin peut être flushé sans risque. `flushPluginStateToValueTree` sur un plugin
// externe qui ne rend pas son état écrit 0 octet → Tracktion fait alors `state.removeProperty` et
// EFFACE l'état sauvé. Ne jamais flusher dans ce cas.
static bool objCanFlushPluginState(te::Plugin& p) {
    auto* ext = dynamic_cast<te::ExternalPlugin*>(&p);
    if (!ext) return true;                       // built-in : pas d'état binaire, rien à perdre
    auto* pi = ext->getAudioPluginInstance();
    return pi != nullptr && objReadInstanceState(*pi).getSize() > 0;
}

// Tous les plugins de l'Edit, CONTENU DES CONTAINERS COMPRIS. `te::getAllPlugins` s'arrête aux
// clips DIRECTS d'une piste : sur ce modèle, où tout objet groupé est un clip imbriqué et où
// l'instrument d'un objet MIDI vit sur son ContainerClip, ça laisse dehors exactement les
// plugins qu'un bake doit emporter — ceux du contenu du groupe qu'on rend.
static void objCollectContainedPlugins(te::ClipOwner& owner, te::Plugin::Array& out) {
    for (auto* c : owner.getClips()) {
        if (!c) continue;
        if (auto* pl = c->getPluginList())
            for (auto* p : *pl)
                out.addIfNotAlreadyThere(p);
        // Descente sur ClipOwner (et non ContainerClip) : même idiome que
        // `getClipsOfTypeRecursive`, seul type concerné aujourd'hui mais pas forcément demain.
        if (auto* sub = dynamic_cast<te::ClipOwner*>(c))
            objCollectContainedPlugins(*sub, out);
    }
}

static te::Plugin::Array objAllPluginsDeep(te::Edit& edit) {
    te::Plugin::Array list = te::getAllPlugins(edit, false);
    for (auto* t : te::getAllTracks(edit))
        for (auto* cc : te::getTrackItemsOfType<te::ContainerClip>(*t))
            objCollectContainedPlugins(*cc, list);
    return list;
}

// MARK: - Capture de trace — helpers de repérage
//
// La procédure, ses seuils et son format sont spécifiés dans `docs/objekat-capture-trace.md`.

/// Où vit un plugin dans une chaîne compilée : la liste qui le porte, et son index dedans.
/// Descend dans les branches d'un bloc parallèle — un FX y vit sous le PLUGIN qui l'héberge et
/// non sous la plugin-list du clip.
struct OBJPluginSite {
    te::PluginList* list = nullptr;
    int index = -1;
    bool isValid() const { return list != nullptr && index >= 0; }
};

static OBJPluginSite objFindPluginSite(te::PluginList& pl, te::EditItemID wanted) {
    int i = 0;
    for (auto* p : pl) {
        if (p != nullptr) {
            if (p->itemID == wanted) return { &pl, i };

            if (auto* block = dynamic_cast<te::ObjParallelBlockPlugin*>(p))
                for (int b = 0; b < block->getNumBranches(); ++b)
                    if (auto* branch = block->getBranch(b))
                        if (auto found = objFindPluginSite(*branch, wanted); found.isValid())
                            return found;
        }
        ++i;
    }
    return {};
}

/// Le plugin d'identifiant `wanted` dans une Edit (le clone), à n'importe quelle profondeur.
static te::Plugin* objFindPluginByItemID(te::Edit& edit, te::EditItemID wanted) {
    for (auto* p : objAllPluginsDeep(edit))
        if (p != nullptr && p->itemID == wanted) return p;
    return nullptr;
}

/// Le plugin porte-t-il une courbe d'automation ? Consigné dans l'en-tête de la trace : une
/// trace dont les paramètres bougeaient ne vaut que pour ce mouvement-là, rejoué à l'identique.
static bool objPluginHasAutomation(te::Plugin& p) {
    for (auto* param : p.getAutomatableParameters())
        if (param != nullptr && param->hasAutomationPoints()) return true;
    return false;
}

/// Deux signaux encodés portent-ils exactement la même chose ? Sert à la détection du cas
/// `linked` — comparer les signaux ENCODÉS plutôt que les tableaux plats évite de garder ces
/// derniers en vie pour tous les canaux à la fois (8 octets par échantillon et par canal).
static bool objTraceSignalsEqual(const objtrace::Signal& a, const objtrace::Signal& b) {
    if (a.defaultValue != b.defaultValue) return false;
    if (a.segments.size() != b.segments.size()) return false;
    for (size_t i = 0; i < a.segments.size(); ++i)
        if (a.segments[i].start != b.segments[i].start
            || a.segments[i].length != b.segments[i].length) return false;
    return a.data == b.data;
}

/// Le pire des deux résidus, canal par canal : une trace vaut ce que vaut son canal le moins bon.
static objtrace::Residual objWorstResidual(const objtrace::Residual& a, const objtrace::Residual& b) {
    objtrace::Residual r;
    r.peakDbfs = std::max(a.peakDbfs, b.peakDbfs);
    r.rmsDbfs  = std::max(a.rmsDbfs,  b.rmsDbfs);
    return r;
}

// DIAGNOSTIC PERF : seuls les plugins EXTERNES coûtent à l'instanciation — un AU se charge,
// s'initialise et restaure son chunk, là où un plugin interne n'est qu'un objet C++. Le second
// nombre est celui qui compte vraiment : combien ont une INSTANCE, c'est-à-dire combien ont
// réellement été chargés une fois le filtre passé. @see OBJRenderPluginFilter.
struct OBJExternalPluginCount { int declared = 0; int loaded = 0; };

static OBJExternalPluginCount objCountExternalPlugins(te::Edit& edit) {
    OBJExternalPluginCount c;
    for (auto* p : objAllPluginsDeep(edit))
        if (auto* ext = dynamic_cast<te::ExternalPlugin*>(p)) {
            ++c.declared;
            if (ext->getAudioPluginInstance() != nullptr) ++c.loaded;
        }
    return c;
}

// Compartiment d'ordonnancement : la ressource que la politique du pool alloue à un objet
// top-level. Le STEM (chaîne vide = Main) dit dans quel FolderTrack submix la piste doit
// vivre ; la LANE ne sert qu'à répartir le travail sur plusieurs pistes, donc plusieurs
// threads. @see « Pool de pistes ».
struct OBJTrackSlot {
    std::string stemKey;
    int lane = 0;
};

// Une piste du pool, avec le compartiment qu'elle sert. Un vecteur (et non deux tables) :
// les deux sens de lecture sont utiles — trouver la piste d'un compartiment, et retrouver le
// compartiment d'une piste quand un objet change de stem sans changer de lane. Il y a autant
// d'entrées que de compartiments OCCUPÉS, soit quelques dizaines au plus.
struct OBJPoolTrack {
    std::string stemKey;
    int lane = 0;
    te::AudioTrack* track = nullptr;
};

// Résultat de `renderChainForKey:` — deux listes qu'il ne faut surtout pas confondre.
struct OBJRenderChain {
    // Liste blanche passée au renderer : la cible, TOUT son contenu, et ses containers ancêtres.
    std::vector<te::EditItemID> allowed;
    // Les ANCÊTRES seuls. Eux seuls se rendent transparents sur le clone ; le contenu, lui, EST
    // ce qu'on cuit — le toucher revenait à bypasser les FX (et l'instrument) de ce qu'on rend.
    std::vector<te::EditItemID> ancestors;
};

@interface OBJEngineCore ()
- (void)ensureMasterMeter;
- (void)checkLatencyAndRebuild;
// Met un plugin externe fraîchement créé en file d'attente de ré-affirmation d'état. Sans effet
// pour un built-in, ou si l'arbre ne porte aucun état à restaurer.
- (void)schedulePluginStateReassert:(te::Plugin::Ptr)plugin fromTree:(juce::ValueTree)tree;
- (void)tickPluginStateReasserts;
// Idem, mais en synchrone, sur le clone d'Edit d'un rendu offline (pas le temps d'attendre).
- (void)forcePluginStatesForRenderClone:(te::Edit&)clone;
// Consigne de plugins : garde vivant un plugin retiré, le temps d'un aller-retour. @see
// OBJParkedPlugin pour le pourquoi et les limites.
- (void)parkPluginsForObjectID:(NSString*)uuid;
- (void)parkPlugin:(te::Plugin&)plugin;
- (te::Plugin::Ptr)takeParkedPluginMatching:(const juce::ValueTree&)wantedTree;
- (void)sweepPluginParking;
- (void)propagateLinkedParamFromKey:(const std::string&)pluginKey index:(int)index value:(float)value;
- (void)reportParamTouch:(const std::string&)pluginKey index:(int)index;
// Suivi du focus de l'app pour les fenêtres d'éditeurs (cf. init).
- (void)hidePluginEditorsOnResign;
- (void)restorePluginEditorsOnActivate;
- (void)teardownPluginLink:(const std::string&)pluginKey;
// Résout la PLUGIN ValueTree (description AU/VST3 / type built-in / état sauvé) pour un
// descripteur d'inspecteur, SANS l'insérer nulle part. Tree invalide = échec de résolution.
- (juce::ValueTree)resolvedPluginTreeForInfo:(NSDictionary*)pluginInfo
                                    stateXML:(NSString* _Nullable)stateXML;
// Renumérote les EditItemID d'un arbre PLUGIN désérialisé. @see l'implémentation.
- (void)freshenItemIDsInTree:(juce::ValueTree&)tree;
// PluginList qui héberge la chaîne FX user + le fader ObjGain d'un objet. Dans ce modèle
// c'est TOUJOURS une CLIP plugin-list : clip audio → son WaveAudioClip ; groupe, aux et objet
// MIDI → leur ContainerClip (pour le MIDI, l'instrument y est en index 0).
- (te::PluginList*)userPluginListForKey:(const std::string&)key;
// Pool de pistes : politique d'allocation, piste d'un compartiment, ramassage des vides.
- (OBJTrackSlot)trackSlotForKey:(const std::string&)key lane:(int)lane;
- (te::AudioTrack*)trackForSlot:(const OBJTrackSlot&)slot;
- (OBJTrackSlot)slotOfTrack:(te::Track*)track;
- (std::string)stemKeyForKey:(const std::string&)key;
- (te::ClipOwner*)clipOwnerForKey:(const std::string&)key lane:(int)lane;
- (void)pruneEmptyPoolTracks;
// Réapplique à TOUTES les pistes du folder d'un stem le routage mémorisé pour ce stem.
- (void)applyStemRouting:(const std::string&)stemKey;
// Recale l'étendue du ContainerClip d'un groupe sur ses enfants (indispensable aux perfs).
- (void)refreshContainerSpanForKey:(const std::string&)key;
- (void)refreshOwnerContainerSpanFor:(const std::string&)childKey;
- (void)installObjectChainTail:(te::PluginList&)pl
                        forKey:(const std::string&)key
                        volume:(float)volumeDb
                           pan:(float)pan
                        window:(te::TimeRange)window
                        fadeIn:(double)fadeIn
                       fadeOut:(double)fadeOut;
- (void)setWindowForKey:(const std::string&)key
                  start:(double)startSecs
                    end:(double)endSecs
                 fadeIn:(double)fadeIn
                fadeOut:(double)fadeOut;
// Oublie tout ce que le moteur retient de l'objet (chaîne, repères, appartenance).
- (void)forgetObjectBookkeeping:(const std::string&)key;
// Retire les envois dont l'émetteur et l'aux ne sont plus au même niveau de montage.
- (BOOL)pruneOutOfScopeSends;
// Index où insérer un FX user de l'objet `key` dans sa plugin-list : avant le trim de fin de
// chaîne s'il existe, sinon avant le fader, sinon en fin de liste.
- (int)userInsertIndexForKey:(const std::string&)key in:(te::PluginList&)pl;
// Vrai si ces plugins occupent déjà `pl` dans cet ordre, tous devant `anchor`.
- (BOOL)plugins:(const std::vector<std::string>&)keys
   areInOrderIn:(te::PluginList&)pl
         before:(const te::Plugin::Ptr&)anchor;
// Sonde : journalise l'ordre RÉEL d'une chaîne compilée, branches parallèles comprises.
- (void)dumpChainOrderForKey:(const std::string&)key in:(te::PluginList&)pl;
// Helper générique de rendu offline en tâche de fond (clone d'Edit + EditRenderer async). `prepare`
// applique le bypass spécifique (fader/fenêtre/fades) sur la piste clonée détachée à la racine.
// `allowedClipIDs` restreint le rendu à ces clips (vide = toute la piste) : c'est ce qui ISOLE
// l'objet visé, y compris à l'intérieur d'un ContainerClip. @see renderChainForKey:
- (void)renderTrackToFileAsync:(te::EditItemID)trackID
                      filePath:(NSString*)filePath
                         start:(double)startSecs
                           end:(double)endSecs
                 allowedClipIDs:(const std::vector<te::EditItemID>&)allowedClipIDs
                       prepare:(std::function<void(te::Track*)>)prepare
                          desc:(NSString*)desc
                    completion:(void(^)(BOOL ok))completion;
// Clone de rendu partagé (flush + copie + chargement filtré + ré-affirmation des états).
// @see buildRenderCloneAllowing:track:desc:
- (std::unique_ptr<te::Edit>)buildRenderCloneAllowing:(const std::vector<te::EditItemID>&)allowedClipIDs
                                                track:(te::EditItemID)trackID
                                                 desc:(NSString*)desc;
// CAPTURE DE TRACE — les trois temps de la machine à états. @see OBJTraceSession.
- (void)runTracePass;
- (void)tracePassFinished:(BOOL)ok;
- (void)finishTraceCaptureWithError:(NSString* _Nullable)errorMessage;
// Chaîne des clips à laisser vivre pour qu'un objet sonne : lui-même, son contenu, puis chacun
// de ses containers ancêtres jusqu'à la piste.
- (OBJRenderChain)renderChainForKey:(const std::string&)key;
@end

@implementation OBJEngineCore {
    std::unique_ptr<te::Engine> _engine;
    std::unique_ptr<te::Edit>   _edit;

    // UUID string → pointeurs Tracktion (valides tant que _edit est vivant)
    // POOL DE PISTES : les pistes porteuses, créées à la demande, une par compartiment
    // (stem, lane) occupé. Elles ne portent AUCUN plugin (simple support) — tout ce qui est
    // propre à un objet vit sur la plugin-list de SON clip. @see trackSlotForKey:lane:.
    //
    // N.B. il n'y a PAS de table « objet → compartiment » : la piste porteuse d'un objet se
    // déduit de son clip (objOwningTrack) et son stem du folder de cette piste. Une table de
    // plus serait une occasion de plus de désynchroniser.
    std::vector<OBJPoolTrack>                                 _poolTracks;
    // objectID d'un ENFANT de groupe → groupID du container qui l'héberge. Sa présence
    // signifie « cet objet ne vit pas sur une piste du pool mais dans un ContainerClip ».
    std::unordered_map<std::string, std::string>              _childOwnerMap;
    // groupID → ContainerClip (le groupe est un CLIP posé sur une piste du pool, ou dans
    // le container de son groupe parent pour un sous-groupe).
    std::unordered_map<std::string, te::ContainerClip*>       _containerClipMap;
    // groupID → bornes AUDIBLES du groupe, telles que le modèle les pose (updateGroupWindow:).
    // C'est l'étendue donnée au ContainerClip, qui coupe alors nativement — et sans destruction —
    // ce qui déborde. Absent = groupe INFINI : là on retombe sur l'enveloppe des enfants, car
    // donner [0, 1e9] au container ruinerait la paresse du CombiningNode de la piste.
    std::unordered_map<std::string, te::TimeRange>            _groupBoundsMap;
    // groupID → bornes IN/OUT de la boucle demandée (secondes EDIT ABSOLUES, posées telles
    // quelles par updateGroupWindow: — plus de calcul d'enveloppe côté moteur, le modèle Swift
    // fait foi). Présent = boucle active avec cette plage ; absent = pas de boucle. Lu par
    // refreshContainerSpanForKey:, qui applique directement `cc->setLoopRange(...)`. Jamais posé
    // pour un aux (canLoop l'exclut côté modèle) ni consulté pour un groupe infini (pas de
    // fenêtre à dépasser). @see [[loop-item-plan]]
    std::unordered_map<std::string, te::TimeRange>            _groupLoopRangeMap;
    // objectID → fader ObjGain (volume/pan) dans sa plugin-list hôte. Repère EXPLICITE : la
    // chaîne contient d'autres ObjGain (trims début/fin), on ne peut plus « prendre le premier ».
    std::unordered_map<std::string, te::Plugin::Ptr>          _faderGainMap;
    // objectID → ObjWindowFade (fenêtre + fades post-FX), en fin de chaîne hôte.
    std::unordered_map<std::string, te::Plugin::Ptr>          _windowFadeMap;
    // auxID des ContainerClip marqués BUS D'AUX. Ils sont aussi dans _containerClipMap (ce
    // sont des containers : ils se déplacent, se dissolvent, portent une chaîne de la même
    // façon), mais ils ne jouent pas leur contenu — ils somment les envois qui les visent.
    std::unordered_set<std::string>                           _auxKeys;
    // "émetteurID|auxID" → ObjAuxSendPlugin posé en fin de chaîne de l'émetteur.
    std::unordered_map<std::string, te::Plugin::Ptr>          _auxSendMap;
    std::unordered_map<std::string, te::WaveAudioClip::Ptr>   _clipMap;
    // clipID → MidiClip. Un objet MIDI est un ContainerClip (dans _containerClipMap, sous la
    // MÊME clé) dont ce clip est l'unique enfant : c'est le container qui porte la chaîne,
    // instrument compris. @see addMidiClip:withID:
    std::unordered_map<std::string, te::MidiClip::Ptr>        _midiClipMap;
    // clipID → instrument virtuel en tête de chaîne (slot index 0 du container, hors RackType)
    std::unordered_map<std::string, te::Plugin::Ptr>          _instrumentMap;

    // stemID → FolderTrack submix (bus de stem)
    std::unordered_map<std::string, te::FolderTrack*>         _stemBusMap;
    // stemID → « la sortie de ce bus est-elle sommée dans le Main ? » (absent = oui).
    //
    // Le routage doit être MÉMORISÉ ici et non lu sur le graphe, parce qu'un FolderTrack n'a pas
    // de TrackOutput à lui : `FolderTrack::getOutput()` renvoie celui de sa PREMIÈRE piste audio
    // (@see applyStemRouting). Le porteur de l'état change donc dès qu'un compartiment naît ou
    // disparaît dans le folder — il faut une source de vérité qui, elle, ne bouge pas.
    std::unordered_map<std::string, bool>                     _stemRouteToMain;
    // Mixer (increment 1) : gain + VU par stem, + VU master.
    // stemID → ObjGain inséré sur le folder du stem (niveau de bus).
    std::unordered_map<std::string, te::Plugin::Ptr>         _stemGainMap;
    // stemID → client de mesure (LevelMeter en fin de chaîne du folder du stem).
    std::unordered_map<std::string, std::unique_ptr<te::LevelMeasurer::Client>> _stemMeterClients;
    // VU du master (LevelMeter inséré paresseusement sur getMasterPluginList).
    std::unique_ptr<te::LevelMeasurer::Client>              _masterMeterClient;
    // INC 2 — clé du Main : userPluginListForKey: la route sur getMasterPluginList(). Vide tant que
    // setMasterStemKey: n'a pas été appelé. Le rack master s'insère avant cet ObjGain d'ancre.
    std::string                                            _masterStemKey;
    te::Plugin::Ptr                                        _masterAnchorGain;  // ObjGain ancre sur le master
    // pluginKey (ObjectPlugin.id) → Plugin::Ptr
    std::unordered_map<std::string, te::Plugin::Ptr>          _pluginMap;
    // pluginKey → fenêtre éditeur ouverte (nullptr = fermée)
    std::unordered_map<std::string, std::unique_ptr<OBJPluginEditorWindow>> _editorWindows;
    // Les éditeurs flottent-ils au-dessus du reste de l'app ? Vrai par défaut, abaissé le temps
    // qu'une UI doive passer devant (explorateur de plugins). S'applique aussi à l'ouverture.
    bool _pluginEditorsFloating;
    // Éditeurs masqués parce que l'app a perdu le focus, à ré-afficher au retour. Une fenêtre
    // flottante reste sinon au-dessus des AUTRES applications, ce qu'aucun hôte ne fait.
    std::vector<std::string> _editorsHiddenOnResign;
    // Jetons des observateurs d'activation de l'app (retirés au dealloc).
    id _appResignObserver;
    id _appActivateObserver;

    // CHAÎNE FX LINÉAIRE (branche containerclip) — remplace le RackType par objet. Les plugins
    // user sont insérés EN SÉRIE dans la plugin-list hôte, encadrés par deux ObjGain de trim
    // (début/fin de chaîne), le tout AVANT le fader et la fenêtre/fades :
    //   [ instrument? | trimIn | FX… | trimOut | fader ObjGain | ObjWindowFade ]
    struct OBJObjectChain {
        std::vector<std::string> pluginKeys;   // ordre série (source de vérité de l'ordre)
        te::Plugin::Ptr          trimIn;
        te::Plugin::Ptr          trimOut;
    };
    std::unordered_map<std::string, OBJObjectChain> _objectChainMap;  // objectID → chaîne user

    // LINK d'instances de plugin (voir setPluginLinkGroup:).
    std::unordered_map<std::string, std::string>           _linkGroup;     // pluginKey → groupID
    std::unordered_map<std::string, std::unique_ptr<OBJParamMirror>> _mirrors; // pluginKey → listener
    // groupID → (index param → dernière valeur canonique). Sert de garde anti-boucle.
    std::unordered_map<std::string, std::unordered_map<int, float>> _groupCanonical;

    // Écoute des params tant qu'un objet sonore est ouvert (re-miroir vivant). Écouteurs
    // installés sur les FX user de l'objet édité ; vidés à la fin de session (begin/end).
    std::vector<std::unique_ptr<OBJParamMirror>>          _objectEditMirrors;
    // Idem pour les plugins EXTERNES (AU/VST) : listener au niveau du juce::AudioProcessor, qui capte
    // les modifs faites dans la GUI native que l'AutomatableParameter rate parfois.
    std::vector<std::unique_ptr<OBJProcessorWatcher>>     _objectEditProcWatchers;
    std::vector<te::Plugin::Ptr>                          _objectEditPlugins;  // pour flush pré-rendu

    // Écoute du dernier paramètre TOUCHÉ, armée le temps qu'un éditeur de plugin soit ouvert
    // (@see beginPluginParamTouchWatch:).
    std::unordered_map<std::string, OBJTouchWatch>        _paramTouchWatches;  // pluginKey → écoute

    // INC 2 — veilleur de latence (PDC à chaud) + dernière signature de latence observée.
    std::unique_ptr<OBJLatencyWatcher>                    _latencyWatcher;
    double                                                _lastLatencySignature;  // <0 = non initialisée
    // Un compile de rack vient d'avoir lieu : il a DÉJÀ demandé une reconstruction, donc le
    // changement de latence qui en découle est déjà compensé. Le prochain tic du veilleur doit
    // absorber la nouvelle signature sans reconstruire une deuxième fois (cf. checkLatencyAndRebuild).
    bool                                                  _latencyResyncPending;

    // Plugins externes en attente de vérification d'état (cf. -schedulePluginStateReassert:).
    // Le timer ne tourne que tant que la file n'est pas vide.
    std::vector<OBJPendingStateReassert>                  _pendingStateReasserts;
    std::unique_ptr<OBJCallbackTimer>                     _stateReassertTimer;

    // Modèles de plugin dont la ré-affirmation d'état sur un clone de rendu s'est révélée SANS
    // EFFET (état d'instance inchangé après coup). Mesuré une fois, plus jamais retenté : sans
    // ça, un AU qui ne rend pas d'état comparable coûte son AudioUnitInitialize à chaque bake,
    // pour rien. @see forcePluginStatesForRenderClone:.
    std::unordered_set<std::string>                       _inertStateReasserts;

    // Plugins retirés du graphe et gardés vivants le temps d'un aller-retour. @see OBJParkedPlugin.
    std::vector<OBJParkedPlugin>                          _pluginParking;
    std::unique_ptr<OBJCallbackTimer>                     _pluginParkingTimer;

    // jobID → job de bake en tâche de fond (clone d'Edit + handle de rendu).
    std::unordered_map<std::string, OBJRenderJob>          _renderJobs;
    // jobID (NSString) → block completion (retenu côté ObjC — ne JAMAIS capturer un block ObjC
    // dans un lambda C++ type-erasé : ARC ne le gère pas de façon fiable → crash).
    NSMutableDictionary<NSString*, id>*                    _renderCompletions;

    // Export du mix : le job vit dans _renderJobs comme un bake, mais son identifiant est retenu
    // à part — c'est lui qui répond à « un export tourne-t-il ? », « où en est-il ? » et
    // « annule ». Vide = aucun export en cours (un seul à la fois). Completions à part aussi :
    // leur signature porte un message d'erreur. @see exportMixToFileAsync:.
    std::string                                            _exportJobID;
    NSMutableDictionary<NSString*, id>*                    _exportCompletions;

    // CAPTURE DE TRACE — une seule à la fois (elle monopolise le graphe pendant deux ou trois
    // rendus, et rien ne serait gagné à en mener deux de front). `_traceSession` non nul =
    // capture en cours ; `_traceJob` porte le clone et le handle de la passe COURANTE, remplacés
    // à chaque passe. Le completion est retenu côté ObjC (même règle que les rendus : ne jamais
    // capturer un block ObjC dans un lambda C++ type-erasé). @see -capturePluginTrace:...
    std::unique_ptr<OBJTraceSession>                       _traceSession;
    std::unique_ptr<OBJRenderJob>                          _traceJob;
    void (^_traceCompletion)(NSDictionary*);
}

/// Drapeau global posé par main.swift AVANT toute construction du moteur (c'est `init` qui ouvre
/// la carte son, il est donc trop tard une fois l'objet créé).
static BOOL gOBJAudioDisabled = NO;

+ (void)setAudioDisabled:(BOOL)disabled { gOBJAudioDisabled = disabled; }

- (instancetype)init {
    if (self = [super init]) {
        juce::initialiseJuce_GUI();
        // Coupe le bruit console de Tracktion (scan MIDI/Wave devices, etc.).
        juce::Logger::setCurrentLogger(new OBJSilentLogger());
        // AVANT la construction du moteur : c'est elle qui charge Settings.xml (en O(n²)).
        purgeStaleTrackDeviceAliases();
        _engine = std::make_unique<te::Engine>("objekat",
                                               std::make_unique<te::UIBehaviour>(),
                                               std::make_unique<OBJEngineBehaviour>());
        // Gain de sortie clip post-FX (plage -96…+40 dB). Doit être enregistré
        // avant toute création/restauration de clip.
        _engine->getPluginManager().createBuiltInType<te::ObjGainPlugin>();
        // Enveloppe fenêtre+fade de bus de groupe (folder). Enregistrer avant toute
        // création/restauration de folder de groupe.
        _engine->getPluginManager().createBuiltInType<te::ObjWindowFadePlugin>();
        _engine->getPluginManager().createBuiltInType<te::ObjParallelBlockPlugin>();
        _engine->getPluginManager().createBuiltInType<te::ObjAuxSendPlugin>();
        // Trace de plugin. La SONDE ne vit que dans un clone de rendu (elle n'apparaît dans aucun
        // projet), la RESTITUTION vit dans le graphe et se charge depuis le projet : les deux
        // s'enregistrent quand même ici, parce qu'un type non enregistré ne s'insère nulle part.
        // @see docs/objekat-capture-trace.md
        _engine->getPluginManager().createBuiltInType<te::ObjTraceProbePlugin>();
        _engine->getPluginManager().createBuiltInType<te::ObjTracePlaybackPlugin>();
        // `--no-audio` : on initialise le gestionnaire de périphériques avec ZÉRO sortie plutôt
        // que de sauter l'appel — Tracktion s'attend à un device manager initialisé, et le
        // court-circuiter le ferait trébucher plus loin. Zéro canal suffit à ne pas réquisitionner
        // la carte son, ce qui est le but : faire tourner plusieurs instances, ou une machine de
        // test sans sortie audio.
        _engine->getDeviceManager().initialise(0, gOBJAudioDisabled ? 0 : 2);
        [self logDefaultWaveOutput];
        _renderCompletions = [NSMutableDictionary dictionary];
        _exportCompletions = [NSMutableDictionary dictionary];
        _pluginEditorsFloating = true;
        [self createEdit];
        [self loadPluginCache];

        // Les éditeurs suivent le focus de l'app : masqués quand elle passe à l'arrière-plan,
        // rétablis au retour. Sans ça, leur niveau flottant les laisse au-dessus de TOUTES les
        // applications — on ne peut plus lire quoi que ce soit derrière objekat.
        {
            __unsafe_unretained OBJEngineCore* obsSelf = self;
            NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
            _appResignObserver =
                [nc addObserverForName:NSApplicationDidResignActiveNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification* _Nonnull note) {
                                (void)note;
                                [obsSelf hidePluginEditorsOnResign];
                            }];
            _appActivateObserver =
                [nc addObserverForName:NSApplicationDidBecomeActiveNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification* _Nonnull note) {
                                (void)note;
                                [obsSelf restorePluginEditorsOnActivate];
                            }];
        }

        // Veilleur de latence (PDC à chaud) — relit les latences ~4×/s, rebuild si elles changent.
        _lastLatencySignature = -1.0;
        _latencyResyncPending = false;
        _latencyWatcher = std::make_unique<OBJLatencyWatcher>();
        __unsafe_unretained OBJEngineCore* rawSelf = self;
        _latencyWatcher->onTick = [rawSelf] { [rawSelf checkLatencyAndRebuild]; };
        _latencyWatcher->startTimer(250);

        NSLog(@"[OBJ] Engine + Edit ready");
    }
    return self;
}

- (void)dealloc {
    if (_latencyWatcher)      _latencyWatcher->stopTimer();      // coupe les timers avant
    if (_stateReassertTimer)  _stateReassertTimer->stopTimer();  // destruction des ivars
    if (_pluginParkingTimer)  _pluginParkingTimer->stopTimer();
    _pluginParking.clear();   // relâche les plugins consignés tant que leur Edit est vivant
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    if (_appResignObserver)   [nc removeObserver:_appResignObserver];
    if (_appActivateObserver) [nc removeObserver:_appActivateObserver];
}

// MARK: - Éditeurs de plugins : niveau et suivi du focus

- (void)setPluginEditorsFloating:(BOOL)floating {
    _pluginEditorsFloating = floating ? true : false;
    for (auto& kv : _editorWindows)
        if (kv.second) kv.second->setAlwaysOnTop(_pluginEditorsFloating);
}

// @see la déclaration (OBJEngineCore.h) pour le partage des rôles avec la détection Cocoa.
// Le composant focalisé est celui de TOUT le processus côté JUCE : nos propres fenêtres étant
// SwiftUI, il ne peut appartenir qu'à un éditeur de plugin. On exige tout de même qu'un éditeur
// soit ouvert, pour ne rien répondre sur un focus resté d'une fenêtre déjà fermée.
- (BOOL)isEditingTextInPluginEditor {
    if (_editorWindows.empty()) return NO;
    auto* focused = juce::Component::getCurrentlyFocusedComponent();
    if (!focused) return NO;
    // Un Label en cours d'édition délègue à un TextEditor enfant, qui prend le focus : ce seul
    // test couvre donc aussi les libellés éditables.
    return dynamic_cast<juce::TextEditor*>(focused) != nullptr;
}

// @see la déclaration (OBJEngineCore.h). La fenêtre native d'une fenêtre JUCE s'obtient par le
// handle de son peer, qui est la NSView de contenu.
- (BOOL)isPluginEditorWindowKey {
    if (_editorWindows.empty()) return NO;
    NSWindow* key = [NSApp keyWindow];
    if (!key) return NO;
    for (auto& kv : _editorWindows) {
        auto* win = kv.second.get();
        if (!win) continue;
        if (void* handle = win->getWindowHandle())
            if ([(__bridge NSView*)handle window] == key) return YES;
    }
    return NO;
}

- (void)setPluginKeyFallback:(BOOL (^)(NSEvent*))handler {
    gPluginKeyFallback = [handler copy];
}

// App passée à l'arrière-plan : on masque les éditeurs visibles et on retient lesquels, pour ne
// rétablir QUE ceux-là (un éditeur fermé entre-temps ne doit pas ressusciter).
- (void)hidePluginEditorsOnResign {
    _editorsHiddenOnResign.clear();
    for (auto& kv : _editorWindows) {
        auto* win = kv.second.get();
        if (win && win->isVisible()) {
            _editorsHiddenOnResign.push_back(kv.first);
            win->setVisible(false);
        }
    }
}

- (void)restorePluginEditorsOnActivate {
    for (const auto& key : _editorsHiddenOnResign) {
        auto it = _editorWindows.find(key);
        if (it != _editorWindows.end() && it->second) {
            it->second->setVisible(true);
            it->second->setAlwaysOnTop(_pluginEditorsFloating);
        }
    }
    _editorsHiddenOnResign.clear();
}

// PDC à chaud : signature = somme des latences rapportées par tous les plugins user (FX de
// clip/groupe/aux/stem/master + instruments). Si elle change (ajout, retrait, ou réglage modifiant
// la latence), on reconstruit le graphe pour recompenser. restartPlayback → editHasChanged →
// ensureContextAllocated(true) = réallocation complète (ce qu'un reload de projet fait déjà).
- (void)checkLatencyAndRebuild {
    if (!_edit) return;
    double sig = 0.0;
    for (auto& kv : _pluginMap)     if (kv.second) sig += kv.second->getLatencySeconds();
    for (auto& kv : _instrumentMap) if (kv.second) sig += kv.second->getLatencySeconds();
    if (_lastLatencySignature < 0.0) { _lastLatencySignature = sig; return; }  // 1er passage = baseline
    // Un compile de rack vient de reconstruire le graphe : la latence lue ici est déjà celle que
    // cette reconstruction a compensée. On absorbe la nouvelle référence sans reconstruire —
    // sinon on payait une reconstruction complète de plus, 250 ms après chaque ajout de plugin.
    // (On absorbe au TIC, pas au compile : la latence d'un plugin n'est fiable qu'une fois le
    // graphe préparé. Si elle rebouge après, le tic suivant la rattrape normalement.)
    if (_latencyResyncPending) { _latencyResyncPending = false; _lastLatencySignature = sig; return; }
    if (std::abs(sig - _lastLatencySignature) > 1.0e-7) {
        _lastLatencySignature = sig;
        _edit->restartPlayback();
    }
}

// MARK: - Cache plugins

- (void)loadPluginCache {
    NSString* xml = [[NSUserDefaults standardUserDefaults] stringForKey:kPluginCacheKey];
    if (!xml) return;
    auto xmlElem = juce::XmlDocument::parse(juce::String::fromUTF8([xml UTF8String]));
    if (!xmlElem) return;
    _engine->getPluginManager().knownPluginList.recreateFromXml(*xmlElem);
    NSLog(@"[OBJ] Plugin cache chargé : %d plugins",
          _engine->getPluginManager().knownPluginList.getNumTypes());
}

- (void)savePluginCache {
    auto xmlElem = _engine->getPluginManager().knownPluginList.createXml();
    if (!xmlElem) return;
    juce::String xmlStr = xmlElem->toString();
    NSString* xml = [NSString stringWithUTF8String:xmlStr.toRawUTF8()];
    [[NSUserDefaults standardUserDefaults] setObject:xml forKey:kPluginCacheKey];
    NSLog(@"[OBJ] Plugin cache sauvegardé : %d plugins",
          _engine->getPluginManager().knownPluginList.getNumTypes());
}

- (BOOL)hasCachedPlugins {
    return [[NSUserDefaults standardUserDefaults] objectForKey:kPluginCacheKey] != nil;
}

- (void)clearPluginCache {
    // Effacer uniquement le cache persisté (UserDefaults).
    // Ne PAS toucher knownPluginList en mémoire : les ExternalPlugin actifs
    // y sont ancrés ; les vider détruirait les instances déjà chargées.
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPluginCacheKey];
    NSLog(@"[OBJ] Plugin cache UserDefaults effacé (liste mémoire conservée)");
}

// MARK: - Edit persistant

- (void)createEdit {
    // AVANT de remplacer l'Edit : vider la consigne. Un plugin consigné tient une référence sur
    // SON Edit et vit dans SON PluginCache ; le laisser survivre au remplacement ferait courir
    // son destructeur après celui de l'Edit qui le possède.
    if (_pluginParkingTimer) _pluginParkingTimer->stopTimer();
    _pluginParking.clear();

    auto editTree = te::createEmptyEdit(*_engine);
    _edit = te::loadEditFromState(*_engine, editTree);
    _poolTracks.clear();
    _childOwnerMap.clear();
    _containerClipMap.clear();
    _groupBoundsMap.clear();
    _groupLoopRangeMap.clear();
    _faderGainMap.clear();
    _windowFadeMap.clear();
    _clipMap.clear();
    _midiClipMap.clear();
    _instrumentMap.clear();
    _objectChainMap.clear();
    _stemBusMap.clear();
    _stemRouteToMain.clear();
    _stemGainMap.clear();
    _stemMeterClients.clear();
    _masterMeterClient.reset();
    _masterStemKey.clear();
    _masterAnchorGain = nullptr;

    // VU master créé tout de suite (dans la master plugin-list → toujours dans le graphe au play).
    [self ensureMasterMeter];
}

// MARK: - Pool de pistes (allocation d'ordonnancement)
//
// La LANE est une donnée d'affichage portée par l'objet : elle ne dit rien au moteur. La PISTE
// est une ressource d'ORDONNANCEMENT, et c'est tout ce qu'elle est ici :
//   • c'est la seule unité que le player racine parallélise (un CombiningNode sérialise TOUS
//     ses TimedNode sur le thread qui le traite) ;
//   • Tracktion crée deux devices d'entrée virtuels par AudioTrack, dont les alias gonflaient
//     Settings.xml jusqu'aux 50 s de démarrage (@see purgeStaleTrackDeviceAliases).
// Elle ne porte donc ni identité ni réglage : ni nom montré, ni plugin, ni volume.
//
// Les deux ne sont reliées que par une POLITIQUE, `trackSlotForKey:lane:`, et par elle seule.
// Politique en vigueur : **un compartiment par (STEM, lane)**. La lane conserve le
// parallélisme d'avant le découplage ; le stem, lui, est ce qui rend les bus de stem possibles
// — un stem est un FolderTrack submix, et l'appartenance d'un objet s'exprime en le posant sur
// une piste QUI EST DANS ce folder. En changer (un pool borné par le nombre de cœurs, un
// compartiment réservé aux objets à forte latence pour que leur rembourrage ne se paie pas sur
// leurs voisins) ne demande de toucher qu'à cette méthode et à `trackForSlot:`.
//
// ⚠️ Ce qu'aucune politique ne doit faire : rendre le nombre de pistes proportionnel au nombre
// d'OBJETS. C'est ce coût-là qu'a supprimé la bascule containerclip ; « une lane = une piste »
// n'en était qu'un proxy commode, et un mauvais (30 lanes visibles = 30 pistes, même si trois
// objets jouent). Le facteur stem borne à (stems × lanes occupées), et les compartiments vides
// sont ramassés.

// Clé du compartiment où doit vivre un objet top-level. Voir la note ci-dessus avant d'y toucher.
//
// Le stem n'est PAS un paramètre : il se DÉDUIT de l'endroit où l'objet vit déjà (@see
// stemKeyForKey:). Même doctrine que pour la piste porteuse — le graphe est la seule vérité,
// une table parallèle ne serait qu'une occasion de dériver. Conséquence utile : changer de lane
// garde l'objet dans son stem, et un objet qui n'a pas encore de piste naît au Main, où
// assignObjects:toStemID: viendra le chercher.
- (OBJTrackSlot)trackSlotForKey:(const std::string&)key lane:(int)lane {
    return { [self stemKeyForKey:key], lane };
}

// Piste d'un compartiment, créée à la demande. C'est le SEUL endroit qui crée des AudioTracks
// pour l'arrangement. Elle ne reçoit AUCUN plugin (support pur) : la chaîne d'un objet vit sur
// son clip, celle d'un stem sur son FolderTrack.
- (te::AudioTrack*)trackForSlot:(const OBJTrackSlot&)slot {
    if (!_edit) return nullptr;

    for (auto& p : _poolTracks)
        if (p.lane == slot.lane && p.stemKey == slot.stemKey)
            return p.track;

    // Un compartiment de stem naît DANS le folder du stem : c'est là, et nulle part ailleurs,
    // que se joue l'appartenance. Si le folder n'existe pas (stem pas encore créé côté moteur),
    // on retombe à la racine — le Main — plutôt que de ne rien rendre.
    te::FolderTrack* folder = nullptr;
    if (!slot.stemKey.empty())
        if (auto it = _stemBusMap.find(slot.stemKey); it != _stemBusMap.end())
            folder = it->second;

    auto track = _edit->insertNewAudioTrack(te::TrackInsertPoint(folder, nullptr), nullptr);
    if (!track) return nullptr;
    // Nom de diagnostic uniquement : rien ne le lit, aucune UI ne le montre.
    track->setName(juce::String("Slot ") + juce::String(slot.lane));
    _poolTracks.push_back({ folder ? slot.stemKey : std::string(), slot.lane, track.get() });
    // Une piste neuve s'initialise sur le device par défaut, et elle vient de s'insérer EN TÊTE
    // du folder : sans ce rappel, elle devient la sortie du bus (@see applyStemRouting) et
    // rebranche au Main un stem qu'on avait détaché.
    if (folder) [self applyStemRouting:slot.stemKey];
    return track.get();
}

// Compartiment d'une piste du pool (lane -1 si ce n'en est pas une).
- (OBJTrackSlot)slotOfTrack:(te::Track*)track {
    for (auto& p : _poolTracks)
        if (p.track == track)
            return { p.stemKey, p.lane };
    return { {}, -1 };
}

// Stem d'un objet, DÉDUIT du folder qui porte sa piste. Chaîne vide = Main (aucun folder).
// Un enfant de groupe rend le stem de son groupe : il vit dans le container, qui vit sur la
// piste du groupe — c'est exactement la règle du modèle (un enfant suit son groupe).
- (std::string)stemKeyForKey:(const std::string&)key {
    te::Track* t = [self trackForKey:key];
    if (!t) return {};
    auto* parent = t->getParentTrack();
    if (!parent) return {};
    for (auto& [stemKey, folder] : _stemBusMap)
        if (folder == parent) return stemKey;
    return {};
}

// Supprime les pistes du pool devenues vides. Un compartiment ne se « ferme » jamais
// explicitement : il se vide quand son dernier objet part (suppression, réallocation, entrée
// dans un groupe, changement de stem). Garder des pistes vides annulerait une partie du gain
// visé — chacune coûte encore ses nœuds dans le graphe. À appeler après tout retrait de clip.
- (void)pruneEmptyPoolTracks {
    if (!_edit) return;
    for (auto it = _poolTracks.begin(); it != _poolTracks.end(); ) {
        te::AudioTrack* t = it->track;
        if (t && t->getClips().isEmpty()) {
            _edit->deleteTrack(t);
            it = _poolTracks.erase(it);
        } else ++it;
    }
}

// Piste qui PORTE ce clip, containers ancêtres traversés. `Clip::getTrack()` ne répond que pour
// un clip posé DIRECTEMENT sur une piste : dans un ContainerClip il renvoie nullptr, puisque le
// parent est le container. On remonte donc de container en container — un ContainerClip est à la
// fois Clip et ClipOwner, c'est ce qui rend la boucle possible.
static te::Track* objOwningTrack(te::Clip& clip) {
    te::Clip* c = &clip;
    while (c) {
        if (auto* t = c->getTrack()) return t;
        c = dynamic_cast<te::ContainerClip*>(c->getParent());
    }
    return nullptr;
}

// Piste Tracktion qui PORTE un objet — DÉDUITE de son clip, jamais mémorisée : le graphe est la
// seule vérité, et une table parallèle ne serait qu'une occasion de dériver. Un clip ou un
// groupe n'a pas de piste à lui, il partage celle de son compartiment ; un enfant de groupe
// remonte jusqu'à la piste qui porte son groupe racine. Seuls les clips MIDI gardent une piste
// dédiée. Sert au rendu offline (bake) et au diagnostic.
- (te::Track*)trackForKey:(const std::string&)key {
    te::Clip* clip = nullptr;
    if (auto it = _clipMap.find(key); it != _clipMap.end())                    clip = it->second.get();
    else if (auto it = _containerClipMap.find(key); it != _containerClipMap.end()) clip = it->second;
    else if (auto it = _midiClipMap.find(key); it != _midiClipMap.end())       clip = it->second.get();
    return clip ? objOwningTrack(*clip) : nullptr;
}

// Propriétaire de clips (ClipOwner) où doit vivre l'objet `key` : le container de son groupe
// s'il est enfant, sinon la piste de son compartiment.
- (te::ClipOwner*)clipOwnerForKey:(const std::string&)key lane:(int)lane {
    if (auto ow = _childOwnerMap.find(key); ow != _childOwnerMap.end())
        if (auto c = _containerClipMap.find(ow->second); c != _containerClipMap.end())
            return c->second;
    return [self trackForSlot:[self trackSlotForKey:key lane:lane]];
}

// Recale l'étendue du ContainerClip d'un groupe sur l'union des positions de ses enfants, avec
// un offset égal à son début (temps local = temps edit → les enfants gardent leurs positions
// absolues). À appeler après TOUTE opération qui bouge, ajoute ou retire un enfant : c'est ce
// qui permet au CombiningNode de la piste de ne traiter que les groupes qui croisent le bloc
// courant (cf le commentaire de kEmptyContainerSpanSecs — sans ça, tout est traité en permanence).
- (void)refreshContainerSpanForKey:(const std::string&)key {
    auto it = _containerClipMap.find(key);
    if (it == _containerClipMap.end() || !it->second) return;
    te::ContainerClip* cc = it->second;

    double start = 0.0, end = 0.0;
    bool bounded = false;

    if (auto bit = _groupBoundsMap.find(key); bit != _groupBoundsMap.end()) {
        // Groupe borné : l'étendue du container EST la fenêtre du modèle. Un enfant qui
        // déborde n'agrandit plus le groupe, il est coupé par ContainerClipNode::process —
        // ré-élargir les bornes le fait réapparaître, comme le faisait ObjWindowFade.
        bounded = true;
        start = bit->second.getStart().inSeconds();
        end   = bit->second.getEnd().inSeconds();
    } else {
        // Groupe infini : enveloppe des enfants. Une étendue « ouverte » ([0, 1e9]) coûterait
        // la paresse du CombiningNode de la piste — le stutter que fe6625a avait corrigé.
        bool any = false;
        for (auto* c : cc->getClips()) {
            if (!c) continue;
            // Un bus d'aux enfant est HORS enveloppe : il ne joue pas de contenu (le graphe
            // le sort des enfants avant de bâtir le CombiningNode), et un aux infini
            // ([0, 1e9]) ferait exploser l'étendue du groupe — la paresse de la lane avec.
            if (auto* sub = dynamic_cast<te::ContainerClip*>(c); sub && sub->isObjAuxBus())
                continue;
            const auto t = c->getPosition().time;
            const double s = t.getStart().inSeconds(), e = t.getEnd().inSeconds();
            if (!any) { start = s; end = e; any = true; }
            else      { start = std::min(start, s); end = std::max(end, e); }
        }
        if (!any) { start = 0.0; end = kEmptyContainerSpanSecs; }
    }

    start = juce::jmax(0.0, start);
    if (end <= start) end = start + kEmptyContainerSpanSecs;

    // Boucle (groupes BORNÉS uniquement — un infini n'a pas de fenêtre, rien à dépasser ; un aux
    // n'a pas d'enfants, `_groupLoopRangeMap` n'est jamais posé pour lui) : la plage IN/OUT posée
    // par le modèle (`updateGroupWindow:`) se répète tant que [start,end] la dépasse. Plus de
    // calcul d'enveloppe ici : le modèle Swift fait foi.
    //
    // ⚠️ La plage est en secondes EDIT ABSOLUES, pas locales au groupe — c'est le repère du
    // container, dont l'offset vaut son propre début (temps local = temps edit, les enfants y
    // sont à leur position absolue). Donnée en local, elle désignait une région vide de la
    // timeline et le groupe se taisait ENTIÈREMENT dès qu'il ne commençait pas à 0.
    // @see [[loop-item-plan]]
    te::TimeRange desiredLoop;
    if (bounded) {
        if (auto lit = _groupLoopRangeMap.find(key); lit != _groupLoopRangeMap.end())
            desiredLoop = lit->second;
    }
    if (cc->getLoopRange() != desiredLoop)
        cc->setLoopRange(desiredLoop);

    // OFFSET du container — normalement son propre début (temps local = temps edit, cf. le
    // commentaire d'en-tête). Sous boucle, il se décale de −loopStart. Raison : le repli de
    // ContainerClipNode lit
    //     position locale = loopStart + ((T − (start − offset)) mod longueurBoucle)
    // (tracktion_ContainerClipNode.cpp) — il AJOUTE loopStart AVANT le modulo, ce qui suppose un
    // temps local compté depuis le début du clip. Avec offset = start il recevait T tel quel et
    // partait sur une phase arbitraire (`loopStart + (T mod L)`), le motif jouant décalé de
    // `start mod L` par rapport à ce que l'écran montre. Retrancher loopStart remet la phase
    // d'aplomb : le bord GAUCHE du groupe joue le point IN, et la tranche [IN,OUT] se répète
    // ensuite — même règle que pour un clip audio (@see updatePosition:...:forID:).
    // Le clamp à 0 est la règle, pas l'exception : IN vit DANS le groupe, donc loopStart ≥ start.
    const double desiredOffset = desiredLoop.isEmpty()
        ? start
        : juce::jmax(0.0, start - desiredLoop.getStart().inSeconds());

    // La fenêtre de la CHAÎNE suit l'étendue du container — y compris pour un groupe infini, dont
    // l'étendue bouge dès qu'un enfant bouge. Posée AVANT la sortie sèche ci-dessous : celle-ci ne
    // regarde que la géométrie du clip, or les fondus peuvent avoir changé sans qu'elle bouge.
    // Les durées de fondu sont relues sur le plugin lui-même, seul endroit où elles vivent
    // désormais (les fondus DU CLIP d'un container sont tenus à zéro).
    if (auto wit = _windowFadeMap.find(key); wit != _windowFadeMap.end())
        if (auto* wf = dynamic_cast<te::ObjWindowFadePlugin*>(wit->second.get()))
            wf->setWindow(start, end, wf->fadeIn, wf->fadeOut);

    te::ClipPosition pos = cc->getPosition();
    const double curStart = pos.time.getStart().inSeconds();
    const double curEnd   = pos.time.getEnd().inSeconds();
    const double curOff   = pos.offset.inSeconds();
    constexpr double eps = 1.0e-9;
    // Sortie sèche si rien n'a bougé : setPosition déclencherait une reconstruction du graphe.
    if (std::abs(curStart - start) < eps && std::abs(curEnd - end) < eps
        && std::abs(curOff - desiredOffset) < eps)
        return;

    pos.time   = te::TimeRange(te::TimePosition::fromSeconds(start),
                               te::TimePosition::fromSeconds(end));
    pos.offset = te::TimeDuration::fromSeconds(desiredOffset);
    cc->setPosition(pos);

    // Un sous-groupe qui s'étend déplace aussi les bornes de son parent.
    if (auto ow = _childOwnerMap.find(key); ow != _childOwnerMap.end())
        [self refreshContainerSpanForKey:ow->second];
}

// Variante « côté enfant » : si l'objet vit dans un groupe, recale l'étendue de ce groupe.
- (void)refreshOwnerContainerSpanFor:(const std::string&)childKey {
    if (auto ow = _childOwnerMap.find(childKey); ow != _childOwnerMap.end())
        [self refreshContainerSpanForKey:ow->second];
}

// Pose la chaîne commune de fin d'un objet sur sa plugin-list hôte : fader ObjGain puis
// ObjWindowFade (fenêtre + fondus post-FX). Les deux sont mémorisés par objectID — la chaîne
// contiendra d'autres ObjGain (trims), donc « le premier ObjGain » n'est plus un repère.
//
// TOUT objet en reçoit un, container compris. Ça n'a pas toujours été le cas : un GROUPE et un
// AUX s'en passaient, leurs bornes venant de l'étendue du ContainerClip et leurs fondus de
// `createFadeNodeForClip`, appliqué APRÈS la plugin-list. Deux raisons d'y avoir renoncé :
//
//  1. L'INCOHÉRENCE AVEC UN CLIP, dans les deux sens. La queue des FX d'un groupe SANS fondu
//     sonnait au-delà de ses bornes, celle d'un clip était rasée — et un groupe AVEC fondu se
//     comportait comme un clip, puisque `FadeInOutNode` est construit avec
//     `clearSamplesOutsideFade`. Le groupe n'était donc même pas cohérent avec lui-même : poser
//     un fondu changeait le sort de la queue. Et l'envoi, posé en fin de plugin-list, était
//     prélevé AVANT ces fondus-là : un groupe qui s'éteignait alimentait son aux à plein niveau.
//  2. L'objection historique est PÉRIMÉE. ObjWindowFade lit son temps sur
//     `PluginRenderContext::editTime`, que `PluginNode` recule de la latence amont ; ça lui
//     faisait couper les L premiers samples d'un groupe DU TEMPS de la lecture anticipée
//     (patchs 0007/0008), où le matériau du bloc `t` appartenait à `t + L - Lc`. Le patch 0017
//     a abandonné cette lecture anticipée : `automationAdjustmentTime` vaut désormais
//     `-latence` partout, donc le plugin voit le vrai temps d'edit de son matériau.
//
// Règle unique qui en résulte, valable pour tout objet : **la fenêtre coupe la chaîne, fondus
// compris**. Un bus qui doit laisser sonner sa queue se déclare INFINI (fenêtre à 24 h), ce qui
// est exactement ce que le modèle appelle un bus infini.
//
// Corollaire à ne pas oublier côté appelant : les fondus DU CLIP d'un container doivent être
// remis à zéro (@see updateGroupWindow:, updateAuxWindow:), sans quoi ils s'appliqueraient une
// seconde fois par-dessus — fondu au carré.
- (void)installObjectChainTail:(te::PluginList&)pl
                        forKey:(const std::string&)key
                        volume:(float)volumeDb
                           pan:(float)pan
                        window:(te::TimeRange)window
                        fadeIn:(double)fadeIn
                       fadeOut:(double)fadeOut {
    te::Plugin::Ptr fader = insertObjGain(pl);
    if (fader) {
        if (auto* g = dynamic_cast<te::ObjGainPlugin*>(fader.get())) {
            g->setGainDb(volumeDb);
            g->setPan(pan);
        }
        _faderGainMap[key] = fader;
    }

    te::Plugin::Ptr wf = pl.insertPlugin(te::ObjWindowFadePlugin::create(), pl.size());
    if (wf) {
        if (auto* w = dynamic_cast<te::ObjWindowFadePlugin*>(wf.get()))
            w->setWindow(window.getStart().inSeconds(), window.getEnd().inSeconds(), fadeIn, fadeOut);
        _windowFadeMap[key] = wf;
    }
}

// Repose la fenêtre + les fades de l'objet (ObjWindowFade mémorisé). Conserve les fades
// courants si `keepFades` (déplacement/redimensionnement).
- (void)setWindowForKey:(const std::string&)key
                  start:(double)startSecs
                    end:(double)endSecs
                 fadeIn:(double)fadeIn
                fadeOut:(double)fadeOut {
    auto it = _windowFadeMap.find(key);
    if (it == _windowFadeMap.end()) return;
    if (auto* w = dynamic_cast<te::ObjWindowFadePlugin*>(it->second.get()))
        w->setWindow(startSecs, endSecs, fadeIn, fadeOut);
}

// Invariants d'un clip wave fraîchement créé dans ce modèle :
//  • pas de time-stretch (aucune lib activée dans ce build — sinon StretchSegment jassert).
//
// Le proxy n'est PLUS interdit dans un groupe : l'assert(!acb->canUseProxy()) vivait dans la
// branche USE_DYNAMIC_OFFSET_CONTAINER_CLIP de createNodeForContainerClip, abandonnée à
// l'étape 1. Les enfants passent maintenant par createNodeForClips → createNodeForAudioClip,
// le chemin ordinaire, donc la lecture inversée y marche comme sur une piste.
static void configureFreshClip(const te::WaveAudioClip::Ptr& clip, const te::ClipPosition& pos,
                               double speed, bool reversed) {
    clip->setAutoTempo(false);
    clip->setTimeStretchMode(te::TimeStretcher::disabled);
    if (reversed) clip->setIsReversed(true);
    if (speed != 1.0) clip->setSpeedRatio(speed);
    clip->setPosition(pos);   // EN DERNIER : les appels ci-dessus redimensionnent le clip
}

// MARK: - CRUD live

- (void)addSoundObject:(OBJSoundObjectData*)data withID:(NSString*)uuid {
    if (!_edit) return;

    // Idempotent : supprimer l'éventuel track existant pour cet UUID
    [self removeSoundObjectWithID:uuid];

    juce::File audioFile(juce::String::fromUTF8([data.filePath UTF8String]));
    if (!audioFile.existsAsFile()) {
        NSLog(@"[OBJ] addSoundObject: file not found: %@", data.filePath);
        return;
    }

    te::AudioFile tracktionFile(*_engine, audioFile);
    double fileLength = tracktionFile.getLength();
    if (fileLength <= 0) {
        NSLog(@"[OBJ] addSoundObject: zero-length/unsupported: %@", data.filePath);
        return;
    }

    double clipDuration = (data.duration > 0) ? data.duration : fileLength;
    std::string key([uuid UTF8String]);

    // Le clip se pose sur la piste de son compartiment (créée à la demande), ou dans le
    // ContainerClip de son groupe si l'appelant l'y a déjà rattaché.
    te::ClipOwner* owner = [self clipOwnerForKey:key lane:(int)data.lane];
    if (!owner) return;
    const bool insideContainer = (_childOwnerMap.find(key) != _childOwnerMap.end());

    te::ClipPosition pos;
    pos.time = te::TimeRange(
        te::TimePosition::fromSeconds(data.startTime),
        te::TimePosition::fromSeconds(data.startTime + clipDuration)
    );
    pos.offset = te::TimeDuration::fromSeconds(juce::jmax(0.0, data.sourceOffset));

    auto clip = te::insertWaveClip(*owner, audioFile.getFileNameWithoutExtension(),
                                   audioFile, pos, te::DeleteExistingClips::no);
    if (!clip) return;

    // ⚠️ INVARIANT « clip sans time-stretch » — à appliquer à TOUT clip fraîchement créé
    // (ici, à la migration dans un container, et au split).
    // Ce build n'a aucune lib de time-stretch activée → defaultMode == disabled. Si on laisse
    // l'autoTempo/timeStretchMode par défaut, Tracktion demande un proxy time-stretché et
    // StretchSegment appelle timestretcher.initialise(mode=disabled) → !isInitialised() →
    // jassert/EXC_BREAKPOINT (tracktion_AudioClipBase.cpp).
    configureFreshClip(clip, pos, 1.0, false);

    _clipMap[key] = clip;

    // La chaîne propre à l'objet (trims + FX user + fader + fenêtre/fades) vit sur la CLIP
    // plugin-list : la piste est partagée par toute la lane, elle ne peut rien porter de
    // spécifique. C'est ce qui impose une chaîne LINÉAIRE (pas de RackInstance sur un clip).
    if (auto* pl = clip->getPluginList())
        [self installObjectChainTail:*pl forKey:key
                              volume:data.volume pan:data.pan
                              window:pos.time fadeIn:data.fadeIn fadeOut:data.fadeOut];

    // Un enfant qui arrive étend son groupe.
    if (insideContainer) [self refreshOwnerContainerSpanFor:key];

    auto fileName = audioFile.getFileName();
    NSLog(@"[OBJ] addSoundObject: %s lane=%ld start=%.2f dur=%.2f off=%.2f%s",
          fileName.toRawUTF8(), (long)data.lane, data.startTime, clipDuration, data.sourceOffset,
          insideContainer ? " (dans un groupe)" : "");
}

// MARK: - MIDI (clip MIDI + instrument virtuel)
//
// Un objet MIDI = UN ContainerClip dont l'unique enfant est un te::MidiClip, l'instrument
// virtuel en index 0 de la plugin-list du CONTAINER : [Instrument, FX…, ObjGain, ObjWindowFade].
// Le MIDI sort du container (ContainerClipNode passe pc.buffers.midi à son player local) et
// traverse cette chaîne — l'instrument le convertit en audio, le reste le traite.
//
// Pourquoi un container par objet MIDI, et pas le MidiClip nu sur la piste comme avant :
//   • un MidiClip n'est pas un AudioClipBase — il n'a NI plugin-list NI fades, donc sa chaîne
//     devait vivre ailleurs. Sur une piste dédiée, ça coûtait une piste par clip MIDI (et un
//     instrument tournant sur TOUS les blocs de la session, pas seulement sa fenêtre) ;
//   • et surtout un tel clip ne pouvait pas entrer dans le container d'un groupe : il restait
//     audible mais hors du bus, donc le bake d'un groupe qui en contenait perdait le MIDI.
// Avec le container, un objet MIDI est un objet comme les autres : chaîne, fenêtre, fondus,
// lane, groupe, aux, bake, objet sonore. @see canContainMIDI (patch moteur 0021)
//
// L'instrument NE PEUT PAS être posé sur le container d'un groupe qui porte aussi des enfants
// audio : un VSTi ÉCRIT son buffer, il ne l'additionne pas — il écraserait leur somme. D'où
// « un container par objet MIDI », dont le contenu est exactement un MidiClip.

- (void)addMidiClip:(OBJSoundObjectData*)data withID:(NSString*)uuid {
    if (!_edit) return;
    std::string key([uuid UTF8String]);
    if (_containerClipMap.count(key)) return;   // idempotent

    double clipDuration = (data.duration > 0) ? data.duration : 4.0;
    te::TimeRange range(
        te::TimePosition::fromSeconds(data.startTime),
        te::TimePosition::fromSeconds(data.startTime + clipDuration));

    te::ClipOwner* owner = [self clipOwnerForKey:key lane:(int)data.lane];
    if (!owner) return;

    auto* raw = te::insertNewClip(*owner, te::TrackItem::Type::container, range);
    auto* cc  = dynamic_cast<te::ContainerClip*>(raw);
    if (!cc) { NSLog(@"[OBJ] addMidiClip: création du container refusée (%@)", uuid); return; }

    juce::String shortID = juce::String::fromUTF8(key.c_str()).substring(0, 8);
    cc->setName("MIDI " + shortID);   // ASCII only (String(const char*) assert sur du non-ASCII)
    cc->setAutoTempo(false);          // Objekat raisonne en secondes, comme pour un groupe

    auto clip = te::insertMIDIClip(*cc, juce::String("MIDI"), range);
    if (!clip) {
        NSLog(@"[OBJ] addMidiClip: le container refuse le clip MIDI (%@)", uuid);
        cc->removeFromParent();
        return;
    }

    _containerClipMap[key] = cc;
    _midiClipMap[key]      = clip;

    // Chaîne complète AVEC ObjWindowFade, contrairement au container d'un groupe : ici la
    // fenêtre est celle du clip et c'est elle qui coupe la queue de l'instrument à la fin de
    // l'objet — exactement ce que faisait la chaîne de piste avant. Un groupe, lui, laisse
    // volontairement sonner cette queue. @see installObjectChainTail
    if (auto* pl = cc->getPluginList())
        [self installObjectChainTail:*pl forKey:key
                              volume:data.volume pan:data.pan
                              window:range fadeIn:data.fadeIn fadeOut:data.fadeOut];

    [self refreshContainerSpanForKey:key];

    NSLog(@"[OBJ] addMidiClip: %@ lane=%ld start=%.2f dur=%.2f (container)",
          uuid, (long)data.lane, data.startTime, clipDuration);
}

- (void)setMidiNotes:(NSArray<NSDictionary*>*)notes forID:(NSString*)uuid {
    auto it = _midiClipMap.find(std::string([uuid UTF8String]));
    if (it == _midiClipMap.end()) return;

    auto& seq = it->second->getSequence();
    seq.clear(nullptr);
    for (NSDictionary* n in notes) {
        int    pitch = [n[@"pitch"]  intValue];
        double start = [n[@"start"]  doubleValue];
        double len   = [n[@"length"] doubleValue];
        int    vel   = n[@"velocity"] ? [n[@"velocity"] intValue] : 100;
        seq.addNote(pitch,
                    te::BeatPosition::fromBeats(start),
                    te::BeatDuration::fromBeats(len),
                    vel, 0, nullptr);
    }
    NSLog(@"[OBJ] setMidiNotes: %@ → %lu notes", uuid, (unsigned long)notes.count);
}

// Boucle d'un clip MIDI : le motif de notes entre [startBeats, endBeats] se répète tant que la
// fenêtre de l'objet le dépasse — mécanisme NATIF de te::MidiClip (setLoopRangeBeats, consommé
// par LoopingMidiNode/MidiNode selon canUseProxy), indépendant du container qui l'héberge : pas
// de lien avec _groupLoopRangeMap/refreshContainerSpanForKey (réservés aux GROUPES). La fenêtre
// elle-même (ce qui est audible du motif bouclé) reste posée par ObjWindowFade, inchangée ici.
// @see [[loop-item-plan]]
- (void)setMidiLoop:(BOOL)enabled startBeats:(double)startBeats endBeats:(double)endBeats forID:(NSString*)uuid {
    auto it = _midiClipMap.find(std::string([uuid UTF8String]));
    if (it == _midiClipMap.end()) return;
    if (enabled && endBeats > startBeats) {
        it->second->setLoopRangeBeats(te::BeatRange(
            te::BeatPosition::fromBeats(startBeats),
            te::BeatPosition::fromBeats(endBeats)));
    } else {
        it->second->disableLooping();
    }
}

// Un arbre PLUGIN sérialisé (`getPluginStateXML`) porte l'`id` — l'EditItemID — de l'instance
// D'ORIGINE, avec ses params et son chunk. L'insérer tel quel enregistre un SECOND EditItem
// sous le même id : `Edit::addItem` assert, le registre `knownEditItems` ne retient que le
// dernier venu, et l'instance d'origine devient introuvable par id. C'est ce qui se produisait
// à chaque duplication / coupe / collage d'un objet portant des plugins, et à chaque
// recompilation de rack depuis un état sauvé.
//
// On renumérote donc tout le sous-arbre. `remapIDs` — et pas un simple retrait de la propriété
// — parce qu'il réécrit AUSSI les références internes (macro-paramètres, assignations de
// modifieurs) : les supprimer les casserait, les garder les ferait pointer chez le voisin.
- (void)freshenItemIDsInTree:(juce::ValueTree&)tree {
    if (!_edit || !tree.isValid()) return;
    te::EditItemID::remapIDs(tree, nullptr, *_edit);
}

// Résout une description de plugin (état sauvé, ou knownPluginList + findAllTypesForFile +
// fallback) et l'insère dans `list` à `index`. Variante isolée de -addPlugin: pour pouvoir
// forcer l'index 0 (instrument). Retourne le Plugin::Ptr inséré, ou nullptr.
- (te::Plugin::Ptr)insertResolvedPlugin:(NSDictionary*)pluginInfo
                               stateXML:(NSString*)stateXML
                                   into:(te::PluginList&)list
                                atIndex:(int)index {
    NSString* identifier = pluginInfo[@"identifier"];
    NSString* format     = pluginInfo[@"format"];
    NSString* pluginName = pluginInfo[@"name"] ?: @"?";
    if (!identifier || !format) return nullptr;

    juce::String fmtStr(juce::String::fromUTF8([format UTF8String]));
    juce::String idStr(juce::String::fromUTF8([identifier UTF8String]));

    if (stateXML.length > 0) {
        if (auto xml = juce::parseXML(juce::String::fromUTF8([stateXML UTF8String]))) {
            juce::ValueTree savedTree = juce::ValueTree::fromXml(*xml);
            if (savedTree.isValid() && savedTree.hasType(juce::Identifier("PLUGIN"))) {
                // CONSIGNE : ce plugin vient peut-être d'être retiré à l'identique (aller-retour
                // d'emballage, de matérialisation, de coupe, d'annulation). Le reprendre vivant
                // évite un chargement d'AU complet sur le thread principal. Réinsérer SON arbre
                // rend le même objet — @see OBJParkedPlugin.
                if (auto parked = [self takeParkedPluginMatching:savedTree]) {
                    if (auto p = list.insertPlugin(parked->state, index)) {
                        NSLog(@"[PERF] plugin « %@ » repris de la consigne (aucun chargement)",
                              pluginName);
                        return p;
                    }
                    // Refusé par la liste (limite, type incompatible) : on relâche et on charge
                    // normalement plus bas.
                }
                [self freshenItemIDsInTree:savedTree];   // sinon on vole son id à l'instance source
                if (auto p = list.insertPlugin(savedTree, index)) {
                    // Idem que dans le compilateur de rack : un AU peut avoir ignoré sa
                    // restauration d'état faute d'être initialisé → on revérifie plus tard.
                    [self schedulePluginStateReassert:p fromTree:savedTree];
                    return p;
                }
            }
        }
    }

    if (fmtStr == "TracktionInternal") {
        juce::ValueTree pt("PLUGIN");
        pt.setProperty("type", idStr, nullptr);
        return list.insertPlugin(pt, index);
    }

    auto& kl = _engine->getPluginManager().knownPluginList;
    juce::PluginDescription foundDesc;
    bool found = false;
    for (int i = 0; i < kl.getNumTypes(); i++) {
        auto* d = kl.getType(i);
        if (!d || d->pluginFormatName != fmtStr) continue;
        bool match = (d->fileOrIdentifier == idStr);
        if (!match && fmtStr == "AudioUnit") {
            juce::String bare = d->fileOrIdentifier.fromLastOccurrenceOf(":", false, false)
                                                   .fromLastOccurrenceOf("/", false, false);
            juce::String qb   = idStr.fromLastOccurrenceOf(":", false, false)
                                     .fromLastOccurrenceOf("/", false, false);
            match = (bare == qb && !bare.isEmpty());
        }
        if (match) { foundDesc = *d; found = true; break; }
    }
    {
        auto& fmgr = _engine->getPluginManager().pluginFormatManager;
        for (int fi = 0; fi < fmgr.getNumFormats(); fi++) {
            auto* fmt = fmgr.getFormat(fi);
            if (!fmt || fmt->getName() != fmtStr) continue;
            juce::String searchId = (fmtStr == "AudioUnit" && !idStr.startsWith("AudioUnit:"))
                                    ? "AudioUnit:" + idStr : idStr;
            juce::OwnedArray<juce::PluginDescription> realTypes;
            fmt->findAllTypesForFile(realTypes, searchId);
            if (!realTypes.isEmpty()) {
                foundDesc = *realTypes[0];
                juce::String targetName(juce::String::fromUTF8([pluginName UTF8String]));
                for (auto* rd : realTypes) if (rd->name == targetName) { foundDesc = *rd; break; }
                kl.addType(foundDesc);
                [self savePluginCache];
                found = true;
            }
            break;
        }
    }
    if (!found || foundDesc.fileOrIdentifier.isEmpty()) {
        foundDesc.name             = juce::String::fromUTF8([pluginName UTF8String]);
        foundDesc.pluginFormatName = fmtStr;
        foundDesc.fileOrIdentifier = idStr;
        foundDesc.uniqueId         = 0;
        foundDesc.numInputChannels  = 2;
        foundDesc.numOutputChannels = 2;
    }
    auto tree = te::ExternalPlugin::create(*_engine, foundDesc);
    return list.insertPlugin(tree, index);
}

- (NSString* _Nullable)setInstrument:(NSDictionary*)pluginInfo
                          forObjectID:(NSString*)uuid
                             stateXML:(NSString* _Nullable)stateXML {
    if (!_edit) return nil;
    std::string key([uuid UTF8String]);
    // L'instrument vit en tête de la chaîne de l'objet, c'est-à-dire sur la plugin-list de son
    // ContainerClip — le même endroit que ses FX. @see addMidiClip:withID:
    te::PluginList* pl = [self userPluginListForKey:key];
    if (!pl) {
        NSLog(@"[OBJ] setInstrument: objet MIDI '%@' introuvable", uuid);
        return nil;
    }

    // Remplace l'instrument courant (slot index 0), s'il existe.
    [self removeInstrumentForObjectID:uuid];

    auto ptr = [self insertResolvedPlugin:pluginInfo stateXML:stateXML
                                     into:*pl atIndex:0];
    if (!ptr) {
        NSLog(@"[OBJ] setInstrument: ECHEC '%@'", pluginInfo[@"name"]);
        return nil;
    }

    _instrumentMap[key] = ptr;
    NSString* pluginKey = pluginInfo[@"pluginKey"];
    std::string pk = pluginKey ? std::string([pluginKey UTF8String]) : (key + ":instr");
    _pluginMap[pk] = ptr;
    NSLog(@"[OBJ] setInstrument: %@ ← %@ (index 0)", uuid, pluginInfo[@"name"]);
    return [NSString stringWithUTF8String:pk.c_str()];
}

- (void)removeInstrumentForObjectID:(NSString*)uuid {
    std::string key([uuid UTF8String]);
    auto it = _instrumentMap.find(key);
    if (it == _instrumentMap.end()) return;
    te::Plugin::Ptr inst = it->second;

    // Ferme l'éditeur natif éventuel + retire du _pluginMap (par identité de pointeur).
    for (auto pit = _pluginMap.begin(); pit != _pluginMap.end(); ) {
        if (pit->second.get() == inst.get()) {
            [self teardownPluginLink:pit->first];
            _editorWindows.erase(pit->first);
            pit = _pluginMap.erase(pit);
        } else {
            ++pit;
        }
    }
    [self parkPlugin:*inst];   // remplacer un instrument par le même = un aller-retour de plus
    inst->deleteFromParent();
    _instrumentMap.erase(it);
}

// Ferme les fenêtres d'éditeur natives ouvertes ET purge _pluginMap pour tous les
// plugins portés par le clip/container d'id `uuid`, AVANT que son AudioProcessor
// soit détruit. Sans ça : (1) ~AudioProcessor assert activeEditor==nullptr si un
// éditeur reste ouvert (crash), (2) _pluginMap garde des Ptr détachés (fuite).
// Idempotent ; ne touche pas les enfants (les retirer séparément avant).
- (te::PluginList*)userPluginListForKey:(const std::string&)key {
    if (auto it = _clipMap.find(key); it != _clipMap.end())
        return it->second->getPluginList();      // clip audio → sa CLIP plugin-list
    if (auto it = _containerClipMap.find(key); it != _containerClipMap.end())
        return it->second->getPluginList();      // groupe, aux OU objet MIDI → son ContainerClip
    if (auto it = _stemBusMap.find(key); it != _stemBusMap.end())
        return &it->second->pluginList;          // stem → chaîne de son FolderTrack submix
    if (!_masterStemKey.empty() && key == _masterStemKey && _edit)
        return &_edit->getMasterPluginList();    // Main → chaîne de mastering
    return nullptr;
}

- (int)userInsertIndexForKey:(const std::string&)key in:(te::PluginList&)pl {
    if (auto it = _objectChainMap.find(key); it != _objectChainMap.end() && it->second.trimOut)
        return indexBefore(pl, it->second.trimOut);
    if (auto it = _faderGainMap.find(key); it != _faderGainMap.end())
        return indexBefore(pl, it->second);
    // Stem : devant le gain de bus, donc devant le VU aussi — le vu-mètre d'un stem doit
    // montrer ce qui sort du bus, FX compris.
    if (auto it = _stemGainMap.find(key); it != _stemGainMap.end())
        return indexBefore(pl, it->second);
    // Master (pas d'objet Objekat derrière) : devant l'ObjGain d'ancre, pour rester pré-VU.
    if (_masterAnchorGain && &pl == &_edit->getMasterPluginList())
        return indexBefore(pl, _masterAnchorGain);
    return pl.size();
}

// Oublie tout le bookkeeping moteur d'un objet (sans toucher aux objets Tracktion, déjà
// détruits ou sur le point de l'être par l'appelant).
- (void)forgetObjectBookkeeping:(const std::string&)key {
    _clipMap.erase(key);
    _midiClipMap.erase(key);
    _instrumentMap.erase(key);
    _containerClipMap.erase(key);
    _groupBoundsMap.erase(key);
    _groupLoopRangeMap.erase(key);
    _faderGainMap.erase(key);
    _windowFadeMap.erase(key);
    _objectChainMap.erase(key);
    _childOwnerMap.erase(key);
    _auxKeys.erase(key);
    // Les envois PARTANT de cet objet meurent avec sa chaîne : ne pas laisser de Ptr pendante.
    // (Ceux qui le VISAIENT, s'il était un aux, sont retirés par removeAux: — ici la chaîne
    // émettrice, elle, est bien vivante.)
    for (auto it = _auxSendMap.begin(); it != _auxSendMap.end(); ) {
        if (it->first.compare(0, key.size(), key) == 0 && it->first.size() > key.size()
            && it->first[key.size()] == '|')
            it = _auxSendMap.erase(it);
        else
            ++it;
    }
}

// Déclare la clé du Main et pose sur le master un ObjGain « ancre » (gain 0 dB, neutre) avant
// le LevelMeter : la chaîne user du master s'insère AVANT cet ObjGain → le VU master reste
// post-FX. Le mastering est le seul bus qui survit dans cette branche (il ne dépend d'aucun
// FolderTrack).
- (void)setMasterStemKey:(NSString*)mainStemID {
    std::string newKey([mainStemID UTF8String]);
    if (!_edit) { _masterStemKey = newKey; return; }

    // Rechargement de projet : la clé du Main change (nouvel UUID) → purge l'ancienne chaîne
    // master (plugins + éditeurs) pour ne pas la laisser orpheline dans le master.
    if (newKey != _masterStemKey && !_masterStemKey.empty()) {
        // Contrairement à un clip (dont la chaîne meurt avec lui), la plugin-list du master
        // survit : il faut retirer nous-mêmes les plugins de l'ancienne chaîne.
        std::vector<te::Plugin::Ptr> toDelete;
        if (auto it = _objectChainMap.find(_masterStemKey); it != _objectChainMap.end()) {
            for (auto& pk : it->second.pluginKeys)
                if (auto pit = _pluginMap.find(pk); pit != _pluginMap.end())
                    toDelete.push_back(pit->second);
            if (it->second.trimIn)  toDelete.push_back(it->second.trimIn);
            if (it->second.trimOut) toDelete.push_back(it->second.trimOut);
        }
        [self closeEditorsAndPurgePluginsForObjectID:
            [NSString stringWithUTF8String:_masterStemKey.c_str()]];   // résout encore sur le master
        for (auto& p : toDelete) if (p) p->deleteFromParent();
    }

    _masterStemKey = newKey;

    // Ancre = ObjGain 0 dB neutre en tête du master : la chaîne user s'insère AVANT elle → VU
    // master (ensureMasterMeter, en fin) reste post-FX. Persiste pour la durée de l'edit.
    if (!_masterAnchorGain) {
        auto& pl = _edit->getMasterPluginList();
        if (auto* existing = pl.findFirstPluginOfType<te::ObjGainPlugin>())
            _masterAnchorGain = existing;
        else
            _masterAnchorGain = pl.insertPlugin(te::ObjGainPlugin::create(), 0);
    }
}

- (void)closeEditorsAndPurgePluginsForObjectID:(NSString*)uuid {
    std::string key([uuid UTF8String]);

    // AVANT de lâcher les Ptr : mettre en consigne. Beaucoup de gestes retirent un objet pour le
    // réajouter identique dans la foulée, et sans ça chaque aller-retour recharge ses AU.
    [self parkPluginsForObjectID:uuid];

    // Chaîne linéaire : les plugins user vivent dans la plugin-list hôte, donc la boucle
    // ci-dessous les couvre déjà. On ne garde ici que l'oubli des clés de la chaîne.
    if (auto cit = _objectChainMap.find(key); cit != _objectChainMap.end()) {
        for (auto& pk : cit->second.pluginKeys) {
            [self teardownPluginLink:pk];
            _editorWindows.erase(pk);
            _pluginMap.erase(pk);
        }
        _objectChainMap.erase(cit);
    }

    te::PluginList* pl = [self userPluginListForKey:key];
    if (!pl) return;
    for (auto* p : *pl) {
        for (auto it = _pluginMap.begin(); it != _pluginMap.end(); ) {
            if (it->second.get() == p) {
                [self teardownPluginLink:it->first];  // retire les listeners (params encore vivants)
                _editorWindows.erase(it->first);   // détache l'éditeur du processor
                it = _pluginMap.erase(it);
            } else {
                ++it;
            }
        }
    }
}

// Retire un objet du moteur : on retire son CLIP (le clip audio, ou le ContainerClip d'un
// groupe / d'un aux / d'un objet MIDI — qui emporte son contenu). La piste porteuse, elle,
// reste en place pour ses voisins ; pruneEmptyPoolTracks ramasse celles qui se vident.
- (void)removeSoundObjectWithID:(NSString*)uuid {
    if (!_edit) return;
    std::string key([uuid UTF8String]);

    const bool isClip      = _clipMap.count(key) > 0;
    const bool isContainer = _containerClipMap.count(key) > 0;
    if (!isClip && !isContainer) return;

    [self closeEditorsAndPurgePluginsForObjectID:uuid];

    if (isContainer) {
        if (auto* cc = _containerClipMap[key]) cc->removeFromParent();
    } else if (isClip) {
        if (auto clip = _clipMap[key]) clip->removeFromParent();
    }

    std::string parentKey;
    if (auto ow = _childOwnerMap.find(key); ow != _childOwnerMap.end()) parentKey = ow->second;
    [self forgetObjectBookkeeping:key];
    if (!parentKey.empty()) [self refreshContainerSpanForKey:parentKey];
    [self pruneEmptyPoolTracks];
    NSLog(@"[OBJ] removeSoundObject: %@", uuid);
}

// Déplace un clip d'un ClipOwner vers un autre SANS le recréer : on ne fait que reparenter son
// ValueTree, et Tracktion retrouve l'objet dans son `clipCache` par EditItemID
// (Clip::createClipForState). Le clip, sa plugin-list et les instances AU/VST chargées — donc
// les éditeurs ouverts — survivent au déplacement. C'est ce que fait Clip::moveTo, qui ne
// gère hélas que les ClipTrack ; ici on couvre aussi le ContainerClip.
static bool moveClipToOwner(te::Clip& clip, te::ClipOwner& dest) {
    if (clip.getParent() == &dest) return true;
    if (!clip.canBeAddedTo(dest))  return false;
    te::Clip::Ptr refHolder(&clip);   // survit à la parenthèse « sans parent »
    auto* um = clip.getUndoManager();
    clip.state.getParent().removeChild(clip.state, um);
    dest.getClipOwnerState().addChild(clip.state, -1, um);
    return true;
}

// La lane d'un objet top-level a changé : RÉÉVALUE son allocation dans le pool. Sous la
// politique en vigueur (un compartiment par lane) ça le déplace de piste, comme avant ; sous
// une politique qui ignore la lane, ça ne fera rien du tout — et c'est le but du découplage.
// Sans objet pour un enfant de groupe : il vit dans le container, pas sur une piste.
- (void)setLane:(NSInteger)lane forID:(NSString*)uuid {
    if (!_edit) return;
    std::string key([uuid UTF8String]);
    if (_childOwnerMap.count(key)) return;

    te::Clip* clip = nullptr;
    if (auto cit = _containerClipMap.find(key); cit != _containerClipMap.end())
        clip = cit->second;                       // groupe/aux/objet MIDI : le container part
                                                  // avec son contenu
    else if (auto it = _clipMap.find(key); it != _clipMap.end())
        clip = it->second.get();
    if (!clip) return;

    auto* dest = [self trackForSlot:[self trackSlotForKey:key lane:(int)lane]];
    if (!dest) return;
    // Déjà au bon endroit : le parent réel du clip est la seule source de vérité — plus de
    // table « objet → lane » à tenir à jour, donc plus rien à désynchroniser.
    if (clip->getParent() == static_cast<te::ClipOwner*>(dest)) return;

    if (!moveClipToOwner(*clip, *dest)) {
        NSLog(@"[OBJ] setLane: déplacement refusé pour %@", uuid);
        return;
    }
    [self pruneEmptyPoolTracks];
}

- (void)updatePosition:(double)startTime duration:(double)duration sourceOffset:(double)sourceOffset loopEnabled:(BOOL)loopEnabled loopRangeStart:(double)loopRangeStart loopRangeEnd:(double)loopRangeEnd forID:(NSString*)uuid {
    std::string key([uuid UTF8String]);

    // Un clip MIDI vit dans _midiClipMap (et non _clipMap) mais doit être repositionné comme un
    // clip audio — sinon ses notes continuent de jouer à l'emplacement initial après un déplacement.
    te::Clip* clip = nullptr;
    bool isMidi = false;
    if (auto it = _clipMap.find(key); it != _clipMap.end()) {
        clip = it->second.get();
    } else if (auto it = _midiClipMap.find(key); it != _midiClipMap.end()) {
        clip = it->second.get();
        isMidi = true;
    }
    if (!clip) return;

    te::ClipPosition pos;
    pos.time = te::TimeRange(
        te::TimePosition::fromSeconds(startTime),
        te::TimePosition::fromSeconds(startTime + duration)
    );
    clip->setPosition(pos);
    // CONVENTION OFFSET : le modèle stocke sourceOffset en SECONDES SOURCE (point d'entrée
    // dans le fichier, invariant). Le reader Tracktion fait fichier = offsetClip × vitesse,
    // donc l'offset CLIP est en temps-clip → on divise par la vitesse. Ainsi le point d'entrée
    // fichier (= offsetClip × vitesse = sourceOffset) ne bouge JAMAIS quand la vitesse change.
    // (Sans objet pour un clip MIDI : pas de fichier source.)
    //
    // REVERSE : Tracktion ne lit pas le fichier à l'envers, il lit à l'endroit un PROXY inversé
    // (updateReversedState) — l'offset y est donc compté depuis la FIN du fichier d'origine.
    // Le modèle, lui, garde toujours sourceOffset = DÉBUT de la plage source dans le fichier
    // d'origine (@see WaveformShaping.sourceTime). La conversion est le miroir de la plage :
    //     offsetProxy = longueurSource − sourceOffset − plage jouée.
    // Sans elle, tout déplacement ou rognage d'un clip inversé republiait un offset « à
    // l'endroit » et faisait sauter le clip ailleurs dans son fichier.
    if (!isMidi) {
        const double speed = clip->getSpeedRatio();
        auto* acb = dynamic_cast<te::AudioClipBase*>(clip);
        double offsetSourceSecs = sourceOffset;
        if (acb && acb->getIsReversed()) {
            const double srcLen = acb->getSourceLength().inSeconds();   // fichier d'ORIGINE
            offsetSourceSecs = srcLen - sourceOffset - duration * speed;
        }
        offsetSourceSecs = juce::jmax(0.0, offsetSourceSecs);

        // PHASE DE BOUCLE : sous boucle, l'offset posé au clip se décale de −loopRangeStart.
        // Le repli de Tracktion (LoopReader, tracktion_WaveNode.cpp) lit
        //     position fichier = loopStart + (position brute mod longueurBoucle)
        // — il AJOUTE loopStart APRÈS le modulo mais ne le retranche pas AVANT. Avec l'offset
        // brut, un clip rogné (sourceOffset ≠ 0) démarrait donc sur `loopStart + (sourceOffset
        // mod L)` : la boucle repartait au milieu de la tranche, décalée d'une phase arbitraire
        // (mesuré : point d'entrée 0,1 s, tranche [0,1 ; 0,4] → reprises à 0,18 s au lieu de
        // 0,28). Retrancher loopStart remet la phase d'aplomb : le bord GAUCHE du clip joue le
        // point IN, et la tranche [IN,OUT] se répète ensuite. Même règle côté groupe
        // (@see refreshContainerSpanForKey:). Le clamp à 0 est la règle et non l'exception :
        // IN vit DANS le clip, donc loopRangeStart ≥ sourceOffset.
        const bool loopingClip = loopEnabled && loopRangeEnd > loopRangeStart
                              && acb && !acb->getIsReversed();
        const double offsetForRead = loopingClip
            ? juce::jmax(0.0, offsetSourceSecs - loopRangeStart) : offsetSourceSecs;
        clip->setOffset(te::TimeDuration::fromSeconds(offsetForRead / speed));

        // Boucle — le motif [loopRangeStart, loopRangeEnd] (secondes FICHIER, posées par
        // EditViewModel.clipLoopFileBounds depuis les bornes IN/OUT du modèle) se répète tant
        // que la fenêtre du clip (`duration`) le dépasse, au lieu de laisser du silence.
        // `loopStart`/`loopLength` (AudioClipBase, autoTempo=false) vivent dans les MÊMES unités
        // que `offset` ci-dessus — temps-CLIP, pré-vitesse — c'est WaveNode qui reconvertit en
        // temps-fichier en multipliant par la vitesse, exactement comme il le fait pour l'offset.
        // Donc les bornes FICHIER se convertissent en divisant par la vitesse, comme offset.
        // Exclu en reverse : `offsetSourceSecs` s'y recalcule depuis `duration`, qui devient
        // justement illimitée sous boucle — la période dégénère. `SoundObject.canLoop` l'exclut
        // déjà côté modèle ; ce garde couvre l'ordre inverse (boucle activée PUIS reverse).
        // @see [[loop-item-plan]]
        if (acb) {
            if (loopingClip) {
                const double loopStartClip = loopRangeStart / speed;
                const double loopLenClip   = (loopRangeEnd - loopRangeStart) / speed;
                acb->setLoopRange(te::TimeRange(
                    te::TimePosition::fromSeconds(loopStartClip),
                    te::TimePosition::fromSeconds(loopStartClip + loopLenClip)));
            } else {
                acb->setLoopRange(te::TimeRange());
            }
        }
    }

    // La fenêtre de fade (post-plugins) suit la position/durée du clip ; on garde les fades.
    if (auto it = _windowFadeMap.find(key); it != _windowFadeMap.end())
        if (auto* wf = dynamic_cast<te::ObjWindowFadePlugin*>(it->second.get()))
            wf->setWindow(startTime, startTime + duration, wf->fadeIn, wf->fadeOut);

    // Objet MIDI : le clip qu'on vient de bouger est l'enfant de SON PROPRE container, dont
    // l'étendue doit suivre (sans quoi le CombiningNode de la piste continuerait de l'activer
    // à l'ancienne place — et de ne pas l'activer à la nouvelle). Cet appel remonte ensuite
    // de lui-même jusqu'au groupe parent éventuel ; no-op si la clé n'a pas de container.
    [self refreshContainerSpanForKey:key];
    // L'enfant a bougé → l'étendue de son groupe suit.
    [self refreshOwnerContainerSpanFor:key];
}

- (void)updateVolume:(float)volume pan:(float)pan forID:(NSString*)uuid {
    std::string key([uuid UTF8String]);
    // Fader = l'ObjGain mémorisé de l'objet. Repère explicite : la chaîne contient aussi les
    // trims de début/fin, qui sont des ObjGain — « le premier de la liste » serait faux.
    if (auto it = _faderGainMap.find(key); it != _faderGainMap.end())
        applyGainAndPan(it->second, volume, pan);
}

// Applique gain (dB) + pan sur le fader ObjGain de l'objet (post-FX, avant la fenêtre).
static void applyGainAndPan(te::Plugin::Ptr fader, float gainDb, float pan) {
    if (auto* g = dynamic_cast<te::ObjGainPlugin*>(fader.get())) {
        g->setGainDb(gainDb);
        g->setPan(pan);
    }
}

// MARK: - Fades

- (void)updateFadeIn:(double)fadeIn fadeOut:(double)fadeOut forID:(NSString*)uuid {
    std::string key([uuid UTF8String]);
    // Tout objet a la même fin de chaîne (ObjGain puis ObjWindowFade), donc le même geste :
    // clip audio, objet MIDI, groupe et aux passent tous par ici. La fenêtre est l'étendue du
    // clip porteur — pour un container, celle que refreshContainerSpanForKey: a posée.
    te::Clip* clip = nullptr;
    if (auto it = _clipMap.find(key); it != _clipMap.end())
        clip = it->second.get();
    else if (auto it = _containerClipMap.find(key); it != _containerClipMap.end())
        clip = it->second;                       // groupe, aux ou objet MIDI
    else if (auto it = _midiClipMap.find(key); it != _midiClipMap.end())
        clip = it->second.get();
    if (!clip) return;

    const auto span = clip->getPosition().time;
    [self setWindowForKey:key
                    start:span.getStart().inSeconds()
                      end:span.getEnd().inSeconds()
                   fadeIn:fadeIn fadeOut:fadeOut];
}

// MARK: - Reverse
// (updatePitchChange: retiré — API morte : le pitch passe par le varispeed,
// updateSpeedRatio:, qui change durée ET hauteur. Cf. convention varispeed.)

- (void)updateIsReversed:(BOOL)reversed forID:(NSString*)uuid {
    std::string key([uuid UTF8String]);
    auto clipIt = _clipMap.find(key);
    if (clipIt == _clipMap.end()) return;
    // Le reverse passe par le proxy, jadis interdit dans un groupe. Cette interdiction venait
    // de la branche USE_DYNAMIC_OFFSET_CONTAINER_CLIP, abandonnée à l'étape 1 : un enfant de
    // container emprunte désormais createNodeForAudioClip comme un clip de piste.
    clipIt->second->setIsReversed(reversed ? true : false);
}

- (void)updateSpeedRatio:(double)ratio forID:(NSString*)uuid {
    std::string key([uuid UTF8String]);
    auto clipIt = _clipMap.find(key);
    if (clipIt == _clipMap.end()) return;

    auto clip = clipIt->second;
    double clamped = juce::jlimit(0.0625, 16.0, ratio);  // ±48 demi-tons (2^±4)

    // Point d'entrée fichier (secondes source) = offsetClip × vitesse. On le capture AVANT,
    // puis on repose l'offset après changement de vitesse pour le garder identique
    // (offsetClip = pointFichier / nouvelleVitesse). Sans ça, changer la vitesse déplacerait
    // l'endroit où on entre dans le sample.
    double fileEntrySourceSecs = clip->getPosition().offset.inSeconds() * clip->getSpeedRatio();
    clip->setSpeedRatio(clamped);
    clip->setOffset(te::TimeDuration::fromSeconds(fileEntrySourceSecs / clamped));
}

// MARK: - Groupes audio (ContainerClip)
//
// Un groupe = UN ContainerClip posé sur la piste de son compartiment (ou dans le container de
// son groupe parent, pour un sous-groupe : Tracktion sait imbriquer, cf createNodeForContainerClip
// qui recurse). Ses enfants sont des clips DANS le container, à leur position ABSOLUE — le
// container couvre une grande étendue avec un offset nul, donc temps local = temps edit, et
// toutes les opérations par clip (position, volume, vitesse, fades) les atteignent inchangées.
//
// La chaîne de bus du groupe (trims, FX, fader, fenêtre/fades) vit sur la plugin-list du
// ContainerClip. Gain structurel visé par l'expérience : un groupe de N enfants coûte UN clip
// sur une piste partagée, là où le modèle folder coûtait N+1 pistes.

- (void)createGroupFolder:(NSString*)groupID lane:(NSInteger)lane {
    if (!_edit) return;
    std::string key([groupID UTF8String]);
    if (_containerClipMap.count(key)) return;  // idempotent

    te::ClipOwner* owner = [self clipOwnerForKey:key lane:(int)lane];
    if (!owner) return;

    // Étendue minuscule à la création : refreshContainerSpanForKey: la recalera sur les enfants
    // au fur et à mesure qu'ils entrent. Un container vide ne produit aucun nœud de toute façon.
    te::TimeRange span(te::TimePosition::fromSeconds(0.0),
                       te::TimePosition::fromSeconds(kEmptyContainerSpanSecs));
    auto* raw = te::insertNewClip(*owner, te::TrackItem::Type::container, span);
    auto* cc  = dynamic_cast<te::ContainerClip*>(raw);
    if (!cc) { NSLog(@"[OBJ] createGroupFolder: création du container refusée (%@)", groupID); return; }

    juce::String shortID = juce::String::fromUTF8(key.c_str()).substring(0, 8);
    // ASCII uniquement : String(const char*) assert sur du non-ASCII (cf piège JUCE).
    cc->setName("Groupe " + shortID);
    // Plus d'autoTempo : il n'était exigé que par la branche USE_DYNAMIC_OFFSET_CONTAINER_CLIP.
    // ContainerClipNode lit getStartBeat/getEndBeat/getOffsetInBeats, qui sont de simples
    // conversions temps→beats de la TempoSequence (TrackItem.cpp:135-140) et ne regardent pas
    // ce drapeau. Objekat raisonne en secondes : autoTempo=false est le comportement juste.
    cc->setAutoTempo(false);

    _containerClipMap[key] = cc;

    // Chaîne de bus du groupe sur la plugin-list du container : fader PUIS ObjWindowFade, comme
    // pour un clip. Fenêtre grande ouverte en attendant que refreshContainerSpanForKey: pose
    // l'étendue réelle (l'étendue du container reste, elle, ce qui borne le CONTENU en amont).
    if (auto* pl = cc->getPluginList())
        [self installObjectChainTail:*pl forKey:key
                              volume:0.0f pan:0.0f
                              window:te::TimeRange(te::TimePosition::fromSeconds(0.0),
                                                   te::TimePosition::fromSeconds(kOpenWindowSecs))
                              fadeIn:0.0 fadeOut:0.0];

    NSLog(@"[OBJ] createGroupFolder(container): %@ lane=%ld", groupID, (long)lane);
}

// Compat : ancienne signature sans lane (lane 0 par défaut).
- (void)createGroupFolder:(NSString*)groupID {
    [self createGroupFolder:groupID lane:0];
}

- (void)assignObject:(NSString*)objectID toGroupFolder:(NSString*)groupID {
    if (!_edit) return;
    std::string gKey([groupID UTF8String]);
    auto cit = _containerClipMap.find(gKey);
    if (cit == _containerClipMap.end()) {
        NSLog(@"[OBJ] assignObject:toGroupFolder: container '%@' introuvable", groupID);
        return;
    }
    te::ContainerClip* container = cit->second;
    std::string oKey([objectID UTF8String]);

    te::Clip* clip = nullptr;
    if (auto sub = _containerClipMap.find(oKey); sub != _containerClipMap.end())
        clip = sub->second;                        // sous-groupe, aux ou objet MIDI : container
                                                   // dans container
    else if (auto it = _clipMap.find(oKey); it != _clipMap.end())
        clip = it->second.get();
    if (!clip) { NSLog(@"[OBJ] assignObject: objet '%@' introuvable", objectID); return; }

    if (!moveClipToOwner(*clip, *container)) {
        NSLog(@"[OBJ] assignObject: le container refuse '%@'", objectID);
        return;
    }
    _childOwnerMap[oKey] = gKey;
    [self refreshContainerSpanForKey:gKey];
    [self pruneEmptyPoolTracks];
    NSLog(@"[OBJ] assignObject(container): %@ → %@", objectID, groupID);
}

// Dissout le groupe : chaque membre ressort chez le propriétaire du container (la piste qui
// portait le groupe, ou le container parent si le groupe était imbriqué), puis le container
// disparaît. Les positions sont absolues des deux côtés → rien à recalculer.
- (void)disbandGroupFolder:(NSString*)groupID memberIDs:(NSArray<NSString*>*)memberIDs {
    if (!_edit) return;
    std::string key([groupID UTF8String]);
    auto cit = _containerClipMap.find(key);
    if (cit == _containerClipMap.end()) return;
    te::ContainerClip* container = cit->second;

    // Les membres ressortent LÀ OÙ ÉTAIT le container : sa piste porteuse, ou son container
    // parent. Rien à reconstituer — le propriétaire réel dit tout.
    te::ClipOwner* dest = container->getParent();
    const bool destIsContainer = (dynamic_cast<te::ContainerClip*>(dest) != nullptr);
    std::string destOwnerKey;
    if (destIsContainer)
        if (auto ow = _childOwnerMap.find(key); ow != _childOwnerMap.end()) destOwnerKey = ow->second;

    for (NSString* mid in memberIDs) {
        std::string mKey([mid UTF8String]);
        te::Clip* clip = nullptr;
        if (auto sub = _containerClipMap.find(mKey); sub != _containerClipMap.end())
            clip = sub->second;
        else if (auto it = _clipMap.find(mKey); it != _clipMap.end())
            clip = it->second.get();

        if (!clip) {                       // membre inconnu du moteur : rien à ressortir
            _childOwnerMap.erase(mKey);
            continue;
        }
        if (dest && moveClipToOwner(*clip, *dest)) {
            if (destIsContainer) _childOwnerMap[mKey] = destOwnerKey;
            else                 _childOwnerMap.erase(mKey);   // redevenu top-level
        }
    }

    [self closeEditorsAndPurgePluginsForObjectID:groupID];
    container->removeFromParent();
    const std::string parentKey = destOwnerKey;   // vidé par forgetObjectBookkeeping
    [self forgetObjectBookkeeping:key];
    // Groupe imbriqué dissous : les membres ressortent dans le container parent, dont
    // l'étendue peut changer (le groupe dissous pouvait la borner).
    if (!parentKey.empty()) [self refreshContainerSpanForKey:parentKey];
    [self pruneEmptyPoolTracks];
    NSLog(@"[OBJ] disbandGroupFolder(container): %@ (%lu membres)",
          groupID, (unsigned long)memberIDs.count);
}

- (void)removeGroupFolder:(NSString*)groupID {
    if (!_edit) return;
    std::string key([groupID UTF8String]);
    auto cit = _containerClipMap.find(key);
    if (cit == _containerClipMap.end()) return;
    [self closeEditorsAndPurgePluginsForObjectID:groupID];
    std::string parentKey;
    if (auto ow = _childOwnerMap.find(key); ow != _childOwnerMap.end()) parentKey = ow->second;
    cit->second->removeFromParent();   // descendants déjà retirés côté Swift
    [self forgetObjectBookkeeping:key];
    if (!parentKey.empty()) [self refreshContainerSpanForKey:parentKey];
    NSLog(@"[OBJ] removeGroupFolder(container): %@", groupID);
}

// Fenêtre + fondus du groupe. Deux mécanismes distincts, et il faut les deux :
//   • l'ÉTENDUE du container borne le CONTENU en amont de la chaîne (ContainerClipNode coupe
//     nativement, et c'est elle qui donne au CombiningNode de la piste sa paresse) ;
//   • l'ObjWindowFade en fin de chaîne borne la SORTIE, queue des FX de bus comprise, et pose
//     les fondus — exactement comme sur un clip. @see installObjectChainTail
// Les fondus DU CLIP sont donc remis à zéro : laissés en place, createFadeNodeForClip les
// appliquerait une seconde fois par-dessus ceux de la chaîne.
// À appeler à la création, au move/resize et au changement de fondu. Secondes edit.
- (void)updateGroupWindow:(NSString*)groupID
                    start:(double)startSecs
                      end:(double)endSecs
                   fadeIn:(double)fadeInSecs
                  fadeOut:(double)fadeOutSecs
              loopEnabled:(BOOL)loopEnabled
                loopStart:(double)loopStartSecs
                  loopEnd:(double)loopEndSecs {
    if (!_edit) return;
    std::string gKey([groupID UTF8String]);

    // Un groupe INFINI (fenêtre [0, 1e9] côté modèle, cf. EditViewModel.infiniteWindowEnd)
    // n'a pas de bornes à faire porter au container : on le laisse suivre ses enfants.
    if (endSecs >= kInfiniteWindowThresholdSecs || endSecs <= startSecs)
        _groupBoundsMap.erase(gKey);
    else
        _groupBoundsMap[gKey] = te::TimeRange(te::TimePosition::fromSeconds(startSecs),
                                              te::TimePosition::fromSeconds(endSecs));
    // Plage IN/OUT en secondes EDIT ABSOLUES (repère du container) — @see [[loop-item-plan]].
    if (loopEnabled && loopEndSecs > loopStartSecs)
        _groupLoopRangeMap[gKey] = te::TimeRange(te::TimePosition::fromSeconds(loopStartSecs),
                                                 te::TimePosition::fromSeconds(loopEndSecs));
    else
        _groupLoopRangeMap.erase(gKey);

    // AVANT de poser les fondus : c'est ce recalage qui donne au container son étendue réelle,
    // et c'est elle que la fenêtre de la chaîne doit épouser (un groupe infini n'a pas d'autres
    // bornes que celles de ses enfants).
    [self refreshContainerSpanForKey:gKey];

    auto it = _containerClipMap.find(gKey);
    if (it == _containerClipMap.end()) return;

    const auto span = it->second->getPosition().time;
    [self setWindowForKey:gKey
                    start:span.getStart().inSeconds()
                      end:span.getEnd().inSeconds()
                   fadeIn:std::max(0.0, fadeInSecs)
                  fadeOut:std::max(0.0, fadeOutSecs)];

    // Les fondus vivent dans la chaîne désormais : ceux du clip doivent rester à zéro, sans quoi
    // le FadeInOutNode du graphe les appliquerait par-dessus (fondu au carré) — et, comme il est
    // bâti avec `clearSamplesOutsideFade`, raserait aussi ce que la fenêtre laisse passer.
    it->second->setFadeIn (te::TimeDuration());
    it->second->setFadeOut(te::TimeDuration());
}

// MARK: - Bake — rendu offline
// (renderGroupToFile: synchrone retiré — API morte : tous les bakes passent par les
// variantes async sur copie d'Edit, cf. renderTrackToFileAsync ci-dessous.)

// Tous les clips d'un container, récursivement (sous-containers compris).
static void collectContainedClipIDs(te::ContainerClip& cc, std::vector<te::EditItemID>& out) {
    for (auto* c : cc.getClips()) {
        if (!c) continue;
        out.push_back(c->itemID);
        if (auto* sub = dynamic_cast<te::ContainerClip*>(c))
            collectContainedClipIDs(*sub, out);
    }
}

// Clips à autoriser au rendu pour que `key` sonne : lui-même, TOUT son contenu, et la chaîne de
// ses containers ancêtres. `allowedClips` est une liste blanche appliquée à CHAQUE niveau —
// `createNodeForContainerClip` passe les mêmes `CreateNodeParams` à `createNodeForClips`, donc
// le filtre s'applique aussi dans le container. D'où les deux sens :
//   • vers le HAUT, sans les ancêtres, le container qui porte la cible n'a pas de nœud et la
//     cible n'existe pas ;
//   • vers le BAS, sans le contenu, le container de la cible a un nœud mais plus rien dedans —
//     il rendrait le silence.
// Renvoie la liste vide pour un objet inconnu : le rendu prend alors toute la piste — repli
// large, mais aucun objet du modèle n'y tombe (tous ont un clip).
//
// Les ancêtres sortent à part (`ancestors`) : ce sont les SEULS clips que le clone doit rendre
// transparents. Contenu et ancêtres arrivaient jusqu'ici mélangés dans une liste plate, et
// `renderObjectToFileAsync` traitait « tout ce qui n'est pas la cible » en ancêtre — donc
// désactivait aussi les plugins DU CONTENU. Sur un objet MIDI (dont l'instrument est un plugin
// du container), ça coupait l'instrument : le rendu ne trouvait plus aucun audio et échouait.
- (OBJRenderChain)renderChainForKey:(const std::string&)key {
    OBJRenderChain chain;
    std::unordered_set<std::string> seen;
    std::string k = key;
    bool isTarget = true;

    while (seen.insert(k).second) {
        te::Clip* c = nullptr;
        if (auto cit = _containerClipMap.find(k); cit != _containerClipMap.end())   c = cit->second;
        else if (auto it = _clipMap.find(k); it != _clipMap.end())                  c = it->second.get();
        else if (auto mit = _midiClipMap.find(k); mit != _midiClipMap.end())        c = mit->second.get();

        if (c) {
            chain.allowed.push_back(c->itemID);
            if (!isTarget) chain.ancestors.push_back(c->itemID);
            // Le contenu ne se collecte que sous la CIBLE : sous un ancêtre, on ne veut que la
            // branche qui mène à elle — ses autres enfants sont justement ce qu'on isole.
            if (isTarget)
                if (auto* cc = dynamic_cast<te::ContainerClip*>(c))
                    collectContainedClipIDs(*cc, chain.allowed);
        }
        isTarget = false;

        auto ow = _childOwnerMap.find(k);
        if (ow == _childOwnerMap.end()) break;
        k = ow->second;
    }
    return chain;
}

// Construit le CLONE DE RENDU d'un rendu offline : flush des états, copie de l'arbre, chargement
// en rôle `forRendering` sous le filtre de plugins, puis ré-affirmation des états qu'un AU aurait
// refusés. Tout cela tourne sur le THREAD PRINCIPAL — c'est la fenêtre pendant laquelle l'UI est
// bloquée, et les quatre jalons journalisés en séparent les postes. Ces mesures restent : le clone
// est le premier suspect dès qu'un rendu rame, et sans elles le diagnostic repart de zéro.
//
// Partagé par le bake et par la capture de trace : ils rendent des choses différentes, mais ils
// partent tous deux de la même copie sous le même filtre, et c'est la partie coûteuse.
// Retourne nullptr si le chargement échoue.
- (std::unique_ptr<te::Edit>)buildRenderCloneAllowing:(const std::vector<te::EditItemID>&)allowedClipIDs
                                                track:(te::EditItemID)trackID
                                                 desc:(NSString*)desc {
    if (!_edit) return nullptr;

    const double tStart = juce::Time::getMillisecondCounterHiRes();

    // L'état binaire d'un plugin ne descend dans la ValueTree que via flushPluginStateToValueTree :
    // sans ce flush, le clone partirait du dernier état sérialisé et non de ce qu'on entend. On
    // saute les plugins qui ne rendent pas leur état — les flusher les effacerait.
    // Balayage PROFOND : les plugins des objets contenus dans un groupe sont précisément ceux
    // qu'un bake de groupe doit emporter, et te::getAllPlugins ne descend pas jusqu'à eux.
    auto livePlugins = objAllPluginsDeep(*_edit);
    int flushedCount = 0;
    for (auto* p : livePlugins)
        if (p && objCanFlushPluginState(*p)) { p->flushPluginStateToValueTree(); ++flushedCount; }
    const double tFlush = juce::Time::getMillisecondCounterHiRes();

    // Clone l'Edit en rôle forRendering (playDisabled → ne s'attache PAS au device live).
    // On opère le détach/bypass sur cette copie : le graphe live est intact.
    auto stateCopy = _edit->state.createCopy();
    const double tCopy = juce::Time::getMillisecondCounterHiRes();
    std::unique_ptr<te::Edit> clone;
    {
        // `forRendering` charge TOUS les plugins de l'Edit. On restreint le chargement à la
        // chaîne qu'on va réellement rendre : les AU des autres objets et des stems ne peuvent
        // pas entrer dans le wave (piste détachée à la racine, useMasterPlugins faux), et un AU
        // coûte des secondes à instancier sur le thread principal. @see OBJRenderPluginFilter.
        OBJRenderPluginFilter::Scope pluginFilter(allowedClipIDs, trackID);
        clone = te::loadEditFromState(*_engine, stateCopy, te::Edit::EditRole::forRendering);
    }
    const double tClone = juce::Time::getMillisecondCounterHiRes();
    if (!clone) return nullptr;

    // Le clone recrée ses plugins depuis la ValueTree → même refus de restauration que le graphe
    // live, mais sans délai d'attente possible : on force l'état AVANT de lancer le rendu, sinon
    // un AU récalcitrant serait rendu à ses réglages d'usine.
    [self forcePluginStatesForRenderClone:*clone];
    const double tForce = juce::Time::getMillisecondCounterHiRes();

    // « chargés / déclarés » mesure directement l'effet du filtre : tout AU déclaré mais non
    // chargé est une instanciation évitée sur le thread principal.
    const auto auCount = objCountExternalPlugins(*clone);
    NSLog(@"[PERF] clone de rendu « %@ » : flush %d/%d plugin(s) %.0f ms | copie d'arbre %.0f ms | "
          @"clone %.0f ms (%d/%d AU chargés) | ré-affirmation %.0f ms",
          desc, flushedCount, livePlugins.size(), tFlush - tStart, tCopy - tFlush,
          tClone - tCopy, auCount.loaded, auCount.declared, tForce - tClone);

    return clone;
}

- (void)renderTrackToFileAsync:(te::EditItemID)trackID
                      filePath:(NSString*)filePath
                         start:(double)startSecs
                           end:(double)endSecs
                 allowedClipIDs:(const std::vector<te::EditItemID>&)allowedClipIDs
                       prepare:(std::function<void(te::Track*)>)prepare
                          desc:(NSString*)desc
                    completion:(void(^)(BOOL ok))completion {
    if (!_edit) { if (completion) completion(NO); return; }

    const double tStart = juce::Time::getMillisecondCounterHiRes();
    auto clone = [self buildRenderCloneAllowing:allowedClipIDs track:trackID desc:desc];
    if (!clone) { if (completion) completion(NO); return; }

    te::Track* track = te::findTrackForID(*clone, trackID);
    if (!track) {
        NSLog(@"[OBJ] renderTrackToFileAsync: piste absente du clone (%@)", desc);
        if (completion) completion(NO);
        return;
    }

    // Détacher à la racine (sortie → device, sinon le graphe top-level skippe une piste qui
    // alimente une autre). Puis bypass spécifique (fader/fenêtre/fades) sur la copie. Pas de
    // restauration : le clone est jeté à la fin.
    clone->moveTrack(track, te::TrackInsertPoint((te::Track*)nullptr, (te::Track*)nullptr));
    if (prepare) prepare(track);

    auto allTracks = te::getAllTracks(*clone);
    juce::BigInteger tracksToDo;
    const int idx = allTracks.indexOf(track);
    if (idx >= 0) tracksToDo.setBit(idx);

    juce::Array<te::EditItemID> trackIDs;
    trackIDs.add(track->itemID);
    for (auto* t : track->getAllSubTracks(true)) trackIDs.add(t->itemID);

    // Isolation de l'objet visé : plutôt que de retirer ses voisins du clone (ce qui ne savait
    // pas descendre dans un container), on déclare les seuls clips à rendre. `findClipForID`
    // cherche récursivement, containers compris — les identifiants viennent du graphe live, les
    // pointeurs doivent venir du CLONE.
    juce::Array<te::Clip*> allowedClips;
    juce::StringArray missingIDs;
    for (auto itemID : allowedClipIDs) {
        if (auto* c = te::findClipForID(*clone, itemID)) allowedClips.add(c);
        else                                             missingIDs.add(itemID.toString());
    }

    // Un seul clip manquant suffit à faire sortir le wave muet (ou à faire échouer le rendu
    // faute d'audio) : on nomme les absents, sans quoi le diagnostic repart de zéro.
    if (!missingIDs.isEmpty()) {
        juce::String list = missingIDs.joinIntoString(", ");
        NSLog(@"[OBJ] renderTrackToFileAsync: %d/%lu clip(s) retrouvé(s) dans le clone (%@) — absents : %s",
              allowedClips.size(), (unsigned long)allowedClipIDs.size(), desc, list.toRawUTF8());
    }

    auto& dm = _engine->getDeviceManager();
    te::Renderer::Parameters r(*clone);
    r.tracksToDo         = tracksToDo;
    r.allowedClips       = allowedClips;   // vide = toute la piste
    r.destFile           = juce::File(juce::String::fromUTF8([filePath UTF8String]));
    r.audioFormat        = _engine->getAudioFileFormatManager().getWavFormat();
    r.bitDepth           = 32;  // WAV 32-bit float (headroom, lisible partout)
    r.sampleRateForAudio = dm.getSampleRate();
    r.blockSizeForAudio  = dm.getBlockSize();
    r.time               = te::TimeRange(te::TimePosition::fromSeconds(startSecs),
                                         te::TimePosition::fromSeconds(endSecs));
    r.endAllowance       = te::RenderOptions::findEndAllowance(*clone, &trackIDs,
                                                               allowedClips.isEmpty() ? nullptr : &allowedClips);
    r.usePlugins         = true;
    r.useMasterPlugins   = false;
    r.canRenderInMono    = false;

    NSString* jobKey = [[NSUUID UUID] UUIDString];
    std::string jobID([jobKey UTF8String]);
    if (completion) _renderCompletions[jobKey] = [completion copy];  // retenu côté ObjC
    juce::File outFile = r.destFile;
    __unsafe_unretained OBJEngineCore* weakSelf = self;  // l'engine vit pour toute la session

    // EditRenderer::render lance un thread dédié ; finishedCallback à la fin (succès/échec).
    // Le lambda C++ ne capture QUE des POD/objets C++ (jamais le block ObjC) ; on marshale vers
    // le main thread via juce::MessageManager::callAsync, où on récupère le block côté ObjC.
    auto handle = te::EditRenderer::render(r,
        [weakSelf, jobID, outFile](tl::expected<juce::File, std::string> res) {
            const bool ok = res.has_value() && outFile.existsAsFile();
            juce::MessageManager::callAsync([weakSelf, jobID, ok] {
                // Cette ligne DÉTRUIT le clone, donc ferme toutes
                // ses instances d'AU — sur le message thread. C'est le second blocage, celui qui
                // tombe alors que le rendu est déjà terminé.
                const double tDel = juce::Time::getMillisecondCounterHiRes();
                weakSelf->_renderJobs.erase(jobID);   // libère le clone + le handle (rendu fini)
                const double delMs = juce::Time::getMillisecondCounterHiRes() - tDel;
                if (delMs >= 1)
                    NSLog(@"[PERF] bake : clone détruit en %.0f ms (thread principal)", delMs);
                NSString* k = [NSString stringWithUTF8String:jobID.c_str()];
                void (^cb)(BOOL) = weakSelf->_renderCompletions[k];
                [weakSelf->_renderCompletions removeObjectForKey:k];
                if (cb) cb(ok ? YES : NO);
            });
        });

    if (!handle) {
        NSLog(@"[OBJ] renderTrackToFileAsync: EditRenderer::render a échoué (%@)", desc);
        [_renderCompletions removeObjectForKey:jobKey];
        if (completion) completion(NO);
        return;
    }
    _renderJobs[jobID] = OBJRenderJob{ std::move(clone), handle };
    // Total de la partie BLOQUANTE. Au-delà, le rendu tourne sur
    // son propre thread — reste la destruction du clone, journalisée dans le callback.
    NSLog(@"[PERF] bake « %@ » : %.0f ms sur le thread principal avant de rendre la main",
          desc, juce::Time::getMillisecondCounterHiRes() - tStart);
    NSLog(@"[OBJ] renderTrackToFileAsync %@ → %@ (job %s, en arrière-plan)",
          desc, filePath, jobID.c_str());
}

// Rendu offline d'UN objet posé sur une piste partagée. L'isolation est DÉCLARÉE au renderer
// (`allowedClips` : l'objet + ses containers ancêtres, cf. renderChainForKey:) et non plus
// obtenue en amputant le clone. La différence n'est pas cosmétique : la liste des clips d'une
// piste ne contient que ses clips DIRECTS, si bien que l'ancienne boucle, pour un objet vivant
// dans un groupe, retirait l'ancêtre qui le portait et rendait une piste vide — un wave
// silencieux, publié sans erreur. On ne touche plus au clone que pour ce que le renderer ne
// peut pas savoir : bypasser la queue de chaîne de l'objet (fader + fenêtre/fades, gardés live
// sur le baké) en laissant ses FX user, qui sont justement ce qu'on veut cuire.
//
// Cas du CONTAINER (groupe, aux, objet MIDI) : sa queue de chaîne se bypasse comme celle d'un
// clip — son ObjWindowFade est un plugin, `bypassTail` le désactive — mais ça ne suffit pas.
// L'étendue du ContainerClip borne aussi le CONTENU, en AMONT de la chaîne
// (ContainerClipNode::process), et aucun bypass de plugin ne l'atteint. Sans correctif le wave
// baké sortait fenêtré, alors que l'appelant garde fenêtre et fondus LIVE sur le clip baké :
// queue et pré-fenêtre perdues (le « reveal par trim » que bakeRenderRange prépare).
// On élargit donc l'étendue du container CLONÉ à la plage de rendu. L'offset suit le début
// (invariant de refreshContainerSpanForKey : temps local = temps edit, donc les enfants gardent
// leurs positions absolues). Les fondus du clip sont déjà à zéro dans le modèle vivant
// (@see updateGroupWindow:) ; on les remet à zéro par sécurité, le clone pouvant venir d'un
// projet enregistré avant cette convention. Les sous-groupes, eux, gardent leurs bornes et leurs
// fondus : ils font partie du contenu à cuire.
//
// D'où la séparation contenu / ancêtres de `renderChainForKey:` : la liste blanche du renderer
// mélange les deux (il lui faut les deux), mais le clone ne doit rendre transparents QUE les
// ancêtres. Traiter « tout ce qui n'est pas la cible » en ancêtre désactivait aussi les plugins
// du contenu — donc l'INSTRUMENT d'un objet MIDI, seul producteur d'audio du groupe qui
// l'emballe : le renderer ne trouvait plus rien à rendre et le bake échouait.
- (void)renderObjectToFileAsync:(NSString*)objectID
                       filePath:(NSString*)filePath
                          start:(double)startSecs
                            end:(double)endSecs
                           desc:(NSString*)desc
                     completion:(void(^)(BOOL ok))completion {
    std::string key([objectID UTF8String]);
    te::Clip* item = nullptr;
    if (auto cit = _containerClipMap.find(key); cit != _containerClipMap.end()) item = cit->second;
    else if (auto it = _clipMap.find(key); it != _clipMap.end())                item = it->second.get();

    te::Track* track = [self trackForKey:key];
    if (!track) {
        NSLog(@"[OBJ] renderObjectToFileAsync: piste introuvable pour %@", objectID);
        if (completion) completion(NO);
        return;
    }
    const te::EditItemID keepID = item ? item->itemID : te::EditItemID{};
    const auto chain = [self renderChainForKey:key];

    [self renderTrackToFileAsync:track->itemID
                        filePath:filePath start:startSecs end:endSecs
                  allowedClipIDs:chain.allowed
                         prepare:[ancestors = chain.ancestors, keepID, startSecs, endSecs](te::Track* t) {
                             auto* ct = dynamic_cast<te::ClipTrack*>(t);
                             if (!ct) return;
                             auto bypassTail = [](te::PluginList* pl) {
                                 if (!pl) return;
                                 for (auto* p : *pl)
                                     if (dynamic_cast<te::ObjGainPlugin*>(p)
                                         || dynamic_cast<te::ObjWindowFadePlugin*>(p))
                                         p->setEnabled(false);
                             };

                             // Ouvre l'étendue d'un container sur toute la plage de rendu et annule
                             // ses fondus : sur un ContainerClip, bornes et fondus sont de la
                             // géométrie, pas des plugins. @see l'en-tête de la méthode.
                             auto openContainer = [startSecs, endSecs](te::Clip* c) {
                                 auto* cc = dynamic_cast<te::ContainerClip*>(c);
                                 if (!cc) return;
                                 const double s = juce::jmax(0.0, startSecs);
                                 const double e = juce::jmax(s + 1.0e-3, endSecs);
                                 te::ClipPosition pos = cc->getPosition();
                                 pos.time   = te::TimeRange(te::TimePosition::fromSeconds(s),
                                                            te::TimePosition::fromSeconds(e));
                                 pos.offset = te::TimeDuration::fromSeconds(s);
                                 cc->setPosition(pos);
                                 // APRÈS le recalage : setFadeIn/Out borne à la longueur du clip.
                                 cc->setFadeIn (te::TimeDuration());
                                 cc->setFadeOut(te::TimeDuration());
                             };

                             // La CIBLE : on cuit ses FX user, on laisse sa queue de chaîne
                             // (fader, fenêtre/fades) au clip baké qui la portera live. Elle peut
                             // vivre à n'importe quelle profondeur : on la retrouve par identifiant
                             // dans le clone plutôt que dans les clips de la piste, qui ne connaît
                             // que ses clips directs.
                             if (keepID.isValid())
                                 if (auto* c = te::findClipForID(t->edit, keepID)) {
                                     bypassTail(c->getPluginList());
                                     openContainer(c);
                                 }

                             // Un ANCÊTRE n'est là que pour porter la cible : sa fenêtre la
                             // rognerait et son traitement (fader, trims, FX de bus) serait cuit
                             // dans le wave PUIS réappliqué à la lecture. On le rend transparent.
                             // Le CONTENU de la cible, lui, n'est touché en RIEN : c'est ce qu'on
                             // cuit — ses FX, l'instrument d'un objet MIDI, les bornes et fondus
                             // d'un sous-groupe en font partie.
                             for (auto ancestorID : ancestors) {
                                 auto* c = te::findClipForID(t->edit, ancestorID);
                                 if (!c || c->itemID == keepID) continue;

                                 if (auto* pl = c->getPluginList())
                                     for (auto* p : *pl)
                                         p->setEnabled(false);
                                 openContainer(c);
                             }
                         }
                            desc:desc
                      completion:completion];
}

- (void)renderGroupToFileAsync:(NSString*)groupID
                      filePath:(NSString*)filePath
                         start:(double)startSecs
                           end:(double)endSecs
                    completion:(void(^)(BOOL ok))completion {
    [self renderObjectToFileAsync:groupID filePath:filePath start:startSecs end:endSecs
                             desc:groupID completion:completion];
}

- (void)renderClipToFileAsync:(NSString*)clipID
                     filePath:(NSString*)filePath
                        start:(double)startSecs
                          end:(double)endSecs
                   completion:(void(^)(BOOL ok))completion {
    [self renderObjectToFileAsync:clipID filePath:filePath start:startSecs end:endSecs
                             desc:clipID completion:completion];
}

// MARK: - Capture de trace — la machine à états
//
// Trois idées, et tout le reste en découle :
//
//  1. UN RENDU PAR PASSE, sur un clone NEUF. Le clone neuf n'est pas une précaution de style :
//     c'est ce qui garantit un plugin réellement réinitialisé d'une passe à l'autre (instance
//     recréée), là où un `reset()` s'en remet à la bonne volonté du plugin.
//  2. DEUX SONDES autour du plugin, qui capturent x et y dans le MÊME rendu, indexées par temps
//     d'edit. C'est l'indexation qui aligne : @see OBJTraceProbePlugin, dont l'en-tête porte le
//     raisonnement complet sur la PDC.
//  3. LE PRÉ-ROLL EST UNE LATENCE. La sonde d'entrée retarde de N secondes et le DÉCLARE ; le
//     plugin démarre donc sur une ligne à retard vide — du silence numérique strict — et
//     l'engine range les échantillons à leur place tout seul.
//
// Ce qu'on ouvre sur le clone, et pourquoi. L'étendue du clip hôte est prolongée à DROITE de
// (pré-roll + queue + marge) : sans ça le nœud du clip cesse de produire des blocs à la fin de
// l'objet, et la queue — qui est précisément ce qu'on vient chercher — n'existe pas. Son
// ObjWindowFade est désactivé pour la même raison, ses ancêtres rendus transparents comme au
// bake. La sonde d'entrée referme ensuite la porte sur la région exacte : l'ouverture ne doit
// pas laisser passer de matière (un groupe en boucle qui se répète, un clip audio qui lit
// au-delà de sa fenêtre).
//
// @see docs/objekat-capture-trace.md

- (BOOL)isCapturingTrace {
    return _traceSession != nullptr;
}

- (float)traceCaptureProgress {
    if (!_traceSession) return 0.0f;
    const float within = (_traceJob && _traceJob->handle) ? _traceJob->handle->getProgress() : 0.0f;
    const float passes = (float) std::max(1, _traceSession->numPasses);
    return juce::jlimit(0.0f, 1.0f, ((float) _traceSession->passIndex + within) / passes);
}

- (void)cancelTraceCapture {
    if (!_traceSession) return;
    _traceSession->cancelled = true;
    if (_traceJob && _traceJob->handle) _traceJob->handle->cancel();
}

- (void)capturePluginTrace:(NSString*)pluginKey
                  objectID:(NSString*)objectID
               regionStart:(double)regionStart
                 regionEnd:(double)regionEnd
                   preRoll:(double)preRollSecs
                      tail:(double)tailSecs
                  filePath:(NSString*)filePath
                   options:(NSDictionary*)options
                completion:(void(^)(NSDictionary*))completion {

    // Un BLOCK et non un lambda C++ : la règle de ce fichier est de ne jamais faire capturer un
    // block ObjC par du C++, et elle vaut aussi pour ce qui n'est que du confort d'écriture.
    void (^refuse)(NSString*, NSString*) = ^(NSString* code, NSString* message) {
        NSLog(@"[TRACE] refus : %@ — %@", code, message);
        if (completion) completion(@{ @"ok": @NO, @"error": code, @"message": message });
    };

    if (!_edit)          { refuse(@"no_edit", @"no edit loaded"); return; }
    if (_traceSession)   { refuse(@"busy", @"a trace capture is already running"); return; }
    if (!pluginKey || !objectID || !filePath) { refuse(@"bad_arguments", @"missing argument"); return; }
    if (regionEnd <= regionStart) { refuse(@"empty_region", @"the region is empty"); return; }

    const std::string key([pluginKey UTF8String]);
    const std::string objKey([objectID UTF8String]);

    auto pit = _pluginMap.find(key);
    if (pit == _pluginMap.end() || pit->second == nullptr) {
        refuse(@"unknown_plugin", @"no live instance for that plugin");
        return;
    }
    te::Plugin& plugin = *pit->second;

    // Un plugin externe pas encore chargé tracerait son propre silence : la liste de ses
    // paramètres est vide, son instance audio n'existe pas, et le rendu passerait sans erreur.
    if (auto* ext = dynamic_cast<te::ExternalPlugin*>(&plugin))
        if (ext->getAudioPluginInstance() == nullptr) {
            refuse(@"plugin_not_loaded", @"the plugin instance is not loaded yet");
            return;
        }

    te::Clip* host = nullptr;
    if (auto cit = _containerClipMap.find(objKey); cit != _containerClipMap.end()) host = cit->second;
    else if (auto it = _clipMap.find(objKey); it != _clipMap.end())                 host = it->second.get();
    if (!host) { refuse(@"unknown_object", @"no clip for that object"); return; }

    te::Track* track = [self trackForKey:objKey];
    if (!track) { refuse(@"no_track", @"the object is on no track"); return; }

    auto& dm = _engine->getDeviceManager();
    const double sampleRate = dm.getSampleRate() > 0 ? dm.getSampleRate() : 48000.0;
    const int    blockSize  = dm.getBlockSize()  > 0 ? dm.getBlockSize()  : 512;

    auto session = std::make_unique<OBJTraceSession>();
    session->pluginKey    = key;
    session->objectKey    = objKey;
    session->pluginItemID = plugin.itemID;
    session->hostClipID   = host->itemID;
    session->trackID      = track->itemID;

    const auto chain = [self renderChainForKey:objKey];
    session->allowed   = chain.allowed;
    session->ancestors = chain.ancestors;

    session->regionStart = regionStart;
    session->regionEnd   = regionEnd;
    session->preRoll     = juce::jmax(0.0, preRollSecs);
    session->tail        = juce::jmax(0.0, tailSecs);
    session->sampleRate  = sampleRate;
    session->blockSize   = blockSize;

    session->regionSamples = (int64_t) std::llround((regionEnd - regionStart) * sampleRate);
    session->numSamples    = session->regionSamples
                           + (int64_t) std::llround(session->tail * sampleRate);

    if (session->numSamples <= 0) { refuse(@"empty_region", @"the region rounds to zero samples"); return; }

    if (options) {
        if (NSNumber* g = options[@"g_max"])     session->gMax     = juce::jmax(1.0, [g doubleValue]);
        if (NSNumber* x = options[@"x_min_db"])  session->xMinDbfs = [x doubleValue];
        if (NSNumber* m = options[@"merge_gap"]) session->mergeGap = (uint64_t) juce::jmax(1, [m intValue]);
    }

    session->pluginName       = plugin.getName().toStdString();
    session->pluginFormat     = plugin.getPluginType().toStdString();
    session->pluginWasBypassed = !plugin.isEnabled();
    session->hasAutomation    = objPluginHasAutomation(plugin);
    session->latencySamples   = juce::roundToInt(plugin.getLatencySeconds() * sampleRate);

    if (auto* ext = dynamic_cast<te::ExternalPlugin*>(&plugin)) {
        session->pluginIdentifier = ext->desc.createIdentifierString().toStdString();
        session->pluginFormat     = ext->desc.pluginFormatName.toStdString();
        session->pluginVersion    = ext->desc.version.toStdString();
    }

    session->destFile = juce::File(juce::String::fromUTF8([filePath UTF8String]));
    if (session->destFile.getParentDirectory().createDirectory().failed()) {
        refuse(@"no_folder", @"cannot create the trace folder");
        return;
    }

    NSLog(@"[TRACE] capture « %s » sur %s — région %.3f→%.3f s, pré-roll %.1f s, queue %.1f s, "
          @"%lld échantillons à %.0f Hz (bloc %d), latence déclarée %d échantillon(s)",
          session->pluginName.c_str(), objKey.c_str(), regionStart, regionEnd,
          session->preRoll, session->tail, (long long) session->numSamples,
          sampleRate, blockSize, session->latencySamples);

    _traceSession   = std::move(session);
    _traceCompletion = [completion copy];
    [self runTracePass];
}

// Une passe : un clone neuf, les sondes posées autour du plugin, un rendu offline.
- (void)runTracePass {
    if (!_traceSession) return;
    auto& S = *_traceSession;

    // Les tampons de CETTE passe. La passe A ne capture que la sortie : son entrée est du
    // silence qu'on vient d'imposer, la relire n'apprendrait rien.
    const bool isPassA = (S.passIndex == 2);

    auto makeBuffer = [&S]() {
        auto b = std::make_shared<te::ObjTraceCaptureBuffer>();
        b->sampleRate = S.sampleRate;
        b->startSecs  = S.regionStart;
        b->numSamples = S.numSamples;
        return b;
    };

    te::ObjTraceCaptureBufferPtr inBuffer, outBuffer;
    if (isPassA) {
        S.dFree = makeBuffer();
        outBuffer = S.dFree;
    } else if (S.passIndex == 0) {
        S.x1 = makeBuffer(); S.y1 = makeBuffer();
        inBuffer = S.x1; outBuffer = S.y1;
    } else {
        S.x2 = makeBuffer(); S.y2 = makeBuffer();
        inBuffer = S.x2; outBuffer = S.y2;
    }

    NSString* desc = [NSString stringWithFormat:@"trace %s passe %s",
                      S.pluginKey.c_str(), isPassA ? "A" : (S.passIndex == 0 ? "B1" : "B2")];

    auto clone = [self buildRenderCloneAllowing:S.allowed track:S.trackID desc:desc];
    if (!clone) { [self finishTraceCaptureWithError:@"clone failed"]; return; }

    te::Track* track = te::findTrackForID(*clone, S.trackID);
    if (!track) { [self finishTraceCaptureWithError:@"track missing from the clone"]; return; }

    clone->moveTrack(track, te::TrackInsertPoint((te::Track*)nullptr, (te::Track*)nullptr));

    // La plage de rendu, en temps NOMINAL. Le pré-roll retarde la matière d'autant : le dernier
    // échantillon de la région sort à `regionEnd + preRoll`, et sa queue court après lui. La
    // marge couvre les latences déclarées ailleurs dans la chaîne — une seconde de rendu en trop
    // ne coûte rien, une queue tronquée coûte la capture.
    const double renderStart = S.regionStart;
    const double renderEnd   = S.regionEnd + S.preRoll + S.tail
                             + (double) S.latencySamples / S.sampleRate + 1.0;

    // Ouvrir l'étendue d'un container sur toute la plage, et annuler ses fondus : sur un
    // ContainerClip, bornes et fondus sont de la géométrie et non des plugins. Même geste qu'au
    // bake (@see renderObjectToFileAsync), au décalage près : ici on n'ouvre QUE vers la droite
    // pour le clip hôte, dont le début est le repère de toute la capture.
    auto openContainerRight = [renderEnd](te::Clip* c) {
        auto* cc = dynamic_cast<te::ContainerClip*>(c);
        if (!cc) return;
        te::ClipPosition pos = cc->getPosition();
        const double s = pos.time.getStart().inSeconds();
        pos.time = te::TimeRange(te::TimePosition::fromSeconds(s),
                                 te::TimePosition::fromSeconds(juce::jmax(s + 1.0e-3, renderEnd)));
        cc->setPosition(pos);
        cc->setFadeIn (te::TimeDuration());
        cc->setFadeOut(te::TimeDuration());
    };

    te::Clip* hostClip = te::findClipForID(*clone, S.hostClipID);
    if (!hostClip) { [self finishTraceCaptureWithError:@"host clip missing from the clone"]; return; }

    // L'hôte : on prolonge son étendue à droite et on lève sa fenêtre. Son fader reste — il est
    // en aval du plugin tracé, il ne touche ni x ni y.
    {
        te::ClipPosition pos = hostClip->getPosition();
        pos.time = te::TimeRange(pos.time.getStart(),
                                 te::TimePosition::fromSeconds(
                                     juce::jmax(pos.time.getEnd().inSeconds(), renderEnd)));
        hostClip->setPosition(pos);
        openContainerRight(hostClip);

        if (auto* pl = hostClip->getPluginList())
            for (auto* p : *pl)
                if (dynamic_cast<te::ObjWindowFadePlugin*>(p))
                    p->setEnabled(false);
    }

    // Les ancêtres ne sont là que pour porter l'hôte : leur fenêtre le rognerait, leur
    // traitement s'ajouterait au signal. On les rend transparents, comme au bake.
    for (auto ancestorID : S.ancestors) {
        auto* c = te::findClipForID(*clone, ancestorID);
        if (!c || c->itemID == S.hostClipID) continue;
        if (auto* pl = c->getPluginList())
            for (auto* p : *pl) p->setEnabled(false);
        openContainerRight(c);
    }

    // Poser les sondes. L'ordre compte : la sortie D'ABORD, sinon insérer l'entrée décale
    // l'index de la cible sous nos pieds.
    te::Plugin* target = objFindPluginByItemID(*clone, S.pluginItemID);
    if (!target) { [self finishTraceCaptureWithError:@"the plugin is missing from the clone"]; return; }

    auto* hostList = hostClip->getPluginList();
    if (!hostList) { [self finishTraceCaptureWithError:@"the host carries no chain"]; return; }

    auto site = objFindPluginSite(*hostList, S.pluginItemID);
    if (!site.isValid()) { [self finishTraceCaptureWithError:@"the plugin is not in the host chain"]; return; }

    auto outProbe = site.list->insertPlugin(te::ObjTraceProbePlugin::create(), site.index + 1);
    auto inProbe  = site.list->insertPlugin(te::ObjTraceProbePlugin::create(), site.index);
    auto* out = dynamic_cast<te::ObjTraceProbePlugin*>(outProbe.get());
    auto* in  = dynamic_cast<te::ObjTraceProbePlugin*>(inProbe.get());
    if (!out || !in) { [self finishTraceCaptureWithError:@"could not insert the probes"]; return; }

    // Les deux sondes raisonnent dans la MÊME fenêtre — début de région, région + queue — ce
    // qui est très exactement ce qui les aligne : chacune indexe par le temps d'edit de la
    // matière qui la traverse, et l'engine a déjà retiré à ce temps la latence accumulée en
    // amont d'elle. @see OBJTraceProbePlugin.
    in->setWindow(S.regionStart, S.numSamples);
    out->setWindow(S.regionStart, S.numSamples);

    in->setPreRoll(S.preRoll);
    in->setGate(0, S.regionSamples);
    in->setSilencesInput(isPassA);
    if (inBuffer) in->setCapture(inBuffer);
    out->setCapture(outBuffer);

    // Un plugin bypassé rend g == 1 et d == 0 : la trace reste juste, mais ce n'est presque
    // jamais ce qu'on voulait. On le trace tel qu'il est — le clone porte son état — et on le
    // DIT dans le rapport (`plugin_was_bypassed`).

    // Le rendu. Le wave produit ne sert à rien — les sondes ont déjà tout — mais le renderer
    // veut un fichier : on lui en donne un temporaire, effacé à la fin.
    auto tempWave = juce::File::createTempFile("objtrace.wav");

    juce::Array<te::Clip*> allowedClips;
    for (auto itemID : S.allowed)
        if (auto* c = te::findClipForID(*clone, itemID)) allowedClips.add(c);

    auto allTracks = te::getAllTracks(*clone);
    juce::BigInteger tracksToDo;
    const int idx = allTracks.indexOf(track);
    if (idx >= 0) tracksToDo.setBit(idx);

    te::Renderer::Parameters r(*clone);
    r.tracksToDo         = tracksToDo;
    r.allowedClips       = allowedClips;
    r.destFile           = tempWave;
    r.audioFormat        = _engine->getAudioFileFormatManager().getWavFormat();
    r.bitDepth           = 32;
    r.sampleRateForAudio = S.sampleRate;
    r.blockSizeForAudio  = S.blockSize;
    r.time               = te::TimeRange(te::TimePosition::fromSeconds(renderStart),
                                         te::TimePosition::fromSeconds(renderEnd));
    r.endAllowance       = te::TimeDuration();
    r.usePlugins         = true;
    r.useMasterPlugins   = false;
    r.canRenderInMono    = false;
    r.trimSilenceAtEnds  = false;
    // La passe A rend, par construction, un fichier qui peut être parfaitement muet : c'est même
    // le cas NORMAL, celui d'un plugin qui répond du silence au silence. Sans ce faux, le
    // renderer refuserait de rendre « une Edit qui ne produit pas d'audio » et la passe qui
    // détecte `multiplicative_only` échouerait précisément quand elle a raison.
    r.checkNodesForAudio = false;

    __unsafe_unretained OBJEngineCore* weakSelf = self;   // l'engine vit pour toute la session
    auto handle = te::EditRenderer::render(r,
        [weakSelf, tempWave](tl::expected<juce::File, std::string> res) {
            const bool ok = res.has_value();
            juce::MessageManager::callAsync([weakSelf, tempWave, ok] {
                tempWave.deleteFile();
                [weakSelf tracePassFinished:(ok ? YES : NO)];
            });
        });

    if (!handle) { [self finishTraceCaptureWithError:@"the render could not be started"]; return; }

    _traceJob = std::make_unique<OBJRenderJob>(OBJRenderJob{ std::move(clone), handle });
}

- (void)tracePassFinished:(BOOL)ok {
    if (!_traceSession) return;
    auto& S = *_traceSession;

    // Le clone (et ses instances d'AU) meurt ici, sur le thread principal — le seul endroit où
    // fermer un AU soit légal.
    _traceJob.reset();

    if (S.cancelled) { [self finishTraceCaptureWithError:@"cancelled"]; return; }
    if (!ok)         { [self finishTraceCaptureWithError:@"a render pass failed"]; return; }

    // Après la seconde passe B : le null test, qui décide de la suite. C'est lui, et pas la
    // capture, qui dit s'il faut faire la passe A — d'où son rang. @see la spec.
    if (S.passIndex == 1) {
        const int channels = juce::jmin(S.x1 ? S.x1->numChannels.load() : 0,
                                        S.y1 ? S.y1->numChannels.load() : 0);
        if (channels <= 0) { [self finishTraceCaptureWithError:@"the capture is empty"]; return; }

        for (int c = 0; c < channels; ++c) {
            const auto* y1 = S.y1->read(c); const auto* y2 = S.y2->read(c);
            const auto* x1 = S.x1->read(c); const auto* x2 = S.x2->read(c);
            if (y1 && y2) S.determinismY = objWorstResidual(S.determinismY,
                              objtrace::nullTest(y1, y2, (size_t) S.numSamples));
            if (x1 && x2) S.determinismX = objWorstResidual(S.determinismX,
                              objtrace::nullTest(x1, x2, (size_t) S.numSamples));
        }

        S.nonDeterministic = !S.determinismY.isExact();

        NSLog(@"[TRACE] null test — y : crête %.1f dBFS / RMS %.1f dBFS · x : crête %.1f dBFS. "
              @"Mode %s.",
              S.determinismY.peakDbfs, S.determinismY.rmsDbfs, S.determinismX.peakDbfs,
              S.nonDeterministic ? "NON DÉTERMINISTE (pas de passe A)" : "déterministe");

        // Les secondes captures ne servaient qu'au null test : autant de mémoire rendue tout de
        // suite plutôt qu'à la fin (elles pèsent autant que celles qu'on garde).
        S.x2.reset(); S.y2.reset();

        if (S.nonDeterministic) {
            // PAS de passe A, et rien à soustraire : la réalisation captée sur du silence serait
            // un AUTRE tirage que celle de la passe B, et la soustraire AJOUTERAIT une seconde
            // source de bruit au lieu d'en retirer une. Le bruit reste dans le numérateur et se
            // fige dans g — c'est le but. @see la spec, « mode non déterministe ».
            S.numPasses = 2;
            [self finishTraceCaptureWithError:nil];
            return;
        }
    }

    ++S.passIndex;

    if (S.passIndex >= S.numPasses) { [self finishTraceCaptureWithError:nil]; return; }

    [self runTracePass];
}

// Fin de capture : le calcul, l'écriture, la validation, le rapport. `errorMessage` non nil =
// on s'arrête là et on le dit ; nil = les passes ont abouti et il reste à en faire une trace.
- (void)finishTraceCaptureWithError:(NSString*)errorMessage {
    if (!_traceSession) return;

    // Sortir la session et le completion des ivars AVANT d'appeler quoi que ce soit : le
    // completion a parfaitement le droit de relancer une capture, et il la trouverait « déjà en
    // cours » si l'état vivait encore ici.
    auto session = std::move(_traceSession);
    void (^completion)(NSDictionary*) = _traceCompletion;
    _traceSession.reset();
    _traceJob.reset();
    _traceCompletion = nil;

    auto& S = *session;

    void (^answer)(NSDictionary*) = ^(NSDictionary* report) {
        if (completion) completion(report);
    };

    if (errorMessage != nil) {
        NSLog(@"[TRACE] abandon : %@", errorMessage);
        answer(@{ @"ok": @NO,
                  @"error": [errorMessage isEqualToString:@"cancelled"] ? @"cancelled" : @"capture_failed",
                  @"message": errorMessage });
        return;
    }

    const int64_t N = S.numSamples;
    const int channels = juce::jmin(S.x1 ? S.x1->numChannels.load() : 0,
                                    S.y1 ? S.y1->numChannels.load() : 0);
    if (channels <= 0 || N <= 0) {
        answer(@{ @"ok": @NO, @"error": @"empty_capture",
                  @"message": @"the probes captured nothing — the object may not sound over that region" });
        return;
    }

    if ((S.x1 && S.x1->allocationFailed.load()) || (S.y1 && S.y1->allocationFailed.load())) {
        answer(@{ @"ok": @NO, @"error": @"too_large",
                  @"message": @"the region is too long to capture in one go" });
        return;
    }

    // Mode déterministe : la passe A a tourné et `d_free` est un SIGNAL complet — offset,
    // ronflement, dérive lente, bruit de fond — sur toute la longueur, région ET queue. Mode non
    // déterministe : elle n'a pas tourné, et il n'y a rien à soustraire. @see la spec.
    const bool hasFree = !S.nonDeterministic && S.dFree != nullptr
                       && S.dFree->numChannels.load() >= channels;

    const double xMin = std::pow(10.0, S.xMinDbfs / 20.0);

    std::vector<objtrace::Signal> gSignals, dSignals;
    gSignals.reserve((size_t) channels);
    dSignals.reserve((size_t) channels);

    for (int c = 0; c < channels; ++c) {
        std::vector<double> gFlat, dFlat;
        objtrace::computeChannel(S.y1->read(c), S.x1->read(c),
                                 hasFree ? S.dFree->read(c) : nullptr,
                                 (uint64_t) N, S.gMax, xMin, gFlat, dFlat);

        gSignals.push_back(objtrace::encodeSignal(gFlat, 1.0, S.mergeGap));
        dSignals.push_back(objtrace::encodeSignal(dFlat, 0.0, S.mergeGap));
        // gFlat/dFlat meurent ici : 16 octets par échantillon et par canal, on ne les garde pas
        // tous en vie pour rien. La détection de `linked` compare les signaux ENCODÉS.
    }

    objtrace::Trace trace;
    auto& H = trace.header;

    H.multiplicativeOnly = std::all_of(dSignals.begin(), dSignals.end(),
                                       [](const objtrace::Signal& s) { return s.isConstant(); });

    H.linked = channels > 1;
    for (int c = 1; c < channels && H.linked; ++c) {
        if (!objTraceSignalsEqual(gSignals[(size_t) c], gSignals[0])) H.linked = false;
        if (!H.multiplicativeOnly && !objTraceSignalsEqual(dSignals[(size_t) c], dSignals[0]))
            H.linked = false;
    }

    H.slotID           = S.pluginKey;
    H.pluginName       = S.pluginName;
    H.pluginIdentifier = S.pluginIdentifier;
    H.pluginFormat     = S.pluginFormat;
    H.pluginVersion    = S.pluginVersion;

    H.sampleRate     = S.sampleRate;
    H.numChannels    = channels;
    H.storedChannels = H.linked ? 1 : channels;
    H.blockSize      = S.blockSize;

    H.regionStart    = S.regionStart;
    H.regionEnd      = S.regionEnd;
    H.tailSeconds    = S.tail;
    H.preRollSeconds = S.preRoll;
    H.numSamples     = (uint64_t) N;

    H.latencySamples = S.latencySamples;
    H.gMax           = S.gMax;
    H.xMinDbfs       = S.xMinDbfs;
    H.mergeGap       = S.mergeGap;

    H.nonDeterministic  = S.nonDeterministic;
    H.pluginWasBypassed = S.pluginWasBypassed;
    H.hasAutomation     = S.hasAutomation;
    H.determinismY      = S.determinismY;
    H.determinismX      = S.determinismX;
    H.capturedAt        = juce::Time::getCurrentTime().toMilliseconds() / 1000.0;

    // L'alignement, mesuré. Ce qu'il attrape n'est PAS ce qu'on croit : le modèle affine est
    // exact quel que soit le décalage, puisque g et d sont résolus sur le MÊME couple
    // (x[n], y[n]). Un décalage ne casse donc pas la reconstruction, il casse la QUALITÉ de la
    // trace — g cesse d'être proche de 1, le clamp verse tout dans d, l'encodage par plages ne
    // trouve plus rien à comprimer et le fichier enfle. D'où : on mesure, on consigne, on le
    // dit dans le rapport ; on ne refuse pas. @see objtrace::correlationLag.
    H.correlationLagSamples = objtrace::correlationLag(S.x1->read(0), S.y1->read(0), (uint64_t) N);
    H.fractionalLatency = std::abs(H.correlationLagSamples
                                   - std::round(H.correlationLagSamples)) > 0.05;

    // L'empreinte de x, pour l'invalidation. ABSENTE quand le null test sur x a échoué : il n'y
    // a alors pas d'entrée stable dont prendre l'empreinte, et la péremption ne peut plus se
    // détecter. Mieux vaut ne rien promettre que promettre à faux.
    if (S.determinismX.isExact()) {
        std::vector<const float*> xChannels;
        for (int c = 0; c < channels; ++c) xChannels.push_back(S.x1->read(c));
        H.inputHash = objtrace::fingerprint(xChannels.data(), channels, (uint64_t) N);
    }

    trace.g.assign(gSignals.begin(), gSignals.begin() + H.storedChannels);
    if (!H.multiplicativeOnly)
        trace.d.assign(dSignals.begin(), dSignals.begin() + H.storedChannels);

    // VALIDATION — reconstruire, soustraire, mesurer. Elle porte sur les signaux DÉCODÉS : c'est
    // le codec par plages qu'elle éprouve, en plus de l'arithmétique. Canal par canal, chaque
    // décodage relâché avant le suivant.
    objtrace::Residual validation;
    for (int c = 0; c < channels; ++c) {
        const int stored = juce::jmin(c, H.storedChannels - 1);
        const auto g = objtrace::decodeSignal(trace.g[(size_t) stored], (uint64_t) N);
        const auto d = H.multiplicativeOnly
                         ? std::vector<double>((size_t) N, 0.0)
                         : objtrace::decodeSignal(trace.d[(size_t) stored], (uint64_t) N);

        const float* x = S.x1->read(c);
        const float* y = S.y1->read(c);
        double peak = 0.0, sumSquares = 0.0;

        for (int64_t n = 0; n < N; ++n) {
            const double diff = g[(size_t) n] * (double) x[n] + d[(size_t) n] - (double) y[n];
            peak = std::max(peak, std::abs(diff));
            sumSquares += diff * diff;
        }

        objtrace::Residual here;
        here.peakDbfs = objtrace::toDbfs(peak);
        here.rmsDbfs  = objtrace::toDbfs(std::sqrt(sumSquares / (double) N));
        validation = objWorstResidual(validation, here);
    }
    H.validation = validation;

    // Écriture, puis relecture : la relecture n'est pas de la coquetterie, c'est la seule chose
    // qui éprouve le format sur le disque. Une trace qu'on ne sait pas relire ne vaut rien, et
    // le moment de s'en apercevoir est maintenant.
    if (!objtrace::writeToFile(trace, S.destFile)) {
        answer(@{ @"ok": @NO, @"error": @"write_failed",
                  @"message": @"could not write the trace file" });
        return;
    }

    objtrace::Trace reread;
    if (!objtrace::readFromFile(S.destFile, reread)) {
        S.destFile.deleteFile();
        answer(@{ @"ok": @NO, @"error": @"reread_failed",
                  @"message": @"the trace was written but cannot be read back" });
        return;
    }

    for (size_t c = 0; c < trace.g.size(); ++c) {
        const bool same = c < reread.g.size()
                       && objTraceSignalsEqual(trace.g[c], reread.g[c])
                       && (H.multiplicativeOnly
                           || (c < reread.d.size() && objTraceSignalsEqual(trace.d[c], reread.d[c])));
        if (!same) {
            S.destFile.deleteFile();
            answer(@{ @"ok": @NO, @"error": @"reread_mismatch",
                      @"message": @"the trace does not read back identical to what was written" });
            return;
        }
    }

    // Ce que l'encodage par plages a effectivement épargné. `flat` est ce qu'aurait coûté un
    // float64 à taux plein pour les mêmes signaux — le chiffre que la spec veut voir baisser.
    const int64_t fileBytes = S.destFile.getSize();
    const int64_t flatBytes = (int64_t) H.storedChannels * (int64_t) N * 8
                            * (H.multiplicativeOnly ? 1 : 2);

    const juce::String destPath = S.destFile.getFullPathName();   // local nommé → toRawUTF8 sûr
    NSString* tracePath = [NSString stringWithUTF8String:destPath.toRawUTF8()];

    NSString* status = H.validation.isExact()      ? @"exact"
                     : H.validation.isAcceptable() ? @"acceptable"
                                                   : @"problem";

    NSLog(@"[TRACE] « %s » : %d canal(aux), %lld échantillons, %s%s%s — validation crête "
          @"%.1f dBFS (%@) — %lld octets au lieu de %lld (%.1f %%) — décalage mesuré %.2f "
          @"échantillon(s)%s",
          H.pluginName.c_str(), channels, (long long) N,
          H.nonDeterministic ? "NON DÉTERMINISTE, " : "",
          H.multiplicativeOnly ? "multiplicatif seul" : "avec terme additif",
          H.linked ? ", canaux liés" : "",
          H.validation.peakDbfs, status,
          (long long) fileBytes, (long long) flatBytes,
          flatBytes > 0 ? 100.0 * (double) fileBytes / (double) flatBytes : 0.0,
          H.correlationLagSamples, H.fractionalLatency ? " (FRACTIONNAIRE)" : "");

    answer(@{
        @"ok":                   @YES,
        @"path":                 tracePath,
        @"status":               status,
        @"plugin":               [NSString stringWithUTF8String:H.pluginName.c_str()],
        @"sample_rate":          @(H.sampleRate),
        @"block_size":           @(H.blockSize),
        @"num_channels":         @(H.numChannels),
        @"stored_channels":      @(H.storedChannels),
        @"num_samples":          @((long long) H.numSamples),
        @"region_start":         @(H.regionStart),
        @"region_end":           @(H.regionEnd),
        @"pre_roll_seconds":     @(H.preRollSeconds),
        @"tail_seconds":         @(H.tailSeconds),
        @"latency_samples":      @(H.latencySamples),
        @"correlation_lag":      @(H.correlationLagSamples),
        @"fractional_latency":   @(H.fractionalLatency),
        @"multiplicative_only":  @(H.multiplicativeOnly),
        @"linked":               @(H.linked),
        @"non_deterministic":    @(H.nonDeterministic),
        @"plugin_was_bypassed":  @(H.pluginWasBypassed),
        @"has_automation":       @(H.hasAutomation),
        @"determinism_y_peak_db": @(H.determinismY.peakDbfs),
        @"determinism_y_rms_db":  @(H.determinismY.rmsDbfs),
        @"determinism_x_peak_db": @(H.determinismX.peakDbfs),
        @"validation_peak_db":    @(H.validation.peakDbfs),
        @"validation_rms_db":     @(H.validation.rmsDbfs),
        @"input_hash":            [NSString stringWithUTF8String:H.inputHash.c_str()],
        @"file_bytes":            @((long long) fileBytes),
        @"flat_bytes":            @((long long) flatBytes),
    });
}

// L'en-tête d'une trace posée sur le disque, sans rien charger de ses données. Sert au modèle
// Swift à afficher l'état d'un slot `traced` et à vérifier sa péremption.
- (NSDictionary*)readTraceHeader:(NSString*)filePath {
    if (!filePath) return nil;

    objtrace::Trace t;
    juce::File f(juce::String::fromUTF8([filePath UTF8String]));
    if (!objtrace::readFromFile(f, t)) return nil;

    const auto& H = t.header;
    return @{
        @"path":                 filePath,
        @"plugin":               [NSString stringWithUTF8String:H.pluginName.c_str()],
        @"plugin_identifier":    [NSString stringWithUTF8String:H.pluginIdentifier.c_str()],
        @"plugin_format":        [NSString stringWithUTF8String:H.pluginFormat.c_str()],
        @"sample_rate":          @(H.sampleRate),
        @"num_channels":         @(H.numChannels),
        @"stored_channels":      @(H.storedChannels),
        @"num_samples":          @((long long) H.numSamples),
        @"region_start":         @(H.regionStart),
        @"region_end":           @(H.regionEnd),
        @"tail_seconds":         @(H.tailSeconds),
        @"pre_roll_seconds":     @(H.preRollSeconds),
        @"latency_samples":      @(H.latencySamples),
        @"correlation_lag":      @(H.correlationLagSamples),
        @"fractional_latency":   @(H.fractionalLatency),
        @"multiplicative_only":  @(H.multiplicativeOnly),
        @"linked":               @(H.linked),
        @"non_deterministic":    @(H.nonDeterministic),
        @"has_automation":       @(H.hasAutomation),
        @"validation_peak_db":   @(H.validation.peakDbfs),
        @"validation_rms_db":    @(H.validation.rmsDbfs),
        @"input_hash":           [NSString stringWithUTF8String:H.inputHash.c_str()],
        @"captured_at":          @(H.capturedAt),
    };
}

// MARK: - Export — rendu du mix complet
//
// Sans aucune des restrictions du bake : ni `tracksToDo` (vide = toutes les pistes), ni
// `allowedClips`, ni filtre de plugins. C'est la sortie générale telle qu'on l'entend, chaîne de
// mastering et fader master inclus (`useMasterPlugins`).
//
// Deux régimes (@see OBJEngineCore.h, où l'arbitrage est expliqué) :
//
//   • SUR COPIE — même ossature qu'un bake : flush des états → copie de l'arbre → clone en rôle
//     forRendering → ré-affirmation des états. L'app reste pleinement utilisable pendant le
//     rendu, mais le clone instancie TOUS les AU du projet sur le thread principal. Le bake s'en
//     tire en ne chargeant que sa chaîne (@see OBJRenderPluginFilter) ; un export ne le peut pas.
//     Les jalons [PERF] disent où part ce temps d'attente.
//
//   • DIRECT — on rend l'Edit vivant. Rien à cloner, rien à instancier, rien à flusher : les
//     plugins qui vont rendre sont exactement ceux qu'on entend, avec leur état courant. Le
//     démarrage est immédiat. On arrête le transport et on déinitialise les plugins avant
//     (comme le fait Renderer::renderToFile pour ses rendus sur Edit vivant), puis on rend la
//     lecture au projet une fois le rendu fini.
- (void)exportMixToFileAsync:(NSString*)filePath
                       start:(double)startSecs
                         end:(double)endSecs
                  sampleRate:(double)sampleRate
                    bitDepth:(NSInteger)bitDepth
                   dithering:(BOOL)dithering
                  onEditCopy:(BOOL)onEditCopy
                  completion:(void(^)(BOOL ok, NSString* _Nullable errorMessage))completion {
    if (!_edit) { if (completion) completion(NO, @"Aucun projet chargé."); return; }
    if (!_exportJobID.empty()) {
        if (completion) completion(NO, @"Un export est déjà en cours.");
        return;
    }
    if (endSecs <= startSecs) {
        if (completion) completion(NO, @"La sélection temporelle est vide.");
        return;
    }

    const double tStart = juce::Time::getMillisecondCounterHiRes();

    // Edit à rendre : le clone en régime « sur copie », l'Edit vivant en régime direct.
    std::unique_ptr<te::Edit> clone;
    te::Edit* renderEdit = _edit.get();

    if (onEditCopy) {
        // OPTIMISATION À FAIRE — ne charger que ce que la fenêtre IN-OUT fait sonner.
        //
        // Le clone instancie TOUS les AU déclarés dans l'arbre, y compris ceux de clips situés
        // hors de [startSecs, endSecs] : la plage borne ce qu'on REND, pas ce qu'on CHARGE.
        // Exporter huit secondes d'une session longue coûte donc le chargement complet.
        //
        // Le mécanisme existe déjà : OBJRenderPluginFilter (en tête de ce fichier) est consulté
        // par shouldLoadPlugin pendant le clonage, et c'est ainsi que les bakes ne chargent que
        // la chaîne d'un objet. Il resterait à en dériver l'ensemble des clips qui chevauchent
        // la fenêtre — en tenant compte des groupes (un enfant qui déborde la fenêtre de son
        // parent est déjà muet) et des objets liés — et à toujours autoriser, sans exception,
        // les chaînes de stems, d'aux et de master.
        //
        // Deux raisons de ne pas l'avoir fait tout de suite : un export MUET est plus grave
        // qu'un export lent (se tromper d'ensemble = un plugin manquant, silencieusement, et un
        // rendu qui diffère de ce qu'on entend), et le gain dépend entièrement du projet — là où
        // les mêmes AU tournent d'un bout à l'autre, le filtre n'écarterait presque rien. À
        // tenter en filtrant large, avec un [PERF] comptant les AU écartés : c'est ce chiffre,
        // sur de vraies sessions, qui dira si ça vaut la complexité.
        //
        // Sans objet dans l'autre régime : le rendu direct ne charge rien du tout.

        // Sans ce flush, le clone partirait du dernier état SÉRIALISÉ des plugins et non de ce
        // qu'on entend — un réglage touché depuis l'ouverture du projet ne serait pas dans le
        // fichier exporté. @see renderTrackToFileAsync, même précaution.
        auto livePlugins = objAllPluginsDeep(*_edit);
        int flushedCount = 0;
        for (auto* p : livePlugins)
            if (p && objCanFlushPluginState(*p)) { p->flushPluginStateToValueTree(); ++flushedCount; }
        const double tFlush = juce::Time::getMillisecondCounterHiRes();

        auto stateCopy = _edit->state.createCopy();
        const double tCopy = juce::Time::getMillisecondCounterHiRes();
        // Pas de OBJRenderPluginFilter::Scope ici : tout le projet doit sonner.
        clone = te::loadEditFromState(*_engine, stateCopy, te::Edit::EditRole::forRendering);
        const double tClone = juce::Time::getMillisecondCounterHiRes();
        if (!clone) { if (completion) completion(NO, @"Copie du projet impossible."); return; }

        [self forcePluginStatesForRenderClone:*clone];
        const double tForce = juce::Time::getMillisecondCounterHiRes();

        const auto auCount = objCountExternalPlugins(*clone);
        NSLog(@"[PERF] export : flush %d/%d plugin(s) %.0f ms | copie d'arbre %.0f ms | "
              @"clone %.0f ms (%d/%d AU chargés) | ré-affirmation %.0f ms",
              flushedCount, livePlugins.size(), tFlush - tStart, tCopy - tFlush,
              tClone - tCopy, auCount.loaded, auCount.declared, tForce - tClone);

        renderEdit = clone.get();
    } else {
        // Rendu direct. Le graphe de rendu va s'emparer des plugins vivants : on arrête d'abord
        // le transport, puis on déinitialise les plugins pour qu'ils soient repréparés à la
        // fréquence et à la taille de bloc du rendu (c'est la séquence de
        // Renderer::renderToFile). EditRenderer, lui, retirera l'Edit du device manager
        // (Edit::ScopedRenderStatus) — la lecture est rendue au projet dans le completion.
        _edit->getTransport().stop(false, false);
        te::Renderer::turnOffAllPlugins(*_edit);
        NSLog(@"[PERF] export direct : transport arrêté et plugins déinitialisés en %.0f ms "
              @"(pas de clone, pas d'instanciation)",
              juce::Time::getMillisecondCounterHiRes() - tStart);
    }

    auto& dm = _engine->getDeviceManager();
    te::Renderer::Parameters r(*renderEdit);
    // tracksToDo et allowedClips laissés VIDES : le renderer prend alors tout (@see
    // render_utils::createRenderTask, `allowedTracks = tracksToDo.isZero() ? nullptr : …`).
    r.destFile           = juce::File(juce::String::fromUTF8([filePath UTF8String]));
    r.audioFormat        = _engine->getAudioFileFormatManager().getWavFormat();
    r.bitDepth           = (int)bitDepth;
    r.sampleRateForAudio = sampleRate > 0 ? sampleRate : dm.getSampleRate();
    r.blockSizeForAudio  = dm.getBlockSize();
    r.time               = te::TimeRange(te::TimePosition::fromSeconds(startSecs),
                                         te::TimePosition::fromSeconds(endSecs));
    // Pas d'endAllowance : la fenêtre demandée est celle qu'on écrit, à la milliseconde près.
    // (C'est le sens de la remarque de Tracktion sur ce champ — utile aux freezes, pas aux
    // exports, où l'utilisateur a choisi ses bornes.)
    r.usePlugins         = true;
    r.useMasterPlugins   = true;   // chaîne de mastering + fader master
    r.canRenderInMono    = false;  // stéréo garantie, même si le mix est mono
    // Choix de l'appelant, pas déduction de la profondeur. En 32 bits flottant le renderer
    // n'écrit rien à quantifier : le drapeau est alors sans objet quoi qu'on demande.
    r.ditheringEnabled   = dithering;

    NSString* jobKey = [[NSUUID UUID] UUIDString];
    std::string jobID([jobKey UTF8String]);
    if (completion) _exportCompletions[jobKey] = [completion copy];
    juce::File outFile = r.destFile;
    __unsafe_unretained OBJEngineCore* weakSelf = self;

    const bool direct = !onEditCopy;
    auto handle = te::EditRenderer::render(r,
        [weakSelf, jobID, outFile, direct](tl::expected<juce::File, std::string> res) {
            const bool ok = res.has_value() && outFile.existsAsFile();
            std::string err = res.has_value() ? std::string() : res.error();
            juce::MessageManager::callAsync([weakSelf, jobID, ok, err, direct] {
                // Détruit le clone (donc ferme tous ses AU) sur le message thread, comme pour
                // les bakes : c'est le second temps d'attente, celui d'après le rendu.
                //
                // En rendu direct il n'y a pas de clone à détruire, mais cet effacement compte
                // quand même : le destructeur du Handle JOINT le thread de rendu, donc à son
                // retour l'Edit::ScopedRenderStatus du renderer est défait et l'Edit n'est plus
                // « en rendu ». C'est la condition pour que ensureContextAllocated ci-dessous
                // fasse quelque chose (il ne fait rien tant que Edit::isRendering()).
                const double tDel = juce::Time::getMillisecondCounterHiRes();
                weakSelf->_renderJobs.erase(jobID);
                const double delMs = juce::Time::getMillisecondCounterHiRes() - tDel;
                if (delMs >= 1)
                    NSLog(@"[PERF] export : clone détruit en %.0f ms (thread principal)", delMs);
                if (weakSelf->_exportJobID == jobID) weakSelf->_exportJobID.clear();

                // Rendu direct : on rend sa lecture au projet. Les plugins sortent du graphe de
                // rendu préparés pour LUI (fréquence, taille de bloc) — on les déinitialise pour
                // que la réallocation les reprépare aux réglages de la carte son.
                if (direct && weakSelf->_edit) {
                    te::Renderer::turnOffAllPlugins(*weakSelf->_edit);
                    weakSelf->_edit->getTransport().ensureContextAllocated();
                }
                NSString* k = [NSString stringWithUTF8String:jobID.c_str()];
                void (^cb)(BOOL, NSString*) = weakSelf->_exportCompletions[k];
                [weakSelf->_exportCompletions removeObjectForKey:k];
                if (cb) cb(ok ? YES : NO,
                           ok ? nil : [NSString stringWithUTF8String:err.c_str()]);
            });
        });

    if (!handle) {
        NSLog(@"[OBJ] exportMixToFileAsync: EditRenderer::render a échoué");
        [_exportCompletions removeObjectForKey:jobKey];
        // En direct, le transport a déjà été arrêté et les plugins déinitialisés : on remet le
        // projet en état de jouer avant de rendre la main sur l'échec.
        if (direct && _edit) _edit->getTransport().ensureContextAllocated();
        if (completion) completion(NO, @"Le moteur n'a pas pu préparer le rendu.");
        return;
    }
    _renderJobs[jobID] = OBJRenderJob{ std::move(clone), handle };   // clone nul en direct
    _exportJobID = jobID;
    NSLog(@"[PERF] export : %.0f ms sur le thread principal avant de rendre la main",
          juce::Time::getMillisecondCounterHiRes() - tStart);
    NSLog(@"[OBJ] export %@ [%.2f s → %.2f s] %.0f Hz / %ld bits%s (job %s, %s)",
          filePath, startSecs, endSecs, sampleRate, (long)bitDepth,
          dithering ? " + dithering" : "", jobID.c_str(),
          onEditCopy ? "sur copie" : "direct");
}

- (float)exportProgress {
    if (_exportJobID.empty()) return 0.0f;
    auto it = _renderJobs.find(_exportJobID);
    if (it == _renderJobs.end() || !it->second.handle) return 0.0f;
    return it->second.handle->getProgress();
}

- (BOOL)isExporting { return !_exportJobID.empty(); }

- (void)cancelExport {
    if (_exportJobID.empty()) return;
    auto it = _renderJobs.find(_exportJobID);
    if (it != _renderJobs.end() && it->second.handle) it->second.handle->cancel();
    // Ni effacement du job ni appel de completion ici : le thread de rendu voit le drapeau,
    // s'arrête et appelle le callback avec « Cancelled » — c'est là que tout se nettoie.
}

// MARK: - AUX et sends — internes à un ContainerClip
//
// Un aux est un ContainerClip marqué `objAuxBus`, enfant du même container que ses émetteurs.
// Il ne joue pas de contenu : le graphe le sort des enfants avant de bâtir leur CombiningNode,
// et lui substitue un ObjAuxReturnNode qui somme les taps des envois, suivi de la chaîne de FX
// de l'aux et de ses fades. Le tout est sommé avec la sortie sèche du container.
//
// D'où la PORTÉE dans un container, et elle n'est pas négociable : émetteur et aux doivent être
// enfants DIRECTS du même container. Un container est une frontière de graphe (getDirectInputNodes
// et getInternalNodes renvoient {}) — rien ne la traverse, ni vers l'extérieur ni vers l'intérieur.
// Au top-level, la frontière est celle d'un bus et elle se franchit VERS LE HAUT : @see ci-dessous
// -isSend:routableToAux:. La règle est dupliquée côté modèle dans EditViewModel.canRouteSend, qui
// filtre en amont ; ce qui suit refuse quand même, car le moteur reste sollicité pendant les
// reconstructions.
//
// L'envoi est un PLUGIN posé en FIN de chaîne de l'émetteur — donc post-fader et post-fenêtre :
// ce qu'on entend est ce qu'on envoie. Il ne touche pas au signal, il en prélève une copie. C'est
// aussi ce qui fait qu'un objet réduit au silence (mute, mute de son stem) n'alimente plus rien.

static void logRoutingDisabledOnce(const char* what) {
    static std::unordered_set<std::string> seen;
    if (seen.insert(what).second)
        NSLog(@"[OBJ] %s : hors de portée du routage (@see -isSend:routableToAux:)", what);
}

static std::string sendMapKey(const std::string& senderKey, const std::string& auxKey) {
    return senderKey + "|" + auxKey;
}

// L'émetteur est-il en amont du NIVEAU DE MONTAGE du retour ? C'est la seule question, parce que
// c'est la seule chose dont dépende l'ordre : un tap doit être écrit avant d'être lu. Deux niveaux
// de montage existent, et la réponse n'est pas la même :
//   • dans un container : les enfants DIRECTS du même container, le retour se somme sur leur
//     CombiningNode et rien ne traverse la frontière d'un container, ni vers l'intérieur ni vers
//     l'extérieur — égalité stricte, donc ;
//   • au top-level : le retour se somme sur les pistes du folder de son stem, ou sur les pistes
//     racine pour un aux du Main. Un envoi MONTE — un objet de stem atteint un aux du Main, dont
//     la somme contient déjà le folder de son stem — mais il ne descend pas, et deux stems frères
//     ne se voient pas. @see createTopLevelAuxReturns / createSubmixAuxReturns
// Ce n'est pas un interdit de politique : un tap prélevé hors de portée serait lu sans ordre
// établi. La règle est dupliquée côté modèle dans EditViewModel.canRouteSend.
- (BOOL)isSend:(const std::string&)senderKey routableToAux:(const std::string&)auxKey {
    if (senderKey == auxKey) return NO;
    if (!_auxKeys.count(auxKey)) return NO;
    auto so = _childOwnerMap.find(senderKey);
    auto ao = _childOwnerMap.find(auxKey);
    const bool senderTopLevel = (so == _childOwnerMap.end());
    const bool auxTopLevel    = (ao == _childOwnerMap.end());
    if (senderTopLevel != auxTopLevel) return NO;
    if (!senderTopLevel) return so->second == ao->second;

    // Clé de stem vide = Main (pas de folder au-dessus de la piste), c'est-à-dire le niveau qui
    // contient tous les autres : ses aux acceptent n'importe quel émetteur top-level.
    const std::string auxStem = [self stemKeyForKey:auxKey];
    return auxStem.empty() || auxStem == [self stemKeyForKey:senderKey];
}

// Le graphe doit être rebâti : la liste des envois qui alimentent un retour est FIGÉE au build
// (ObjAuxReturnNode reçoit les plugins, il ne les cherche pas à chaque bloc), et l'ensemble des
// aux détermine la forme même du montage. Sans ça, poser un envoi pendant la lecture ne
// s'entendrait qu'au prochain changement qui reconstruit, par hasard.
- (void)rebuildGraphForAuxTopology {
    if (_edit) _edit->restartPlayback();
}

- (void)createAux:(NSString*)auxID lane:(NSInteger)lane {
    if (!_edit) return;
    std::string key([auxID UTF8String]);
    if (_containerClipMap.count(key)) return;   // idempotent

    // Posé sur la piste de son compartiment. Un aux ENFANT de groupe n'y passera qu'un instant :
    // l'appelant enchaîne aussitôt sur assignObject:, qui le déplace dans son container.
    te::ClipOwner* owner = [self clipOwnerForKey:key lane:(int)lane];
    if (!owner) return;

    te::TimeRange span(te::TimePosition::fromSeconds(0.0),
                       te::TimePosition::fromSeconds(kEmptyContainerSpanSecs));
    auto* raw = te::insertNewClip(*owner, te::TrackItem::Type::container, span);
    auto* cc  = dynamic_cast<te::ContainerClip*>(raw);
    if (!cc) { NSLog(@"[OBJ] createAux: création du container refusée (%@)", auxID); return; }

    juce::String shortID = juce::String::fromUTF8(key.c_str()).substring(0, 8);
    cc->setName("Aux " + shortID);
    cc->setAutoTempo(false);
    cc->setObjAuxBus(true);          // ce drapeau seul distingue un aux d'un groupe

    _containerClipMap[key] = cc;
    _auxKeys.insert(key);

    // Même chaîne de fin qu'un groupe : fader puis ObjWindowFade. La fenêtre de l'aux borne donc
    // aussi la QUEUE de ses propres FX — c'est la règle commune, et un bus de reverb qui doit
    // laisser sonner sa queue se déclare INFINI (updateAuxWindow: le ramène à kOpenWindowSecs).
    // À ne pas confondre avec le gate d'ObjAuxReturnNode, qui borne l'ENTRÉE du retour (les taps)
    // en amont des FX de l'aux.
    if (auto* pl = cc->getPluginList())
        [self installObjectChainTail:*pl forKey:key
                              volume:0.0f pan:0.0f
                              window:te::TimeRange(te::TimePosition::fromSeconds(0.0),
                                                   te::TimePosition::fromSeconds(kOpenWindowSecs))
                              fadeIn:0.0 fadeOut:0.0];

    // Un aux top-level ajoute une branche de retour à la racine de l'Edit → forme du graphe.
    [self rebuildGraphForAuxTopology];
    NSLog(@"[OBJ] createAux(container): %@ lane=%ld", auxID, (long)lane);
}

// Compat : ancienne signature sans lane (lane 0 par défaut).
- (void)createAux:(NSString*)auxID {
    [self createAux:auxID lane:0];
}

- (void)updateAuxWindow:(NSString*)auxID
                  start:(double)startSecs
                    end:(double)endSecs
                 fadeIn:(double)fadeInSecs
                fadeOut:(double)fadeOutSecs {
    if (!_edit) return;
    std::string key([auxID UTF8String]);
    if (!_containerClipMap.count(key)) return;

    // Contrairement à un groupe, un aux BORNE TOUJOURS son étendue par sa fenêtre : il n'a pas
    // d'enfants sur qui retomber, et l'enveloppe vide l'écraserait à kEmptyContainerSpanSecs.
    // Ça ne coûte rien : un aux ne passe jamais par le CombiningNode d'une lane (sans enfants,
    // createNodeForContainerClip ne produit aucun nœud) — c'est ObjAuxReturnNode qui lit ces bornes.
    //
    // Un aux INFINI est ramené à kOpenWindowSecs au lieu du 1e9 du modèle : l'étendue d'un clip
    // entre dans `Edit::getLength()`, et rien ne gagne à ce qu'une session dure mille ans.
    const double s = juce::jmax(0.0, startSecs);
    double e = (endSecs > s) ? endSecs : s + kEmptyContainerSpanSecs;
    if (e >= kInfiniteWindowThresholdSecs) e = s + kOpenWindowSecs;
    _groupBoundsMap[key] = te::TimeRange(te::TimePosition::fromSeconds(s),
                                         te::TimePosition::fromSeconds(e));

    // AVANT de poser les fondus : c'est ce recalage qui donne au container son étendue réelle.
    [self refreshContainerSpanForKey:key];

    auto it = _containerClipMap.find(key);
    if (it == _containerClipMap.end()) return;

    // Même fin de chaîne qu'un groupe : la fenêtre et les fondus sont ceux de l'ObjWindowFade,
    // et les fondus du clip restent à zéro. @see updateGroupWindow:
    const auto span = it->second->getPosition().time;
    [self setWindowForKey:key
                    start:span.getStart().inSeconds()
                      end:span.getEnd().inSeconds()
                   fadeIn:std::max(0.0, fadeInSecs)
                  fadeOut:std::max(0.0, fadeOutSecs)];

    it->second->setFadeIn (te::TimeDuration());
    it->second->setFadeOut(te::TimeDuration());
}

- (void)removeAux:(NSString*)auxID {
    if (!_edit) return;
    std::string key([auxID UTF8String]);
    auto cit = _containerClipMap.find(key);
    if (cit == _containerClipMap.end()) return;

    // Les envois qui visaient cet aux n'ont plus de destinataire : les retirer des chaînes
    // émettrices, sans quoi ils continueraient de prélever une copie que personne ne lit.
    for (auto it = _auxSendMap.begin(); it != _auxSendMap.end(); ) {
        const std::string& k = it->first;
        const auto sep = k.find('|');
        if (sep != std::string::npos && k.compare(sep + 1, std::string::npos, key) == 0) {
            if (it->second) it->second->removeFromParent();
            it = _auxSendMap.erase(it);
        } else {
            ++it;
        }
    }

    std::string parentKey;
    if (auto ow = _childOwnerMap.find(key); ow != _childOwnerMap.end()) parentKey = ow->second;

    [self closeEditorsAndPurgePluginsForObjectID:auxID];
    cit->second->removeFromParent();
    _auxKeys.erase(key);
    [self forgetObjectBookkeeping:key];
    if (!parentKey.empty()) [self refreshContainerSpanForKey:parentKey];
    [self pruneEmptyPoolTracks];
    [self rebuildGraphForAuxTopology];
    NSLog(@"[OBJ] removeAux(container): %@", auxID);
}

- (void)addSend:(NSString*)senderID toAux:(NSString*)auxID levelDb:(float)levelDb {
    if (!_edit) return;
    std::string sKey([senderID UTF8String]), aKey([auxID UTF8String]);

    // Appelé aussi pendant une reconstruction, où l'aux peut n'être pas encore né : on sort
    // en silence, resyncAllSends repassera quand tout le monde sera là.
    auto ait = _containerClipMap.find(aKey);
    if (ait == _containerClipMap.end()) return;

    if (![self isSend:sKey routableToAux:aKey]) {
        logRoutingDisabledOnce("Send vers un aux hors de portée de l'émetteur");
        return;
    }

    te::PluginList* pl = [self userPluginListForKey:sKey];
    if (!pl) {
        logRoutingDisabledOnce("Send depuis un objet sans chaîne");
        return;
    }

    const std::string mk = sendMapKey(sKey, aKey);
    if (auto ex = _auxSendMap.find(mk); ex != _auxSendMap.end()) {
        // Le Ptr mémorisé garde le plugin en vie même si sa chaîne a été refaite entre-temps
        // (recompilation des FX de l'objet) : il faut donc vérifier qu'il est TOUJOURS dans la
        // liste, sans quoi on croirait câblé un envoi devenu orphelin — et donc muet.
        bool stillInList = false;
        for (auto* p : *pl) if (p == ex->second.get()) { stillInList = true; break; }
        if (stillInList) {
            [self setSendLevel:senderID toAux:auxID levelDb:levelDb];   // câblé → niveau seul
            return;
        }
        _auxSendMap.erase(ex);
    }

    // Filet : un envoi déjà présent dans la chaîne mais absent du registre (chaîne restaurée
    // depuis un état sérialisé) est ADOPTÉ, jamais doublé.
    for (auto* p : *pl) {
        auto* existing = dynamic_cast<te::ObjAuxSendPlugin*>(p);
        if (existing && existing->getTargetAuxClipID() == ait->second->itemID) {
            existing->setLevelDb(levelDb);
            _auxSendMap[mk] = te::Plugin::Ptr(p);
            return;
        }
    }

    // En FIN de chaîne : après le fader ET après l'ObjWindowFade d'un clip. Un envoi posé
    // avant la fenêtre alimenterait l'aux avec ce que l'objet ne fait pas entendre.
    te::Plugin::Ptr p = pl->insertPlugin(te::ObjAuxSendPlugin::create(), pl->size());
    auto* send = dynamic_cast<te::ObjAuxSendPlugin*>(p.get());
    if (!send) { NSLog(@"[OBJ] addSend: insertion refusée (%@ → %@)", senderID, auxID); return; }

    send->setTargetAuxClip(ait->second->itemID);
    send->setLevelDb(levelDb);
    _auxSendMap[mk] = p;
    [self rebuildGraphForAuxTopology];
    NSLog(@"[OBJ] addSend: %@ → %@ (%.1f dB)", senderID, auxID, levelDb);
}

- (void)removeSend:(NSString*)senderID toAux:(NSString*)auxID {
    std::string sKey([senderID UTF8String]), aKey([auxID UTF8String]);
    auto it = _auxSendMap.find(sendMapKey(sKey, aKey));
    if (it == _auxSendMap.end()) return;
    if (it->second) it->second->removeFromParent();
    _auxSendMap.erase(it);
    [self rebuildGraphForAuxTopology];
}

- (void)setSendLevel:(NSString*)senderID toAux:(NSString*)auxID levelDb:(float)levelDb {
    std::string sKey([senderID UTF8String]), aKey([auxID UTF8String]);
    auto it = _auxSendMap.find(sendMapKey(sKey, aKey));
    if (it == _auxSendMap.end()) return;
    // À chaud : le plugin lisse la rampe, le graphe n'est pas reconstruit.
    if (auto* s = dynamic_cast<te::ObjAuxSendPlugin*>(it->second.get())) s->setLevelDb(levelDb);
}


// MARK: - Bus de stem (FolderTrack submix par stem)
//
// Un stem = UN FolderTrack submix. Ses membres ne sont pas des objets mais des PISTES : les
// compartiments du pool alloués à ce stem (@see « Pool de pistes »). Tracktion fait le reste
// nativement — `createNodeForSubmixTrack` somme les pistes filles, applique la plugin-list du
// folder puis sa sortie, et `createNodeForTrack` rend {} pour une piste de submix afin qu'elle
// ne soit pas comptée une seconde fois à la racine.
//
// C'est ce que la bascule containerclip avait tué, et pour une raison précise : « une lane =
// une piste » faisait porter à une même piste des objets de stems différents, si bien que
// l'appartenance ne pouvait plus s'exprimer par un déplacement de piste. Le découplage lane /
// piste lève exactement cette prémisse — le compartiment devient (stem, lane), et changer un
// objet de stem, c'est déplacer son CLIP vers le compartiment de même lane dans l'autre stem.
//
// Ce que ce modèle donne gratuitement, et qu'aucun montage par taps ne donnerait sans le
// réécrire : la chaîne FX de bus (plugin-list du folder), le gain, le mute, le VU, le
// DÉTACHEMENT du Main (`getOutput()->setOutputToDeviceID({})` — un ContainerClip n'a pas de
// sortie), et « Σ stems = mix » vrai par construction puisqu'un objet n'emprunte qu'un chemin.
//
// Un ENFANT de groupe n'a pas de stem propre : il vit dans le container de son groupe, donc sur
// la piste du groupe, donc dans le stem du groupe. Le modèle Swift interdit déjà de lui en
// assigner un ; ici les déplacements le sautent explicitement.
//
// Un AUX, lui, en a un — et c'est le stem qui détermine où son retour est monté : dans le folder
// du stem qui porte son ContainerClip (@see createSubmixAuxReturns), à la racine s'il est au Main.
// D'où la portée d'un envoi top-level : mêmes stem. Changer de stem un aux OU un émetteur peut
// donc rompre des envois — c'est ce que purge `pruneOutOfScopeSends`.

- (void)createStemBus:(NSString*)stemID {
    if (!_edit) return;
    std::string sKey([stemID UTF8String]);
    if (_stemBusMap.count(sKey)) return;  // idempotent

    auto folderTrack = _edit->insertNewFolderTrack(
        te::TrackInsertPoint(nullptr, nullptr), nullptr, true);   // true = submix
    if (!folderTrack) { NSLog(@"[OBJ] createStemBus: création du folder refusée (%@)", stemID); return; }

    juce::String shortID = juce::String::fromUTF8(sKey.c_str()).substring(0, 8);
    // ASCII uniquement : String(const char*) assert sur du non-ASCII (cf piège JUCE).
    folderTrack->setName("Stem " + shortID);
    _stemBusMap[sKey] = folderTrack.get();

    // Mixer : ObjGain (niveau de bus) puis LevelMeter (VU sortie) en fin de chaîne du folder.
    // Les FX user du bus viendront s'insérer DEVANT le gain (@see userInsertIndexForKey:).
    auto& pl = folderTrack->pluginList;
    if (auto g = pl.insertPlugin(te::ObjGainPlugin::create(), pl.size()))
        _stemGainMap[sKey] = g;
    if (auto meter = pl.insertPlugin(te::LevelMeterPlugin::create(), pl.size())) {
        auto client = std::make_unique<te::LevelMeasurer::Client>();
        if (auto* lm = dynamic_cast<te::LevelMeterPlugin*>(meter.get())) {
            // Peak (et non RMS) : détecte le clipping même sur quelques samples. La balistique
            // (attaque rapide / release lent) est appliquée côté Swift dans le poll du VU.
            lm->measurer.setMode(te::LevelMeasurer::peakMode);
            lm->measurer.addClient(*client);
        }
        _stemMeterClients[sKey] = std::move(client);
    }
    NSLog(@"[OBJ] createStemBus: %@", stemID);
}

// Déplace l'objet `key` vers le compartiment de même lane du stem `stemKey` (vide = Main).
// C'est l'unique geste d'appartenance : le clip change de piste, la piste dit le stem.
- (void)moveObjectKey:(const std::string&)key toStemKey:(const std::string&)stemKey {
    if (!_edit) return;
    // Enfant de groupe : pas de stem propre, il suit son groupe.
    if (_childOwnerMap.count(key)) return;

    te::Clip* clip = nullptr;
    if (auto cit = _containerClipMap.find(key); cit != _containerClipMap.end())
        clip = cit->second;                       // groupe, aux ou objet MIDI
    else if (auto it = _clipMap.find(key); it != _clipMap.end())
        clip = it->second.get();
    if (!clip) return;

    // Un AUX se déplace comme les autres depuis que son retour est monté dans le folder du stem
    // qui le porte (@see createSubmixAuxReturns) : poser son ContainerClip sur une piste de ce
    // folder, c'est exactement ce qui décide du niveau de montage. Auparavant on sortait ici,
    // parce que le retour était bâti au-dessus de TOUTES les pistes et qu'un aux rangé dans un
    // folder n'y aurait ajouté qu'un nœud muet.

    // La lane est celle du compartiment actuel : changer de stem ne déplace pas l'objet dans
    // l'affichage, et ne doit donc pas changer sa répartition sur les pistes.
    const OBJTrackSlot current = [self slotOfTrack:objOwningTrack(*clip)];
    if (current.lane < 0) return;                 // pas sur une piste du pool : rien à faire

    auto* dest = [self trackForSlot:OBJTrackSlot{ stemKey, current.lane }];
    if (!dest || clip->getParent() == static_cast<te::ClipOwner*>(dest)) return;

    if (!moveClipToOwner(*clip, *dest)) {
        NSLog(@"[OBJ] moveObjectKey: déplacement refusé (%s)", key.c_str());
        return;
    }
    [self pruneEmptyPoolTracks];

    // Reconstruire le graphe ne se justifie que si la TOPOLOGIE des aux a bougé : un aux qui
    // change de stem change le niveau où son retour est monté, et un envoi qui sort de portée
    // change la liste figée que reçoit ObjAuxReturnNode. Un simple clip qui change de bus, lui,
    // n'y touche pas — et le déplacement de piste déclenche déjà sa propre reconstruction.
    // L'inverse (un envoi qui redevient possible) passe par addSend, qui rebâtit de lui-même.
    const BOOL pruned = [self pruneOutOfScopeSends];
    if (pruned || _auxKeys.count(key))
        [self rebuildGraphForAuxTopology];
}

// Retire les envois dont l'émetteur et l'aux ne sont plus au même niveau de montage — après un
// changement de stem, typiquement. Les laisser en place serait pire que les perdre : le tap
// continuerait d'être prélevé pour un retour qui ne le lit pas (au mieux), ou qui le lit sans
// ordre établi (au pire). Le modèle Swift décâble les siens de son côté (resyncAllSends) ; ceci
// est le filet, et il couvre aussi les envois restaurés depuis un projet enregistré avant cette
// règle. Renvoie OUI si au moins un envoi est parti.
- (BOOL)pruneOutOfScopeSends {
    BOOL removedAny = NO;

    for (auto it = _auxSendMap.begin(); it != _auxSendMap.end(); ) {
        const auto sep = it->first.find('|');
        if (sep == std::string::npos) { ++it; continue; }

        const std::string senderKey = it->first.substr(0, sep);
        const std::string auxKey    = it->first.substr(sep + 1);

        if ([self isSend:senderKey routableToAux:auxKey]) { ++it; continue; }

        if (it->second) it->second->removeFromParent();
        NSLog(@"[OBJ] envoi retiré, hors de portée après changement de stem : %s → %s",
              senderKey.c_str(), auxKey.c_str());
        it = _auxSendMap.erase(it);
        removedAny = YES;
    }

    return removedAny;
}

// MARK: - Mixer : gain + VU des stems et du master (increment 1)

// Niveau (0..1, -60..0 dB mappé) à la sortie du stem. Lit le LevelMeter du folder.
- (float)audioLevelForStem:(NSString*)stemID {
    auto it = _stemMeterClients.find(std::string([stemID UTF8String]));
    if (it == _stemMeterClients.end() || !it->second) return 0.0f;
    auto& client = *it->second;
    float dB = std::max(client.getAndClearAudioLevel(0).dB, client.getAndClearAudioLevel(1).dB);
    return std::max(0.0f, std::min(1.0f, (dB + 60.0f) / 60.0f));
}

- (void)setStemGain:(float)dB stemID:(NSString*)stemID {
    auto it = _stemGainMap.find(std::string([stemID UTF8String]));
    if (it == _stemGainMap.end()) return;
    if (auto* g = dynamic_cast<te::ObjGainPlugin*>(it->second.get())) g->setGainDb(dB);
}

// Détache / rattache la sortie du bus au Main. Le FolderTrack submix route par défaut vers le
// device de sortie (= sommé dans le master). routeToMain=NO → sortie sur un device ID vide :
// plus aucun signal n'atteint le Main. Le VU du bus (LevelMeter en amont dans le folder) reste
// alimenté quel que soit le routage.
//
// L'état est MÉMORISÉ (_stemRouteToMain) puis appliqué : @see applyStemRouting pour la raison,
// qui n'a rien d'anecdotique — le folder n'a pas de sortie à lui.
- (void)setStemRouteToMain:(BOOL)routeToMain stemID:(NSString*)stemID {
    std::string sKey([stemID UTF8String]);
    _stemRouteToMain[sKey] = (bool) routeToMain;
    [self applyStemRouting:sKey];
}

// Applique le routage mémorisé du stem à TOUTES les pistes audio de son folder.
//
// Un FolderTrack n'a PAS de TrackOutput à lui : `FolderTrack::getOutput()` renvoie celui de sa
// PREMIÈRE piste audio, et c'est cette sortie-là que le constructeur de graphe interroge pour
// décider si le submix est sommé dans le device (donc dans le Main) ou drainé dans un SinkNode.
//
// Deux conséquences, qui étaient exactement le bug : une piste fraîchement insérée s'initialise
// sur le device par défaut (TrackOutput::initialise), et `trackForSlot:` l'insère EN TÊTE du
// folder — le premier objet rangé dans un stem détaché fabriquait donc, sans le vouloir, une
// nouvelle sortie de bus rebranchée au Main. L'objet continuait de s'entendre dans le mix
// principal jusqu'à ce qu'on rebascule « route to main », qui réécrivait l'état sur le nouveau
// porteur. Le même piège vaut au chargement d'un projet (les bus sont créés avant les objets :
// le folder n'avait alors aucune piste, et le réglage tombait dans le vide).
//
// D'où l'invariant posé ici : toutes les pistes du folder portent le MÊME routage, donc peu
// importe laquelle `getOutput()` désigne. Aucune d'elles n'est routée pour son propre compte —
// une piste dans un submix est rendue par `createNodeForSubmixTrack`, jamais au niveau racine.
- (void)applyStemRouting:(const std::string&)stemKey {
    auto it = _stemBusMap.find(stemKey);
    if (it == _stemBusMap.end() || !it->second) return;

    auto rit = _stemRouteToMain.find(stemKey);
    const bool routeToMain = (rit == _stemRouteToMain.end()) ? true : rit->second;

    for (auto* track : it->second->getAllAudioSubTracks(true)) {
        if (!track) continue;
        auto& out = track->getOutput();
        if (routeToMain) out.setOutputToDefaultDevice(false);
        else             out.setOutputToDeviceID({});
    }
}

// Master : VU + gain sur la sortie générale (chaîne de mastering = getMasterPluginList).
- (void)ensureMasterMeter {
    if (_masterMeterClient || !_edit) return;
    auto& pl = _edit->getMasterPluginList();
    if (auto meter = pl.insertPlugin(te::LevelMeterPlugin::create(), pl.size())) {
        _masterMeterClient = std::make_unique<te::LevelMeasurer::Client>();
        if (auto* lm = dynamic_cast<te::LevelMeterPlugin*>(meter.get())) {
            // Peak (voir stem) : nécessaire pour capter les crêtes / clips brefs.
            lm->measurer.setMode(te::LevelMeasurer::peakMode);
            lm->measurer.addClient(*_masterMeterClient);
        }
    }
}

- (float)audioLevelForMaster {
    [self ensureMasterMeter];
    if (!_masterMeterClient) return 0.0f;
    float dB = std::max(_masterMeterClient->getAndClearAudioLevel(0).dB,
                        _masterMeterClient->getAndClearAudioLevel(1).dB);
    return std::max(0.0f, std::min(1.0f, (dB + 60.0f) / 60.0f));
}

- (void)setMasterGain:(float)dB {
    if (!_edit) return;
    if (auto vol = _edit->getMasterVolumePlugin())
        vol->setVolumeDb(dB);
}

- (void)disbandStemBus:(NSString*)stemID memberIDs:(NSArray<NSString*>*)memberIDs {
    if (!_edit) return;
    std::string sKey([stemID UTF8String]);
    auto it = _stemBusMap.find(sKey);
    if (it == _stemBusMap.end()) return;
    te::FolderTrack* folder = it->second;

    // Purge la chaîne FX user du bus (plugins + éditeurs ouverts) AVANT de détruire le folder,
    // comme pour un clip : sinon ~AudioProcessor assert sur un éditeur resté ouvert et
    // _pluginMap garde des Ptr détachées.
    [self closeEditorsAndPurgePluginsForObjectID:stemID];

    // Les membres retournent au Main, à lane égale.
    for (NSString* memberID in memberIDs)
        [self moveObjectKey:std::string([memberID UTF8String]) toStemKey:std::string()];

    // Déregistre le client de mesure AVANT que le LevelMeterPlugin ne soit détruit.
    if (auto cl = _stemMeterClients.find(sKey); cl != _stemMeterClients.end() && cl->second)
        for (auto* p : folder->pluginList)
            if (auto* lm = dynamic_cast<te::LevelMeterPlugin*>(p))
                lm->measurer.removeClient(*cl->second);
    _stemMeterClients.erase(sKey);
    _stemGainMap.erase(sKey);
    _stemBusMap.erase(sKey);
    _stemRouteToMain.erase(sKey);
    _objectChainMap.erase(sKey);

    // Les compartiments du stem sont vides une fois les membres partis : les ramasser AVANT de
    // supprimer le folder, sinon deleteTrack emporterait des pistes encore inscrites au pool.
    [self pruneEmptyPoolTracks];
    // Filet : un compartiment que le ramassage n'aurait pas vidé (objet resté sans membre
    // déclaré) doit quand même sortir du folder, pas disparaître avec lui. Sa sortie est
    // rebranchée au device : dans un folder DÉTACHÉ elle était vide (@see applyStemRouting), et
    // une piste à sortie vide posée à la racine n'est plus qu'un puits — ses objets seraient
    // devenus inaudibles au lieu de retomber sur le Main.
    for (auto& p : _poolTracks)
        if (p.stemKey == sKey) {
            _edit->moveTrack(p.track, te::TrackInsertPoint((te::Track*)nullptr, (te::Track*)nullptr));
            if (p.track) p.track->getOutput().setOutputToDefaultDevice(false);
            p.stemKey.clear();
        }

    _edit->deleteTrack(folder);
    NSLog(@"[OBJ] disbandStemBus: %@", stemID);
}

- (void)assignObjects:(NSArray<NSString*>*)objectIDs toStemID:(NSString*)stemID {
    if (!_edit || !stemID) return;
    std::string sKey([stemID UTF8String]);
    if (!_stemBusMap.count(sKey)) return;

    for (NSString* objID in objectIDs)
        [self moveObjectKey:std::string([objID UTF8String]) toStemKey:sKey];

    NSLog(@"[OBJ] assignObjects %lu → stem %@", (unsigned long)objectIDs.count, stemID);
}

- (void)moveObject:(NSString*)objectID
       fromStemID:(NSString* _Nullable)oldStemID
         toStemID:(NSString* _Nullable)newStemID {
    if (!_edit) return;
    // `oldStemID` est ignoré : d'où vient l'objet se lit sur son clip, pas sur un paramètre.
    // Le garder à la signature évite de toucher l'API et le modèle Swift.
    (void)oldStemID;
    std::string sKey = newStemID ? std::string([newStemID UTF8String]) : std::string();
    if (!sKey.empty() && !_stemBusMap.count(sKey)) return;

    [self moveObjectKey:std::string([objectID UTF8String]) toStemKey:sKey];
    NSLog(@"[OBJ] moveObject %@ → stem %@", objectID, newStemID ?: @"Main");
}

// MARK: - Ciseaux (split)

- (BOOL)splitSoundObjectWithID:(NSString*)uuid
                        atTime:(double)splitTime
                         newID:(NSString*)newID {
    if (!_edit) return NO;

    std::string key([uuid UTF8String]);
    auto clipIt  = _clipMap.find(key);
    if (clipIt == _clipMap.end()) return NO;

    auto clip    = clipIt->second;
    auto origPos = clip->getPosition();
    // Le fragment droit naît chez le MÊME propriétaire que l'original : sa piste porteuse,
    // ou le ContainerClip de son groupe.
    te::ClipOwner* owner = clip->getParent();
    if (!owner) return NO;
    const bool insideContainer = (_childOwnerMap.find(key) != _childOwnerMap.end());

    double origStart  = origPos.time.getStart().inSeconds();
    double origEnd    = origPos.time.getEnd().inSeconds();
    double origOffset = origPos.offset.inSeconds();
    // Sous boucle, l'offset du clip porte un décalage de phase (−loopStart, @see updatePosition:) :
    // le remettre à plat avant d'en dériver l'offset du fragment droit, sans quoi la moitié droite
    // d'un clip bouclé naîtrait ailleurs dans son fichier.
    if (auto* acbSrc = dynamic_cast<te::AudioClipBase*>(clip.get()))
        if (const auto lr = acbSrc->getLoopRange(); !lr.isEmpty())
            origOffset += lr.getStart().inSeconds();
    double splitRel   = splitTime - origStart;

    // Propriétés à préserver sur le fragment droit (varispeed / pitch / reverse)
    double origSpeed     = clip->getSpeedRatio();
    float  origPitch     = clip->getPitchChange();
    bool   origReversed  = clip->getIsReversed();

    // Sécurité : point de coupe doit être strictement à l'intérieur du clip
    if (splitRel <= 0.01 || splitRel >= (origEnd - origStart) - 0.01) return NO;

    // Réduire le clip original à la partie gauche
    te::ClipPosition leftPos;
    leftPos.time = te::TimeRange(
        te::TimePosition::fromSeconds(origStart),
        te::TimePosition::fromSeconds(splitTime)
    );
    leftPos.offset = te::TimeDuration::fromSeconds(origOffset);
    clip->setPosition(leftPos);
    [self setWindowForKey:key start:origStart end:splitTime fadeIn:0.0 fadeOut:0.0];

    // Fichier d'ORIGINE, et non `getAudioFile()` : un clip inversé pointe alors sur son PROXY
    // retourné (updateReversedState). Le fragment droit serait né sur ce proxy, puis
    // `configureFreshClip` lui aurait demandé d'inverser… le proxy — un retournement de plus,
    // dont le rendu échoue (ReverseRenderJob recopie alors la source telle quelle) : la moitié
    // droite d'un clip inversé se remettait à jouer À L'ENDROIT.
    juce::File audioFile = clip->getOriginalFile();
    // origOffset est en temps-clip (offsetClip), et le fragment droit garde la même vitesse :
    // son offsetClip avance simplement de splitRel (timeline). PAS de ×vitesse ici — la
    // conversion source↔clip se fait ailleurs (voir CONVENTION OFFSET dans updatePosition).
    // Vrai aussi en reverse : le proxy retourné se lit, lui, dans le sens des temps croissants.
    double rightClipOffset = juce::jmax(0.0, origOffset + splitRel);
    te::ClipPosition rightPos;
    rightPos.time = te::TimeRange(
        te::TimePosition::fromSeconds(splitTime),
        te::TimePosition::fromSeconds(origEnd)
    );
    rightPos.offset = te::TimeDuration::fromSeconds(rightClipOffset);

    auto newClip = te::insertWaveClip(*owner, audioFile.getFileNameWithoutExtension(),
                                      audioFile, rightPos, te::DeleteExistingClips::no);
    if (!newClip) {
        clip->setPosition(origPos);  // rollback
        return NO;
    }

    // INVARIANT « clip sans time-stretch » — voir addSoundObject.
    configureFreshClip(newClip, rightPos, origSpeed, origReversed);
    newClip->setPitchChange(origPitch);
    newClip->setPosition(rightPos);   // ré-affirmée en dernier (disableLooping rallonge le clip)

    // Reprendre le gain / pan du fader de l'original. Les FX user sont reconstruits côté modèle
    // via syncPlugins ; ici on ne pose que la queue de chaîne (fader + fenêtre/fades).
    float origGainDb = 0.0f, origPan = 0.0f;
    if (auto fit = _faderGainMap.find(key); fit != _faderGainMap.end())
        if (auto* g = dynamic_cast<te::ObjGainPlugin*>(fit->second.get())) {
            origGainDb = g->getGainDb();
            origPan    = g->getPan();
        }

    std::string newKey([newID UTF8String]);
    _clipMap[newKey] = newClip;
    // Le fragment droit est né chez `owner`, donc dans le même compartiment que l'original :
    // seule l'appartenance à un container reste à recopier, elle n'est pas déductible du clip.
    if (insideContainer) _childOwnerMap[newKey] = _childOwnerMap[key];

    if (auto* pl = newClip->getPluginList())
        [self installObjectChainTail:*pl forKey:newKey
                              volume:origGainDb pan:origPan
                              window:rightPos.time fadeIn:0.0 fadeOut:0.0];

    // (Le split conserve l'étendue totale, mais on recale par principe : no-op si rien n'a bougé.)
    if (insideContainer) [self refreshOwnerContainerSpanFor:newKey];

    NSLog(@"[OBJ] split %@ at %.3fs → %s", uuid, splitTime, newKey.c_str());
    return YES;
}

// MARK: - Tempo et signature temporelle

- (double)getTempo {
    if (!_edit) return 120.0;
    return _edit->tempoSequence.getBpmAt(te::TimePosition::fromSeconds(0.0));
}

- (void)setTempo:(double)bpm {
    [self setTempo:bpm remap:YES];
}

- (void)setTempo:(double)bpm remap:(BOOL)remap {
    if (!_edit) return;
    double clamped = juce::jlimit(20.0, 300.0, bpm);
    auto& ts = _edit->tempoSequence.getTempoAt(te::TimePosition::fromSeconds(0.0));
    if (remap) {
        ts.setBpm(clamped);
    } else {
        ts.set(ts.startBeatNumber, clamped, ts.curve, false);
    }
}

- (double)getClipStartTimeForID:(NSString*)uuid {
    if (!_edit) return -1.0;
    std::string key([uuid UTF8String]);
    if (auto it = _clipMap.find(key); it != _clipMap.end())
        return it->second->getPosition().time.getStart().inSeconds();
    if (auto it = _midiClipMap.find(key); it != _midiClipMap.end())
        return it->second->getPosition().time.getStart().inSeconds();
    // Groupe/aux : pas de clip moteur → -1 (la position est un fait modèle).
    return -1.0;
}

- (NSInteger)getTimeSigNumerator {
    if (!_edit) return 4;
    return (NSInteger)_edit->tempoSequence.getTimeSigAt(te::TimePosition::fromSeconds(0.0)).numerator;
}

- (NSInteger)getTimeSigDenominator {
    if (!_edit) return 4;
    return (NSInteger)_edit->tempoSequence.getTimeSigAt(te::TimePosition::fromSeconds(0.0)).denominator;
}

- (void)setTimeSig:(NSInteger)numerator denominator:(NSInteger)denominator {
    if (!_edit) return;
    auto& ts = _edit->tempoSequence.getTimeSigAt(te::TimePosition::fromSeconds(0.0));
    ts.numerator  = (int)numerator;
    ts.denominator = (int)denominator;
}

// MARK: - Transport

- (void)play {
    if (_edit) _edit->getTransport().play(false);
}

- (void)stop {
    if (_edit) _edit->getTransport().stop(false, false);
}

- (void)seekTo:(double)seconds {
    if (_edit)
        _edit->getTransport().setPosition(te::TimePosition::fromSeconds(seconds));
}

- (double)currentPlaybackPosition {
    return _edit ? _edit->getTransport().getPosition().inSeconds() : 0.0;
}

- (BOOL)isCurrentlyPlaying {
    return _edit ? (BOOL)_edit->getTransport().isPlaying() : NO;
}

// MARK: - Loop Tracktion
// Ces méthodes sont appelées depuis ContentView, pas depuis le ViewModel.
// loopModeEnabled (Objekat) et l'état Tracktion sont deux choses distinctes :
// le moteur ne sait rien du mode loop Objekat — il reçoit juste la région et un on/off.

- (void)setTracktionLoopRegionFrom:(double)start to:(double)end {
    if (!_edit) return;
    _edit->getTransport().setLoopRange(
        te::TimeRange(te::TimePosition::fromSeconds(start),
                      te::TimePosition::fromSeconds(end)));
}

- (void)activateTracktionLoop {
    if (_edit) _edit->getTransport().looping = true;
}

- (void)deactivateTracktionLoop {
    if (_edit) _edit->getTransport().looping = false;
}

// MARK: - Plugins

static NSArray<NSDictionary*>* tracktionBuiltInPluginList() {
    return @[
        @{@"name": @"Equalizer",   @"manufacturer": @"Tracktion", @"identifier": @"4bandEq",     @"format": @"TracktionInternal"},
        @{@"name": @"Reverb",      @"manufacturer": @"Tracktion", @"identifier": @"reverb",       @"format": @"TracktionInternal"},
        @{@"name": @"Compressor",  @"manufacturer": @"Tracktion", @"identifier": @"compressor",   @"format": @"TracktionInternal"},
        @{@"name": @"Chorus",      @"manufacturer": @"Tracktion", @"identifier": @"chorus",       @"format": @"TracktionInternal"},
        @{@"name": @"Delay",       @"manufacturer": @"Tracktion", @"identifier": @"delay",        @"format": @"TracktionInternal"},
        @{@"name": @"Phaser",      @"manufacturer": @"Tracktion", @"identifier": @"phaser",       @"format": @"TracktionInternal"},
        @{@"name": @"Low Pass",    @"manufacturer": @"Tracktion", @"identifier": @"lowpass",      @"format": @"TracktionInternal"},
        @{@"name": @"Pitch Shift", @"manufacturer": @"Tracktion", @"identifier": @"pitchShifter", @"format": @"TracktionInternal"},
    ];
}

- (NSArray<NSDictionary*>*)availablePlugins {
    NSMutableArray* result = [NSMutableArray arrayWithArray:tracktionBuiltInPluginList()];
    // Ajoute les plugins externes scannés
    auto& kl = _engine->getPluginManager().knownPluginList;
    for (int i = 0; i < kl.getNumTypes(); i++) {
        auto* d = kl.getType(i);
        if (!d) continue;
        juce::String nameStr = d->name;
        juce::String mfStr   = d->manufacturerName;
        juce::String idStr   = d->fileOrIdentifier;
        juce::String fmtStr  = d->pluginFormatName;
        [result addObject:@{
            @"name":         [NSString stringWithUTF8String:nameStr.toRawUTF8()],
            @"manufacturer": [NSString stringWithUTF8String:mfStr.toRawUTF8()],
            @"identifier":   [NSString stringWithUTF8String:idStr.toRawUTF8()],
            @"format":       [NSString stringWithUTF8String:fmtStr.toRawUTF8()],
            @"isInstrument": @(d->isInstrument)
        }];
    }
    return result;
}

// Détecte si un bundle VST3 est un instrument (VSTi), SANS charger son binaire : lit
// Contents/Resources/moduleinfo.json (VST3 SDK ≥ 3.7) et cherche "Instrument" dans le tableau
// "Sub Categories" d'une classe. JSON relâché (virgules traînantes) → pas de parser strict :
// on scope la recherche à l'intérieur de chaque tableau "Sub Categories" pour éviter les faux
// positifs sur un nom de plugin contenant « Instrument ». Retourne NO si pas de moduleinfo.json
// (vieux plugins) — ils restent traités comme effets (limite connue).
- (BOOL)vst3IsInstrumentAtURL:(NSURL*)bundleURL {
    NSURL* infoURL = [bundleURL URLByAppendingPathComponent:@"Contents/Resources/moduleinfo.json"];
    NSString* text = [NSString stringWithContentsOfURL:infoURL encoding:NSUTF8StringEncoding error:nil];
    if (text.length == 0) return NO;
    NSRange search = NSMakeRange(0, text.length);
    while (true) {
        NSRange key = [text rangeOfString:@"\"Sub Categories\"" options:0 range:search];
        if (key.location == NSNotFound) break;
        NSUInteger from = key.location + key.length;
        NSRange rest = NSMakeRange(from, text.length - from);
        NSRange close = [text rangeOfString:@"]" options:0 range:rest];
        NSUInteger end = (close.location == NSNotFound) ? text.length : close.location;
        NSRange arrRange = NSMakeRange(from, end - from);
        if ([text rangeOfString:@"\"Instrument\"" options:0 range:arrRange].location != NSNotFound)
            return YES;
        search = NSMakeRange(end, text.length - end);
    }
    return NO;
}

- (void)scanPluginsWithCompletion:(void(^)(NSArray<NSDictionary*>*))completion {
    auto& kl = _engine->getPluginManager().knownPluginList;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        // ── AU : énumération via CoreAudio sans instanciation ─────────────────
        // AudioComponentFindNext + GetDescription + CopyName ne créent jamais
        // d'instance AU → aucun risque de crash AudioComponentInstanceDispose.
        {
            // Convertit un OSType en chaîne 4 caractères (format JUCE)
            auto fourCC = [](OSType t) -> juce::String {
                char s[5] = {
                    (char)((t >> 24) & 0xFF), (char)((t >> 16) & 0xFF),
                    (char)((t >>  8) & 0xFF), (char)(t & 0xFF), '\0'
                };
                return juce::String(s);
            };

            AudioComponentDescription search = {};  // zéro = wildcard tous types
            AudioComponent comp = nullptr;
            while ((comp = AudioComponentFindNext(comp, &search)) != nullptr) {
                AudioComponentDescription cd;
                if (AudioComponentGetDescription(comp, &cd) != noErr) continue;

                // Ne garder que les types pertinents pour une DAW
                OSType t = cd.componentType;
                if (t != kAudioUnitType_Effect       &&
                    t != kAudioUnitType_MusicEffect   &&
                    t != kAudioUnitType_MusicDevice   &&
                    t != kAudioUnitType_MIDIProcessor) continue;

                CFStringRef nameRef = nullptr;
                if (AudioComponentCopyName(comp, &nameRef) != noErr) continue;
                NSString* fullName = (__bridge_transfer NSString*)nameRef;

                // Format standard CoreAudio : "Fabricant: NomPlugin"
                NSArray<NSString*>* parts = [fullName componentsSeparatedByString:@": "];
                NSString* manufacturer = (parts.count >= 2) ? parts[0] : @"";
                NSString* name        = (parts.count >= 2) ? parts[1] : fullName;

                // fileOrIdentifier au format JUCE AudioUnit : "xxxx,yyyy,zzzz"
                juce::String identifier = fourCC(cd.componentType)         + ","
                                        + fourCC(cd.componentSubType)      + ","
                                        + fourCC(cd.componentManufacturer);

                juce::PluginDescription pd;
                pd.name             = juce::String::fromUTF8([name UTF8String]);
                pd.pluginFormatName = "AudioUnit";
                pd.fileOrIdentifier = identifier;
                pd.manufacturerName = juce::String::fromUTF8([manufacturer UTF8String]);
                pd.numInputChannels  = 2;
                pd.numOutputChannels = 2;
                pd.isInstrument      = (t == kAudioUnitType_MusicDevice);
                pd.uniqueId          = (int)(cd.componentSubType ^ cd.componentManufacturer);
                kl.addType(pd);
                NSLog(@"[OBJ] AU trouvé: %@ / %@", name, manufacturer);
            }
        }

        // ── VST3 : lecture Info.plist — le binaire n'est jamais chargé ────────
        NSArray<NSString*>* vst3Dirs = @[
            @"/Library/Audio/Plug-Ins/VST3",
            [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Audio/Plug-Ins/VST3"]
        ];
        NSFileManager* fm = [NSFileManager defaultManager];
        for (NSString* baseDir in vst3Dirs) {
            NSDirectoryEnumerator* enumerator =
                [fm enumeratorAtURL:[NSURL fileURLWithPath:baseDir]
                includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                options:NSDirectoryEnumerationSkipsHiddenFiles
                errorHandler:nil];
            for (NSURL* url in enumerator) {
                if (![url.pathExtension isEqualToString:@"vst3"]) continue;
                [enumerator skipDescendants];
                NSURL* plistURL = [url URLByAppendingPathComponent:@"Contents/Info.plist"];
                NSDictionary* plist = [NSDictionary dictionaryWithContentsOfURL:plistURL];
                NSString* bundleName = plist[@"CFBundleName"]
                    ?: url.URLByDeletingPathExtension.lastPathComponent;
                NSString* bundleID = plist[@"CFBundleIdentifier"] ?: @"";
                juce::PluginDescription pd;
                pd.name             = juce::String::fromUTF8([bundleName UTF8String]);
                pd.pluginFormatName = "VST3";
                pd.fileOrIdentifier = juce::String::fromUTF8([url.path UTF8String]);
                pd.manufacturerName = juce::String::fromUTF8([bundleID UTF8String]);
                pd.numInputChannels  = 2;
                pd.numOutputChannels = 2;
                pd.isInstrument      = [self vst3IsInstrumentAtURL:url];
                // uniqueId dérivé du chemin pour distinguer les sub-plugins
                pd.uniqueId = (int)juce::String::fromUTF8([url.path UTF8String]).hashCode();
                kl.addType(pd);
                NSLog(@"[OBJ] VST3 trouvé: %@ (%@)%@", bundleName, url.lastPathComponent,
                      pd.isInstrument ? @" [instrument]" : @"");
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self savePluginCache];
            completion([self availablePlugins]);
        });
    });
}

- (NSString* _Nullable)addPlugin:(NSDictionary*)pluginInfo toObjectID:(NSString*)uuid {
    return [self addPlugin:pluginInfo toObjectID:uuid stateXML:nil];
}

- (NSString* _Nullable)addPlugin:(NSDictionary*)pluginInfo
                      toObjectID:(NSString*)uuid
                        stateXML:(NSString* _Nullable)stateXML {
    if (!_edit) return nil;
    std::string key([uuid UTF8String]);

    // PluginList unifiée sur la track de l'objet (clip → track dédiée, groupe → FolderTrack,
    // aux → AudioTrack). Voir -userPluginListForKey:.
    te::PluginList* pluginListPtr = [self userPluginListForKey:key];
    if (!pluginListPtr) {
        NSLog(@"[OBJ] addPlugin: objet '%@' introuvable", uuid);
        return nil;
    }
    te::PluginList* clipPlugins = pluginListPtr;

    NSString* pluginKey  = pluginInfo[@"pluginKey"];
    NSString* identifier = pluginInfo[@"identifier"];
    NSString* format     = pluginInfo[@"format"];
    NSString* pluginName = pluginInfo[@"name"] ?: @"?";
    if (!pluginKey || !identifier || !format) return nil;

    te::Plugin::Ptr ptr = nullptr;

    juce::String fmtStr(juce::String::fromUTF8([format UTF8String]));
    juce::String idStr(juce::String::fromUTF8([identifier UTF8String]));

    // ── Restauration directe depuis l'état sauvé (round-trip Tracktion) ──
    // Le ValueTree sauvé encode déjà la description résolue + les params/state,
    // donc on l'insère tel quel plutôt que de re-résoudre la PluginDescription.
    if (stateXML.length > 0) {
        if (auto xml = juce::parseXML(juce::String::fromUTF8([stateXML UTF8String]))) {
            juce::ValueTree savedTree = juce::ValueTree::fromXml(*xml);
            if (savedTree.isValid() && savedTree.hasType(juce::Identifier("PLUGIN"))) {
                const int at = [self userInsertIndexForKey:key in:*clipPlugins];
                // CONSIGNE, comme pour l'instrument : un FX qui vient d'être retiré à l'identique
                // se reprend vivant. Un aller-retour de chaîne recharge sinon chaque AU user.
                if (auto parked = [self takeParkedPluginMatching:savedTree]) {
                    ptr = clipPlugins->insertPlugin(parked->state, at);
                    if (ptr) NSLog(@"[PERF] plugin « %@ » repris de la consigne (aucun chargement)",
                                   pluginName);
                }
                if (!ptr) {
                    [self freshenItemIDsInTree:savedTree];   // sinon on vole son id à l'instance source
                    ptr = clipPlugins->insertPlugin(savedTree, at);
                    NSLog(@"[OBJ] addPlugin: restauration état sauvé '%@' → %@",
                          pluginName, ptr ? @"OK" : @"ECHEC (fallback création standard)");
                }
            }
        }
    }

    if (!ptr) {
    NSLog(@"[OBJ] addPlugin: tentative ajout '%@' [%@] identifiant='%@'",
          pluginName, format, identifier);

    // Pour les plugins à chemin fichier (VST3), vérifier l'existence avant toute tentative
    if ([format isEqualToString:@"VST3"]) {
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:identifier];
        if (!exists) {
            NSLog(@"[OBJ] addPlugin: bundle introuvable — purge du cache UserDefaults : %@", identifier);
            // Retirer toutes les entrées pointant vers ce chemin disparu
            auto& kl = _engine->getPluginManager().knownPluginList;
            juce::String idStr(juce::String::fromUTF8([identifier UTF8String]));
            juce::Array<juce::PluginDescription*> toRemove;
            for (int i = 0; i < kl.getNumTypes(); i++) {
                auto* d = kl.getType(i);
                if (d && d->fileOrIdentifier == idStr)
                    toRemove.add(d);
            }
            for (auto* d : toRemove) kl.removeType(*d);
            if (!toRemove.isEmpty()) [self savePluginCache];
            return nil;
        }
    }

    if ([format isEqualToString:@"TracktionInternal"]) {
        juce::ValueTree pt("PLUGIN");
        pt.setProperty("type", idStr, nullptr);
        ptr = clipPlugins->insertPlugin(pt, [self userInsertIndexForKey:key in:*clipPlugins]);
        NSLog(@"[OBJ] addPlugin: built-in %@ → %@", pluginName, ptr ? @"OK" : @"ECHEC");

    } else {
        // ── Étape 1 : cherche dans knownPluginList (cache scan) ──
        auto& kl = _engine->getPluginManager().knownPluginList;
        NSLog(@"[OBJ] addPlugin: knownPluginList contient %d entrées", kl.getNumTypes());

        juce::PluginDescription foundDesc;
        bool found = false;
        for (int i = 0; i < kl.getNumTypes(); i++) {
            auto* d = kl.getType(i);
            if (!d || d->pluginFormatName != fmtStr) continue;
            // Match on exact identifier, or on the 4-char code part after the last ':' or '/'
            // so that "aumf,FQ3p,FabF" matches "AudioUnit:aufx/FQ3p,FabF" and vice-versa.
            bool match = (d->fileOrIdentifier == idStr);
            if (!match && fmtStr == "AudioUnit") {
                juce::String bare = d->fileOrIdentifier.fromLastOccurrenceOf(":", false, false)
                                                       .fromLastOccurrenceOf("/", false, false);
                juce::String queryBare = idStr.fromLastOccurrenceOf(":", false, false)
                                              .fromLastOccurrenceOf("/", false, false);
                match = (bare == queryBare && !bare.isEmpty());
            }
            if (match) {
                foundDesc = *d;
                found = true;
                NSLog(@"[OBJ] addPlugin: description trouvée dans cache — name='%s' uid=%d id='%s'",
                      d->name.toRawUTF8(), d->uniqueId, d->fileOrIdentifier.toRawUTF8());
                break;
            }
        }

        // ── Étape 2 : obtenir la vraie PluginDescription via findAllTypesForFile ──
        //
        // Toujours nécessaire pour AU et VST3 :
        // • Notre scan AU calcule uid = subType ^ manufacturer ≠ uid JUCE réel.
        // • Notre scan VST3 calcule uid = hashCode(path) ≠ hash(classCID) attendu par
        //   findClassMatchingDescription → VST3ModuleHandle::create retourne invalide.
        // findAllTypesForFile AU = requête CoreAudio (pas de binaire). VST3 = chargement
        // binaire unique, acceptable lors d'un addPlugin ponctuel.
        bool needsRealDesc = [format isEqualToString:@"AudioUnit"] ||
                              [format isEqualToString:@"VST3"];
        if (needsRealDesc) {
            auto& fmgr = _engine->getPluginManager().pluginFormatManager;
            for (int fi = 0; fi < fmgr.getNumFormats(); fi++) {
                auto* fmt = fmgr.getFormat(fi);
                if (!fmt || fmt->getName() != fmtStr) continue;

                // AU: JUCE's findAllTypesForFile requires "AudioUnit:" prefix.
                juce::String searchId = (fmtStr == "AudioUnit" && !idStr.startsWith("AudioUnit:"))
                                        ? "AudioUnit:" + idStr : idStr;
                NSLog(@"[OBJ] addPlugin: findAllTypesForFile('%s')", searchId.toRawUTF8());
                juce::OwnedArray<juce::PluginDescription> realTypes;
                fmt->findAllTypesForFile(realTypes, searchId);
                NSLog(@"[OBJ] addPlugin: findAllTypesForFile → %d type(s)", realTypes.size());

                if (!realTypes.isEmpty()) {
                    // For shell VST3 with multiple sub-plugins, match by name.
                    foundDesc = *realTypes[0];
                    juce::String targetName(juce::String::fromUTF8([pluginName UTF8String]));
                    for (auto* rd : realTypes) {
                        if (rd->name == targetName) { foundDesc = *rd; break; }
                    }
                    NSLog(@"[OBJ] addPlugin: vrai uid=%d name='%s' id='%s'",
                          foundDesc.uniqueId, foundDesc.name.toRawUTF8(),
                          foundDesc.fileOrIdentifier.toRawUTF8());
                    kl.addType(foundDesc);
                    [self savePluginCache];
                    found = true;
                }
                break;
            }
        }

        // ── Étape 3 : fallback ultime si toujours rien ──
        if (!found || foundDesc.fileOrIdentifier.isEmpty()) {
            NSLog(@"[OBJ] addPlugin: '%@' — fallback description minimale", pluginName);
            foundDesc.name             = juce::String::fromUTF8([pluginName UTF8String]);
            foundDesc.pluginFormatName = fmtStr;
            foundDesc.fileOrIdentifier = idStr;
            foundDesc.uniqueId         = 0;
            foundDesc.numInputChannels  = 2;
            foundDesc.numOutputChannels = 2;
        }

        auto tree = te::ExternalPlugin::create(*_engine, foundDesc);
        ptr = clipPlugins->insertPlugin(tree, [self userInsertIndexForKey:key in:*clipPlugins]);
        NSLog(@"[OBJ] addPlugin: insertPlugin → %@", ptr ? @"entrée créée" : @"ECHEC");
    }
    }  // fin if (!ptr) — création standard

    if (!ptr) {
        NSLog(@"[OBJ] addPlugin: ECHEC FINAL pour '%@' [%@]", pluginName, format);
        return nil;
    }

    std::string pk([pluginKey UTF8String]);
    _pluginMap[pk] = ptr;

    // Log état initial — l'instance se charge souvent en asynchrone
    auto* ext = dynamic_cast<te::ExternalPlugin*>(ptr.get());
    if (ext) {
        bool instanceReady = (ext->getAudioPluginInstance() != nullptr);
        juce::String err   = ext->getLoadError();
        NSLog(@"[OBJ] addPlugin OK: '%@' — instance=%s loadError='%s'",
              pluginName,
              instanceReady ? "prête" : "en cours",
              err.toRawUTF8());
        if (!instanceReady) {
            NSLog(@"[OBJ] addPlugin: chargement asynchrone en cours (normal pour VST3/AU)");
        }
    } else {
        NSLog(@"[OBJ] addPlugin OK: '%@' (built-in, instance synchrone)", pluginName);
    }
    return pluginKey;
}

- (NSArray<NSDictionary*>*)getPluginParams:(NSString*)pluginKey {
    std::string pk([pluginKey UTF8String]);
    auto it = _pluginMap.find(pk);
    if (it == _pluginMap.end()) return @[];

    NSMutableArray* result = [NSMutableArray array];
    for (auto* param : it->second->getAutomatableParameters()) {  // NOLINT — copy intentional
        if (!param) continue;
        auto range = param->getValueRange();
        juce::String valStr = param->getCurrentValueAsString();
        [result addObject:@{
            @"name":          [NSString stringWithUTF8String:param->paramName.toRawUTF8()],
            @"paramID":       [NSString stringWithUTF8String:param->paramID.toRawUTF8()],
            @"value":         @(param->getCurrentValue()),
            @"minValue":      @(range.getStart()),
            @"maxValue":      @(range.getEnd()),
            @"valueAsString": [NSString stringWithUTF8String:valStr.toRawUTF8()]
        }];
    }
    return result;
}

- (void)setPluginParam:(NSString*)pluginKey index:(int)index value:(float)value {
    std::string pk([pluginKey UTF8String]);
    auto it = _pluginMap.find(pk);
    if (it == _pluginMap.end()) return;

    const auto params = it->second->getAutomatableParameters();
    if (index >= 0 && index < params.size())
        params[index]->setParameter(value, juce::sendNotification);
}

- (NSString* _Nullable)getPluginStateXML:(NSString*)pluginKey {
    std::string pk([pluginKey UTF8String]);
    auto it = _pluginMap.find(pk);
    if (it == _pluginMap.end()) return nil;

    // Pousse l'état courant (params built-in + chunk binaire externe) dans state — SAUF si le
    // plugin ne rend pas son état (AU pas encore initialisé) : Tracktion effacerait alors la
    // propriété `state`, et on renverrait un XML sans état qui écraserait le bon dans le modèle.
    // Dans ce cas on renvoie l'arbre tel quel : l'état déjà connu reste la meilleure réponse.
    if (objCanFlushPluginState(*it->second))
        it->second->flushPluginStateToValueTree();
    juce::String xml = it->second->state.toXmlString();  // local nommé → toRawUTF8 sûr
    if (xml.isEmpty()) return nil;
    return [NSString stringWithUTF8String:xml.toRawUTF8()];
}

// MARK: État des plugins externes — ré-affirmation différée
//
// Certains AudioUnits (Soundtoys : Devil-Loc…) REFUSENT `kAudioUnitProperty_ClassInfo` tant que
// l'unité n'a pas reçu `AudioUnitInitialize` (erreur -10867, en lecture comme en écriture). Or
// Tracktion restaure l'état d'un plugin dans `completePluginInstanceCreation`, donc AVANT
// `prepareToPlay` — le seul endroit où JUCE initialise l'AU. Le `setStateInformation` est alors un
// no-op SILENCIEUX (JUCE ignore le code de retour) et le plugin repart à ses réglages d'usine.
//
// Et le plugin n'est préparé qu'une fois le GRAPHE DE LECTURE alloué, ce qui n'arrivait qu'au
// premier play : un projet rouvert sans appuyer sur play gardait un Devil-Loc à zéro indéfiniment.
// (C'est le même verrou qui faisait planter son éditeur : son interface aussi présuppose une unité
// initialisée — clic sur un potard → déréférencement de NULL dans le plugin.)
//
// Corriger ça dans JUCE a été essayé et ANNULÉ. On reste donc côté objekat : on retient l'état
// voulu à la création, on force l'allocation du graphe, puis on relit l'état réel et on ré-applique
// UNE SEULE FOIS s'il diffère. Un plugin qui a correctement restauré sort de la file sans rien subir.

- (void)schedulePluginStateReassert:(te::Plugin::Ptr)plugin fromTree:(juce::ValueTree)tree {
    if (!plugin) return;
    auto* ext = dynamic_cast<te::ExternalPlugin*>(plugin.get());
    if (!ext) return;                                   // built-in Tracktion : jamais concerné

    juce::MemoryBlock desired = objDesiredStateFromTree(tree);
    if (desired.getSize() == 0) return;                 // plugin neuf : rien à restaurer

    juce::String name = ext->getName();                 // local nommé (getName renvoie par valeur)
    _pendingStateReasserts.push_back({ plugin, tree, std::move(desired), name, 0 });

    if (!_stateReassertTimer) {
        _stateReassertTimer = std::make_unique<OBJCallbackTimer>();
        __unsafe_unretained OBJEngineCore* rawSelf = self;  // self possède le timer → toujours vivant
        _stateReassertTimer->onTick = [rawSelf] { [rawSelf tickPluginStateReasserts]; };
    }
    if (!_stateReassertTimer->isTimerRunning())
        _stateReassertTimer->startTimer(kObjStateReassertIntervalMs);
}

- (void)tickPluginStateReasserts {
    // Rien ne prépare les plugins tant que le graphe de lecture n'est pas alloué — et il ne l'est
    // qu'au premier play. Tant qu'on attend un état, on force l'allocation : c'est exactement ce
    // que fait `play`, sans démarrer le transport.
    if (!_pendingStateReasserts.empty() && _edit && !_edit->getTransport().isPlayContextActive())
        _edit->getTransport().ensureContextAllocated();

    for (auto it = _pendingStateReasserts.begin(); it != _pendingStateReasserts.end(); ) {
        auto* ext = dynamic_cast<te::ExternalPlugin*>(it->plugin.get());
        if (!ext) { it = _pendingStateReasserts.erase(it); continue; }

        // Plugin retiré du rack entre-temps (deleteFromParent détache son state) : il ne sera
        // jamais préparé. On le lâche tout de suite — notre Ptr est sa dernière référence.
        if (!ext->state.getParent().isValid()) { it = _pendingStateReasserts.erase(it); continue; }

        auto* pi = ext->getAudioPluginInstance();
        juce::MemoryBlock now;
        if (pi) now = objReadInstanceState(*pi);

        // Pas d'instance (formats à chargement async) ou état illisible (= unité pas encore
        // initialisée, exactement le symptôme qui nous intéresse) : on repassera.
        if (!pi || now.getSize() == 0) {
            if (++it->ticks <= kObjStateReassertMaxTicks) { ++it; continue; }
            NSLog(@"[OBJ] état plugin : '%s' n'a jamais rendu son état — abandon",
                  it->name.toRawUTF8());
            it = _pendingStateReasserts.erase(it);
            continue;
        }

        if (now != it->desired) {
            // La restauration de Tracktion n'a pas pris : on la refait maintenant que l'instance
            // est préparée. Une seule tentative, quel qu'en soit le résultat — pas de boucle qui
            // risquerait d'écraser un réglage fait entre-temps par l'utilisateur.
            ext->restorePluginStateFromValueTree(it->savedTree);
            juce::MemoryBlock after = objReadInstanceState(*pi);
            NSLog(@"[OBJ] état plugin ré-appliqué : %s → %s", it->name.toRawUTF8(),
                  (after == it->desired) ? "OK" : "toujours différent (état non bit-stable ?)");
        }
        it = _pendingStateReasserts.erase(it);
    }
    if (_pendingStateReasserts.empty() && _stateReassertTimer)
        _stateReassertTimer->stopTimer();
}

#pragma mark - Consigne de plugins

// Met en consigne tous les plugins EXTERNES de la chaîne d'un objet, juste avant qu'il ne quitte
// le graphe. @see OBJParkedPlugin.
- (void)parkPluginsForObjectID:(NSString*)uuid {
    te::PluginList* pl = [self userPluginListForKey:std::string([uuid UTF8String])];
    if (!pl) return;
    for (auto* p : *pl)
        if (p) [self parkPlugin:*p];
}

- (void)parkPlugin:(te::Plugin&)plugin {
    auto* ext = dynamic_cast<te::ExternalPlugin*>(&plugin);
    if (!ext) return;   // un plugin interne se reconstruit pour rien du tout

    // On lit le chunk SUR L'ARBRE, sans flusher. Deux raisons, et la seconde est la vraie :
    //   • flusher coûterait un getStateInformation par plugin retiré ;
    //   • surtout, l'arbre porte le chunk que l'application a en modèle — c'est LUI qu'elle
    //     redemandera. Le relire sur l'instance donnerait un chunk qui, pour un AU dont l'état
    //     n'est pas bit-stable (UADx Opal, mesuré), ne coïnciderait avec rien.
    juce::MemoryBlock st = objDesiredStateFromTree(ext->state);
    if (st.getSize() == 0) return;   // sans état, rien à apparier

    [self sweepPluginParking];
    _pluginParking.push_back({ te::Plugin::Ptr(ext), objPluginTreeTypeKey(ext->state),
                               std::move(st),
                               juce::Time::getMillisecondCounterHiRes() + kObjPluginParkingTtlMs });

    if (!_pluginParkingTimer) {
        _pluginParkingTimer = std::make_unique<OBJCallbackTimer>();
        __unsafe_unretained OBJEngineCore* rawSelf = self;
        _pluginParkingTimer->onTick = [rawSelf] { [rawSelf sweepPluginParking]; };
    }
    if (!_pluginParkingTimer->isTimerRunning())
        _pluginParkingTimer->startTimer(kObjPluginParkingSweepMs);
}

// Reprend — et RETIRE de la consigne — un plugin de même modèle et de même état que l'arbre
// demandé. Nil si rien ne correspond : l'appelant charge alors normalement.
- (te::Plugin::Ptr)takeParkedPluginMatching:(const juce::ValueTree&)wantedTree {
    [self sweepPluginParking];
    const std::string typeKey = objPluginTreeTypeKey(wantedTree);
    const juce::MemoryBlock wanted = objDesiredStateFromTree(wantedTree);
    if (wanted.getSize() == 0) return nullptr;

    int sameTypeOtherState = 0;
    for (auto it = _pluginParking.begin(); it != _pluginParking.end(); ++it) {
        if (it->typeKey != typeKey) continue;
        if (it->state != wanted) { ++sameTypeOtherState; continue; }
        te::Plugin::Ptr p = it->plugin;
        _pluginParking.erase(it);   // un exemplaire consigné ne sert qu'UNE fois
        return p;
    }

    // Journalisé exprès : c'est LA mesure qui dira s'il faut aller plus loin. Un exemplaire du
    // bon modèle mais d'état différent pourrait être repris quand même, en lui ré-appliquant
    // l'état voulu — moins cher qu'un chargement, mais il faudrait alors recopier proprement le
    // reste de l'arbre (params, macro-paramètres, assignations de modifieurs), et ça ne se fait
    // pas à l'aveugle. Tant que ce compteur reste à zéro, la question ne se pose pas.
    if (sameTypeOtherState > 0)
        NSLog(@"[PERF] consigne : %d exemplaire(s) du bon modèle mais d'état différent — "
              @"chargement complet", sameTypeOtherState);
    return nullptr;
}

// Relâche les plugins dont le délai est passé. Lâcher le Ptr suffit : le PluginCache ramasse
// ceux que plus personne ne tient, et c'est là que l'instance AU se ferme réellement.
- (void)sweepPluginParking {
    const double now = juce::Time::getMillisecondCounterHiRes();
    const size_t before = _pluginParking.size();
    _pluginParking.erase(std::remove_if(_pluginParking.begin(), _pluginParking.end(),
                                        [now](const OBJParkedPlugin& e) {
                                            return e.plugin == nullptr || e.deadlineMs <= now;
                                        }),
                         _pluginParking.end());
    if (_pluginParking.empty() && _pluginParkingTimer && _pluginParkingTimer->isTimerRunning())
        _pluginParkingTimer->stopTimer();
    if (before != _pluginParking.size())
        NSLog(@"[OBJ] consigne : %lu plugin(s) relâché(s), %lu en attente",
              (unsigned long)(before - _pluginParking.size()), (unsigned long)_pluginParking.size());
}

- (void)forcePluginStatesForRenderClone:(te::Edit&)clone {
    auto& dm = _engine->getDeviceManager();
    const double sr = dm.getSampleRate() > 0 ? dm.getSampleRate() : 44100.0;
    const int    bs = dm.getBlockSize()  > 0 ? dm.getBlockSize()  : 512;

    int reasserted = 0;

    // Balayage PROFOND, comme le flush côté vivant : sans lui, l'AU d'un objet CONTENU dans le
    // groupe qu'on rend ne serait jamais ré-affirmé et cuirait à ses réglages d'usine.
    for (auto* p : objAllPluginsDeep(clone)) {
        auto* ext = dynamic_cast<te::ExternalPlugin*>(p);
        if (!ext) continue;
        juce::MemoryBlock desired = objDesiredStateFromTree(ext->state);
        if (desired.getSize() == 0) continue;

        auto* pi = ext->getAudioPluginInstance();
        if (!pi) continue;
        juce::MemoryBlock before = objReadInstanceState(*pi);
        if (before == desired) continue;   // déjà bon → on n'y touche pas

        // Certains AU ne rendent JAMAIS un état comparable au chunk sauvé (UADx Opal, mesuré) :
        // la comparaison ci-dessus les déclenche à chaque bake, pour 200 à 400 ms de
        // AudioUnitInitialize. On ne renonce pas sur cette seule présomption — on mesure : si la
        // ré-affirmation ne modifie EN RIEN l'état de l'instance, elle est inerte pour ce plugin
        // et on ne la retente plus. Une ré-affirmation qui produit un effet, elle, est toujours
        // faite. Même esprit que le « une seule tentative » du chemin live.
        const std::string key = objPluginTypeKey(*ext);
        if (_inertStateReasserts.count(key)) continue;

        // prepareToPlay force AudioUnitInitialize : l'unité accepte alors son état. Le renderer
        // rappellera prepareToPlay (releaseResources + init) — l'état survit à ce cycle.
        const double tP = juce::Time::getMillisecondCounterHiRes();
        pi->prepareToPlay(sr, bs);
        ext->restorePluginStateFromValueTree(ext->state);
        const juce::MemoryBlock after = objReadInstanceState(*pi);
        const double ms = juce::Time::getMillisecondCounterHiRes() - tP;
        ++reasserted;

        juce::String name = ext->getName();
        if (after == before) {
            _inertStateReasserts.insert(key);
            NSLog(@"[OBJ] rendu : ré-affirmation SANS EFFET sur %s (%.0f ms) — plus retentée "
                  @"pour ce plugin", name.toRawUTF8(), ms);
        } else {
            NSLog(@"[OBJ] rendu : état ré-appliqué sur le clone pour %s (%.0f ms)",
                  name.toRawUTF8(), ms);
        }
    }

    if (reasserted > 0)
        NSLog(@"[PERF] bake : %d AU ré-initialisé(s) sur le clone", reasserted);
}

// MARK: Écoute des params (objet sonore ouvert)

- (void)beginObjectEditParamWatch:(NSArray<NSString*>*)objectKeys {
    _objectEditMirrors.clear();
    _objectEditProcWatchers.clear();
    _objectEditPlugins.clear();
    __unsafe_unretained OBJEngineCore* weakSelf = self;  // self possède les mirrors → toujours vivant
    for (NSString* k in objectKeys) {
        std::string key([k UTF8String]);
        te::PluginList* pl = [self userPluginListForKey:key];
        if (!pl) continue;
        for (auto* p : *pl) {
            if (!p) continue;
            // Plugins système : fader, fenêtre/fade et VU. Le VU change de valeur à chaque bloc
            // audio en lecture → l'inclure spammerait le preview en boucle.
            if (dynamic_cast<te::ObjGainPlugin*>(p)
                || dynamic_cast<te::ObjWindowFadePlugin*>(p)
                || dynamic_cast<te::LevelMeterPlugin*>(p))
                continue;
            te::Plugin::Ptr ptr(p);
            _objectEditPlugins.push_back(ptr);
            _objectEditMirrors.push_back(std::make_unique<OBJParamMirror>(ptr,
                [weakSelf](int, float) {
                    if (weakSelf->_onObjectEditParamChanged) weakSelf->_onObjectEditParamChanged();
                }));
            // Plugin externe : doubler d'un listener processor (capte la GUI native AU/VST).
            if (auto* ext = dynamic_cast<te::ExternalPlugin*>(p))
                if (auto* inst = ext->getAudioPluginInstance())
                    _objectEditProcWatchers.push_back(std::make_unique<OBJProcessorWatcher>(inst,
                        [weakSelf] {
                            if (weakSelf->_onObjectEditParamChanged) weakSelf->_onObjectEditParamChanged();
                        }));
        }
    }
    NSLog(@"[OBJ] beginObjectEditParamWatch : %lu plugin(s) surveillé(s), %lu externe(s)",
          (unsigned long)_objectEditPlugins.size(),
          (unsigned long)_objectEditProcWatchers.size());
}

- (void)endObjectEditParamWatch {
    _objectEditMirrors.clear();      // ~OBJParamMirror retire les listeners (params encore vivants)
    _objectEditProcWatchers.clear(); // ~OBJProcessorWatcher retire les listeners (processors vivants)
    _objectEditPlugins.clear();
}

- (void)flushObjectEditPluginStates {
    for (auto& p : _objectEditPlugins)
        if (p) p->flushPluginStateToValueTree();
}

// MARK: Dernier paramètre touché (éditeur ouvert)

// @see la déclaration dans OBJEngineCore.h pour le pourquoi de la portée.
- (void)beginPluginParamTouchWatch:(NSString*)pluginKey {
    if (!pluginKey) return;
    std::string pk([pluginKey UTF8String]);
    if (_paramTouchWatches.count(pk)) return;          // idempotent (ré-ouverture au premier plan)
    auto it = _pluginMap.find(pk);
    if (it == _pluginMap.end()) return;                // instance pas (encore) créée

    __unsafe_unretained OBJEngineCore* weakSelf = self;  // self possède les watches → toujours vivant
    OBJTouchWatch w;
    w.plugin = it->second;
    w.mirror = std::make_unique<OBJParamMirror>(it->second,
        [weakSelf, pk](int index, float) { [weakSelf reportParamTouch:pk index:index]; },
        // La SAISIE compte autant que la modification : attraper un knob suffit à désigner le
        // paramètre, sans avoir à le dérégler d'abord pour qu'on le remarque.
        [weakSelf, pk](int index)         { [weakSelf reportParamTouch:pk index:index]; });
    _paramTouchWatches[pk] = std::move(w);
}

- (void)endPluginParamTouchWatch:(NSString*)pluginKey {
    if (!pluginKey) return;
    // ~OBJTouchWatch : ~OBJParamMirror retire les écouteurs (params encore vivants), puis la Ptr
    // est rendue — l'ordre de destruction des membres est l'inverse de leur déclaration.
    _paramTouchWatches.erase(std::string([pluginKey UTF8String]));
}

// Traduit un changement de valeur en « paramètre touché », ou l'écarte.
- (void)reportParamTouch:(const std::string&)pk index:(int)index {
    if (!_onPluginParamTouched) return;
    auto wit = _paramTouchWatches.find(pk);
    if (wit == _paramTouchWatches.end() || !wit->second.plugin) return;

    const auto params = wit->second.plugin->getAutomatableParameters();  // NOLINT — copy intentional
    if (index < 0 || index >= params.size() || !params[index]) return;
    te::AutomatableParameter* param = params[index];

    // Un paramètre DÉJÀ automatisé bouge tout seul en lecture : le signaler le remettrait en tête
    // à chaque bloc audio, pour proposer une ligne qu'il a déjà. On l'écarte à la source.
    if (param->getCurve().getNumPoints() > 0) return;

    // Valeur ramenée en 0…1 LINÉAIREMENT sur la plage annoncée — la convention du modèle
    // (@see ParamRef.valueRange), et celle que `getPluginParams:` emploie déjà pour ses
    // min/max. Passer par `getCurrentNormalisedValue` (qui suit le skew) donnerait un autre
    // chiffre que la dénormalisation faite côté Swift.
    const auto range = param->getValueRange();
    const float span = range.getLength();
    const float v01  = span > 0.0f
        ? juce::jlimit(0.0f, 1.0f, (param->getCurrentValue() - range.getStart()) / span)
        : 0.0f;

    const juce::String pid = param->paramID;   // local nommé → toRawUTF8 sûr
    NSString* nsKey = [NSString stringWithUTF8String:pk.c_str()];
    NSString* nsPID = [NSString stringWithUTF8String:pid.toRawUTF8()];
    _onPluginParamTouched(nsKey, nsPID, v01);
}

// MARK: LINK d'instances

- (void)setPluginLinkGroup:(NSString*)pluginKey groupID:(NSString*)groupID {
    std::string pk([pluginKey UTF8String]);
    std::string gid([groupID UTF8String]);
    auto it = _pluginMap.find(pk);
    if (it == _pluginMap.end()) return;  // instance pas (encore) créée
    _linkGroup[pk] = gid;
    if (_mirrors.find(pk) == _mirrors.end()) {
        __unsafe_unretained OBJEngineCore* weakSelf = self;  // self possède _mirrors → toujours vivant
        std::string pkCopy = pk;
        _mirrors[pk] = std::make_unique<OBJParamMirror>(it->second,
            [weakSelf, pkCopy](int index, float value) {
                [weakSelf propagateLinkedParamFromKey:pkCopy index:index value:value];
            });
    }
}

- (void)clearPluginLinkGroup:(NSString*)pluginKey {
    std::string pk([pluginKey UTF8String]);
    [self teardownPluginLink:pk];
}

// @see la déclaration (OBJEngineCore.h) pour le pourquoi de l'ordre copie-puis-armement.
- (void)relinkPluginAdoptingGroup:(NSString*)pluginKey groupID:(NSString*)groupID {
    std::string pk([pluginKey UTF8String]);
    std::string gid([groupID UTF8String]);
    auto it = _pluginMap.find(pk);
    if (it == _pluginMap.end()) return;   // instance pas (encore) créée

    // Un donneur = n'importe quel membre ENCORE actif du groupe. Ses valeurs courantes font foi.
    te::Plugin::Ptr donor;
    for (auto& kv : _linkGroup) {
        if (kv.second != gid || kv.first == pk) continue;
        auto dit = _pluginMap.find(kv.first);
        if (dit != _pluginMap.end()) { donor = dit->second; break; }
    }

    if (donor != nullptr) {
        const auto from = donor->getAutomatableParameters();     // NOLINT — copy intentional
        const auto to   = it->second->getAutomatableParameters();// NOLINT
        // Appariement par index, comme la propagation : ce sont des instances du MÊME plugin.
        const int n = juce::jmin(from.size(), to.size());
        for (int i = 0; i < n; ++i)
            if (from[i] != nullptr && to[i] != nullptr)
                to[i]->setParameter(from[i]->getCurrentValue(), juce::sendNotification);
    }

    // Armement APRÈS la copie : les notifications ci-dessus ne repartent donc pas vers le groupe.
    [self setPluginLinkGroup:pluginKey groupID:groupID];
}

// Retire un plugin de toute structure de link (listeners + appartenance au groupe).
// Nettoie la valeur canonique du groupe s'il ne reste plus aucun membre.
- (void)teardownPluginLink:(const std::string&)pk {
    _mirrors.erase(pk);  // ~OBJParamMirror retire les listeners (params encore vivants)
    auto git = _linkGroup.find(pk);
    if (git == _linkGroup.end()) return;
    std::string group = git->second;
    _linkGroup.erase(git);
    bool stillUsed = false;
    for (auto& kv : _linkGroup)
        if (kv.second == group) { stillUsed = true; break; }
    if (!stillUsed) _groupCanonical.erase(group);
}

// Vrai tant que l'état d'un plugin fraîchement créé n'a pas été ré-affirmé : son instance est
// encore, potentiellement, à ses réglages d'USINE. @see schedulePluginStateReassert
- (BOOL)isPluginStateSettling:(const std::string&)pk {
    auto it = _pluginMap.find(pk);
    if (it == _pluginMap.end()) return NO;
    for (auto& pending : _pendingStateReasserts)
        if (pending.plugin == it->second) return YES;
    return NO;
}

// Répercute un changement de paramètre vers les autres instances du même groupe.
// Garde anti-boucle : on ignore un changement dont la valeur ≈ valeur canonique du
// groupe (= un écho de notre propre écriture, qui arrive de façon asynchrone).
- (void)propagateLinkedParamFromKey:(const std::string&)pk index:(int)index value:(float)value {
    auto git = _linkGroup.find(pk);
    if (git == _linkGroup.end()) return;
    const std::string group = git->second;

    // Une instance qui vient de naître traverse ses réglages d'usine avant que son état ne
    // soit (ré)appliqué — c'est tout l'objet de la ré-affirmation différée. Les notifications
    // de paramètre qu'elle émet pendant ce laps ne disent pas ce que l'utilisateur a réglé :
    // les diffuser écrasait les autres membres du groupe. Concrètement, dupliquer un objet
    // (un aux dans un groupe, par exemple) liait la copie à l'original par défaut, puis la
    // copie encore vierge remettait l'ORIGINAL à zéro pendant qu'elle-même finissait par
    // restaurer son état — l'original perdait son réglage, la copie l'avait.
    if ([self isPluginStateSettling:pk]) return;

    auto& canon = _groupCanonical[group];
    auto cit = canon.find(index);
    if (cit != canon.end() && std::abs(cit->second - value) <= 1.0e-6f) return;  // écho
    canon[index] = value;

    for (auto& kv : _linkGroup) {
        if (kv.second != group || kv.first == pk) continue;
        auto pit = _pluginMap.find(kv.first);
        if (pit == _pluginMap.end()) continue;
        const auto params = pit->second->getAutomatableParameters();  // NOLINT
        if (index >= 0 && index < params.size())
            params[index]->setParameter(value, juce::sendNotification);
    }
}

- (void)removePlugin:(NSString*)pluginKey fromObjectID:(NSString*)uuid {
    std::string pk([pluginKey UTF8String]);
    auto it = _pluginMap.find(pk);
    if (it == _pluginMap.end()) return;
    [self teardownPluginLink:pk];  // retire les listeners AVANT de détruire le plugin
    _editorWindows.erase(pk);   // ferme l'éditeur si ouvert
    it->second->deleteFromParent();
    _pluginMap.erase(it);
    NSLog(@"[OBJ] removePlugin: %@ from %@", pluginKey, uuid);
}

- (void)setPlugin:(NSString*)pluginKey enabled:(BOOL)enabled forObjectID:(NSString*)uuid {
    std::string pk([pluginKey UTF8String]);
    auto it = _pluginMap.find(pk);
    if (it == _pluginMap.end()) return;
    it->second->setEnabled(enabled);
}

- (void)movePlugin:(NSString*)pluginKey toIndex:(int)toIndex forObjectID:(NSString*)uuid {
    std::string pk([pluginKey UTF8String]);
    auto it = _pluginMap.find(pk);
    if (it == _pluginMap.end()) return;
    auto pluginState = it->second->state;
    auto parentState = pluginState.getParent();
    if (!parentState.isValid()) return;
    int fromIndex = parentState.indexOf(pluginState);
    if (fromIndex < 0 || fromIndex == toIndex) return;
    parentState.moveChild(fromIndex, toIndex, nullptr);
    // Déclenche un rebuild du graphe audio si la lecture est active.
    // (Sans ça, objectOrderChanged() dans PluginList est un no-op et le DSP garde l'ancien ordre.)
    if (_edit) _edit->restartPlayback();
}

- (BOOL)pluginHasEditor:(NSString*)pluginKey {
    std::string pk([pluginKey UTF8String]);
    auto it = _pluginMap.find(pk);
    if (it == _pluginMap.end()) return NO;
    auto* ext = dynamic_cast<te::ExternalPlugin*>(it->second.get());
    if (!ext) return NO;
    auto* instance = ext->getAudioPluginInstance();
    return instance ? (BOOL)instance->hasEditor() : NO;
}

- (void)_doOpenPluginEditor:(NSString*)pluginKey attempt:(int)attempt colorHex:(NSInteger)colorHex {
    std::string pk([pluginKey UTF8String]);

    auto winIt = _editorWindows.find(pk);
    if (winIt != _editorWindows.end() && winIt->second) {
        winIt->second->toFront(true);
        return;
    }

    auto mapIt = _pluginMap.find(pk);
    if (mapIt == _pluginMap.end()) return;

    auto* ext = dynamic_cast<te::ExternalPlugin*>(mapIt->second.get());
    if (!ext) return;  // built-in → éditeur SwiftUI géré côté Swift

    // Le plugin doit être PRÉPARÉ avant qu'on ouvre son interface. Certains AU (Soundtoys :
    // Devil-Loc) construisent leur GUI sur des internes qui n'existent qu'après
    // AudioUnitInitialize : ouvrir l'éditeur avant ça donne une fenêtre qui déréférence NULL au
    // premier clic (crash dans le code du plugin, pas dans le nôtre). Or rien ne prépare les
    // plugins tant que le graphe de lecture n'est pas alloué — ce qui n'arrivait qu'au premier
    // play. On l'alloue donc ici, comme le ferait `play`, sans démarrer le transport.
    if (_edit && !_edit->getTransport().isPlayContextActive())
        _edit->getTransport().ensureContextAllocated();

    // Le plugin se charge de façon asynchrone : attendre que l'instance soit prête
    if (!ext->getAudioPluginInstance()) {
        if (attempt >= 20) {
            NSLog(@"[OBJ] openPluginEditor: timeout — instance jamais chargée pour %@", pluginKey);
            return;
        }
        NSLog(@"[OBJ] openPluginEditor: instance en cours de chargement, retry %d/20…", attempt + 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            [self _doOpenPluginEditor:pluginKey attempt:attempt + 1 colorHex:colorHex];
        });
        return;
    }

    auto* instance = ext->getAudioPluginInstance();
    if (!instance) {
        NSLog(@"[OBJ] openPluginEditor: instance nullptr après chargement pour %@", pluginKey);
        return;
    }

    if (!instance->hasEditor()) {
        NSLog(@"[OBJ] openPluginEditor: plugin sans éditeur GUI (%s)", instance->getName().toRawUTF8());
        return;
    }

    auto* editor = instance->createEditorIfNeeded();
    if (!editor) {
        NSLog(@"[OBJ] openPluginEditor: createEditorIfNeeded → nil");
        return;
    }

    juce::String title = instance->getName();
    OBJEngineCore* rawSelf = self;
    const bool floating = _pluginEditorsFloating;
    juce::Colour accent((juce::uint8)((colorHex >> 16) & 0xFF),
                        (juce::uint8)((colorHex >> 8) & 0xFF),
                        (juce::uint8)(colorHex & 0xFF));
    auto* win = new OBJPluginEditorWindow(title, editor, [rawSelf, pk] {
        // « delete this » indirect (erase détruit la fenêtre + ce lambda + pk) :
        // on sort tout ce dont on a besoin sur la pile AVANT l'erase.
        OBJEngineCore* engineRef = rawSelf;
        std::string keyCopy = pk;
        NSString* nsKey = [NSString stringWithUTF8String:keyCopy.c_str()];
        engineRef->_editorWindows.erase(keyCopy);
        if (engineRef.onEditorVisibilityChanged) engineRef.onEditorVisibilityChanged(nsKey, NO);
    }, floating, accent);
    _editorWindows[pk].reset(win);
    if (self.onEditorVisibilityChanged) self.onEditorVisibilityChanged(pluginKey, YES);
    NSLog(@"[OBJ] openPluginEditor: '%s' ouvert", title.toRawUTF8());
}

- (void)openPluginEditor:(NSString*)pluginKey colorHex:(NSInteger)colorHex {
    [self _doOpenPluginEditor:pluginKey attempt:0 colorHex:colorHex];
}

- (void)closePluginEditor:(NSString*)pluginKey {
    std::string pk([pluginKey UTF8String]);
    if (_editorWindows.erase(pk) > 0 && self.onEditorVisibilityChanged)
        self.onEditorVisibilityChanged(pluginKey, NO);
}

- (BOOL)isPluginEditorOpen:(NSString*)pluginKey {
    std::string pk([pluginKey UTF8String]);
    auto it = _editorWindows.find(pk);
    return it != _editorWindows.end() && it->second != nullptr;
}

- (int)pluginInstanceState:(NSString*)pluginKey {
    std::string pk([pluginKey UTF8String]);
    auto it = _pluginMap.find(pk);
    if (it == _pluginMap.end()) return 0;

    auto* ext = dynamic_cast<te::ExternalPlugin*>(it->second.get());
    if (!ext) return 2;  // built-in = toujours prêt

    juce::String err = ext->getLoadError();
    if (!err.isEmpty()) return 3;  // erreur

    return ext->getAudioPluginInstance() ? 2 : 1;  // prêt ou en chargement
}

- (void)diagnosePlugin:(NSString*)identifier format:(NSString*)format name:(NSString*)name {
    auto& fmgr = _engine->getPluginManager().pluginFormatManager;
    juce::String idStr(juce::String::fromUTF8([identifier UTF8String]));
    juce::String fmtStr(juce::String::fromUTF8([format UTF8String]));

    NSLog(@"[DIAG-PLUG] ══════════════════════════════════════");
    NSLog(@"[DIAG-PLUG] Plugin : '%@' [%@] id='%@'", name, format, identifier);
    NSLog(@"[DIAG-PLUG] ──────────────────────────────────────");

    // ── Q1 : formats enregistrés ──────────────────────────────────────────
    NSLog(@"[DIAG-PLUG] Q1 — Formats dans PluginFormatManager : %d", fmgr.getNumFormats());
    bool formatFound = false;
    for (int i = 0; i < fmgr.getNumFormats(); i++) {
        auto* fmt = fmgr.getFormat(i);
        if (!fmt) continue;
        bool match = (fmt->getName() == fmtStr);
        NSLog(@"[DIAG-PLUG]   [%d] '%s' %s", i, fmt->getName().toRawUTF8(), match ? "← CHERCHÉ ✓" : "");
        if (match) formatFound = true;
    }
    if (!formatFound)
        NSLog(@"[DIAG-PLUG]   ⚠️  Format '%@' ABSENT du PluginFormatManager ← cause probable", format);

    // ── Q2 : findAllTypesForFile ──────────────────────────────────────────
    NSLog(@"[DIAG-PLUG] Q2 — findAllTypesForFile('%@')", identifier);
    juce::PluginDescription bestDesc;
    bool gotDesc = false;
    for (int i = 0; i < fmgr.getNumFormats(); i++) {
        auto* fmt = fmgr.getFormat(i);
        if (!fmt || fmt->getName() != fmtStr) continue;
        juce::OwnedArray<juce::PluginDescription> types;
        fmt->findAllTypesForFile(types, idStr);
        NSLog(@"[DIAG-PLUG]   → %d type(s)", types.size());
        for (auto* d : types) {
            NSLog(@"[DIAG-PLUG]     name='%s' uid=%d fmt='%s' id='%s'",
                  d->name.toRawUTF8(), d->uniqueId,
                  d->pluginFormatName.toRawUTF8(),
                  d->fileOrIdentifier.toRawUTF8());
            if (!gotDesc) { bestDesc = *d; gotDesc = true; }
        }
        if (types.isEmpty())
            NSLog(@"[DIAG-PLUG]   ⚠️  Aucun type retourné — identifiant non reconnu par ce format");
        break;
    }

    // ── Q3 : ValueTree produit par ExternalPlugin::create ────────────────
    NSLog(@"[DIAG-PLUG] Q3 — ValueTree ExternalPlugin::create");
    {
        juce::PluginDescription descForTree = gotDesc ? bestDesc : juce::PluginDescription{};
        if (!gotDesc) {
            descForTree.name             = juce::String::fromUTF8([name UTF8String]);
            descForTree.pluginFormatName = fmtStr;
            descForTree.fileOrIdentifier = idStr;
        }
        auto tree = te::ExternalPlugin::create(*_engine, descForTree);
        auto xmlStr = tree.toXmlString();
        NSLog(@"[DIAG-PLUG]   ValueTree:\n%s", xmlStr.toRawUTF8());
    }

    // ── Q4 : createPluginInstance direct ─────────────────────────────────
    NSLog(@"[DIAG-PLUG] Q4 — createPluginInstance direct (sans Tracktion)");
    if (gotDesc) {
        juce::String errMsg;
        auto instance = fmgr.createPluginInstance(bestDesc, 44100.0, 512, errMsg);
        if (instance) {
            NSLog(@"[DIAG-PLUG]   ✓ Instance créée directement : '%s' hasEditor=%s",
                  instance->getName().toRawUTF8(),
                  instance->hasEditor() ? "OUI" : "NON");
        } else {
            NSLog(@"[DIAG-PLUG]   ✗ Échec createPluginInstance : '%s'", errMsg.toRawUTF8());
        }
    } else {
        NSLog(@"[DIAG-PLUG]   — ignoré (pas de description valide depuis Q2)");
    }

    NSLog(@"[DIAG-PLUG] ══════════════════════════════════════");
}

- (void)diagnosVST3Load:(NSString*)bundlePath {
    NSLog(@"[DIAG-VST3] ── Diagnostic dlopen pour : %@", bundlePath);

    // 1. Bundle présent ?
    BOOL isDir = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:bundlePath isDirectory:&isDir];
    NSLog(@"[DIAG-VST3] Bundle existe=%@ isDir=%@", exists ? @"OUI" : @"NON", isDir ? @"OUI" : @"NON");
    if (!exists) return;

    // 2. Trouver le binaire dans Contents/MacOS/
    NSString* macosDir = [bundlePath stringByAppendingPathComponent:@"Contents/MacOS"];
    NSArray* binaries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:macosDir error:nil];
    NSLog(@"[DIAG-VST3] Contents/MacOS → %@", binaries ?: @"(dossier introuvable)");

    NSString* binaryPath = nil;
    if (binaries.count > 0) {
        binaryPath = [macosDir stringByAppendingPathComponent:binaries.firstObject];
    }

    if (!binaryPath) {
        NSLog(@"[DIAG-VST3] Aucun binaire trouvé dans Contents/MacOS");
        return;
    }

    // 3. Architecture du binaire
    NSTask* task = [NSTask new];
    task.launchPath = @"/usr/bin/file";
    task.arguments = @[binaryPath];
    NSPipe* pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError  = pipe;
    @try {
        [task launch];
        [task waitUntilExit];
        NSData* data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString* output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSLog(@"[DIAG-VST3] file: %@", [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    } @catch (NSException* e) {
        NSLog(@"[DIAG-VST3] Impossible d'exécuter 'file': %@", e.reason);
    }

    // 4. Tentative dlopen directe
    dlerror(); // clear
    void* handle = dlopen([binaryPath UTF8String], RTLD_LAZY | RTLD_LOCAL);
    if (handle) {
        NSLog(@"[DIAG-VST3] dlopen réussi ✓ — le binaire se charge correctement");
        // Vérifier la présence du symbole GetPluginFactory (requis VST3)
        void* factory = dlsym(handle, "GetPluginFactory");
        NSLog(@"[DIAG-VST3] GetPluginFactory=%s", factory ? "TROUVÉ ✓" : "ABSENT ✗");
        dlclose(handle);
    } else {
        const char* err = dlerror();
        NSLog(@"[DIAG-VST3] dlopen ÉCHEC ✗ — %s", err ? err : "(erreur inconnue)");
    }
    NSLog(@"[DIAG-VST3] ─────────────────────────────────────");
}

- (NSString* _Nullable)pluginLoadError:(NSString*)pluginKey {
    std::string pk([pluginKey UTF8String]);
    auto it = _pluginMap.find(pk);
    if (it == _pluginMap.end()) return nil;

    auto* ext = dynamic_cast<te::ExternalPlugin*>(it->second.get());
    if (!ext) return nil;

    juce::String err = ext->getLoadError();
    if (err.isEmpty()) return nil;
    return [NSString stringWithUTF8String:err.toRawUTF8()];
}

// MARK: - ÉTAPE 2 : compilateur déclaratif

// Résout la PLUGIN ValueTree pour un descripteur d'inspecteur (même logique que -addPlugin:
// mais SANS insertion). Keeper : le compilateur s'en sert pour créer les Plugin::Ptr du rack.
- (juce::ValueTree)resolvedPluginTreeForInfo:(NSDictionary*)pluginInfo
                                    stateXML:(NSString* _Nullable)stateXML {
    NSString* identifier = pluginInfo[@"identifier"];
    NSString* format     = pluginInfo[@"format"];
    NSString* pluginName = pluginInfo[@"name"] ?: @"?";

    // TRACE : le modèle demande la RESTITUTION plutôt que le plugin. C'est le même slot, à la
    // même place dans la chaîne, avec la même clé — seule change la nature de ce qu'on y met.
    // Passer par ici plutôt que par une méthode d'installation à part, c'est ce qui fait que
    // l'ordre, le bypass, le déplacement et la persistance marchent sans une ligne de plus.
    // Le fichier lui-même se charge après l'insertion, dans compileSeries: — un constructeur de
    // plugin n'a rien à faire d'un accès disque. @see docs/objekat-capture-trace.md
    if (NSString* tracePath = pluginInfo[@"tracePath"]; tracePath.length > 0) {
        juce::ValueTree v = te::ObjTracePlaybackPlugin::create();
        v.setProperty(juce::Identifier("tracePath"),
                      juce::String::fromUTF8([tracePath UTF8String]), nullptr);
        v.setProperty(juce::Identifier("traceName"),
                      juce::String::fromUTF8([pluginName UTF8String]), nullptr);
        return v;
    }

    if (!identifier || !format) return {};

    juce::String fmtStr(juce::String::fromUTF8([format UTF8String]));
    juce::String idStr(juce::String::fromUTF8([identifier UTF8String]));

    // Restauration directe depuis l'état sauvé (round-trip Tracktion).
    if (stateXML.length > 0) {
        if (auto xml = juce::parseXML(juce::String::fromUTF8([stateXML UTF8String]))) {
            juce::ValueTree saved = juce::ValueTree::fromXml(*xml);
            [self freshenItemIDsInTree:saved];   // sinon on vole son id à l'instance source
            if (saved.isValid() && saved.hasType(juce::Identifier("PLUGIN")))
                return saved;
        }
    }

    if ([format isEqualToString:@"VST3"]) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:identifier]) {
            NSLog(@"[RACK] resolve: bundle VST3 introuvable: %@", identifier);
            return {};
        }
    }

    if ([format isEqualToString:@"TracktionInternal"]) {
        juce::ValueTree pt("PLUGIN");
        pt.setProperty("type", idStr, nullptr);
        return pt;
    }

    // External (AU/VST3) : cache knownPluginList → findAllTypesForFile → fallback minimal.
    auto& kl = _engine->getPluginManager().knownPluginList;
    juce::PluginDescription foundDesc;
    bool found = false;
    for (int i = 0; i < kl.getNumTypes(); i++) {
        auto* d = kl.getType(i);
        if (!d || d->pluginFormatName != fmtStr) continue;
        bool match = (d->fileOrIdentifier == idStr);
        if (!match && fmtStr == "AudioUnit") {
            juce::String bare = d->fileOrIdentifier.fromLastOccurrenceOf(":", false, false)
                                                   .fromLastOccurrenceOf("/", false, false);
            juce::String queryBare = idStr.fromLastOccurrenceOf(":", false, false)
                                          .fromLastOccurrenceOf("/", false, false);
            match = (bare == queryBare && !bare.isEmpty());
        }
        if (match) { foundDesc = *d; found = true; break; }
    }

    if ([format isEqualToString:@"AudioUnit"] || [format isEqualToString:@"VST3"]) {
        auto& fmgr = _engine->getPluginManager().pluginFormatManager;
        for (int fi = 0; fi < fmgr.getNumFormats(); fi++) {
            auto* fmt = fmgr.getFormat(fi);
            if (!fmt || fmt->getName() != fmtStr) continue;
            juce::String searchId = (fmtStr == "AudioUnit" && !idStr.startsWith("AudioUnit:"))
                                    ? "AudioUnit:" + idStr : idStr;
            juce::OwnedArray<juce::PluginDescription> realTypes;
            fmt->findAllTypesForFile(realTypes, searchId);
            if (!realTypes.isEmpty()) {
                foundDesc = *realTypes[0];
                juce::String targetName(juce::String::fromUTF8([pluginName UTF8String]));
                for (auto* rd : realTypes) if (rd->name == targetName) { foundDesc = *rd; break; }
                kl.addType(foundDesc);
                [self savePluginCache];
                found = true;
            }
            break;
        }
    }

    if (!found || foundDesc.fileOrIdentifier.isEmpty()) {
        foundDesc.name              = juce::String::fromUTF8([pluginName UTF8String]);
        foundDesc.pluginFormatName  = fmtStr;
        foundDesc.fileOrIdentifier  = idStr;
        foundDesc.uniqueId          = 0;
        foundDesc.numInputChannels  = 2;
        foundDesc.numOutputChannels = 2;
    }

    return te::ExternalPlugin::create(*_engine, foundDesc);
}

// MARK: - Sonde d'ordre de chaîne FX
//
// Ce que le modèle demande est une chose, ce que la plugin-list contient VRAIMENT en est une
// autre — et c'est là que se voit un décalage d'ordre : un FX passé derrière son gain de voie, la
// chaîne user passée derrière trimOut. Le synoptique, lui, dessine le modèle : il ne peut pas
// démentir le moteur.
//
// Coupée par défaut, allumée par OBJ_FX_DUMP=1 dans l'environnement (Xcode : Run ▸ Arguments ▸
// Environment Variables). Lue par variable d'env et non par macro de compilation, exprès : c'est
// en Release qu'on écoute, et c'est là qu'il faut pouvoir regarder.
static bool objFxDumpEnabled() {
    static const bool on = juce::SystemStats::getEnvironmentVariable("OBJ_FX_DUMP", "0")
                             .trim().getIntValue() != 0;
    return on;
}

// Journalise une plugin-list dans l'ordre où le moteur la traversera, en descendant dans les
// branches d'un bloc parallèle. `role` nomme chaque plugin : pluginKey du modèle pour un FX user,
// rôle (trimIn/trimOut/fader/…) pour les plugins de service.
static void objDumpPluginList(te::PluginList& pl,
                              const std::unordered_map<const te::Plugin*, std::string>& role,
                              int depth) {
    const std::string pad(4 + depth * 4, ' ');
    int i = 0;

    for (auto p : pl) {
        if (!p) { ++i; continue; }

        juce::String line;
        line << pad.c_str() << i << "  " << p->getName() << " [" << p->getPluginType() << "]";

        if (auto* g = dynamic_cast<te::ObjGainPlugin*>(p))
            line << juce::String::formatted(" %+.1f dB", g->getGainDb());
        if (!p->isEnabled())
            line << " (bypass)";
        if (const double latency = p->getLatencySeconds(); latency > 0.0)
            line << juce::String::formatted(" +%.1f ms", latency * 1000.0);

        auto it = role.find(p);
        line << "  ← " << (it != role.end() ? it->second.c_str() : "(hors modèle)");
        NSLog(@"[FX] %s", line.toRawUTF8());

        if (auto* block = dynamic_cast<te::ObjParallelBlockPlugin*>(p)) {
            const int branches = block->getNumBranches();
            for (int b = 0; b < branches; ++b) {
                if (auto* branch = block->getBranch(b)) {
                    NSLog(@"[FX] %s  ├ branche %d/%d — %d plugin(s)",
                          pad.c_str(), b + 1, branches, branch->size());
                    objDumpPluginList(*branch, role, depth + 1);
                }
            }
        }

        ++i;
    }
}

// Compile une série de l'arbre modèle dans `pl`, juste avant `anchor` (trimOut pour la chaîne
// hôte, gain de voie pour une branche ; nullptr → en fin de liste). Réentrante : un bloc
// parallèle devient un ObjParallelBlockPlugin et la fonction se rappelle sur la PluginList de
// chacune de ses branches.
//
// `order` accumule TOUTES les clés posées, à tous les niveaux — c'est le bookkeeping qui
// permettra de retrouver et détruire ces plugins plus tard. Les enfants d'un bloc y sont
// poussés AVANT son porteur : la purge détruit ainsi le contenu avant le contenant.
- (void)compileSeries:(const CompileSeries&)series
                 into:(te::PluginList&)pl
               anchor:(te::Plugin::Ptr)anchor
                order:(std::vector<std::string>&)order
               failed:(NSMutableArray<NSString*>*)failed {
    std::vector<std::string> here;   // clés de CE niveau, dans l'ordre du modèle

    for (auto& n : series) {
        if (n.key.empty()) continue;

        if (n.isRack) {
            te::Plugin::Ptr carrier;
            if (auto pit = _pluginMap.find(n.key); pit != _pluginMap.end()) carrier = pit->second;
            if (!carrier) {
                carrier = pl.insertPlugin(te::ObjParallelBlockPlugin::create(), indexBefore(pl, anchor));
                if (!carrier) {
                    NSLog(@"[FX] compile: bloc parallèle '%s' refusé", n.key.c_str());
                    [failed addObject:[NSString stringWithUTF8String:n.key.c_str()]];
                    continue;
                }
                _pluginMap[n.key] = carrier;
            }

            auto* block = dynamic_cast<te::ObjParallelBlockPlugin*>(carrier.get());
            if (!block) continue;

            const int wantedBranches = (int)n.voices.size();
            while (block->getNumBranches() < wantedBranches) block->addBranch();
            while (block->getNumBranches() > wantedBranches) block->removeBranch(block->getNumBranches() - 1);

            for (size_t i = 0; i < n.voices.size(); ++i) {
                te::PluginList* branch = block->getBranch((int)i);
                if (!branch) continue;

                // Gain de voie en FIN de branche : il sert aussi d'ancre d'insertion, ce qui
                // garde la chaîne de la voie devant lui sans avoir à compter les index.
                const std::string wk = voiceGainKey(n.key, i);
                te::Plugin::Ptr wet;
                if (auto wit = _pluginMap.find(wk); wit != _pluginMap.end()) wet = wit->second;
                if (!wet) {
                    wet = branch->insertPlugin(te::ObjGainPlugin::create(), branch->size());
                    if (wet) _pluginMap[wk] = wet;
                }
                if (auto* g = dynamic_cast<te::ObjGainPlugin*>(wet.get()))
                    g->setGainDb(i < n.wetDb.size() ? n.wetDb[i] : 0.0f);

                [self compileSeries:n.voices[i] into:*branch anchor:wet order:order failed:failed];

                if (wet) order.push_back(wk);
            }

            order.push_back(n.key);   // après son contenu
            here.push_back(n.key);
            continue;
        }

        const std::string& pk = n.key;
        if (_pluginMap.find(pk) == _pluginMap.end()) {
            juce::ValueTree vt = [self resolvedPluginTreeForInfo:n.info
                                                        stateXML:n.info[@"stateXML"]];
            if (!vt.isValid()) {
                NSLog(@"[FX] compile: '%s' non résolu — ignoré", pk.c_str());
                [failed addObject:[NSString stringWithUTF8String:pk.c_str()]];
                continue;
            }
            te::Plugin::Ptr p = pl.insertPlugin(vt, indexBefore(pl, anchor));
            if (!p) {
                NSLog(@"[FX] compile: insertion refusée pour '%s'", pk.c_str());
                [failed addObject:[NSString stringWithUTF8String:pk.c_str()]];
                continue;
            }
            _pluginMap[pk] = p;
            // Une restitution de trace charge son fichier maintenant : le constructeur n'a rien à
            // faire d'un accès disque, et le nœud reste transparent tant que rien n'est chargé —
            // ce qui est exactement ce qu'on veut d'une trace introuvable. @see OBJTracePlaybackPlugin.
            if (auto* playback = dynamic_cast<te::ObjTracePlaybackPlugin*>(p.get())) {
                NSString* tracePath = n.info[@"tracePath"];
                juce::File file(juce::String::fromUTF8([(tracePath ?: @"") UTF8String]));
                if (!playback->loadTrace(file)) {
                    const juce::String path = file.getFullPathName();   // local nommé → toRawUTF8 sûr
                    NSLog(@"[TRACE] restitution '%s' : trace illisible ou absente (%s)",
                          pk.c_str(), path.toRawUTF8());
                }
            }
            // Certains AU refusent leur état tant qu'ils ne sont pas préparés → on revérifie plus tard.
            [self schedulePluginStateReassert:p fromTree:vt];
        }
        if (auto pit = _pluginMap.find(pk); pit != _pluginMap.end())
            pit->second->setEnabled(n.enabled);

        order.push_back(pk);
        here.push_back(pk);
    }

    // Remettre CE niveau dans l'ordre du modèle : chaque plugin est reposé juste avant l'ancre,
    // dans l'ordre du modèle, ce qui restaure l'ordre voulu sans jamais détruire d'instance
    // (état, éditeur ouvert, link préservés). @see movePluginBefore, qui porte le décalage
    // d'index qu'il faut éviter ici.
    //
    // Rien n'est déplacé si l'ordre est DÉJÀ celui du modèle : un déplacement détache le plugin
    // de son arbre le temps de le reposer, ce qui réveille les listeners de Plugin (dont un
    // hideWindowForShutdown) et rebâtit son entrée de plugin-list. Le faire à chaque
    // recompilation pour rien, c'est du bruit sur le cas de loin le plus fréquent.
    if (![self plugins:here areInOrderIn:pl before:anchor])
        for (auto& pk : here)
            if (auto pit = _pluginMap.find(pk); pit != _pluginMap.end())
                movePluginBefore(pl, pit->second, anchor);
}

// Vrai si les plugins de `keys` occupent DÉJÀ `pl` dans cet ordre, tous devant `anchor` —
// l'invariant que la passe de remise en ordre doit établir. Les clés non résolues (plugin
// introuvable) sont sautées : elles n'ont rien à ordonner.
- (BOOL)plugins:(const std::vector<std::string>&)keys
   areInOrderIn:(te::PluginList&)pl
         before:(const te::Plugin::Ptr&)anchor {
    const int anchorIndex = anchor ? pl.indexOf(anchor.get()) : pl.size();
    int previous = -1;

    for (auto& pk : keys) {
        auto pit = _pluginMap.find(pk);
        if (pit == _pluginMap.end()) continue;

        const int i = pl.indexOf(pit->second.get());
        if (i < 0 || i <= previous) return NO;                 // absent de la liste, ou mal placé
        if (anchorIndex >= 0 && i > anchorIndex) return NO;    // passé derrière l'ancre
        previous = i;
    }

    return YES;
}

// Compile la chaîne FX user d'un objet dans sa plugin-list hôte.
//
// Disposition visée, de gauche à droite :
//   [ instrument? | trimIn | FX… | trimOut | fader ObjGain | ObjWindowFade ]
// L'instrument (clip MIDI) et la queue (fader + fenêtre) sont posés ailleurs ; ici on ne
// touche qu'au segment [trimIn … trimOut], qu'on réconcilie par pluginKey pour préserver les
// instances vivantes (état, éditeurs ouverts, paramètres, link), puis qu'on remet dans l'ordre.
- (NSArray<NSString*>*)compileUserRackForObjectID:(NSString*)uuid
                                             tree:(NSArray<NSDictionary*>*)tree
                                        chainInDb:(float)chainInDb
                                       chainOutDb:(float)chainOutDb {
    NSMutableArray<NSString*>* failed = [NSMutableArray array];  // pluginKeys non résolus
    if (!_edit) return failed;
    std::string key([uuid UTF8String]);

    te::PluginList* pl = [self userPluginListForKey:key];
    if (!pl) { NSLog(@"[FX] compile: objet '%@' introuvable", uuid); return failed; }

    auto& chain = _objectChainMap[key];

    CompileSeries root = parseCompileSeries(tree);

    std::unordered_set<std::string> wantedKeys;
    collectCompileKeys(root, wantedKeys);

    // 1) Retirer les plugins qui ont disparu du modèle.
    for (auto& pk : chain.pluginKeys) {
        if (wantedKeys.count(pk)) continue;
        [self teardownPluginLink:pk];
        _editorWindows.erase(pk);
        if (auto pit = _pluginMap.find(pk); pit != _pluginMap.end()) {
            pit->second->deleteFromParent();
            _pluginMap.erase(pit);
        }
    }

    // 2) Trims de début / fin de chaîne : créés une fois, jamais détruits (ils bornent le
    //    segment user et rendent setChainGain: instantané, sans recompiler).
    auto ensureTrim = [&](te::Plugin::Ptr& slot, float dB) {
        if (!slot) slot = pl->insertPlugin(te::ObjGainPlugin::create(),
                                           [self userInsertIndexForKey:key in:*pl]);
        if (auto* g = dynamic_cast<te::ObjGainPlugin*>(slot.get())) g->setGainDb(dB);
    };
    ensureTrim(chain.trimIn,  chainInDb);
    ensureTrim(chain.trimOut, chainOutDb);

    // 3) Créer / réutiliser / ordonner, récursivement : un bloc parallèle descend dans la
    //    PluginList de chacune de ses branches.
    std::vector<std::string> newOrder;
    [self compileSeries:root into:*pl anchor:chain.trimOut order:newOrder failed:failed];
    chain.pluginKeys = newOrder;

    NSLog(@"[FX] compile '%@' OK — %lu plugins", uuid, (unsigned long)newOrder.size());
    [self dumpChainOrderForKey:key in:*pl];

    // La reconstruction ci-dessous compense déjà la nouvelle latence : le veilleur ne doit pas
    // en redemander une seconde au tic suivant (cf. checkLatencyAndRebuild).
    _latencyResyncPending = true;
    _edit->restartPlayback();
    return failed;
}

// Journalise l'ordre RÉEL de la chaîne compilée d'un objet — à comparer au synoptique, qui montre
// le modèle. Coupée par défaut. @see objFxDumpEnabled.
- (void)dumpChainOrderForKey:(const std::string&)key in:(te::PluginList&)pl {
    if (!objFxDumpEnabled()) return;

    // Nommer chaque plugin : les FX user par leur pluginKey (la clé que le synoptique manipule),
    // les plugins de service par leur rôle. Ce qui reste anonyme n'appartient pas à cet objet.
    std::unordered_map<const te::Plugin*, std::string> role;
    for (auto& [pk, p] : _pluginMap)
        if (p) role[p.get()] = pk;

    if (auto it = _objectChainMap.find(key); it != _objectChainMap.end()) {
        if (it->second.trimIn)  role[it->second.trimIn.get()]  = "trimIn";
        if (it->second.trimOut) role[it->second.trimOut.get()] = "trimOut";
    }
    if (auto it = _faderGainMap.find(key);  it != _faderGainMap.end()  && it->second)
        role[it->second.get()] = "fader";
    if (auto it = _windowFadeMap.find(key); it != _windowFadeMap.end() && it->second)
        role[it->second.get()] = "fenêtre + fades";
    if (auto it = _instrumentMap.find(key); it != _instrumentMap.end() && it->second)
        role[it->second.get()] = "instrument";

    NSLog(@"[FX] ── ordre réel de la chaîne '%s' — %d plugin(s) ──", key.c_str(), pl.size());
    objDumpPluginList(pl, role, 0);
}

// Vu-mètre par plugin : il vivait dans le rack (un LevelMeterPlugin câblé après chaque plugin).
// En chaîne linéaire, l'ajouter reviendrait à doubler le nombre de plugins de la chaîne — soit
// exactement ce que cette branche cherche à mesurer. Retourne 0 : les cartes du synoptique
// affichent un vu-mètre au repos.
- (float)audioLevelForPluginKey:(NSString*)pluginKey forObjectID:(NSString*)uuid {
    (void)pluginKey; (void)uuid;
    return 0.0f;
}

// Ajuste à chaud le gain dB d'une voie de bloc parallèle, sans recompiler (pas de glitch en
// draguant, et c'est aussi ce qui porte le MUTE de voie : le modèle pousse un gain EFFECTIF).
//
// Le plugin visé est l'ObjGain de FIN de branche posé par compileSeries:, retrouvé par
// voiceGainKey() — l'id du bloc est unique dans l'Edit, `uuid` ne sert qu'à la symétrie d'API.
// Silencieux si le bloc n'a jamais été compilé ou si la voie n'existe pas : la valeur vit dans le
// modèle, la prochaine compilation la posera (cf. rackSpec / effectiveWetDb côté Swift).
- (void)setVoiceGain:(float)dB forBlockID:(NSString*)blockID voiceIndex:(int)vi objectID:(NSString*)uuid {
    (void)uuid;
    if (!blockID || vi < 0) return;

    auto it = _pluginMap.find(voiceGainKey(std::string([blockID UTF8String]), (size_t)vi));
    if (it == _pluginMap.end()) return;

    if (auto* g = dynamic_cast<te::ObjGainPlugin*>(it->second.get()))
        g->setGainDb(dB);
}

// Ajuste à chaud le gain dB de début (output=NO) / fin (output=YES) de chaîne, sans recompiler.
// Retourne NO si la chaîne n'existe pas encore (objet jamais compilé) → le caller compile alors.
- (BOOL)setChainGain:(float)dB output:(BOOL)isOutput objectID:(NSString*)uuid {
    auto it = _objectChainMap.find(std::string([uuid UTF8String]));
    if (it == _objectChainMap.end()) return NO;
    te::Plugin::Ptr g = isOutput ? it->second.trimOut : it->second.trimIn;
    if (!g) return NO;
    if (auto* og = dynamic_cast<te::ObjGainPlugin*>(g.get())) og->setGainDb(dB);
    return YES;
}

// MARK: - Automations — courbes de paramètre
//
// @see la déclaration dans OBJEngineCore.h pour le contrat (remplacement en bloc, temps edit).

// Retrouve le paramètre automatable visé par une cible d'automation. nil quand la chaîne n'a
// pas (encore) le plugin correspondant — trims d'un objet dont le rack n'a jamais été compilé,
// envoi non câblé, plugin retiré depuis. Cas normal, pas une erreur : le modèle Swift fait foi
// et repoussera la courbe quand la cible existera (compileUserRack, addSend, syncAdd).
- (te::AutomatableParameter::Ptr)automatableParamForObject:(NSString*)uuid
                                                    target:(OBJAutomationTarget)target
                                                 targetKey:(NSString*)targetKey
                                                   paramID:(NSString*)paramID {
    if (!uuid) return {};
    const std::string key([uuid UTF8String]);

    te::Plugin::Ptr plugin;
    juce::String wantedID;

    switch (target) {
        case OBJAutomationTargetVolume:
        case OBJAutomationTargetPan:
            // Le fader mémorisé de l'objet — repère explicite, la chaîne porte d'autres ObjGain.
            if (auto it = _faderGainMap.find(key); it != _faderGainMap.end()) plugin = it->second;
            wantedID = (target == OBJAutomationTargetVolume) ? "gain" : "pan";
            break;

        case OBJAutomationTargetTrimIn:
        case OBJAutomationTargetTrimOut:
            if (auto it = _objectChainMap.find(key); it != _objectChainMap.end())
                plugin = (target == OBJAutomationTargetTrimOut) ? it->second.trimOut : it->second.trimIn;
            wantedID = "gain";
            break;

        case OBJAutomationTargetSend: {
            if (!targetKey) return {};
            auto it = _auxSendMap.find(sendMapKey(key, std::string([targetKey UTF8String])));
            if (it != _auxSendMap.end()) plugin = it->second;
            wantedID = "level";
            break;
        }

        case OBJAutomationTargetPlugin:
            // Étape 4 : les params de plugins USER. La cible est le plugin lui-même, pas l'objet
            // — `uuid` ne sert qu'à la symétrie d'API (le pluginKey est unique dans l'Edit).
            if (!targetKey || !paramID) return {};
            if (auto it = _pluginMap.find(std::string([targetKey UTF8String])); it != _pluginMap.end())
                plugin = it->second;
            wantedID = juce::String([paramID UTF8String]);
            break;
    }

    if (!plugin) return {};
    return plugin->getAutomatableParameterByID(wantedID);
}

- (void)setAutomationCurve:(NSArray<NSDictionary*>*)points
                 forObject:(NSString*)uuid
                    target:(OBJAutomationTarget)target
                 targetKey:(NSString*)targetKey
                   paramID:(NSString*)paramID {
    te::AutomatableParameter::Ptr param = [self automatableParamForObject:uuid
                                                                   target:target
                                                                targetKey:targetKey
                                                                  paramID:paramID];
    if (!param) return;

    auto& curve = param->getCurve();
    const int had = curve.getNumPoints();
    const NSUInteger want = points.count;

    // Le cas de TRÈS loin le plus fréquent : un paramètre sans automation, repoussé par une
    // resynchro de géométrie ou de mix. Sortir sec évite d'écrire dans le ValueTree — donc
    // d'armer le timer de recalcul de l'itérateur — pour rien.
    if (had == 0 && want == 0) return;

    // Remplacement EN BLOC : `clear` puis un `addPoint` par point. Pas de réconciliation fine —
    // une courbe fait quelques dizaines de points, et le moteur ne recalcule son itérateur
    // qu'une fois, sur un timer différé (@see AutomationCurveSource::triggerAsyncIteratorUpdate).
    // UndoManager NUL : l'annulation est tenue côté Swift, sur des instantanés du modèle.
    curve.clear(nullptr);

    const auto range = param->getValueRange();
    for (NSDictionary* p in points) {
        if (![p isKindOfClass:[NSDictionary class]]) continue;
        const double t = juce::jmax(0.0, [p[@"t"] doubleValue]);
        // Bornage sur la plage du PARAMÈTRE : le modèle Swift borne déjà sur la sienne, qui peut
        // être plus étroite (un envoi va de -60 à +6, le plugin de -96 à +12). C'est le garde-fou
        // du moteur, pas une conversion.
        const float v = juce::jlimit(range.getStart(), range.getEnd(), [p[@"v"] floatValue]);
        const float c = juce::jlimit(-1.0f, 1.0f, [p[@"c"] floatValue]);
        curve.addPoint(te::TimePosition::fromSeconds(t), v, c, nullptr);
    }

    // Courbe vidée : rien à forcer. L'itérateur tombe à nul au prochain tick et le paramètre
    // reprend sa valeur explicite — celle du dernier setGainDb/setLevelDb (@see
    // AutomatableParameter::updateToFollowCurve).
}

- (void)diagnosticScanPlugins {
    auto& pm   = _engine->getPluginManager();
    auto& fmgr = pm.pluginFormatManager;
    auto& kl   = pm.knownPluginList;

    NSLog(@"[DIAG] ============================================");
    NSLog(@"[DIAG] Formats enregistrés dans pluginFormatManager : %d", fmgr.getNumFormats());
    for (int fi = 0; fi < fmgr.getNumFormats(); fi++) {
        auto* fmt = fmgr.getFormat(fi);
        if (!fmt) continue;
        auto name = fmt->getName();
        NSLog(@"[DIAG]   Format[%d] = %s", fi, name.toRawUTF8());
    }

    NSLog(@"[DIAG] ---- Dossiers AU ----");
    NSArray* auDirs = @[
        @"/Library/Audio/Plug-Ins/Components",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Audio/Plug-Ins/Components"]
    ];
    for (NSString* dir in auDirs) {
        NSArray* contents = [[NSFileManager defaultManager]
                             contentsOfDirectoryAtPath:dir error:nil] ?: @[];
        NSLog(@"[DIAG] %@ → %lu items", dir, (unsigned long)contents.count);
        for (NSString* f in contents)
            NSLog(@"[DIAG]     %@", f);
    }

    NSLog(@"[DIAG] ---- Dossiers VST3 ----");
    NSArray* vst3Dirs = @[
        @"/Library/Audio/Plug-Ins/VST3",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Audio/Plug-Ins/VST3"]
    ];
    for (NSString* dir in vst3Dirs) {
        NSArray* contents = [[NSFileManager defaultManager]
                             contentsOfDirectoryAtPath:dir error:nil] ?: @[];
        NSLog(@"[DIAG] %@ → %lu items", dir, (unsigned long)contents.count);
        for (NSString* f in contents)
            NSLog(@"[DIAG]     %@", f);
    }

    NSLog(@"[DIAG] ---- Scan JUCE par format (AU seulement — VST3 via Info.plist) ----");
    for (int fi = 0; fi < fmgr.getNumFormats(); fi++) {
        auto* fmt = fmgr.getFormat(fi);
        if (!fmt) continue;
        auto fmtName = fmt->getName();
        // Ne scanner que AU ici : VST3 findAllTypesForFile charge les binaires → crash
        if (fmtName != "AudioUnit") {
            NSLog(@"[DIAG] Format '%s' — ignoré (scan binaire désactivé)", fmtName.toRawUTF8());
            continue;
        }
        auto paths = fmt->getDefaultLocationsToSearch();

        NSLog(@"[DIAG] Format '%s' — searchPaths:", fmtName.toRawUTF8());
        for (int pi = 0; pi < paths.getNumPaths(); pi++)
            NSLog(@"[DIAG]   path[%d] = %s", pi, paths[pi].getFullPathName().toRawUTF8());

        juce::StringArray files = fmt->searchPathsForPlugins(paths, true, false);
        NSLog(@"[DIAG]   → searchPathsForPlugins() a retourné %d entrées", files.size());
        for (auto& f : files) {
            NSLog(@"[DIAG]     file: %s", f.toRawUTF8());
            juce::OwnedArray<juce::PluginDescription> types;
            fmt->findAllTypesForFile(types, f);
            NSLog(@"[DIAG]       → findAllTypesForFile: %d type(s)", types.size());
            for (auto* d : types)
                NSLog(@"[DIAG]         • %s / %s",
                      d->name.toRawUTF8(), d->manufacturerName.toRawUTF8());
        }
    }

    NSLog(@"[DIAG] ---- knownPluginList actuelle ----");
    NSLog(@"[DIAG] %d plugin(s) en cache", kl.getNumTypes());
    for (int i = 0; i < kl.getNumTypes(); i++) {
        auto* d = kl.getType(i);
        if (d)
            NSLog(@"[DIAG]   [%s] %s — %s",
                  d->pluginFormatName.toRawUTF8(),
                  d->name.toRawUTF8(),
                  d->fileOrIdentifier.toRawUTF8());
    }
    NSLog(@"[DIAG] ============================================");
}

// MARK: - Device

// Trace au démarrage le device de sortie retenu et son nombre de canaux. Une sortie tombée en
// MONO ne s'entend pas comme une panne — le master reste stéréo, les vu-mètres bougent, seul un
// canal atteint les enceintes. Sans cette ligne, rien dans l'app ne le dit.
- (void)logDefaultWaveOutput {
    auto& dm = _engine->getDeviceManager();
    // La liste est bâtie en ASYNCHRONE (deviceListChanged → triggerAsyncUpdate) : juste après
    // initialise, elle est encore vide et le device par défaut nul. getWaveOutputDevices force
    // le dispatch — et donc aussi le checkDefaultDevicesAreValid qui choisit le défaut.
    const auto outs = dm.getWaveOutputDevices();
    auto* wo = dm.getDefaultWaveOutDevice();
    if (wo == nullptr) { NSLog(@"[OBJ] Sortie : AUCUN device wave par défaut"); return; }

    const int numChans = wo->getChannels().getNumChannels();
    juce::String name  = wo->getName();
    NSLog(@"[OBJ] Sortie : « %s » — %d %s%s (%d devices wave)",
          name.toRawUTF8(), numChans, numChans > 1 ? "canaux" : "canal",
          numChans < 2 ? "  ⚠️ MONO" : "", (int) outs.size());
}

- (NSArray<NSString*>*)availableOutputDevices {
    auto& dm = _engine->getDeviceManager().deviceManager;
    NSMutableArray* result = [NSMutableArray array];
    for (auto* type : dm.getAvailableDeviceTypes()) {
        // getDeviceNames() sert une liste MISE EN CACHE : sans ce scan, une carte branchée
        // après le lancement n'apparaît jamais (elle ne surgissait que parce que changer de
        // device force JUCE à re-scanner de son côté).
        type->scanForDevices();
        for (auto& name : type->getDeviceNames(false))
            [result addObject:[NSString stringWithUTF8String:name.toRawUTF8()]];
    }
    return result;
}

- (NSString*)currentOutputDeviceName {
    auto& dm = _engine->getDeviceManager().deviceManager;
    if (auto* dev = dm.getCurrentAudioDevice()) {
        juce::String n = dev->getName();   // local nommé (piège toRawUTF8 sur temporaire)
        return [NSString stringWithUTF8String:n.toRawUTF8()];
    }
    return nil;
}

- (void)setOutputDevice:(NSString*)name {
    NSLog(@"[OBJ] setOutputDevice: %@", name);
    BOOL wasPlaying = [self isCurrentlyPlaying];
    [self stop];

    auto& dm = _engine->getDeviceManager().deviceManager;
    auto setup = dm.getAudioDeviceSetup();
    setup.outputDeviceName = juce::String::fromUTF8([name UTF8String]);
    auto err = dm.setAudioDeviceSetup(setup, true);
    if (!err.isEmpty()) {
        NSLog(@"[OBJ] ERROR setting device: %s", err.toRawUTF8());
        return;
    }
    // Relance si on était en lecture (l'Edit est intact, pas besoin de reconstruire)
    if (wasPlaying) {
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_async(dispatch_get_main_queue(), ^{ [self play]; });
        });
    }
}

// MARK: Réglages audio avancés (fréquence d'échantillonnage / taille du buffer)

- (NSArray<NSNumber*>*)availableSampleRates {
    auto& dm = _engine->getDeviceManager().deviceManager;
    NSMutableArray* result = [NSMutableArray array];
    if (auto* dev = dm.getCurrentAudioDevice())
        for (double r : dev->getAvailableSampleRates())
            [result addObject:@(r)];
    return result;
}

- (double)currentSampleRate {
    auto& dm = _engine->getDeviceManager().deviceManager;
    if (auto* dev = dm.getCurrentAudioDevice())
        return dev->getCurrentSampleRate();
    return 0;
}

- (void)setSampleRate:(double)rate {
    NSLog(@"[OBJ] setSampleRate: %.0f", rate);
    BOOL wasPlaying = [self isCurrentlyPlaying];
    [self stop];

    auto& dm = _engine->getDeviceManager().deviceManager;
    auto setup = dm.getAudioDeviceSetup();
    setup.sampleRate = rate;
    auto err = dm.setAudioDeviceSetup(setup, true);
    if (!err.isEmpty()) {
        NSLog(@"[OBJ] ERROR setting sample rate: %s", err.toRawUTF8());
        return;
    }
    if (wasPlaying) {
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_async(dispatch_get_main_queue(), ^{ [self play]; });
        });
    }
}

- (NSArray<NSNumber*>*)availableBufferSizes {
    auto& dm = _engine->getDeviceManager().deviceManager;
    NSMutableArray* result = [NSMutableArray array];
    if (auto* dev = dm.getCurrentAudioDevice())
        for (int b : dev->getAvailableBufferSizes())
            [result addObject:@(b)];
    return result;
}

- (NSInteger)currentBufferSize {
    auto& dm = _engine->getDeviceManager().deviceManager;
    if (auto* dev = dm.getCurrentAudioDevice())
        return dev->getCurrentBufferSizeSamples();
    return 0;
}

- (void)setBufferSize:(NSInteger)frames {
    NSLog(@"[OBJ] setBufferSize: %ld", (long)frames);
    BOOL wasPlaying = [self isCurrentlyPlaying];
    [self stop];

    auto& dm = _engine->getDeviceManager().deviceManager;
    auto setup = dm.getAudioDeviceSetup();
    setup.bufferSize = (int)frames;
    auto err = dm.setAudioDeviceSetup(setup, true);
    if (!err.isEmpty()) {
        NSLog(@"[OBJ] ERROR setting buffer size: %s", err.toRawUTF8());
        return;
    }
    if (wasPlaying) {
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_async(dispatch_get_main_queue(), ^{ [self play]; });
        });
    }
}

@end
