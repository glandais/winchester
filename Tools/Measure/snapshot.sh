#!/bin/sh
# Construit le rendu hors-ligne et le range sous un nom d'étape, avec son paquet
# de ressources : un binaire par étape, et n'importe quelle paire se compare
# sans rien reconstruire.
#
#   ./Tools/Measure/snapshot.sh base       # avant de toucher au code
#   ./Tools/Measure/snapshot.sh m1         # après la première correction
#
# Tout va sous $MEASURE_DIR (par défaut .build/measure).
set -e
cd "$(dirname "$0")/../.."
STEP="${1:?usage : snapshot.sh <étape>}"
DIR="${MEASURE_DIR:-.build/measure}/bin-$STEP"

./Tools/build-render.sh /tmp/rendertrace >/dev/null
rm -rf "$DIR"
mkdir -p "$DIR"
cp /tmp/rendertrace "$DIR/"
# L'exécutable cherche son paquet à côté de lui.
cp -R .build/release/DiskCore_DiskCore.bundle "$DIR/"
echo "$DIR"
