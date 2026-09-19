#!/bin/sh
# Démarre chaque disque de la galerie après chaque outil de son format, et
# garde les bilans : le démarrage rangé, et la passe qui l'a rangé.
#
#   ./Tools/Measure/smart.sh <étape> [outils FAT] [outils NTFS]
#
# Le binaire est $MEASURE_DIR/bin-<étape> (snapshot.sh) ; les bilans vont dans
# $MEASURE_DIR/out-<étape>/rboot-<profil>-<outil>.txt, `-` pour le disque tel
# que la galerie le livre.
set -e
cd "$(dirname "$0")/../.."
STEP="${1:?usage : smart.sh <étape> [outils FAT] [outils NTFS]}"
FAT_TOOLS="${2:-- windows95 jkDefrag ultraDefrag frontierCompaction}"
NTFS_TOOLS="${3:-- windowsXP ultraDefrag jkDefrag fragmentMerge}"
ROOT="$(cd "${MEASURE_DIR:-.build/measure}" && pwd)"
BIN="$ROOT/bin-$STEP"
OUT="$ROOT/out-$STEP"
mkdir -p "$OUT"
python3 - "$FAT_TOOLS" "$NTFS_TOOLS" <<'PY' | (cd "$BIN" && xargs -P 6 -L 1 sh -c '
    p=$0 t=$1
    if [ "$t" = - ]; then env SCENARIO=boot:$p PLAN_ONLY=1 ./rendertrace /dev/null > "'"$OUT"'/rboot-$p-$t.txt" 2>&1
    else env STRATEGY=$t SCENARIO=boot:$p PLAN_ONLY=1 ./rendertrace /dev/null > "'"$OUT"'/rboot-$p-$t.txt" 2>&1; fi')
import sys
fat, ntfs = sys.argv[1].split(), sys.argv[2].split()
for year in ("1993", "1996", "1999", "2003", "2007"):
    for who in ("dev", "famille", "gamer", "secretaire", "poweruser"):
        if who == "poweruser" and year != "1993": continue
        if who == "famille" and year == "1993": continue
        for t in (fat if year < "2003" else ntfs):
            print(f"{who}-{year} {t}")
PY
ls "$OUT" | grep -c rboot | xargs echo "bilans :"
