# Revue critique des algorithmes de défragmentation

Relecture par quelqu'un qui a passé des nuits devant `DEFRAG.EXE` en mode
graphique, puis devant `dfrg.msc`, et qui a lu le source de JkDefrag et
d'UltraDefrag pour comprendre pourquoi ils ne faisaient pas la même chose.

Périmètre : **uniquement la défragmentation** — `DefragStrategy.swift`,
`Windows95Strategy`, `WindowsXPStrategy`, `JKDefragStrategy`,
`JKDefragFullOptimize`, `UltraDefragStrategy`, `FrontierCompactionStrategy`,
`FragmentMergeStrategy`, et ce que `DefragVolume` leur donne à manipuler. La
mécanique du disque, la synthèse sonore, la carte et le générateur de volumes
sont hors sujet ; ils n'apparaissent que là où un planificateur s'appuie sur
eux.

Toutes les mesures citées ont été obtenues en instrumentant le code tel qu'il
est sur `develop` (commit `b1d8e09`), avec un outil d'audit compilé en release
sur la même liste de sources que `Tools/build-render.sh` : il rejoue chaque
plan sur les vingt profils de la galerie, puis repose `plan.arrangement` sur le
volume de départ et vérifie les invariants d'allocation. Rien n'est estimé.

---

## 1. Verdict

La transposition de JkDefrag et d'UltraDefrag est **du travail d'archiviste**,
et c'est rare. `FindBestItem` est rendu avec son rembobinage (`Item = FirstItem ;
continue`) et son critère `TotalItemsSize` mesuré contre le trou *entier* et non
contre ce qu'il en reste ; `Fixup` garde son trou courant par zone et le
« force re-scan » qui met sa longueur à zéro ; `CalculateZones` itère jusqu'au
point fixe avec son plafond de dix tours ; `MoveItem` marque le fichier
`Unmovable` **et recalcule les zones** quand un déplacement échoue ; le tri
`CompareItems` trie le dernier accès à l'envers de ce qu'annonce son propre
commentaire, et le code Swift le suit en le disant. J'ai relu ces cinq fonctions
ligne à ligne contre `JkDefragLib.cpp` : elles sont justes.

Le reste de cette revue porte donc sur ce qui ne l'est pas. Il y a **une faute
de correction** — un plan qui écrit un fichier par-dessus un autre —, **une
faute d'algorithme** qui multiplie par douze le travail d'une passe FAT, et
**deux règles de placement appliquées au mauvais outil**, dont l'une inverse la
conclusion que l'application tire du défragmenteur de Windows XP.

| # | défaut | où | ampleur mesurée |
|---|--------|----|-----------------|
| 1 | un fichier est écrit par-dessus un autre | `Windows95Strategy` | 746 clusters sur 6 fichiers (`dev-1996`) |
| 2 | l'évacuation repose le fichier juste au-dessus de la frontière | `Windows95Strategy` | 12,4 × le volume déplacé, 7 h 36 au lieu de 33 min |
| 3 | la règle NTFS des clusters retenus n'est appliquée qu'à deux outils sur cinq | `WindowsXPStrategy`, `JKDefragStrategy` | `dev-2007` : 0 fichier cassé restant au lieu de 42 |
| 4 | la zone MFT est interdite à UltraDefrag, qui s'en sert délibérément | `DefragOperations.firstGap` | `gamer-2007` : 92 fichiers cassés restants au lieu de 70 |

---

## 2. Défaut majeur : la passe de Windows 95 écrit sur des fichiers vivants

### Ce que fait le code

`Windows95Strategy.plan` avance une frontière et, pour chaque fichier, évacue
d'abord ce qui occupe sa destination (`Windows95Strategy.swift:120-141`) :

```swift
for occupantPosition in volume.occupants(of: target.start..<target.end)
where occupantPosition != position {
    let occupant = volume.files[occupantPosition]
    guard occupant.isMovable else { continue }
    guard let refuge = freeRuns(in: volume, count: occupant.clusterCount,
                                from: target.end, excluding: reserved, total: total)
    else { continue }                      // ← aucun refuge : on passe au suivant
    …
}

