#!/usr/bin/env bash
#
# La matière des captures de l'App Store : chaque écran, chaque langue, sur
# l'iPhone puis sur l'iPad, sans un seul tap.
#
# Construit l'app dans la configuration `Screenshots` (voir `project.yml`), puis
# la lance une fois par carte et par langue avec les arguments que lit
# `ScreenshotMode` (`Sources/Screenshots/`). Un lancement par capture : rien ne
# dépend d'un libellé d'onglet, qui change d'une langue à l'autre.
#
# Sortie : screenshots/flat/<appareil>/<locale>/NN-nom.png — la capture du
# simulateur à pleine définition, canal alpha aplati. Ce ne sont pas encore les
# fichiers envoyés : Koubou en fait des cartes (cadre et titre), et
# `screenshots/assemble.sh` les range là où `asc` les lit. Voir
# `screenshots/README.md`.
#
# Usage : ./scripts/screenshots.sh [--iphone | --ipad] [locale ...]
#         (par défaut les deux appareils, et toutes les langues de
#          `knownRegions` dans project.yml)
#
# Un seul simulateur démarré à la fois (voir « Simulateur » dans CLAUDE.md) :
# l'iPad ne démarre qu'une fois tout autre simulateur éteint, et s'éteint à la
# fin, même sur une erreur ; l'iPhone du dépôt est rallumé s'il l'était.
#
# Écrit pour le /bin/bash 3.2 de macOS : ni mapfile, ni tableaux associatifs.

set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sim-config.sh

source scripts/sim-capture.sh

OUT_ROOT="screenshots/flat"

# écran de ScreenshotMode -> fichier, dans l'ordre d'envoi (les fichiers partent
# par ordre alphabétique, d'où la numérotation). La carte plein écran ouvre :
# c'est l'image que personne d'autre n'a, et les trois premières cartes sont
# celles qu'affichent les résultats de recherche.
CARDS=(
  "fullmap:01-map"
  "pass:02-pass"
  "platter:03-platter"
  "tools:04-tools"
  "disk:05-disk"
  "instruments:06-instruments"
)

# Ce qu'on laisse à l'écran une fois la passe en place : le plein écran s'ouvre
# une seconde après, la fiche du disque et le choix de l'outil attendent que la
# galerie ait fabriqué le disque.
SETTLE=4

parse_capture_args "$@"

# Rapport largeur/hauteur attendu d'une capture, à 2 % près : c'est ce qui
# prouve qu'elle vient du bon simulateur, et donc qu'elle ira dans le cadre de
# Koubou (iPhone 17 Pro Max, iPad Pro 13 M4).
ratio_for() {
  case "$1" in
    iphone) echo "1320/2868" ;;
    ipad)   echo "2064/2752" ;;
  esac
}

build_capture_app

# ---------------------------------------------------------------- captures

capture() {
  local screen="$1" locale="$2" file="$3"
  launch_staged "$screen" "$locale"
  sleep "$SETTLE"
  xcrun simctl io "$CURRENT" screenshot --type=png "$file" >/dev/null 2>&1
}

for device in "${devices[@]}"; do
  udid=$(udid_for "$device")
  echo "▸ $device : ${udid}"
  use_simulator "$udid"
  install_fresh

  for locale in "${locales[@]}"; do
    prepare_locale "$locale"
    dir="$OUT_ROOT/$device/$locale"
    mkdir -p "$dir"
    rm -f "$dir"/*.png
    echo "▸ $device · $locale"
    for entry in "${CARDS[@]}"; do
      screen="${entry%%:*}"
      name="${entry#*:}"
      capture "$screen" "$locale" "$dir/$name.png"
      echo "   · $name"
    done
  done
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
done

# ---------------------------------------------------------------- vérifications

# Six écrans différents ne peuvent pas donner deux fois la même image. Quand
# c'est le cas, l'app qui a répondu n'est pas celle qu'on a installée : le Debug
# de `xcb.sh run`, installé par-dessus sous le même identifiant, ignore
# `-screenshotScreen` et s'ouvre toujours sur les disques.
echo "▸ six écrans distincts par jeu"
for device in "${devices[@]}"; do
  for locale in "${locales[@]}"; do
    dup="$(md5 -q "$OUT_ROOT/$device/$locale"/*.png | sort | uniq -d | wc -l | tr -d ' ')"
    if [ "$dup" != "0" ]; then
      echo "✖ $device/$locale : captures identiques — l'app lancée n'est pas celle" >&2
      echo "  qu'on a installée. Rien d'autre ne doit piloter le simulateur pendant" >&2
      echo "  une capture (./scripts/xcb.sh run en particulier)." >&2
      exit 1
    fi
  done
done

echo "▸ forme et canal alpha"
for device in "${devices[@]}"; do
  python3 - "$OUT_ROOT/$device" "$(ratio_for "$device")" "${locales[@]}" <<'PY'
import pathlib, sys
from PIL import Image

root, ratio = pathlib.Path(sys.argv[1]), sys.argv[2]
w, h = (int(x) for x in ratio.split("/"))
TARGET, TOLERANCE = w / h, 0.02
for locale in sys.argv[3:]:
    for src in sorted((root / locale).glob("*.png")):
        im = Image.open(src)
        skew = abs((im.width / im.height) / TARGET - 1)
        if skew > TOLERANCE:
            sys.exit(f"{src} fait {im.width}x{im.height}, {skew:.0%} hors du rapport "
                     f"attendu ({ratio}) : ce n'est pas le simulateur du cadre Koubou.")
        # App Store Connect refuse tout canal alpha (IMAGE_ALPHA_NOT_ALLOWED),
        # et `asc screenshots validate` ne le voit pas. Les coins arrondis d'une
        # capture d'iPhone sont transparents : noir derrière, comme le cadre.
        if "A" in im.getbands():
            bg = Image.new("RGB", im.size, (0, 0, 0))
            bg.paste(im, mask=im.getchannel("A"))
            im = bg
        else:
            im = im.convert("RGB")
        im.save(src, "PNG", optimize=True)
        print(f"   · {src}")
PY
done

echo "▸ fini : $OUT_ROOT/<appareil>/<locale>/NN-*.png, ${#CARDS[@]} cartes ×" \
     "${#locales[@]} langues × ${#devices[@]} appareil(s)."
echo "▸ ensuite : kou generate screenshots/koubou/iphone.yaml (et ipad.yaml),"
echo "  puis ./screenshots/assemble.sh."
