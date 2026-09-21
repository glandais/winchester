"""Lire les bilans de RenderTrace rangés par `run.sh`.

Commun aux scripts de ce dossier : où sont les bilans, ce qu'on en extrait, et
comment le README écrit les nombres.
"""
import os
import re

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
MEASURE = os.environ.get("MEASURE_DIR", os.path.join(ROOT, ".build", "measure"))

YEARS = ("1993", "1996", "1999", "2003", "2007", "2012")
PROFILES = [f"{p}-{y}" for y in YEARS
            for p in ("dev", "famille", "gamer", "secretaire")]
PROFILES[PROFILES.index("famille-1993")] = "poweruser-1993"
NTFS = [p for p in PROFILES if p.split("-")[1] >= "2003"]

# L'époque de chaque système de `ThinkModel.boot`, par son identifiant ; le
# `default` est Vista.
THINK_ERA = {"msdos-6.22+win31": "1993", "win95-osr1": "1996", "win98se": "1999",
             "winxp-sp1": "2003", "": "2007", "win7-sp1": "2012"}


def think_models(root):
    """Les constantes de `ThinkModel.boot`, lues dans le source, par époque."""
    source = open(os.path.join(root, "Sources", "Model", "BootSession.swift")).read()
    table = re.findall(r'(?:case "([^"]+)"|default):\s+ThinkModel\(perFile: ([\d.]+), perMegabyte: ([\d.]+)\)',
                       source)
    return {THINK_ERA[name]: (name, per_file, per_mb) for name, per_file, per_mb in table}

# Les durées de démarrage que le modèle donnait avant la relecture des experts,
# et sur lesquelles `ThinkModel.boot` est calé (LEDGER.md, chantiers 20 à 22).
# Ce ne sont pas des mesures d'époque : ce sont les cibles du calage. 2012 n'en
# a pas : le modèle d'avant ne connaissait pas Windows 7 (chantier 34).
BOOT_TARGETS = {
    "dev-1993": 41.8, "gamer-1993": 29.5, "poweruser-1993": 42.7, "secretaire-1993": 36.0,
    "dev-1996": 58.7, "famille-1996": 54.4, "gamer-1996": 44.0, "secretaire-1996": 55.4,
    "dev-1999": 57.0, "famille-1999": 66.0, "gamer-1999": 54.8, "secretaire-1999": 56.7,
    "dev-2003": 49.1, "famille-2003": 28.8, "gamer-2003": 70.0, "secretaire-2003": 33.8,
    "dev-2007": 47.0, "famille-2007": 38.3, "gamer-2007": 29.8, "secretaire-2007": 41.9,
}


def text(step, name):
    with open(os.path.join(MEASURE, f"out-{step}", f"{name}.txt")) as f:
        return f.read()


def _int(pattern, t):
    m = re.search(pattern, t, re.M)
    return int(m.group(1)) if m else None


def _float(pattern, t):
    m = re.search(pattern, t, re.M)
    return float(m.group(1)) if m else None


def common(t):
    """Ce que tout bilan porte : durée, requêtes, seeks, lu et écrit, et ce que
    le cache d'écriture du disque a différé."""
    return dict(duration=_float(r"^durée\s+: ([\d.]+)", t),
                requests=_int(r"^requêtes\s+: (\d+)", t),
                seeks=_int(r"^seeks\s+: (\d+)", t),
                meanSeek=_int(r"moy\. (\d+) cyl", t),
                read=_int(r"^lu / écrit\s+: (\d+)", t),
                written=_int(r"^lu / écrit\s+: \d+ / (\d+)", t),
                cachedWrites=_int(r"(\d+) écritures différées", t),
                destages=_int(r"posées en (\d+) vidages", t))


def boot(step, profile):
    t = text(step, f"boot-{profile}")
    d = common(t)
    d.update(os=re.search(r"^système\s+: (.*?)(?: puis .*)?$", t, re.M).group(1),
             files=_int(r"(\d+) ouverts", t),
             think=_float(r"^calcul\s+: ([\d.]+)", t),
             witness=re.search(r"soit ([-+]\d+) %", t).group(1),
             stamped=_int(r"dates d'accès : (\d+)", t),
             stampWrites=_int(r"réécrites en (\d+)", t),
             diskShare=_int(r"^disque\s+: [\d.]+ s \((\d+) % de l'attente\)", t),
             fatPages=_int(r"table FAT32 : (\d+) pages lues", t),
             fatReread=_int(r"dont (\d+) relues après éviction", t))
    return d


