#!/usr/bin/env python3
"""Compare deux étapes, bilan par bilan.

    ./Tools/Measure/compare.py base m1                 # tout
    ./Tools/Measure/compare.py base m1 defrag- 0.5     # passes qui bougent de plus de 0,5 %
    ./Tools/Measure/compare.py base m1 --identical     # bilans identiques au texte près

`--identical` compare le texte entier, ligne « génération de … » et lignes
vides exceptées : c'est ce qui prouve qu'une correction n'a rien touché
qu'elle ne devait pas. Il sort en erreur si un bilan diffère, s'il manque d'un
côté, ou si la première étape n'en a aucun — une preuve sur rien n'en est pas
une.
"""
import glob
import os
import sys

from bilan import MEASURE, common, text

args = [a for a in sys.argv[1:] if not a.startswith("--")]
a, b = args[0], args[1]
prefix = args[2] if len(args) > 2 else ""
threshold = float(args[3]) if len(args) > 3 else None

names = sorted(os.path.basename(f)[:-4]
               for f in glob.glob(os.path.join(MEASURE, f"out-{a}", f"{prefix}*.txt")))

if "--identical" in sys.argv:
    if not names:
        sys.exit(f"aucun bilan « {prefix}* » dans out-{a}")
    strip = lambda t: "\n".join(l.rstrip() for l in t.splitlines()
                                if l.strip() and not l.startswith("génération"))
    missing = [n for n in names if not os.path.exists(os.path.join(MEASURE, f"out-{b}", f"{n}.txt"))]
    changed = [n for n in names if n not in missing and strip(text(a, n)) != strip(text(b, n))]
    print(f"{len(names) - len(changed) - len(missing)} identiques, {len(changed)} différents, "
          f"{len(missing)} absents de out-{b}")
    for n in changed:
        print("  " + n)
    for n in missing:
        print("  absent : " + n)
    sys.exit(1 if changed or missing else 0)

for n in names:
    # Un bilan que la seconde étape ne fait plus — les passes XP sur FAT depuis
    # le chantier 47 — est dit absent, pas comparé.
    if not os.path.exists(os.path.join(MEASURE, f"out-{b}", f"{n}.txt")):
        print(f"{n:44} absent de out-{b}")
        continue
    x, y = common(text(a, n)), common(text(b, n))
    if x["duration"] is None or y["duration"] is None:
        continue
    delta = (y["duration"] / x["duration"] - 1) * 100 if x["duration"] else 0
    if threshold is not None and abs(delta) < threshold:
        continue
    print(f"{n:44} {x['duration']:9.1f} → {y['duration']:9.1f} s ({delta:+6.1f} %)  "
          f"requêtes {x['requests']} → {y['requests']}  seeks {x['seeks']} → {y['seeks']}  "
          f"lu/écrit {x['read']}/{x['written']} → {y['read']}/{y['written']} Mo")
