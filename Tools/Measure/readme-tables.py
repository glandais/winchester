#!/usr/bin/env python3
"""Les chiffres mesurés du README — tables **et** prose —, tirés des bilans
d'une étape.

    ./Tools/Measure/run.sh <étape> full
    ./Tools/Measure/readme-tables.py <étape>            # imprime tables et phrases
    ./Tools/Measure/readme-tables.py <étape> --check    # les confronte au README
    ./Tools/Measure/readme-tables.py <étape> --write    # réécrit le README

Une **table** est reconnue à sa ligne d'en-tête ; ses lignes sont remplacées en
entier. Une **phrase** est un modèle écrit tel qu'il est dans le README, où
chaque chiffre mesuré est un champ `{nom}` : le modèle retrouve la phrase
(les retours à la ligne du README n'y comptent pas), et seuls les champs sont
comparés ou réécrits — le texte autour reste celui du README. Un chiffre qui
n'est dans aucun modèle n'est pas vérifié : la liste `PROSE` est celle des
chiffres que le README tient d'un bilan.

`--check` sort en erreur si une ligne de table, un champ ou une phrase ne
correspond pas, et dit lequel. C'est ce qui empêche un chiffre du texte de
mentir sans qu'un outil le dise.

Quelques phrases comparent la galerie à un modèle privé d'un mécanisme ou
réglé autrement — sans lecture anticipée, sans préchargeur, sans `SMARTDRV`,
la commutation de tête égale au pas de piste, les points de contrôle NTFS à
une seconde, à trente ou en fin de passe. Leurs chiffres viennent
d'un binaire jetable (LEDGER.md, chantier 29), désigné en argument :

    ./Tools/Measure/readme-tables.py final nora=nora nopf=nopf nosd=nosd hs10=hs10 \
        cp1=cp1 cp30=cp30 cpend=cpend --check

Sans lui, ces phrases sont dites non vérifiées, pas fausses.

À valider avant de s'en servir : lancé sur les bilans du commit d'avant, il doit
reproduire le README d'avant — les tables à la ligne près, la prose au champ
près, ou dire lesquels étaient déjà faux.

Ce qu'il ne fait pas :
- la table des trois allocateurs, que `swift test --filter AllocatorComparison`
  imprime ;
- la table du rangement intelligent et sa prose n'en sortent que si
  `smart.sh <étape>` et `passes.py <étape>:smart` ont tourné : elles sont dites
  non vérifiées sinon ;
- les chiffres des journaux (LEDGER.md), qui datent de leur chantier.
"""
import os
import re
import sys

from bilan import (BOOT_TARGETS, MEASURE, NTFS, PROFILES, ROOT, boot, common, decimal, defrag,
                   disk, duration, gigabytes, number, rounded, signed, text, think_models, word)

args = [a for a in sys.argv[1:] if not a.startswith("--")]
step = args[0]
asides = dict(a.split("=", 1) for a in args[1:] if "=" in a)
d = lambda p, t, full=False: defrag(step, p, t, full)
FAT = [p for p in PROFILES if p not in NTFS]
# Les phrases qui comparent à un binaire jetable du chantier 29 portent sur les
# vingt disques d'alors : 2012 n'existait pas.
PROFILES20 = [p for p in PROFILES if not p.endswith("2012")]


# --- Les tables ---------------------------------------------------------------

TABLES = []


def table(header, separator, available=lambda: True):
    """Déclare une table : son en-tête et son séparateur, tels que dans le
    README ; la fonction décorée rend ses lignes. `available` dit si les
    bilans dont elle a besoin existent — sinon elle est non vérifiée."""
    def register(rows):
        TABLES.append((header, separator, rows, available))
        return rows
    return register


ORDER = ["gamer-2003", "secretaire-2003", "famille-2003", "dev-2003",
         "secretaire-2007", "famille-2007", "gamer-2007", "dev-2007",
         "secretaire-2012", "famille-2012", "gamer-2012", "dev-2012"]


@table("| scénario NTFS     | plein | requêtes | durée      | déplacés | fragmentés avant → après | morceaux avant → après |",
       "|-------------------|------:|---------:|-----------:|---------:|--------------------------|------------------------|")
def xp_ntfs(_):
    for p in ORDER:
        x = d(p, "windowsXP")
        (fb, fa), (mb, ma) = x["fragmented"], x["fragments"]
        fa = f"**{fa}**" if fa == 0 and fb > 0 else str(fa)
        ma = f"**{number(ma)}**" if ma == 0 and mb > 0 else number(ma)
        yield (f"| `{p}`".ljust(20) + f"| {x['fill']:>3} % | {number(x['requests']):>8} | {duration(x['duration']):>10} "
               f"| {x['moved']:>8} | {number(fb) + ' → ' + fa:24} | {number(mb) + ' → ' + ma:22} |")


@table("| scénario NTFS     | morceaux restants, XP | UltraDefrag |  requêtes XP → UD |    durée XP → UD |",
       "|-------------------|----------------------:|------------:|------------------:|-----------------:|")
def xp_ud(_):
    for p in ORDER[1:]:
        x, u = d(p, "windowsXP"), d(p, "ultraDefrag")
        yield (f"| `{p}`".ljust(20) + f"| {number(x['fragments'][1]):>21} | {number(u['fragments'][1]):>11} "
               f"| {number(x['requests']) + ' → ' + number(u['requests']):>17} "
               f"| {duration(x['duration']) + ' → ' + duration(u['duration']):>16} |")


@table("| scénario | plein | morceaux restants, XP | UltraDefrag | JkDefrag | durée, XP → JkDefrag | Go déplacés, XP → JkDefrag |",
       "|---|---:|---:|---:|---:|---:|---:|")