def defrag(step, profile, tool, full_blocks=False):
    t = text(step, f"{'full' if full_blocks else 'defrag'}-{profile}-{tool}")
    d = common(t)
    if d["duration"] is None:
        return None  # outil refusé sur ce format
    pair = lambda label: tuple(map(int, re.search(label + r"\s+: (\d+) avant, (\d+) après", t).groups()))
    d.update(files=_int(r"clusters de \d+ Ko, (\d+) fichiers", t),
             fill=_int(r"(\d+) % plein", t),
             moved=_int(r"^déplacements\s+: (\d+) fichiers", t),
             evacuations=_int(r"(\d+) évacuations", t),
             movedMB=_int(r"^déplacé\s+: (\d+) Mo", t),
             fragmented=pair("fragmentés"),
             fragments=pair("morceaux"),
             holes=pair("trous libres"))
    return d


EXTENT_CLASSES = ["1", "2", "3-4", "5-16", "17-64", ">64"]


def disk(step, profile):
    """Un volume généré (`SCENARIO=disk:`) : histogramme d'extents, répertoires,
    coût de génération."""
    t = text(step, f"disk-{profile}")
    counts = dict(re.findall(r"(\S+?)=(\d+)", re.search(r"^extents\s+: (.*)$", t, re.M).group(1)))
    d = dict(generationMs=_int(r"^génération\s+: (\d+) ms", t),
             files=_int(r"^fichiers\s+: (\d+)", t),
             residents=_int(r"(\d+) résidents", t),
             histogram=[int(counts[c]) for c in EXTENT_CLASSES],
             fragmented=_int(r"^fragmentés\s+: (\d+) sur", t),
             fragmentable=_int(r"sur (\d+) fragmentables", t),
             ratio=_float(r"fragmentables, ([\d.]+) %", t),
             worst=_int(r"^pire fichier\s+: (\d+)", t),
             holes=_int(r"^trous libres\s+: (\d+)", t),
             failed=_int(r"^refusées\s+: (\d+)", t),
             directories=_int(r"^répertoires\s+: (\d+)", t),
             directoryClusters=_int(r"^répertoires\s+: \d+, (\d+) clusters", t),
             multiCluster=_int(r"(\d+) en plusieurs clusters", t),
             fragmentedDirectories=_int(r"(\d+) fragmentés, pire", t),
             worstDirectory=_int(r"pire (\d+) extents", t))
    return d


# --- Les nombres comme le README les écrit ---------------------------------

def number(x):
    """12 345 → « 12 345 »."""
    return f"{int(round(x)):,}".replace(",", " ")


def decimal(x, digits=1):
    return f"{x:.{digits}f}".replace(".", ",")


def duration(seconds):
    """Arrondie à la seconde : « 8 s », « 5 min 54 », « 1 h 16 »."""
    s = int(round(seconds))
    if s < 60:
        return f"{s} s"
    if s < 3600:
        return f"{s // 60} min {s % 60:02d}"
    return f"{s // 3600} h {(s % 3600) // 60:02d}"


def gigabytes(mb):
    """Les Go du README sont des Mo divisés par 1 024."""
    return decimal(mb / 1024)


def rounded(x):
    """L'arrondi du README : au plus proche, la moitié vers le haut."""
    return int(x + 0.5) if x >= 0 else -int(-x + 0.5)


def signed(x):
    """+3, −2, −0 : les écarts au témoin comme le README les écrit."""
    return str(x).replace("-", "−") if str(x).startswith("-") else f"+{x}"


WORDS = ["zéro", "un", "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf", "dix",
         "onze", "douze", "treize", "quatorze", "quinze", "seize"]


def word(n):
    """Un petit nombre en toutes lettres, comme la prose l'écrit."""
    return WORDS[n] if 0 <= n < len(WORDS) else number(n)