// 2. Déplacer le fichier vers sa destination définitive.
DefragOperations.move(source: …, destination: [target], …)
```

Le `continue` de la ligne 127 laisse l'occupant **en place**, et l'étape 2
déplace quand même le fichier sur `target`. Personne ne revérifie que la
destination est libre : il n'y a nulle part de `guard volume.bitmap.isFree(target)`,
contrairement à `JKDefragStrategy.Pass.move` qui, lui, teste et refuse.

### Ce que cela donne, mesuré

Sur les douze volumes FAT de la galerie, deux déclenchent le cas. En comptant
les occupants qui n'ont trouvé aucun refuge :

| volume | occupants non évacués | recouvrement dans l'état final |
|--------|----------------------:|-------------------------------:|
| `dev-1996` (FAT16, 95 % plein) | 417 (dont 393 fois le même fichier de 2 332 clusters) | **746 clusters sur 6 fichiers** |
| `gamer-1996` (FAT16, 99 % plein) | 438 | **85 clusters sur 2 fichiers** |

Sur les dix autres volumes FAT, zéro. Sur les huit volumes NTFS et pour les
sept autres stratégies, zéro : l'invariant tient partout ailleurs.

Le recouvrement final n'est que la partie visible. À chaque occupant non
évacué, la passe émet des `writeExtent` sur des clusters qu'un autre fichier
référence encore, puis `volume.relocate` libère l'ancienne empreinte du fichier
déplacé et alloue la nouvelle — sans savoir que ces clusters appartenaient déjà
à quelqu'un. La bitmap perd le compte : quand l'occupant sera déplacé à son
tour, il libérera des clusters que le premier fichier occupe, et ils
ressortiront comme trous. C'est très probablement une partie de ce qu'on lit
dans `dev-1996` : **347 trous avant la passe, 496 après**, pour une stratégie
dont le principe est de tasser le volume contre son début.

### Ce que faisait le vrai outil

`DEFRAG.EXE` ne s'est jamais permis cela. Quand il ne pouvait pas déloger un
fichier, il ne le tassait pas — il **sautait sa place** et continuait, en
laissant un trou, exactement comme `FrontierCompactionStrategy` le fait avec ses
`shelters`. Un défragmenteur qui écrit sur une donnée encore référencée est un
défragmenteur qui détruit le volume ; c'était la hantise de l'époque, et le prix
à payer pour l'éviter était précisément la lenteur de ces outils.

### Correction

Trois lignes. Si l'occupant ne peut pas être évacué, le fichier ne se pose pas
là :

```swift
var blockedHere = false
for occupantPosition in … {
    …
    guard let refuge = freeRuns(…) else { blockedHere = true; break }
    …
}
if blockedHere { frontier = target.end; continue }   // le trou reste, comme en 1995
```

Et, par sécurité, une assertion `volume.bitmap.isFree(target)` avant l'étape 2 :
tout plan qui la viole est faux, quelle que soit la stratégie.

---

## 3. Défaut d'algorithme : où Windows 95 repose ce qu'il évacue

### Le geste

`freeRuns` cherche les clusters libres **en montant depuis `target.end`**
(`Windows95Strategy.swift:211-231`) : l'occupant évacué atterrit dans le premier
trou au-dessus de la destination, c'est-à-dire à quelques centaines de clusters
de la frontière. La frontière l'y rattrape aussitôt, et il est réévacué. Et
encore. Les gros fichiers, qui couvrent de larges destinations et sont donc
occupants plus souvent, font le trajet le plus souvent.

### Le coût, mesuré

`movedBytes` rapporté à ce que le volume contient réellement :

| volume FAT | occupé | Windows 95 | tassage à la frontière | rapport |
|------------|-------:|-----------:|-----------------------:|--------:|
| `dev-1996` | 1 034 Mo | 3 590 Mo (3,5 ×) | 1 050 Mo (1,0 ×) | 3,4 |
| `gamer-1996` | 1 079 Mo | 4 775 Mo (4,4 ×) | 1 787 Mo (1,7 ×) | 2,7 |
| `secretaire-1999` | 3 771 Mo | 34 436 Mo (9,1 ×) | 4 307 Mo (1,1 ×) | 8,0 |
| `famille-1999` | 6 163 Mo | 42 028 Mo (6,8 ×) | 6 418 Mo (1,0 ×) | 6,5 |
| `dev-1999` | 5 975 Mo | 44 934 Mo (7,5 ×) | 7 126 Mo (1,2 ×) | 6,3 |
| `gamer-1999` | 7 810 Mo | 104 279 Mo (**13,4 ×**) | 8 125 Mo (1,0 ×) | 12,8 |

Sur `gamer-1999`, en rendu complet sur le matériel de la fiche :

```
windows95           1 277 358 requêtes, 1 274 339 seeks, 27 353 s  (7 h 36)
frontierCompaction     87 793 requêtes,    86 101 seeks,  2 007 s  (0 h 33)
```

Pour **le même résultat** : les deux ramènent 654 fichiers cassés à 1. Sur les
44,9 Go que `dev-1999` déplace, 39 Go — 87 % — ne sont que du va-et-vient
d'évacuation : chaque fichier ne doit atterrir qu'une fois, et le volume ne pèse
que 6 Go.

### Pourquoi c'est un défaut du modèle, et pas une fidélité

Le docstring assume le va-et-vient comme la signature de l'outil, et il a
raison sur le principe : c'est bien ce qui faisait le « clac … clac … clac ».
Mais le facteur 13 n'est pas historique. Une défragmentation complète d'un
disque de 8 Go sous Windows 98 prenait une à trois heures, pas sept heures et
demie, et ne lisait pas cent gigaoctets. L'outil d'époque évacuait vers
**l'espace libre du fond du volume**, qui était sa zone de manœuvre, précisément
pour ne pas repasser dessus.

Et le projet connaît déjà le correctif : `FrontierCompactionStrategy` le
documente à l'endroit exact où il choisit l'inverse
(`FrontierCompactionStrategy.swift:493-495`) —

> « Au fond du volume : posé juste au-dessus, le morceau serait retrouvé et
> repoussé à chaque avancée de la frontière — 70 000 évacuations sur
> `famille-1999`. »

`highestFreeRuns(downTo:need:)` existe déjà, écrit et éprouvé sur les douze
volumes FAT, mais il vit dans `FrontierCompactionStrategy.Pass` et n'a jamais
été appliqué à la stratégie qui en a le plus besoin. Remplacer `freeRuns(from:
target.end, …)` par une recherche descendante depuis la fin du volume ne change
rien à la nature sonore de la passe — elle garde ses évacuations, ses retours au
bord du plateau pour les tables, son ordre de parcours — et lui retire le
facteur 10.

Si l'intention est au contraire de **garder** ce comportement comme portrait
d'un outil naïf, alors il faut le dire dans le docstring : aujourd'hui il
présente le va-et-vient comme fidèle, et c'est le chiffre qui ne l'est pas.

---

## 4. La règle NTFS des clusters retenus ne s'applique qu'à deux outils sur cinq

### La règle

Sur NTFS, les clusters qu'un `FSCTL_MOVE_FILE` libère restent marqués alloués
jusqu'au point de contrôle suivant. Le projet le sait, le dit, et le modélise :
`DefragVolume.relocateHoldingReleased` et `releaseHeldClusters` existent pour
cela, et le commentaire cite `move.c:719-727`. Le README le formule au niveau du
système de fichiers : « Windows tient ces clusters pour temporairement alloués
jusqu'au prochain point de contrôle ».

Or c'est **une propriété du volume, pas de l'outil**. Et pourtant :

| stratégie | ce qu'elle appelle | clusters retenus ? |
|-----------|--------------------|--------------------|
| `UltraDefragStrategy` | `relocateHoldingReleased` si NTFS | oui |
| `FragmentMergeStrategy` | `relocateHoldingReleased` | oui |
| `FrontierCompactionStrategy` | `relocateHoldingReleased` | oui |
| `WindowsXPStrategy` | `volume.relocate` | **non** |
| `JKDefragStrategy` | `volume.relocateChanges` | **non** |

Les deux outils qui appellent réellement `FSCTL_MOVE_FILE` sur du NTFS — celui
de XP et JkDefrag, qui tous deux relisent le bitmap du volume à chaque recherche
de trou, donc voient ces clusters occupés — sont les deux qui l'ignorent.

### Ce que cela change, mesuré

J'ai repris `WindowsXPStrategy` à l'identique en remplaçant sa seule ligne de
validation par `relocateHoldingReleased`, avec une libération en fin de passe
(l'outil de XP n'a pas de tours ; c'est l'hypothèse la plus favorable, un seul
point de contrôle à la fin) :

| volume NTFS | fichiers cassés restants | morceaux restants | déplacé |
|-------------|--------------------------|-------------------|---------|
| `dev-2007` | 0 → **42** | 0 → **43 651** | 38 850 → 24 079 Mo |
| `gamer-2007` | 98 → 108 | 41 269 → 44 444 | 20 468 → 16 220 Mo |
| `famille-2007` | 155 → 162 | 137 805 → 148 541 | 19 706 → 16 301 Mo |
| `secretaire-2003` | 103 → 105 | 22 321 → 22 472 | 392 → 348 Mo |
| `dev-2003`, `famille-2003`, `secretaire-2007` | inchangé | inchangé | inchangé |

Sur `dev-2007`, la conclusion s'inverse : le tableau du README annonce
`176 → 0` en gras, « cet outil-là nettoie entièrement le volume ». Avec la règle
que le projet applique déjà à UltraDefrag, il en laisse un quart. La raison est
mécanique : `firstGap` repart du cluster 0 à chaque fichier et retombe sur les
trous que la passe vient d'ouvrir juste devant elle. Ces trous n'existent pas
encore pour le vrai `dfrg.msc`.

L'écart est plus petit ailleurs (sept à dix fichiers), mais il va toujours dans
le même sens : le modèle **flatte** les deux outils qui ignorent la règle, et
les compare à un UltraDefrag qui, lui, la subit. La comparaison XP / UltraDefrag
que porte tout le chapitre NTFS du README repose donc sur une asymétrie de
règle, pas seulement sur une différence d'algorithme.

### Correction

Faire porter la règle par le volume et non par la stratégie : que
`DefragVolume` refuse tout simplement `relocate` sur un volume NTFS, et
n'expose que `relocateHoldingReleased`. Chaque stratégie choisit alors sa
**cadence de points de contrôle** — un par tour pour UltraDefrag, tous les
`checkpointMoves` pour le recollage économe, un par lot pour la frontière, et
pour XP et JkDefrag ce que fait Windows, c'est-à-dire un toutes les quelques
secondes. C'est un réglage assumé, au lieu d'un oubli.

---

## 5. La zone MFT est interdite à UltraDefrag, qui s'en sert exprès

`DefragOperations.firstGap` et `largestGap` sautent la zone MFT, et leur
docstring le justifie par `FindGap` et ses `MftExcludes`. C'est exact **pour
JkDefrag**. Ce ne l'est pas pour UltraDefrag, et le source le dit en toutes
lettres (`src/dll/udefrag/analyze.c:259-296`) :

```c
/**
 * @brief Retrieves mft zones layout.
 * @note Since we have MFT optimization routine,
 * let's use MFT zone for files placement on XP
 * and more recent Windows editions.
 */