def jk_ntfs(_):
    for p in ["secretaire-2003", "famille-2003", "dev-2003", "gamer-2003", "famille-2007", "gamer-2007"]:
        x, u, j = d(p, "windowsXP"), d(p, "ultraDefrag"), d(p, "jkDefrag")
        yield (f"| `{p}` | {x['fill']} % | {number(x['fragments'][1])} | {number(u['fragments'][1])} "
               f"| {number(j['fragments'][1])} | {duration(x['duration'])} → {duration(j['duration'])} "
               f"| {gigabytes(x['movedMB'])} → {gigabytes(j['movedMB'])} |")


MERGE_TOOLS = ["windowsXP", "ultraDefrag", "jkDefrag", "fragmentMerge"]
MERGE_ORDER = ["dev-2003", "famille-2003", "secretaire-2003", "gamer-2003",
               "dev-2007", "famille-2007", "gamer-2007", "secretaire-2007",
               "dev-2012", "famille-2012", "gamer-2012", "secretaire-2012"]


@table("| scénario | plein | durée, XP / UltraDefrag / JkDefrag / recollage | morceaux restants | trous libres |",
       "|---|---:|---:|---:|---:|")
def merge(_):
    for p in MERGE_ORDER:
        xs = [d(p, t) for t in MERGE_TOOLS]
        cols = lambda f: " / ".join(f(x) for x in xs[:3]) + f" / **{f(xs[3])}**"
        yield (f"| `{p}` | {xs[0]['fill']} % | {cols(lambda x: duration(x['duration']))} "
               f"| {cols(lambda x: number(x['fragments'][1]))} | {cols(lambda x: number(x['holes'][1]))} |")


@table("| | système | fichiers | lu | durée | dont calcul | témoin |",
       "|---|---|---|---|---|---|---|")
def boots_table(_):
    for p in ["gamer-1993", "dev-1993", "gamer-1996", "famille-1999",
              "secretaire-1999", "gamer-2003", "dev-2003", "famille-2007", "gamer-2012"]:
        b = boot(step, p)
        yield (f"| `{p}` | {b['os']} | {number(b['files'])} | {b['read']} Mo | {decimal(b['duration'])} s "
               f"| {round(b['think'] / b['duration'] * 100)} % | {b['witness'].replace('-', '−')} % |")


@table("| | source | posé | archives | redémarrages | durée |",
       "|---|---|---|---:|---:|---:|")
def installs_table(_):
    for p in ["gamer-1993", "secretaire-1996", "famille-1999", "famille-2003", "gamer-2007", "gamer-2012"]:
        t = text(step, f"install-{p}")
        files, mb = map(int, re.search(r"posé\s+: (\d+) fichiers, (\d+) Mo", t).groups())
        size = f"{mb} Mo" if mb < 1000 else f"{decimal(mb / 1000)} Go"
        yield (f"| `{p}` | {re.search(r'source\s+: (.*)', t).group(1)} | {number(files)} fichiers, {size} "
               f"| {re.search(r'archives\s+: (\d+)', t).group(1)} | {re.search(r'redémarrages\s+: (\d+)', t).group(1)} "
               f"| {duration(common(t)['duration'])} |")


DAYS = ["dev-1996_20", "dev-1996_300", "famille-2003_400", "gamer-1999_365"]


@table("| journée | activités | lu / écrit | durée |",
       "|---|---|---|---:|")
def days_table(readme_rows):
    # La colonne « activités » est du texte : elle reste celle du README.
    activities = {r.split("|")[1].strip(): r.split("|")[2].strip() for r in readme_rows}
    for name in DAYS:
        x = common(text(step, f"day-{name}"))
        profile, day = name.split("_")
        key = f"`{profile}`, jour {day}"
        yield f"| {key} | {activities.get(key, '?')} | {x['read']} / {x['written']} Mo | {duration(x['duration'])} |"


@table("| scénario | plein | durée, 95 → JkDefrag | évacuations, 95 | morceaux restants, 95 → JkDefrag |",
       "|---|---:|---:|---:|---:|")
def jk_fat(_):
    for p in ["dev-1993", "dev-1996", "secretaire-1999", "famille-1999", "gamer-1996"]:
        w, j = d(p, "windows95"), d(p, "jkDefrag")
        yield (f"| `{p}` | {w['fill']} % | {duration(w['duration'])} → {duration(j['duration'])} "
               f"| {number(w['evacuations'])} | {number(w['fragments'][1])} → {number(j['fragments'][1])} |")


FRONTIER_ORDER = ["dev-1993", "secretaire-1993", "poweruser-1993", "gamer-1993", "dev-1996", "famille-1996",
                  "secretaire-1996", "gamer-1996", "dev-1999", "famille-1999", "secretaire-1999", "gamer-1999"]


@table("| scénario | plein | durée, 95 → JkDefrag → frontière | morceaux restants, 95 / JkDefrag / frontière "
       "| trous libres, 95 / JkDefrag / frontière |",
       "|---|---:|---:|---:|---:|")
def frontier(_):
    for p in FRONTIER_ORDER:
        w, j, f = d(p, "windows95"), d(p, "jkDefrag"), d(p, "frontierCompaction")
        yield (f"| `{p}` | {w['fill']} % | {duration(w['duration'])} → {duration(j['duration'])} → "
               f"**{duration(f['duration'])}** | {number(w['fragments'][1])} / {number(j['fragments'][1])} / "
               f"**{number(f['fragments'][1])}** | {number(w['holes'][1])} / {number(j['holes'][1])} / "
               f"**{number(f['holes'][1])}** |")


# --- La prose -----------------------------------------------------------------
#
# Chaque entrée : le modèle, tel qu'il est écrit dans le README, et ses champs.
# Un champ est une chaîne déjà formatée comme le README l'écrit. `needs` nomme
# les binaires jetables dont la phrase a besoin.

PROSE = []


