# Journal de bord

Ce que chaque chantier a décidé, ce qu'il a mesuré, et ce qu'il laisse ouvert.
Le README décrit le modèle tel qu'il est ; ce fichier-ci garde la trace de
**pourquoi** il est ainsi, et de ce qui a été écarté en route. Les chiffres
sont ceux qui ont été mesurés, pas ceux qu'on visait.

---

## Chantier 1 — la géométrie d'un disque vient de son année

**Fait** · commit `c8f1999`

### Le problème

`DriveGeometry.era` déduisait un disque de sa seule capacité, par une loi de
puissance d'exposant 0,20 calée sur les deux disques écrits à la main. Elle
faisait tout porter à la densité linéaire, et se trompait d'un facteur trois aux
deux bouts de la période.

| | ancien modèle | disque réel | modèle actuel |
|---|---|---|---|
| 170 Mo, 1993 | 562 pistes | 1 806 (Conner CFA170A) | 1 806 |
| 1,08 Go, 1996 | 1 264 pistes | 3 835 (Fireball 1080AT) | 3 835 |
| 320 Go, 2007 | ~235 000 pistes | ~160 000 | 162 227 |

Le débit suivait : 5,9 Mo/s pour un disque de 1993 qui en faisait 1,8.

### Les décisions

- **L'année est un paramètre du modèle**, au même titre que la capacité. Elle
  vient de `spec.timeline.start.year`, qui existait déjà. Une capacité seule ne
  décrit pas un disque.
- **On n'interpole que ce que les fiches publient sans ambiguïté** : le nombre
  de pistes par face et la capacité d'une face. Les secteurs par piste tombent
  du quotient des deux — ce n'est pas un troisième paramètre libre.
- **La densité linéaire est une propriété de l'époque**, fixée par le canal de
  lecture. Une capacité hors de son époque ne l'étire pas : elle ajoute des
  plateaux, puis de la surface. Marge tolérée avant correction : 1,20.
- **Le nombre de faces est celui qui approche le mieux la densité de l'année**,
  et non le plus petit qui suffirait.
- **La loi de seek passe par les deux durées d'une fiche** — seek moyen et
  piste-à-piste. Les deux réglages sont orthogonaux : le seek moyen (un tiers de
  course) tombe toujours sur la branche linéaire, le piste-à-piste à l'autre
  bout de la branche en racine. Leur rapport était jusque-là figé à celui d'un
  disque de 1996, ce qui donnait à un disque de 2003 le crépitement d'un disque
  d'une décennie plus tôt.
- **Les deux scénarios livrés tournent sur des disques nommés** : Seagate
  Barracuda ATA IV ST320011A (2001, une seule face — donc pas une commutation de
  tête de tout le démarrage) et Quantum Fireball 1080AT (1996).

### Ce qui valide

- Les huit disques du catalogue sont retrouvés depuis leur seule fiche
  commerciale, à 2 % près sur la course.
- **Vérification croisée** : le débit de la piste externe n'entre dans aucun
  calcul, et il retombe à 5 % (Barracuda 7200.7) et 1,5 % (7200.10) des valeurs
  des manuels.
- Ce même contrôle a fait **écarter une fiche** : la géométrie « native » du
  Quantum Fireball ST 6.4AT donnerait 6,5 Mo/s là où son manuel annonce 16 — ses
  13 328 cylindres sont ceux d'une translation, pas des pistes.

### Effets mesurés

- Passe livrée : 193 s → 204,7 s. Démarrage : inchangé à 60 s.
- Les huit passes de la galerie alors ouvertes : 17–51 min → 27–62 min.
- La densité seule ne dit pas la durée : la plus longue passe est celle du plus
  petit disque, un 170 Mo de 1993 lu à 1,8 Mo/s.

### Laissé ouvert

Le seul paramètre du modèle qui ne vienne pas d'une fiche est la largeur de la
bande de données d'un plateau 3,5 pouces, réglée à 1,10 pouce. Un point de
calibration entre 1996 et 1999 manque — la densité double alors chaque année, et
l'interpolation y est la plus fragile.

---

## Chantier 2 — le défragmenteur travaille en extents

**Partiellement fait** · commits `c2b8640`, `794a921`, `faa2bbd`, `47a9abc`,
`ac71696`, `2ef7533`, `f3c8177`, puis branche `chantier-2`

### Le problème

La passerelle construisait un volume FAT16 où chaque fichier portait la liste de
ses clusters, et refusait donc tout ce qui dépassait 65 524 clusters — les trois
quarts de la galerie. Or le comptage montre que **le nombre de fichiers ne croît
quasiment pas** avec la capacité ; seuls les clusters explosent :

| volume | clusters | fichiers | extents |
|---|---|---|---|
| `dev-1996` | 34 560 | 5 529 | 6 927 |
| `dev-1999` | 1,6 M | 7 260 | 21 530 |
| `secretaire-2003` | 10,2 M | 9 278 | 30 453 |
| `famille-2007` | 81,9 M | 12 222 | 177 790 |

C'est ce tableau qui a décidé de la suite : un volume de 320 Go est planifiable,
à condition de ne jamais raisonner en clusters.

### Les décisions

- **`DefragVolume`** : bitmap d'occupation (`ClusterBitmap`, déjà écrite pour le
  générateur), fichiers décrits par extents, et un **index des occupants par
  blocs** pour répondre à « qui occupe ces clusters ? » sans tableau
  proportionnel au volume.
- **`PartitionGeometry` décrit les trois formats** et porte ce qui les distingue
  pour l'oreille : le coût d'une validation. Sur FAT, trois écritures au tout
  début de la partition — le bras revient au bord une fois par fichier. Sur
  NTFS, un enregistrement de MFT, qui ne ramène personne au bord.
- **Le refus ne porte plus sur la taille mais sur le format**, et il est
  appliqué par la passerelle elle-même, pas seulement par l'écran qui grise le
  bouton.
- **La couche défragmentation est testée** : le paquet la compile une seconde
  fois sous le nom `DefragKit`. Les fichiers appartiennent à l'application, qui
  les compile de son côté ; les faire entrer dans un vrai module aurait demandé
  de rendre publique la moitié de la couche pour la seule commodité des tests.
  La double compilation coûte deux secondes.
- **`PLAN_ONLY`** dans le rendu hors-ligne : le bilan d'une passe sans rendre une
  note. Une passe d'époque dure des heures et son rendu pèse des gigaoctets.

### Effets mesurés

- Douze scénarios sur vingt se défragmentent, contre huit. Les quatre FAT32 de
  1999 s'ouvrent : passes de 3 h 07 à 5 h 04.
- Passe livrée **inchangée** : 204,7 s, 390 fichiers déplacés, 921 évacuations,
  aucun fichier fragmenté à l'arrivée.
- Le rejeu de la carte recomptait tous les clusters à chaque image ; il tient
  maintenant un décompte par bloc. Sans cela, un volume de 1999 figeait l'écran.
- Ce qui fixe la durée d'une passe est le **remplissage**, pas la taille : à
  76 % la passe livrée déplace 231 Mo pour ranger 179 Mo ; à 93 %, `dev-1999` en
  déplace 44 938 pour 6 710 — sept fois son contenu, en 23 284 évacuations.

### Pourquoi la stratégie de 95 n'a aucun sens sur NTFS

La stratégie de Windows 95 appliquée au 320 Go de `famille-2007` tasse trois
cents gigaoctets contre le début du disque par tampons de 256 Ko : **vingt-huit
millions de requêtes, 1,5 Go de mémoire, quatre-vingt-quatorze heures de passe
simulée** — pour ranger 244 fichiers fragmentés sur 12 220. Ce n'est pas une
limite technique, c'est un contresens historique.

### Le point d'accroche — `DefragStrategy`

**Fait** · commit `794a921`

Le planificateur mélangeait deux choses : émettre des requêtes bloc — lire,
écrire, valider — et décider quels fichiers déplacer, et où. Seule la seconde
change d'un outil à l'autre, et c'est elle qui fait la signature sonore d'une
passe. Le partage retenu :

- **`DefragStrategy`** porte la décision, et c'est une **valeur, pas un espace de
  noms** : les variantes d'un même outil (analyse seule, optimisation complète,
  *fast optimize*) sont des réglages, pas des algorithmes différents ;
- **`DefragOperations`** garde les fabriques communes. Rien n'y décide de quoi
  déplacer ni où : elles ne savent que traduire une décision déjà prise en
  requêtes bloc et en mutations de la carte ;
- **`Windows95Strategy`** est l'algorithme d'époque, inchangé ;
- **la taille du tampon devient un réglage de la stratégie**, plus une constante
  du module : 256 Ko est ce que faisait l'outil de 1995, pas une propriété des
  disques ;
- `DefragPlanner` se réduit au choix d'une stratégie **sur le format**. Ce choix
  n'a aujourd'hui aucune alternative à offrir, et c'est assumé : il existe pour
  que la passe NTFS soit un cas de plus, et rien d'autre.

Refactoring à comportement constant, vérifié sur trois volumes de tailles très
différentes plutôt que sur la seule passe livrée :

| | requêtes | durée | déplacés | évacuations |
|---|---|---|---|---|
| passe livrée | 12 036 | 204,7 s | 390 | 921 |
| `dev-1996` | 88 513 | 2 181 s | 5 522 | 3 811 |
| `dev-1999` | 1 092 121 | 18 256 s | 7 254 | 23 284 |

Tous les chiffres déjà publiés plus haut se retrouvent **à la requête près**.

### Deux défragmenteurs — `WindowsXPStrategy`

**Fait** · commit `faa2bbd`

La question posée était : pour NTFS, transposer JKDefrag depuis `ALGO.md`, ou
écrire quelque chose de plus naïf ? Ni l'un ni l'autre — la question mélangeait
deux axes.

- **`ALGO.md` documente JKDefrag, qui n'est pas un algorithme NTFS.** Son §8.1
  est catégorique : le moteur raisonne exclusivement en LCN, `ScanFat.cpp` et
  `ScanNtfs.cpp` ne sont que des parseurs. La même stratégie tourne sur FAT.
  L'implémenter n'aurait donc **pas** levé le refus, qui portait sur la mécanique
  du déplacement et non sur le placement.
- **L'outil à écrire n'était pas JKDefrag**, freeware de niche de ~2008, mais le
  `dfrg.msc` livré avec XP puis Vista — dérivé de Diskeeper Lite, et seul outil
  qu'un utilisateur de 2003 ou 2007 avait réellement sous la main.

Ce qui distingue cette passe, et qui s'entend : elle ne visite que les fichiers
fragmentés, sa destination est un trou déjà libre, elle n'évacue personne, et
valider un déplacement écrit un enregistrement de MFT là où il vit au lieu de
ramener le bras au cluster 0.

