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

BUNDLE_ID="io.github.glandais.winchester"
OUT_ROOT="screenshots/flat"
APP="${DERIVED_DATA}/Build/Products/Screenshots-iphonesimulator/Winchester.app"

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
# Le disque de la démo se fabrique en une dizaine de secondes en Debug ; au-delà
# de ce délai, quelque chose s'est mal passé.
READY_TIMEOUT=120

devices=()
locales=()
for arg in "$@"; do
  case "$arg" in
    --iphone) devices+=(iphone) ;;
    --ipad)   devices+=(ipad) ;;
    -*)       echo "✖ option inconnue : $arg" >&2; exit 2 ;;
    *)        locales+=("$arg") ;;
  esac
done
[ "${#devices[@]}" -gt 0 ] || devices=(iphone ipad)

# Langue de l'app (knownRegions de project.yml) -> locale App Store Connect, qui
# nomme les dossiers. Une langue sans correspondance est une erreur : deviner,
# c'est ranger un marché dans le dossier d'un autre.
asc_locale_for() {
  case "$1" in
    en) echo "en-US" ;;
    fr) echo "fr-FR" ;;
    *)
      echo "✖ « $1 » est dans knownRegions mais n'a pas de locale App Store" >&2
      echo "  Connect dans asc_locale_for() — en ajouter une." >&2
      exit 1
      ;;
  esac
}

if [ "${#locales[@]}" -eq 0 ]; then
  while IFS= read -r lang; do
    locales+=("$(asc_locale_for "$lang")")
  done < <(awk '
    /^  knownRegions:/ { f=1; next }
    f && /^    - / { sub(/^    - /, ""); print; next }
    f { exit }
  ' project.yml)
fi

# Rapport largeur/hauteur attendu d'une capture, à 2 % près : c'est ce qui
# prouve qu'elle vient du bon simulateur, et donc qu'elle ira dans le cadre de
# Koubou (iPhone 17 Pro Max, iPad Pro 13 M4).
ratio_for() {
  case "$1" in
    iphone) echo "1320/2868" ;;
    ipad)   echo "2064/2752" ;;
  esac
}

udid_for() {
  case "$1" in
    iphone) sim_udid ;;
    ipad)   ipad_udid ;;
  esac
}

# ---------------------------------------------------------------- simulateurs

# L'iPhone du dépôt était-il démarré en arrivant ? C'est le seul qu'on rallume
# en partant : l'iPad n'a aucune raison de rester allumé après une capture, même
# s'il l'était avant — le rallumer ferait deux simulateurs.
IPHONE_UDID=$(sim_udid)
IPHONE_WAS_BOOTED=0
xcrun simctl list devices booted | grep -q "$IPHONE_UDID" && IPHONE_WAS_BOOTED=1
CURRENT=""
# La langue du système de l'appareil en cours, à lui rendre (voir plus bas).
SYSTEM_LANGUAGES_BEFORE=""
SYSTEM_LOCALE_BEFORE=""

# Met le *système* du simulateur courant en `$1` (une langue) / `$2` (une
# locale) et redémarre SpringBoard pour qu'il la prenne.
#
# La barre d'état est dessinée par le système, que `-AppleLanguages` ne touche
# pas : l'iPad y écrit la date, et l'écrivait en français sur les captures
# anglaises tant que le simulateur était en français.
set_system_locale() {
  xcrun simctl spawn "$CURRENT" defaults write -g AppleLanguages -array "$1" >/dev/null 2>&1 || true
  xcrun simctl spawn "$CURRENT" defaults write -g AppleLocale -string "$2" >/dev/null 2>&1 || true
  xcrun simctl spawn "$CURRENT" launchctl stop com.apple.SpringBoard >/dev/null 2>&1 || true
  sleep 6
}