def prose(template, needs=(), **fields):
    PROSE.append((template, needs, fields))


class Timing:
    """Un coût de calcul — la génération d'un volume : il dépend de la machine
    et de sa charge. Il se vérifie à 10 % près, et ne se réécrit qu'au-delà."""
    def __init__(self, formatted, value):
        self.text, self.value = formatted(value), value

    def matches(self, written):
        try:
            return abs(float(written.replace(",", ".")) / self.value - 1) <= 0.10
        except ValueError:
            return False


def total(seconds):
    """Un total s'arrondit à la minute la plus proche, pas à celle d'avant."""
    return duration(round(seconds / 60) * 60)


def minutes(seconds):
    return str(rounded(seconds / 60))


def share(part, whole):
    return rounded(part / whole * 100)


def trail(profile):
    """Fichiers en deux à seize morceaux, parmi les fragmentables."""
    x = disk(step, profile)
    return decimal((x["histogram"][1] + x["histogram"][2] + x["histogram"][3]) / x["fragmentable"] * 100)


boots = {p: boot(step, p) for p in PROFILES}
witness = {p: int(b["witness"]) for p, b in boots.items()}
disks = {p: disk(step, p) for p in PROFILES}

# L'en-tête : les deux démos.
b = boots["secretaire-1999"]
prose("sur `secretaire-1999`, un FAT32 de 4,2 Go vieilli par deux ans de bureautique : {dur} s, dont "
      "{disk} % d'attente du disque, et {wit} % de plus que le même contenu jamais fragmenté",
      dur=decimal(b["duration"]), disk=str(b["diskShare"]), wit=str(witness["secretaire-1999"]))
f = d("dev-1993", "frontierCompaction")
prose("un FAT16 de 210 Mo plein à {fill} % : {dur}, {moved} fichiers déplacés",
      fill=str(f["fill"]), dur=duration(f["duration"]), moved=number(f["moved"]))

# Le scénario de défragmentation.
w = d("dev-1993", "windows95")
x = disks["dev-1993"]
prose("Résultat : {files} fichiers et {dirs} répertoires, {pct} % fragmentés en {frags} morceaux, "
      "{holes} trous dans l'espace libre, à {fill} % de remplissage.",
      files=number(x["files"]), dirs=str(w["files"] - x["files"]),
      pct=str(share(w["fragmented"][0], w["files"])), frags=number(w["fragments"][0]),
      holes=str(w["holes"][0]), fill=str(w["fill"]))
prose("l'outil de 95 déplace {moved} éléments et évacue {evac} fois : c'est ce va-et-vient, pas le volume de "
      "données, qui fait durer une passe — {dur}, quand le tassage à la frontière, qui ne déloge presque "
      "personne, finit en {frontier} ;",
      moved=number(w["moved"]), evac=number(w["evacuations"]), dur=duration(w["duration"]),
      frontier=duration(f["duration"]))

# Le tampon du disque.
x = d("dev-2007", "windowsXP")
prose("partent **en salves** — {n} écritures par vidage en moyenne pour l'outil de XP sur `dev-2007`",
      n=decimal(x["cachedWrites"] / x["destages"]))
if "nora" in asides:
    extra = [boot(asides["nora"], p)["duration"] - boots[p]["duration"] for p in PROFILES20]
    fields = dict(lo=decimal(min(extra)), hi=decimal(max(extra)))
else:
    fields = dict(lo=None, hi=None)
prose("les vingt démarrages dureraient {lo} à {hi} s de plus", needs=("nora",), **fields)

# La commutation de tête, égalée au pas de piste comme le Fireball la publie.
if "hs10" in asides:
    extra = [boot(asides["hs10"], p)["duration"] - boots[p]["duration"] for p in PROFILES20]
    fields = dict(hi=decimal(max(extra)))
else:
    fields = dict(hi=None)
prose("les égaler allongerait les démarrages de {hi} s au plus", needs=("hs10",), **fields)

# La recalibration thermique.
prose("Aucun démarrage n'en contient (le plus long dure {longest} s)",
      longest=str(rounded(max(b["duration"] for b in boots.values()))))

# Les disques d'époque.
prose("en 2 à 16 morceaux atteint {pct} % des fichiers fragmentables sur `secretaire-2003`",
      pct=trail("secretaire-2003"))
prose("(de 0,5 à {pct} % des fichiers fragmentables sur `dev-2007`)", pct=trail("dev-2007"))
prose("Un poste DOS de 1993 après deux ans en a {pct} %.", pct=str(rounded(disks["secretaire-1993"]["ratio"])))
prose("`dev-1996` donne {a} % de fichiers fragmentés au lieu des 35 à 50 % visés, et `secretaire-1999` {b} % "
      "au lieu de 15 à 25 %",
      a=str(rounded(disks["dev-1996"]["ratio"])), b=str(rounded(disks["secretaire-1999"]["ratio"])))
prose("l'allocateur de XP, suivi à la lettre, en produit {c} %", c=str(rounded(disks["famille-2003"]["ratio"])))
prose("se génère en {dev} s en release", dev=Timing(decimal, disks["dev-2007"]["generationMs"] / 1000))
prose("les plus lourds de 2012, un Windows 7 de 500 Go et un de 1 To, en {dev} et {fam} s",
      dev=Timing(decimal, disks["dev-2012"]["generationMs"] / 1000),
      fam=Timing(decimal, disks["famille-2012"]["generationMs"] / 1000))
prose("Les deux disques des démos, fabriqués au lancement, prennent {a} et {b} ms.",
      a=Timing(str, disks["dev-1993"]["generationMs"]), b=Timing(str, disks["secretaire-1999"]["generationMs"]))
prose("`famille-2003` en prend {s} s, parce",
      s=Timing(decimal, disks["famille-2003"]["generationMs"] / 1000))

