#!/usr/bin/env python3
"""Durée et volume déplacé des passes, par étape et par outil.

    ./Tools/Measure/passes.py <étape>:<outil>[,<outil>…] […]

Lance les passes manquantes (PLAN_ONLY, six à la fois) dans
$MEASURE_DIR/out-<étape>/pass-<profil>-<outil>.txt, puis les tabule. Un outil
qui ne va pas avec le format du profil (windows95 sur NTFS…) est sauté.
"""
import os, re, sys, subprocess, collections
from concurrent.futures import ThreadPoolExecutor
ROOT = os.path.abspath(os.environ.get("MEASURE_DIR", ".build/measure"))
PROFILES = [f"{w}-{y}" for y in ("1993", "1996", "1999", "2003", "2007")
            for w in ("dev", "famille", "gamer", "secretaire", "poweruser")
            if not (w == "poweruser" and y != "1993") and not (w == "famille" and y == "1993")]
FAT_ONLY = {"windows95", "frontierCompaction"}
NTFS_ONLY = {"windowsXP", "fragmentMerge"}

def fits(p, tool):
    ntfs = p.split("-")[1] >= "2003"
    return not (ntfs and tool in FAT_ONLY) and not (not ntfs and tool in NTFS_ONLY)

jobs, columns = [], []
for arg in sys.argv[1:]:
    step, tools = arg.split(":")
    for tool in tools.split(","):
        columns.append((step, tool))
        for p in PROFILES:
            out = f"{ROOT}/out-{step}/pass-{p}-{tool}.txt"
            if fits(p, tool) and not os.path.exists(out):
                jobs.append((step, p, tool, out))

def run(job):
    step, p, tool, out = job
    os.makedirs(os.path.dirname(out), exist_ok=True)
    env = dict(os.environ, STRATEGY=tool, SCENARIO=p, PLAN_ONLY="1")
    with open(out, "w") as f:
        subprocess.run(["./rendertrace", "/dev/null"], cwd=f"{ROOT}/bin-{step}", env=env,
                       stdout=f, stderr=subprocess.STDOUT)
with ThreadPoolExecutor(6) as pool: list(pool.map(run, jobs))

def fmt(s):
    s = int(round(s))
    return f"{s // 3600} h {s % 3600 // 60:02d}" if s >= 3600 else f"{s // 60} min {s % 60:02d}"

totals = collections.defaultdict(lambda: [0.0, 0])
for p in PROFILES:
    cells = []
    for step, tool in columns:
        if not fits(p, tool): continue
        t = open(f"{ROOT}/out-{step}/pass-{p}-{tool}.txt").read()
        d = float(re.search(r"^durée\s*: ([\d.]+) s", t, re.M).group(1))
        mo = int(re.search(r"déplacé\s*: (\d+) Mo", t).group(1))
        totals[(step, tool, p >= "" and p.split("-")[1] >= "2003")][0] += d
        totals[(step, tool, p.split("-")[1] >= "2003")][1] += mo
        cells.append(f"{step}:{tool} {fmt(d)} ({mo} Mo)")
    print(f"{p:16} " + "  ".join(cells))
print()
for (step, tool, ntfs), (d, mo) in sorted(totals.items()):
    print(f"  {'ntfs' if ntfs else 'fat':5} {step}:{tool:22} {fmt(d):>10}  {mo / 1024:8.1f} Go")
