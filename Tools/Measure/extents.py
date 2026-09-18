#!/usr/bin/env python3
"""Combien de fichiers en combien de morceaux : l'observable du lot 4.

    ./Tools/Measure/run.sh <étape> disks
    ./Tools/Measure/extents.py base incr entre dirs            # dev-2003, dev-1996
    ./Tools/Measure/extents.py --all base dirs                 # les vingt volumes
    ./Tools/Measure/extents.py --profiles famille-2003 -- base dirs

L'histogramme a les colonnes de `FILESYSTEM_EXPERT_REVIEW.md` §2 — 1 extent, 2,
3-4, 5-16, 17-64, plus de 64 — et compte les fichiers non résidents. La
« traîne » est la part des fichiers de plus d'un cluster qui sont en 2 à 16
morceaux : c'est elle qui manquait, et un taux global de fichiers fragmentés
la noie dans la démographie du volume.

Suivent le taux de fragmentation (parmi les fragmentables), les répertoires
quand le binaire les décrit, et le coût de génération.
"""
import sys

from bilan import EXTENT_CLASSES, PROFILES, decimal, disk, number

args = sys.argv[1:]
profiles = ["dev-2003", "dev-1996"]
if "--all" in args:
    profiles = PROFILES
    args.remove("--all")
if "--profiles" in args:
    i, j = args.index("--profiles"), args.index("--")
    profiles = args[i + 1:j]
    args = args[:i] + args[j + 1:]
steps = args

print("| volume | étape | " + " | ".join(EXTENT_CLASSES) + " | traîne 2–16 | fragmentés | répertoires | génération |")
print("|---|---|" + "---:|" * (len(EXTENT_CLASSES) + 4))
for p in profiles:
    for s in steps:
        d = disk(s, p)
        tail = sum(d["histogram"][1:4])
        share = tail / d["fragmentable"] * 100 if d["fragmentable"] else 0
        dirs = number(d["directories"])
        if d["directoryClusters"] is not None:
            dirs += f" ({number(d['multiCluster'])} > 1 cl., {number(d['fragmentedDirectories'])} fragm.)"
        print(f"| `{p}` | {s} | " + " | ".join(number(c) for c in d["histogram"])
              + f" | {number(tail)} ({decimal(share)} %) | {decimal(d['ratio'])} % | {dirs} | {number(d['generationMs'])} ms |")
