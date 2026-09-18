#!/usr/bin/env python3
"""Les tables mesurées du README, régénérées depuis les bilans d'une étape.

    ./Tools/Measure/run.sh <étape> full
    ./Tools/Measure/readme-tables.py <étape>

À valider avant de s'en servir : lancé sur les bilans du commit d'avant, il doit
reproduire le README d'avant au chiffre près. Il imprime les tables et les
chiffres de prose qui en dépendent ; les coller reste une affaire de relecture.

Les tables de défragmentation **FAT** (JkDefrag contre 95, tassage à la
frontière) en sortent depuis le chantier 23, avec les chiffres de prose qui les
accompagnent.

Ce qu'il ne fait pas :
- la table des trois allocateurs, que `swift test --filter AllocatorComparison`
  imprime ;
- les colonnes « activités » des journées, qui sont du texte.
"""
import sys

from bilan import (NTFS, PROFILES, boot, common, decimal, defrag, duration,
                   gigabytes, number, text)
import re

step = sys.argv[1]
d = lambda p, t, full=False: defrag(step, p, t, full)


def section(title):
    print(f"\n### {title}\n")


section("Passe de XP sur NTFS")
print("| scénario NTFS     | plein | requêtes | durée      | déplacés | fragmentés avant → après | morceaux avant → après |")
print("|-------------------|------:|---------:|-----------:|---------:|--------------------------|------------------------|")
order = ["gamer-2003", "secretaire-2003", "famille-2003", "dev-2003",
         "secretaire-2007", "famille-2007", "gamer-2007", "dev-2007"]
for p in order:
    x = d(p, "windowsXP")
    (fb, fa), (mb, ma) = x["fragmented"], x["fragments"]
    fa = f"**{fa}**" if fa == 0 and fb > 0 else str(fa)
    ma = f"**{number(ma)}**" if ma == 0 and mb > 0 else number(ma)
    print(f"| `{p}`".ljust(20) + f"| {x['fill']:>3} % | {number(x['requests']):>8} | {duration(x['duration']):>10} "
          f"| {x['moved']:>8} | {number(fb) + ' → ' + fa:24} | {number(mb) + ' → ' + ma:22} |")

section("XP contre UltraDefrag")
print("| scénario NTFS     | morceaux restants, XP | UltraDefrag |  requêtes XP → UD |    durée XP → UD |")
print("|-------------------|----------------------:|------------:|------------------:|-----------------:|")
for p in order[1:]:
    x, u = d(p, "windowsXP"), d(p, "ultraDefrag")
    print(f"| `{p}`".ljust(20) + f"| {number(x['fragments'][1]):>21} | {number(u['fragments'][1]):>11} "
          f"| {number(x['requests']) + ' → ' + number(u['requests']):>17} "
          f"| {duration(x['duration']) + ' → ' + duration(u['duration']):>16} |")

section("JkDefrag sur NTFS")
print("| scénario | plein | morceaux restants, XP | UltraDefrag | JkDefrag | durée, XP → JkDefrag | Go déplacés, XP → JkDefrag |")
print("|---|---:|---:|---:|---:|---:|---:|")
for p in ["secretaire-2003", "famille-2003", "dev-2003", "gamer-2003", "famille-2007", "gamer-2007"]:
    x, u, j = d(p, "windowsXP"), d(p, "ultraDefrag"), d(p, "jkDefrag")
    print(f"| `{p}` | {x['fill']} % | {number(x['fragments'][1])} | {number(u['fragments'][1])} "
          f"| {number(j['fragments'][1])} | {duration(x['duration'])} → {duration(j['duration'])} "
          f"| {gigabytes(x['movedMB'])} → {gigabytes(j['movedMB'])} |")