**Aucune fabrique nouvelle dans `DefragOperations`** : le cas NTFS est plus
simple que le cas FAT, la destination étant libre, donc disjointe de la source
par construction — la logique de recouvrement de `move` tourne à vide. Le bloc
de déplacement est un réglage de la stratégie, à 4 Mo : `FSCTL_MOVE_FILE` confie
la copie au système de fichiers, et la seule valeur citable est la courbe
d'UltraDefrag, qui dimensionne son bloc sur la capacité du volume (256 Ko sous
20 Go, 64 Mo au-delà de 2 To).

### Effets mesurés — les huit volumes NTFS

| scénario | plein | requêtes | durée | déplacés | fragmentés |
|---|---:|---:|---:|---:|---|
| `gamer-2003` | 8 % | 17 | 7,8 s | 0 | 0 → 0 |
| `secretaire-2003` | 94 % | 7 455 | 2 min 22 | 57 | 141 → 84 |
| `famille-2003` | 93 % | 9 190 | 2 min 28 | 39 | 80 → 41 |
| `dev-2003` | 94 % | 19 353 | 5 min 58 | 260 | 299 → 39 |
| `secretaire-2007` | 88 % | 35 408 | 16 min 03 | 186 | 186 → 0 |
| `famille-2007` | 93 % | 78 797 | 23 min 28 | 89 | 244 → 155 |
| `gamer-2007` | 90 % | 76 425 | 27 min 31 | 131 | 192 → 61 |
| `dev-2007` | 86 % | 280 595 | 1 h 18 | 172 | 172 → 0 |

`famille-2007` passe de 28 millions de requêtes et 94 h à **78 797 requêtes et
23 min 28**, et son plan se construit en 1,45 s. Aucune évacuation nulle part.
Les douze scénarios FAT sont inchangés à la requête près.

**Une lecture séduisante, et fausse, a été écartée en route.** Les deux volumes
à 86 et 88 % ressortent sans un fichier fragmenté, ceux à 93 et 94 % en gardent
la moitié : de quoi conclure à la règle des 15 % d'espace libre. Mais `dev-2003`
est plein à 94 % et répare 260 fichiers sur 299. La comparaison est même
contrôlée — `dev-2003` et `secretaire-2003` sont deux volumes de 40 Go remplis à
94 %, l'un répare 87 % de ses fichiers cassés, l'autre 40 %. Ce qui les sépare
est la **taille** de ce qu'il y a à réparer : 11 Mo par fichier déplacé contre
21, et 213 Mo sur `famille-2007`, qui n'en répare qu'un tiers. Un volume plein
garde des trous, mais pas de *grands* trous.

Réserve, et elle compte : ces moyennes portent sur les fichiers que la passe a
**réussi** à déplacer, pas sur ceux qui sont restés en morceaux. La corrélation
est nette, le mécanisme reste une hypothèse tant que les échecs ne sont pas
comptés par taille.

### Deux corrections, et ce qu'elles valent

**Fait** · commit `47a9abc`

**La zone réservée à la MFT est désormais visible du planificateur.** Elle est
libre dans la bitmap et pourtant interdite : aucun fichier n'y est, mais
l'allocateur n'y met personne tant que le volume n'est pas plein à 87 %. Sur un
320 Go, cela fait quarante gigaoctets d'un seul tenant — le plus grand trou du
volume, et de très loin. Le défragmenteur s'y précipitait et condamnait la MFT à
se fragmenter dès la création de fichier suivante. `GeneratedDisk` publie
`mftZone`, `DefragVolume` la porte, la recherche de trou la saute ; c'est ce que
fait `FindGap` avec ses `MftExcludes`.

Elle se voit dans les chiffres : `dev-2003` passe de 27 747 à 19 353 requêtes et
répare 260 fichiers au lieu de 274, les trous qu'il prenait dans la réserve lui
étant retirés. Le tableau ci-dessus est à jour.

**La règle « deux fragments contigus comptent pour un »** (`IsFragmented`,
`ALGO.md` §4.2) est appliquée par `DefragFile.fragmentCount` : ce qui compte est
le nombre de morceaux que la tête doit aller chercher, pas le nombre d'extents
que le système de fichiers a écrits.

Et le résultat mesuré est qu'elle **ne change rien** — pas un compteur de
fragmentation ne bouge sur les vingt scénarios, parce qu'aucun des deux
allocateurs ne produit d'extents adjacents. C'est une garde, pas une correction :
elle vaut pour ce qu'elle interdit à un futur allocateur, et il faut la compter
comme telle plutôt que lui attribuer un effet qu'elle n'a pas eu.

### Recoller au lieu de déplacer — `UltraDefragStrategy`

**Fait** · commits `ac71696`, `2ef7533`, `f3c8177`

La passe de XP échoue toujours au même endroit, et le journal l'avait déjà
noté : `famille-2007` garde 155 fichiers en morceaux sur 244, parce que ses gros
fichiers — 213 Mo en moyenne — ne trouvent aucun trou à leur taille sur un volume
plein à 93 %. L'outil ne sait faire qu'une chose, recopier un fichier **entier**
dans un trou libre, et sur ceux-là il renonce.

Le `defrag_routine` d'UltraDefrag 7.1.1 pose la question autrement. Un fichier de
213 Mo en quatre morceaux n'a pas besoin d'être déplacé pour aller mieux ; il a
besoin qu'on recolle ses **petits** morceaux et qu'on laisse les gros où ils
sont. La comparaison des deux bases de code donne cette défragmentation
partielle comme sans équivalent chez JKDefrag, et c'est ce qui l'a fait passer
en tête du classement : c'est la seule des trois pistes restantes dont le gain
se chiffrait d'avance.

#### D'abord, un compteur qui mentait par omission

Le gain ne se chiffrait pas, en réalité — il n'était pas *mesurable*.
`VolumeStats.fragmentedFiles` est binaire : un fichier ramené de quarante
morceaux à deux y reste « fragmenté », exactement comme avant. C'est suffisant
pour les deux stratégies écrites jusqu'ici, qui rendent un fichier contigu ou
renoncent, et parfaitement aveugle à un outil qui ne fait que réduire le nombre
de sauts de la tête.

Mesurée à ce compteur-là, la première passe UltraDefrag sur `famille-2007`
ressortait **pire** que celle de XP — 158 fichiers fragmentés contre 155 — au
prix de quatre fois plus de requêtes. Conclure à l'échec aurait été l'erreur du
chantier. `VolumeStats.fragments` est le `pi.bad_fragments` d'UltraDefrag : le
total des morceaux portés par les fichiers cassés. La même passe, au même
compteur : **130 288 morceaux restants contre 1 378**.

La leçon vaut au-delà de ce cas : un compteur binaire hérité d'un outil décrit
le monde de cet outil-là, et tout outil qui travaille autrement en sort perdant
par construction.

#### Les décisions

- **La transposition est littérale**, et jusqu'aux détails qui semblent
  arbitraires, parce que ce sont eux qui décident du nombre de déplacements :
  l'ordre décroissant par nombre de fragments (`fragmented_files_compare`), les
  **deux séquences** de `defrag_sequence` — seuil infini d'abord, donc tout
  fichier recopié entier, puis 20 Mo — chacune rejouée tant qu'elle déplace
  quelque chose ; le plafond du plus grand trou du volume ; le garde-fou
  `n < 2`, qui interdit de déplacer un morceau isolé ; et l'annexion d'un bout du
  gros voisin pour qu'un morceau recollé naisse au-dessus du seuil.
- **Le seuil de 20 Mo est une constante magique**, et le code d'origine le dit
  lui-même (`PART_DEFRAG_MAGIC_CONSTANT`). Rien dans UltraDefrag ne la justifie.
  Elle reste un réglage de la stratégie, comme la taille de tampon des deux
  autres.
- **Elle ne se choisit pas toute seule.** UltraDefrag est de 2018 et aucun des
  vingt disques de la galerie n'en a vu la couleur. `DefragPlanner.strategy(for:)`
  continue de donner l'outil que le format datait ; celle-ci s'obtient par
  `STRATEGY=ultraDefrag` au rendu hors-ligne. C'est un point de comparaison, pas
  un outil d'époque, et le journal préfère l'anachronisme déclaré à
  l'anachronisme discret.
- **Un déplacement partiel coupe une liste d'extents en son milieu** — le seul
  endroit de la couche où cela arrive. `relocation(of:vcn:length:to:)` isole ce
  découpage, et c'est ce que le test « un déplacement partiel conserve le
  fichier » surveille.
- **`firstGap` quitte `WindowsXPStrategy`** pour `DefragOperations` : elle ne
  décide rien, elle lit un bitmap et saute la zone MFT. Refactoring vérifié à la
  requête près sur les huit passes NTFS.

#### Effets mesurés

Les deux colonnes sont mesurées le même jour, sur les mêmes volumes.

| scénario | morceaux, XP | UltraDefrag | requêtes XP → UD | durée XP → UD |
|---|---:|---:|---:|---:|
| `gamer-2003` | 0 | 0 | 17 → 17 | 7,8 s → 7,8 s |
| `secretaire-2003` | 17 704 | 7 622 | 7 455 → 29 069 | 2 min 22 → 7 min 48 |
| `famille-2003` | 38 054 | 15 186 | 9 190 → 56 406 | 2 min 28 → 14 min 25 |
| `dev-2003` | 10 229 | **474** | 19 353 → 38 999 | 5 min 58 → 9 min 47 |
| `secretaire-2007` | 0 | 0 | 35 408 → 31 714 | 16 min 03 → 15 min 16 |
| `famille-2007` | 130 288 | **1 378** | 78 797 → 334 817 | 23 min 28 → 1 h 25 |
| `gamer-2007` | 26 753 | **376** | 76 425 → 121 233 | 27 min 31 → 39 min 32 |
| `dev-2007` | 0 | 0 | 280 595 → 272 531 | 1 h 18 → 1 h 18 |

Sur les quatre volumes où XP laisse du travail, il en reste entre **vingt et
cent fois moins**. Le prix est du même ordre de grandeur que le gain est grand :
quatre fois plus de requêtes et trois fois plus de temps sur `famille-2007`. Les
deux volumes que XP nettoie entièrement sont nettoyés de la même façon, ni mieux
ni plus vite — l'outil ne coûte que là où il sert.

#### L'ordre de passage coûte plus cher que la défragmentation partielle

Le détail qui ne se voyait pas dans le tableau. Sur `famille-2007`, la
**première** séquence — celle qui recopie les fichiers entiers, donc celle qui
fait le même travail que XP — prend 2 421 s là où XP en prend 1 400, pour
*moins* de données transférées (33,4 Go contre 38,0 Go).

L'écart est dans le seek moyen : **35 489 cylindres pour XP, 49 187 pour
UltraDefrag**. L'ordre de la MFT que suit XP a une localité involontaire — deux
fichiers voisins dans la MFT ont été créés à peu près en même temps, donc
alloués à peu près au même endroit. Le « les plus fragmentés d'abord »
d'UltraDefrag n'en a aucune : il traverse le plateau à chaque fichier. C'est
directement audible, et c'est un effet de l'ordre de parcours, pas de
l'algorithme de placement.