…
    if(jp->win_version < WINDOWS_XP)
        jp->free_regions = winx_sub_volume_region(jp->free_regions,start,length);
```

La zone n'est retirée de la liste des régions libres que **sous XP**, c'est-à-
dire jamais pour les volumes de 2003 et 2007 de la galerie.
`find_first_free_region` parcourt ensuite `jp->free_regions` sans aucun test de
zone : UltraDefrag y range des fichiers, délibérément.

### Ce que cela change, mesuré

Même outil, même volume, avec la zone MFT rendue disponible :

| volume NTFS | zone MFT libre | fichiers cassés restants | morceaux restants |
|-------------|---------------:|--------------------------|-------------------|
| `gamer-2007` | ≈ 2 562 862 clusters (≈ 9,8 Go) | 92 → **70** | 546 → 385 |
| `secretaire-2003` | ≈ 321 597 clusters (≈ 1,2 Go) | 103 → **88** | 13 028 → **8 290** |
| `dev-2007` | ≈ 2 248 830 clusters (≈ 8,6 Go) | 3 → 1 | 14 → 4 |
| `dev-2003` | ≈ 52 242 clusters | 5 → 5 | 109 → **19** |
| `secretaire-2007`, `famille-2007` | — | inchangé | inchangé |

Sur `gamer-2007`, la passe actuelle s'interdit **dix gigaoctets d'un seul
tenant** sur un volume où l'argumentaire de l'outil est précisément « il n'y a
plus un seul trou à la taille ». C'est le plus grand trou du disque, et de très
loin.

### Le cas de Windows XP est moins clair

`WindowsXPStrategy` passe par le même `firstGap` et hérite donc de la même
interdiction. Je n'ai pas de source pour `dfrg.msc` ; l'API de défragmentation
de Windows autorise l'écriture dans la zone MFT, et le noyau la cède de
lui-même dès que le volume dépasse ~87 % de remplissage — ce que le générateur
du projet modélise déjà, puisque `dev-2003` a 780 000 clusters de fichiers
ordinaires dedans au départ. Il est donc peu probable que l'outil de XP l'ait
respectée. Mais c'est une hypothèse, et je la donne comme telle : la certitude
ne porte que sur UltraDefrag.

### Correction

Faire du refus de la zone MFT un **paramètre de la stratégie** et non une
propriété de `firstGap` : vrai pour JkDefrag (qui a ses `MftExcludes`), faux
pour UltraDefrag (qui les a explicitement retirés depuis XP), à trancher et à
documenter pour la passe de XP.

---

## 6. Ce qui manque au modèle : les répertoires

`Volume.defragVolume()` et `GeneratedVolumeBridge.volume(from:)` ne construisent
de `DefragFile` que pour des fichiers ; `ClusterCategory` n'a pas de cas
`directory`, et aucun cluster du volume n'est porté par un répertoire. Le seul
endroit où ils existent est `DefragOperations.directoryCount`, qui les déduit
des chemins pour chiffrer la durée de l'analyse.

Trois conséquences, toutes dans la défragmentation :

- **la zone 0 de JkDefrag est toujours vide.** `Pass.init` attribue à chaque
  élément `zone: hog ? 2 : 1`, jamais 0. Sur `gamer-1996` la bande des
  répertoires mesure 345 clusters — c'est exactement la réserve de 1 % de
  `-f`, et rien d'autre. Le découpage en trois bandes qui fait la signature de
  JkDefrag est en réalité un découpage en deux ;
- **le cas FAT le plus caractéristique de JkDefrag ne se produit jamais.**
  `MoveItem` (`JkDefragLib.cpp:2486-2493`, et le même test dans `Fixup`, `JkDefragLib.cpp:1940`) compte les répertoires qu'il n'a pas
  pu déplacer et, **au vingtième**, marque tous les répertoires `Unmovable`
  pour le reste de la passe. Sur un volume FAT c'est la règle et non
  l'exception : Windows ne sait pas déplacer un répertoire FAT. Une passe
  JkDefrag sur FAT commence donc par vingt échecs, puis abandonne toute une
  classe d'objets — vingt recalculs de zones compris. Rien de cela n'est
  modélisé, parce qu'il n'y a rien à échouer à déplacer ;
- **`Fixup` et `Defragment` ne rencontrent jamais de répertoire.** Or un
  répertoire FAT32 de 1999 grandit par clusters isolés et compte parmi les
  objets les plus fragmentés d'un volume vieilli.

Ce n'est pas un bug : c'est une limite du modèle de volume, héritée du
générateur, qui se paie dans la couche défragmentation. Elle mérite d'être
nommée dans les docstrings de `JKDefragStrategy` au même titre que les autres
écarts assumés (les dates d'accès, `SlowDown`, la garde des quinze minutes),
qui le sont tous scrupuleusement — celui-ci ne l'est pas, alors qu'il est le
plus lourd des cinq.

---

## 7. L'hypothèse la plus fragile de la transposition JkDefrag, et où elle mord

`JKDefragStrategy.Pass.defragment` reproduit un défaut réel de l'original : dans
la boucle de découpage en tranches, `Clusters` est calculé **avant** la boucle
qui saute les morceaux déjà bien placés, et n'est pas recalculé après. La
tranche peut donc déborder de la fin du fichier. Le code Swift en tire :

```swift
if clusters > total - done {
    pass.report.overrunSlices += 1
    break                      // FSCTL_MOVE_FILE refuse, rien n'est copié
}
```

et le commentaire est honnête : « C'est une lecture de l'API et non une
mesure ».

C'est la bonne prudence, mais il faut mesurer où elle tombe :

| volume | tranches | dont débordantes |
|--------|---------:|-----------------:|
| `famille-1999` | 416 | **135 (24 %)** |
| `dev-1996` | 390 | 18 |
| `famille-2007` | 744 | 50 |
| `secretaire-2003` | 4 577 | 29 |
| `dev-1999` | 324 | 16 |

Sur `famille-1999`, une tranche sur quatre est abandonnée par cette lecture — et
`famille-1999` est justement le volume où JkDefrag fait son plus mauvais score
de la galerie : **874 fichiers cassés au départ, 479 à l'arrivée**, là où le
tassage à la frontière en laisse 1. L'hypothèse la moins solide du portage
décide donc du résultat le plus défavorable.

Les deux lectures ne divergent pas seulement sur le son. Si Windows **tronque**
la plage à la fin du fichier au lieu de la refuser, la dernière tranche est
bien recopiée dans le trou, le fichier finit ailleurs, et la passe suivante n'a
plus le même volume sous les yeux. Dans les deux cas la boucle s'arrête —
`ClustersDone += Clusters` déborde — mais l'état d'arrivée n'est pas le même.

Ce qui trancherait : `MoveItem1` (`JkDefragLib.cpp:2055-2135`) émet **un seul**
`FSCTL_MOVE_FILE` avec `StartingVcn` et `ClusterCount = Size`. Il suffit donc de
savoir ce que fait `FSCTL_MOVE_FILE` d'un `ClusterCount` qui dépasse la fin du
fichier. Tant que ce n'est pas établi, je noterais dans le docstring que 24 %
des tranches d'un volume en dépendent — aujourd'hui le compteur existe
(`overrunSlices`) mais rien ne dit qu'il est gros.

---

## 8. Ce qui est juste, et vaut d'être dit

- **`FindBestItem` et `FindHighestItem`.** Le glouton qui rembobine est rendu
  exactement, y compris le fait que `TotalItemsSize` s'accumule contre le trou
  *entier* (`if item.clusters < full`) et non contre `remaining`, et que la
  reprise repart de l'élément **suivant** le premier retenu. Le docstring
  corrige même une erreur de l'`ALGO.md` du dépôt de référence (« le plus gros
  qui rentre » au lieu de « le plus haut qui rentre ») : c'est le code original
  qui a raison, et le Swift le suit.
- **La borne de visites ne mord pas.** Sur les vingt volumes,
  `perfectFitsExhausted` vaut zéro partout et le pic de visites est de 88 954
  (`gamer-1999`) pour un budget de 2 000 000. Le remplacement du chronomètre de
  l'original par un compteur de visites — indispensable pour que le plan soit
  déterministe — ne coûte donc **aucune** divergence sur la galerie. C'est
  vérifié, pas supposé.
- **La sortie de la zone MFT par `Fixup`.** `moveMe = true` quand
  `mft.contains(item.lcn)` reproduit le test de `JkDefragLib.cpp:3875-3885`, et
  ça se voit : sur `dev-2007`, JkDefrag ramène les 697 297 clusters de fichiers
  ordinaires posés dans la zone MFT à **zéro**, là où XP et UltraDefrag les y
  laissent tous. C'est un comportement réel, correctement transposé, et il
  s'entend.
- **La comptabilité des clusters retenus** (`relocateHoldingReleased`) est le
  bon modèle, et `FrontierCompactionStrategy` en tire la garantie qu'il annonce :
  sur les douze volumes FAT, l'audit ne trouve **aucune** écriture sur une donnée
  encore référencée et **aucun** recouvrement final. La promesse « une coupure de
  courant laisse un volume cohérent » tient.
- **La défragmentation partielle d'UltraDefrag** est fidèle jusqu'au
  `goto move_clusters` : le Swift `if overflowed { break }` sort de la boucle
  externe et tombe sur le déplacement en sautant l'annexion, ce qui est
  exactement ce que fait le `goto`. L'annexion d'un bout du gros fragment voisin,
  en aval sinon en amont, avec la règle « si le reste tombait sous le seuil,
  prends-le en entier », est reproduite dans le bon ordre.
- **`fragmentCount` compte les morceaux et non les extents**, en suivant l'ordre
  logique du fichier et non l'ordre sur le plateau. C'est la règle de
  `IsFragmented` et de `build_fragments_list`, et c'est ce qui évite de promettre
  au défragmenteur un travail qui n'existe pas.

---

## 9. Points plus petits

**Le regroupement des validations du tassage à la frontière s'effondre quand il
faudrait qu'il tienne.** C'est l'argument central de la stratégie — « un
déplacement vers des clusters déjà libres n'écrit les tables qu'avec les
suivants, en une traite » :

| volume | remplissage | déplacements | validations groupées | déplacements par validation |
|--------|------------:|-------------:|---------------------:|----------------------------:|
| `secretaire-1999` | 87 % | 5 523 | 367 | 15,0 |
| `dev-1996` | 95 % | 3 777 | 1 914 | 2,0 |
| `gamer-1996` | 99 % | 21 918 | **31 103** | **0,7** |

À 99 % de remplissage il y a plus de validations que de déplacements : le lot
est vidé à chaque fois qu'un cluster retenu barre la frontière ou qu'une
évacuation manque de place. Sur FAT, chaque validation, c'est trois écritures au
bord du plateau ; 31 103 lots font 93 000 allers-retours du bras. C'est
défendable — il faut bien rendre les clusters pour avancer — mais le docstring
présente le groupement comme acquis, alors qu'il ne fonctionne que sous 95 %.

**Des chiffres périmés dans les docstrings.** Ils servent d'argumentaire et ne
correspondent plus au générateur :

| affirmation | où | mesuré aujourd'hui |
|-------------|----|--------------------|
| « `dev-2003` répare 260 fichiers sur 299 » | `WindowsXPStrategy.swift:43` | 35 sur 40 |
| « le second 57 sur 141 » (`secretaire-2003`) | idem | 78 sur 181 |
| « 244 fichiers fragmentés sur 12 220 » (`famille-2007`) | `Windows95Strategy.swift:31`, `DefragStrategy.swift:17` | 259 sur 12 229 |
| « 213 Mo en moyenne » | `UltraDefragStrategy.swift:9-11` | non revérifié |

Le tableau du README a moins dérivé (`36 → 4` pour 40 → 5, `268 → 150` pour
259 → 155) : ce sont les commentaires de code qui sont restés en arrière. Le
raisonnement qu'ils portent reste juste — ce n'est pas le remplissage qui
prédit l'échec — mais un lecteur qui vérifie les chiffres ne les retrouve pas.

**`recordFreed` a une ligne morte.** `cursor = max(stop, cursor + 1)`
(`DefragStrategy.swift:296`) : la dichotomie garantit `kept[low].start > cursor`,
donc `stop > cursor` tant que la boucle tourne. Le `cursor + 1` ne sert jamais.
Sans conséquence, mais il laisse croire à un cas de non-progression qui n'existe
pas.

**Le repli « plus grand trou » de `FindGap` a un défaut que le Swift ne
reproduit pas.** L'original initialise `LargestBeginLcn = 0` et teste
`if (LargestBeginLcn == 0 || …)` : si le premier trou commence au cluster 0, le
« plus grand trou » devient en fait le **dernier** trou rencontré, et un plus
grand trou commençant à 0 n'est jamais rendu. Le Swift prend honnêtement le plus
grand. Ce n'est atteignable que par l'appel de repli `gap(from: 0, …)` de
`defragment`, et le cluster 0 d'un volume est toujours alloué dans la galerie :
je le signale pour mémoire, pas pour le corriger.

**`Windows95Strategy.destination` est en O(nombre d'extents immobiles) par
fichier.** `blocked.first(where:)` rebalaie le tableau depuis le début à chaque
essai, alors qu'il est trié et qu'une dichotomie répondrait. Sur un volume dont
le fichier d'échange est en centaines de morceaux et qui compte 7 000 fichiers,
c'est du temps de planification pur. Sans effet sur le résultat.

---

## 10. Par ordre de ce que je ferais

1. **Corriger le recouvrement de `Windows95Strategy`** (§2). C'est une faute de
   correction : un plan produit aujourd'hui un état de volume impossible. Trois
   lignes, plus une assertion d'invariant valable pour les huit stratégies —
   l'audit qui l'a trouvée tient en cinquante lignes et mériterait d'entrer dans
   `Tests/DefragKitTests`.
2. **Décider de la règle NTFS des clusters retenus** (§4) et la faire porter par
   `DefragVolume`. Tant qu'elle n'est appliquée qu'à trois stratégies sur cinq,
   le chapitre NTFS du README compare deux algorithmes **et** deux règles, et
   `dev-2007` bascule de « nettoyé entièrement » à « un quart laissé en
   morceaux » selon celle qu'on retient.
3. **Rendre la zone MFT à UltraDefrag** (§5). Le source dit exactement ce qu'il
   fait et pourquoi ; dix gigaoctets sur `gamer-2007` en dépendent.
4. **Évacuer vers le fond du volume dans `Windows95Strategy`** (§3), ou assumer
   explicitement le contraire dans le docstring. Le facteur 12 sur le travail
   d'une passe n'est aujourd'hui revendiqué nulle part.
5. **Nommer l'absence des répertoires** (§6) dans les écarts assumés de
   `JKDefragStrategy`, à côté des dates d'accès et de `SlowDown`. C'est le plus
   gros des cinq, et le seul qui ne soit pas écrit.
6. **Établir ce que fait `FSCTL_MOVE_FILE` d'une plage qui déborde** (§7), ou au
   minimum écrire dans le docstring que 135 des 551 tranches de `famille-1999`
   en dépendent.
7. **Rafraîchir les chiffres des docstrings** (§9), ou les remplacer par un test
   qui les régénère — c'est le genre d'argumentaire qui perd toute valeur dès
   qu'il ne se vérifie plus.
