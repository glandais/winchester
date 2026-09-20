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

rm -rf "$DIR"
mkdir -p "$DIR"
# Construit droit dans le dossier de l'étape, pas dans un chemin partagé : deux
# worktrees qui mesurent en même temps se voleraient le binaire. Le script pose
# le paquet de ressources à côté de l'exécutable, où celui-ci le cherche.
./Tools/build-render.sh "$(cd "$DIR" && pwd)/rendertrace" >/dev/null
echo "$DIR"