# Démarrer un disque généré.
shares = [b["think"] / b["duration"] * 100 for b in boots.values()]
durations = [b["duration"] for b in boots.values()]
prose("il pèse entre {lo} et {hi} % du total, et les vingt-quatre démarrages tiennent entre {dlo} et {dhi} s",
      lo=f"{min(shares):.0f}", hi=f"{max(shares):.0f}", dlo=decimal(min(durations)), dhi=decimal(max(durations)))
# Les constantes de `ThinkModel` pour XP et Vista, lues dans le source, et ce
# que l'ajustement de `fit-think.py` en dit : les deux doivent se rejoindre.
think = {year: (per_file, per_mb) for year, (_, per_file, per_mb) in think_models(ROOT).items()}


def fitted(year):
    """`perMegabyte` seul, ajusté sur les quatre profils d'une époque."""
    per_file, per_mb = map(float, think[year])
    rows = [(p, (boots[p]["think"] - per_file * boots[p]["files"]) / per_mb)
            for p in PROFILES if p.endswith(year)]
    k = sum(mb * (BOOT_TARGETS[p] - boots[p]["duration"]) for p, mb in rows) / sum(mb * mb for _, mb in rows)
    return per_mb + k


prose("Pour 2003 et 2007, l'ajustement retombe sur {xp} et {vista} s par mégaoctet",
      xp=decimal(fitted("2003"), 2), vista=decimal(fitted("2007"), 2))
fat_w = [witness[p] for p in FAT]
prose("ne coûte presque rien à un démarrage** : de {lo} à {hi} %", lo=str(min(fat_w)), hi=str(max(fat_w)))
ntfs_w = {p: witness[p] for p in NTFS}
low = min(ntfs_w, key=ntfs_w.get)
prose("l'écart va de {lo} % (`{low}`) à {hi} %, et {n} volumes démarrent aussi vite ou plus vite que leur témoin",
      lo=signed(ntfs_w[low]), low=low, hi=signed(max(ntfs_w.values())),
      n=word(sum(1 for w in ntfs_w.values() if w <= 0)))
b = boots["famille-2007"]
if "nopf" in asides:
    o = boot(asides["nopf"], "famille-2007")
    fields = dict(c0=number(o["meanSeek"]), s0=number(o["seeks"]), d0=decimal(o["duration"]))
else:
    fields = dict(c0=None, s0=None, d0=None)
prose("sur `famille-2007`, le seek moyen passe de {c0} à {c1} cylindres, le nombre de seeks de {s0} à {s1}, "
      "et le démarrage de {d0} à {d1} s", needs=("nopf",),
      c1=number(b["meanSeek"]), s1=number(b["seeks"]), d1=decimal(b["duration"]), **fields)
b = boots["gamer-2003"]
prose("sur `gamer-2003`, {n} dates réécrites en {w} écritures", n=number(b["stamped"]), w=number(b["stampWrites"]))
w98 = [boots[p] for p in PROFILES if p.endswith("1999")]
prose("de {lo} à {hi} pages sur un démarrage de Windows 98",
      lo=str(min(b["fatPages"] for b in w98)), hi=str(max(b["fatPages"] for b in w98)))
prose("et de {lo} à {hi} d'entre elles sont **relues**",
      lo=str(min(b["fatReread"] for b in w98)), hi=str(max(b["fatReread"] for b in w98)))
if "nosd" in asides:
    cost = [boots[p]["duration"] - boot(asides["nosd"], p)["duration"] for p in PROFILES if p.endswith("1993")]
    fields = dict(lo=decimal(min(cost)), hi=decimal(max(cost)))
else:
    fields = dict(lo=None, hi=None)
prose("coûte plus que ce que le cache rend : de {lo} à {hi} s par démarrage", needs=("nosd",), **fields)

# Installer, vivre.
installs = [common(text(step, f"install-{p}"))["duration"] for p in PROFILES]
prose("Les vingt-quatre installations durent de {lo} à {hi} minutes",
      lo=minutes(min(installs)), hi=minutes(max(installs)))
prose("passe d'un seek moyen de {a} cylindres au jour 20 à {b} au jour 300",
      a=number(common(text(step, "day-dev-1996_20"))["meanSeek"]),
      b=number(common(text(step, "day-dev-1996_300"))["meanSeek"]))

# Huit défragmenteurs.
w, x = d("famille-2007", "windows95"), d("famille-2007", "windowsXP")
prose("tampons de 256 Ko : {req95} requêtes et {dur95} de passe simulée pour ranger {frag} fichiers sur {files}. "
      "La passe de XP sur le même volume tient en **{req} requêtes et {dur}**.",
      req95=number(w["requests"]), dur95=duration(w["duration"]),
      frag=number(w["fragmented"][0]), files=number(w["files"]), req=number(x["requests"]),
      dur=duration(x["duration"]))
# La cadence des points de contrôle : 1 s et 30 s au lieu de 5, puis un seul.
if "cp1" in asides and "cp30" in asides:
    moves = [abs(defrag(asides[c], p, t)["fragmented"][1] - d(p, t)["fragmented"][1])
             for c in ("cp1", "cp30") for p in NTFS for t in ("windowsXP", "jkDefrag")]
    fields = dict(n=str(max(moves)))
else:
    fields = dict(n=None)
prose("à une seconde ou à trente, XP et JkDefrag laissent au plus {n} fichiers cassés de plus ou de moins",
      needs=("cp1", "cp30"), **fields)
prose("sur `dev-2007`, XP laisserait alors {once} fichiers en morceaux au lieu de {now}.", needs=("cpend",),
      once=number(defrag(asides["cpend"], "dev-2007", "windowsXP")["fragmented"][1]) if "cpend" in asides else None,
      now=number(d("dev-2007", "windowsXP")["fragmented"][1]))