section("Recollage économe")
tools = ["windowsXP", "ultraDefrag", "jkDefrag", "fragmentMerge"]
print("| scénario | plein | durée, XP / UltraDefrag / JkDefrag / recollage | morceaux restants | trous libres |")
print("|---|---:|---:|---:|---:|")
totals = {t: [0.0, 0, 0] for t in tools}
for p in ["dev-2003", "famille-2003", "secretaire-2003", "gamer-2003",
          "dev-2007", "famille-2007", "gamer-2007", "secretaire-2007"]:
    xs = [d(p, t) for t in tools]
    for t, x in zip(tools, xs):
        totals[t][0] += x["duration"]; totals[t][1] += x["fragments"][1]; totals[t][2] += x["holes"][1]
    cols = lambda f: " / ".join(f(x) for x in xs[:3]) + f" / **{f(xs[3])}**"
    print(f"| `{p}` | {xs[0]['fill']} % | {cols(lambda x: duration(x['duration']))} "
          f"| {cols(lambda x: number(x['fragments'][1]))} | {cols(lambda x: number(x['holes'][1]))} |")
print()
for t, (s, m, h) in totals.items():
    print(f"- {t} : {duration(s)}, {number(m)} morceaux, {number(h)} trous")
for t in ("windowsXP", "ultraDefrag"):
    s = sum(d(p, t, full=True)["duration"] for p in NTFS)
    print(f"- {t} en blocs pleins : {duration(s)}")

section("Démarrages")
print("| | système | fichiers | lu | durée | dont calcul | témoin |")
print("|---|---|---|---|---|---|---|")
for p in ["gamer-1993", "dev-1993", "gamer-1996", "famille-1999",
          "secretaire-1999", "gamer-2003", "dev-2003", "famille-2007"]:
    b = boot(step, p)
    print(f"| `{p}` | {b['os']} | {number(b['files'])} | {b['read']} Mo | {decimal(b['duration'])} s "
          f"| {round(b['think'] / b['duration'] * 100)} % | {b['witness'].replace('-', '−')} % |")
boots = {p: boot(step, p) for p in PROFILES}
shares = [b["think"] / b["duration"] * 100 for b in boots.values()]
durations = [b["duration"] for b in boots.values()]
print(f"\n- part du calcul : {min(shares):.0f} à {max(shares):.0f} %, "
      f"durées : {decimal(min(durations))} à {decimal(max(durations))} s")
print("- témoins : " + ", ".join(f"{p} {b['witness']}" for p, b in boots.items()))
print(f"- requêtes d'un démarrage de dev-1996 : {number(boots['dev-1996']['requests'])}")

section("Installations")
print("| | source | posé | archives | redémarrages | durée |")
print("|---|---|---|---:|---:|---:|")
for p in ["gamer-1993", "secretaire-1996", "famille-1999", "famille-2003", "gamer-2007"]:
    t = text(step, f"install-{p}")
    files, mb = map(int, re.search(r"posé\s+: (\d+) fichiers, (\d+) Mo", t).groups())
    size = f"{mb} Mo" if mb < 1000 else f"{decimal(mb / 1000)} Go"
    print(f"| `{p}` | {re.search(r'source\s+: (.*)', t).group(1)} | {number(files)} fichiers, {size} "
          f"| {re.search(r'archives\s+: (\d+)', t).group(1)} | {re.search(r'redémarrages\s+: (\d+)', t).group(1)} "
          f"| {duration(common(t)['duration'])} |")
installs = [common(text(step, f"install-{p}"))["duration"] for p in PROFILES]
print(f"\n- les vingt installations : de {duration(min(installs))} à {duration(max(installs))}")

section("Journées")
print("| journée | lu / écrit | durée | seek moyen |")
print("|---|---|---:|---:|")
for name in ["dev-1996_20", "dev-1996_300", "famille-2003_400", "gamer-1999_365"]:
    x = common(text(step, f"day-{name}"))
    profile, day = name.split("_")
    print(f"| `{profile}`, jour {day} | {x['read']} / {x['written']} Mo | {duration(x['duration'])} "
          f"| {number(x['meanSeek'])} cyl. |")

