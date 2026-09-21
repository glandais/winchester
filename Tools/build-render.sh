#!/bin/sh
# Compile le moteur de rendu hors-ligne (modèle + synthèse, sans UI ni AVAudioEngine).
set -e
cd "$(dirname "$0")/.."

# La géométrie, le modèle de seek et le générateur déterministe vivent
# désormais dans le paquet DiskCore : on le construit d'abord, puis on lie
# l'outil contre lui.
swift build -c release --target DiskCore
CORE="$(swift build -c release --show-bin-path)"

# Swift Build (défaut depuis Swift 6.4) pose le module à la racine du dossier
# de produits et pré-lie la cible en un seul DiskCore.o ; l'ancien système
# natif rangeait les modules dans Modules/ et les objets dans DiskCore.build/.
if [ -f "$CORE/DiskCore.o" ]; then
    CORE_FLAGS="-I $CORE $CORE/DiskCore.o"
else
    CORE_FLAGS="-I $CORE/Modules $(echo "$CORE"/DiskCore.build/*.o)"
fi

OUT="${1:-/tmp/rendertrace}"
# L'outil vidéo se range à côté : même dossier, même paquet de ressources.
VIDEO_OUT="$(dirname "$OUT")/rendervideo"

# Les sources du modèle et de la synthèse que partagent les deux outils.
MODEL_SOURCES="
    Sources/Model/VolumeLayout.swift
    Sources/Model/DefragVolume.swift
    Sources/Model/Workload.swift
    Sources/Model/Platter.swift
    Sources/Model/BootSession.swift
    Sources/Model/BootLayout.swift
    Sources/Model/InstallSession.swift
    Sources/Model/MachineWriter.swift
    Sources/Model/DaySession.swift
    Sources/Model/DiskLife.swift
    Sources/Model/DiskSimulator.swift
    Sources/Model/DriveCache.swift
    Sources/Model/SoftwareCache.swift
    Sources/Model/Volume.swift
    Sources/Model/DisplayFormat.swift
    Sources/Model/DefragJob.swift
    Sources/Model/DefragStrategy.swift
    Sources/Model/Windows95Strategy.swift
    Sources/Model/WindowsXPStrategy.swift
    Sources/Model/JKDefragStrategy.swift
    Sources/Model/JKDefragFullOptimize.swift
    Sources/Model/UltraDefragStrategy.swift
    Sources/Model/FrontierCompactionStrategy.swift
    Sources/Model/FragmentMergeStrategy.swift
    Sources/Model/SmartDefragStrategy.swift
    Sources/Model/GeneratedVolume.swift
    Sources/Model/ClusterMap.swift
    Sources/Model/OperationSink.swift
    Sources/Model/PassPipeline.swift
    Sources/Model/PassSession.swift
    Sources/Model/LivePass.swift
    Sources/Model/ClusterPalette.swift
    Sources/Model/Scenario.swift
    Sources/Audio/Biquad.swift
    Sources/Audio/SeekSynth.swift
    Sources/Audio/SpindleVoice.swift
    Sources/Model/AudioCue.swift
    Sources/Model/SpindleCharacter.swift
    Tools/Shared/ScenarioRequest.swift
    Tools/Shared/StreamingMixer.swift
    Tools/Shared/Report.swift
"

# shellcheck disable=SC2086 # CORE_FLAGS et MODEL_SOURCES se découpent en arguments
swiftc -O -swift-version 6 -o "$OUT" $CORE_FLAGS $MODEL_SOURCES Tools/RenderTrace/main.swift

# shellcheck disable=SC2086
swiftc -O -swift-version 6 -o "$VIDEO_OUT" $CORE_FLAGS $MODEL_SOURCES \
    Tools/RenderVideo/Canvas.swift \
    Tools/RenderVideo/PlatterDrawing.swift \
    Tools/RenderVideo/FrameComposer.swift \
    Tools/RenderVideo/AudioSnippets.swift \
    Tools/RenderVideo/main.swift

# Bundle.module ne cherche les ressources de DiskCore qu'à côté de l'exécutable
# (Swift Build n'y ajoute plus le chemin du dossier de build).
rm -rf "$(dirname "$OUT")/DiskCore_DiskCore.bundle"
cp -R "$CORE/DiskCore_DiskCore.bundle" "$(dirname "$OUT")/"