dev, sec = d("dev-2003", "windowsXP"), d("secretaire-2003", "windowsXP")
prose("remplis à {lo}-{hi} % : le premier répare {r1} fichiers sur {f1}, le second {r2} sur {f2}. La taille",
      lo=str(min(dev["fill"], sec["fill"])), hi=str(max(dev["fill"], sec["fill"])),
      r1=number(dev["fragmented"][0] - dev["fragmented"][1]), f1=number(dev["fragmented"][0]),
      r2=number(sec["fragmented"][0] - sec["fragmented"][1]), f2=number(sec["fragmented"][0]))
prose("ne l'explique pas non plus — {m1} Mo par fichier déplacé chez le développeur, {m2} Mo chez la secrétaire",
      m1=str(rounded(dev["movedMB"] / dev["moved"])), m2=decimal(sec["movedMB"] / sec["moved"]))

x, u = d("famille-2007", "windowsXP"), d("famille-2007", "ultraDefrag")
prose("les {a} morceaux que XP laisse derrière lui tombent à **{b}** — {pct} % de moins — pendant que le "
      "nombre de fichiers fragmentés, lui, reste à {c}.",
      a=number(x["fragments"][1]), b=number(u["fragments"][1]),
      pct=str(rounded((1 - u["fragments"][1] / x["fragments"][1]) * 100)), c=number(u["fragmented"][1]))
prose("Le prix est {rq} fois plus de requêtes et {rt} fois plus de temps.",
      rq=decimal(u["requests"] / x["requests"]), rt=decimal(u["duration"] / x["duration"]))
x, u = d("dev-2007", "windowsXP"), d("dev-2007", "ultraDefrag")
prose("sur `dev-2007`, le seek moyen est de {ud} cylindres contre {xp} chez XP",
      ud=number(u["meanSeek"]), xp=number(x["meanSeek"]))
prose("il nettoie l'un aussi, et laisse {n} morceaux sur l'autre", n=number(u["fragments"][1]))
u, w = d("dev-1996", "ultraDefrag"), d("dev-1996", "windows95")
prose("sur `dev-1996`, la passe tient en {u} contre {w} à l'outil de 95, parce qu'elle n'évacue personne. Elle "
      "laisse {uf} morceaux — et l'outil de 95, sur ce volume-là, en laisse {wf} : à {fill} % de remplissage",
      u=duration(u["duration"]), w=duration(w["duration"]), uf=number(u["fragments"][1]),
      wf=number(w["fragments"][1]), fill=str(w["fill"]))

# Ranger sans évacuer.
table95 = [d(p, "windows95") for p in ["dev-1993", "dev-1996", "secretaire-1999", "famille-1999", "gamer-1996"]]
table95 = [x["duration"] for x in table95 if x["movedMB"] > 0]
prose("ce que Windows 95 fait en {lo} à {hi}, et il laisse",
      lo=duration(min(table95)), hi=duration(max(table95)))
prose("il n'évacue que {n} occupants avant de se retrouver bloqué partout",
      n=word(d("gamer-1996", "windows95")["evacuations"]))
worst = max(FAT, key=lambda p: d(p, "jkDefrag")["fragments"][1])
prose("Sur `{worst}`, le volume FAT où JkDefrag fait son plus mauvais score, il laisse {n} morceaux.",
      worst=worst, n=number(d(worst, "jkDefrag")["fragments"][1]))
pairs = [(d(p, "jkDefrag")["fragments"][1], d(p, "ultraDefrag")["fragments"][1])
         for p in ["secretaire-2003", "famille-2003", "dev-2003", "gamer-2003", "famille-2007", "gamer-2007"]]
prose("mieux sur {better} volumes, un peu moins bien sur {worse}. Mais",
      better=word(sum(1 for j, u in pairs if j < u)), worse=word(sum(1 for j, u in pairs if j > u)))
prose("— {go} Go sur `gamer-2003`", go=gigabytes(d("gamer-2003", "jkDefrag")["movedMB"]))

# Tasser, trier.
prose("sur `secretaire-1999`, il laisse {a} morceaux contre {b} au mode 2",
      a=number(d("secretaire-1999", "jkDefragSortName")["fragments"][1]),
      b=number(d("secretaire-1999", "jkDefrag")["fragments"][1]))
s = d("famille-2007", "jkDefragSortName")
prose("le tri par nom déplace {go} Go en {ev} évacuations et {dur}, et laisse {left} morceaux sur les {before} "
      "du départ ; `gamer-2007` en sort avec {g} morceaux, contre {j} au mode 2",
      go=number(s["movedMB"] / 1024), ev=number(s["evacuations"]), dur=duration(s["duration"]),
      left=number(s["fragments"][1]), before=number(s["fragments"][0]),
      g=number(d("gamer-2007", "jkDefragSortName")["fragments"][1]),
      j=number(d("gamer-2007", "jkDefrag")["fragments"][1]))
# Un volume où l'outil « a de quoi travailler » : il y déplace des données. Sur
# `gamer-1993` (plein) et `gamer-1996` (bloqué), il ne déplace rien.
working = [p for p in FAT if d(p, "windows95")["movedMB"] > 0]
fastest = min(working, key=lambda p: d(p, "windows95")["duration"])
slowest = max(working, key=lambda p: d(p, "windows95")["duration"])
prose("Les passes FAT de Windows 95 vont de {lo} (`{fast}`) à {hi} (`{slow}`) sur les {n} volumes où l'outil a de "
      "quoi travailler",
      lo=duration(d(fastest, "windows95")["duration"]), fast=fastest,
      hi=duration(d(slowest, "windows95")["duration"]), slow=slowest, n=word(len(working)))
prose("a pris un autre outil que celui de 95 : {f} sur `dev-1993` au lieu de {w}, pour le même résultat",
      f=duration(d("dev-1993", "frontierCompaction")["duration"]), w=duration(d("dev-1993", "windows95")["duration"]))