#### Ce que cela ne règle pas

- **Les fichiers ne deviennent pas contigus**, et ce n'est pas un défaut : c'est
  la promesse de l'outil. Sur `famille-2007`, 158 restent fragmentés contre 155
  pour XP — trois de plus, parce que l'ordre de passage n'attribue pas les mêmes
  trous aux mêmes fichiers.
- **Sur FAT, la défragmentation partielle n'a rien à mordre.** Presque aucun
  fichier de 1996 n'atteint les 40 Mo qui la déclenchent. Ce qui reste est une
  passe qui n'évacue personne : sur `dev-1996`, 79 s contre 36 min 21 pour
  Windows 95, et 862 morceaux restants contre 290. Quarante fois plus rapide et
  trois fois moins efficace, pour exactement la même raison.
- **Rien n'a été écouté.** Tout ce qui précède est en `PLAN_ONLY`. La signature
  décrite — des rafales courtes autour des mêmes cylindres, là où XP fait de
  longs transferts — est déduite des seeks et des tailles de requête, pas
  entendue. Et l'écran de l'application ne propose toujours que l'outil
  d'époque : la stratégie n'est atteignable que par le rendu hors-ligne.

#### Quatre durées fausses dans le tableau précédent

En remesurant la colonne XP, quatre durées du tableau des huit volumes NTFS se
sont révélées mal transcrites — le cas le plus net étant `dev-2007`, donné à
1 h 12 pour 4 655 s, c'est-à-dire 1 h 18. Vérification faite en rejouant le plan
depuis le commit `47a9abc` lui-même : les requêtes sont identiques à l'unité et
les durées aussi. Le modèle n'a pas bougé, c'est la transcription qui était
fausse. Le tableau ci-dessus et le README sont corrigés.

### Ranger sans évacuer — `JKDefragStrategy`

**Fait** · branche `chantier-2`

La première des pistes laissées ouvertes : le comblement de trous
d'`OptimizeVolume`. Il n'a pas été écrit seul, et c'est la première décision.

#### Pourquoi le mode 2 entier, et pas `OptimizeVolume`

`OptimizeVolume` n'est jamais appelé seul. Le mode par défaut de JkDefrag est le
mode 2 (`JkDefrag.cpp:267`), qui enchaîne quatre passes : `Defragment`, `Fixup`,
`OptimizeVolume`, `Fixup` (`JkDefragLib.cpp:5417`). Les deux `Fixup` remettent
chaque fichier dans sa **zone**, et les zones sont `CalculateZones` : la moitié
de la deuxième piste venait donc avec la première. Transposer le comblement sans
le reste aurait donné un outil qui n'a jamais existé, sur un volume encore
fragmenté que l'original n'aurait jamais vu.

Ce qui distingue cet outil des trois autres, et que les chiffres confirment : il
**range** le volume comme celui de 1995, et **n'évacue personne** comme XP et
UltraDefrag. Une destination est toujours un trou déjà libre.

#### Les décisions

- **La transposition est littérale**, jusqu'aux défauts, parce que ce sont eux
  qui fixent l'ordre des déplacements. `FindBestItem` rembobine sur le fichier
  qui suit le premier retenu, et rend ce **premier**. Il ne rembobine pas s'il
  n'existe aucun fichier sous le trou. Un fichier de la taille exacte du trou
  n'entre pas dans la somme qui sert de sortie anticipée
  (`Item->Clusters < ClusterEnd - ClusterStart`). Et `Defragment` s'arrête tout
  entier au premier fichier pour lequel le volume n'a plus un seul trou.
- **`FindHighestItem` rend le fichier le plus haut qui tient, pas le plus gros.**
  `ALGO.md` §6.4 dit « le plus gros qui rentre », et c'est inexact : le parcours
  part du fond du disque et s'arrête au premier qui convient. C'est ce qui vide
  le volume par le fond.
- **Le budget de `FindBestItem` est compté en visites, et il vaut deux
  millions.** L'original s'arrête au bout d'une demi-seconde de temps réel, ce
  qui rendrait le plan dépendant de la machine. Deux millions, c'est une
  demi-seconde à 250 ns la visite, un défaut de cache par nœud d'un arbre chaîné.
  **Il ne mord jamais** : sur les vingt volumes, la recherche la plus longue fait
  166 176 visites (`secretaire-2007`). Le plan est donc celui qu'aurait produit
  l'original sur n'importe quelle machine de l'époque, et non une approximation.
- **Un déplacement peut échouer, et l'échec coûte cher.** `Fixup` garde un trou
  courant par zone sans le relire, et rien n'empêche deux zones de viser le même
  trou. La zone 2 le remplit, la zone 1 croit qu'il est libre. Chez l'original,
  `FSCTL_MOVE_FILE` refuse la destination occupée, et `MoveItem` en conclut que
  le fichier est **immobile** pour le reste de la passe, puis recalcule les zones
  (`JkDefragLib.cpp:2542-2547`). C'est modélisé tel quel. Le premier essai ne le
  modélisait pas et écrivait par-dessus un voisin : c'est un plantage sur
  `famille-1996` qui l'a révélé. Mesuré : un échec sur `famille-1996`, un sur
  `secretaire-2007`, aucun ailleurs.
- **Une tranche qui déborde du fichier est refusée.** `Defragment` ne recalcule
  pas la taille de sa tranche après avoir sauté les morceaux trop gros pour elle.
  Elle peut alors demander des clusters au-delà de la fin du fichier. Borner la
  tranche aurait inventé un déplacement. La lecture retenue est que l'API refuse
  la plage, et comme `ClustersDone` avance quand même, le fichier est
  abandonné là. C'est une **hypothèse sur l'API**, pas une mesure : de 0 à
  150 cas par volume.
- **Space hogs** : plus de 50 Mo, ou l'un des 52 masques par défaut de
  `RunJkDefrag`. Le critère du dernier accès à plus de trente jours est
  **inactif** : le catalogue ne connaît pas les dates d'accès. C'est le
  comportement de Vista, qui désactive leur mise à jour par défaut, et non celui
  de XP.
- **Les répertoires n'ont pas de clusters** dans la galerie : la zone 0 ne
  contient que la réserve de 1 % et, sur NTFS, la zone MFT.
- **Le grain est celui de XP**, 4 Mo : JkDefrag passe par `FSCTL_MOVE_FILE`
  comme lui, et ses tranches de 1 Gio découpent les appels, pas la copie.
- **Elle ne se choisit pas toute seule** : JkDefrag est de 2008. Elle s'obtient
  par `STRATEGY=jkDefrag`, comme UltraDefrag.

`relocation(of:vcn:length:to:)` quitte `UltraDefragStrategy` pour
`DefragOperations`, puisque les tranches de `Defragment` en ont besoin. Les
vingt passes d'époque et trois passes UltraDefrag sont vérifiées à la requête
près.

#### Effets mesurés — FAT

| scénario | plein | durée, 95 → JkDefrag | évacuations, 95 | morceaux restants, 95 → JkDefrag |
|---|---:|---:|---:|---:|
| `secretaire-1993` | 90 % | 1 h 06 → 8 min 15 | 9 249 | 0 → 0 |
| `poweruser-1993` | 86 % | 40 min 51 → 6 min 07 | 2 705 | 0 → 64 |
| `gamer-1993` | 99 % | 32 min 36 → 8,7 s | 1 426 | 0 → 941 |
| `dev-1993` | 74 % | 30 min 35 → 4 min 30 | 4 561 | 0 → 0 |
| `secretaire-1996` | 75 % | 46 min 12 → 7 min 21 | 4 009 | 2 → 2 |
| `famille-1996` | 89 % | 1 h 01 → 6 min 54 | 4 039 | 176 → 192 |
| `gamer-1996` | 99 % | 59 min 18 → 7,9 s | 4 438 | 14 → 1 622 |
| `dev-1996` | 87 % | 36 min 21 → 5 min 03 | 3 811 | 290 → 330 |
| `secretaire-1999` | 87 % | 3 h 07 → 10 min 19 | 19 595 | 3 → 1 032 |
| `famille-1999` | 97 % | 4 h 29 → 12 min 09 | 11 989 | 8 → 2 707 |
| `gamer-1999` | 97 % | 4 h 14 → 8 min 55 | 8 675 | 89 → 1 325 |
| `dev-1999` | 93 % | 5 h 04 → 17 min 40 | 23 284 | 3 → 658 |

Hors des deux volumes pleins, la passe est **de six à vingt-huit fois plus
courte**, sans une évacuation. Ce que le tassage de 95 payait en va-et-vient,
JkDefrag le paie en morceaux laissés derrière lui. Sur les autres volumes de 1993
et 1996, l'écart tient en quelques dizaines de morceaux (64 au pire). Sur ceux de
1999, remplis de 87 à 97 %, il en reste de 658 à 2 707. Le remplissage seul ne
l'explique pas, puisque `famille-1996` est plein à 89 % et n'en garde que 192 ;
la cause n'a pas été cherchée.

Sur les deux volumes pleins à 99 %, JkDefrag ne fait **presque rien** : 7
fichiers déplacés sur l'un, 1 sur l'autre. `Defragment` s'arrête au premier
fichier pour lequel le volume n'a plus de trou (« Disk is full, cannot
defragment », `JkDefragLib.cpp:4047`), et `Fixup` échoue sur tous les autres. Un
outil qui n'évacue personne a besoin de trous, et ces deux volumes n'en ont plus.

#### Effets mesurés — NTFS

Mesurés sur le générateur corrigé (section suivante), où la zone MFT cède de
moitié au lieu de s'ouvrir d'un coup.

| scénario | plein | morceaux restants, XP | UltraDefrag | JkDefrag | durée, XP → JkDefrag | Go déplacés, XP → JkDefrag |
|---|---:|---:|---:|---:|---:|---:|
| `secretaire-2003` | 94 % | 23 777 | 13 821 | **5 118** | 1 min 18 → 21 min 25 | 0,4 → 5,6 |
| `famille-2003` | 93 % | 42 617 | 17 131 | **1 786** | 2 min 34 → 28 min 24 | 0,7 → 11,6 |
| `gamer-2003` | 8 % | 0 | 0 | 0 | 7,8 s → 6 min 11 | 0,0 → 4,1 |
| `dev-2003` | 94 % | 3 771 | 13 | 25 | 4 min 50 → 11 min 38 | 1,1 → 3,6 |
| `secretaire-2007` | 88 % | 0 | 0 | 0 | 9 min 49 → 49 min 41 | 10,2 → 44,3 |
| `famille-2007` | 93 % | 132 920 | 1 350 | 1 911 | 23 min 14 → 2 h 02 | 22,9 → 103,1 |
| `gamer-2007` | 90 % | 38 419 | 511 | 1 437 | 18 min 42 → 1 h 15 | 20,6 → 86,9 |
| `dev-2007` | 86 % | 0 | 3 | 0 | 1 h 07 → 1 h 55 | 40,7 → 79,4 |

