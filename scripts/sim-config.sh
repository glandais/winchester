#!/usr/bin/env bash
#
# Le seul simulateur que ce dépôt utilise, et aucun autre.
#
# Ce Mac a des ressources limitées : un simulateur démarré coûte des gigaoctets
# de mémoire, et le dossier de l'appareil grossit de plusieurs gigaoctets sur le
# disque. Tout ce qui a besoin d'une destination la résout ici, pour qu'aucune
# compilation ne démarre un appareil que personne n'a demandé.
#
# `iPhone 17 Pro Max` (iOS 26.5) est celui de `~/.claude/CLAUDE.md`, donc celui
# qui est déjà démarré sur cette machine. C'est aussi un grand iPhone, la taille
# que réclament les captures de l'App Store. Un `iPhone 18 Pro Max` (iOS 27.0)
# existe aussi ; en préférer un des deux, jamais les deux à la fois —
# `WINCHESTER_SIM_DEVICE` permet de basculer pour une session entière.
#
# On le source, on ne l'exécute pas :  source "$(dirname "$0")/sim-config.sh"

SIM_DEVICE="${WINCHESTER_SIM_DEVICE:-iPhone 17 Pro Max}"
DERIVED_DATA="${WINCHESTER_DERIVED_DATA:-.build/DerivedData}"

# Écrit l'UDID de $SIM_DEVICE, ou explique ce qui est disponible et échoue.
sim_udid() {
  local udid
  udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
for runtime in devices:
    for device in devices[runtime]:
        if device["name"] == name:
            print(device["udid"])
            sys.exit(0)
sys.exit(1)
' "$SIM_DEVICE") || {
    echo "sim-config: aucun simulateur disponible nommé « ${SIM_DEVICE} »." >&2
    echo "Appareils disponibles :" >&2
    xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime in devices:
    for device in devices[runtime]:
        print("  " + device["name"])
' >&2
    echo "Le créer dans Xcode, ou passer par WINCHESTER_SIM_DEVICE." >&2
    return 1
  }
  echo "$udid"
}

# Démarre $SIM_DEVICE si besoin et attend qu'il soit prêt. Idempotent.
sim_boot() {
  local udid="${1:-}"
  if [ -z "$udid" ]; then udid=$(sim_udid) || return 1; fi
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
}

# La seule -destination qu'un xcodebuild de ce dépôt ait le droit d'employer.
sim_dest() {
  local udid="${1:-}"
  if [ -z "$udid" ]; then udid=$(sim_udid) || return 1; fi
  echo "platform=iOS Simulator,id=${udid}"
}

# L'iPad des captures de l'App Store, et rien d'autre : la fiche en réclame un
# jeu en 13 pouces. Un M4 parce que c'est le cadre que Koubou connaît (« iPad
# Pro 13 - M4 »), à la même définition que le M5. Il ne démarre que pendant
# `scripts/screenshots.sh`, qui éteint l'iPhone avant et le rallume après :
# jamais deux simulateurs à la fois.
IPAD_DEVICE="${WINCHESTER_IPAD_DEVICE:-iPad Pro 13-inch (M4)}"

# Écrit l'UDID de l'iPad des captures, avec les mêmes messages que `sim_udid`.
ipad_udid() {
  SIM_DEVICE="$IPAD_DEVICE" sim_udid
}
