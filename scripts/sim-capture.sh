#!/usr/bin/env bash
#
# Ce que partagent les captures de l'App Store (`scripts/screenshots.sh`) et ses
# vidéos (`scripts/previews.sh`) : les arguments, les langues, l'app construite
# dans la configuration `Screenshots`, un simulateur à la fois, la langue du
# système et la barre d'état, et le lancement d'un écran en mode capture.
#
# On le source, on ne l'exécute pas, après `cd` à la racine du dépôt et
# `source scripts/sim-config.sh` :
#
#   source scripts/sim-capture.sh
#   parse_capture_args "$@"      # -> devices=(iphone ipad), locales=(en-US fr-FR)
#   build_capture_app
#   for device in "${devices[@]}"; do use_simulator "$(udid_for "$device")"; … done
#
# Écrit pour le /bin/bash 3.2 de macOS : ni mapfile, ni tableaux associatifs.

BUNDLE_ID="io.github.glandais.winchester"
APP="${DERIVED_DATA}/Build/Products/Screenshots-iphonesimulator/Winchester.app"

# Le disque de la démo se fabrique en une dizaine de secondes en Debug ; au-delà
# de ce délai, quelque chose s'est mal passé.
READY_TIMEOUT=120

# ---------------------------------------------------------------- arguments

# [--iphone | --ipad] [locale ...] -> `devices` et `locales`. Par défaut les
# deux appareils, et toutes les langues de `knownRegions` dans project.yml.
parse_capture_args() {
  devices=()
  locales=()
  local arg lang
  for arg in "$@"; do
    case "$arg" in
      --iphone) devices+=(iphone) ;;
      --ipad)   devices+=(ipad) ;;
      -*)       echo "✖ option inconnue : $arg" >&2; exit 2 ;;
      *)        locales+=("$arg") ;;
    esac
  done
  [ "${#devices[@]}" -gt 0 ] || devices=(iphone ipad)

  if [ "${#locales[@]}" -eq 0 ]; then
    while IFS= read -r lang; do
      locales+=("$(asc_locale_for "$lang")")
    done < <(awk '
      /^  knownRegions:/ { f=1; next }
      f && /^    - / { sub(/^    - /, ""); print; next }
      f { exit }
    ' project.yml)
  fi
}

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

apple_locale_for() { echo "${1/-/_}"; }

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

# Le système du simulateur dans la langue de `$1` (une locale App Store
# Connect), puis la barre d'état d'Apple : l'heure fixe, une batterie pleine,
# tout le réseau — reposés après chaque changement de langue, que le redémarrage
# de SpringBoard efface. Aucun écran capturé ne dit l'heure qu'il est : rien ne
# la contredit.
prepare_locale() {
  set_system_locale "$1" "$(apple_locale_for "$1")"
  xcrun simctl status_bar "$CURRENT" override --time "9:41" \
    --batteryLevel 100 --batteryState discharging \
    --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3
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

# Désinstalle puis installe l'app : un conteneur neuf, sans historique de passes
# ni disques construits, pour que la galerie ne dise « rangé il y a 12 h » que
# si on le lui fait dire.
install_fresh() {
  xcrun simctl uninstall "$CURRENT" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$CURRENT" "$APP"
}

# ---------------------------------------------------------------- construction

build_capture_app() {
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
}

# ---------------------------------------------------------------- lancement

# Le témoin que `ScreenshotMode` écrit une fois la passe en place : l'écran,
# puis l'instant où la lecture est partie, en secondes Unix.
ready_marker() {
  echo "$(xcrun simctl get_app_container "$CURRENT" "$BUNDLE_ID" data)/tmp/screenshot-ready"
}

# Lance l'app sur l'écran `$1`, dans la langue `$2` (une locale App Store
# Connect), avec les arguments de `ScreenshotMode` qui suivent, puis attend son
# témoin. Pas de délai fixe : le temps que prend le disque de la démo varie du
# simple au double d'une machine à l'autre.
launch_staged() {
  local screen="$1" locale="$2" marker waited=0
  shift 2
  xcrun simctl terminate "$CURRENT" "$BUNDLE_ID" >/dev/null 2>&1 || true
  marker="$(ready_marker)"
  rm -f "$marker"
  xcrun simctl launch "$CURRENT" "$BUNDLE_ID" \
    -screenshotMode YES \
    -screenshotScreen "$screen" \
    -onboardingSeen YES \
    -AppleLanguages "(${locale%%-*})" \
    -AppleLocale "$(apple_locale_for "$locale")" \
    "$@" >/dev/null
  until [ -s "$marker" ]; do
    sleep 0.2
    waited=$((waited + 1))
    if [ "$waited" -ge $((READY_TIMEOUT * 5)) ]; then
      echo "✖ $screen : l'app n'a pas signalé qu'elle était prête en ${READY_TIMEOUT} s" >&2
      exit 1
    fi
  done
}
