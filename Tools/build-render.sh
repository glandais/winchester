#!/bin/sh
# Compile le moteur de rendu hors-ligne (modèle + synthèse, sans UI ni AVAudioEngine).
set -e
cd "$(dirname "$0")/.."

# La géométrie, le modèle de seek et le générateur déterministe vivent
# désormais dans le paquet DiskCore : on le construit d'abord, puis on lie
# l'outil contre lui.
swift build -c release --target DiskCore
CORE=".build/release"

swiftc -O -swift-version 6 -o "${1:-/tmp/rendertrace}" \
    -I "$CORE/Modules" "$CORE"/DiskCore.build/*.o \
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
    Sources/Model/UltraDefragStrategy.swift \
    Sources/Model/GeneratedVolume.swift \
    Sources/Model/ClusterMap.swift \
    Sources/Model/ClusterPalette.swift \
    Sources/Model/Scenario.swift \
    Sources/Audio/Biquad.swift \
    Sources/Audio/SeekSynth.swift \
    Sources/Audio/SpindleVoice.swift \
    Sources/Audio/AudioCue.swift \
    Tools/RenderTrace/main.swift
