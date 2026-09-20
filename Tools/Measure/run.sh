#!/bin/sh
# Rejoue les bilans d'une étape, en PLAN_ONLY et en parallèle.
#
#   ./Tools/Measure/run.sh <étape> boots   # les vingt démarrages, ~3 s
#   ./Tools/Measure/run.sh <étape> disks   # les vingt volumes, un à la fois, ~30 s
#   ./Tools/Measure/run.sh <étape> full    # tout le README : 5 à 7 min
#
# `disks` décrit les vingt volumes générés (`SCENARIO=disk:`) : l'histogramme
# des extents par fichier, les répertoires, le coût de génération — ce que lit
# `extents.py`. `full` fait les vingt démarrages, les vingt volumes, les vingt
# installations, les quatre journées du README, les vingt profils croisés avec
# les treize outils, et XP et UltraDefrag en blocs pleins sur les huit NTFS :
# 340 bilans. Chaque bilan est un fichier texte dans $MEASURE_DIR/out-<étape>/.
set -e
cd "$(dirname "$0")/../.."
STEP="${1:?usage : run.sh <étape> boots|disks|full}"
WHAT="${2:-boots}"
ROOT="$(cd "${MEASURE_DIR:-.build/measure}" && pwd)"
BIN="$ROOT/bin-$STEP"
OUT="$ROOT/out-$STEP"
[ -x "$BIN/rendertrace" ] || { echo "pas de binaire : ./Tools/Measure/snapshot.sh $STEP" >&2; exit 1; }
mkdir -p "$OUT"

PROFILES="dev-1993 gamer-1993 poweruser-1993 secretaire-1993
dev-1996 famille-1996 gamer-1996 secretaire-1996
dev-1999 famille-1999 gamer-1999 secretaire-1999
dev-2003 famille-2003 gamer-2003 secretaire-2003
dev-2007 famille-2007 gamer-2007 secretaire-2007"
NTFS="dev-2003 famille-2003 gamer-2003 secretaire-2003 dev-2007 famille-2007 gamer-2007 secretaire-2007"
TOOLS="windows95 windowsXP jkDefrag ultraDefrag jkDefragForcedFill jkDefragMoveUp
jkDefragSortName jkDefragSortSize jkDefragSortAccess jkDefragSortChange
jkDefragSortCreation frontierCompaction fragmentMerge"
DAYS="dev-1996:20 dev-1996:300 famille-2003:400 gamer-1999:365"

# Les volumes d'abord, **un à la fois** : leur bilan porte la durée de
# génération, et six générations en parallèle se la disputeraient.
if [ "$WHAT" != boots ]; then
    for p in $PROFILES; do
        (cd "$BIN" && SCENARIO="disk:$p" ./rendertrace > "$OUT/disk-$p.txt" 2>&1)
    done
fi
[ "$WHAT" = disks ] && { ls "$OUT" | wc -l | xargs echo "bilans :"; exit 0; }

# Une ligne par bilan : fichier, blocs pleins, scénario, outil.
{
    for p in $PROFILES; do echo "boot-$p - boot:$p -"; done
    if [ "$WHAT" = full ]; then
        for p in $PROFILES; do echo "install-$p - install:$p -"; done
        for d in $DAYS; do echo "day-$(echo "$d" | tr : _) - day:$d -"; done
        for p in $PROFILES; do for t in $TOOLS; do echo "defrag-$p-$t - $p $t"; done; done
        for p in $NTFS; do for t in windowsXP ultraDefrag; do echo "full-$p-$t 1 $p $t"; done; done
    fi
} | (cd "$BIN" && xargs -P 6 -L 1 sh -c '
    name=$0 full=$1 scenario=$2 tool=$3
    [ "$tool" = - ] && unset tool
    [ "$full" = - ] && unset full
    env ${full:+FULL_BLOCKS=1} ${tool:+STRATEGY=$tool} SCENARIO=$scenario PLAN_ONLY=1 \
        ./rendertrace > "'"$OUT"'/$name.txt" 2>&1')
ls "$OUT" | wc -l | xargs echo "bilans :"
# Un bilan sans durée ni empreinte est un rendu interrompu : le compte y est,
# le chiffre non.
TRUNCATED="$(cd "$OUT" && grep -L -e '^durée' -e '^empreinte' -- *.txt || true)"
[ -z "$TRUNCATED" ] || { echo "bilans tronqués :" >&2; echo "$TRUNCATED" >&2; exit 1; }
