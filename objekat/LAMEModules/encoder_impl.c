// Unité de compilation de libmp3lame pour la cible Xcode : la config d'abord, la source
// vendored ensuite. Les `#pragma` taisent trois avertissements du code amont (décalages de
// valeurs négatives, fabs sur entier, comparaison de tableau à NULL) — les corriger
// reviendrait à patcher LAME. @see objlame_config.h et lame-3.100/OBJEKAT-INTEGRATION.md
#include "objlame_config.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wshift-negative-value"
#pragma clang diagnostic ignored "-Wabsolute-value"
#pragma clang diagnostic ignored "-Wtautological-pointer-compare"
#include "../../lame-3.100/libmp3lame/encoder.c"
#pragma clang diagnostic pop
