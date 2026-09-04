//
//  objekat-Bridging-Header.h
//  objekat
//
//  Created by Nicolas Vair on 17/05/2026.
//

#ifndef objekat_Bridging_Header_h
#define objekat_Bridging_Header_h

#import "OBJEngineCore.h"

// libmp3lame — encodage MP3 depuis Swift (macOS ne fournit AUCUN encodeur MP3 : ni CoreAudio ni
// AVFoundation ne savent écrire du MPEG Layer III). Les sources sont vendorées dans
// `lame-3.100/` et compilées par les unités de `objekat/LAMEModules/`.
// @see lame-3.100/OBJEKAT-INTEGRATION.md et Export/Mp3Encoder.swift
#import "../lame-3.100/include/lame.h"

#endif /* objekat_Bridging_Header_h */
