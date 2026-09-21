#!/usr/bin/env python3
"""Hook PreToolUse : refuse une commande Bash qui piloterait un autre simulateur.

Ce Mac a des ressources limitées et ne peut pas s'offrir plusieurs simulateurs
démarrés. La convention est écrite dans `CLAUDE.md`, mais une convention n'est
qu'une demande — voici ce qui la fait tenir. Lit l'appel d'outil en JSON sur
l'entrée standard ; une sortie 2 bloque l'appel et rend stderr à l'agent, une
sortie 0 le laisse passer.

L'appareil n'est jamais défini ici : il vient de `scripts/sim-config.sh`, de
sorte que le garde-fou et les scripts ne peuvent pas diverger.

Branché depuis `.claude/settings.json` comme hook `PreToolUse` sur `Bash`.
"""

import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# `xcrun xcodebuild …` is the same call as `xcodebuild …`.
SEPARATORS = re.compile(r"(?:&&|\|\||[;&|\n])")
HEREDOC = re.compile(r"<<-?\s*[\"']?(\w+)[\"']?")
READ_ONLY = ("-showBuildSettings", "-showdestinations", "-list", "archive")


def sim_config():
    """(device, udid) from sim-config.sh; udid is "" if it cannot be resolved."""
    script = 'source "$1/scripts/sim-config.sh"; echo "$SIM_DEVICE"; sim_udid'
    out = subprocess.run(["bash", "-c", script, "_", REPO],
                         capture_output=True, text=True)
    lines = out.stdout.splitlines()
    return (lines[0] if lines else ""), (lines[1] if len(lines) > 1 else "")


def strip_heredocs(text):
    """Drop heredoc bodies: they are data, not commands.

    Writing *about* xcodebuild — in a markdown file, a comment, this very
    script — must not trip the guard.
    """
    kept, lines, i = [], text.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        kept.append(line)
        match = HEREDOC.search(line)
        if match:
            tag = match.group(1)
            i += 1
            while i < len(lines) and lines[i].strip() != tag:
                i += 1
        i += 1
    return "\n".join(kept)


def invocations(text, name):
    """Command segments whose first word is `name`, optionally via xcrun."""
    for segment in SEPARATORS.split(text):
        words = segment.split()
        if words and words[0] == "xcrun":
            words = words[1:]
        if words and words[0].rsplit("/", 1)[-1] == name:
            yield " ".join(words)


def refuse(device, why):
    print(f"Bloqué : ce dépôt n'utilise qu'un simulateur — {device}.", file=sys.stderr)
    print(f"\n{why}\n", file=sys.stderr)
    print("Passer par l'enveloppe, qui épingle la destination et le DerivedData :",
          file=sys.stderr)
    print("  ./scripts/xcb.sh build | run | strings | gen", file=sys.stderr)
    print("  ./scripts/xcb.sh -- <arguments xcodebuild bruts>", file=sys.stderr)
    print("Voir la section « Simulateur » de CLAUDE.md.", file=sys.stderr)
    sys.exit(2)


def main():
    try:
        command = json.load(sys.stdin).get("tool_input", {}).get("command", "")
    except Exception:
        return  # Un hook qui ne sait pas lire son entrée ne doit pas bloquer la session.
    if not command:
        return

    # Le script est le chemin sanctionné ; ce qu'il lance est déjà épinglé.
    if "scripts/xcb.sh" in command:
        return
    # Rien d'autre ne peut démarrer un simulateur : on évite l'aller-retour simctl.
    if "xcodebuild" not in command and "simctl" not in command:
        return

    device, udid = sim_config()
    if not device:
        return

    def pinned(segment):
        return device in segment or (bool(udid) and udid in segment)

    body = strip_heredocs(command)

    for call in invocations(body, "xcodebuild"):
        if any(flag in call for flag in READ_ONLY):
            continue  # Les requêtes en lecture et les archives ne démarrent rien.
        if "generic/platform=iOS Simulator" in call:
            refuse(device, "« generic/platform=iOS Simulator » laisse l'appareil libre.")
        if "generic/platform=iOS" in call:
            continue  # Un appareil réel : rien à démarrer.
        if "-destination" not in call:
            refuse(device, "Cet appel xcodebuild n'a pas de -destination : "
                           "Xcode choisit un appareil tout seul.")
        if "platform=iOS Simulator" in call and not pinned(call):
            refuse(device, f"Sa -destination nomme un simulateur autre que {device}.")

    for call in invocations(body, "simctl"):
        words = call.split()
        if len(words) > 1 and words[1] in ("boot", "bootstatus") and not pinned(call):
            refuse(device, f"Elle démarre un simulateur autre que {device}.")


main()
