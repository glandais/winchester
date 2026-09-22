#!/usr/bin/env python3
"""Rend les scénarios sonores d'une étape et garde leur md5.

    ./Tools/Measure/wav-md5.py <étape> [-j N]      # 58 rendus, ~1 min 40

Les bilans de `run.sh` sont en PLAN_ONLY : ils ne voient pas le son. Ici les
scénarios sont rendus pour de bon — les deux démos, les démarrages, les
installations, les journées du README, les passes de 1993 — et hachés : deux
étapes aux mêmes md5 sonnent pareil, au bit près.

Le binaire est $MEASURE_DIR/bin-<étape>/rendertrace ; les empreintes vont dans
$MEASURE_DIR/wav-<étape>/md5.txt (nom, md5, octets). Les WAV de moins de 80 Mo sont
gardés pour l'écoute, les autres effacés une fois hachés.
"""
import hashlib, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.abspath(os.environ.get("MEASURE_DIR", ".build/measure"))
step = sys.argv[1]
jobs = int(sys.argv[sys.argv.index("-j") + 1]) if "-j" in sys.argv else 4
BIN = os.path.join(ROOT, f"bin-{step}")
OUT = os.path.join(ROOT, f"wav-{step}")
os.makedirs(OUT, exist_ok=True)

PROFILES = [f"{p}-{y}" for y in (1993, 1996, 1999, 2003, 2007, 2012)
            for p in ("dev", "famille", "gamer", "secretaire")]
PROFILES = [p.replace("famille-1993", "poweruser-1993") for p in PROFILES]

scenarios = [("demo-boot", ""), ("demo-defrag", "defrag")]
scenarios += [(f"boot-{p}", f"boot:{p}") for p in PROFILES]
scenarios += [(f"install-{p}", f"install:{p}") for p in PROFILES]
scenarios += [(f"day-{d.replace(':', '_')}", f"day:{d}")
              for d in ("dev-1996:20", "dev-1996:300", "famille-2003:400", "gamer-1999:365")]
scenarios += [(f"defrag-{p}", p) for p in PROFILES if p.endswith("1993")]


def render(item):
    name, scenario = item
    wav = os.path.join(OUT, name + ".wav")
    env = dict(os.environ, SCENARIO=scenario)
    done = subprocess.run(["./rendertrace", wav], cwd=BIN, env=env,
                          stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if done.returncode != 0 or not os.path.exists(wav):
        return name, "ECHEC", 0
    digest = hashlib.md5()
    with open(wav, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 22), b""):
            digest.update(chunk)
    size = os.path.getsize(wav)
    if size > 80_000_000:
        os.remove(wav)
    return name, digest.hexdigest(), size


with ThreadPoolExecutor(jobs) as pool:
    rows = sorted(pool.map(render, scenarios))
with open(os.path.join(OUT, "md5.txt"), "w") as handle:
    for name, digest, size in rows:
        handle.write(f"{name}\t{digest}\t{size}\n")
print(len(rows), "rendus,", sum(1 for r in rows if r[1] == "ECHEC"), "échecs")
