#!/usr/bin/env python3
"""Les vingt-quatre démarrages, étape par étape, contre leur cible — les
vingt qui en ont une : 2012 n'en a pas, son écart s'écrit « — ».

    ./Tools/Measure/boots.py base m1 m2        # durée, écart, calcul, seeks
    ./Tools/Measure/boots.py --steps base m1 m2 m3 recal
                                               # tableau du journal : l'écart de
                                               # chaque étape à la précédente
    ./Tools/Measure/boots.py --eras recal      # somme par époque contre la cible
"""
import sys

from bilan import BOOT_TARGETS, PROFILES, YEARS, boot, decimal

steps = [a for a in sys.argv[1:] if not a.startswith("--")]


def signed(x):
    s = f"{x:+.1f}".replace(".", ",").replace("-", "−")
    return "0" if s in ("+0,0", "−0,0") else s


if "--eras" in sys.argv:
    for year in YEARS:
        for step in steps:
            ps = [p for p in PROFILES if p.endswith(year) and p in BOOT_TARGETS]
            if not ps:
                continue
            total = sum(boot(step, p)["duration"] for p in ps)
            target = sum(BOOT_TARGETS[p] for p in ps)
            think = sum(boot(step, p)["think"] for p in ps)
            print(f"{year} {step:10} {total:6.1f} s pour {target:6.1f} ({(total / target - 1) * 100:+5.1f} %), "
                  f"dont calcul {think:.1f} s")
elif "--steps" in sys.argv:
    print("| profil | cible | " + " | ".join(steps[:1] + steps[1:-1] + steps[-1:]) + " | écart |")
    print("|---|" + "---:|" * (len(steps) + 2))
    for p in (p for p in PROFILES if p in BOOT_TARGETS):
        v = [boot(s, p)["duration"] for s in steps]
        row = [f"`{p}`", decimal(BOOT_TARGETS[p]), decimal(v[0])]
        row += [signed(v[i] - v[i - 1]) for i in range(1, len(v) - 1)]
        row += [decimal(v[-1]), f"{(v[-1] / BOOT_TARGETS[p] - 1) * 100:+.1f} %".replace(".", ",").replace("-", "−")]
        print("| " + " | ".join(row) + " |")
else:
    print(f"{'profil':16} {'cible':>5}  " + "  ".join(f"{s:>40}" for s in steps))
    for p in PROFILES:
        target = BOOT_TARGETS.get(p)
        row = [f"{p:16}", f"{target:5.1f}" if target else "    —"]
        for s in steps:
            b = boot(s, p)
            gap = f"{(b['duration'] / target - 1) * 100:+6.1f} %" if target else "     — "
            row.append(f"{b['duration']:5.1f} {gap} "
                       f"calcul {b['think']:4.1f} seeks {b['seeks']:4} témoin {b['witness']:>3} %")
        print("  ".join(row))
