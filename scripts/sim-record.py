#!/usr/bin/env python3
"""Filme l'écran d'un simulateur, et dit à quel instant la vidéo commence.

    scripts/sim-record.py <udid> <sortie.mov> <témoin>

Lance `simctl io <udid> recordVideo` et écrit dans <témoin>, en secondes Unix,
l'instant où il annonce « Recording started » : c'est l'image zéro de la vidéo,
et elle vient trois quarts de seconde après le lancement de la commande, plus
ou moins selon la charge. `scripts/previews.sh` en retranche l'instant où l'app
a lancé la lecture (le témoin de `ScreenshotMode`), sur la même horloge : le
simulateur partage celle du Mac.

S'arrête sur SIGINT ou SIGTERM, transmis à `simctl`, qui n'écrit la vidéo qu'à
ce moment-là.
"""

import signal
import subprocess
import sys
import time

udid, output, marker = sys.argv[1:4]

recorder = subprocess.Popen(
    ["xcrun", "simctl", "io", udid, "recordVideo", "--codec", "h264", "--force", output],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)


def forward(signum, _frame):
    recorder.send_signal(signal.SIGINT)


signal.signal(signal.SIGINT, forward)
signal.signal(signal.SIGTERM, forward)

for line in recorder.stdout:
    if "Recording started" in line:
        with open(marker, "w") as f:
            f.write(f"{time.time()}\n")
    elif not line.startswith(("Note: No display specified", "Recording completed",
                                "Wrote video to")) and line.strip():
        sys.stderr.write(line)
sys.exit(recorder.wait())