Sur les cinq volumes où XP laisse du travail, JkDefrag fait mieux
qu'UltraDefrag sur `secretaire-2003` et `famille-2003`, et moins bien sur les
trois autres, sans jamais s'en éloigner d'un ordre de grandeur. Les deux
mécanismes diffèrent : UltraDefrag ne recolle que les petits morceaux,
`Defragment` recopie le fichier entier par tranches, chacune dans le plus grand
trou du moment. Ce qui fait gagner l'un ou l'autre selon le volume n'a pas été
isolé.

Le prix est ailleurs que chez UltraDefrag : dans ce qui est déplacé sans être
cassé. `gamer-2003` est plein à 8 % et n'a pas un fichier en morceaux ; JkDefrag
y déplace pourtant **4 Go en six minutes**. La zone des fichiers ordinaires
commence après la zone MFT et la réserve, à 13,5 % du volume, et tout ce qui est
posé devant est renvoyé derrière. C'est la mise en zone, pas un défaut.

Même leçon que pour UltraDefrag, dans l'autre sens : le nombre de **fichiers**
fragmentés monte (150 → 159 sur `famille-2007`, 90 → 110 sur `gamer-2007`),
parce qu'une tranche ramène un fichier à deux morceaux là où XP renonçait et le
laissait intact.

#### D'abord mesurée sur une zone MFT qui ne rétrécissait pas

La première série de mesures a été faite sur l'ancien générateur, dont la zone
MFT restait publiée entière même une fois entamée. Sur sept volumes sur huit,
`CalculateZones` comptait alors la zone comme de l'immobile **en plus** des
fichiers qui l'occupaient : la somme dépassait le volume, et `Fixup` passait
l'essentiel de son temps à vider une réserve que Windows aurait déjà rendue.
13 196 déplacements de `Fixup` sur `secretaire-2007`, 16 998 échecs faute de
trou sur `dev-2003`, où la phase d'optimisation ne faisait **rien du tout**.

Retirer la zone dès qu'elle était entamée faisait tomber ces chiffres de moitié
ou plus. C'est ce qui a décidé de corriger le générateur plutôt que la
stratégie : l'écart venait de la zone publiée, pas de JkDefrag. Les tableaux
ci-dessus sont ceux du générateur corrigé ; la comparaison complète est dans la
section suivante.

### L'ordre de passage, isolé

La troisième piste. `WindowsXPStrategy` gagne un réglage `order`, et la même
passe (même placement, même garde, même grain) est rejouée dans l'ordre de
chacun des autres outils. Par défaut rien ne change : les huit passes XP
retombent à la requête près.

Seek moyen en cylindres, sur le générateur corrigé :

| scénario | MFT (XP) | plus fragmenté d'abord (UD) | position sur le disque (JK) | arborescence (95) |
|---|---:|---:|---:|---:|
| `famille-2003` | 35 909 | 26 515 (−26 %) | 28 770 (−20 %) | 24 933 (−31 %) |
| `secretaire-2007` | 36 427 | 41 102 (+13 %) | 39 410 (+8 %) | 36 333 (0 %) |
| `dev-2007` | 29 089 | *47 805* | 38 055 (+31 %) | 29 087 (0 %) |
| `dev-2003` | 44 737 | *28 527* | *27 275* | 44 749 (0 %) |
| `secretaire-2003` | 22 202 | *26 852* | *26 221* | *24 531* |
| `gamer-2007` | 40 584 | *44 912* | *40 523* | *42 149* |
| `famille-2007` | 31 841 | *52 334* | *56 519* | *35 241* |

En italique, les cas où l'ordre change aussi **quels fichiers sont déplacés** :
le nombre de requêtes n'est plus le même, et l'écart ne mesure plus un ordre de
passage.

**Les « 39 % » écrits plus haut ne mesuraient pas un ordre de passage.** Ils
comparaient la première séquence d'UltraDefrag à la passe de XP sur
`famille-2007`. Sur ce volume, l'ordre décide aussi quels fichiers obtiennent
les trous : dans l'ordre d'UltraDefrag, la passe XP lit presque trois fois plus
de requêtes (191 221 contre 69 967) et laisse 71 019 morceaux au lieu de
132 920. Ce n'est plus la même passe.

Là où les fichiers déplacés sont les mêmes à l'unité, **l'ordre seul pèse de
−31 % à +31 %** du seek moyen. Deux choses en ressortent :
- **aucun ordre ne gagne partout** : l'arborescence est le meilleur sur
  `famille-2003` et n'apporte rien ailleurs ;
- l'ordre qui semble le plus local, la position sur le disque, coûte +31 % sur
  `dev-2007`. L'hypothèse est que la destination reste le premier trou depuis le
  début du volume : chaque fichier pris un peu plus loin allonge l'aller-retour.
  Rien ne l'a vérifiée.

La même mesure faite sur l'ancien générateur donnait de −26 % à +4 %, et
concluait à un effet négligeable sur les volumes de 2007. Cette conclusion n'a
pas survécu au changement de volumes. C'est un avertissement sur la portée de
ces chiffres : ils valent pour une disposition de volume, pas pour un outil.

La leçon qui, elle, tient sur les deux séries : **l'ordre de passage agit
d'abord sur ce qui est réparé**. Sur `dev-2003`, la passe XP laisse 2 310
morceaux dans l'ordre d'UltraDefrag contre 3 771 dans le sien, à placement
identique.

### La zone MFT cède de moitié

**Fait** · branche `chantier-2`

#### Le problème

L'allocateur NTFS tenait sa zone MFT, 12,5 % du volume, entièrement à l'écart
jusqu'à 87 % de remplissage, puis l'ouvrait **d'un coup et en entier**. Et le
générateur publiait cette zone telle qu'à la création du volume, même une fois
remplie de fichiers. Deux conséquences :

- **le vieillissement** : une fois la zone ouverte, l'allocateur y éparpillait
  les fichiers, loin de sa zone vierge, au lieu d'y trouver un bloc d'un tenant ;
- **les défragmenteurs** voyaient une réserve de 12,5 % pleine de fichiers.
  JkDefrag la vidait (section précédente), XP et UltraDefrag s'interdisaient
  des trous que Windows aurait déjà rendus.

#### Les décisions

- **La zone rend la moitié de sa queue libre, chaque fois que le reste du volume
  est plein.** C'est la seule règle publiée : « Each time the rest of the disk
  becomes full, the buffer size is halved » (documentation Linux-NTFS, `$MFT`),
  et « the unused tail of the MFT zone is halved […] this process can repeat »
  (HackMag, *Inside NTFS*). Microsoft ne publie pas l'algorithme : l'article de
  support sur `NtfsMftZoneReservation` dit seulement que la zone n'est utilisée
  qu'une fois le reste plein. La loi est donc **empruntée à des descriptions
  tierces**, pas à une source de Microsoft.
- **« Le reste est plein » veut dire qu'un placement hors zone échoue**, faute
  de clusters libres en nombre suffisant. Aucun seuil de remplissage :
  `mftZoneYieldsAt` disparaît du profil.
- **La moitié rendue est la plus éloignée de la MFT**, pour que celle-ci garde
  de quoi grandir d'un tenant. Et la zone publiée est la zone **courante**,
  celle que renverrait `FSCTL_GET_NTFS_VOLUME_DATA`.
- **La MFT est enfin visible des défragmenteurs.** Le volume qu'ils reçoivent
  ne marquait occupés que les clusters des fichiers du catalogue : `$Boot`, la
  MFT et `$MFTMirr` y paraissaient libres. La zone entière les masquait presque
  toujours ; une zone qui rétrécit les découvre. Le disque généré publie
  désormais ses `systemExtents`, que `DefragVolume` marque occupés sans en faire
  des fichiers. Mesuré sur le nouveau générateur **sans** cette correction : de 0
  à 104 clusters système écrasés par passe selon l'outil (`dev-2003`, dont la
  MFT est en 348 morceaux, est le pire). La passe de Windows 95 les contourne
  aussi : elle ne consulte pas la bitmap.

#### Ce qui change

Les douze volumes FAT et `gamer-2003`, qui n'a jamais rempli le reste de son
volume, donnent des passes d'époque et des démarrages **identiques** à la requête
près. Seule la passe JkDefrag de `gamer-2003` bouge, de 4,0 à 4,1 Go déplacés :
elle voit maintenant `$MFTMirr`. Les sept autres NTFS vieillissent autrement :

| scénario | fichiers fragmentés au départ | morceaux au départ | passe XP, requêtes | passe XP, morceaux restants |
|---|---:|---:|---:|---:|
| `secretaire-2003` | 141 → 178 | 21 315 → 26 099 | 7 455 → 4 819 | 17 704 → 23 777 |
| `famille-2003` | 80 → 68 | 42 510 → 47 055 | 9 190 → 9 144 | 38 054 → 42 617 |
| `dev-2003` | **299 → 36** | 19 168 → 12 253 | 19 353 → 17 309 | 10 229 → 3 771 |
| `secretaire-2007` | **186 → 49** | 13 922 → 9 651 | 35 408 → 23 962 | 0 → 0 |
| `famille-2007` | 244 → 268 | 165 802 → 163 226 | 78 797 → 69 967 | 130 288 → 132 920 |
| `gamer-2007` | 192 → 175 | 58 976 → 60 516 | 76 425 → 50 991 | 26 753 → 38 419 |
| `dev-2007` | 172 → 176 | 132 445 → 120 211 | 280 595 → 258 179 | 0 → 0 |

L'effet n'a pas de sens unique. Ce qui reste de la zone après le vieillissement,
en part du volume, sur une réserve d'origine de 12,5 % : 8,1 % sur `dev-2003`,
4,6 % sur `secretaire-2007` et `dev-2007`, 3,1 % sur `secretaire-2003` et
`gamer-2007`, et presque rien sur `famille-2003` et `famille-2007` (2 266 et
9 229 clusters). Le volume qui perd le plus de fichiers cassés, `dev-2003`, est
celui qui garde la plus grande zone ; mais `dev-2007`, qui en garde autant que
`secretaire-2007`, n'en perd aucun quand l'autre en perd les trois quarts. Une
moitié rendue est un bloc d'un tenant, où un fichier peut tomber entier : c'est
une piste, pas une explication. Le nombre de cessions n'a pas été compté.

Les démarrages bougent peu, mais le témoin change de signe sur deux volumes :

| scénario | durée | témoin |
|---|---:|---:|
| `secretaire-2003` | 35,4 s → 35,4 s | −4 % → +4 % |
| `famille-2003` | 31,6 s → 31,5 s | +5 % → +10 % |
| `dev-2003` | 50,4 s → 51,0 s | −11 % → −9 % |
| `secretaire-2007` | 40,4 s → 41,9 s | +1 % → +5 % |
| `famille-2007` | 38,9 s → 39,3 s | +7 % → +1 % |
| `gamer-2007` | 34,4 s → 34,9 s | +4 % → +4 % |
| `dev-2007` | 43,5 s → 44,0 s | +4 % → +2 % |

