/*
 objlame_config.h — remplace le `config.h` d'autoconf pour la compilation de libmp3lame
 DANS la cible Xcode d'Objekat.

 LAME se compile normalement via ./configure, qui écrit un config.h et le fait inclure par
 chaque .c via -DHAVE_CONFIG_H. On ne peut pas passer ce flag ici : le groupe synchronisé
 d'Xcode compile toutes les sources de `objekat/` avec les MÊMES réglages, et poser
 HAVE_CONFIG_H pour tout le projet ferait aussi réagir les bibliothèques tierces embarquées
 dans JUCE (FLAC, Ogg), qui testent le même symbole.

 Chaque unité de compilation `*_impl.c` de ce dossier inclut donc CE fichier AVANT la source
 LAME correspondante (le `#ifdef HAVE_CONFIG_H` de LAME reste faux, sans conséquence : tout ce
 qu'il aurait apporté est ci-dessous). Les valeurs reproduisent la sortie de
 `./configure --disable-frontend --disable-decoder` sur macOS arm64 (LAME 3.100).

 @see lame-3.100/OBJEKAT-INTEGRATION.md
 */

#ifndef objlame_config_h
#define objlame_config_h

/* En-têtes disponibles (POSIX/macOS) */
#define STDC_HEADERS 1
#define HAVE_LIMITS_H 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_MEMORY_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_UNISTD_H 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_DLFCN_H 1

/* Fonctions */
#define HAVE_STRTOL 1
#define HAVE_GETTIMEOFDAY 1

/* Types entiers de largeur fixe */
#define HAVE_INT8_T 1
#define HAVE_INT16_T 1
#define HAVE_INT32_T 1
#define HAVE_INT64_T 1
#define HAVE_UINT8_T 1
#define HAVE_UINT16_T 1
#define HAVE_UINT32_T 1
#define HAVE_UINT64_T 1
#define A_INT32_T int
#define A_INT64_T long
#define A_UINT32_T unsigned int
#define A_UINT64_T unsigned long

/* Tailles (LP64) */
#define SIZEOF_SHORT 2
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_LONG_LONG 8
#define SIZEOF_UNSIGNED_SHORT 2
#define SIZEOF_UNSIGNED_INT 4
#define SIZEOF_UNSIGNED_LONG 8
#define SIZEOF_UNSIGNED_LONG_LONG 8
#define SIZEOF_FLOAT 4
#define SIZEOF_DOUBLE 8

/* Flottants nommés — fournis par le config.h d'autoconf, attendus par util.h/machine.h. */
#ifndef HAVE_IEEE754_FLOAT32_T
typedef float ieee754_float32_t;
#endif
#ifndef HAVE_IEEE754_FLOAT64_T
typedef double ieee754_float64_t;
#endif

/* Identité de la bibliothèque (lame_version_string, tag LAME du VBR header). */
#define LAME_LIBRARY_BUILD 1
#define PACKAGE "lame"
#define VERSION "3.100"

/*
 NON définis, volontairement :
   HAVE_MPGLIB          — décodeur mpglib : on n'encode que (pas de lame_decode).
   HAVE_XMMINTRIN_H     — chemins SSE de vector/xmm_quantize_sub.c : on reste en C portable,
                          la cible étant universelle (arm64 + x86_64).
   TAKEHIRO_IEEE754_HACK — bit-twiddling sur la représentation IEEE, inutile ici.
   HAVE_NASM            — routines assembleur i386.
 */

#endif /* objlame_config_h */
