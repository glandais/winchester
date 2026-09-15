#!/bin/sh
# Compile le moteur de rendu hors-ligne (modèle + synthèse, sans UI ni AVAudioEngine).
set -e
cd "$(dirname "$0")/.."
swiftc -O -o "${1:-/tmp/rendertrace}" \
    Sources/Model/DriveGeometry.swift \
    Sources/Model/SeekModel.swift \
    Sources/Model/Workload.swift \
    Sources/Model/DiskSimulator.swift \
    Sources/Audio/Biquad.swift \
    Sources/Audio/SeekSynth.swift \
    Sources/Audio/SpindleVoice.swift \
    Sources/Audio/AudioCue.swift \
    Tools/RenderTrace/main.swift