**Deux conclusions publiées ne tiennent plus**, et sont corrigées au README
plutôt qu'effacées ici :
- « sur NTFS, le témoin perd, jusqu'à −11 % » (chantier 6) : seuls `dev-2003`
  (−9 %) et `gamer-2003` (−1 %) restent sous leur témoin ;
- « ce n'est pas le remplissage qui décide » : l'argument reposait sur
  `dev-2003`, qui réparait 260 fichiers sur 299 là où `secretaire-2003` en
  réparait 57 sur 141. Sur les nouveaux volumes, `dev-2003` n'a plus que 36
  fichiers cassés. L'observation elle-même tient (32 sur 36 contre 68 sur 178,
  à remplissage égal), mais sur des effectifs trop petits pour porter une loi.

Les tableaux des sections précédentes du chantier 2 et du chantier 6 restent
tels qu'ils ont été mesurés, sur l'ancien générateur. Le README donne les
chiffres actuels.

**La génération ralentit sur deux volumes** : `dev-2007` passe de 1,8 à 5,1 s,
`secretaire-2007` de 0,34 à 0,92 s ; les cinq autres ne bougent pas. Ce sont les
deux volumes qui gardent le plus de zone, donc qui restent le plus longtemps
pleins hors d'elle : chaque écriture y rassemble des trous épars par `scatter`,
sur tout le volume. Avant, la zone s'ouvrait d'un bloc et ce régime n'existait
presque pas. Un compte des clusters libres de la zone, pour renoncer plus tôt, a
été essayé et retiré : il coûtait plus qu'il ne rapportait (6,2 s), le temps
étant dans les écritures qui réussissent, pas dans celles qui échouent.

#### Ce qui valide

Le test de l'allocateur vérifie désormais que la zone cède **de moitié** (entre
un tiers et deux tiers de sa taille à la première cession, toujours collée à la
MFT), qu'elle cède plusieurs fois à 96 % de remplissage, et que la MFT finit
malgré tout par se fragmenter. Un test vérifie que les quatre défragmenteurs
n'écrivent pas sur des extents système posés hors de toute zone. 209 tests.

### Un index des trous libres

**Fait** · branche `chantier-2`

#### Le problème

La zone MFT qui cède de moitié avait fait passer la génération de `dev-2007` de
1,8 à 5,1 s. La mesure, par compteurs posés dans `ClusterBitmap` :
`nextFreeCluster` lisait **8,86 milliards de mots** de bitmap pendant la
génération de ce volume. 8,3 milliards venaient de `scatter`, en 26 889 appels :
chacun traversait en moyenne 309 000 mots pleins, un tiers du volume, pour
rassembler quelques trous. `freeRunLength`, qui mesure les trous une fois
trouvés, ne pesait que 64 millions de mots.

Le coût n'était donc pas de **choisir** un trou, mais de **sauter les régions
pleines** pour l'atteindre.

#### Ce qui a été écarté

- **Un ensemble ordonné des plages libres**, un arbre des trous par adresse.
  Il répond aussi exactement, mais chaque allocation et chaque libération y
  scinde ou fusionne des plages : beaucoup de code et de mises à jour pour
  accélérer une seule question.
- **Un index des trous par taille.** Il ferait du best-fit en temps
  logarithmique, mais le best-fit du modèle est volontairement **fenêtré** (au
  plus 64 trous examinés, 65 536 clusters parcourus) : un index par taille
  trouverait de meilleurs trous, donc d'autres volumes, donc d'autres chiffres
  partout.
- **Faire partir `scatter` du curseur de recherche** plutôt que du début de la
  plage. Plus rapide, mais c'est changer le placement.
- **Compter les clusters libres de la zone** pour renoncer plus tôt (essayé à
  la section précédente) : le temps est dans les écritures qui réussissent.

#### La décision

**Deux niveaux de résumé au-dessus de la bitmap.** Un bit par mot, posé quand ce
mot a au moins un cluster libre ; un bit par mot de ce résumé, posé quand il
n'est pas nul. `nextFreeCluster` lit le premier mot comme avant, puis descend
dans les résumés pour trouver le prochain mot qui a un trou : il saute 64 puis
4 096 mots pleins d'un coup. Les résumés se tiennent dans `setRange`, seulement
quand un mot devient plein ou cesse de l'être.

L'index **ne décide de rien** : la réponse est exactement celle du balayage.
C'est la condition qui permettait de ne rien remesurer d'autre. Il coûte un bit
tous les 64 clusters, 125 Ko sur le 250 Go de `dev-2007`.

#### Ce qui valide

- **Empreinte exacte des vingt disques générés** (tous les extents du
  catalogue, tous les trous de la bitmap, la zone MFT et les extents système) :
  identique à celle d'avant l'index, volume par volume.
- **Les 56 bilans en aval** (vingt passes d'époque, vingt démarrages, huit
  passes UltraDefrag, huit JkDefrag) : identiques à la requête près.
- **Un test confronte l'index à un balayage naïf** sur deux volumes de 300 001
  et un million de clusters, assez grands pour que les deux niveaux servent,
  avec des plages allant du cluster isolé à 300 000 clusters. Il est
  discriminant : un résumé qui oublie de retirer un mot devenu plein le fait
  échouer 3 934 fois.

#### Effets mesurés

Génération, meilleur de trois :

| scénario | sans index | avec |
|---|---:|---:|
| `dev-2007` | 5,07 s | **0,82 s** |
| `famille-2007` | 1,19 s | 0,39 s |
| `secretaire-2007` | 0,87 s | 0,16 s |
| `gamer-2007` | 0,36 s | 0,12 s |
| `dev-2003` | 0,72 s | 0,65 s |
| `famille-2003` | 0,57 s | 0,44 s |

`dev-2007` passe sous les 1,8 s de l'ancien générateur. Les volumes FAT, trop
petits pour avoir de longues régions pleines, ne bougent pas au-delà du bruit de
mesure.

Les passes en profitent aussi, parce que les recherches de trou des
défragmenteurs passent par la même primitive. De bout en bout, génération
comprise : UltraDefrag sur `famille-2007` de 3,0 à 1,3 s, JkDefrag sur
`dev-2007` de 7,1 à 2,8 s. Windows 95 sur `dev-1999` ne bouge pas (0,84 s).

Ce qui domine maintenant la génération de `dev-2007` est le best-fit fenêtré de
`preferredRun` : c'est sa sémantique, pas un balayage, et il n'y a plus de gain
facile.

#### Un piège de build