prose("y passe {s} — 170 Mo dont {pct} % des fichiers fragmentables sont en morceaux",
      s=duration(d("secretaire-1993", "windows95")["duration"]), pct=str(rounded(disks["secretaire-1993"]["ratio"])))
prose("quand `dev-1996`, six fois plus gros, en prend {m}.", m=minutes(d("dev-1996", "windows95")["duration"]))
w = d("dev-1999", "windows95")
prose("`dev-1999` déplace {mb} Mo pour un contenu de 6 Go, en {ev} évacuations",
      mb=number(w["movedMB"]), ev=number(w["evacuations"]))
prose("`dev-1999` en sort avec {n} morceaux. C'est pour cela", n=number(w["fragments"][1]))

# Tasser sans changer l'ordre.
f = d("dev-1996", "frontierCompaction")
prose("sur `dev-1996`, {frags} morceaux ne laissent plus {holes}. Une exception",
      frags=number(f["fragments"][1]),
      holes="qu'un trou" if f["holes"][1] == 1 else f"que {number(f['holes'][1])} trous")
sums = {t: [0.0, 0] for t in ("windows95", "jkDefrag", "frontierCompaction")}
for p in FAT:
    for t in sums:
        x = d(p, t)
        sums[t][0] += x["duration"]
        sums[t][1] += x["movedMB"]
prose("la passe dure {f} au total contre {w} pour Windows 95, et elle déplace à peu près autant de données "
      "({fgo} Go contre {wgo})",
      f=total(sums["frontierCompaction"][0]), w=total(sums["windows95"][0]),
      fgo=gigabytes(sums["frontierCompaction"][1]), wgo=gigabytes(sums["windows95"][1]))
y1999 = [p for p in FAT if p.endswith("1999")]
prose("Windows 95 laisse jusqu'à {w} morceaux, la frontière {f} au plus",
      w=number(max(d(p, "windows95")["fragments"][1] for p in y1999)),
      f=number(max(d(p, "frontierCompaction")["fragments"][1] for p in y1999)))
prose("Elle est {r} fois plus longue que JkDefrag ({jk})",
      r=decimal(round(sums["frontierCompaction"][0] / 60) / round(sums["jkDefrag"][0] / 60)),
      jk=total(sums["jkDefrag"][0]))
jk99 = [d(p, "jkDefrag") for p in y1999]
prose("il laisse entre {lo} et {hi} morceaux et de {hlo} à {hhi} trous",
      lo=number(min(x["fragments"][1] for x in jk99)), hi=number(max(x["fragments"][1] for x in jk99)),
      hlo=number(min(x["holes"][1] for x in jk99)), hhi=number(max(x["holes"][1] for x in jk99)))

# Recoller peu.
fr = {p: d(p, "frontierCompaction") for p in NTFS}
biggest = max(NTFS, key=lambda p: fr[p]["movedMB"])
prose("jusqu'à {go} Go et {dur} de passe",
      go=number(fr[biggest]["movedMB"] / 1024), dur=duration(fr[biggest]["duration"]))
x = d("famille-2007", "windowsXP")
prose("sur `famille-2007`, {n} fichiers cassés en {m} morceaux",
      n=number(x["fragmented"][0]), m=number(x["fragments"][0]))
merged = {t: [d(p, t) for p in NTFS] for t in MERGE_TOOLS}
prose("la passe dure {m}, contre {xp} pour XP, {ud} pour UltraDefrag et {jk} pour JkDefrag, et laisse moins de "
      "morceaux ({frags}) et moins de trous ({holes})",
      **{k: total(sum(x["duration"] for x in merged[t]))
         for k, t in (("m", "fragmentMerge"), ("xp", "windowsXP"), ("ud", "ultraDefrag"), ("jk", "jkDefrag"))},
      frags=number(sum(x["fragments"][1] for x in merged["fragmentMerge"])),
      holes=number(sum(x["holes"][1] for x in merged["fragmentMerge"])))
busy = [d(p, "windowsXP") for p in NTFS if d(p, "windowsXP")["moved"] >= 100]
prose("par salves de {lo} à {hi} écritures selon le volume, quand celles du recollage sont éparses, {m} par vidage.",
      lo=decimal(min(x["cachedWrites"] / x["destages"] for x in busy)),
      hi=decimal(max(x["cachedWrites"] / x["destages"] for x in busy)),
      m=decimal(sum(x["cachedWrites"] for x in merged["fragmentMerge"])
                / sum(x["destages"] for x in merged["fragmentMerge"])))
prose("ils les mènent à {xp} et {ud}, sans changer",
      xp=total(sum(d(p, "windowsXP", True)["duration"] for p in NTFS)),
      ud=total(sum(d(p, "ultraDefrag", True)["duration"] for p in NTFS)))
prose("finissent sans un morceau, et elle en laisse {n}.", n=number(d("dev-2007", "fragmentMerge")["fragments"][1]))
prose("contre {f} au tassage à la frontière et {w} à Windows 95",
      f=total(sums["frontierCompaction"][0]), w=total(sums["windows95"][0]))
prose("quand le recollage économe s'en tient à {m}.", m=total(sum(x["duration"] for x in merged["fragmentMerge"])))

# Ce qui ne l'est pas.
prose("l'oreille** : {n} requêtes pour tout un démarrage de `dev-1996`", n=number(boots["dev-1996"]["requests"]))
prose("se tassent en {f} à la frontière et en {w} sous l'outil de 95",
      f=duration(d("dev-1993", "frontierCompaction")["duration"]), w=duration(d("dev-1993", "windows95")["duration"]))


