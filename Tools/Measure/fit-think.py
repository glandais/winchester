#!/usr/bin/env python3
"""Quelle constante de `ThinkModel` a absorbé l'écart à la cible ?

    ./Tools/Measure/fit-think.py <étape>

Le temps de calcul d'un démarrage est `perFile × fichiers + perMegabyte × Mo`.
Pour chaque époque, on ajuste l'une **ou** l'autre seule sur ses quatre profils
(moindres carrés sur l'écart à la cible) et on compare les résidus : la
constante qui laisse les plus petits est celle dont la description avait
absorbé le défaut. C'est ce qui a désigné `perMegabyte` au chantier 22 — et
c'est ce qui empêche de tourner une constante comme un bouton.

Les valeurs courantes sont lues dans `ThinkModel.boot` : l'étape mesurée doit
avoir été construite avec ces valeurs-là.
"""
import sys

from bilan import BOOT_TARGETS, PROFILES, ROOT, boot, think_models

step = sys.argv[1]
# 2012 n'a pas de cible : rien à ajuster.
eras = {y: m for y, m in sorted(think_models(ROOT).items())
        if all(p in BOOT_TARGETS for p in PROFILES if p.endswith(y))}

for year, (os_name, per_file, per_mb) in eras.items():
    per_file, per_mb = float(per_file), float(per_mb)
    rows = []
    for p in (p for p in PROFILES if p.endswith(year)):
        b = boot(step, p)
        megabytes = (b["think"] - per_file * b["files"]) / per_mb
        rows.append((p, b["files"], megabytes, BOOT_TARGETS[p] - b["duration"]))
    k = sum(mb * gap for _, _, mb, gap in rows) / sum(mb * mb for _, _, mb, _ in rows)
    j = sum(n * gap for _, n, _, gap in rows) / sum(n * n for _, n, _, _ in rows)
    print(f"{year} ({os_name or 'vista'}) perMegabyte {per_mb} → {per_mb + k:.3f}   "
          f"ou perFile {per_file} → {per_file + j:.4f}")
    for p, n, mb, gap in rows:
        print(f"    {p:16} {n:4} fichiers {mb:6.1f} Mo  écart {gap:+5.1f} s  "
              f"résidu perMegabyte {gap - k * mb:+5.1f}  résidu perFile {gap - j * n:+5.1f}")
