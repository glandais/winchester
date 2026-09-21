#!/usr/bin/env python3
"""La table du rangement intelligent dans le README : démarrage rangé, morceaux,
trous et durée de passe, contre le disque livré et les outils de son format.

    ./Tools/Measure/smart-table.py <étape des autres outils> <étape du rangement>

Lit les bilans de smart.sh (`rboot-…`) et de passes.py (`pass-…`).
"""
import os, re, sys
ROOT = os.environ.get("MEASURE_DIR", ".build/measure")
base, step = sys.argv[1], sys.argv[2]
from bilan import PROFILES
FAT = ["windows95", "jkDefrag", "ultraDefrag", "frontierCompaction"]
NTFS = ["windowsXP", "jkDefrag", "ultraDefrag", "fragmentMerge"]

def rboot(s, p, t):
    x = open(f"{ROOT}/out-{s}/rboot-{p}-{t}.txt").read()
    g = lambda rx: re.search(rx, x, re.M)
    return dict(boot=float(g(r"^durée\s*: ([\d.]+) s").group(1)) if g(r"^durée") else None,
                fill=int(g(r"(\d+) % plein").group(1)) if g(r"% plein") else None,
                pieces=int(g(r"morceaux\s*: \d+ avant, (\d+) après").group(1)) if g(r"morceaux  ") else None,
                holes=int(g(r"trous libres\s*: \d+ avant, (\d+) après").group(1)) if g(r"trous libres") else None,
                pieces0=int(g(r"morceaux\s*: (\d+) avant").group(1)) if g(r"morceaux  ") else None,
                holes0=int(g(r"trous libres\s*: (\d+) avant").group(1)) if g(r"trous libres") else None)

def pass_duration(s, p, t):
    x = open(f"{ROOT}/out-{s}/pass-{p}-{t}.txt").read()
    return float(re.search(r"^durée\s*: ([\d.]+) s", x, re.M).group(1))

def n(v): return f"{v:,}".replace(",", " ") if v >= 10_000 else str(v)
def sec(v): return f"{v:.1f}".replace(".", ",")
def dur(s):
    s = int(round(s))
    if s < 60: return f"{s} s"
    if s < 3600: return f"{s // 60} min {s % 60:02d}"
    return f"{s // 3600} h {s % 3600 // 60:02d}"

print("| scénario | plein | démarrage : livré / meilleur outil / **intelligent** | morceaux restants : meilleur outil / **intelligent** | trous libres : meilleur outil / **intelligent** | passe |")
print("|---|---:|---:|---:|---:|---:|")
totals = {}
for p in PROFILES:
    ntfs = p.split("-")[1] >= "2003"
    tools = NTFS if ntfs else FAT
    smart = "smart"
    s = rboot(step, p, smart)
    shipped = rboot(base, p, "-")
    others = {t: rboot(base, p, t) for t in tools}
    fastest = min(others, key=lambda t: others[t]["boot"])
    fewest = min(others, key=lambda t: others[t]["pieces"])
    tightest = min(others, key=lambda t: others[t]["holes"])
    fam = "ntfs" if ntfs else "fat"
    tot = totals.setdefault(fam, [0, 0, 0, 0, 0, 0, 0, 0])
    for i, v in enumerate([shipped["boot"], others[fastest]["boot"], s["boot"], others[fewest]["pieces"],
                           s["pieces"], others[tightest]["holes"], s["holes"], pass_duration(step, p, smart)]):
        tot[i] += v
    print(f"| `{p}` | {s['fill']} % | {sec(shipped['boot'])} / {sec(others[fastest]['boot'])} / **{sec(s['boot'])}** "
          f"| {n(others[fewest]['pieces'])} / **{n(s['pieces'])}** | {n(others[tightest]['holes'])} / **{n(s['holes'])}** "
          f"| {dur(pass_duration(step, p, smart))} |")
print()
for fam, t in totals.items():
    print(f"{fam} : démarrage {sec(t[0])} / {sec(t[1])} / {sec(t[2])} s ; morceaux {t[3]} / {t[4]} ; "
          f"trous {t[5]} / {t[6]} ; passes {dur(t[7])}")
