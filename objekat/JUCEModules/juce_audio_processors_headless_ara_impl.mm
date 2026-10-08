// JUCE_PLUGINHOST_ARA=1 (et TRACKTION_ENABLE_ARA=1) : l'hôte ARA de JUCE veut `ARADebug.c` du SDK
// ARA (ARAInterfaceAssert, ARASetExternalAssertReference) dans SA PROPRE unité de compilation —
// JUCE le dit lui-même en tête de ce fichier (WIN32_LEAN_AND_MEAN). Le SDK vit dans `ARA_SDK/`
// (sous-modules ARA_API et ARA_Library, tag releases/2.3.0), cherché via HEADER_SEARCH_PATHS.
#include <juce_audio_processors_headless/juce_audio_processors_headless_ara.cpp>