# --- Le rangement intelligent ------------------------------------------------
#
# Ses bilans ne sont pas ceux de `run.sh full` : `smart.sh <étape>` démarre
# chaque disque après chaque outil (`rboot-…`), `passes.py <étape>:smart` joue
# les passes du rangement (`pass-…`). Sans eux, la table et ses phrases sont
# dites non vérifiées.

SMART_ORDER = [f"{w}-{y}" for y in ("1993", "1996", "1999", "2003", "2007")
               for w in ("dev", "famille", "gamer", "secretaire", "poweruser")
               if not (w == "poweruser" and y != "1993") and not (w == "famille" and y == "1993")]
SMART_TOOLS = {False: ["windows95", "jkDefrag", "ultraDefrag", "frontierCompaction"],
               True: ["windowsXP", "jkDefrag", "ultraDefrag", "fragmentMerge"]}


def smart_available():
    folder = os.path.join(MEASURE, f"out-{step}")
    return all(os.path.exists(os.path.join(folder, f"rboot-{p}-{t}.txt"))
               for p in SMART_ORDER for t in ["-", "smart"] + SMART_TOOLS[p in NTFS]) \
        and all(os.path.exists(os.path.join(folder, f"pass-{p}-smart.txt")) for p in SMART_ORDER)


def rboot(p, t):
    x = text(step, f"rboot-{p}-{t}")
    g = lambda rx: re.search(rx, x, re.M)
    return dict(boot=float(g(r"^durée\s*: ([\d.]+) s").group(1)),
                fill=int(g(r"(\d+) % plein").group(1)) if g(r"% plein") else None,
                pieces=int(g(r"morceaux\s*: \d+ avant, (\d+) après").group(1)) if g(r"morceaux  ") else None,
                holes=int(g(r"trous libres\s*: \d+ avant, (\d+) après").group(1)) if g(r"trous libres") else None)


def smart_rows():
    """Par volume : le disque livré, le meilleur des quatre autres outils de son
    format pour chaque mesure, et le rangement, avec la durée de sa passe."""
    rows = {}
    for p in SMART_ORDER:
        others = {t: rboot(p, t) for t in SMART_TOOLS[p in NTFS]}
        passed = common(text(step, f"pass-{p}-smart"))
        moved = re.search(r"^déplacé\s+: (\d+) Mo", text(step, f"pass-{p}-smart"), re.M)
        rows[p] = dict(shipped=rboot(p, "-")["boot"], smart=rboot(p, "smart"),
                       boot=min(x["boot"] for x in others.values()),
                       pieces=min(x["pieces"] for x in others.values()),
                       holes=min(x["holes"] for x in others.values()),
                       duration=passed["duration"], movedMB=int(moved.group(1)))
    return rows


def compact(v):
    """Les nombres de cette table : l'espace des milliers à partir de 10 000."""
    return number(v) if v >= 10_000 else str(v)


@table("| scénario | plein | démarrage : livré / meilleur outil / **intelligent** "
       "| morceaux restants : meilleur outil / **intelligent** | trous libres : meilleur outil / **intelligent** | passe |",
       "|---|---:|---:|---:|---:|---:|", available=smart_available)
def smart_table(_):
    for p, r in smart_rows().items():
        s = r["smart"]
        yield (f"| `{p}` | {s['fill']} % | {decimal(r['shipped'])} / {decimal(r['boot'])} / **{decimal(s['boot'])}** "
               f"| {compact(r['pieces'])} / **{compact(s['pieces'])}** | {compact(r['holes'])} / **{compact(s['holes'])}** "
               f"| {duration(r['duration'])} |")


if smart_available():
    rows = smart_rows()
    fam = {False: [r for p, r in rows.items() if p not in NTFS], True: [r for p, r in rows.items() if p in NTFS]}
    sums = lambda ntfs, f: sum(f(r) for r in fam[ntfs])
    fields = dict(
        fs=decimal(sums(False, lambda r: r["shipped"])), fb=decimal(sums(False, lambda r: r["boot"])),
        fi=decimal(sums(False, lambda r: r["smart"]["boot"])),
        ns=decimal(sums(True, lambda r: r["shipped"])), nb=decimal(sums(True, lambda r: r["boot"])),
        ni=decimal(sums(True, lambda r: r["smart"]["boot"])))
    holes = dict(fh=number(sums(False, lambda r: r["holes"])), fhi=number(sums(False, lambda r: r["smart"]["holes"])),
                 nh=number(sums(True, lambda r: r["holes"])), nhi=number(sums(True, lambda r: r["smart"]["holes"])))
    worse = [p for p, r in rows.items() if r["smart"]["holes"] > r["holes"]]
    exception = dict(p=worse[0] if len(worse) == 1 else "?",
                     best=str(rows[worse[0]]["holes"]) if len(worse) == 1 else "?",
                     mine=str(rows[worse[0]]["smart"]["holes"]) if len(worse) == 1 else "?")
    longest = max((p for p in NTFS), key=lambda p: rows[p]["duration"])
    passes = dict(fat=total(sums(False, lambda r: r["duration"])),
                  tb=decimal(sums(True, lambda r: r["movedMB"]) / 1024 / 1024),
                  ntfs=total(sums(True, lambda r: r["duration"])),
                  longest=duration(rows[longest]["duration"]), where=longest)
else:
    fields = dict.fromkeys(["fs", "fb", "fi", "ns", "nb", "ni"])
    holes = dict.fromkeys(["fh", "fhi", "nh", "nhi"])
    exception = dict.fromkeys(["p", "best", "mine"])
    passes = dict.fromkeys(["fat", "tb", "ntfs", "longest", "where"])
prose("Sur les douze FAT, les démarrages passent de {fs} s livrés et {fb} s au mieux à **{fi} s** ; sur les huit "
      "NTFS, de {ns} et {nb} s à **{ni} s**.", needs=("smart",), **fields)
