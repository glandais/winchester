#!/usr/bin/env python3
"""Compare deux étapes, bilan par bilan.

    ./Tools/Measure/compare.py base m1                 # tout
    ./Tools/Measure/compare.py base m1 defrag- 0.5     # passes qui bougent de plus de 0,5 %
    ./Tools/Measure/compare.py base m1 --identical     # bilans identiques au texte près

`--identical` compare le texte entier, ligne « génération de … » exceptée : c'est
ce qui prouve qu'une correction n'a rien touché qu'elle ne devait pas.
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
    strip = lambda t: "\n".join(l for l in t.splitlines() if not l.startswith("génération"))
    changed = [n for n in names if strip(text(a, n)) != strip(text(b, n))]
    print(f"{len(names) - len(changed)} identiques, {len(changed)} différents")
    for n in changed:
        print("  " + n)
    sys.exit(0)

for n in names:
    x, y = common(text(a, n)), common(text(b, n))
    if x["duration"] is None or y["duration"] is None:
        continue
    delta = (y["duration"] / x["duration"] - 1) * 100 if x["duration"] else 0
    if threshold is not None and abs(delta) < threshold:
        continue
    print(f"{n:44} {x['duration']:9.1f} → {y['duration']:9.1f} s ({delta:+6.1f} %)  "
          f"requêtes {x['requests']} → {y['requests']}  seeks {x['seeks']} → {y['seeks']}  "
          f"lu/écrit {x['read']}/{x['written']} → {y['read']}/{y['written']} Mo")