Ajouter deux propriétés stockées à `ClusterBitmap` a laissé le build debug
incrémental de `swift test` incohérent : la suite complète **plantait** (signal
11, dans la destruction d'un `GeneratedDisk` compilée dans `DefragKitTests`),
alors que chaque suite passait seule. Ce n'était pas le code : un
`rm -rf .build/arm64-apple-macosx/debug` et la suite passe, 210 tests.

### La MFT sur la carte

**Fait** · branche `chantier-2`

#### Le problème

La section sur la zone MFT avait rendu `$Boot`, la MFT et `$MFTMirr` visibles
aux défragmenteurs, par `systemExtents`, mais pas à l'écran. Les deux cartes ne
lisaient que les fichiers : `DefragVolume.categoryRuns()` pour la passe,
`GeneratedDisk.shaded(count:)` pour la galerie. Une MFT hors zone y paraissait
libre, alors qu'aucun outil n'a le droit d'y écrire.

L'écart est petit en clusters et pas en sens. MFT des huit volumes NTFS :

| scénario | clusters | extents |
|---|---:|---:|
| `gamer-2003` | 802 | 1 |
| `famille-2003` | 1 980 | 1 |
| `secretaire-2003` | 2 554 | 1 |
| `gamer-2007` | 4 019 | 1 |
| `famille-2007` | 4 259 | 1 |
| `dev-2003` | 4 652 | **348** |
| `secretaire-2007` | 4 721 | **203** |
| `dev-2007` | 7 102 | 6 |

C'est sur `dev-2003` et `secretaire-2007` que l'erreur se voyait : une MFT en
centaines de morceaux, semés hors d'une zone qui a cédé, faisait autant de
faux trous.

#### Les décisions

- **Les extents système entrent dans les deux agrégations**, avant les
  fichiers, sans devenir des fichiers : ni déplacés, ni comptés dans les
  statistiques de la passe.
- **Ils prennent la couleur de `.reserved`**, celle des tables FAT, et non une
  couleur neuve. C'est la même chose : ce que le système de fichiers occupe pour
  lui-même. Le noyau le disait déjà, `FileCategory.metadata` étant commentée
  « FAT, MFT, répertoires ». La légende passe de « FAT, racine » à « FAT, MFT,
  racine ».
- `categoryMap()`, des deux côtés, suit la même règle : c'est la référence
  cluster par cluster des tests, et elle ne doit pas diverger de ce que montrent
  les plages.

Rien d'audible ne bouge : `initialRuns` ne sert qu'au rejeu de la carte et à la
légende, et aucune mutation ne change.

#### Ce qui valide

Deux tests, qui échouent tous les deux sans la correction (MFT comptée 0 au lieu
de 81 et de 104) :
- les quatre défragmenteurs publient la MFT en `.reserved` au départ, et elle y
  est encore une fois toutes les mutations rejouées ;
- la galerie peint un bloc entièrement MFT plein et en métadonnées, et laisse
  libre un bloc sans MFT.

212 tests.

#### Laissé ouvert

**Rien n'a été regardé à l'écran.** Le simulateur démarré sur le poste n'était
pas celui du projet, et un second n'a pas été démarré. La légende se replie
d'elle-même (`FlowRow`), mais le libellé allongé n'a pas été vu. À 48 × 26, un
bloc de `dev-2003` vaut des milliers de clusters : la MFT n'y gagne la couleur
d'un bloc que là où elle domine, et le nombre de blocs concernés n'a pas été
compté.

### Ce qui reste

- **La loi de la zone MFT n'a pas de source Microsoft.** La division par deux
  vient de descriptions tierces, et rien ne dit si la zone se reconstitue au
  montage suivant. Le modèle la suppose définitive.
- **Les tris complets de JkDefrag** : `OptimizeSort` sur les cinq critères, avec
  `Vacate` et sa protection anti-ver, plus `ForcedFill` et `OptimizeUp`. Ce sont
  les seuls modes qui évacuent. Les zones, elles, sont faites.
- **`SlowDown`** reste un réglage de tempo historique et audible (`-s 1..5`).
  Non transposé : la vitesse par défaut n'endort rien.
- **Rien n'a été écouté.** JkDefrag comme l'ordre de passage sont mesurés en
  `PLAN_ONLY`. La signature attendue (prendre au fond, poser dans le trou en
  cours, un trou après l'autre en remontant) est déduite, pas entendue.

### Deux petits points, et une mise au point de vocabulaire

**Une passe qui n'a rien à faire ne devrait pas se lancer.** `gamer-2003` est
plein à 8 % et n'a pas un fichier fragmenté : il rend une passe de 17 requêtes
et 7,8 s. UltraDefrag a exactement la garde qui manque —
`check_fragmentation_level` annule le job sous un seuil. C'est quelques lignes,
et c'est plus juste que sept secondes de bruit.

**Correction, à la relecture du source : cette garde ne garde rien par défaut.**
Le seuil vaut zéro (`memset` des options, `options.c:51`), et l'interface
graphique efface la variable qui le règle (`wxgui/config.cpp:180`). La condition
est `fragmentation < seuil`, donc `0 < 0`, qui est fausse : un volume sans un
fichier cassé passe quand même. La garde n'existe que pour qui pose
`UD_FRAGMENTATION_THRESHOLD`. L'ajouter ici aurait fait mieux que l'outil
qu'elle prétend imiter. Elle n'est pas écrite.

**`SlowDown()` (`-s 1..5`) de JKDefrag bride volontairement l'I/O.** Pour un
projet qui sonifie une passe, c'est un réglage de tempo directement audible,
et il est historique.

**Le journal disait « JKDefrag / MyDefrag … *fast optimize* ». C'était
imprécis.** MyDefrag est un fork **closed source** : rien n'en est lisible dans
le corpus, et lui attribuer une référence revient à en promettre une qu'on ne
peut pas ouvrir. Ce qui existe et se lit, c'est `OptimizeVolume` de JKDefrag
3.36, que `ALGO.md` §6.4 décrit comme « la passe d'optimisation rapide, celle
des modes 2 et 3 ». Même algorithme, vrai nom, source vérifiable.

Licences, pour mémoire : JKDefrag est **incohérent** (`LICENSE` dit Apache 2.0,
tous les en-têtes source disent GPL v2 / LGPL), UltraDefrag est en GPL v2
cohérent partout. Ni l'un ni l'autre ne gêne pour transposer un algorithme
décrit en prose ; les deux gêneraient pour du code recopié.

### Écouté, à l'oreille

Ce paragraphe ne vaut que pour la passe NTFS de Windows XP. La passe
UltraDefrag, elle, n'a pas été écoutée du tout.

Tout ce qui précède est mesuré en `PLAN_ONLY`. La signature sonore décrite ici —
pas de « clac » de retour au bord, des rafales longues de 4 Mo — en était
**déduite**, et a depuis été **confirmée à l'écoute** : une passe NTFS sonne
continue, sans le battement périodique qu'impose à FAT une validation au tout
début de la partition.

C'est une écoute, pas une mesure : personne n'a compté les retours au cylindre 0
dans la trace. Ce qui est acquis, c'est que le motif FAT est absent là où le
modèle dit qu'il doit l'être — assez pour ne plus tenir la signature NTFS pour
une hypothèse, pas assez pour en faire un chiffre.

---

## Chantier 3 — rendre la passe au fil de l'eau

**À venir**

Tout est calculé avant que le premier son ne sorte : requêtes, chronologie
mécanique, repères audio. Mesure sur `dev-1999`, un FAT32 de 6,4 Go rempli à
93 % : **1,1 million de requêtes, 780 Mo de pic**. Tenable sur un Mac, à la
limite sur un téléphone. C'est cela qui plafonne la taille des volumes, pas le
planificateur, qui ne connaît que des extents.

Ce qui rend le passage en flux possible : le simulateur est déjà causal, chaque
opération partant quand le disque se libère. Planificateur → simulateur → repères
deviennent un pipeline tiré par une fenêtre de quelques secondes d'avance.

Ce qui casse, et qu'il faudra trancher :

- la **durée totale n'est plus connue d'avance** — donc plus de transport absolu,
  et l'avancement s'exprime en fichiers traités, ce qu'affichait d'ailleurs
  l'outil d'époque ;
- le **retour en arrière** demande des points de reprise périodiques ;
- les phases se datent au fil de l'eau.

Tentatives déjà faites pour réduire le pic, sans effet notable : aplatir les
mutations dans un tableau unique, réserver la capacité des gros tableaux,
supprimer les tableaux temporaires de la boucle chaude. Le pic est structurel —
c'est le prix du « tout calculer d'avance ». En revanche, l'empreinte qui
**reste** après construction a été réduite : ni les requêtes, ni la trace brute,
ni les opérations du plan ne sont conservées, personne ne les relisant.

---

## Chantier 4 — afficher des millions de blocs

**Fait**

### Le problème

Trois choses tenaient ensemble, et une seule était visible.

`ClusterMapView` construisait un `Path(roundedRect:)` par cellule dans un
`Canvas`. À 1 248 blocs (48 × 26) cela passait ; au-delà de ~3 000 rectangles
SwiftUI plie, et le plein écran en demande vingt fois plus. C'était le symptôme.

La grille était figée en `static` sur `ClusterMapPlayer`, lue par la vue, par la
galerie et par le player lui-même. Un plein écran a besoin d'une grille dérivée
de la surface, donc variable à l'exécution : c'était ce contrat-là, et non le
dessin, qui interdisait le chantier.

Et la carte était tenue **par cluster**. `DefragVolume.categoryMap()` alloue un
octet par cluster, le plan le gardait dans `initialMap`, et le player en prenait
une copie qui devenait réelle à la première mutation. Sur `famille-2007` —
82 millions de clusters — cela faisait deux fois 78 Mo résidents pendant toute la
passe, à côté du pic du chantier 3.

Ce que coûtait chaque partie, mesuré sur ce volume :

| | avant | après |
|---|---:|---:|
| `reset()` + décompte, grille 48 × 26 | 194,0 ms | **3,5 ms** |
| `reset()` + décompte, grille 192 × 108 | 194,6 ms | **3,9 ms** |
| rejeu des 78 602 mutations | 137,6 ms | 19,7 ms |
| carte portée par le plan | 81 920 000 o | **2 133 480 o** |
| empreinte du player après rejeu | +78,2 Mo | **+2,6 Mo** |

Les 194 ms étaient payés à **chaque retour en arrière** dans le transport, et
l'auraient été une seconde fois à chaque entrée en plein écran.

### Les décisions

- **Le rendu n'était pas le problème, et Metal n'y aurait rien changé.** Mesuré
  à 192 × 108 : réduire le décompte en cellules coûte 0,1 ms, fabriquer le
  buffer de pixels et le `CGImage` 0,1 ms — pour un budget d'image de 16 ms. Ce
  qui coûtait, c'était un `Path` par cellule. Un `MTKView` aurait accéléré ce
  qui ne consomme rien, au prix d'une sortie de SwiftUI, d'une seconde horloge à
  accorder avec celle du moteur audio — qui est aujourd'hui la seule, et c'est
  ce qui fait qu'un bloc change de couleur quand il s'entend — et d'une couche
  que `DefragKit` ne compilerait pas, donc intestable. La carte est **un
  `CGImage` d'un pixel par bloc**, agrandi sans interpolation.
- **Ce qui disparaît en route, ce sont les jours entre les blocs.** Un rendu par
  pixel ne porte ni marge ni coin arrondi : la carte devient un aplat au lieu
  d'une mosaïque. Un chemin de secours par seuil a été écarté — il aurait laissé
  le seul chemin qui compte, celui du plein écran, sans jamais être regardé par
  personne. C'est aussi ce que faisait la carte d'origine quand les blocs
  devenaient fins, et le contraste suffit à détacher un bloc isolé.
- **La carte est une suite de plages, jamais un tableau de clusters.** C'est la
  bascule que le chantier 2 avait faite pour le défragmenteur, appliquée au
  dernier endroit qui y échappait. `ClusterRunMap` est une carte d'intervalles
  **découpée en blocs**, exactement comme l'`ExtentIndex` du volume et pour la
  même raison : dans un tableau plat de 356 000 plages, une insertion au milieu
  déplacerait la moitié du tableau, et le coût d'une écriture dépendrait encore
  de la taille du volume. Le prix assumé est que deux plages identiques de part
  et d'autre d'une frontière de bloc restent deux plages.
- **Une mutation rend ce qu'elle recouvre.** `replace` restitue chaque morceau
  écrasé avec sa catégorie d'avant : c'était la seule chose que le rejeu
  demandait à la carte par cluster, et le décompte s'en décrémente exactement.
- **La grille se dérive de la surface, elle ne se fige pas.** 192 × 108 est du
  16:9 ; un iPhone 17 Pro Max en paysage est en 19,5:9 et y aurait gagné des
  bandes noires. Le repliement en lignes n'a aucune signification physique — la
  carte est une suite linéaire de clusters, et l'endroit où elle revient à la
  ligne est arbitraire. On prend donc le découpage qui remplit l'écran :
  **191 × 88 = 16 808 blocs**. Le plafond de 24 000 blocs est une contrainte de
  surface, et il vient de la reconstruction du décompte, pas du rendu.
- **La couleur d'un bloc porte son remplissage.** À 6 579 clusters par bloc sur
  un 320 Go, une catégorie majoritaire ne dit plus rien : la teinte est celle de
  la catégorie dominante, mélangée vers le fond selon la part occupée, avec un
  plancher — sans lui, huit clusters écrits dans un bloc de quatre mille
  seraient strictement invisibles. C'est calculé dans la boucle de réduction,
  celle qui coûte 0,1 ms. **La carte 48 × 26 n'y touche pas** : à 35 clusters
  par bloc le taux n'apprend rien et délaverait une carte déjà petite.
- **La rémanence se fonde sur l'âge, pas sur le rang** — la décision du
  chantier 5 pour la traînée du plateau, reprise telle quelle : un train de mille
  accès en dix millisecondes ne doit pas manger tout le dégradé. Fenêtre de
  0,34 s, plafond de 512 points qui coupe la queue de la liste sans toucher au
  fondu. Elle se dessine en `Canvas` par-dessus l'image, et non dans le buffer :
  refaire le `CGImage` soixante fois par seconde pour quelques dizaines de blocs
  serait payer la carte entière pour une trace.
- **La géométrie d'affichage descend dans `Sources/Model`**, où `DefragKit` la
  compile — c'est ce qui la rend testable. Même partage qu'au chantier 5 : la
  vue ne fait plus que dessiner.

### Ce qui valide

Vingt-six tests, dont celui qui porte tout le changement de structure : sur un
volume assez petit pour que la carte par cluster tienne, le décompte par plages
est comparé à celui qu'aurait donné l'ancien algorithme — **treize instants,
quatre grilles, égalité stricte**. Les autres : la somme des décomptes vaut le
nombre de clusters ; un retour en arrière suivi d'un ravancement redonne la même
carte qu'un player neuf ; changer de grille puis revenir est réversible, et ne
rembobine pas le rejeu ; un bloc entièrement libre rend exactement la couleur du
fond, un bloc plein exactement celle de sa catégorie, un bloc à moitié rempli
strictement entre les deux ; 191 × 88 tombe sur les 956 × 440 de l'appareil visé.

Non-régression : passe livrée **inchangée à 204,7 s**, 390 fichiers déplacés,
921 évacuations. `dev-1996` à 2 181,1 s et `secretaire-2003` à 142,1 s de même.
La sortie du rendu hors-ligne est restée **bit à bit identique** après l'étape de
rendu, et les captures d'écran de la carte 48 × 26 sont pixel pour pixel celles
d'avant le passage aux plages.

Deux erreurs ont été prises par la capture d'écran et non par les tests : la
première carte rendue était rouge et jaune, un `UInt32` se rangeant à l'envers
en mémoire là où Core Graphics attendait l'ordre réseau ; et c'est en regardant
`famille-2007` en plein écran que la teinte proportionnelle a montré ce qu'elle
vaut — la zone réservée à la MFT s'y lit enfin, là où la carte en pouce n'était
qu'un aplat violet.

### Ce qui reste ouvert

- **Le paysage n'a été vérifié que par les tests.** Faire pivoter le simulateur
  demande des autorisations d'accessibilité dont la session ne disposait pas, et
  la préférence d'orientation est réécrite au redémarrage de l'appareil. Toute la
  mise en page passe par `GeometryReader` et la dérivation de grille est testée
  sur 956 × 440, mais **aucune capture ne le montre**, et c'est exactement le cas
  d'usage que le plein écran vise.
- **Le rétablissement de la veille** après sortie du plein écran est écrit et lu,
  pas observé à l'exécution.
- **Une mutation coûte maintenant un remaniement de plages** là où elle ne
  touchait que deux clusters : sur `dev-1996`, 34 560 clusters et 60 375
  mutations, le rejeu complet passe de 3,2 à 15,1 ms. C'est le prix du
  changement, il ne se paie qu'au rembobinage total d'une passe de 2 181 s, et
  il est très inférieur aux 194 ms qu'il remplace sur les gros volumes — mais
  c'est bien une régression sur les petits, et elle est écrite comme telle.
- **Tous les chiffres sont ceux d'un Mac.** Rien n'a été mesuré sur l'appareil,
  où il faut compter un facteur deux.
- `GeneratedDisk.categoryMap()` et `Volume.categoryMap()` n'ont plus aucun
  appelant hors des tests. Elles étaient déjà sans emploi avant ce chantier ;
  elles restent, faute d'avoir tranché si elles gardent une valeur de référence.

---

## Chantier 5 — le plateau montre ce que le disque fait

**Fait**

### Le problème

`PlatterView` n'avait pas bougé depuis le spike, alors que la couche physique
avait été reprise trois fois. La vue **affichait des positions que le simulateur
savait fausses** :

| | ce que le modèle calcule | ce que la vue montrait |
|---|---|---|
| bras au repos | cylindre de parcage, au moyeu | cylindre 0, au bord |
| lecture séquentielle | la tête descend piste après piste | bras immobile, puis saut |
| rotation | 3 600 à 7 200 tr/min selon le disque | 0,85 tour/s, en dur |
| mise en rotation | rampe du premier ordre, `spinUp(duration:)` | `time > 0.6` |
| écriture | `isWrite` est dans l'échantillon | pointe toujours ambre |

Le premier écart contredisait ce que le README donne pour le fondement du « clac »
du démarrage : le bras parqué au diamètre intérieur, donc un premier accès en
course quasi complète. On l'entendait ; on voyait l'inverse.

### Les décisions

- **Un échantillon par requête porte son début et sa fin.** `HeadSample` gagne
  une durée et un cylindre d'arrivée — donc le bras avance pendant le transfert.
  Un échantillon par piste aurait suivi la taille des transferts ; celui-ci
  reste à un par requête, et les largeurs sont choisies pour que la structure
  **garde son pas de vingt-quatre octets**. Le gain d'information est gratuit.
- **Une seule horloge angulaire, ralentie d'un facteur cent.** Un plateau à
  120 tours/s n'a pas d'angle affichable à 60 images/s — au mieux un aplat, au
  pire des repères qui battent en arrière. Les deux échelles qui coexistaient
  (repères en dur, traînée à l'angle absolu, donc dispersée au hasard et
  immobile) sont remplacées par un seul ralenti, **proportionnel au régime
  réel** : 1,2 tour/s pour un 7 200, 0,6 pour un 3 600.
- **La traînée est solidaire du plateau.** Les données sont gravées dessus : un
  accès naît sous la tête, puis dérive. Une lecture séquentielle y dessine une
  spirale, qui est ce qu'elle est. La fenêtre de traînée vaut **un tour
  apparent** — au-delà, les points anciens repassent sur les récents.
- **Le fondu se calcule sur l'âge, pas sur le rang.** Il étalait tout le dégradé
  sur quatre-vingt-dix millisecondes dans un train dense, et affichait presque à
  pleine opacité deux accès distants d'une seconde.
- **Le bras part au dernier moment**, en calant le départ sur la durée du seek
  au lieu de le faire apparaître à destination avec jusqu'à vingt-huit
  millisecondes de retard. Interpolation par `smoothstep` et **non** par les
  quatre phases du `SeekProfile` : celui-ci donne des durées, pas une loi de
  position, et il faudrait intégrer deux fois une vitesse trapézoïdale pour un
  événement qui dure de 0,06 à 1,2 image. La cubique a déjà la bonne allure —
  c'est le profil *speedup + slowdown sans coast*, celui des seeks courts.
- **Le balayage de l'image est montré comme un voile.** Dans un train dense le
  bras traverse plusieurs cylindres par image ; en afficher un tiré au sort
  donnait un grésillement.
- **La géométrie d'affichage descend dans `Sources/Model`** (`Platter.swift`),
  où `DefragKit` la compile : c'est ce qui la rend testable. La vue ne fait plus
  que dessiner.

### Ce qui valide

Neuf tests dans `PlatterTests`, dont les quatre invariants qui comptent : le
bras est au cylindre de parcage avant le premier accès ; le nombre de cylindres
traversés par un transfert tombe sur `sectorCount / (heads × spt)` à un près ;
la position ne se téléporte jamais d'une image à l'autre sur quatre cents accès
aléatoires ; et les tours accomplis sont monotones, nuls avant la mise en
rotation, avec un retard asymptotique égal à la constante de temps.

Non-régression : passe livrée inchangée à 204,7 s, 390 fichiers déplacés,
921 évacuations. La constante de temps de la rampe est désormais **partagée**
avec `SpindleVoice` — si les deux divergent, l'image cesse de coller au son.

### Laissé ouvert

- **`WorkloadPhase.spin` est du code mort** : `WorkloadLibrary` le renseigne,
  personne ne le lit, et `DiskSimulator` n'émet **jamais** de `spinDown`.
  `SpindleTimeline` sait déjà le décrire ; l'activer ajoute un repère aux cues,
  donc change le son.
- **Le bras n'est jamais re-parqué** après une longue inactivité, alors que les
  trois secondes et demie de queue de la passe s'y prêteraient — et qu'un
  parcage s'entend.
- **Un transfert qui déborde du dernier cylindre tourne en rond** au lieu d'être
  tronqué (`min(headCylinder + 1, cylinders - 1)`) : préexistant, mais le bras
  s'y colle maintenant visiblement au moyeu.
- **La ZBR ne se voit pas** : les cercles de zones sont tracés, mais rien ne
  montre que le débit chute vers l'intérieur alors que ça s'entend.
  `sustainedMBs(cylinder:)` existe et n'est utilisé nulle part dans l'interface.
- Le **sens de rotation** n'est documenté nulle part. Repères et traînée sont
  cohérents entre eux, ce qui est l'essentiel, mais la convention mériterait
  d'être vérifiée plutôt que devinée.
---

## Chantier 6 — démarrer n'importe quel disque

**Fait** · branche `boot-all`

### Le problème

La galerie fabriquait vingt disques, et le simulateur ne savait en faire qu'une
chose : les défragmenter — quand le format s'y prêtait, soit douze sur vingt. Le
scénario de démarrage, lui, ne vivait que sur un disque : le Barracuda de 2001.

La raison n'était pas le matériel — `GeneratedVolumeBridge.drive` déduisait déjà
la géométrie et la loi de seek de n'importe quelle fiche — mais la **description
de la charge**. `WorkloadLibrary.windowsBootAndOffice` décrit le démarrage en
fractions du plateau : `Region.drivers = 0.075`, `Region.registry = 0.125`. Ces
constantes ont été réglées à l'oreille pour un 20 Go de 2001. Sur un 210 Mo de
1993, elles ne désignent rien.

### Les décisions

- **Un démarrage se décrit en fichiers, pas en fractions.** Un acte du
  démarrage est une requête sur le catalogue — catégorie, extension, plafonds —
  et les fichiers retenus sont lus avec exactement les extents que l'allocateur
  leur a donnés. Où va la tête devient un résidu de l'histoire du volume, comme
  la fragmentation en est un. C'est la même bascule que pour la génération de
  disques : on décrit une intention, jamais un résultat.
- **La durée est mesurée, pas décrétée.** Entre deux fichiers, la machine
  calcule, et le disque attend. Ce temps entre dans le simulateur par un champ
  de plus sur une requête (`thinkTime`, nul pour les deux scénarios livrés) et
  devient le **plancher** du démarrage. Il vaut 29 à 52 % du total selon les
  profils : assez pour que le disque reste audible, assez pour qu'un disque
  parfait ne donne pas un démarrage instantané.
- **Les constantes de calcul sont assumées comme un calage**, deux par époque,
  choisies pour que le total tombe sur les durées d'alors (29,5 à 68,9 s sur les
  vingt profils). Elles ne prétendent pas mesurer un processeur. Ce qu'elles
  fixent honnêtement, c'est le plancher ; ce qui s'y ajoute est du disque, et
  c'est la seule grandeur qu'on revendique.
- **Un témoin accompagne chaque mesure** : le même contenu jamais fragmenté,
  chaque fichier d'un seul tenant, tassé contre le début du volume. Sans lui une
  durée de démarrage ne veut rien dire — on ne saurait pas ce qui, dedans, vient
  du disque. Il ne change qu'une chose, la place ; la sélection des fichiers est
  identique, et l'ordre est celui que le système tirerait de chaque placement.
- **Le préchargeur est un trait d'époque, pas de matériel.** Jusqu'à Windows 98
  les fichiers partent dans l'ordre du registre ; à partir de XP, le préchargeur
  range la liste par position sur le disque. C'est modélisé par un ordre de plus
  (`byPosition`) porté par la table des époques.
- **Rien n'est refusé, et sans outil supplémentaire.** Le chantier voisin a dû
  écrire un second défragmenteur pour NTFS, parce que le format datait l'outil.
  Un démarrage n'en demande aucun : lire des fichiers ne suppose aucune
  stratégie de rangement, et les vingt profils passent par le même chemin.

### Ce qui a été mesuré

**Sur FAT, la fragmentation ne coûte presque rien à un démarrage** — de 0 à 4 %.
**Sur NTFS, le témoin perd**, jusqu'à −11 %.

| | durée | témoin | écart |
|---|---|---|---|
| `dev-1996` (VFAT, 11 % de fichiers fragmentés) | 57,5 s | 57,5 s | +0 % |
| `secretaire-1999` (FAT32) | 54,5 s | 52,4 s | +4 % |
| `famille-2007` (NTFS 320 Go) | 38,9 s | 36,4 s | +7 % |
| `gamer-2003` (NTFS 80 Go) | 68,9 s | 69,6 s | −1 % |
| `dev-2003` (NTFS 40 Go) | 50,4 s | 56,4 s | −11 % |

Le premier résultat n'est pas un défaut du modèle, c'est ce qu'il dit : un
démarrage lit les fichiers qu'un installeur a écrits d'affilée sur un disque
encore vide — la population **la moins** fragmentée du volume. Les fichiers en
morceaux d'un `dev-1996`, ce sont ses sorties de compilation, que personne ne
lit au démarrage. Ce qui fait le bruit, c'est l'ordre des demandes et
l'étalement de ce qu'il faut lire, pas le morcellement. Windows a fini par en
tirer la même conclusion : c'est `layout.ini`, et non le défragmenteur, qui
s'occupait des fichiers de démarrage.

Le second dit la même chose que la galerie depuis le début : NTFS choisit le
trou qui convient plutôt que le premier venu. Sa disposition réelle après trois
ans d'usage bat un rangement naïf qui empile tout dans l'ordre du répertoire
derrière la zone MFT. Le témoin reste une borne — ce qu'un rangement bête
donnerait — mais il cesse d'être un majorant, et c'est écrit plutôt qu'arrondi.

**Le préchargeur de XP se voit dans les chiffres.** Sur `famille-2007`, le seek
moyen tombe de 100 202 à 32 693 cylindres et le nombre de seeks de 1 140 à 684.

**La lecture groupée des métadonnées NTFS était indispensable.** Sans elle,
chaque ouverture faisait un aller-retour entre l'enregistrement de MFT, en tête
du volume, et un fichier posé trois cents gigaoctets plus loin : deux courses
quasi complètes par fichier, un seek moyen de 100 000 cylindres, et un démarrage
qui ne ressemblait à rien. Le préchargeur lisait bien les métadonnées d'un bloc,
et c'est ce qui est modélisé.

### Ce qui a été écarté

- **Le mode « live ».** Un démarrage dure une minute et coûte quelques milliers
  de requêtes : le précalculer prend quelques millisecondes et garde le
  déplacement dans la chronologie, la barre de progression et les séries
  d'affichage. Le rendu au fil de l'eau reste le chantier 3, pour la
  défragmentation — qui, elle, dure des heures.
- **La carte des clusters pendant un démarrage.** Un démarrage ne déplace rien,
  et la carte par cluster pèse 80 Mo sur un volume de 320 Go. Le plateau et sa
  traînée disent déjà où va la tête ; le panneau se contente du bilan.
- **Déduire le système des manifestes** qui posent des fichiers système : c'est
  faux, Internet Explorer 5 en posait autant qu'un pilote et reste une
  application qu'on lance. La liste des six manifestes de système est écrite en
  clair.

### Ce qui reste ouvert

- **Le crépitement est plus clairsemé que celui du scénario livré** : 1 056
  requêtes sur tout un démarrage de `dev-1996`, contre 90 à 150 par seconde dans
  le scénario réglé à l'oreille. Un vrai démarrage consulte le registre à chaque
  périphérique, relit des `.INI`, rouvre des répertoires — autant d'accès courts
  qui ne correspondent à aucun fichier du catalogue, et qu'il faudrait poser
  comme un modèle à part plutôt que d'inventer des fichiers pour les porter.
- **L'entrée de répertoire d'un fichier FAT est lue là où vivent ses fichiers**,
  faute de savoir où l'allocateur a posé les clusters du répertoire. C'est la
  seule approximation de placement du modèle, et elle ne coûte qu'une lecture
  par répertoire.
- **Le témoin coûte une seconde planification et une seconde simulation.**
  Négligeable sur un démarrage, mais c'est un patron à ne pas reprendre tel quel
  pour une passe de défragmentation de cinq heures.
- Une **session sans fin** — laisser le disque travailler en fond — demanderait
  le mode live, et c'est le seul usage qui l'exige vraiment.

## Chantier 7 — ce que le disque fait quand il ne fait rien

**Fait** · branche `disque-au-repos`

### Le problème

Trois points laissés ouverts par le chantier 5, qui ont en commun de décrire un
disque dont **le modèle savait déjà tout, mais qu'il ne produisait jamais**.

| | ce que le modèle sait | ce qu'il faisait |
|---|---|---|
| `WorkloadPhase.spin` | chaque phase dit ce que fait le moteur | renseigné par la bibliothèque, lu par personne ; la mise en rotation était recopiée à la main dans `Scenario` |
| arrêt du moteur | `SpindleVoice.spinDown`, `AudioCue.spinDown`, le cas haptique : tout existe | `DiskSimulator` n'émettait **jamais** l'événement |
| fin d'une passe | 3,5 s de queue | silence complet, bras abandonné là où le dernier transfert l'a laissé |
| transfert au-delà du dernier cylindre | `min(headCylinder + 1, cylinders - 1)` | relit la même piste jusqu'à épuisement du compte |

Le dernier est mesurable : une requête de cinquante pistes posée à une piste de
la fin du disque annonçait **2 841 600 octets lus là où il en restait 227 328**.
Un facteur 12,5 de données inventées, des pas de piste qui ne menaient nulle
part, et — depuis que le bras suit vraiment le transfert — un bras visiblement
collé au moyeu.

### Les décisions

- **Un disque au repos a deux gestes, et ils appartiennent au disque, pas au
  scénario.** Ils sont décrits par un `IdleBehavior` passé au simulateur, et non
  par des requêtes : personne ne demande à un bras de se parquer.
- **Le bras se parque une seconde après la dernière requête.** Ce n'est pas la
  temporisation de veille d'un vrai disque, qui se compte en minutes — c'est la
  durée qui tient dans la queue d'un scénario. Ce qu'on veut entendre, c'est
  qu'une passe se referme sur un dernier mouvement plutôt que sur un blanc. Et
  c'est la symétrie exacte du « clac » d'ouverture : la même course, dans
  l'autre sens.
- **Le parcage n'entre pas dans les compteurs.** `stats` décrit ce qu'on a
  demandé au disque ; l'y compter décalerait le seek moyen d'une passe sans
  qu'aucun accès ait bougé, et rendrait incomparables les chiffres publiés au
  chantier 6.
- **Les têtes sont parquées avant que le moteur soit coupé**, même si le délai
  d'inactivité n'est pas écoulé : sans couple, plus de coussin d'air. C'est la
  coupure qui déclenche alors le voyage.
- **La descente du plateau est la même loi que la montée**, sous forme fermée
  comme elle : un plateau lancé accomplit encore `v·τ` tours après la coupure.
  La traîne est donc **bornée et calculable**, et `revolutions(at:)` reste une
  fonction pure du temps — un saut dans la chronologie retombe sur la même image.
- **`WorkloadPhase.spin` redevient la source de la chronologie du moteur.** Un
  `SpinSchedule` la tire des phases ; les constantes qui vivaient dans
  `Scenario` (`spinUpAt: 0.35`, `duration - 0.6`) deviennent un délai de
  commande et une marge d'établissement, et redonnent **exactement** les mêmes
  valeurs.
- **Le scénario livré gagne une phase d'extinction.** C'est le seul endroit où
  couper le moteur est vrai : une passe de défragmentation et un démarrage
  laissent tous deux la machine allumée. Ces deux-là ne reçoivent donc qu'un
  parcage.
- **Une requête qui déborde du disque est tronquée**, parce que c'est ce qu'un
  disque répond. Les octets comptés sont ceux réellement transférés.

### Ce qui valide

Sept tests dans `IdleTests`, dont les trois qui comptent : le parcage laisse
`stats` strictement identique à une passe sans lui ; les tours accomplis restent
monotones sur quarante secondes de descente et la traîne tombe sur `v·τ` à
0,5 tour près ; et la troncature est discriminante — remise à `min(…)`, le test
échoue sur les 2,84 Mo inventés.

Non-régression, au rendu hors-ligne :

| | avant | après |
|---|---|---|
| passe livrée | 204,7 s · 12 036 requêtes · 9 125 seeks (moy. 130) · 2 718 repères | **identique**, 2 719 repères |
| `boot:dev-1996` | 57,5 s · 439 seeks (moy. 262) | **identique** |
| `boot:famille-2007` | 38,9 s · 684 seeks (moy. 32 693) | **identique** |
| démarrage livré | 60,0 s · 143 repères | 65,0 s · 145 repères |

Les repères ajoutés sont exactement ceux attendus : un parcage partout, plus un
arrêt moteur pour le seul scénario qui s'éteint. Les cinq secondes du démarrage
livré sont la phase d'extinction, et rien d'autre : requêtes, seeks et seek
moyen sont inchangés.

**L'extinction s'entend** : −40,6 dBFS RMS, crête 0,078. Soit 4,7 dB sous le
POST BIOS (−35,9), pour une crête équivalente (0,074) — la crête est le seek de
parcage, le fond est un plateau qui s'éteint là où l'autre monte.

### Laissé ouvert

- **Le re-parcage ne joue qu'en fin de trace.** Un trou d'inactivité *au milieu*
  d'un scénario ne le déclenche pas. Aucune passe n'en a — une défragmentation
  est en boucle fermée, et les `thinkTime` d'un démarrage sont courts — mais
  c'est bien une limite du modèle et non une propriété du disque.
- **L'extinction ne modélise que la mécanique.** Une vraie fermeture de session
  écrit : ruches du registre, cache, fichier d'échange. Ici la phase est
  `.idle`, donc silencieuse hormis le parcage et le moteur. Y poser des
  écritures demanderait de savoir lesquelles, et c'est le même manque que les
  accès courts du chantier 6.
- **La troncature n'a rien changé aux vingt profils**, et c'est normal : aucune
  partition ne déborde du disque qui la porte. C'est une garde, à compter comme
  telle — elle vaut pour ce qu'elle interdit, pas pour un effet mesuré.
- **La constante de temps de la descente est celle de la montée.** Un vrai
  plateau s'arrête plus lentement qu'il ne démarre — il n'y a que les frottements
  pour le freiner, là où le moteur pousse. Le modèle ne le distingue pas, faute
  d'un chiffre à citer.