prose("Les trous tombent de {fh} à {fhi} sur FAT et de {nh} à {nhi} sur NTFS ;", needs=("smart",), **holes)
prose("un volume fait exception, `{p}`, où la frontière seule en laisse {best} et le rangement {mine}.",
      needs=("smart",), **exception)
prose("Sur FAT, elle dure {fat} pour les douze volumes", needs=("smart",), fat=passes["fat"])
prose("Sur NTFS, c'est un tassage complet : {tb} To déplacés et {ntfs} pour les huit volumes, jusqu'à {longest} "
      "sur `{where}`", needs=("smart",), **{k: passes[k] for k in ("tb", "ntfs", "longest", "where")})
prose("entre les morceaux du fichier d'échange ou de petits métafichiers NTFS — {n} trous sur `famille-1996`.",
      n=number(d("famille-1996", "frontierCompaction")["holes"][1]))
if smart_available():
    asides["smart"] = step


# --- Confronter au README -----------------------------------------------------

FIELD = re.compile(r"\{(\w+)\}")


def pattern(template):
    """Le modèle en expression : le texte à l'espace près — un retour à la ligne
    du README vaut une espace —, chaque champ capturé."""
    parts, names, last = [], [], 0
    for m in FIELD.finditer(template):
        parts.append(template[last:m.start()])
        names.append(m.group(1))
        last = m.end()
    parts.append(template[last:])
    literal = lambda s: r"\s+".join(re.escape(w) for w in s.split(" ")) if s else ""
    body = "".join(literal(p) + (r"(.{1,40}?)" if i < len(names) else "") for i, p in enumerate(parts))
    return re.compile(body, re.S), names


def tables(readme):
    """Pour chaque table : où sont ses lignes dans le README, et ce qu'elles
    devraient être."""
    lines = readme.split("\n")
    for header, separator, rows, available in TABLES:
        if not available():
            yield header, "absent", []
            continue
        if header not in lines:
            yield header, None, list(rows([]))
            continue
        start = lines.index(header) + 2
        end = start
        while end < len(lines) and lines[end].startswith("|"):
            end += 1
        yield header, (start, end), list(rows(lines[start:end]))


def check(readme):
    wrong, unchecked = [], []
    lines = readme.split("\n")
    for header, span, rows in tables(readme):
        if span == "absent":
            unchecked.append(f"table (bilans absents) : {header}")
            continue
        if span is None:
            wrong.append(f"table introuvable : {header}")
            continue
        current = lines[span[0]:span[1]]
        for i, row in enumerate(rows):
            if i >= len(current) or current[i] != row:
                wrong.append(f"table, ligne {span[0] + i + 1}\n    README : {current[i] if i < len(current) else '—'}\n"
                             f"    mesuré : {row}")
        if len(current) > len(rows):
            wrong.append(f"table, ligne {span[0] + len(rows) + 1} : de trop")
    flat = lambda s: re.sub(r"\s+", " ", s)
    for template, needs, fields in PROSE:
        missing = [n for n in needs if n not in asides]
        regex, names = pattern(template)
        found = list(regex.finditer(readme))
        if len(found) != 1:
            wrong.append(f"phrase {'introuvable' if not found else 'ambiguë'} : {template}")
            continue
        m = found[0]
        line = readme.count("\n", 0, m.start()) + 1
        for i, name in enumerate(names):
            field, written = fields[name], flat(m.group(i + 1))
            if field is None:
                continue
            if isinstance(field, Timing) and field.matches(written):
                continue
            expected = field.text if isinstance(field, Timing) else field
            if written != expected:
                wrong.append(f"ligne {line}, {{{name}}} : README « {written} », mesuré « {expected} »"
                             f"\n    {flat(template)}")
        if missing:
            unchecked.append(f"ligne {line} (sans {', '.join(missing)}) : {flat(template)}")
    return wrong, unchecked


def write(readme):
    lines = readme.split("\n")
    # Du bas vers le haut du fichier, pas dans l'ordre de déclaration : une
    # table qui gagne une ligne décale toutes celles d'en dessous.
    found = [(span, rows) for _, span, rows in tables(readme) if span not in (None, "absent")]
    for span, rows in sorted(found, key=lambda f: f[0][0], reverse=True):
        lines[span[0]:span[1]] = rows
    readme = "\n".join(lines)
    for template, needs, fields in PROSE:
        regex, names = pattern(template)
        found = list(regex.finditer(readme))
        if len(found) != 1:
            continue
        m = found[0]
        for i in reversed(range(len(names))):
            field = fields[names[i]]
            if field is None or (isinstance(field, Timing) and field.matches(m.group(i + 1))):
                continue
            value = field.text if isinstance(field, Timing) else field
            readme = readme[:m.start(i + 1)] + value + readme[m.end(i + 1):]
    return readme


path = os.path.join(ROOT, "README.md")
if "--check" in sys.argv or "--write" in sys.argv:
    readme = open(path).read()
    if "--write" in sys.argv:
        readme = write(readme)
        open(path, "w").write(readme)
    wrong, unchecked = check(readme)
    rows = sum(len(list(r([]))) for _, _, r, available in TABLES if available())
    print(f"{rows} lignes de table, {len(PROSE)} phrases ; {len(wrong)} écarts, {len(unchecked)} non vérifiées")
    for w in wrong:
        print("  ✗ " + w)
    for u in unchecked:
        print("  ? " + u)
    sys.exit(1 if wrong else 0)

for header, separator, rows, available in TABLES:
    if not available():
        print(f"\n(bilans absents) {header}")
        continue
    print(f"\n{header}\n{separator}")
    for row in rows([]):
        print(row)
print()
for template, needs, fields in PROSE:
    shown = lambda f: f.text if isinstance(f, Timing) else f
    print("- " + FIELD.sub(lambda m: shown(fields[m.group(1)]) or f"<{m.group(1)} : {', '.join(needs)}>", template))
