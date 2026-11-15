//
//  OBJDiagLog.h
//  objekat
//
//  Le CŒUR du journal de diagnostic : un fichier en append, une ligne = un write() sous verrou,
//  aucune file d'attente, aucune allocation sur le chemin chaud. Appelable depuis Swift (via
//  l'en-tête de pont) ET depuis le pont C++/ObjC (OBJEngineCore.mm).
//
//  Pourquoi du C et pas du Swift : le gestionnaire de crash doit écrire AVANT que le processus
//  meure, dans un contexte de signal où rien de ce que Swift/ObjC offre n'est sûr (allocation,
//  verrous, runtime). Tout ce qui est partagé avec lui vit donc ici, dans des tampons statiques.
//
//  RÈGLES
//    • JAMAIS depuis le thread audio : le coût est un write() (µs, parfois plus), et il prend un
//      verrou. En Debug, un appel depuis un thread temps réel CoreAudio est une assertion
//      (`objdiag_is_realtime_thread` permet de tester avant, pour ceux qui ne maîtrisent pas
//      leur appelant — le logger JUCE par exemple).
//    • Désactivé (`objdiag_enabled() == 0`), un appel ne coûte que la lecture d'un entier.
//    • Une ligne : `HH:MM:SS.mmm +secondes CAT   message` ; le message est assaini (retours à la
//      ligne → « | »), tronqué à ~4 Ko.
//
//  Le format complet, les dossiers et la lecture par Claude : docs/command_api.md (« Journal de
//  diagnostic ») et ~/Library/Logs/Objekat/README.md.
//

#ifndef OBJDiagLog_h
#define OBJDiagLog_h

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Lu sans verrou ; ne jamais l'écrire hors du cœur.
extern int objdiag_enabled_flag;

static inline int objdiag_enabled(void) {
    return __atomic_load_n(&objdiag_enabled_flag, __ATOMIC_RELAXED);
}

/// Ouvre une session de journal.
///   log_path          fichier du journal (créé, en append) ;
///   meta_path         fichier méta de la session (JSON) — écrit tout de suite avec
///                     `meta_unclean_json` (clean_exit:false) ;
///   meta_clean_json   ce que le méta devient à une sortie NORMALE (clean_exit:true) : réécrit
///                     par atexit, `objdiag_close`, et le gestionnaire SIGTERM/SIGINT ;
///   header            première ligne du journal (« # OBJEKAT … »), rejouée après une rotation ;
///   max_bytes         taille à laquelle le journal passe en `.log.1` (0 = 20 Mo).
/// Installe, une fois pour le processus, les gestionnaires de crash et d'arrêt externe.
/// Renvoie 0, ou -errno.
int objdiag_open(const char* log_path, const char* meta_path,
                 const char* meta_unclean_json, const char* meta_clean_json,
                 const char* header, uint64_t max_bytes);

/// Réécrit le méta (le projet ouvert a changé…) et mémorise la version « sortie normale ».
void objdiag_update_meta(const char* meta_unclean_json, const char* meta_clean_json);

/// Fin NORMALE de la session : ligne `EXIT <reason>`, méta → clean_exit:true, fichier fermé,
/// journal désactivé. Sans effet si rien n'est ouvert.
void objdiag_close(const char* reason);

/// Écrit une ligne. `cat` : catégorie courte (« API », « EDIT »…, 5 caractères au plus).
void objdiag_log(const char* cat, const char* message);
void objdiag_logf(const char* cat, const char* fmt, ...) __attribute__((format(printf, 2, 3)));

/// Chemin du journal courant (copié dans `buf`), longueur ; 0 si rien d'ouvert.
size_t objdiag_copy_path(char* buf, size_t capacity);

/// Octets écrits dans le fichier COURANT (remis à zéro à la rotation).
uint64_t objdiag_bytes_written(void);

/// Nombre de rotations faites depuis l'ouverture.
int objdiag_rotation_count(void);

/// Vrai sur un thread temps réel CoreAudio (nom « com.apple.audio.… »), mis en cache par thread.
int objdiag_is_realtime_thread(void);

#ifndef NDEBUG
/// Provoque un vrai crash, pour les tests (`debug.crash`). kind : 0 = SIGSEGV (écriture en 8),
/// 1 = abort(), 2 = débordement de pile (récursion). Les autres types (exception ObjC, fatalError
/// Swift) sont faits côté Swift.
void objdiag_debug_crash(int kind);
#endif

#ifdef __cplusplus
}
#endif

#endif /* OBJDiagLog_h */