section("JkDefrag sur FAT")
print("| scénario | plein | durée, 95 → JkDefrag | évacuations, 95 | morceaux restants, 95 → JkDefrag |")
print("|---|---:|---:|---:|---:|")
for p in ["dev-1993", "dev-1996", "secretaire-1999", "famille-1999", "gamer-1996"]:
    w, j = d(p, "windows95"), d(p, "jkDefrag")
    print(f"| `{p}` | {w['fill']} % | {duration(w['duration'])} → {duration(j['duration'])} "
          f"| {number(w['evacuations'])} | {number(w['fragments'][1])} → {number(j['fragments'][1])} |")

section("Tassage à la frontière")
FAT = ["dev-1993", "secretaire-1993", "poweruser-1993", "gamer-1993", "dev-1996", "famille-1996",
       "secretaire-1996", "gamer-1996", "dev-1999", "famille-1999", "secretaire-1999", "gamer-1999"]
print("| scénario | plein | durée, 95 → JkDefrag → frontière | morceaux restants, 95 / JkDefrag / frontière "
      "| trous libres, 95 / JkDefrag / frontière |")
print("|---|---:|---:|---:|---:|")
sums = {t: [0.0, 0] for t in ("windows95", "jkDefrag", "frontierCompaction")}
for p in FAT:
    w, j, f = d(p, "windows95"), d(p, "jkDefrag"), d(p, "frontierCompaction")
    for t, x in (("windows95", w), ("jkDefrag", j), ("frontierCompaction", f)):
        sums[t][0] += x["duration"]; sums[t][1] += x["movedMB"]
    print(f"| `{p}` | {w['fill']} % | {duration(w['duration'])} → {duration(j['duration'])} → "
          f"**{duration(f['duration'])}** | {number(w['fragments'][1])} / {number(j['fragments'][1])} / "
          f"**{number(f['fragments'][1])}** | {number(w['holes'][1])} / {number(j['holes'][1])} / "
          f"**{number(f['holes'][1])}** |")
print()
for t, (seconds, mb) in sums.items():
    # Un total s'arrondit à la minute la plus proche, pas à celle d'avant.
    print(f"- {t} sur les douze FAT : {duration(round(seconds / 60) * 60)}, {gigabytes(mb)} Go déplacés")

section("Chiffres de prose FAT")
w = d("dev-1993", "windows95")
t = text(step, "defrag-dev-1993-windows95")
files = int(re.search(r"(\d+) fichiers, \d+ % plein", t).group(1))
print(f"- dev-1993 : {number(files)} éléments, {w['fragmented'][0]} fragmentés en "
      f"{number(w['fragments'][0])} morceaux, {w['holes'][0]} trous, {w['fill']} % plein")
print(f"- dev-1993, 95 : {number(w['moved'])} déplacés, {number(w['evacuations'])} évacuations, "
      f"{duration(w['duration'])} ; frontière {duration(d('dev-1993', 'frontierCompaction')['duration'])} ; "
      f"{w['movedMB']} Mo déplacés")
x = d("dev-1999", "windows95")
print(f"- dev-1999, 95 : {number(x['movedMB'])} Mo déplacés, {number(x['evacuations'])} évacuations, "
      f"{duration(x['duration'])}")
print(f"- secretaire-1993, 95 : {duration(d('secretaire-1993', 'windows95')['duration'])} ; "
      f"dev-1996, 95 : {duration(d('dev-1996', 'windows95')['duration'])}")
u = d("dev-1996", "ultraDefrag")
print(f"- dev-1996, UltraDefrag : {duration(u['duration'])}, {number(u['fragments'][1])} morceaux ; "
      f"95 : {number(d('dev-1996', 'windows95')['fragments'][1])} morceaux")
sorts = d("famille-2007", "jkDefragSortName")
print(f"- famille-2007, tri par nom : {number(sorts['movedMB'] / 1024)} Go, {number(sorts['evacuations'])} "
      f"évacuations, {duration(sorts['duration'])} ; gamer-2007 tri : "
      f"{number(d('gamer-2007', 'jkDefragSortName')['fragments'][1])} morceaux ; secretaire-1999 tri : "
      f"{number(d('secretaire-1999', 'jkDefragSortName')['fragments'][1])} morceaux")
