/*
 AJOUT OBJEKAT — ce fichier ne fait pas partie de LAME 3.100.

 Les sources de libmp3lame incluent l'en-tête public par `#include "lame.h"`, en comptant sur
 le `-I<racine>/include` que pose le Makefile d'autoconf. La cible Xcode d'Objekat compile ces
 sources sans chemin d'inclusion supplémentaire (@see OBJEKAT-INTEGRATION.md) : cette
 passerelle d'une ligne, posée à côté des sources, résout l'inclusion sans dupliquer l'en-tête
 ni toucher au code amont.
 */
#include "../include/lame.h"
