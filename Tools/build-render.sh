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

# shellcheck disable=SC2086 # CORE_FLAGS doit se découper en arguments
swiftc -O -swift-version 6 -o "$OUT" \
    $CORE_FLAGS \
    Sources/Model/VolumeLayout.swift \
    Sources/Model/DefragVolume.swift \
    Sources/Model/Workload.swift \
    Sources/Model/Platter.swift \
    Sources/Model/BootSession.swift \
    Sources/Model/DiskSimulator.swift \
    Sources/Model/Volume.swift \
    Sources/Model/DefragJob.swift \
    Sources/Model/DefragStrategy.swift \
    Sources/Model/Windows95Strategy.swift \
    Sources/Model/WindowsXPStrategy.swift \
    Sources/Model/JKDefragStrategy.swift \
    Sources/Model/JKDefragFullOptimize.swift \
    Sources/Model/UltraDefragStrategy.swift \
    Sources/Model/FrontierCompactionStrategy.swift \
    Sources/Model/FragmentMergeStrategy.swift \
    Sources/Model/GeneratedVolume.swift \
    Sources/Model/ClusterMap.swift \
    Sources/Model/OperationSink.swift \
    Sources/Model/PassPipeline.swift \
    Sources/Model/PassSession.swift \
    Sources/Model/LivePass.swift \
    Sources/Model/ClusterPalette.swift \
    Sources/Model/Scenario.swift \
    Sources/Audio/Biquad.swift \
    Sources/Audio/SeekSynth.swift \
    Sources/Audio/SpindleVoice.swift \
    Sources/Model/AudioCue.swift \
    Tools/RenderTrace/main.swift

# Bundle.module ne cherche les ressources de DiskCore qu'à côté de l'exécutable
# (Swift Build n'y ajoute plus le chemin du dossier de build).
rm -rf "$(dirname "$OUT")/DiskCore_DiskCore.bundle"
cp -R "$CORE/DiskCore_DiskCore.bundle" "$(dirname "$OUT")/"
