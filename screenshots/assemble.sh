#!/usr/bin/env bash
#
# Troisième temps des captures : faire des rendus de Koubou le jeu que lit
# `asc screenshots upload`.
#
#   1. ./scripts/screenshots.sh                      -> screenshots/flat/<appareil>/<locale>/NN-*.png
#   2. kou generate screenshots/koubou/<appareil>.yaml
#                                                    -> screenshots/koubou/out/<appareil>/<locale>/<cadre>/NN-*.png
#   3. ./screenshots/assemble.sh                     -> screenshots/<type>/<locale>/NN-*.png
#
# Koubou écrit un niveau de dossier qu'App Store Connect ne connaît pas (le nom
# du cadre) : on l'aplatit, on efface de la destination ce que le nouveau rendu
# ne remplace pas — un ancien nommage partirait sinon avec le nouveau jeu —, et
# on refuse de laisser sur le disque un jeu que l'envoi rejetterait.
#
# Vérifications, toutes bloquantes :
#   - les dimensions exactes du type d'affichage (1242x2688, 2048x2732)
#   - aucun canal alpha — ASC répond IMAGE_ALPHA_NOT_ALLOWED, et
#     `asc screenshots validate` ne le voit PAS (voir screenshots/README.md)
#   - pas vide, et pas beaucoup plus léger que la même carte dans l'autre
#     langue : un rendu blanc ou à moitié peint est léger, pas absent
#   - `asc screenshots validate` par locale en plus, quand asc est là
#
# Usage : ./screenshots/assemble.sh [--keep-stale] [--no-validate]
#
# Écrit pour le /bin/bash 3.2 de macOS. Les vérifications par fichier sont
# dans le Python embarqué.

set -euo pipefail
cd "$(dirname "$0")/.."

OUT="screenshots/koubou/out"

keep_stale=0
run_validate=1
for arg in "$@"; do
  case "$arg" in
    --keep-stale)  keep_stale=1 ;;
    --no-validate) run_validate=0 ;;
    *) echo "argument inconnu : $arg" >&2; exit 2 ;;
  esac
done

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

# appareil -> type d'affichage App Store Connect, qui nomme la destination.
display_type_for() {
  case "$1" in
    iphone) echo "IPHONE_65" ;;
    ipad)   echo "IPAD_PRO_3GEN_129" ;;
    *) red "appareil inconnu sous $OUT : $1"; exit 1 ;;
  esac
}

[ -d "$OUT" ] || { red "aucun rendu sous $OUT — lancer : kou generate screenshots/koubou/iphone.yaml"; exit 1; }

devices=$(find "$OUT" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
[ -n "$devices" ] || { red "aucun appareil sous $OUT"; exit 1; }

copied=0
for device in $devices; do
  type=$(display_type_for "$device")
  locales=$(find "$OUT/$device" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
  bold "$device -> screenshots/$type : $(echo "$locales" | tr '\n' ' ')"
  for loc in $locales; do
    # out/<appareil>/<locale>/<cadre>/NN-*.png : un seul dossier de cadre attendu.
    ndev=$(find "$OUT/$device/$loc" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    if [ "$ndev" != "1" ]; then
      red "ÉCHEC $device/$loc : un dossier de cadre attendu sous $OUT/$device/$loc, $ndev trouvés"
      exit 1
    fi
    framedir=$(find "$OUT/$device/$loc" -mindepth 1 -maxdepth 1 -type d)
    npng=$(find "$framedir" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')
    [ "$npng" != "0" ] || { red "ÉCHEC $device/$loc : aucun PNG dans $framedir"; exit 1; }

    dst="screenshots/$type/$loc"
    mkdir -p "$dst"
    if [ "$keep_stale" -eq 0 ]; then
      for existing in "$dst"/*.png; do
        [ -e "$existing" ] || continue
        base=$(basename "$existing")
        if [ ! -e "$framedir/$base" ]; then
          rm "$existing"
          echo "  retiré (périmé) $dst/$base"
        fi
      done
    fi
    for src in "$framedir"/*.png; do
      cp "$src" "$dst/$(basename "$src")"
      copied=$((copied + 1))
    done
  done
done
bold "$copied fichiers copiés"

# ---------------------------------------------------------------- vérifications
python3 - <<'PY' || exit 1
import os, statistics, subprocess, sys

SETS = {"IPHONE_65": (1242, 2688), "IPAD_PRO_3GEN_129": (2048, 2732)}
FLOOR = 0.50   # de la taille médiane de la même carte dans les autres langues

fail, checked = [], 0
for kind, expect in SETS.items():
    root = os.path.join("screenshots", kind)
    if not os.path.isdir(root):
        continue
    files = [(loc, name, os.path.join(root, loc, name))
             for loc in sorted(os.listdir(root)) if os.path.isdir(os.path.join(root, loc))
             for name in sorted(os.listdir(os.path.join(root, loc))) if name.endswith(".png")]
    by_card = {}
    for _, name, path in files:
        by_card.setdefault(name, []).append(os.path.getsize(path))
    median = {k: statistics.median(v) for k, v in by_card.items()}
    for loc, name, path in files:
        checked += 1
        out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", path],
                             capture_output=True, text=True).stdout
        got = {}
        for line in out.splitlines():
            if ":" in line:
                k, _, v = line.strip().partition(":")
                got[k.strip()] = v.strip()
        w, h = got.get("pixelWidth"), got.get("pixelHeight")
        where = f"{kind}/{loc}/{name}"
        if (w, h) != (str(expect[0]), str(expect[1])):
            fail.append(f"{where} : {w}x{h}, attendu {expect[0]}x{expect[1]}")
        if got.get("hasAlpha") != "no":
            fail.append(f"{where} : canal alpha (ASC : IMAGE_ALPHA_NOT_ALLOWED)")
        size = os.path.getsize(path)
        if size == 0:
            fail.append(f"{where} : vide")
        elif size < FLOOR * median[name]:
            fail.append(f"{where} : {size} o, sous {FLOOR:.0%} des {int(median[name])} o "
                        f"médians de {name}")

print(f"{checked} fichiers vérifiés")
for f in fail:
    print("ÉCHEC " + f)
sys.exit(1 if fail or not checked else 0)
PY

if [ "$run_validate" -eq 1 ]; then
  if command -v asc >/dev/null 2>&1; then
    for device in $devices; do
      type=$(display_type_for "$device")
      for dir in screenshots/"$type"/*/; do
        echo "asc screenshots validate — $type/$(basename "$dir")"
        asc screenshots validate --path "./$dir" --device-type "$type" >/dev/null
      done
    done
  else
    echo "asc absent du PATH — validation par locale sautée"
  fi
fi

bold "OK — screenshots/IPHONE_65/ et screenshots/IPAD_PRO_3GEN_129/ sont prêts à l'envoi"