restore_simulators() {
  if [ -n "$CURRENT" ]; then
    if [ -n "$SYSTEM_LANGUAGES_BEFORE" ] && [ -n "$SYSTEM_LOCALE_BEFORE" ]; then
      set_system_locale "$SYSTEM_LANGUAGES_BEFORE" "$SYSTEM_LOCALE_BEFORE"
    fi
    xcrun simctl status_bar "$CURRENT" clear >/dev/null 2>&1 || true
    xcrun simctl terminate "$CURRENT" "$BUNDLE_ID" >/dev/null 2>&1 || true
    if [ "$CURRENT" != "$IPHONE_UDID" ]; then
      echo "▸ extinction de l'iPad"
      xcrun simctl shutdown "$CURRENT" >/dev/null 2>&1 || true
    fi
  fi
  if [ "$IPHONE_WAS_BOOTED" = 1 ] && [ "$CURRENT" != "$IPHONE_UDID" ]; then
    echo "▸ redémarrage de ${SIM_DEVICE}, démarré avant la capture"
    xcrun simctl boot "$IPHONE_UDID" >/dev/null 2>&1 || true
  fi
}
trap restore_simulators EXIT

# Démarre `$1` après avoir éteint tout autre simulateur : un seul à la fois.
use_simulator() {
  local target="$1" udid
  for udid in $(xcrun simctl list devices booted -j | python3 -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        print(d["udid"])
'); do
    if [ "$udid" != "$target" ]; then
      echo "▸ extinction de $udid (un seul simulateur à la fois)"
      xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    fi
  done
  CURRENT="$target"
  sim_boot "$target"
  SYSTEM_LANGUAGES_BEFORE="$(xcrun simctl spawn "$target" defaults read -g AppleLanguages 2>/dev/null | tr -d ' \n"()' || true)"
  SYSTEM_LOCALE_BEFORE="$(xcrun simctl spawn "$target" defaults read -g AppleLocale 2>/dev/null || true)"
}

# ---------------------------------------------------------------- construction

echo "▸ construction (configuration Screenshots)"
# Une construction pour simulateur vaut pour tous les appareils de la même
# architecture : l'iPad installe le même produit. La destination ne démarre rien.
xcodebuild -project Winchester.xcodeproj \
  -scheme Winchester-Screenshots \
  -configuration Screenshots \
  -destination "$(sim_dest "$IPHONE_UDID")" \
  -derivedDataPath "$DERIVED_DATA" \
  build >/dev/null
[ -d "$APP" ] || { echo "✖ produit introuvable : $APP" >&2; exit 1; }

# ---------------------------------------------------------------- captures

apple_locale_for() { echo "${1/-/_}"; }

capture() {
  local udid="$1" screen="$2" lang="$3" apple_locale="$4" file="$5" marker waited=0
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  marker="$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data)/tmp/screenshot-ready"
  rm -f "$marker"
  xcrun simctl launch "$udid" "$BUNDLE_ID" \
    -screenshotMode YES \
    -screenshotScreen "$screen" \
    -onboardingSeen YES \
    -AppleLanguages "($lang)" \
    -AppleLocale "$apple_locale" >/dev/null
  until [ -f "$marker" ]; do
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge "$READY_TIMEOUT" ]; then
      echo "✖ $screen : l'app n'a pas signalé qu'elle était prête en ${READY_TIMEOUT} s" >&2
      exit 1
    fi
  done
  sleep "$SETTLE"
  xcrun simctl io "$udid" screenshot --type=png "$file" >/dev/null 2>&1
}

for device in "${devices[@]}"; do
  udid=$(udid_for "$device")
  echo "▸ $device : ${udid}"
  use_simulator "$udid"

  # Désinstaller d'abord : un conteneur neuf, sans historique de passes ni
  # disques construits, pour que la galerie ne dise « rangé il y a 12 h » que
  # si on le lui fait dire.
  xcrun simctl uninstall "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$APP"

  for locale in "${locales[@]}"; do
    lang="${locale%%-*}"
    set_system_locale "$locale" "$(apple_locale_for "$locale")"
    # L'heure fixe d'Apple, une batterie pleine, tout le réseau — reposés après
    # chaque changement de langue, que le redémarrage de SpringBoard efface.
    # Aucun écran capturé ne dit l'heure qu'il est : rien ne la contredit.
    xcrun simctl status_bar "$udid" override --time "9:41" \
      --batteryLevel 100 --batteryState discharging \
      --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3

    dir="$OUT_ROOT/$device/$locale"
    mkdir -p "$dir"
    rm -f "$dir"/*.png
    echo "▸ $device · $locale"
    for entry in "${CARDS[@]}"; do
      screen="${entry%%:*}"
      name="${entry#*:}"
      capture "$udid" "$screen" "$lang" "$(apple_locale_for "$locale")" "$dir/$name.png"
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
