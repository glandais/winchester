#!/usr/bin/env python3
"""Tabule les bilans de smart.sh : démarrage rangé, morceaux, trous.

    ./Tools/Measure/smart.py <étape> [<étape>…]
"""
import os, re, sys, glob, collections
ROOT = os.environ.get("MEASURE_DIR", ".build/measure")

def read(path):
    t = open(path).read()
    g = lambda rx, conv=float: (lambda m: conv(m.group(1)) if m else None)(re.search(rx, t))
    return dict(boot=g(r"durée\s*: ([\d.]+) s"), disk=g(r"disque\s*: ([\d.]+) s"),
                fresh=g(r"témoin\s*: ([\d.]+) s"),
                frag=g(r"fragmentés\s*: \d+ avant, (\d+) après", int),
                pieces=g(r"morceaux\s*: \d+ avant, (\d+) après", int),
                holes=g(r"trous libres\s*: \d+ avant, (\d+) après", int),
                pieces0=g(r"morceaux\s*: (\d+) avant", int),
                holes0=g(r"trous libres\s*: (\d+) avant", int))

rows = collections.defaultdict(dict)
for step in sys.argv[1:]:
    for f in glob.glob(f"{ROOT}/out-{step}/rboot-*.txt"):
        name = os.path.basename(f)[6:-4]
        p, tool = name.rsplit("-", 1) if not name.endswith("--") else (name[:-2], "-")
        rows[p][tool if len(sys.argv) == 2 else f"{step}:{tool}"] = read(f)

order = lambda p: (p.split("-")[1], p)
tot = collections.defaultdict(lambda: [0, 0, 0, 0])
for p in sorted(rows, key=order):
    base = rows[p].get("-") or next((v for k, v in rows[p].items() if k.endswith(":-")), None)
    print(f"\n{p}  (livré : démarrage {base['boot'] if base else '?'} s, témoin {base['fresh'] if base else '?'} s, "
          f"morceaux {next(iter(rows[p].values()))['pieces0']}, trous {next(iter(rows[p].values()))['holes0']})")
    for tool, r in sorted(rows[p].items()):
        if r["boot"] is None: print(f"   {tool:28} ÉCHEC"); continue
        fam = "fat" if p.split("-")[1] < "2003" else "ntfs"
        t = tot[(fam, tool)]; t[0] += r["boot"]; t[1] += r["pieces"] or 0; t[2] += r["holes"] or 0; t[3] += 1
        print(f"   {tool:28} démarrage {r['boot']:7.1f} s (disque {r['disk']:6.1f})  "
              f"morceaux {r['pieces'] if r['pieces'] is not None else '-':>7}  trous {r['holes'] if r['holes'] is not None else '-':>7}")
print("\nTOTAUX")
for (fam, tool), (b, pc, h, n) in sorted(tot.items()):
    print(f"  {fam:5} {tool:28} démarrage {b:8.1f} s  morceaux {pc:8}  trous {h:7}  ({n})")
