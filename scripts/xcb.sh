#!/usr/bin/env bash
#
# La seule façon de lancer xcodebuild sur un simulateur dans ce dépôt.
#
# Il épingle la destination au simulateur unique déclaré dans `sim-config.sh` et
# un DerivedData local au dépôt, pour qu'aucune compilation ne démarre un
# appareil de son choix — voir la section « Simulateur » de `CLAUDE.md`.
# `scripts/guard-simulator.py` le fait respecter aux agents.
#
# Usage :
#   ./scripts/xcb.sh build            construit le schéma Winchester (Debug)
#   ./scripts/xcb.sh run              construit, installe et lance sur le simulateur
#   ./scripts/xcb.sh strings          construit, puis synchronise le catalogue
#   ./scripts/xcb.sh gen              (re)génère le .xcodeproj depuis project.yml
#   ./scripts/xcb.sh -- <args...>     xcodebuild brut, destination toujours épinglée
#
# Les arguments qui suivent la sous-commande sont passés à xcodebuild.
#
# Les tests ne passent pas par ici : le noyau et la couche Model se testent en
# ligne de commande avec `swift test`, sans simulateur. `project.yml` ne déclare
# pas de cible de test Xcode.

set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sim-config.sh

PROJECT="Winchester.xcodeproj"
SCHEME="${WINCHESTER_SCHEME:-Winchester}"
BUNDLE_ID="io.github.glandais.winchester"
CATALOG="Sources/Resources/Localizable.xcstrings"
INFO_CATALOG="Sources/Resources/InfoPlist.xcstrings"

# Le .xcodeproj n'est pas versionné : dans un worktree neuf, ou après l'ajout
# d'un fichier, il faut le régénérer. Sans ça la compilation échoue sur un
# « cannot find X in scope » qui n'a rien d'une erreur de code.
generate() {
  command -v xcodegen >/dev/null || {
    echo "xcb: xcodegen est absent (brew install xcodegen)" >&2
    exit 1
  }
  echo "▸ xcodegen generate"
  xcodegen generate --quiet
}

command="${1:-build}"
shift || true

[ -d "$PROJECT" ] || generate

UDID=$(sim_udid)
DEST=$(sim_dest "$UDID")

xcb() {
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -destination "$DEST" -derivedDataPath "$DERIVED_DATA" "$@"
}

case "$command" in
  gen)
    generate
    ;;

  build)
    echo "▸ build sur ${SIM_DEVICE} (${UDID})"
    xcb build "$@"
    ;;

  run)
    # Chemin explicite vers le produit Debug : un `Release-iphonesimulator/`
    # périmé traîne dans le même dossier, et un `find … | head -1` tombe
    # dessus — on installe alors un binaire d'avant la modification.
    echo "▸ build sur ${SIM_DEVICE} (${UDID})"
    xcb build "$@"
    app="${DERIVED_DATA}/Build/Products/Debug-iphonesimulator/Winchester.app"
    [ -d "$app" ] || { echo "xcb: produit introuvable : ${app}" >&2; exit 1; }
    sim_boot "$UDID"
    echo "▸ install ${app}"
    xcrun simctl install "$UDID" "$app"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID"
    echo "▸ l'écran reste blanc une dizaine de secondes en Debug : le disque de"
    echo "  la démo se fabrique au lancement. Attendre avant de capturer."
    ;;

  strings)
    # `xcstringstool sync` a deux façons silencieuses de détruire un catalogue,
    # toutes deux traitées ici : le catalogue est synchronisé sur place (une
    # copie hors du dépôt ne résout aucune source et marque toutes les clés
    # périmées), et *toutes* les tranches d'architecture sont passées, pas
    # seulement la première qu'un `head -1` aurait retenue — en omettre une
    # efface l'extractionState des autres.
    echo "▸ build sur ${SIM_DEVICE} (${UDID})"
    xcb build "$@" >/dev/null
    objects="${DERIVED_DATA}/Build/Intermediates.noindex/Winchester.build/Debug-iphonesimulator/Winchester.build/Objects-normal"
    slices=("$objects"/*/*.stringsdata)
    if [ ! -e "${slices[0]}" ]; then
      echo "xcb: aucun .stringsdata sous ${objects}" >&2
      exit 1
    fi
    echo "▸ synchronisation de ${CATALOG} depuis ${#slices[@]} fichier(s) stringsdata"
    xcrun xcstringstool sync "$CATALOG" --stringsdata "${slices[@]}"
    if [ -f "$INFO_CATALOG" ]; then
      xcrun xcstringstool sync "$INFO_CATALOG" --stringsdata "${slices[@]}"
    fi
    echo "▸ fini. Remplir l'unité en et l'unité fr de chaque clé nouvelle ;"
    echo "  extractionState: stale signale une clé morte."
    ;;

  --)
    xcb "$@"
    ;;

  *)
    echo "xcb: sous-commande inconnue « ${command} »" >&2
    sed -n '/^# Usage:/,/^# Les arguments/p' "$0" | sed 's/^#\{1,\} \{0,1\}//' >&2
    exit 1
    ;;
esac
