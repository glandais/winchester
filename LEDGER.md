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

### Les autres modes de JkDefrag

**Fait** · branche `chantier-2`

#### Le problème

Seul le mode par défaut était transposé (`-a 3`, le « mode 2 » interne). La ligne
de commande en propose d'autres, aiguillés par `DefragOnePath`
(`JkDefragLib.cpp:5412-5459`), et chacun est **une seule routine**, sans
`Defragment` devant :

| option | routine | ce qu'elle fait |
|---|---|---|
| `-a 5` | `ForcedFill` | chaque trou, en montant, rempli par la fin du fragment le plus haut |
| `-a 6` | `OptimizeUp` | chaque trou, du fond vers le début, rempli par des fichiers pris dessous |
| `-a 7` à `-a 11` | `OptimizeSort` | chaque zone reconstruite dans l'ordre du nom, de la taille, du dernier accès, de la dernière modification ou de la création |

`OptimizeSort` est le seul qui évacue, par `Vacate`. Le journal disait que
`ForcedFill` et `OptimizeUp` évacuaient aussi : c'était faux, eux ne posent
jamais que dans un trou.

`-a 2` (défragmenter seul) n'a pas été ajouté. `-a 12`, qui déplacerait la MFT,
est commenté dans le source.

#### Les décisions

- **Une stratégie par mode**, sous un identifiant à elle
  (`jkDefragForcedFill`, `jkDefragMoveUp`, `jkDefragSortName`, `…Size`,
  `…Access`, `…Change`, `…Creation`). `JKDefragStrategy` prend un `mode`, et le
  mode 2 garde `jkDefrag`. Les nouvelles routines vivent dans
  `JKDefragFullOptimize.swift`.
- **La transposition reste littérale.** Trois défauts de l'original fixent
  l'ordre des déplacements, et sont gardés :
  - avec `Direction = 0`, `FindHighestItem` parcourt le disque **depuis le
    début** : `OptimizeUp` monte le fichier le plus **bas** qui tient, pas le
    plus haut ;
  - `FindBestItem` en montant s'arrête au premier fichier *au-delà* de la fin
    du trou (`ItemLcn > ClusterEnd`) : celui qui commence pile à sa fin reste
    candidat, et s'il est retenu, il descend ;
  - le dernier accès est trié du plus récent au plus ancien, alors que le
    commentaire de `CompareItems` annonce l'inverse. Le code fait foi.

  S'y ajoutent les constantes de `OptimizeSort` : un déplacement partiel
  arrondi au multiple de 8 (« il semble qu'un déplacement partiel ne réussisse
  que si… »), 16 clusters de marge avant d'appeler `Vacate`, `Vacate` qui libère
  un demi-pour-cent du volume en plus. Un fichier est « déjà en place » dès que
  son **premier** fragment est au curseur, sans regarder la suite.
- **Le dernier accès est la dernière écriture.** Le catalogue ne date pas les
  lectures, et une écriture est un accès : c'est une borne basse, pas une
  mesure. La dernière modification est la même date, ce qui vaut sur FAT
  (`DIR_WrtDate`) comme sur NTFS (`MftChangeTime` change à chaque écriture). Les
  dates sont au **jour** près, là où l'original les a à la centaine de
  nanosecondes : à jour égal, c'est le chemin qui départage. `DefragFile` porte
  désormais la taille logique et les deux jours.
- **L'ordre d'un tri est calculé une fois.** L'original cherche le suivant en
  reparcourant tout l'arbre : le plus petit de ceux qui sont plus grands que le
  précédent. C'est le même ordre tant que `CompareItems` départage avant le LCN,
  qui bouge. Sur un vrai volume, un chemin est unique et c'est toujours le cas.
  **Pas dans la galerie** : le générateur réutilise des noms
  (`\projets\src\module.c` existe 6 812 fois sur `dev-2003`, quatorze volumes
  sur vingt ont des doublons). La taille et les dates les départagent presque
  toujours. Restent **dix fichiers** sur toute la galerie, sur quatre volumes
  `dev-`, où tout coïncide jusqu'au LCN : ils sont pris dans l'ordre des LCN de
  départ, là où l'original lirait ceux du moment.
  *(Chantier 10 : le générateur ne fait plus coexister deux chemins
  identiques, la réserve est levée.)*
- **Deux primitives nouvelles.** `ClusterBitmap.previousFreeRun(before:)` descend
  l'index des trous dans l'autre sens : `OptimizeUp` et `Vacate` cherchent le
  **dernier** trou sous une borne, qu'il fallait sinon énumérer depuis le début
  du volume. `ExtentIndex` rend le fragment qui commence le plus bas au-dessus
  d'un cluster, ou le plus haut en dessous : c'est la question que `Vacate` et
  `ForcedFill` posent en reparcourant tous les fichiers.

#### Un déplacement qui coûtait le nombre de morceaux du fichier

Premier balayage : 157 s de calcul pour un tri de `famille-2007`, 12 s pour
`famille-2003`. Un échantillonnage donne 45 % du temps dans
`ExtentIndex.remove`. `Vacate` évacue **un fragment à la fois**, et chaque
déplacement retirait puis réinsérait tous les extents du fichier : un fichier en
3 439 morceaux coûte un travail quadratique.

Un premier essai par ensembles d'extents n'a rien gagné (13 s), le temps passant
dans le hachage. Ce qui marche : un déplacement ne change qu'une plage de VCN,
donc on compare le début et la fin des deux listes et on ne touche la bitmap et
l'index que pour le milieu. **13 s → 1,3 s** sur `famille-2003`, 157 s → 7 s sur
`famille-2007`, génération comprise.

`relocate` n'est pas remplacé : les extents inchangés y changent de rang dans
les listes de l'index, `occupants` rend ses fichiers dans cet ordre, et
Windows 95 évacue dans cet ordre-là. La variante `relocateChanges` ne sert qu'à
JkDefrag, qui ne lit de l'index que des minimums et des maximums.

#### Ce qui valide

- **Le mode 2 est identique à la requête près** sur les vingt volumes, avant et
  après la refonte, et de nouveau après l'optimisation.
- **Le balayage des sept modes redonne les mêmes 140 bilans** avant et après
  l'optimisation.
- Sur les 140 passes : aucun déplacement refusé, aucune recherche de
  combinaison à court de visites (la plus longue en fait 134 296), et la garde
  anti-ver de `Vacate` **ne s'est jamais déclenchée**.
- Dix tests : chaque critère de tri sur un volume fait à la main, dont
  l'insensibilité à la casse et le départage par le chemin ; un fichier coupé
  par un immobile, posé en morceaux multiples de 8 ; le comblement forcé qui
  tasse contre le début ; `OptimizeUp` qui monte d'abord le plus bas ; la
  conservation des clusters pour les sept modes ; aucune écriture sur la MFT,
  désormais vérifiée pour les onze stratégies. La recherche descendante est
  confrontée au balayage naïf du test de l'index des trous. 221 tests.

#### Effets mesurés

Le tri par nom, face au mode 2 :

| scénario | plein | mode 2 | tri par nom | évacuations | Go déplacés | morceaux restants, mode 2 → nom |
|---|---:|---:|---:|---:|---:|---:|
| `dev-1996` | 87 % | 5 min 03 | 17 min 45 | 1 593 | 1,4 | 330 → 326 |
| `secretaire-1999` | 87 % | 10 min 19 | 30 min 43 | 8 415 | 6,4 | 1 032 → 14 |
| `dev-1999` | 93 % | 17 min 40 | 41 min 58 | 18 984 | 5,2 | 658 → 6 401 |
| `famille-1999` | 97 % | 12 min 09 | 51 min 46 | 22 911 | 8,7 | 2 707 → 4 776 |
| `secretaire-2003` | 94 % | 21 min 25 | 22 min 09 | 12 768 | 9,7 | 5 118 → 22 328 |
| `famille-2003` | 93 % | 28 min 24 | 1 h 30 | 46 578 | 45,1 | 1 786 → 8 964 |
| `dev-2007` | 86 % | 1 h 54 | 6 h 03 | 81 571 | 346,2 | 0 → 10 |
| `famille-2007` | 93 % | 2 h 02 | 7 h 21 | 156 563 | 447,7 | 1 911 → 15 235 |
| `gamer-2007` | 90 % | 1 h 15 | 4 h 49 | 82 013 | 328,6 | 1 437 → 30 095 |

Un tri déplace **plus que le volume** : 448 Go sur les 320 de `famille-2007`,
parce que ce que `Vacate` évacue redescend quand vient son tour. Et il ne répare
pas toujours : sur un volume plein, `Vacate` ne trouve pas de quoi loger ce
qu'il évacue, le curseur tombe sur des trous trop petits, et le fichier est posé
par morceaux multiples de 8. `gamer-2007` en ressort avec 30 095 morceaux, pour
124 fichiers posés en plusieurs fois. Sur les volumes moins pleins ou plus
petits, le tri fait mieux que le mode 2 (`secretaire-1999` : 14 morceaux).

Le critère change la durée du simple au double, sans règle :

| scénario | nom | taille | accès | modification | création |
|---|---:|---:|---:|---:|---:|
| `dev-1996` | 17 min 45 | 14 min 02 | 19 min 18 | 17 min 51 | 17 min 39 |
| `secretaire-1999` | 30 min 43 | 26 min 09 | 28 min 48 | 26 min 52 | 26 min 10 |
| `dev-1999` | 41 min 58 | 41 min 12 | 55 min 20 | 38 min 42 | 38 min 51 |
| `famille-1999` | 51 min 46 | 13 min 46 | 36 min 25 | 25 min 06 | 38 min 40 |
| `secretaire-2003` | 22 min 09 | 33 min 28 | 19 min 50 | 31 min 18 | 31 min 52 |
| `famille-2003` | 1 h 30 | 1 h 39 | 1 h 21 | 1 h 32 | 1 h 31 |
| `dev-2007` | 6 h 03 | 4 h 13 | 5 h 47 | 8 h 14 | 8 h 16 |
| `famille-2007` | 7 h 21 | 4 h 52 | 7 h 18 | 7 h 33 | 7 h 43 |
| `gamer-2007` | 4 h 49 | 2 h 32 | 5 h 00 | 4 h 27 | 4 h 26 |

Modification et création donnent des passes presque identiques : dans le
catalogue, la plupart des fichiers ne sont écrits qu'une fois.

Les deux tassements sont courts, et ne réparent pas :

| scénario | fragmentés au départ | après mode 2 | comblement forcé | vers la fin | durée, forcé / fin |
|---|---:|---:|---:|---:|---:|
| `dev-1996` | 133 | 5 | 138 | 57 | 2 min 08 / 2 min 36 |
| `secretaire-1999` | 739 | 35 | 775 | 168 | 2 min 17 / 5 min 22 |
| `dev-1999` | 682 | 54 | 686 | 127 | 2 min 52 / 6 min 20 |
| `famille-1999` | 898 | 549 | 914 | 651 | 2 min 37 / 2 min 52 |
| `secretaire-2003` | 178 | 124 | 237 | 143 | 2 min 06 / 3 min 52 |
| `famille-2003` | 68 | 45 | 119 | 42 | 4 min 30 / 7 min 06 |
| `dev-2007` | 176 | 0 | 242 | 101 | 26 min 23 / 48 min 59 |
| `famille-2007` | 268 | 159 | 306 | 186 | 21 min 05 / 33 min 01 |
| `gamer-2007` | 175 | 110 | 229 | 116 | 17 min 02 / 32 min 40 |

Le comblement forcé **casse** des fichiers sur tous les volumes : il détache la
fin d'un fragment pour remplir un trou trop petit pour lui. `OptimizeUp` en
répare, par effet de bord, parce qu'il déplace des fichiers entiers. Sur les
volumes qui n'ont pas de trou (`gamer-1996`, deux clusters libres) ou dont
l'espace libre est déjà tout au fond (`secretaire-1993`), les deux s'arrêtent
après un fichier ou deux : il n'y a rien à tasser.

#### Laissé ouvert

- **Le mode 2 ne réessaie pas un trou.** En relisant `OptimizeVolume` pour
  écrire `OptimizeUp`, qui en est le miroir : après un déplacement refusé,
  l'original remet `GapEnd = GapBegin`, relit **le même trou** et essaie
  jusqu'à cinq fichiers (`Retry`). La transposition du mode 2 saute le trou au
  premier refus. `OptimizeUp` a le `Retry`, le mode 2 non. Sans effet tant
  qu'aucun refus n'a lieu dans `OptimizeVolume`, ce qui n'a pas été vérifié
  volume par volume. Le corriger changerait peut-être des bilans publiés, et ce
  n'est pas fait ici.
- **Les passes dépassent le million de requêtes** : 1 115 079 pour le tri par
  nom de `famille-2007`, plus que la passe de Windows 95 sur `dev-1999` qui
  motive le chantier 3.
- **Les doublons de noms du générateur** faussent un peu le tri par nom
  lui-même : 6 812 `module.c` sont triés par taille, pas par nom. C'est au
  générateur de nommer ses fichiers, pas à la passe de le deviner.
- **Le dernier accès n'est qu'une borne basse**, faute de lectures datées.

### Ce qui reste

- **La loi de la zone MFT n'a pas de source Microsoft.** La division par deux
  vient de descriptions tierces, et rien ne dit si la zone se reconstitue au
  montage suivant. Le modèle la suppose définitive.
- **`SlowDown`** reste un réglage de tempo historique et audible (`-s 1..5`).
  Non transposé : la vitesse par défaut n'endort rien.
- **Rien n'a été écouté.** JkDefrag, ses tris et l'ordre de passage sont mesurés
  en `PLAN_ONLY`. La signature attendue (prendre au fond, poser dans le trou en
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

**Fait** · branche `passe-au-fil-de-l-eau`

### Le problème

Tout était calculé avant que le premier son ne sorte : plan complet, requêtes,
chronologie mécanique, repères audio, séries d'affichage. Sur `dev-1999`, un
FAT32 de 6,4 Go rempli à 93 %, cela faisait **1 092 121 requêtes et 781 Mo de
pic** pour une passe de cinq heures dont on n'écoute jamais que la seconde en
cours. C'est ce pic, et non le planificateur, qui plafonnait la taille des
volumes.

La consigne de départ tranchait les trois questions que ce journal laissait
ouvertes : **on renonce à la navigation dans le temps**, seul l'état à
l'instant écouté est gardé ; **la durée n'a pas à être connue d'avance** ; et
l'historique complet, s'il sert, se reconstitue par un récepteur branché sur le
flux, pour les tests.

### Les décisions

- **Les stratégies émettent au lieu d'empiler.** Un `OperationSink` remplace les
  deux tableaux `operations` et `mutations` : sans aval il empile (c'est ce que
  lisent les tests, `plan(volume:)` n'a pas changé), avec un aval chaque
  opération part aussitôt avec ses mutations, et rien n'est retenu. Le
  changement dans les cinq stratégies est mécanique ; aucun algorithme n'a
  bougé.
- **Le planificateur n'est pas interruptible, et c'est assumé.** Le rendre
  annulable demandait de faire remonter `throws` à travers toute la
  transposition de JkDefrag. Mesuré, le pire planificateur de la galerie
  calcule en sept secondes (tri par nom de `famille-2007`, simulation
  comprise). Une passe abandonnée cesse donc de simuler et finit son calcul à
  vide.
- **La mécanique devient pas à pas.** `DiskMechanics` sert une requête à la fois
  : elle était déjà causale, il suffisait de sortir son état de la boucle.
  `DiskSimulator.run` n'est plus qu'une boucle dessus.
- **Les repères sont décidés au fil des événements, à l'identique.** Un train de
  seeks se referme au plus tard une seconde après son début, et un
  micro-transitoire ne dépend que des trains commencés avant lui. `CueStream`
  retient le train ouvert et les tics tombés dedans, relâche le reste sous une
  garde (`watermark`) et rend **exactement** la liste du calcul d'un bloc, dans
  le même ordre. Le fichier a quitté `Sources/Audio` pour `Sources/Model`, où il
  se teste ; le type des tics (`HeadTick`) l'a suivi.
- **Un producteur tenu en laisse, pas une file.** `PassSession` fait tourner
  planificateur, mécanique et repères sur un `Thread`, et le fil s'endort dès
  qu'il a **huit secondes** d'avance sur l'écoute. C'est un fil et non une
  tâche parce qu'il *bloque*. L'avance n'est pas là pour la mémoire, mais pour
  absorber un planificateur qui calcule longtemps sans rien émettre. Si
  l'audio rattrape malgré tout la garde des repères, le moteur suspend la
  lecture plutôt que de jouer un trou.
- **L'écoute ne garde que des fenêtres.** `LivePass` oublie ce qu'aucune image ne
  montrera plus : 2,5 s d'échantillons pour la traînée du plateau, 1 s d'accès
  pour la carte, 60 s de tranches pour le bandeau. La carte applique ses
  mutations à leur date puis les jette, et ne rembobine plus. Les compteurs
  affichés sont des cumuls jusqu'à l'instant écouté.
- **Ce qui disparaît de l'écran**, faute de passé ou d'avenir connus : la tête
  de lecture et le saut de cinq secondes (le bouton de retour relance la
  passe), le total « Mo déplacés sur X », l'état d'arrivée et le commentaire de
  la stratégie, ainsi que le temps disque d'un démarrage, qui n'apparaissent
  qu'une fois la passe entendue jusqu'au bout. La barre de progression affiche
  l'avancement **annoncé par l'outil** : un rang dans le parcours pour Windows
  95 et XP, une position sur le disque pour JkDefrag, un rang par tour pour
  UltraDefrag.
- **Pause par `stop`, pas par `pause`.** Le moteur arrête désormais le player
  et reprogramme à la reprise les transitoires déjà retirés du flux. Avec
  `pause`, l'horloge du player reprend là où elle s'était arrêtée alors que
  `timelineOffset` avait déjà avancé : un saut dans le temps à chaque reprise.
  Ce saut est déduit de la lecture du code, il n'a pas été observé sur
  l'ancienne version.
- **Le rendu hors-ligne passe au flux, au bit près.** Il mixe à mesure, écrit
  le définitif dans un fichier brut, puis le convertit en WAV. Il garde l'ordre
  des additions du rendu d'un bloc : toute la rotation d'un échantillon avant
  ses transitoires, et les transitoires dans l'ordre des repères.

### Ce qui valide

**Non-régression, 48 exécutions du rendu hors-ligne** comparées à `develop` :
les 20 démarrages de la galerie, les deux scénarios livrés, les passes
complètes de `dev-1993`, `gamer-1993` et `dev-1996`, les 20 bilans `PLAN_ONLY`
et trois stratégies forcées sur `famille-2007`. **Tous les bilans sont
identiques et les 25 WAV ont la même empreinte MD5.** Seule la ligne
`événements` change : elle affichait 0, parce que la trace était résumée avant
impression, et donne maintenant le vrai compte.

**Six tests dans `StreamingTests`** comparent le flux à un calcul d'un bloc
refait à l'ancienne, avec pour oracle l'ancien constructeur de repères recopié
tel quel :

- les repères de quatre stratégies et du démarrage livré ;
- une trace synthétique de 20 000 événements coupée par la durée maximale ;
- les échantillons, mutations, accès et tranches d'activité ;
- une écoute image par image qui ne garde jamais plus d'un dixième des
  échantillons de la passe ;
- une session qui respecte son horizon et se libère à l'abandon.

Ces tests ont été éprouvés par deux mutations volontaires : allonger la durée
maximale d'un train, et décider les tics sans attendre le train. Chacune fait
échouer trois tests.

**Mémoire, pic RSS au rendu hors-ligne :**

| | avant | après |
|---|---|---|
| passe livrée, son compris | 97 Mo | **38 Mo** |
| `dev-1993`, son compris | 763 Mo | **54 Mo** |
| `dev-1996`, son compris (36 min) | 1 019 Mo | **154 Mo** |
| `dev-1999`, `PLAN_ONLY` | 781 Mo | **220 Mo** |
| `famille-1999`, `PLAN_ONLY` | 796 Mo | **70 Mo** |
| `famille-2007`, tri par nom | 892 Mo | **273 Mo** |
| `dev-2007`, `PLAN_ONLY` | 957 Mo | 875 Mo |

Ce qui reste est **la génération du disque**, pas la passe : le démarrage de
`dev-1999` pèse les mêmes 220 Mo, celui de `dev-2007` 719 Mo.

**À l'écran**, sur le simulateur démarré (voir plus bas) : le démarrage livré
s'arrête seul à 1:05.0 avec ses 4 716 requêtes, bras parqué. La passe livrée
s'arrête à 3:24.7. Une pause fige le compteur de seeks et la reprise ne saute
pas. Carte, plein écran, bandeau défilant et plateau suivent l'écoute. La passe
de cinq heures de `dev-1999` tient à **95 Mo** en lecture, disque généré
compris.

### Laissé ouvert

- **Le calcul coûte 20 % de plus** : 1,04 s au lieu de 0,86 s pour le bilan de
  `dev-1999` au repos, ce qui fait des centaines de milliers de requêtes par
  seconde. C'est le prix des paquets et des tranches. Rien n'a été optimisé.
- **L'attente du producteur n'a jamais été déclenchée.** Elle est écrite, mais
  aucune passe de la galerie ne prend huit secondes de retard.
- **La barre de progression ne suit pas le temps** : à 40 s d'une passe de
  205 s, Windows 95 annonce 49 %, parce que les premiers fichiers du parcours
  sont souvent déjà en place. C'est ce que l'outil affichait, et c'est trompeur.
- **Vu sur l'iPhone SE (3ᵉ génération) démarré par une autre session**, pas sur
  le 17 Pro Max du projet, et toujours pas en paysage. L'haptique n'a pas été
  éprouvée : le simulateur n'en a pas.
- **Le plein écran consomme 120 % de CPU au simulateur**, en redessinant la carte
  deux fois (plein écran et panneau dessous). C'était déjà le cas avant ce
  chantier, mais cela rend `axe describe-ui` inutilisable pendant la lecture.
- **Le témoin d'un démarrage reste calculé d'un bloc** avant l'écoute : quelques
  milliers de requêtes, rien à gagner.
- **La session sans fin devient possible** (laisser le disque travailler en fond,
  cf. chantier 6), mais elle n'est pas faite.

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

---

## Chantier 8 — la carte dessinée une fois

**Fait** · branche `carte-dessinee-une-fois`

### Le problème

Le chantier 3 laissait ouvert un plein écran qui coûtait **plus cher** que
l'écran qu'il recouvre, et rendait `axe describe-ui` inutilisable pendant la
lecture. Mesuré sur la passe livrée, en build Debug, temps CPU cumulé sur 20 s
de lecture, deux essais :

| | écran normal | plein écran | `axe describe-ui` en plein écran |
|---|---:|---:|---:|
| `develop` | 65–70 % | 105–110 % | **64 s** |

Un échantillonnage du fil principal (`sample`, 5 s) donne deux causes, de poids
comparable :

- **l'écran du dessous suivait toujours l'horloge.** `SimulatorScreen` observait
  le moteur, et `@ObservedObject` ne se désabonne pas quand une vue est
  recouverte : son corps était recalculé à chaque image, avec sa carte, son
  plateau et son bandeau, que personne ne voyait. Sa carte avait en plus la
  grille fine du plein écran, que le modèle partage. 469 ms de corps sur 5 s,
  dont 443 dans `clusterShades(at:)` ;
- **la carte refaisait tout son calcul à chaque image.** `shades(at:)`
  reparcourait tous les blocs et rendait un tableau neuf, que SwiftUI ne pouvait
  pas reconnaître comme identique : le `CGImage` était refabriqué soixante fois
  par seconde, deux fois, pour une carte qui ne change qu'aux mutations.

### Les décisions

- **Un relais qu'on peut couper, plutôt qu'une réorganisation de l'écran.**
  `ClockRelay` retransmet à l'écran les changements du moteur, et se tait tant
  que le plein écran est ouvert. En se rouvrant, il envoie un seul changement,
  et l'écran rattrape d'un coup ce qu'il a manqué. L'autre solution, sortir
  chaque morceau lié à l'horloge dans sa propre vue, laissait ces morceaux
  abonnés sous le plein écran : elle aurait déplacé le coût, pas supprimé. Le
  prix : les réglages du mixage ne sont plus des `$engine.…` mais des `Binding`
  fabriqués, puisque le relais n'expose pas l'objet observé.
- **La réduction ne refait que les blocs touchés.** Le rejeu note, dans `add`,
  chaque bloc dont le décompte bouge, et `shades(at:)` ne recalcule que ceux-là.
  C'est une liste et non un intervalle : un déplacement écrit au début du
  volume et évacue vers la fin, et l'intervalle qui couvrirait les deux serait
  la carte entière. Un simple cache invalidé à chaque mutation ne suffisait pas.
  Mesuré après cette première étape, il ramenait le plein écran à 48 %, mais le
  profil montrait encore la réduction complète en tête : sur la passe livrée,
  une mutation tombe presque à chaque image.
- **Rien n'a changé, même tableau.** Quand aucune mutation n'est tombée,
  `shades(at:)` rend le tableau précédent, qui partage son stockage : la
  comparaison de SwiftUI s'arrête à l'identité du stockage, et `ClusterMapImage`
  n'est pas recalculée.

### Ce qui valide

| | écran normal | plein écran | `axe describe-ui` en plein écran |
|---|---:|---:|---:|
| `develop` | 65–70 % | 105–110 % | 64 s |
| branche | **60 %** | **35–40 %** | **1 s** |

Le plein écran coûte désormais moins que l'écran normal, ce qu'on attend d'une
vue qui ne montre qu'une carte et une barre. La mesure lit le temps CPU de `ps`
à la seconde près : ±5 %.

Un test, `unchangedFramesReuseTheReduction`, avance la passe image par image.
Une image sur deux, il compare la carte à celle d'un player neuf, qui ne peut
rien avoir retenu. Il vérifie aussi que le même stockage revient quand rien n'a
bougé, et que le cache a servi. **Il a été éprouvé par une mutation
volontaire** : oublier un seul bloc touché par image le fait échouer, ainsi que
des tests existants de la carte (un seul au premier essai, quatre au second). À une comparaison toutes les trente
images, il ne la voyait pas : le bloc oublié était souvent retouché avant d'être
comparé.

Les 229 tests passent. À l'écran, la carte en plein écran avance, la rémanence
suit, et en sortant, l'écran normal reprend la lecture là où elle en est.

### Laissé ouvert

- **Mesuré en Debug, sur le simulateur de l'iPhone SE (3ᵉ génération)** démarré
  par une autre session, comme au chantier 3. Pas en Release, pas sur l'appareil,
  pas en paysage. En Debug, la boucle de réduction est très pénalisée par les
  itérateurs génériques non spécialisés : l'écart réel sur l'appareil est
  probablement plus faible.
- **L'écran normal reste à 60 %.** La carte n'y est plus la cause principale :
  plateau, bandeau et compteurs sont recalculés en entier à chaque image. Ce
  chantier ne l'a pas profilé plus loin.
- **La galerie** (`LibraryFullScreenMap`) n'était pas concernée : son volume ne
  bouge pas et ne suit aucune horloge. Elle n'a pas été mesurée.

---

## Chantier 9 — ce qu'`UltraDefragStrategy` ne reproduit pas

**Relevé**, puis **corrigé** · branche `ultradefrag-fidele` (voir « La correction »)

### Le problème

Une relecture de `UltraDefragStrategy` face aux sources d'UltraDefrag 7.1.1
(`defrag.c`, `move.c`, `search.c`, `zenwinx/ftw*.c`) confirme que
`defrag_routine` et `defrag_sequence` sont transposés presque à l'instruction
près : ordre de passage, deux séquences, plafond du plus grand trou, garde-fou
`n < 2`, annexion du voisin, avancée de `min_vcn`, grain de
`adjust_move_at_once_parameter`. Deux écarts de **comportement** ressortent
pourtant. Aucun n'est mentionné dans l'en-tête de la stratégie, qui ne déclare
que le second essai de `defragment()` et les répertoires FAT.

#### 1. L'espace libéré sur NTFS est réutilisé dans le même tour

Dans `move_file` (`move.c:719-727`), les clusters que le déplacement libère ne
reviennent dans `jp->free_regions` **que hors NTFS** :

> on NTFS we cannot use the released space until release_temp_space_regions
> call because Windows marks clusters as temporarily allocated immediately
> after the move

`release_temp_space_regions` n'est appelé qu'en tête de chaque
`defrag_routine`. Sur NTFS, un trou libéré pendant un tour n'est donc visible
qu'au tour suivant, pour `find_first_free_region` comme pour
`find_largest_free_region`.

`DefragVolume.relocate` libère la source dans la bitmap immédiatement
(`DefragVolume.swift:249`). Dans un même tour, `firstGap` et `largestGap`
voient des trous que l'outil réel ne voit pas, en particulier ceux que le
fichier vient lui-même de quitter pendant sa défragmentation partielle. Effets
attendus, non mesurés :

- des destinations **plus basses** sur le plateau, donc d'autres trajets de tête
  et un autre son ;
- un plafond « plus grand trou » plus haut, donc des suites de petits fragments
  plus longues ;
- probablement moins de tours avant convergence.

Les huit volumes où cette passe a été mesurée sont NTFS : l'écart pèse sur tous
les chiffres de la section « Recoller au lieu de déplacer ».

#### 2. Les fragments sont comptés dans l'ordre du plateau, pas du fichier

UltraDefrag compte `disp.fragments` **dans l'ordre des VCN** (`ftw.c:225`,
`ftw_ntfs.c:1098`) : un bloc ouvre un fragment si son LCN ne prolonge pas le
bloc *précédent du fichier*. `build_fragments_list` suit la même règle, et
`IsFragmented` de JKDefrag aussi (`JkDefragLib.cpp:1348`, `NextLcn`).

`DefragFile.fragmentCount` (`DefragVolume.swift:44`) **trie d'abord les extents
par LCN** avant de chercher les ruptures. Un fichier dont deux extents se
touchent sur le disque mais dans l'ordre inverse du fichier — B posé juste
avant A — y compte pour **un** morceau, contre deux dans les deux outils. La
tête, qui lit le fichier dans l'ordre, fait pourtant un seek arrière.

Conséquences pour UltraDefrag : un tel fichier sort de `canDefragment`
(`isContiguous`) et change de rang dans le tri par nombre de fragments. Le
commentaire de `fragments(of:)`, qui dit suivre « la même règle que
`DefragFile.fragmentCount` », n'est exact que pour des extents rangés par LCN
croissant. L'écart dépasse la stratégie : `fragmentCount` sert aussi au tri de
`WindowsXPStrategy` (`WindowsXPStrategy.swift:242`) et à
`VolumeStats.fragments` (`DefragVolume.swift:299`), donc à tous les tableaux de
morceaux restants du journal.

### Laissé ouvert au relevé

- **Rien n'est mesuré.** Ni la fréquence, dans la galerie, des fichiers aux
  extents adjacents mais inversés, ni l'effet du report de l'espace libéré sur
  les passes NTFS. Les deux sont à chiffrer avant de corriger.
- **Corriger le point 1** voudrait une bitmap « libérée ce tour-ci » propre à
  NTFS, relâchée en tête de `routine`. La question est de savoir si elle reste
  locale à `UltraDefragStrategy` ou si `WindowsXPStrategy`, qui appelle le même
  `FSCTL_MOVE_FILE`, subit la même contrainte.
- **Corriger le point 2** change les compteurs de toutes les stratégies. Il
  faudra remesurer les tableaux existants, pas seulement ceux d'UltraDefrag.
- Écarts mineurs relevés au passage, sans effet sur les passes livrées :
  départage des chemins sensible à la casse (`winx_wcsicmp` ne l'est pas), zone
  MFT exclue même au-delà de XP (`move.c:44` ne la retire qu'avant XP), seconde
  séquence toujours jouée même quand le seuil est personnalisé, et doc de
  `eliminateLittleFragments` trop stricte sur `n < 2` (un fragment isolé plus
  l'annexe du voisin donne `n = 2` et se déplace).

### La correction

Les deux écarts ont été chiffrés **avant** d'être corrigés, puis corrigés l'un
après l'autre, chacun mesuré seul : trois binaires de rendu (`develop`, point 1,
points 1 et 2), les vingt volumes, `PLAN_ONLY`, le même jour. XP et
Windows 95 sur les volumes de leur format, UltraDefrag sur les vingt, JkDefrag
dans ses modes 2, 5, 6 et le tri par nom.

#### Le point 2 pèse peu au départ, et plus à l'arrivée

Sur les volumes **livrés**, les deux règles de comptage ne divergent presque
jamais. Un outil d'audit jetable a comparé, fichier par fichier, le compte par
LCN trié et le compte dans l'ordre du fichier :

| | fichiers aux extents non croissants | comptes différents | morceaux en plus |
|---|---:|---:|---:|
| FAT, douze volumes | 92 | 1 | 1 (`famille-1996`) |
| NTFS, huit volumes | 11 | 5 | 44, dont 23 sur `famille-2007` |

Aucun fichier ne change de statut : aucun contigu ne devient fragmenté. Les
allocateurs du générateur ne posent presque jamais B juste avant A.

Les **passes**, elles, le font. Ce qu'elles recopient par tranches atterrit
dans le premier trou venu, parfois juste avant la tranche suivante du même
fichier. L'ancien compteur y voyait un seul morceau. Les requêtes émises ne
changent pour ainsi dire pas, mais les morceaux restants, si :

| passe | morceaux restants, LCN trié → ordre du fichier |
|---|---:|
| JkDefrag, `famille-2003` | 1 786 → 2 128 (+19 %) |
| JkDefrag, `famille-2007` | 1 911 → 2 191 (+15 %) |
| JkDefrag tri par nom, `famille-2007` | 15 235 → 17 165 (+13 %) |
| JkDefrag, `secretaire-2003` | 5 118 → 5 307 |
| JkDefrag, `dev-1999` | 658 → 707 |
| UltraDefrag, `famille-2007` | 1 357 → 1 503 (+11 %) |
| UltraDefrag, `gamer-2007` | 524 → 561 |
| XP et Windows 95, partout | au plus un morceau d'écart |

Les tableaux du journal antérieurs à ce chapitre **sous-estimaient donc les
morceaux restants** des passes qui recopient par tranches, de 10 à 20 % sur les
volumes NTFS pleins. Ils ne sont pas réécrits : ils restent justes pour le
compteur de leur époque. Le README, lui, donne les chiffres d'aujourd'hui.

Côté comportement, un seul plan change en dehors d'UltraDefrag :
JkDefrag mode 2 sur `famille-1996`, qui déplace un fichier de plus (12 921
requêtes au lieu de 12 924). Un fichier qui passait pour contigu y est reconnu
cassé.

#### Le point 1 change le son d'UltraDefrag sur NTFS

| scénario | seek moyen, cyl. | durée | requêtes | morceaux restants |
|---|---:|---:|---:|---:|
| `secretaire-2003` | 31 865 → 38 713 | 370 s → 384 s | 25 975 → 25 153 | 13 821 → 14 333 |
| `famille-2003` | 35 547 → 39 044 | 969 s → 1 084 s | 61 912 → 66 598 | 17 131 → 14 942 |
| `dev-2003` | 36 542 → 42 266 | 387 s → 408 s | 24 989 → 24 987 | 13 → 11 |
| `secretaire-2007` | 39 497 → 40 842 | 579 s → 593 s | 21 684 → 21 684 | 0 → 0 |
| `famille-2007` | 46 815 → 52 535 | 4 944 s → 5 204 s | 329 977 → 331 355 | 1 350 → 1 357 |
| `gamer-2007` | 37 426 → 37 497 | 2 287 s → 2 300 s | 123 331 → 123 361 | 511 → 524 |
| `dev-2007` | 47 430 → **64 868** | 4 394 s → 4 582 s | 248 719 → 247 803 | 3 → 18 |

L'effet prévu au relevé se vérifie en partie. Les destinations sont **plus
lointaines**, et c'est le résultat net : le seek moyen monte partout, de 37 %
sur `dev-2007`. La passe dure 1 à 12 % de plus. Le reste ne suit pas de règle.
Le relevé attendait des morceaux restants en baisse (plafond du plus grand trou
plus bas), et il en reste moins sur `famille-2003` mais plus sur
`secretaire-2003` et `dev-2007`. Le nombre de requêtes bouge dans les deux sens.
C'est un effet d'attribution des trous, pas un effet de seuil.

Les douze volumes FAT et toutes les passes XP ressortent **identiques au bit
près** : la retenue ne s'applique qu'à NTFS, et seulement dans UltraDefrag.

#### Les décisions

- **La retenue reste locale à `UltraDefragStrategy`.** Ce qu'elle reproduit
  n'est pas NTFS, c'est la comptabilité de l'outil : sa propre liste
  `jp->free_regions`, qu'il ne relit qu'en tête de `defrag_routine`. JkDefrag
  fait autrement : son `FindGap` relit `FSCTL_GET_VOLUME_BITMAP` à chaque
  appel, voit ces clusters comme libres, et gère l'échec de `FSCTL_MOVE_FILE`
  a posteriori (`MoveItem4`, `JkDefragLib.cpp:2350`). Le code de l'outil de XP
  n'est pas public. Imposer la contrainte à ces deux-là serait modéliser le
  point de contrôle de NTFS, dont le rythme n'est écrit nulle part.
- **La retenue vit dans la bitmap.** `DefragVolume.relocateHoldingReleased`
  laisse occupés les clusters que le fichier quitte et les note dans
  `heldClusters`. `releaseHeldClusters` les rend en tête de chaque tour, puis
  une dernière fois avant le bilan. `firstGap` et `largestGap` n'ont pas bougé :
  ils voient des clusters occupés, comme `find_first_free_region` voit une
  région absente. La retenue ne prend que les clusters réellement libérés, pas
  ce qui reste en place d'un déplacement partiel.
- **`fragmentCount` suit l'ordre de la liste d'extents**, sans tri. Le test qui
  affirmait l'inverse (« l'ordre de la liste ne doit rien changer ») a été
  retourné : deux extents jointifs sur le plateau mais inversés dans le fichier
  font deux morceaux. Le commentaire de `fragments(of:)` dit désormais vrai :
  son compte égale `fragmentCount` pour toute liste.

#### Ce qui valide

- Un test, « Sur NTFS, l'espace libéré n'est réutilisé qu'au tour suivant ».
  La même disposition est passée sur une partition NTFS et sur une FAT, et le
  second fichier n'atterrit pas au même endroit (cluster 90 contre 18). La
  variante FAT sert de témoin : le test distingue bien les deux comportements.
  Il vérifie aussi que le bilan est pris une fois tout rendu.
- Le test des extents inversés attend deux morceaux.
- Les 230 tests passent.
- Hors du champ corrigé, les WAV ne sont pas comparés, mais les bilans le sont.
  XP et Windows 95 ressortent à la requête et à la seconde près, JkDefrag aussi
  sauf sur `famille-1996`.

#### Laissé ouvert

- **Rien n'a été écouté**, comme au chantier 2 : les effets sonores sont déduits
  des seeks.
- **Les tableaux antérieurs du journal** gardent leurs anciens morceaux
  restants (voir plus haut). Seul le README est à jour.
- **Les écarts mineurs du relevé** restent tels quels : départage des chemins
  sensible à la casse, zone MFT exclue au-delà de XP, seconde séquence toujours
  jouée, et la doc de `n < 2`.
- **Le nombre de tours** de chaque séquence n'est pas compté. La retenue en
  ajoute probablement, et le bilan ne le dit pas.

---

## Chantier 10 — un chemin, un fichier

**Fait** · branche `noms-uniques`

### Le problème

Le compilateur de scénarios nomme les fichiers d'après ce qu'ils sont, sans
savoir ce qui existe encore au jour où ils sont écrits. `MODULE.C`, `BUILD.ZIP`,
`SAVE.DAT`, `EXTRAIT` ou `DL` ont un nom fixe. `M\(index).OBJ` et
`C\(index).TMP` renumérotent à partir de zéro à chaque build ou à chaque
session. FAT comme NTFS refusent pourtant deux fois le même nom dans un
répertoire, et les défragmenteurs s'appuient dessus. Le tri par nom de JkDefrag
est calculé une seule fois, ce qui suppose des chemins uniques (chantier « Les
autres modes de JkDefrag »). Windows XP et UltraDefrag départagent aussi par
chemin, et `Volume.fileID(atPath:)` rend le premier fichier trouvé.

Nombre de fichiers créés sur un chemin **déjà occupé** au moment de leur
création, en rejouant la timeline triée :

| volume | coexistences | volume | coexistences |
|---|---:|---|---:|
| `dev-1993` | 10 029 | `famille-2003` | 245 250 |
| `dev-1996` | 42 425 | `gamer-2003` | 6 |
| `dev-1999` | 127 112 | `secretaire-2003` | 64 610 |
| `dev-2003` | 350 343 | `dev-2007` | 550 466 |
| `famille-1996` | 20 627 | `famille-2007` | 327 425 |
| `famille-1999` | 75 818 | `gamer-2007` | 176 030 |
| `gamer-1999` | 38 088 | `secretaire-2007` | 129 939 |
| `secretaire-1999` | 14 091 | `poweruser-1993` | 2 638 |
| `gamer-1993`, `gamer-1996` | 1 097 chacun | | |

Dix-huit volumes sur vingt. Compter sur tout l'historique, suppressions
ignorées, donnait jusqu'à 1,3 million de doublons sur `dev-2007`. La plupart ne
sont pas des collisions : ce sont des noms repris après une suppression, ce que
fait Windows.

### Les décisions

- **Une passe unique, après le tri de la timeline**, plutôt qu'un nom corrigé à
  chacune des vingt-deux écritures du compilateur. `EventTimeline.giveUniqueNames`
  rejoue les créations et les suppressions dans l'ordre où le simulateur les
  verra. Un nom déjà porté par un fichier présent est remplacé. Un site de
  nommage ajouté plus tard sera couvert d'office.
- **Seuls les fichiers présents en même temps sont en conflit.** Un nom libéré
  est repris tel quel. Rendre les noms uniques sur tout l'historique aurait été
  plus simple, mais aurait produit des alias à six chiffres pour des fichiers qui
  ne se sont jamais croisés.
- **L'alias suit les noms courts de Windows** : `MODULE~1.C`, `EXTRAI~1`,
  radical ramené à huit caractères, extension gardée. Les requêtes du démarrage
  (`BootQuery.accepts`) et les masques de JkDefrag ne lisent que l'extension et
  le répertoire. La comparaison ignore la casse ASCII, comme `_wcsicmp`. Le
  numéro repart à un quand le nom demandé se libère.
- **Aucun tirage aléatoire n'est consommé**, et aucune génération ne trie par
  nom : la disposition sur le disque ne change pas.
- **Une empreinte FNV, calculée une fois par nom.** La première version passait
  les noms en majuscules et laissait `Set<String>` hacher : 1,05 s sur
  `dev-2007` en release, soit 2,7 millions d'événements. Hacher octet par octet
  était pire (1,6 s). Avec une empreinte insensible à la casse, calculée en un
  seul passage et seule à entrer dans le `Hasher`, la passe tombe à **0,42 s**.

### Ce qui valide

`FileNameTests` vérifie les alias, la reprise d'un nom libéré et le saut d'un
alias déjà porté. Il compile aussi les vingt scénarios et vérifie qu'aucune
création ne tombe sur un chemin occupé. Ce dernier test échoue sur `develop`
avec les nombres du tableau ci-dessus. Les 233 tests passent.

`RenderTrace`, `PLAN_ONLY`, sur `develop` puis sur la branche : onze stratégies
sur `dev-1996`, `dev-1999`, `dev-2003`, `famille-2003` et `secretaire-2003`, soit
55 bilans. **43 sont identiques à l'octet**, dont Windows 95, Windows XP,
UltraDefrag, le mode 2 de JkDefrag, `ForcedFill`, `MoveUp` et le tri par taille
partout, et tous les bilans de `famille-2003` et `secretaire-2003`. Les douze
autres sont les tris de JkDefrag par nom et par date sur les volumes `dev-`,
où le chemin départage :

| volume | tri par nom, seeks | évacuations | durée |
|---|---|---|---|
| `dev-1996` | 23 585 → 23 766 | 1 593 → 1 667 | 1 064,7 → 1 070,9 s |
| `dev-1999` | 143 128 → 142 796 | 18 984 → 18 956 | 2 518,1 → 2 515,8 s |
| `dev-2003` | 92 245 → 92 689 | 10 684 → 10 806 | 1 920,5 → 1 927,8 s |

Les tris par date ne bougent que sur les repères audio et le dixième de
seconde, sauf `dev-1999` par dernier accès (166 757 → 166 739 seeks). Aucun
écart ne dépasse 1 %.

### Laissé ouvert

- **Les autres volumes et `dev-2007` n'ont pas été rejoués.** L'invariant est
  testé sur les vingt, mais les bilans ne sont comparés que sur cinq.
- **UltraDefrag départage toujours en tenant compte de la casse**
  (chantier 9). Deux chemins qui ne diffèrent que par la casse ne peuvent plus
  coexister, mais leur ordre relatif reste celui de `<`, pas de `winx_wcsicmp`.
- **Un fichier dont la création échoue** (volume plein) garde son nom réservé
  jusqu'à sa suppression. Le simulateur ne l'insère pas, et un autre fichier
  prend un alias sans nécessité. Sans effet sur l'unicité.
- Le radical peut passer sous un caractère au-delà de `~9999999`. Aucun volume
  n'en approche.

---

## Chantier 11 — le mode 2 réessaie un trou

**Fait** · branche `mode-2-reessaie-le-trou`

### Le problème

Laissé ouvert par « Les autres modes de JkDefrag » : après un déplacement
refusé, `OptimizeVolume` (`JkDefragLib.cpp:4818`) ne saute pas le trou. Il
remet `GapEnd = GapBegin`, sort de la boucle de remplissage, et `FindGap`
retrouve **le même trou** au tour suivant. Le fichier refusé est devenu
immobile entre-temps (`MoveItem`), un autre est donc choisi. Le compteur
`Retry` borne l'obstination à cinq refus d'affilée ; il revient à zéro à chaque
déplacement réussi et à chaque trou sauté. La transposition du mode 2, elle,
sortait de la boucle au premier refus et comptait le trou comme sauté.
`OptimizeUp` avait déjà le `Retry`.

### La décision

Recopier la boucle de l'original telle quelle, comme dans `optimizeUp` :
`retry < 5` dans la condition, `end = begin` et un essai de plus sur un refus,
remise à zéro sur un succès et sur un trou sauté. Un compteur,
`Report.gapRetries`, dit combien de fois un trou a été relu.

### Ce qui valide

Le bilan du mode 2 sur les vingt profils de la galerie, avant et après, en
release (nombre de fichiers déplacés, déplacements par passe, refus, trous
visités et sautés, fichiers fragmentés à l'arrivée, nombre d'opérations, et
une empreinte de toutes les mutations du plan) : **identique sur les vingt**,
et `gapRetries` vaut 0 partout. Les 229 tests passent.

Ce n'est pas une surprise, et c'est le point à retenir : dans le modèle, un
refus **ne peut pas** survenir dans `OptimizeVolume`. `move` ne refuse qu'une
destination occupée ou dans la zone MFT ; or la destination est prise dans un
trou que `gap` vient de lire hors de la zone MFT, bornée à la taille qui reste,
et les fichiers candidats commencent tous au-dessus de ce trou. Les deux refus
observés (`famille-1996`, `secretaire-2007`) viennent d'ailleurs — `Fixup`,
dont le trou mémorisé n'est pas relu. Sous Windows, un refus pouvait venir du
système de fichiers lui-même (fichier ouvert, verrouillé) ; ce modèle n'en
simule aucun.

La correction est donc une **fidélité à l'original** sans effet sur les bilans
publiés : l'inquiétude du chantier précédent (« changerait peut-être des bilans
publiés ») est levée.

### Laissé ouvert

- **Pas de test qui exerce la relecture** : aucun volume ne peut provoquer un
  refus dans cette passe sans injecter une panne dans `move`, et l'injection
  n'a pas été ajoutée pour un chemin que le modèle ne visite pas.
- `gapsVisited` compterait deux fois un trou relu, comme l'original l'annonçait
  deux fois à l'écran. Sans objet tant que `gapRetries` reste nul.

---

## Chantier 12 — le calcul au fil de l'eau, allégé

**Fait** · branche `fil-de-l-eau-plus-leger`

### Le problème

Le chantier 3 laissait ouvert un calcul **plus cher de 20 %** : 1,04 s au lieu
de 0,86 s pour le bilan de `dev-1999`, sans que rien n'ait été optimisé.
Remesuré ici (`PLAN_ONLY=1`, temps CPU utilisateur + système, médiane de cinq
essais) : 0,83 s avant le flux (`13203f0`), 1,02 s sur `develop`.

Un profil (`xctrace`, Time Profiler) des deux versions donne deux choses
distinctes :

- **l'écart lui-même venait des vérifications d'exclusivité.** `PassPipeline`
  tenait son état dans des propriétés de classe : la mécanique, le flux des
  repères, le paquet en cours, les tranches ouvertes. Chaque accès en écriture,
  et chaque `inout` comme `mechanics.serve(request, events: &events)`, passait
  par `swift_beginAccess` à l'exécution : une dizaine par requête, soit 15 %
  des échantillons. Le calcul d'un bloc, fait de valeurs locales, n'en payait
  aucune ;
- **le plus gros poste était plus ancien que le flux.** `DefragOperations.move`
  pesait la moitié des échantillons, dans les deux versions. Pour chaque
  tronçon déplacé, `freed` allouait trois tableaux (`filter`, `map`, le
  résultat), et parcourait deux fois tous les extents de la destination. Un
  refuge d'évacuation peut compter des centaines de morceaux, et chaque tronçon
  de l'occupant évacué le reparcourait.

### Les décisions

- **L'état de la chaîne tient dans une valeur.** Une structure privée `Chain`
  porte tout ce que `PassPipeline` modifiait, avec les méthodes qui le font
  avancer. La classe ne garde que la livraison : un seul accès par requête, et
  le paquet part après, hors de l'accès. Le rendre `@exclusivity(unchecked)`
  aurait coûté moins de lignes, mais c'est un attribut non documenté qui
  désarme une garantie au lieu de la rendre inutile.
- **La première date d'une phase n'est cherchée qu'au changement de phase.**
  Les requêtes partent dans l'ordre : la première d'une phase est aussi la plus
  précoce. Le dictionnaire `firstStarts` n'est plus consulté à chaque requête.
- **Les clusters libérés sont écrits directement dans le récepteur**, sans
  tableau intermédiaire. `OperationSink.record(contentsOf:)`, qui ne servait
  qu'à cela, disparaît.
- **La destination est triée une fois par déplacement, puis cherchée par
  dichotomie.** C'est juste parce que les extents d'un fichier ne se
  chevauchent pas : au plus un couvre le curseur, et le suivant est le premier
  qui commence après. Les extents vides sont écartés au tri, puisque l'ancien
  calcul ne pouvait pas les voir couvrir quoi que ce soit. Une destination d'un
  seul extent, le cas du fichier posé à sa place, n'est ni copiée ni triée.

### Ce qui valide

**Temps CPU**, médiane de cinq essais en `PLAN_ONLY`, génération du disque
comprise :

| | avant le flux | `develop` | exclusivité | + sans allocation | + dichotomie |
|---|---:|---:|---:|---:|---:|
| `dev-1999`, Windows 95 | 0,83 s | 1,02 s | 0,91 s | 0,65 s | **0,46 s** |
| `famille-2007`, tri par nom | 7,01 s | 7,22 s | 7,27 s | 7,06 s | **6,98 s** |
| `dev-2007` | 0,97 s | 1,01 s | 1,01 s | 0,97 s | 1,01 s |

Le calcul de `dev-1999` coûte **deux fois moins** que sur `develop`, et
45 % de moins qu'avant le flux. Sur les deux autres, c'est la génération du
disque et le planificateur de JkDefrag qui dominent : l'écart y reste dans le
bruit. Le pic mémoire n'a pas bougé (220 Mo sur `dev-1999`).

**Non-régression, 113 exécutions du rendu hors-ligne** comparées à `develop` :
les 20 bilans `PLAN_ONLY`, les onze stratégies forcées sur `famille-2007`,
`dev-1993` et `dev-2003`, les 20 démarrages rendus en WAV, les deux scénarios
livrés, les passes complètes de `dev-1993`, `gamer-1993`, `secretaire-1993` et
`dev-1996`, et quatre stratégies forcées sur `gamer-1993`. **Tous les bilans
sont identiques et les 30 WAV ont la même empreinte MD5.**

Le son et les bilans ne voient pas les mutations de la carte. Un test,
`MoveTests`, compare donc les mutations de `move` à celles de l'ancien calcul
recopié tel quel, sur 200 tirages de sources et de destinations morcelées,
dans le désordre et qui se recouvrent. **Il a été éprouvé par deux mutations
volontaires** : ne pas trier la destination (160 écarts), ignorer l'extent
suivant (122 écarts). Une troisième, `>=` au lieu de `>` pour la couverture,
ne fait pas échouer le test : elle le fait boucler sans fin.

Les 230 tests passent.

### Laissé ouvert

- **La génération du disque est désormais le premier poste** de `dev-1999` :
  environ 0,16 s sur 0,46 s au profil. Elle n'a pas été regardée.
- **Mesuré sur le rendu hors-ligne, compilé en `-O` sur le Mac**, pas dans
  l'application ni sur l'appareil. Le fil producteur fait le même calcul, mais
  personne n'a regardé son CPU au simulateur.
- **`OperationSink` paie encore ses vérifications d'exclusivité**, moins de 3 %
  des échantillons. Le même regroupement l'en débarrasserait, mais toutes les
  stratégies l'appellent, et le gain ne justifiait pas de les toucher.

---

## Intégration des chantiers 9 à 12

**Fait** · sur `develop`, par reprise des commits des quatre branches

### Ce qui se recouvrait

Les quatre branches ne modifient jamais le même fichier de code :
`ultradefrag-fidele` touche `DefragVolume` et `UltraDefragStrategy`,
`noms-uniques` `EventTimeline`, `ScenarioCompiler` et un commentaire de
`JKDefragFullOptimize`, `mode-2-reessaie-le-trou` `JKDefragStrategy`,
`fil-de-l-eau-plus-leger` `DefragStrategy`, `OperationSink` et `PassPipeline`.
`OperationSink.record(contentsOf:)`, que le dernier supprime, n'était appelé
nulle part ailleurs.

Les conflits étaient tous dans ce journal : chacune ajoutait son chapitre à la
fin, et deux branches parties d'avant le relevé d'UltraDefrag s'étaient
numérotées « chantier 9 ». Ordre retenu : la correction d'UltraDefrag complète
le chapitre 9, puis viennent les noms uniques (10, qui cite déjà le 9), le mode
2 (11) et le calcul allégé (12). Les textes des chapitres sont repris tels
quels ; les nombres de tests qu'ils citent sont ceux de leur branche.

Le recouvrement réel est **dans les résultats** : chaque branche avait mesuré
ses bilans sans les trois autres. `fragmentCount` suit maintenant l'ordre du
fichier, ce qui change le tri et les morceaux restants. Les noms uniques
changent le départage par chemin de JkDefrag, de XP et d'UltraDefrag.

### Ce qui valide

- **Les 235 tests passent** après reconstruction complète du build debug, et
  l'application se construit.
- **`RenderTrace`, `PLAN_ONLY`**, sur le binaire de `ultradefrag-fidele` (d'où
  venaient les chiffres du README) puis sur `develop` intégré, soit 41 bilans :
  XP, UltraDefrag et JkDefrag mode 2 sur les huit volumes NTFS de 2003 et 2007,
  Windows 95 et JkDefrag mode 2 sur sept volumes FAT, le tri par nom sur
  `famille-2007`, `gamer-2007` et `secretaire-1999`. **39 sont identiques à
  l'octet.** Le mode 2, relecture du trou comprise, ne change nulle part sous
  le nouveau `fragmentCount`.
- **Les deux écarts** sont des tris par nom sur des volumes que le chantier 10
  n'avait pas rejoués :

| tri par nom | requêtes | évacuations | durée | morceaux restants |
|---|---:|---:|---:|---:|
| `famille-2007` | 1 115 079 → 1 128 727 | 156 563 → 160 570 | 7 h 21 → 7 h 24 | 17 165 → 18 200 |
| `gamer-2007` | 581 347 → 578 477 | 82 013 → 81 315 | 4 h 50 → 4 h 49 | 30 441 → 30 383 |

  C'est plus que le « moins de 1 % » des volumes `dev-` : 6 % de morceaux en
  plus sur `famille-2007`. Le README est corrigé.
- **Les huit démarrages du README**, rendus en WAV : même empreinte MD5 des
  deux côtés. Les requêtes du démarrage ne lisent que l'extension et le
  répertoire, que les alias gardent.
- **Coût de génération** : `dev-2007` passe de 0,95 s à 1,43 s de temps CPU
  pour un bilan XP, soit le 0,4 s de `giveUniqueNames`. Le README disait 0,8 s
  pour le volume le plus lourd, il dit maintenant 1,3 s.

### Laissé ouvert

- **Les autres tris** (taille, dates) et les modes 5 et 6 n'ont pas été
  rejoués sur les volumes de 2007.
- **Rien n'a été écouté**, et les passes complètes ne sont pas comparées en
  WAV : le seul effet du calcul allégé sur le son est garanti par le
  chapitre 12, mesuré sans les trois autres branches.

## Chantier 13 — les fichiers d'un seul tenant, d'une autre teinte

**Fait** · branche `fichiers-contigus-teintes`

### Le problème

La carte ne disait que la catégorie d'un cluster. Un volume rangé et un volume
éparpillé avaient les mêmes couleurs ; seule la position trahissait la
fragmentation, et encore, pas pour un fichier resté sur place en morceaux.

### Les décisions

- **Un booléen `contiguous` sur `MapRun`, `MapMutation` et `TimedMutation`**,
  plutôt qu'un bit dans l'octet de catégorie : la plage fait douze octets avec
  ou sans lui, et aucune comparaison à `rawValue` des tests n'avait à changer.
  Deux plages voisines ne fusionnent plus que si elles ont la même nuance.
- **Le décompte par bloc double** (seize compteurs au lieu de huit). Un bloc
  prend la nuance de la majorité stricte des clusters de sa catégorie
  dominante ; la catégorie elle-même se choisit toujours sur le total.
- **Plus sombre, pas plus clair** : ×0,8 sur la couleur de la catégorie, comme
  le bleu foncé des données optimisées de Windows 95. Le libre et les
  métadonnées ne changent pas. La teinte proportionnelle mélange vers le libre
  depuis cette couleur-là.
- **L'état écrit est celui du fichier après le déplacement**, connu avant de
  le lancer (`relocation(…).coalesced().count <= 1`). Un déplacement **partiel**
  qui change cet état repeint le fichier entier, par des mutations portées par
  la première écriture de métadonnées de `commit` — le moment où le système de
  fichiers valide. Un déplacement complet n'en a pas besoin.
- **La galerie** fait le même décompte dans `GeneratedDisk.shaded`, qui rend un
  troisième tableau.

### Ce qui valide

- **239 tests passent**, dont quatre nouveaux : la palette, la majorité par
  bloc, l'état de chaque fichier après chaque validation pour les onze
  stratégies, et le fichier coupé autour d'un immobile par le tri par nom — ce
  dernier **échoue quand on retire le repeint**, ce que le test des onze
  stratégies ne faisait pas (ses fichiers sont tous déplacés en entier).
- Les contrôles « aucune écriture sur un cluster occupé » de JkDefrag ne
  regardent plus que les opérations `writeExtent` : un repeint n'est pas une
  écriture.
- **`RenderTrace`, `PLAN_ONLY`** sur `gamer-1996` pour Windows 95, le tri par
  nom de JkDefrag et UltraDefrag : bilans identiques à `develop` à l'octet.
- Capture sur le simulateur : la passe de Windows 95 montre les fichiers
  système fragmentés plus clairs que les autres, et la légende a son entrée.

### Laissé ouvert

- Rien n'a été regardé **pendant** une passe ni en plein écran, seulement l'état
  de départ.
- La nuance d'un bloc à 17 000 cellules sur un gros volume se joue à la
  majorité : un bloc à moitié rangé bascule d'un cluster à l'autre.

## Chantier 14 — tasser un volume FAT sans changer son ordre

**Fait** · branche `defrag-fat-econome`

### Le problème

Sur les douze volumes FAT de la galerie, aucun des outils simulés ne tient à
la fois la durée, la qualité et le manque de place. Mesures `PLAN_ONLY` de
départ, avec le compte des trous libres ajouté au bilan de `RenderTrace` :

| scénario | plein | durée 95 / JkDefrag / UltraDefrag | morceaux restants 95 / JK / UD | trous 95 / JK / UD |
|---|---:|---:|---:|---:|
| `gamer-1993` | 99 % | 1 956 / 8 / 8 s | 0 / 941 / 929 | 241 / 7 / 12 |
| `gamer-1996` | 99 % | 3 558 / 7 / 7 s | 14 / 1 622 / 1 620 | 286 / 2 / 2 |
| `dev-1999` | 93 % | 18 256 / 1 060 / 382 s | 3 / 707 / 8 130 | 248 / 612 / 4 785 |
| `famille-1999` | 97 % | 16 130 / 729 / 234 s | 8 / 2 739 / 14 523 | 312 / 1 563 / 4 751 |
| **douze volumes** | | **83 247 / 5 250 / 2 002 s** | | |

Windows 95 range tout, mais dans l'ordre du parcours de l'arborescence : il
déplace jusqu'à sept fois le contenu du volume. JkDefrag et UltraDefrag
n'évacuent personne et ne font rien quand les trous manquent — deux clusters
libres sur `gamer-1996`, douze sur `gamer-1993`. Et le fichier d'échange,
immobile, est souvent en centaines de morceaux (290 sur `dev-1996`), qui
découpent le volume en fenêtres.

### Les décisions

- **L'ordre d'arrivée est l'ordre actuel.** Une frontière balaie le volume ; un
  fichier d'un seul tenant qui y commence ne bouge pas. C'est ce qui supprime
  la cascade d'évacuations de Windows 95 : ce qu'on range n'a presque jamais
  une destination occupée par quelqu'un qui repartira.
- **Le glissement par tronçons de la taille du trou.** Le fichier qui suit un
  trou descend tronçon par tronçon, chacun écrit dans la place que le
  précédent vient de quitter. C'est le seul geste qui marche avec deux clusters
  libres, et il n'écrit jamais sur une donnée encore référencée.
- **Aucune écriture sur un cluster quitté mais pas encore validé.** Les
  déplacements vers des clusters déjà libres sont validés par lots — une
  écriture des tables, triée et fusionnée — et les clusters qu'ils quittent
  restent retenus jusque-là (`relocateHoldingReleased`, écrit pour UltraDefrag
  sur NTFS). Un test rejoue chaque plan et compte les écritures fautives ; il
  en trouve 17 171 sur le volume vieilli quand on retire la rétention.
- **Les refuges.** Un trou qu'aucun fichier ne peut combler devant un obstacle
  reste libre à l'arrivée, mais sert d'abri pendant la passe. Sans eux, le
  premier trou laissé sur `gamer-1996` avalait ses deux clusters libres, et
  194 fichiers étaient abandonnés.
- **La navette.** Quand tout l'espace libre est le trou de la frontière et que
  le fichier suivant ne tient pas avant l'obstacle, un fichier qui y tient est
  rangé pièce à pièce, le trou servant de va-et-vient. S'il n'en reste aucun,
  la zone est laissée en refuge. Ce sont ces deux cas, et non un défaut de la
  bitmap que j'ai d'abord cru voir, qui faisaient abandonner des fichiers.
- **Le plus gros d'abord, fenêtre par fenêtre.** Un fichier qui ne trouvera
  plus de fenêtre à sa taille entre les obstacles à venir, une fois celles-ci
  partagées entre les plus gros, passe avant les autres. Sans cette règle, un
  fichier de 73 243 clusters restait en 2 300 morceaux sur `gamer-1999`.

Les réglages qui suivent ont été choisis à la mesure, un par un :

| version | durée, douze volumes | fichiers déplaçables restés en morceaux |
|---|---:|---:|
| glissement seul, morceaux évacués juste au-dessus | 37 016 s | 300 |
| morceaux évacués au fond du volume | 30 081 s | 325 |
| + comblement exact seulement, parcage, refuges, navette, fenêtres | 21 575 s | 0 |
| + réparation préalable, validations groupées, plafond de 16 clusters | **17 275 s** | **0** |

- **Évacuer au fond du volume.** Posé juste au-dessus, le morceau d'un gros
  fichier était retrouvé et repoussé à chaque avancée de la frontière : 70 092
  évacuations sur `famille-1999`, 16 712 au fond.
- **Ne combler qu'au cluster près, et que les petits trous.** Chaque fichier
  tiré dans le trou le consommait, et tout ce qui glissait ensuite le faisait
  par tronçons de 18 clusters en moyenne sur `famille-1999` (62 000 tronçons).
  Plafonné à 16 clusters : 2 929 → 2 129 s sur ce volume, 1 305 → 1 140 s sur
  `secretaire-1999`, et +2 % sur `dev-1999`.
- **Pousser au fond un fichier qui glisserait en plus de 8 tronçons.** Le seuil
  compte peu : de 2 à 16, le total varie de moins de 2 %.
- **Réparer d'abord ce qui tient dans un trou.** 4 à 22 % selon le volume.
- **Valider par lots.** 4 à 8 % de moins sur les gros volumes. Garder le lot
  ouvert quand la frontière n'a plus de trou devant elle allonge `gamer-1996`
  de 10 % : sur un volume plein, les clusters retenus sont ceux qui manquent.
  Le lot est alors validé tout de suite.
- **Le tampon reste de 256 Ko**, celui de Windows 95, pour que l'écart vienne de
  l'algorithme. Mesuré avant les deux derniers réglages, 4 Mo gagnaient 11 à
  15 % sur les gros volumes de 1999, et rien sur `gamer-1996`.

### Ce qui valide

- Sur les douze volumes, **aucun fichier déplaçable ne reste en morceaux** ; ce
  qui reste est le fichier d'échange (290 morceaux sur `dev-1996`, 46 sur
  `gamer-1999` contre 89 pour Windows 95). Trous libres : 1 sur huit volumes,
  273 au total contre 2 398 pour Windows 95 et 5 043 pour JkDefrag.
- **4 h 47 de passe au total contre 23 h 07** pour Windows 95 ; de deux à sept
  fois moins de données déplacées. Planification et simulation en une seconde
  de CPU au plus par volume, comme les autres outils.
- **246 tests passent**, dont sept nouveaux : conservation du volume, écritures
  jamais faites sur un cluster non validé, deux clusters libres, fichiers en
  place ni lus ni écrits, trou devant le fichier d'échange, fenêtres, lots. Ils
  mordent : retirer la rétention des clusters en fait échouer trois, retirer
  la règle des fenêtres en fait échouer un.
- Les bilans de Windows 95, JkDefrag et UltraDefrag sur `gamer-1996` sont
  identiques à ceux d'avant le chantier.
- Le rendu complet de `dev-1993` passe par la chaîne au fil de l'eau : 5 min 22,
  62 Mo de WAV.

### Laissé ouvert

- **Rien n'a été écouté**, ni vu dans l'application, qui ne propose toujours
  que l'outil d'époque. `xcodegen generate` sera nécessaire pour que le fichier
  entre dans le projet Xcode.
- **JkDefrag reste trois fois plus rapide** (1 h 27), au prix de milliers de
  morceaux sur les volumes de 1999. Sur les volumes pleins à 99 %, le gain sur
  Windows 95 n'est que de 10 à 20 % : chaque tronçon de la navette se paie
  d'une écriture des tables.
- **Les trous entre les morceaux du fichier d'échange** : 157 sur `dev-1996`, 60
  sur `famille-1996`. Les combler demanderait de chercher des combinaisons de
  fichiers à leur taille, comme `FindBestItem`.
- **Les seuils sont calés sur ces douze volumes**, et nulle part ailleurs.
- **La garantie de cohérence est celle du modèle** : l'ordre des écritures à
  l'intérieur d'un lot — les deux copies de la table, puis les entrées de
  répertoire — n'est pas simulé, pas plus qu'il ne l'est pour les autres outils.

## Chantier 15 — recoller peu, sur les gros volumes NTFS

**Fait** · branche `defrag-ntfs-econome`

### Le problème

La même demande que pour FAT — une stratégie plus économe quand la place
manque, plus rapide, et qui défragmente mieux — sur les huit volumes NTFS de la
galerie. Mesures `PLAN_ONLY` de départ (durée simulée · morceaux restants ·
trous libres restants) :

| scénario | plein | Windows XP | UltraDefrag | JkDefrag | tassage à la frontière |
|---|---:|---|---|---|---|
| `dev-2003` | 94 % | 289 s · 3 771 · 3 029 | 407 s · 11 · 1 130 | 698 s · 25 · 620 | plantage |
| `famille-2003` | 93 % | 154 s · 42 617 · 5 711 | 1 083 s · 14 949 · 10 905 | 1 703 s · 2 128 · 1 062 | 8 929 s · 0 · 2 |
| `secretaire-2003` | 94 % | 77 s · 23 778 · 2 795 | 383 s · 14 334 · 7 683 | 1 285 s · 5 307 · 2 903 | 5 781 s · 0 · 2 |
| `gamer-2003` | 8 % | 7 s · 0 · 6 | 7 s · 0 · 6 | 371 s · 0 · 15 | 8 s · 0 · 2 |
| `dev-2007` | 86 % | 4 021 s · 0 · 5 323 | 4 581 s · 19 · 5 346 | 6 870 s · 0 · 253 | 30 500 s · 0 · 7 |
| `famille-2007` | 93 % | 1 393 s · 132 920 · 29 449 | 5 202 s · 1 503 · 6 586 | 7 323 s · 2 191 · 1 544 | 35 676 s · 0 · 2 |
| `gamer-2007` | 90 % | 1 122 s · 38 419 · 13 470 | 2 299 s · 561 · 6 950 | 4 520 s · 1 439 · 1 696 | 34 210 s · 0 · 2 |
| `secretaire-2007` | 88 % | 589 s · 0 · 3 347 | 593 s · 0 · 3 370 | 2 980 s · 0 · 297 | 23 963 s · 0 · 78 |

Le tassage du chantier 14 est parfait et hors de prix : il déplace tout le
contenu du volume, jusqu'à 335 Go, et demande 94 s de CPU sur `famille-2007`.
Aucun des trois autres ne tient à la fois les morceaux et les trous.

La forme des volumes, relevée par un outil jetable avant de rien concevoir, a
décidé de tout :

- **la place ne manque plus, la taille oui** : 2 à 33 Go libres, jusqu'à
  80 millions de clusters. Ce qui coûte O(contenu) coûte des heures ;
- **la fragmentation est concentrée et faite de miettes.** Sur `famille-2007`,
  268 fichiers cassés pèsent 239 Go en 163 249 morceaux ; les morceaux de moins
  de 4 Mo sont 161 550, mais ne pèsent que 11 Go. Regroupés par suites, ils ne
  feraient plus que 3 090 morceaux. Même forme partout : 12 179 des 12 253
  morceaux de `dev-2003` font moins de 4 Mo, pour 586 Mo ;
- **une passe coûte environ 12 ms par requête**, plus deux fois les données au
  débit du disque. Recoller 163 000 morceaux, c'est d'abord 163 000 lectures ;
- **`secretaire-2003` est le cas où la place manque vraiment** : 900 Mo libres
  hors zone MFT, et les morceaux cassés intercalés, de 2 à 60 % du volume, entre
  des archives contiguës de 36 Mo en moyenne, sans un cluster libre.

### Le plantage d'abord

`FrontierCompactionStrategy` plantait sur `dev-2003` : division par un trou
nul. La zone MFT courante de ce volume (`9..<829135`) **recouvre des fichiers**
; la frontière la saute d'un coup et tombe au milieu d'un fichier d'un seul
tenant qui commence 176 clusters plus bas. Il n'y a pas de trou, et le fichier
n'est pas « juste après le trou » : il se range désormais comme un fichier en
morceaux, depuis ce qui dépasse de la frontière. Le calcul du morceau ne change
que dans ce cas : les douze bilans FAT de la stratégie sont identiques à
l'octet. Sur `dev-2003`, la passe donne 4 465 s, 0 morceau, 464 trous. Un test
le reproduit, et plante sans la correction.

### Les décisions

`FragmentMergeStrategy` (`STRATEGY=fragmentMerge`, « Recollage économe »).
Chaque ligne ajoute un geste ou un réglage à la précédente, mesurée sur les huit
volumes :

| version | durée totale | morceaux | trous |
|---|---:|---:|---:|
| petits morceaux (< 4 Mo) recollés au trou le plus proche | 11 275 s | 19 342 | 32 973 |
| + déplacement par blocs pleins | 2 280 s | 19 342 | 32 973 |
| + petit fichier entre deux trous déplacé, validations groupées par tour | 2 390 s | 18 522 | 19 716 |
| + érosion du bord des trous | 3 976 s | 16 280 | 7 750 |
| + plafond de 4 Mo, points de contrôle tous les 16 déplacements, arrêt au rendement | 4 231 s | 15 458 | 4 799 |
| + morceau collé à son voisin | 5 072 s | 8 714 | 3 661 |
| + correction d'une oscillation | **5 104 s** | **8 864** | **3 680** |

- **Ne recoller que les suites de petits morceaux, laisser les gros.** C'est ce
  que la forme des volumes désigne : presque tous les morceaux pour presque
  aucune donnée. Une suite va d'abord contre le gros morceau qui la précède ou
  la suit si le trou voisin l'accepte (553 fois sur `famille-2007`), sinon dans
  le trou le plus proche qui l'accepte ; à défaut, elle est coupée à la taille
  du plus grand. Une suite d'un seul morceau ne bouge que pour rejoindre un
  voisin. Le trou le plus proche plutôt que le plus serré : 11 275 s contre
  12 568, à qualité égale. Le seuil de 4 Mo : à 16 Mo, 12 % de durée en plus
  pour 14 % de morceaux en moins ; à 2 Mo, 5 % de durée en moins pour 17 % de
  morceaux en plus.
- **Déplacer par blocs pleins** (`DefragOperations.gatheredMove`). `move` coupe
  ses tampons aux bornes des extents : un fichier en 10 000 morceaux de 150 Ko
  s'y recopie en 10 000 allers-retours du bras. `FSCTL_MOVE_FILE` copie par
  blocs ; un bloc de 16 Mo qui en rassemble cent se lit en cent lectures
  voisines et s'écrit une fois. Le grain est celui d'UltraDefrag (4 à 16 Mo
  selon la capacité). C'est la décision qui pèse le plus, et elle n'est **pas**
  algorithmique : voir plus bas.
- **Consolider l'espace libre avec de petits fichiers.** Un fichier de 4 Mo au
  plus, coincé entre deux trous, part dans un trou exactement à sa taille ou
  dans le plus proche : les deux trous n'en font qu'un. Au bord d'un seul trou,
  il part dans un trou exactement à sa taille, ou dans le plus petit qui
  l'accepte s'il est plus petit que celui qu'il borde : l'espace libre passe du
  petit trou au grand, et le tour suivant y trouve de quoi recoller. L'érosion
  seule fait passer les trous de 19 565 à 7 750 ; limitée aux trous exacts, de
  19 565 à 10 831. Le plafond de 4 Mo : à 1 Mo il reste 77 % de trous en plus ; à
  16 Mo, 5 % de durée en plus pour 14 % de trous en moins.
- **Coller un morceau à son voisin**, même gros, jusqu'à 16 Mo, quand la
  consolidation a ouvert un trou à côté de ce voisin : 15 458 → 8 714 morceaux
  (`secretaire-2003` : 8 221 → 3 236), pour 20 % de durée. De 8 à 32 Mo, la
  durée croît de 17 % et les morceaux baissent de 14 %.
- **Un point de contrôle tous les 16 déplacements.** Les clusters quittés sont
  retenus (`relocateHoldingReleased`), et l'index des trous où la passe pose ne
  les voit qu'une fois les validations écrites : triées et fusionnées, puis
  les clusters rendus, puis l'index reconstruit. Par tour entier, comme le fait
  UltraDefrag, l'espace libéré attend trop : 4 420 s · 15 825 · 5 056 contre
  4 231 s · 15 458 · 4 799, meilleur sur les trois axes. Tous les 4 : 9 % de
  durée en plus ; tous les 64 : 4 % de moins, 3 % de trous en plus.
- **S'arrêter au rendement.** La consolidation décroît géométriquement — la
  moitié de son gain en trois tours, 90 % en douze — et traîne ensuite des
  centaines de tours pour quelques clusters. Un tour qui retire moins de 1 % des
  trous est le dernier. Le compte se fait une fois les clusters du tour rendus :
  compté avant, le premier tour de recollage paraissait créer des trous et la
  passe s'arrêtait au deuxième (13 610 trous au lieu de 5 056).
- **Pas de glissement vers un trou voisin.** Un fichier qui borde un seul trou
  exactement à sa taille pouvait « s'y déplacer » : le trou passait de l'autre
  côté, et le fichier revenait au tour suivant. Ce trou n'est plus une
  destination. 0,6 % de durée, et surtout une passe qui converge.
- **Écarté : recopier les fichiers entiers.** Quand un trou accepte un fichier
  resté en quelques gros morceaux, le déplacer entier si cela coûte moins de
  4 Mo par morceau supprimé gagne 7 % de morceaux pour 2,5 % de durée. Mesuré
  plus tôt, avant le collage au voisin, le même geste à 16 et 64 Mo par morceau
  allongeait la passe de 19 et 76 %. Gardé hors de la passe, pour que les gros
  morceaux restent la règle.

**Ce qui revient à l'algorithme, et ce qui revient aux primitives.** Mesuré en
retirant chacune, puis en donnant les blocs pleins aux autres outils (le temps
d'une mesure, rien n'en est resté) :

| | durée totale | morceaux | trous |
|---|---:|---:|---:|
| recollage économe, `move` d'origine, une validation par déplacement | 14 655 s | 8 714 | 3 661 |
| + validations groupées seulement | 13 110 s | | |
| + blocs pleins seulement | 6 617 s | | |
| + les deux | 5 072 s | | |
| Windows XP · UltraDefrag · JkDefrag, tels quels | 7 652 · 14 555 · 25 750 s | 241 505 · 31 377 · 11 090 | 63 130 · 41 976 · 8 390 |
| les mêmes, avec les blocs pleins | 4 063 · 5 277 · 17 345 s | inchangés | inchangés |

(mesures faites avant la correction de l'oscillation, d'où 5 072 s et non
5 104.) À primitives égales, la passe dure **autant qu'UltraDefrag** et laisse
3,6 fois moins de morceaux et 11 fois moins de trous ; elle est **3,4 fois
plus rapide que JkDefrag**, avec 21 % de morceaux et 56 % de trous en moins.
L'avance en durée sur XP et UltraDefrag, elle, vient des blocs pleins.

### Ce qui valide

| scénario | Windows XP | UltraDefrag | JkDefrag | recollage économe |
|---|---|---|---|---|
| `dev-2003` | 289 s · 3 771 · 3 029 | 407 s · 11 · 1 130 | 698 s · 25 · 620 | **196 s · 101 · 138** |
| `famille-2003` | 154 s · 42 617 · 5 711 | 1 083 s · 14 949 · 10 905 | 1 703 s · 2 128 · 1 062 | **718 s · 1 073 · 256** |
| `secretaire-2003` | 77 s · 23 778 · 2 795 | 383 s · 14 334 · 7 683 | 1 285 s · 5 307 · 2 903 | **694 s · 3 410 · 879** |
| `gamer-2003` | 7 s · 0 · 6 | 7 s · 0 · 6 | 371 s · 0 · 15 | **8 s · 0 · 3** |
| `dev-2007` | 4 021 s · 0 · 5 323 | 4 581 s · 19 · 5 346 | 6 870 s · 0 · 253 | **750 s · 844 · 207** |
| `famille-2007` | 1 393 s · 132 920 · 29 449 | 5 202 s · 1 503 · 6 586 | 7 323 s · 2 191 · 1 544 | **1 417 s · 1 822 · 539** |
| `gamer-2007` | 1 122 s · 38 419 · 13 470 | 2 299 s · 561 · 6 950 | 4 520 s · 1 439 · 1 696 | **1 086 s · 1 560 · 720** |
| `secretaire-2007` | 589 s · 0 · 3 347 | 593 s · 0 · 3 370 | 2 980 s · 0 · 297 | **235 s · 54 · 938** |
| **huit volumes** | 7 652 s · 241 505 · 63 130 | 14 555 s · 31 377 · 41 976 | 25 750 s · 11 090 · 8 390 | **5 104 s · 8 864 · 3 680** |

- **1 h 25 de passe au total**, contre 2 h 08 pour XP, 4 h 03 pour UltraDefrag
  et 7 h 09 pour JkDefrag ; 67 Go déplacés contre 94, 126 et 331. Moins de
  morceaux et moins de trous au total que tous les outils simulés.
- **Quand la place manque** (`secretaire-2003`, 94 %) : 3 410 morceaux contre
  5 307 pour JkDefrag et 14 334 pour UltraDefrag, 879 trous contre 2 903, en
  deux fois moins de temps que JkDefrag.
- **Le volume où il n'y a rien à faire** (`gamer-2003`) reste à 8 s.
- **Planification en 0,8 s au plus** en release (`famille-2007`), 2,5 s de CPU
  pour génération, planification et simulation, contre 2,0 s pour XP.
- **253 tests passent**, dont sept nouveaux : six pour cette passe (passe
  complète sur un volume vieilli — conservation, zone MFT, fichier d'échange,
  écritures jamais faites sur un cluster non validé —, petits morceaux contre un
  gros qui ne bouge pas, zone MFT seul grand trou, fichier entre deux trous,
  bloc plein, outil jamais choisi seul) et celui du plantage. Les tests
  existants qui passent toutes les stratégies (MFT jamais écrite, nuance de la
  carte) la couvrent aussi. Ils mordent : autoriser la zone MFT en fait échouer
  deux, retirer le voisin un, la consolidation deux, et rendre l'espace quitté
  sans valider fait compter une écriture fautive dans deux.
- **Non-régression** : 79 des 80 bilans (Windows 95, XP, UltraDefrag, JkDefrag,
  tassage, sur les vingt volumes où la passe les mesure) sont identiques à
  l'octet ; le 80ᵉ est le plantage corrigé.
- Le **rendu complet** de `dev-2003` passe par la chaîne au fil de l'eau : 3 min
  17, 38 Mo de WAV, même bilan qu'en `PLAN_ONLY`.

### Laissé ouvert

- **Les blocs pleins restent une option pour les autres outils NTFS**
  (`fullBlocks`, `FULL_BLOCKS=1` au rendu hors-ligne), éteinte par défaut. Par
  défaut, leurs bilans sont identiques à l'octet ; avec l'option, ils redonnent
  exactement les mesures ci-dessus. L'allumer par défaut diviserait leur durée
  par 1,5 à 2,8 et changerait le son de la passe que l'application fait
  entendre : c'est une décision à part.
- **`dev-2007` et `secretaire-2007` gardent des morceaux** : 844 et 54,
  quand XP et JkDefrag tombent à zéro en recopiant 10 à 78 Go dans le grand trou
  de 20 à 23 Go de ces volumes. La passe ne recopie pas de fichier entier.
- **`secretaire-2003` laisse 2 560 suites sans trou.** Les recoller demanderait
  de faire glisser les archives qui les séparent, c'est-à-dire le tassage du
  chantier 14 et son prix.
- **Le journal de NTFS n'est pas simulé**, pour aucun outil. Grouper les
  validations au point de contrôle suppose que les enregistrements de MFT et la
  bitmap partent avec l'écrivain paresseux ; chaque `FSCTL_MOVE_FILE` écrirait
  aussi dans `$LogFile`.
- **Les réglages sont calés sur les huit volumes de la galerie**, et la grille
  de réglage a été mesurée avant la correction de l'oscillation.
- **Rien n'a été écouté**, ni vu dans l'application. `xcodegen generate` sera
  nécessaire pour que le fichier entre dans le projet Xcode.
- **`Tools/build-render.sh` ne compilait plus avec Swift 6.4** : `swift build`
  y prend par défaut le nouveau système de build, qui pose le module et un seul
  `DiskCore.o` à la racine des produits. Le script accepte maintenant les deux
  dispositions et copie le paquet de ressources à côté de l'exécutable. Les
  mesures de ce chantier ont été faites avec l'ancien système ; les bilans sont
  les mêmes avec le nouveau.

## Chantier 16 — installer le disque

### Le problème

Un disque de la galerie se **démarre** et se **défragmente** ; il ne
s'**installe** pas. Or le jour 0 de son histoire est déjà écrit : le compilateur
pose le système répertoire par répertoire, puis les applications de
`spec.installs`, les bibliothèques partagées et le fichier d'échange, et
l'allocateur leur donne leurs places. Rien ne le faisait entendre.

Rejouer ces créations telles quelles n'aurait pas sonné comme une installation
d'époque. Ce qui la fait reconnaître se passe autour des fichiers, et le
modèle n'en avait rien :

- **la source** : disquette à quelques dizaines de ko/s, CD de 4x à 48x. C'est
  elle qui espace les écritures ;
- **les archives** : l'installeur extrait son moteur et ses CAB, les relit en
  copiant, puis les efface. Le va-et-vient crépite, et l'effacement laisse les
  premiers trous du volume ;
- **les tables** : écrites à chaque fichier sous MS-DOS, par salves derrière
  VCACHE ou l'écrivain paresseux ensuite ;
- **le registre**, réécrit en bloc après chaque logiciel, et absent du
  catalogue ;
- **les redémarrages**, qui relisent ce qui vient d'être posé.

### Les décisions

- **Les archives entrent dans le scénario, pas seulement dans le rejeu.** Elles
  ont occupé le disque le temps de l'installation. Ce qui s'est écrit ensuite
  est tombé après elles, et leurs trous ont été comblés plus tard. Les poser
  dans le rejeu seul aurait donné une arrivée différente du disque que la
  galerie vieillit. Conséquence acceptée : tous les disques d'après 1994
  changent un peu (tableau plus bas).
- **Un générateur à part pour la mise en place** (`spec.seed ^ constante`).
  Archives et ruches ne consomment aucun tirage du générateur principal : tailles
  et dates du reste de l'histoire sont inchangées, seules les places bougent.
  Preuve : les quatre profils de 1993 (disquettes, ni archives ni ruches)
  gardent des bilans identiques.
- **`SetupStyle` par manifeste** (`Sources/DiskCore/InstallSetup.swift`) :

  | | source | archives | ruches | redémarrages |
  |---|---|---|---|---|
  | MS-DOS 6.22, Windows 3.1 | disquettes | — | (INI déjà au manifeste) | 1 |
  | Windows 95 | CD 4x–8x | `WININST0.400`, 3,6 Mo | `SYSTEM.DAT`, `USER.DAT` | 2 |
  | Windows 98 SE | CD 24x–32x | `WININST0.400`, 5,8 Mo | idem, plus gros | 3 |
  | Windows XP | CD 40x–48x | — (phase texte depuis le CD) | 5 ruches + `NTUSER.DAT` | 2 |
  | Windows Vista | DVD 16x | — | 6 ruches + `NTUSER.DAT` | 3 |
  | application avant 1995 | disquettes | — | — | 0 |
  | application sur CD | CD de l'année | `\WINDOWS\TEMP\_ISTMP0.DIR`, 10 % de l'application (1,5 à 60 Mo) | — | 1 si DLL partagées |

  Ce sont des ordres de grandeur, comme les manifestes. Les archives d'une
  application sont des `cabinets` : chaque fichier posé en relit une part. Celles
  de Windows 95/98 sont le moteur d'installation, lu d'un bloc au lancement.
- **`CompiledScenario.installSteps`** décrit le jour 0 en étapes : fichiers,
  archives, ruches, et une dernière étape pour le fichier d'échange.
  `WIN386.SWP`, créé au jour 1, n'en fait pas partie.
- **`DiskGenerator.install(spec)`** rejoue le jour 0 pas à pas
  (`Simulator.step`). Il rend le disque au soir de l'installation et le journal
  des créations, effacements et croissances de la MFT, avec les extents exacts.
  Le choix de l'allocateur est factorisé avec `generate`.
- **`InstallPlanner`** (`Sources/Model/InstallSession.swift`) traduit le journal
  en `DiskOperation` et `MapMutation`, comme une stratégie de défragmentation :
  la carte part d'un volume vierge et se remplit. Le temps hors disque passe par
  un nouveau `DiskOperation.thinkTime`, relayé au pipeline, et nul pour les
  défragmenteurs.
  - **Source** : octets compressés (×1,9) divisés par le débit du support ; une
    pause de 6 s toutes les 1,44 Mo lus sur disquette.
  - **Décompression et création** : `ThinkModel` par époque, de 0,08 s par
    fichier et 0,6 s/Mo sous MS-DOS à 0,006 s et 0,03 s/Mo sous Vista.
  - **Tables** : `commitAccesses` marque les secteurs sales. Ils sont vidés à
    chaque fichier sous MS-DOS, toutes les 3 s estimées sous 95/98, toutes les
    secondes sous NT, avec une écriture de `$LogFile` près de `$MFTMirr`. Le
    vidage est trié par LBA et fusionné.
  - **Taille des écritures** : 64 Ko sous MS-DOS, 128 Ko (95), 256 Ko (98),
    512 Ko (XP), 1 Mo (Vista). Par morceaux de 64 Ko, les 13,5 Go de
    `gamer-2007` attendaient un demi-tour de plateau deux cent mille fois :
    1 336 s de disque au lieu de 352.
  - **Registre** : les ruches posées sont réécrites en bloc à la fin de chaque
    étape, et après chaque redémarrage d'un système.
  - **Redémarrage** : `BootPlanner.plan(disk:launchesApplication: false)` sur le
    catalogue posé jusque-là, POST compris. Le plateau ne s'arrête pas.
  - **Pauses raccourcies** : détection du matériel de 3 à 12 s, configuration de
    4 à 12 s, clic sur « Redémarrer » 2 s.
- **Dans l'app** : « Installer ce disque » sur la fiche (`GeneratedActivity.install`),
  carte et avancement sur l'écran de la passe, tuiles « fichiers posés / Mo
  écrits / source / redémarrages », section des Instruments, bilan (« vierge →
  installé »), historique, fiche ⓘ « L'installation ». Le bilan propose
  **« Démarrer ce disque fraîchement installé »**, qui démarre le disque du jour 0.
- **Rendu hors-ligne** : `SCENARIO=install:<profil>`, avec le décompte du
  planificateur (archives, vidages, réécritures, redémarrages, temps de source).

### Ce qui valide

- **`swift test` : 113 tests `DiskCore` et 194 `DefragKit` passent**, dont 17
  nouveaux :
  - archives nées et effacées au jour 0 ;
  - étapes couvrant toutes les créations du jour 0 ;
  - ruches de XP ;
  - époque des disquettes ;
  - journal rejoué sur une bitmap vierge qui redonne celle du soir, au cluster
    près ;
  - un fichier posé au jour 0 et jamais retouché qui garde, sur le disque
    vieilli, les extents de l'installation ;
  - soustraction d'extents ;
  - neuf pour le planificateur : volume, déterminisme, chaque cluster posé
    écrit, carte finale identique au disque installé, vidage par fichier en
    1993 et groupé en 1996, redémarrages, disquette plus lente que le CD,
    archives relues puis effacées, noms des phases ;
  - l'installation en flux identique au calcul d'un bloc (repères, mutations
    datées, avancement monotone).
- **`CalibrationTests` passent sans retouche.**
- **Les vingt installations** (`PLAN_ONLY=1 SCENARIO=install:…`, release) :

  | | durée | source | posé | archives | redém. | hors disque |
  |---|---:|---|---|---:|---:|---:|
  | `gamer-1993` | 728 s | 21 disquettes | 373 fichiers, 39 Mo | 0 | 2 | 659 s |
  | `dev-1993` | 1 000 s | 26 disquettes | 615 fichiers, 54 Mo | 0 | 2 | 904 s |
  | `secretaire-1996` | 449 s | CD 8x | 1 008 fichiers, 222 Mo | 46 | 3 | 336 s |
  | `dev-1996` | 878 s | CD 8x | 1 801 fichiers, 516 Mo | 68 | 4 | 637 s |
  | `famille-1999` | 560 s | CD 32x | 2 412 fichiers, 574 Mo | 77 | 5 | 397 s |
  | `gamer-2003` | 827 s | CD 48x | 3 172 fichiers, 5,9 Go | 23 | 2 | 597 s |
  | `famille-2003` | 528 s | CD 48x | 3 388 fichiers, 1,4 Go | 26 | 4 | 378 s |
  | `famille-2007` | 846 s | DVD 16x | 10 710 fichiers, 4,8 Go | 34 | 5 | 567 s |
  | `gamer-2007` | 1 262 s | DVD 16x | 10 398 fichiers, 13,5 Go | 23 | 3 | 911 s |

  De 7 à 21 minutes. Sur disquettes, la source fait plus des trois quarts de
  l'attente. Sur CD et DVD, ce sont la décompression et les pauses. Chaque
  arrivée compte au plus 2 fichiers fragmentés et 5 trous libres.
- **Écarts sur les disques vieillis** (`develop` → branche, bilans de passe) :

  | | fichiers | fragmentés | morceaux | trous | défragmentation | démarrage |
  |---|---|---|---|---|---|---|
  | quatre profils de 1993 | = | = | = | = | = | = |
  | `dev-1996` | 5 529 → 5 533 | 133 → 152 | 1 531 → 2 412 | 588 → 347 | 2 181 → 2 934 s | 57,5 → 58,7 s |
  | `famille-1999` | 4 048 → 4 037 | 898 → 874 | 21 179 → 22 607 | 821 → 1 862 | 16 130 → 18 001 s | 66,7 → 66,0 s |
  | `gamer-1999` | 3 796 → 3 836 | 738 → 654 | 7 964 → 7 236 | 484 → 617 | 15 264 → 27 353 s | 57,5 → 54,8 s |
  | `famille-2003` | 4 194 → 4 200 | 68 → 75 | 47 063 → 43 930 | 1 906 → 1 539 | 155 → 107 s | 31,5 → 28,8 s |
  | `famille-2007` | 12 222 → 12 229 | 268 → 259 | 163 249 → 176 608 | 6 382 → 6 349 | 1 394 → 1 531 s | 39,3 → 38,3 s |
  | `gamer-2003` | 3 173 → 3 179 | 0 → 0 | 0 → 0 | 6 → 7 | 7,8 → 7,9 s | 68,9 → 70,0 s |

  Les autres profils bougent dans les mêmes proportions. La texture reste celle
  de chaque époque : les deux ruches et quelques mégaoctets d'archives
  déplacent le curseur de l'allocateur, et c'est lui qui décide du reste. Les
  démarrages varient de −15 % à +7 %. **`gamer-1999` est le cas extrême** : sa
  passe Windows 95 dure 79 % de plus pour un volume *moins* fragmenté. Le premier
  trou laissé par les archives change l'ordre dans lequel le tassage trouve ses
  places.
- **L'app se construit** en Debug pour le simulateur iPhone 18 Pro Max
  (`xcodegen generate` d'abord), sans erreur.

### Laissé ouvert

- **Rien n'a été écouté ni regardé dans l'app.** Le simulateur a été lancé,
  mais `axe` ne touche plus l'écran (« XCUIAutomation couldn't be loaded »), et
  la machine, saturée par d'autres travaux, n'a pas laissé la session
  d'interaction Xcode répondre.
- **Pas de formatage** : ni `FORMAT` complet ni vérification de surface.
  C'était le son le plus reconnaissable ; il demanderait une phase de lecture
  séquentielle de toute la partition avant la copie.
- **Les jeux installés en cours d'usage** (`play`, fichiers `DATA*.PAK`) ne
  passent pas par les manifestes et ne sont pas rejoués. `WIN386.SWP` naît au
  jour 1, hors de l'installation.
- **Les disquettes comptent 38 Mo pour Windows 3.1**, parce que les manifestes
  décrivent le système installé, pas le jeu de disquettes : une vingtaine de
  changements de disquette là où il y en avait six ou sept.
- **L'installation se prépare sur le fil principal** (`DiskGenerator.install`
  compile toute l'histoire pour en garder le premier jour) : moins d'une seconde
  en release sur le Mac pour `famille-2007`, à mesurer sur le téléphone. Le
  démarrage fait déjà de même avec son témoin.
- **Les écritures ne sonnent pas autrement que les lectures** : `DiskMechanics`
  leur donne le même coût et `CueStream` ignore les transferts. Ce qu'on entend
  de l'installation, ce sont ses seeks.
- **Les réglages** (débits, pauses, part des archives, tailles des ruches) sont
  des ordres de grandeur d'époque, pas des relevés.

## Chantier 17 — revivre un disque

### Le problème

Un disque de la galerie s'installe, se démarre et se défragmente : trois
instants. Entre eux, il y a **deux ans**, et c'est là que tout se joue — le
volume se remplit, les fichiers partent en morceaux, le curseur de l'allocateur
fait son tour. Cette histoire était écrite depuis le début (`ScenarioCompiler`)
et rejouée d'un trait par `DiskGenerator.generate`, qui n'en rendait que
l'arrivée. Rien ne la faisait entendre ni voir.

Deux obstacles :

- **la durée.** L'histoire d'un profil écrit de 0,8 Go (`secretaire-1993`) à
  585 Go (`dev-2007`), pour 6 600 à 2,7 millions d'événements. En temps réel,
  `dev-1993` demanderait plus de quatre heures, et les profils de 2007 des
  jours. Un seek dure ce qu'il dure : on ne peut pas accélérer le son ;
- **ce que l'histoire ne dit pas.** Elle ne décrit que des **écritures**, datées
  au jour près. Or une journée lit au moins autant qu'elle écrit : un
  compilateur relit ses sources, l'éditeur de liens ses objets, un jeu recharge
  ses niveaux. Et elle ne dit rien de la machine qu'on allume le matin.

### Les décisions

- **Deux vitesses qui s'enchaînent**, plutôt qu'un seul mode : un **défilement**
  muet où la carte avance de plusieurs jours par seconde, et des **journées
  écoutées** en temps réel, prises là où le défilement en est. On s'arrête, on
  écoute, on repart.
- **`HistoryReplay` (DiskCore)** rejoue l'histoire jour par jour, sur l'allocateur
  du format et les tirages du profil. Il joue une journée en racontant chaque
  événement, ou saute les jours sans les raconter — même disque à l'arrivée.
  Rien n'est gardé : les 2,7 millions d'événements de `dev-2007` ne tiennent
  jamais en mémoire.
  - Les deux simulateurs (FAT, NTFS) sont deux propriétés optionnelles et non
    une énumération : sortir un simulateur d'un `case` pour le muter recopie sa
    bitmap et son catalogue **à chaque événement**.
- **`Simulator.step` rend compte de tout** : créations, effacements, ajouts en
  fin de fichier, troncatures, enregistrements par temporaire, réécritures sur
  place, et les déplacements d'une défragmentation de l'histoire. Il dit ce qui
  est écrit, ce qui est pris et ce qui est rendu — d'où se refait la bitmap,
  cluster par cluster. L'installation du chantier 16 s'appuie désormais dessus,
  et ses bilans sont inchangés à l'octet.
- **`DaySession` remet la journée autour des écritures** : un démarrage, une
  **séance** par activité, l'arrêt. Une journée revient sur ses pas — le cache
  expire pendant qu'on compile — et chaque retour est une séance de plus, pas la
  reprise de la précédente.
  - **Les lectures viennent de l'activité** : le compilateur relit ses sources,
    l'éditeur de liens relit ses objets avant d'écrire l'exécutable, le
    navigateur rouvre son cache, on ouvre un document avant de l'enregistrer,
    lancer un jeu charge un niveau.
  - **Les sources lentes brident** : carte mémoire ou CD pour les médias, la
    ligne pour les téléchargements et les correctifs — 1,8 ko/s en 1993,
    1 Mo/s en 2007. Les attentes sont **plafonnées à 8 s** : un téléchargement
    de 1999 prenait la nuit, et ce n'est pas la nuit qu'on veut entendre.
  - Les tables suivent l'époque, comme à l'installation : écrites à chaque
    fichier sous MS-DOS, par salves derrière le cache ensuite. C'est
    `MachineWriter`, sorti du planificateur d'installation pour servir aux deux.
- **`DiskLife` fait défiler**, sans rien jouer : une journée par pas, un relevé
  par journée (date, remplissage, fichiers, fichiers en morceaux, octets écrits,
  activités), et les **journées à écouter** nommées au passage : installation,
  caps de remplissage (50, 75, 90, 95 %), premier refus d'écriture, grosses
  journées (plus d'un vingtième du disque, espacées d'un mois au moins),
  défragmentations de l'histoire, pics de fragmentation.
- **Dans l'app** : « Revivre ce disque » sur la fiche ouvre un écran à part —
  carte, date et jour, compteurs, deux courbes (remplissage et fichiers en
  morceaux), la liste des repères, une vitesse (1 jour, 1 semaine, 1 mois par
  seconde), « repère suivant », et « Écouter le jour N », qui rend la main à la
  passe. Le bilan d'une journée dit ce qu'elle a lu et écrit, pas ce qu'elle a
  rangé.

### Ce qui valide

- **`swift test` : 116 tests `DiskCore` et 206 `DefragKit`**, dont 15 nouveaux.
  - Rejeu : l'histoire rejouée en mêlant jours racontés et jours sautés redonne
    le disque généré ; ce que chaque événement prend et rend refait la bitmap au
    cluster près ; sauter jusqu'à un jour équivaut à le jouer.
  - Journée : accès dans le volume, phases qui avancent, une journée lit plus
    qu'elle n'écrit, écritures conformes à l'histoire, avancement d'un seul
    jour, déterminisme, attentes bridées, jour de joueur qui charge son jeu.
  - Défilement : arrivée sur le disque de la galerie, courbes dans le bon sens,
    repères sensés et en nombre raisonnable, reprise possible sur le lendemain,
    carte identique à celle du volume de ce jour-là.
- **Le rejeu raconté de toute une vie** (release) : `dev-1993` 0,1 s,
  `famille-2003` 2,5 s, `dev-2007` 2,8 s pour 2,7 millions d'événements et
  588 Go écrits — et le même disque qu'une génération d'un trait.
- **Journées rendues** (`SCENARIO=day:<profil>:<jour>`) :

  | journée | activités | lu / écrit | durée |
  |---|---|---|---:|
  | `dev-1996`, jour 20 | navigation, compilation, archivage | 215 / 44 Mo | 5 min 46 |
  | `dev-1996`, jour 300 | idem | 231 / 78 Mo | 7 min 11 |
  | `famille-2003`, jour 400 | navigation, bureautique, téléchargement, médias | 201 / 16 Mo | 1 min 37 |
  | `gamer-1999`, jour 365 | navigation, jeu | 547 / 6 Mo | 2 min 35 |

  **L'usure s'entend** : sur `dev-1996`, la même journée passe d'un seek moyen
  de 273 cylindres au jour 20 à 604 au jour 300.
- **Défilements** (`SCENARIO=life:<profil>`) : une vie entière en 0,1 s pour un
  disque de 1996, 3,8 s pour `dev-2007`. De 1 à 39 journées à écouter selon les
  profils. Sur `secretaire-1996` : installation, disque à 50 % au jour 73, à
  90 % au jour 232, grosse journée au 277, 95 % au 282.
- **L'app se construit** en Debug pour le simulateur, sans erreur.

### Laissé ouvert

- **Rien n'a été vu ni écouté dans l'app**, comme au chantier 16 : `axe` ne
  touche plus l'écran depuis Xcode 27, et la machine était saturée par d'autres
  travaux pendant tout le chantier.
- **`famille-2003` et `famille-2007` importent des films tous les jours** : 90
  médias par semaine, dont un quart de DivX de 700 Mo à 1,4 Go en 2003, soit
  20 Go par semaine sur un disque de 40 Go, aussitôt effacés par le ménage. Leur
  vie rejouée est donc surtout une copie de films. C'est le profil qu'il
  faudrait corriger, et cela redessinerait les quatre disques « famille ».
- **Le planificateur d'installation garde son propre émetteur** : `MachineWriter`
  lui a été extrait, mais l'installation n'a pas été récrite dessus, pour ne pas
  risquer de changer ses bilans. Les deux se ressemblent de près.
- **Les lectures d'une journée sont des règles, pas des relevés** : le nombre de
  sources relues, la part du cache rouverte, la taille d'un niveau de jeu.
- **Le défilement recalcule la carte entière à chaque pas** ; sur un volume de
  2007 cela coûte quelques millisecondes, mais rien n'est incrémental.
- **Les jours sautés ne sont pas racontés** : on ne peut pas revenir en arrière
  dans une vie, seulement la rejouer depuis le début.

## Chantier 18 — des vidéos de la passe, rendues hors de l'application

**Fait** · branche `videos-youtube`

### Le problème

Montrer DiskNoise sur YouTube : un démarrage, une défragmentation, plus tard une
installation. Filmer l'application n'est pas possible proprement. Le simulateur
enregistre l'écran **sans le son**, l'application n'a aucun point d'entrée
d'automatisation (ni argument de lancement, ni lien profond), et une
défragmentation d'époque dure de trente minutes à plusieurs heures en temps réel.
Capturer la sortie audio du Mac en même temps aurait demandé un pilote audio
virtuel, et un calage à la main.

### Les décisions

- **Tout rendre hors de l'application**, depuis la même passe. `RenderTrace`
  produisait déjà le son au fil de l'eau, et tout ce que l'écran montre passe par
  le même `PassBatch` : mutations de la carte, échantillons de tête, accès,
  phases, avancement. `RenderVideo` nourrit une `LivePass` sans producteur
  (`absorb`, puis `advance` à l'instant de chaque image). La carte, la rémanence,
  le plateau, la phase et les compteurs sont donc **lus exactement comme dans
  l'application**, sur la même horloge que le mixeur. Rien n'est recalculé : il
  n'existe pas de seconde simulation à maintenir.
- **Une image n'est rendue qu'une fois la passe produite jusqu'à son instant**
  (`batch.clock`). Les mutations antérieures sont alors toutes connues, et la
  vidéo reste en flux comme le son : les images partent dans `ffmpeg` à mesure,
  et rien ne s'accumule.
- **Core Graphics plutôt que SwiftUI.** L'outil est un exécutable macOS, compilé
  contre les mêmes sources `Model` et `Audio` que `RenderTrace`. Le plateau de
  `PlatterView` est transcrit trait pour trait (`PlatterDrawing`), avec des
  épaisseurs rapportées au rayon. La carte reprend l'image d'un pixel par bloc de
  `ClusterMapImage`, agrandie sans interpolation en blocs de pixels entiers.
  Couleurs et palette viennent de `ClusterPalette` et des valeurs de `Theme`.
- **Le son accéléré est fait d'extraits, pas accéléré.** Un seek de trente
  millisecondes passé à ×20 n'est plus un seek. Chaque tranche de quatre
  secondes de vidéo fait entendre le son réel du milieu de ce que l'image
  montre, enchaîné en fondu à puissance constante. Les fenêtres ne dépendent
  que de leur rang, ce qui permet de les remplir en flux sans connaître la durée
  de la passe. `FIT_SECONDS` déduit la vitesse d'une planification à blanc.
  Au-delà de ×1, le plateau ne tourne plus (comme avec « Réduire les
  animations ») : une image y couvrirait des dizaines de tours.
- **Le code commun sort de `RenderTrace`** dans `Tools/Shared` : lecture de
  `SCENARIO`/`STRATEGY`/`FULL_BLOCKS`, mixeur en flux (gains passés en
  paramètres, sortie brute facultative, rappel `onFlush`), bilan et écriture du
  WAV.
- **Deux formats** : 1920 × 1080, et 1080 × 1920 pour les Shorts. Chaque vidéo
  finit sur huit secondes de bilan, avec les chiffres de `PLAN_ONLY`.
- **Un lot décrit en texte** (`Tools/videos.txt`), rendu par
  `Tools/make-videos.sh` dans `.build/videos/`, deux rendus à la fois. Une vidéo
  déjà faite n'est pas refaite.

### Ce qui valide

- **`RenderTrace` n'a pas bougé** : les WAV de `windowsBoot`, `defrag` et
  `boot:dev-1993` ont le même md5 avant et après la mise en commun.
- **Le son de la vidéo intégrale est celui de `RenderTrace`** : WAV identique à
  l'octet sur toute la durée commune (vidéo `windowsBoot` sans bilan). L'image
  et le son partagent l'instant zéro et la même horloge, donc le calage se
  vérifie par construction.
- **Formats** (`ffprobe`) : 1920 × 1080 ou 1080 × 1920, 30 images/s, H.264 et
  AAC, pistes de même durée.
- Images relues aux instants clés : carte, rémanence, plateau, légende,
  avancement, bilan.
- **Le débit est moyenné sur ce que l'image couvre**, jamais moins d'une
  seconde. La tranche de 100 ms sous l'instant de l'image convient au temps
  réel ; en accéléré, une image couvre plusieurs tranches et n'en lire qu'une
  affichait « 0,0 Mo/s » pendant que la passe écrivait. Sur `famille-2007` sous
  UltraDefrag à ×17, la ligne passe de 0,0 à 27,0 puis 4,3 Mo/s selon le moment
  de la passe. Les autres compteurs sont des cumuls, et ne souffrent pas du
  problème.
- **Le premier lot entier** (17 vidéos, 5,2 Go) se rend en une quarantaine de
  minutes, deux rendus à la fois. Il comprend trois démarrages, la
  défragmentation livrée, `dev-1993` sous Windows 95, et `famille-2007` sous
  XP et sous UltraDefrag, chacun en intégrale, en accéléré et en Short. La
  simulation et l'image tiennent environ 100 images/s en 1080p : 30 min 42 de
  `dev-1993` en 615 s, 1 h 26 min 50 d'UltraDefrag en 1 550 s. Les Shorts
  accélérés vont jusqu'à ×90 et durent 1 min 06, bilan compris.

### Après le rebasage sur `develop`

Les chantiers 16 et 17 ont ajouté `install:<profil>` et `day:<profil>:<jour>`.
La demande de scénario étant désormais commune aux deux outils, la vidéo les a
pris sans rien changer d'autre que l'accès à la carte, qui passe par
`Scenario.map` au lieu du seul `defrag` : une installation se regarde donc
remplir un volume vierge, et une journée montre ce qu'elle laisse. Le bilan
final reprend les deux nouvelles descriptions, sans répéter ce qu'elles disent
déjà, et son titre rétrécit plutôt que de se tronquer — le nom d'une journée
porte sa date. Les WAV de `RenderTrace` sont
restés identiques à l'octet, sur les cinq scénarios, y compris les deux
nouveaux.

### Laissé ouvert

- **Ni intro, ni musique, ni sous-titres** : titres et miniatures restent à
  faire au montage. Rien n'a été publié.
- **Rien n'a été écouté** en entier. L'enchaînement des extraits accélérés n'a
  été vérifié qu'au niveau (−30 dB de moyenne, −10 dB de crête sur la
  défragmentation livrée).
- La passe livrée dure 3 min 25 : une version « accélérée » en trois minutes
  n'aurait pas eu de sens, `videos.txt` la demande en une minute.

## Chantier 19 — les deux démos sur des disques du catalogue

**Fait** · branche `develop`

### Le problème

L'accueil proposait deux démos qui ne tournaient sur rien de ce que
l'application sait fabriquer. Chacune portait son propre disque, écrit à la
main à côté du reste :

| | volume | matériel | ce qu'il décrivait |
|---|---|---|---|
| Démarrage | aucun — des phases réglées à l'oreille | Barracuda ATA IV, fiche recopiée | des **fractions du plateau** : « les pilotes à 7,5 % » |
| Défragmentation | FAT16 de 180 Mo à 78 %, `VolumeFactory.agedWindows95` | Quantum Fireball 1080AT, fiche recopiée | un vieillissement paramétré par un taux de remplissage |

Deux conséquences. D'abord, les démos étaient les deux seules passes de
l'application **sans disque** : pas de fichiers nommés, donc pas de catégories
sur la carte, pas de témoin, pas de bilan comparable, pas de « démarrer le
disque rangé », et un résumé de volume écrit d'avance plutôt que mesuré.
Ensuite, elles vieillissaient à part : les vingt profils de la galerie ont reçu
l'installation, la journée, la vie entière et six outils, et ces deux-là n'ont
rien reçu.

### Les décisions

- **Chaque démo nomme un profil de la galerie** (`ScenarioKind.profileID`) et
  passe par les constructeurs existants, `build(boot:)` et
  `build(generated:using:)`. Elle n'ajoute que son titre et sa phrase ; la note
  de modélisation reste celle que le volume généré sait dire de lui-même, et
  elle est **mesurée** — taille de cluster, remplissage, jours vieillis, durée
  du témoin.
- **Le démarrage prend `secretaire-1999`** : Windows 98 SE puis Office 97, deux
  ans de documents et rien d'autre, FAT32 rempli à 88 %. C'est le volume de la
  galerie où la fragmentation coûte le plus à un démarrage — +4 % sur le témoin,
  le maximum des huit mesurés — et son système n'a pas le préchargeur de XP :
  les fichiers partent dans l'ordre du registre, et le bras suit. Il remplace un
  scénario qui promettait « Windows puis une suite bureautique » sans ouvrir un
  fichier.
- **La défragmentation prend `dev-1993`**, le plus proche parent du volume
  qu'elle remplace : FAT16 en clusters de 8 Ko, plein à 74 %, là où l'ancien
  était un FAT16 de 180 Mo à 78 %. Sa carte est assez petite pour qu'un bloc
  d'écran vaille 22 clusters.
- **Et elle le range au tassage à la frontière**, pas avec l'outil de 95. Le
  critère est ce qu'on **regarde** : une frontière balaie le volume depuis son
  début, tout ce qui est dessous est rangé, et la carte se remplit d'un bord à
  l'autre. Les deux outils finissent au même état sur ce volume — aucun fichier
  déplaçable en morceaux, un seul trou libre — mais l'un met 5 min 22 et l'autre
  30 min 35. Une démo de trente minutes n'est pas une démo.
- **Le disque d'une démo est un disque de la galerie pour tout le reste** :
  `SimulationModel` le garde dans `disk`, donc le bilan le nomme, les
  comparaisons d'outils le retrouvent, et « démarrer le disque rangé » marche
  depuis une démo comme depuis une fiche.
- **Il se fabrique au lancement pour la première, à la première écoute pour la
  seconde**, puis reste en mémoire (`demoDisks`). Les deux profils ont été
  choisis parmi les plus légers du catalogue : 25 ms et 47 ms en release, contre
  1,3 s pour un Vista de 250 Go. La galerie continue de fabriquer hors du fil
  principal, avec son avancement ; une démo n'en a pas besoin.

### Ce qui valide

- **`swift test` : 206 tests passent**, dont un nouveau qui vérifie que les deux
  identifiants de profil des démos sont bien dans le catalogue — `Scenario.swift`
  n'étant pas compilé par le paquet, c'est le seul filet contre un profil
  renommé, qui se verrait sinon au lancement de l'application.
- **Le rendu hors-ligne donne les deux passes attendues.**
  `SCENARIO=windowsBoot` : 56,7 s, 534 fichiers lus, 105 Mo, 28,1 s de calcul,
  témoin à 54,7 s soit +4 %. `SCENARIO=defrag` : 322,4 s, 5 762 requêtes,
  1 025 fichiers déplacés, 52 évacuations, 200 fichiers fragmentés avant et 0
  après, 46 trous libres avant et 1 après.
- **Sur le simulateur** (iPhone 17 Pro Max, iOS 26.5, Debug) : l'accueil montre
  les deux cartes avec le disque qu'elles nomment ; la démo de défragmentation
  joue le tassage à la frontière sur une carte de 220 Mo en FAT16 où les six
  catégories de fichiers apparaissent ; la démo de démarrage titre « Windows 98
  SE, puis Office 97 » sur « IDE 4,2 Go · 5 400 tr/min », 534 fichiers à lire.

### Le nettoyage qui suit

Remplacer les deux volumes a laissé sans client toute la branche du modèle qui
décrivait une passe **en phases** plutôt qu'en fichiers. Elle est supprimée, et
ce qui restait dans le code de production pour le seul usage des tests en sort :

- **`WorkloadLibrary`, `WorkloadPhase`, `Ramp`, `SpinSchedule` et
  `WorkloadGenerator` sont supprimés** (450 lignes). `Workload.swift` ne garde
  que `BlockRequest` et la datation des phases après coup. Plus aucune passe
  n'est décrite par un débit, une localité et une rafale : toutes viennent d'un
  catalogue de fichiers ou d'un volume à ranger.
- **`Scenario.fixedSpans`, `PassPipeline.mark(phase:at:)`,
  `PassSetup.datesPhases` et `PassSetup.minimumDuration` disparaissent avec
  elles.** Aucune phase n'a plus de durée imposée, donc `spans(of:)` passe
  toujours par `PhaseSpan.closedLoop` et la chaîne date les phases sans
  condition. Une durée de passe ne dépend plus que de la trace et du parcage.
- **`VolumeFactory.agedWindows95` passe dans les tests**
  (`Tests/DefragKitTests/AgedVolumeFactory.swift`). C'était le volume de la
  démo ; ce n'est plus qu'un volume d'essai — il se fabrique en quelques
  millisecondes, sans générateur ni catalogue, et six suites s'en servent pour
  donner à une stratégie de quoi travailler.
- **`DriveCatalog.bootDrive` et `defragDrive` sont renommés `barracuda2001` et
  `fireball1996`.** Les deux fiches restent — ce sont des points de mesure du
  modèle de géométrie, et les tests les vérifient — mais elles ne portent plus
  de scénario, donc elles portent le nom du disque et non celui d'une passe.
- **Le test du démarrage en flux est réécrit sur un disque généré.** Il
  vérifiait que la passe livrée décrite en phases était identique au calcul d'un
  bloc ; il le vérifie maintenant sur le démarrage de `gamer-1993`, c'est-à-dire
  sur le seul cas où la date d'une requête dépend de ce que la précédente a duré
  (`BlockRequest.thinkTime`). Le test qui ne portait que sur `SpinSchedule` est
  supprimé avec elle.

`swift test` : 205 tests passent, et les deux passes des démos donnent le même
bilan qu'avant le nettoyage — 322,4 s et 5 762 requêtes pour la
défragmentation, 56,7 s et 1 942 pour le démarrage.

### Laissé ouvert

- **Le WAV des deux démos n'est plus celui de la référence** : il ne pouvait pas
  l'être, ce sont d'autres volumes. Les md5 de `windowsBoot` et `defrag` d'avant
  ce chantier ne valent plus rien. `Tools/videos.txt` nomme désormais ses lignes
  d'après le disque et l'outil, pour qu'une vidéo dise sur quoi elle porte.
- **Le crépitement est plus clairsemé** que celui des phases réglées à
  l'oreille : un démarrage décrit en fichiers ne pose que les accès qui
  correspondent à un fichier du catalogue. C'était déjà noté pour les disques de
  la galerie ; c'est maintenant vrai de la démo d'accueil.
- **Rien n'a été écouté en entier**, ni comparé à l'ancien son autrement qu'au
  bilan.

## Chantier 20 — les quatre fautes du lot 1

**Fait** · branche `experts`

### Le problème

`LEDGER-EXPERTS.md` range ce que trois relectures ont trouvé en trois tas :
quatre **fautes** — le code produit quelque chose d'impossible —, huit erreurs
de fait, et deux décisions de conception. Ce chantier ne traite que les quatre
fautes, et rien d'autre. Ce ne sont pas des réglages : ce sont un plan de
défragmentation qui écrit par-dessus une donnée encore référencée, un disque qui
perd un tour de plateau au milieu d'une lecture contiguë, un curseur mort et une
MFT qui ramasse les miettes du volume une par une.

| | où | ce qui était faux | mesuré avant |
|---|---|---|---|
| F1 | `Windows95Strategy.swift:120` | un occupant qui ne trouve pas de refuge reste en place, et l'étape 2 pose le fichier par-dessus | `dev-1996` : 347 trous avant la passe, **496 après** — pour une passe dont le principe est de tasser |
| F2 | `DiskSimulator.swift:270` | la latence rotationnelle suppose le secteur 0 à l'angle 0 sur toutes les pistes, le franchissement de piste suppose l'inverse | un Barracuda ATA IV lit un fichier **contigu** à 10,1 Mo/s en requêtes de 64 Ko, pour une piste à 47,1 |
| F3 | `NTFSAllocator.swift:238` | `systemCursor = range.lowerBound` écrase la ligne au-dessus et fait l'inverse du commentaire | chaque fichier système rebalaie la tête saturée depuis le même point |
| F4 | `NTFSAllocator.swift:438` | `bestFitRun(minLength: 1)` sur tout le volume rend le plus petit trou du disque | MFT de `dev-2003` : 4 653 clusters en **348 extents** |

### Les décisions

**F1 — la place reste prise, et le trou avec.** Si un occupant de la destination
ne trouve aucun refuge, la frontière saute la place et continue. C'est ce que
faisait `DEFRAG.EXE`, et c'est ce que `FrontierCompactionStrategy` fait déjà
avec ses `shelters` : un défragmenteur qui écrit sur une donnée encore
référencée est un défragmenteur qui détruit le volume, et la lenteur de ces
outils est exactement le prix qu'ils payaient pour l'éviter. L'assertion posée
avant tout dépôt ne s'énonce pas en `bitmap.isFree(target)` — un fichier occupe
souvent déjà une partie de sa destination, et ces clusters-là sont les siens :
ce que la place ne doit plus porter, c'est la donnée de quelqu'un d'autre.

**F2 — un skew explicite, et un seul `angleOf`.** `DriveGeometry.TrackSkew`
porte `track = seek(1)/tour` et `head = commutation/tour` ;
`angleOf(position, skew:)` dit où passe un secteur, et sert **et** la latence
rotationnelle **et** le franchissement de piste au milieu d'un transfert. Les
deux ne peuvent donc plus se contredire. Le décalage d'un cylindre au suivant
vaut `track + (heads-1)·head` : on quitte la dernière tête et on rejoint la
première, ce qui défait `heads-1` décalages de tête — sans ce terme, la
continuité serait vraie d'une tête à l'autre et fausse d'un cylindre à l'autre,
soit l'incohérence qu'on corrige. C'est ainsi que ces disques étaient formatés,
et non un correctif d'arrondi déguisé. La tolérance `delta < -1e-9` vient en
plus, et elle reconnaît seulement qu'un angle nul calculé par somme de durées ne
tombe jamais exactement sur zéro : la marge de l'horloge reste à 1e-10 même sur
la plus longue passe de la galerie.

**F3 — le curseur avance, comme son commentaire l'annonçait.** L'affectation
morte disparaît, `systemCursor` avance d'un `searchHorizon` à chaque échec et ne
recule plus.

**F4 — la MFT s'étend par paquets, au plus près d'elle-même.** Deux choses la
cassaient, et la seconde compte plus que la première. Un `bestFitRun` rend le
trou le plus **juste**, donc un trou différent à chaque fois : il disperse par
construction. Le premier trou venu à partir de la fin de la table, lui, fait
tomber deux paquets successifs côte à côte dans le même grand trou, et
`coalesced()` n'en fait qu'un extent. Et le paquet — huit clusters, le minimum
dont les descriptions de NTFS fassent état — espace les demandes, là où un
cluster à la fois en faisait une par fichier créé. Attention au sens du
best-fit : demander le bloc minimal rendrait un trou de la taille du bloc, donc
autant d'extents que de blocs. Premier essai à 8 : **676 extents**, deux fois
pire que le défaut corrigé.

### Ce qui valide

- **`swift test` : 330 tests passent** sur les deux cibles, et
  `DISKCORE_CALIBRATION=1 swift test --filter Calibration` passe avec ses deux
  problèmes connus.
- **L'audit d'allocation** (`Tests/DefragKitTests/AllocationInvariantTests.swift`)
  rejoue les **treize** plans que la galerie sait produire — les huit
  algorithmes et les cinq tris de JkDefrag — sur un volume d'essai à 80 % puis à
  97 %, et vérifie deux choses : `plan.arrangement` ne référence aucun cluster
  deux fois ni un extent système, et aucune `writeExtent` ne tombe sur une donnée
  encore vivante. Le flux d'opérations ne nomme pas le fichier déplacé, mais il
  porte ses **validations**, et un déplacement tient entre deux d'entre elles :
  la règle s'énonce alors sans identité — une écriture ne tombe que sur un
  cluster libre, ou sur un cluster que le même déplacement vient de lire. Un
  second test réduit le cas de F1 à trois fichiers et cent clusters, et il
  échoue sur le code d'avant la correction.
- **Le test de non-régression du skew** (`TrackSkewTests`) : *N* requêtes
  contiguës coûtent exactement ce que coûte une requête de *N* fois la taille,
  à 1e-9 près, pour *N* de 8 à 128. Avant, l'écart était d'un facteur 2,2 ; le
  débit d'une lecture contiguë de 4 Mo découpée en 64 Ko passe de **10,1 à
  35,8 Mo/s**, pour une piste à 47,1. Un troisième test confronte `AccessCost`,
  second consommateur du modèle de coût, à `DiskMechanics` : les deux doivent
  facturer le même transfert. Ce n'était pas garanti — `AccessCost` ne facture
  aucune attente au franchissement de piste, ce qui était jusqu'ici une
  hypothèse muette et contraire, et qui est maintenant la même, par le même
  `angleOf`.
- **Le test de la MFT** (`Tests/DiskCoreTests/MFTGrowthTests.swift`) borne le
  nombre d'extents sur les deux volumes dont la MFT déborde de sa zone, et
  vérifie que les cinq autres la gardent d'un seul tenant.

| volume | MFT, extents avant | après |
|---|---:|---:|
| `dev-2003` | 348 | **39** |
| `secretaire-2007` | 50 | **23** |
| `dev-2007` | 6 | **4** |
| les cinq autres NTFS | 1 | 1 |

### Ce que cela change, mesuré

**F2 fait tomber les vingt démarrages**, de 3,7 à 21,5 %, et l'écart croît avec
l'époque : plus le disque est rapide et plus la lecture est longue, plus le tour
perdu pesait. `ThinkModel` n'a **pas** été recalé — c'est le lot 3 qui le fera,
une fois les corrections de montage et d'arrondi au cluster en place.

| profil | avant | après | |
|---|---:|---:|---:|
| `dev-2007` | 47,0 s | 36,9 s | −21,5 % |
| `gamer-2003` | 70,0 s | 56,0 s | −20,0 % |
| `secretaire-2007` | 41,9 s | 34,0 s | −18,9 % |
| `dev-2003` | 49,1 s | 40,0 s | −18,5 % |
| `famille-2007` | 38,3 s | 31,6 s | −17,5 % |
| `famille-1999` | 66,0 s | 56,3 s | −14,7 % |
| `dev-1999` | 57,0 s | 49,7 s | −12,8 % |
| `gamer-1999` | 54,8 s | 47,9 s | −12,6 % |
| `secretaire-2003` | 33,8 s | 29,9 s | −11,5 % |
| `famille-2003` | 28,8 s | 25,7 s | −10,8 % |
| `secretaire-1999` | 56,7 s | 50,8 s | −10,4 % |
| `gamer-2007` | 29,8 s | 26,9 s | −9,7 % |
| `secretaire-1996` | 55,4 s | 50,3 s | −9,2 % |
| `dev-1996` | 58,7 s | 53,5 s | −8,9 % |
| `famille-1996` | 54,4 s | 50,0 s | −8,1 % |
| `gamer-1996` | 44,0 s | 41,4 s | −5,9 % |
| `dev-1993` | 41,8 s | 39,7 s | −5,0 % |
| `poweruser-1993` | 42,7 s | 40,7 s | −4,7 % |
| `secretaire-1993` | 36,0 s | 34,6 s | −3,9 % |
| `gamer-1993` | 29,5 s | 28,4 s | −3,7 % |

Conséquence directe : la part du calcul dans un démarrage passe de 29–52 % à
30–64 %. Le plancher n'a pas bougé ; c'est le disque qui a cessé de payer un
tour qu'il ne devait pas.

**F1 révèle ce que la passe de 95 valait vraiment.** Six des douze volumes FAT
changent de résultat, et deux basculent complètement : sur `gamer-1993` et
`gamer-1996`, pleins à 99 %, l'outil de 95 n'évacue plus que deux occupants
avant d'être bloqué partout, et rend le volume intact. Ses anciens 438 → 3
fichiers fragmentés sur `gamer-1996` étaient achetés en écrivant sur des
données vivantes.

| volume | morceaux restants, avant → après | trous libres, avant → après |
|---|---:|---:|
| `dev-1996` | 416 → 2 258 | 496 → **131** |
| `dev-1999` | 3 → 1 332 | 24 → 232 |
| `famille-1999` | 52 → 2 511 | 330 → 387 |
| `gamer-1999` | 13 → 818 | 21 → 97 |
| `gamer-1993` | 0 → 942 | 241 → **4** |
| `gamer-1996` | 20 → 1 601 | 359 → **1** |

Les deux lectures sont vraies en même temps : la passe laisse plus de morceaux,
et **beaucoup moins de trous**. Le « 347 avant, 496 après » de `dev-1996`, qui
était le symptôme, devient 347 → 131. La bitmap ne perd plus le compte.

**F3 est le changement le plus lourd du lot, et ce n'était pas prévu.** Le
curseur système qui repartait du début tassait les fichiers système en tête de
volume et laissait le reste étrangement propre. Sur `famille-2003`, le taux de
fichiers fragmentés passe de **1,8 % à 11,1 %** — dans la direction de la cible
du cahier des charges, qui est de 40 à 60 %. Le test
« Le même usage fragmente trois fois plus sur FAT32 que sur NTFS » mesurait donc
un facteur douze qui n'était pas mérité ; il en mesure deux, et son titre suit.
Le facteur n'a pas été élargi pour que le modèle y entre : c'est la valeur
mesurée, et la raison est dans le docstring.

**F4 divise par neuf le morcellement de la MFT de `dev-2003`** sans rien coûter
à la génération (1,0 s en release, inchangé).

### Le README

Toutes les tables mesurées ont été régénérées d'un seul jeu de mesures — vingt
démarrages, et vingt volumes croisés avec les treize outils, en release et en
`PLAN_ONLY` — parce que la moitié d'entre elles avaient déjà dérivé **avant** ce
chantier : `dev-1996` y était donné plein à 87 % quand le générateur le remplit
à 95 %, et sa passe de 95 à 36 min 21 quand elle en durait 48. Une table à moitié
fraîche aurait été pire qu'une table périmée. C'est exactement le défaut que les
trois revues signalent, et il vaut pour ce journal comme pour le reste : les
chiffres ci-dessus sont ceux du commit qui les porte.

### Laissé ouvert

- **La dérive de calibration n'est pas compensée** : les vingt démarrages sont
  sous leur cible de 4 à 21 %, et `ThinkModel` n'a pas bougé. C'est le lot 3 qui
  recalera, une fois le montage et l'arrondi au cluster corrigés — les trois
  changements touchent la même durée, et la recaler trois fois reviendrait à
  cacher les deux suivants dans la première.
- **`InstallEra.writeRequestSectors` n'a pas été plafonné**, bien que ce soit
  maintenant possible : c'est un autre lot.
- **La passe de 95 ne fait plus rien sur les deux volumes à 99 %.** C'est
  correct — un volume dont l'espace libre ne loge pas le plus gros fichier ne se
  compacte pas par cet algorithme-là — mais ce n'est pas tout ce que faisait
  `DEFRAG.EXE`, qui déplaçait par tronçons plutôt que par fichiers entiers.
  `LEDGER-EXPERTS.md` range la question au lot 5 (« évacuer vers le fond du
  volume dans `Windows95Strategy`, ou assumer le facteur 12 ») ; elle y reste.
- **L'audit d'allocation a trouvé un second cas, hors lot.** Sur un volume
  construit à la main, un fichier déplacé de deux clusters vers l'avant avec un
  tampon de soixante-quatre écrit sur ses propres clusters avant de les avoir
  lus. Aucun volume de la galerie ne le déclenche — l'audit passe sur les treize
  plans aux deux remplissages — mais c'est une propriété de
  `DefragOperations.move`, pas de la stratégie qui l'appelle.
- **Le lot 2 reste entier** : `clusterKB` de 1993, `gamer-1999`, `$MFTMirr`,
  `.system`, la commutation de tête. Aucune n'a été touchée, y compris quand
  elle se trouvait trois lignes plus bas.

## Chantier 21 — les huit erreurs de fait du lot 2

**Fait** · branche `experts`

### Le problème

Le lot 1 a corrigé les quatre endroits où le code produisait quelque chose
d'impossible. Celui-ci corrige les huit endroits où il **affirme quelque chose
de faux** — huit points vérifiables contre une source : une table de `FORMAT`,
une fiche technique, la documentation de NTFS. Aucun n'est un arbitrage, aucun
ne demande de trancher : il suffit d'aller lire.

Ils sont triviaux un par un. Leur difficulté est ailleurs — trois d'entre eux
changent la taille des clusters ou la place des fichiers système, donc
**regénèrent des volumes entiers**, et avec eux tous les chiffres du dépôt.

| | où | ce qui était faux | la source qui tranche |
|---|---|---|---|
| E1 | les trois JSON de 1993 | `clusterKB: 8` sur 170 et 210 Mo | table de `FORMAT` : 128–256 Mo → 4 Ko. `FAT16Profile.forVolume`, interrogé, répondait déjà 4 |
| E2 | `gamer-1999` | 8 400 Mo en clusters de 4 Ko | table FAT32 : au-delà de 8 Gio → 8 Ko. 8 400 Mo = 8,20 Gio |
| E3 | `NTFSAllocator.init` | `$MFTMirr` de 4 clusters posé à `mftZone.upperBound`, `$Boot` d'un cluster | `$MFTMirr` copie les **quatre premiers enregistrements** de la MFT, soit 4 Ko ; `$Boot` en fait 8 ; la copie du secteur d'amorçage est au dernier secteur du volume |
| E4 | `DiskGenerator.ntfsAllocator` | miroir ramené au début en `>= 2001` | le déplacement accompagne NTFS 3.0, donc Windows **2000** |
| E5 | `FATAllocator.origin(for:)` | `.system` force le cluster 0 même en VFAT et FAT32 | le pilote ne connaît pas la catégorie d'un fichier : il sert son curseur `next-free`, pour tout le monde. Seul le chargeur d'amorçage impose le début du volume |
| E6 | `SeekModel.calibrated(_:trackToTrackMs:)` | commutation de tête mise à l'échelle par le seek **moyen** | une commutation est un basculement électronique suivi d'une micro-correction : elle décroît comme le piste-à-piste, et lui est toujours inférieure |
| E7 | `ScenarioCompiler.installSwapFile` | `WIN386.SWP` à la racine | il vivait dans `C:\WINDOWS` ; c'est `386SPART.PAR` qui était à la racine, et le modèle le place déjà bien |
| E8 | `PartitionGeometry` | 1 secteur réservé en FAT32 | FAT32 en réserve **32** : amorçage sur trois secteurs, `FSINFO`, copie de secours au secteur 6 |

### Les décisions

**E1 et E2 — la règle plutôt que la clé.** Les trois JSON de 1993 perdent leur
`clusterKB`, et avec eux les cinq autres où la clé ne faisait que répéter ce que
la règle donne : `poweruser-1993` et les quatre FAT32 de 1999. `FAT32Profile`
reçoit le `forVolume` que `FAT16Profile` avait déjà — la table de l'outil de
formatage, qui double la taille de cluster à chaque puissance de deux à partir
de 8 Gio — et `resolvedFileSystem` s'en sert quand la description se tait. Huit
descriptions sur vingt ne peuvent donc plus se tromper, parce qu'elles ne disent
plus rien.

**Les huit JSON NTFS gardent leur `clusterKB: 4`**, et c'est une décision, pas un
oubli : il n'existe pas de `NTFSProfile.forVolume`, et retirer la clé ferait
reposer la valeur sur un `?? 4` muet à deux endroits du code plutôt que sur une
règle nommée. Quatre kilo-octets est bien ce que `FORMAT` donne au-delà de
2 Gio ; le test le vérifie contre sa propre table. Écrire cette table dans le
modèle est un autre lot.

**E3 — le miroir derrière `$Boot`, et la MFT derrière le miroir.** « Près du
début » valait `mftZone.upperBound`, c'est-à-dire 12,5 % du volume : 31 Go sur
`dev-2007`, ni au milieu ni près du début, et pile sur le premier cluster où les
données ont le droit d'aller, qu'il coupait en deux. Le miroir est désormais au
cluster 16, là où vivent les premiers métafichiers, et la MFT commence derrière
lui — sans quoi elle buterait dessus au premier paquet et sortirait en deux
extents dès la création. `$Boot` passe à deux clusters, le miroir à un seul.

**La copie du secteur d'amorçage est modélisée là où elle s'entend**, et non
comme des clusters : `scanAccesses` lit maintenant le **dernier secteur du
volume** au montage d'un NTFS. Une course complète du bras, aller et retour,
avant la première lecture de la MFT.

**E5 — `.system` suit le curseur.** `FileCategory.systemCore.hint` vaut
`.system`, et `systemCore` est la catégorie de toutes les DLL, de tous les
pilotes et de tous les fichiers des vagues de mise à jour. Les forcer au
cluster 0 revenait à faire trier au pilote VFAT une population qu'il ne
distingue pas. `.boot` garde sa contrainte — `IO.SYS` au premier cluster libre,
c'est le chargeur d'amorçage qui l'exige —, `.system` rejoint `.normal` : le
cluster 0 pour `fromVolumeStart`, le curseur `next-free` sinon.

**E6 — la commutation dérivée du piste-à-piste.** `referenceShape` la fixe à
2,0 ms et `calibrated` la recopiait telle quelle, mise à l'échelle par le seul
seek moyen. Elle vaut désormais six dixièmes du piste-à-piste, avec pour
plancher le repositionnement fin — une commutation se termine par lui, elle ne
peut pas être plus courte que lui.

| disque | piste-à-piste | commutation, avant | après |
|---|---:|---:|---:|
| Conner CFA170A (1993) | 3,00 ms | 2,13 ms | **1,80 ms** |
| Fireball 1080AT (1996) | 3,00 ms | 1,97 ms | **1,80 ms** |
| Seagate U8 (1999) | 1,50 ms | 1,46 ms | **0,90 ms** |
| Barracuda ATA IV (2001) | 0,95 ms | 1,48 ms | **0,57 ms** |
| Barracuda 7200.7 (2003) | 1,00 ms | 1,39 ms | **0,60 ms** |
| Barracuda 7200.10 (2006) | 1,00 ms | 1,39 ms | **0,60 ms** |
| Barracuda 7200.11 (2008) | 1,00 ms | 1,39 ms | **0,60 ms** |

L'inversion touchait **cinq** des huit fiches, et non six comme l'annonce la
revue : le Seagate U8 de 1999 passait à 1,46 ms pour un pas de piste de 1,50, de
justesse du bon côté. Le reste de la mesure est exact.

**E6 en cachait une seconde, et c'est la plus intéressante.** Depuis le lot 1,
`DriveGeometry.skew(seekModel:)` calcule `head = headSwitchDuration / tour` :
cette durée n'est plus seulement un coût, c'est **la façon dont les pistes sont
décalées les unes par rapport aux autres**. La changer déplace le skew de tête,
donc l'angle auquel chaque secteur passe sous la tête. Sur le Fireball, qui a
quatre têtes, le skew passe de 0,177 à 0,162 tour et une lecture contiguë de
8 Mo — 76 commutations — passe de 6,09 à 6,14 Mo/s. La continuité, elle, ne
bouge pas : c'est la garantie même du skew, et `TrackSkewTests` la vérifie
toujours à 1e-9 près.

### Ce qui valide

- **`swift test` : 341 tests passent** sur les deux cibles (330 avant, onze de
  plus), et `DISKCORE_CALIBRATION=1 swift test --filter Calibration` passe
  avec **trois** problèmes connus au lieu de deux — voir plus bas.
- **Le filet du lot n'est pas un test par correction, c'en est un seul**
  (`Tests/DiskCoreTests/FormatRulesTests.swift`) : pour les vingt scénarios, la
  taille de cluster retenue est comparée à celle que la table de `FORMAT` donne
  pour ce volume et ce système de fichiers. La table du test est **écrite à
  part**, en FAT16, FAT32 et NTFS — deux copies du même calcul ne prouveraient
  rien. E1 et E2 ne peuvent plus être réintroduites, et le corollaire est vérifié
  aussi : imposer la valeur juste donne la même chose que se taire.
- **La commutation de tête** est confrontée au pas de piste sur les huit fiches
  du catalogue, et à sa propre loi : deux disques de même seek moyen et de
  piste-à-piste différent n'ont pas la même commutation.
- **`$Boot` et `$MFTMirr`** sont vérifiés en taille et en position, dans les deux
  époques, et **la bascule à 2000** a son test à elle : aucun scénario embarqué
  ne démarre cette année-là, donc rien d'autre ne la retiendrait.
- **Un fichier `systemCore` ne tombe plus en tête de volume** sur VFAT et FAT32,
  et y tombe toujours sous MS-DOS — le même test, deux `Scan`. Le chargeur
  d'amorçage, lui, a gardé sa contrainte.

### Ce que cela change, mesuré

**E1 et E2 regénèrent quatre volumes.** Les trois disques de 1993 passent à
4 Ko, `gamer-1999` à 8 Ko ; `poweruser-1993`, seul de son époque à mériter ses
8 Ko, ne bouge pas d'un cluster — c'est le témoin du lot.

| volume | clusters | remplissage | slack |
|---|---|---|---|
| `dev-1993` | 26 880 → **53 760** | 74,0 → 69,0 % | 12,4 → **6,0 %** |
| `secretaire-1993` | 21 760 → **43 520** | 90,8 → 88,5 % | 5,3 → **2,8 %** |
| `gamer-1993` | 26 880 → **53 760** | 99,96 → 99,96 % | 1,2 → **0,6 %** |
| `gamer-1999` | 2 150 400 → **1 075 200** | 93,0 → **97,4 %** | 0,10 → 0,18 % |
| `poweruser-1993` | 43 520 | 86,8 % | 2,2 % |

**E5 est le correctif qui déplace le plus de choses**, comme annoncé. Les
fichiers de mise à jour cessent de camper en tête de volume :

| volume | `UPD*.DLL` | position moyenne, avant → après |
|---|---:|---|
| `gamer-1999` (FAT32) | 786 | 1,4 % → **58,2 %** |
| `famille-1999` (FAT32) | 642 | 2,1 % → **56,5 %** |
| `secretaire-1999` (FAT32) | 1 044 | 2,5 % → **47,1 %** |
| `dev-1999` (FAT32) | 1 184 | 2,5 % → **49,5 %** |
| `dev-1996` (VFAT) | 306 | 9,8 % → **63,2 %** |

Conséquence : **la fragmentation des volumes FAT baisse**, parce qu'un mécanisme
qui la fabriquait a disparu. `dev-1999` passe de 658 à 221 fichiers fragmentés,
`secretaire-1999` de 748 à 331, `famille-1999` de 874 à 666, `dev-1996` de 152 à
96. Et la passe de 95 sur `dev-1996`, qui passait son temps à remuer des
fichiers système coincés en tête, tombe de **33 min 59 à 13 min 42**.

**Trois cibles de calibration sont désormais manquées**, au lieu de deux, et
c'est la même cause. `secretaire-1999` visait 15 à 25 % de fichiers fragmentés
et en donnait 13,7 ; il en donne **6,1 %**. Le test le dit en `withKnownIssue`,
comme les deux autres, avec la raison : la fragmentation qu'il mesurait venait
pour partie d'un mécanisme qui n'a jamais existé. Dans la même direction, l'écart
FAT32 / NTFS de `famille-1999` contre `famille-2003` se resserre encore — douze,
puis deux au lot 1, **une fois et demie** aujourd'hui — et le titre du test suit
la mesure, comme au lot précédent. Ce qui manque aux trois est le même, et
`LEDGER-EXPERTS.md` le range au lot 4 : l'allocation incrémentale et
l'entrelacement, c'est-à-dire des fichiers qui se fragmentent **pendant** qu'on
les écrit, et non seulement parce que l'espace libre l'était déjà.

**E3 ne change presque rien aux volumes, et c'est attendu** : quatre clusters
déplacés sur des dizaines de millions. Sur les huit volumes NTFS, le nombre de
fichiers fragmentés bouge de −14 à +9, et la MFT garde ses extents du lot 1
(`dev-2003` 39, `secretaire-2007` 23, `dev-2007` 4). Un seul effet mérite d'être
noté : sur le volume d'essai de `AllocatorComparisonTests`, le décalage de seize
clusters fait manquer sa place à **un** fichier de 22 Mo, qui sort en 339 extents
au lieu de 4. Le taux de fragmentation, lui, ne bouge pas (1,0 %), et le p95
reste à 1 : c'est la moyenne d'extents par fichier qui est dominée par sa queue.
L'assertion qui la comparait à FAT16 tenait par chance ; elle compare désormais
les deux volumes **sans leur pire fichier**, ce que les deux autres assertions du
test disent déjà de la population.

**Les vingt démarrages bougent peu, et dans les deux sens.** Les volumes FAT
s'allongent — les fichiers système ne sont plus groupés en tête, le bras
voyage —, les 1993 raccourcissent avec leurs clusters deux fois plus petits, les
NTFS ne bougent pas. `ThinkModel` n'a **pas** été recalé.

| profil | cible | après lot 1 | après lot 2 | écart à la cible |
|---|---:|---:|---:|---:|
| `dev-2007` | 47,0 s | 36,9 s | 36,9 s | −21,5 % |
| `gamer-2003` | 70,0 s | 56,0 s | 55,8 s | −20,3 % |
| `secretaire-2007` | 41,9 s | 34,0 s | 33,9 s | −19,1 % |
| `dev-2003` | 49,1 s | 40,0 s | 40,1 s | −18,3 % |
| `famille-2007` | 38,3 s | 31,6 s | 31,5 s | −17,8 % |
| `famille-1999` | 66,0 s | 56,3 s | 57,9 s | −12,3 % |
| `secretaire-2003` | 33,8 s | 29,9 s | 29,9 s | −11,5 % |
| `famille-2003` | 28,8 s | 25,7 s | 25,6 s | −11,1 % |
| `dev-1999` | 57,0 s | 49,7 s | 51,1 s | −10,4 % |
| `secretaire-1999` | 56,7 s | 50,8 s | 51,0 s | −10,1 % |
| `gamer-2007` | 29,8 s | 26,9 s | 27,0 s | −9,4 % |
| `secretaire-1996` | 55,4 s | 50,3 s | 50,6 s | −8,7 % |
| `dev-1996` | 58,7 s | 53,5 s | 54,9 s | −6,5 % |
| `dev-1993` | 41,8 s | 39,7 s | 39,2 s | −6,2 % |
| `famille-1996` | 54,4 s | 50,0 s | 51,1 s | −6,1 % |
| `gamer-1999` | 54,8 s | 47,9 s | 51,5 s | −6,0 % |
| `poweruser-1993` | 42,7 s | 40,7 s | 40,2 s | −5,9 % |
| `secretaire-1993` | 36,0 s | 34,6 s | 34,0 s | −5,6 % |
| `gamer-1993` | 29,5 s | 28,4 s | 28,0 s | −5,1 % |
| `gamer-1996` | 44,0 s | 41,4 s | 43,0 s | −2,3 % |

La dérive tient maintenant entre **2,3 et 21,5 %** sous la cible, contre 3,7 à
21,5 après le lot 1 : E5 travaille dans la direction du recalage sur les volumes
FAT, sans rien y ramener. Elle n'est **pas** compensée ; c'est le lot 3 qui
recalera, une fois le montage et l'arrondi au cluster corrigés.

### Le README

Régénéré d'un seul jeu de mesures, comme au chantier 20 : les vingt démarrages,
les cinq installations, les quatre journées et les vingt volumes croisés avec les
treize outils, en release et en `PLAN_ONLY` — deux minutes trente avec
`xargs -P 6`. Trois cent cinq mesures, aucune table à moitié fraîche.

Un paragraphe y a été **réécrit et non rafraîchi** : « Le scénario de
défragmentation » décrivait encore le volume fixe d'avant le chantier 19 — un
FAT16 de 180 Mo sur le Fireball, 504 fichiers — alors que la démo tourne sur
`dev-1993` depuis. La dérive était antérieure à ce lot ; la laisser à côté de
tables fraîches aurait été pire.

**Un coup d'œil au simulateur, pour E1.** `dev-1993` porte la démo de
défragmentation de l'accueil, choisie au chantier 19 parce que « sa carte est
assez petite pour qu'un bloc d'écran vaille 22 clusters ». Ses clusters ayant
été divisés par deux, ce compte a doublé : l'app affiche « 1 bloc ≈ 43
clusters = 172 Ko ». La carte reste parfaitement lisible — les bandes de
catégories, la frontière qui descend, les trous — et aucun bilan ne l'aurait dit.

### Laissé ouvert

- **La dérive de calibration n'est toujours pas compensée**, et elle a bougé :
  de 2,3 à 21,5 % sous la cible. Le recalage reste au lot 3, une seule fois,
  après le montage et l'arrondi au cluster — la recaler trois fois reviendrait à
  cacher les deux corrections suivantes dans la première.
- **`NTFSProfile` n'a pas de `forVolume`**, et les huit descriptions NTFS gardent
  donc leur `clusterKB: 4`. Le test porte la table ; le modèle, non.
- **Le piste-à-piste du Fireball reste à 3,0 ms**, la même valeur ronde que le
  Conner de 1993, que `DISK_EXPERT_REVIEW.md` §3.2 donne pour suspecte. La
  commutation de tête en dérive désormais, donc cette constante pèse plus
  qu'avant — et elle reste à vérifier sur fiche. C'est la seule des quatre
  questions « à trancher sur source » que ce lot ait rendue plus pressante.
- **Le fichier de 22 Mo en 339 extents** du volume d'essai n'a pas été creusé :
  c'est un fichier ordinaire qui n'a pas trouvé sa place à 80 % de remplissage et
  qui est parti en miettes, comportement documenté de `scatter`. Aucun volume de
  la galerie ne le montre.
- **Rien d'autre n'a été corrigé** : `ProfileSpec.clusterCount` ignore toujours
  la surcharge de format, le montage lit toujours FAT2, la MFT n'a toujours pas
  de `$LogFile`, et l'allocation reste d'un seul tenant.

## Chantier 22 — le lot 3, et le recalage qu'il fallait

**Fait** · branche `experts`

### Le problème

Les lots 1 et 2 ont corrigé ce que le code faisait d'impossible et ce qu'il
affirmait de faux. Tous deux ont refusé de toucher à `ThinkModel`, pour ne pas
cacher leurs corrections les unes dans les autres, et ils ont laissé les vingt
démarrages **de 2,3 à 21,5 % sous leur cible**. Ce lot réunit ce qui, dans les
trois revues, change encore une durée de démarrage — le montage, la granularité
de lecture, le journal de NTFS, la date de dernier accès — puis recale, une
fois.

| | où | ce qui était faux | mesuré avant |
|---|---|---|---|
| M1 | `PartitionGeometry.scanAccesses`, lu au montage | FAT1 **et** FAT2 lues entières au montage ; FAT2 n'est lue que si FAT1 est illisible, et VFAT met la table FAT32 en cache à la demande | `gamer-1999` : 2 × 4,3 Mo de table lus avant le premier fichier |
| M2 | même endroit, NTFS | 2 Mo de MFT d'un trait, par une formule sans sens physique | un seul transfert contigu là où le montage réel touche `$Boot`, les seize premiers enregistrements, `$MFTMirr`, `$Bitmap` et le fond du disque |
| M3 | `BootPlanner.emitData` | toute lecture arrondie au **cluster** | lire 2 Ko sur `dev-1996` émet 32 Ko |
| M4 | `NTFSAllocator.systemExtents`, `commitAccesses` | pas de `$LogFile` ; l'en-tête de `VolumeFormat` en conclut que le bras ne revient jamais au bord sur NTFS | l'installation et la journée écrivaient « le journal » sur le premier cluster de la MFT |
| M5 | `BootSession` | aucune date de dernier accès ; `writeBack` réécrit des **données**, au même endroit que la lecture | 2003 et 2007 ne diffèrent que par le préchargeur et les budgets |
| chaîne | `BootPlanner` | sans table FAT32 lue au montage, plus rien ne la lit : le commentaire d'`openAccesses` la dit en mémoire, ce qui est vrai de FAT16 et faux de FAT32 | — (conséquence de M1) |

### Les décisions

**M1 — le montage n'est pas l'analyse.** `scanAccesses` servait deux lecteurs :
le démarrage et l'analyse initiale d'un défragmenteur. Le second a besoin de
chaque cluster, et lit donc bien toute la table ; le premier non. Le montage a
maintenant ses accès à lui (`mountAccesses`), et l'analyse garde les siens :
aucune passe de défragmentation ne change d'un octet, ce qui est vérifié plus
bas. Sur FAT16, le montage lit l'amorçage, la **première** table entière — au
plus 128 Ko, et c'est ce qui fonde l'affirmation, jugée juste par la revue,
qu'un fichier fragmenté ne coûte là aucun retour à la table — et la racine. Sur
FAT32 : l'amorçage et `FSINFO`, qui donne le compte des clusters libres
précisément pour que le pilote n'ait pas à parcourir la table, le premier
secteur de table (l'état du volume), et le premier cluster de la racine. **De
5,5 à 9,5 Ko** selon la taille de cluster, contre 8,6 Mo sur `gamer-1999`.

**M1 appelait la moitié de l'option, et c'est elle qui pèse le plus.** Une
table qu'on ne lit plus au montage doit être lue quelque part. Le pilote la
charge par pages de 4 Ko — 1 024 entrées FAT32 — au fil des chaînes qu'il
suit : chaque requête de données d'un démarrage FAT32 demande d'abord la page
de table qui décrit ses clusters, si elle n'a pas encore été lue. **Une page lue
reste en cache pour tout le démarrage** : c'est le seul choix qui n'invente pas
de taille de cache, et il minore les retours. Le suivi de chaîne tel que la
revue le décrit — des **retours périodiques** vers la table pendant la lecture
d'un fichier fragmenté, parce que VCACHE évince — demande une éviction, donc
une taille de cache, et ce cache-là n'existe dans aucun lot. Il n'est pas fait.

**M2 — trois zones, peu de transfert.** Le montage NTFS lit `$Boot` (8 Ko), la
copie du secteur d'amorçage au dernier secteur du volume (posée au lot 2), les
seize premiers enregistrements de la MFT, les quatre de `$MFTMirr`, la zone de
redémarrage de `$LogFile` (M4) et la première page de `$Bitmap` : 40,5 Ko. Pour
que ces lectures tombent là où le générateur a posé les fichiers, la règle de
placement est sortie de `NTFSAllocator.init` en une fonction publique
(`NTFSAllocator.layout`) que `PartitionGeometry` appelle aussi, avec l'époque
que `DiskGenerator.mirrorPlacement(for:)` lui passe. La MFT du simulateur, qui
était posée au cluster 0, sur `$Boot`, suit donc enfin celle du générateur.

**M3 — la page, pas le cluster.** Le cluster est l'unité d'allocation, pas de
lecture. Une lecture de démarrage est arrondie à la page de 4 Ko du cache de
Windows, et au secteur sous MS-DOS (`Era.readGranularity`). L'amplification est
bornée par une page, et ne dépend plus de la taille de cluster. `SMARTDRV`, que
le démarrage de 1993 charge, lisait par éléments de 8 Ko et anticipait :
c'est du cache, hors lot.

**M4 — le journal, groupé.** `$LogFile` est posé au formatage derrière
`$MFTMirr`, comme le fait `mkntfs`, qui reproduit la disposition de Windows :
en tête depuis Windows 2000 — la MFT le suit —, au milieu du volume avant. Sa
taille est celle de `mkntfs` : 64 Mio à partir de 12 Gio, ce que tous les NTFS
de la galerie dépassent. Il entre dans `systemExtents`, et dans
`commitAccesses` : **une validation sur huit** écrit la page de journal que les
huit ont remplie, la page suivante à chaque fois, en boucle sur le fichier.
Huit, c'est un demi-kilo-octet d'enregistrements *redo*/*undo* par validation
dans une page de 4 Ko — un ordre de grandeur, et c'est lui qui fixe le rythme
des rafales. La page entamée part en fin de passe, avant les tables, comme le
veut l'écriture anticipée. Le rang de la validation est tenu par
`OperationSink`, parce que le journal avance avec les validations de la passe,
quelle que soit la stratégie qui les produit. L'installation et la journée
gardent leur écriture de journal **par vidage** — c'est leur *lazy writer* qui
groupe, au rythme de son cache —, mais elle tombe maintenant dans le journal et
non sur la MFT, et elle avance d'une page à chaque fois. Le montage déclare le
volume en service dans la zone de redémarrage.

L'en-tête de `VolumeFormat` est réécrit : sur NTFS, en lecture, le bras n'a
aucune raison de revenir au bord ; en écriture, il y revient par rafales
espacées. `$Bitmap` était déjà dans `commitAccesses` ; il n'a pas été touché.

**M5 — la date de dernier accès, ailleurs que la lecture.** Sous NT jusqu'à XP,
toute lecture réécrit `LastAccessTime` dans l'enregistrement de MFT ; VFAT a le
même champ depuis Windows 95, dans l'entrée de répertoire ; MS-DOS ne l'avait
pas, Vista l'a éteint. Les deux ne réécrivent la date que si elle a changé —
NTFS ne descend pas sous l'heure, FAT ne note que le jour —, ce qui est toujours
le cas au premier démarrage de la journée, et jamais à un redémarrage
d'installation (`firstOfTheDay: false`). Les secteurs salis sont écrits par le
même cache que pendant une installation — toutes les trois secondes sous
Windows 9x, toutes les secondes sous NT —, triés et fusionnés, sur une horloge
qui est le temps de calcul : elle minore le temps réel, les vidages sont un peu
plus espacés qu'en vrai. Le modèle suppose, **sans source qui le tranche**, que
NTFS ne journalise pas une simple date.

`writeBack` n'a pas été remplacé : il réécrit des ruches, des journaux
d'application, un fichier de préchargement — de vraies données, qui se
réécrivent bien là où on les a lues. C'était le bon crochet, pas le même
mécanisme.

### Ce qui valide

- **`swift test` : 349 tests passent** sur les deux cibles (341 avant), et
  `DISKCORE_CALIBRATION=1 swift test --filter Calibration` passe avec ses
  **trois** problèmes connus, les mêmes, tous de fragmentation.
- **`MountAndJournalTests`**, sept tests, chiffrés en octets et en positions
  plutôt qu'en durées — parce que le recalage pourrait garder un total juste
  sur un mécanisme faux :
  - sur les quatre FAT32 de la galerie, le montage lit entre 4 et 16 Ko, et
    **aucun accès ne touche FAT2** ; l'analyse du défragmenteur lit toujours les
    deux tables ;
  - sur FAT16, la première table entière, pas la seconde ;
  - sur `dev-2003` et `famille-2007`, le montage NTFS tient sous 64 Ko, aucun
    accès ne dépasse 16 Ko, et ses accès se rangent en **exactement trois
    zones** — le dernier secteur du volume en est une ;
  - le journal que lit le simulateur est l'extent que le générateur a posé, et
    aucun fichier du catalogue n'est dessus ;
  - lire 2 Ko émet 8 secteurs sous Windows, 4 sous MS-DOS, et de 1 à 200 000
    octets l'excès reste sous une page ;
  - **cent validations NTFS donnent treize écritures de journal**, à treize
    endroits différents, et trois écritures par validation sur FAT.
- **« 2003 horodate ses accès, 2007 non »** (`BootSessionTests`) : le même
  volume réduit de `secretaire-2003`, démarré sous XP, réécrit la date de
  chaque fichier lu en quatre fois moins d'écritures ; sous Vista, aucune ; en
  redémarrage d'installation, aucune. C'est le seul filet de cet écart
  d'époque : aucun total ne le verrait disparaître, le recalage l'absorberait.
- **Les passes FAT n'ont pas bougé d'un octet** : les 156 bilans des douze
  volumes FAT croisés avec les treize outils sont identiques avant et après.
  C'est la vérification de la séparation montage / analyse.
- **Un coup d'œil au simulateur** (iPhone 17 Pro Max, iOS 26.5) : la démo de
  démarrage de l'accueil tourne sur `secretaire-1999`, un FAT32, c'est-à-dire
  le volume que M1 et le suivi de chaîne touchent le plus. Elle se joue jusqu'au
  bout et son bilan affiche **57 s, dont 31 s de calcul et 16 s de disque** —
  les chiffres du rendu hors-ligne (56,7 s, 30,8 s).

### Ce que cela change, mesuré — correction par correction

Chaque colonne est l'écart à la précédente, en secondes, sur les vingt
démarrages, chaque correction mesurée seule avant la suivante, toutes en
release et en `PLAN_ONLY`.

| profil | cible | lot 2 | M1 | M2 | M3 | M4 | M5 | chaîne | recalé | écart |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `dev-1993` | 41,8 | 39,2 | −0,1 | 0 | −0,1 | 0 | 0 | 0 | 41,8 | +0,0 % |
| `gamer-1993` | 29,5 | 28,0 | 0 | 0 | −0,1 | 0 | 0 | 0 | 29,1 | −1,4 % |
| `poweruser-1993` | 42,7 | 40,2 | 0 | 0 | −0,3 | 0 | 0 | 0 | 42,8 | +0,2 % |
| `secretaire-1993` | 36,0 | 34,0 | 0 | 0 | −0,2 | 0 | 0 | 0 | 36,0 | +0,0 % |
| `dev-1996` | 58,7 | 54,9 | 0 | 0 | −0,7 | 0 | +0,6 | 0 | 58,7 | +0,0 % |
| `famille-1996` | 54,4 | 51,1 | 0 | 0 | −0,2 | 0 | +0,5 | 0 | 54,9 | +0,9 % |
| `gamer-1996` | 44,0 | 43,0 | 0 | 0 | −0,6 | 0 | +0,5 | 0 | 45,3 | +3,0 % |
| `secretaire-1996` | 55,4 | 50,6 | 0 | 0 | −0,2 | 0 | +0,6 | 0 | 54,5 | −1,6 % |
| `dev-1999` | 57,0 | 51,1 | −0,7 | 0 | 0 | 0 | +0,3 | +3,7 | 56,9 | −0,2 % |
| `famille-1999` | 66,0 | 57,9 | −0,8 | 0 | 0 | 0 | +0,6 | +2,3 | 63,0 | −4,5 % |
| `gamer-1999` | 54,8 | 51,5 | −0,3 | 0 | −0,1 | 0 | +0,7 | +2,2 | 56,8 | +3,6 % |
| `secretaire-1999` | 56,7 | 51,0 | −0,4 | 0 | 0 | 0 | +0,3 | +3,3 | 56,7 | +0,0 % |
| `dev-2003` | 49,1 | 40,1 | 0 | 0 | 0 | −0,1 | +0,1 | 0 | 50,1 | +2,0 % |
| `famille-2003` | 28,8 | 25,6 | 0 | 0 | 0 | +0,2 | +0,2 | 0 | 29,3 | +1,7 % |
| `gamer-2003` | 70,0 | 55,8 | 0 | 0 | 0 | −0,2 | +0,4 | 0 | 69,0 | −1,4 % |
| `secretaire-2003` | 33,8 | 29,9 | 0 | 0 | 0 | 0 | +0,2 | 0 | 35,2 | +4,1 % |
| `dev-2007` | 47,0 | 36,9 | 0 | 0 | 0 | −0,1 | 0 | 0 | 46,0 | −2,1 % |
| `famille-2007` | 38,3 | 31,5 | 0 | +0,1 | 0 | −0,2 | 0 | 0 | 38,0 | −0,8 % |
| `gamer-2007` | 29,8 | 27,0 | 0 | +0,1 | 0 | −0,1 | 0 | 0 | 31,1 | +4,4 % |
| `secretaire-2007` | 41,9 | 33,9 | 0 | 0 | 0 | 0 | 0 | 0 | 41,6 | −0,7 % |

Ce que dit chaque colonne :

- **M1 raccourcit les quatre FAT32**, de 0,3 à 0,8 s, et leur retire 9 à 14 Mo
  de lecture. Moins qu'annoncé : 8,6 Mo de table se lisent d'un trait, au débit
  de la piste, et la seconde et demie de la revue supposait un disque plus lent.
- **M2 ne change aucune durée au dixième**, et c'est le résultat : 2 Mo de
  transfert en moins, deux seeks de plus par démarrage NTFS. Même temps,
  profil inverse — ce qui s'entend et ne se chronomètre pas.
- **M3 raccourcit les volumes à gros clusters** : de 0,2 à 0,7 s sur ceux de
  1996 (16 et 32 Ko), 0,1 à 0,3 s sur 1993 (lecture au secteur), rien au-delà
  (clusters de 4 Ko, déjà la page).
- **M4 ne bouge les démarrages que de ±0,2 s** : un démarrage ne valide presque
  rien. Sa variation vient surtout de ce que les huit volumes NTFS sont
  **régénérés** — 64 Mo en tête décalent la MFT et tout ce qui suit.
- **M5 allonge les FAT de 1996 et 1999** de 0,3 à 0,7 s, **XP** de 0,1 à 0,4 s,
  et ni MS-DOS ni Vista : 10 à 36 seeks de plus par démarrage, vers les
  répertoires ou la MFT. `gamer-2003` réécrit 912 dates en 26 écritures.
- **La chaîne FAT32 est la plus lourde du lot** : de 2,2 à 3,7 s et 165 à 270
  seeks de plus sur les quatre FAT32, pour 151 à 254 pages de table lues à la
  demande. Le témoin des FAT32 passe de +7 à +10 % : la fragmentation coûte
  plus quand chaque saut d'extent peut renvoyer le bras à la table. C'est le
  va-et-vient qu'on prêtait aux Windows 98 fatigués, **avant éviction**.

Avant recalage, la dérive était de −6,3 % (1993), −5,8 % (1996), −5,1 % (1999),
−16,2 % (2003) et −17,8 % (2007) en somme par époque. M1 à M5 s'y compensent
presque ; la chaîne FAT32 referme la moitié de l'écart de 1999 ; celui de 2003 et
2007 reste entier — c'est celui du lot 1.

### Le recalage

**Ce qui manquait était proportionnel aux mégaoctets, pas aux fichiers.** Avec
deux constantes par époque, le temps de calcul d'un démarrage est
`perFile × fichiers + perMegabyte × Mo lus`. En ajustant l'une ou l'autre seule
sur les quatre profils de chaque époque, les résidus disent laquelle avait
absorbé les défauts : en 2003, ±1,3 s en ne touchant que `perMegabyte`, ±3,4 s en
ne touchant que `perFile` ; en 2007, ±1,4 s contre ±3,8 s ; en 1993, ±0,2 s
contre ±0,4 s. Pour 1996 et 1999 les deux se valent — l'écart y est petit. C'est
la signature de F2 : un tour de plateau perdu **par requête** d'une lecture
contiguë, donc payé au mégaoctet, et d'autant plus que le disque est rapide et
la lecture longue. Le premier calage l'avait rangé dans le coût de calcul par
mégaoctet. **Seul `perMegabyte` bouge** ; `perFile` décrit toujours ce qu'il
décrivait.

| époque | `perFile` | `perMegabyte`, avant → après | somme des quatre démarrages / cible |
|---|---:|---:|---:|
| MS-DOS et Windows 3.1 | 0,045 | 0,60 → **0,80** | 149,7 / 150,0 s |
| Windows 95 | 0,022 | 0,34 → **0,41** | 213,4 / 212,5 s |
| Windows 98 SE | 0,015 | 0,22 → **0,25** | 233,4 / 234,5 s |
| Windows XP | 0,009 | 0,13 → **0,19** | 183,6 / 181,7 s |
| Windows Vista | 0,009 | 0,09 → **0,15** | 156,7 / 157,0 s |

Les vingt démarrages tiennent entre **−4,5 et +4,4 %** de leur cible, chaque
époque à 1 % près en somme. Le reste est la dispersion entre profils d'une
même époque, qu'une constante par époque ne peut pas suivre et ne doit pas
suivre.

**Ce qui a changé dans la description** : `perMegabyte` était « décompression et
relocalisation, plus un défaut du disque qu'on ne voyait pas » ; il n'est plus
que la première moitié. La part du calcul dans un démarrage monte en
conséquence, de 30–65 % à **34–71 %** : le disque fait moins, parce qu'il ne
perd plus de tour, et le plancher processeur porte ce qu'il portait vraiment.

**Ce que la cible seule justifie, et qu'il faut dire.** La décroissance de
1993 à 1999 suit à peu près les processeurs. Celle de 2003 à 2007 non : 0,19
puis 0,15 s par mégaoctet, un gain de 20 % là où les processeurs ont été
multipliés par trois ou quatre. Rien dans la description n'explique ce 0,15 —
sinon que Vista initialise bien plus de choses par mégaoctet chargé, ce que
personne ici n'a mesuré. C'est une valeur tirée de la cible, et les cibles
elles-mêmes sont les durées que le modèle donnait avant la relecture, non des
mesures d'époque : le docstring de `ThinkModel` promettait « une bonne minute
pour un Vista » quand les quatre démarrages de 2007 visent 30 à 47 s. La phrase
a été retirée plutôt que corrigée.

**Le recalage est en un seul endroit** : `ThinkModel.boot(_:)`, une table de
cinq lignes qui porte chacune sa valeur d'avant en commentaire. Les époques de
`BootScript.Era` ne portent plus de `ThinkModel` en propre ; elles le lisent là.

**Un effet de bord à connaître** : l'horloge des vidages de dates d'accès est
le temps de calcul, que le recalage allonge. Le regroupement change donc un peu
avec lui — quelques seeks, dans un sens ou dans l'autre, sur les FAT de 1996 et
1999. Ce n'est pas un réglage, c'est la minoration de l'horloge qui se
réduit.

### Au-delà des démarrages

- **Les installations** bougent de 0 à 0,5 % avant recalage, et de 0,1 à
  5,5 % en tout après : leurs redémarrages sont de vrais démarrages, et portent le nouveau
  plancher. `famille-2003` passe de 8 min 12 à 8 min 39. Le journal y est
  désormais écrit dans `$LogFile`, une page de plus à chaque vidage, au lieu du
  premier cluster de la MFT.
- **Les journées** s'allongent d'autant que leur démarrage : `famille-2003`,
  jour 400, de 1 min 26 à 1 min 38.
- **Les passes NTFS changent surtout parce que les volumes changent.** Pour
  isoler le journal, la même version a été mesurée avec et sans écriture de
  `$LogFile` dans les validations : XP, UltraDefrag, JkDefrag et le recollage
  économe s'allongent de **0 à 2,3 %** sur les huit volumes, avec exactement
  une écriture de journal par huit validations. Le reste — de −28 à +55 % selon
  l'outil et le volume — est la régénération : `famille-2003` passe de 450 à 382
  fichiers fragmentés, `gamer-2007` de 290 à 334, et la passe de XP sur
  `famille-2007` tombe de 28 min 54 à 20 min 43.
- **La table de comparaison des allocateurs** (même histoire sur trois
  formats) : le pire fichier NTFS passe de 339 à 138 extents, et le nombre de
  trous de 293 à 441. Le fichier de 22 Mo en 339 extents du chantier 21 a trouvé
  un autre trou, sur un volume d'essai plus petit de son journal.

### Le README

Régénéré d'un seul jeu de mesures : les vingt démarrages, vingt installations,
les quatre journées et les vingt volumes croisés avec les treize outils, en
release et en `PLAN_ONLY`, avec le binaire du commit — plus les seize passes NTFS
de XP et UltraDefrag en blocs pleins. Le générateur des tables a d'abord été
validé en reproduisant au chiffre près le README d'avant à partir des mesures
d'avant. Les tables FAT de défragmentation n'ont pas été réécrites : leurs bilans
sont identiques.

Deux chiffres de prose étaient **déjà périmés avant ce lot**, et ont été
remesurés plutôt que recopiés : le gain du préchargeur sur `famille-2007`
(« 105 289 à 34 974 cylindres », en fait 49 142 à 22 652 aujourd'hui, mesuré en
retirant le préchargeur à Vista dans un binaire jetable), et les requêtes d'un
démarrage de `dev-1996` (1 115 annoncées, 1 091 avant ce lot, 1 121 après).
Trois ne l'ont pas été, faute d'outil qui les produise : les 249 Go et 187 000
miettes de moins de 4 Mo (12 Go) de `famille-2007`, et le trou de 22 Go de
`dev-2007`. 64 Mo de journal ne les déplacent pas à cette précision, mais ils
ne viennent pas de ce jeu de mesures.

### Laissé ouvert

- **Le cache disque et la lecture anticipée rouvriront ce recalage.** Ils ne
  sont dans aucun lot, l'expert disque les classe troisièmes, et c'est le
  mécanisme qui masquait sur un vrai disque le tour perdu du lot 1 : quand ils
  arriveront, tout le séquentiel raccourcira encore, et `ThinkModel.boot` sera
  à recaler une seconde fois. C'est une décision : recaler maintenant, en un
  seul endroit, plutôt que laisser vingt démarrages faux jusque-là.
- **Le suivi de chaîne FAT32 n'évince rien.** Les pages de table lues restent
  en cache pour tout le démarrage : c'est un minorant. Les retours périodiques
  d'un Windows 98 fatigué demandent une taille de cache — même lot que
  ci-dessus.
- **Les trois cibles manquées de `CalibrationTests` n'ont pas bougé** : ce sont
  des taux de fragmentation, `ThinkModel` n'a aucune prise dessus, lot 4.
  `famille-2003` s'en éloigne un peu en se régénérant (450 → 382 fichiers
  fragmentés).
- **L'analyse du défragmenteur lit toujours FAT2.** Elle a besoin de toute la
  table ; qu'elle compare les deux copies, comme `SCANDISK`, ou non, n'a pas
  été tranché sur source.
- **L'installation et la journée arrondissent toujours au cluster**
  (`MachineWriter.transfer`, `InstallSession.readWhole`). M3 ne portait que sur
  le démarrage ; c'est la même erreur ailleurs, et elle n'a pas été touchée.
- **Le modèle de volume garde deux approximations NTFS** : `$Bitmap` est posé à
  12,5 % du volume, derrière la zone MFT, là où le générateur met des données ;
  et le rang d'un fichier dans l'ordre de lecture sert toujours de numéro
  d'enregistrement de MFT (`FILESYSTEM_EXPERT_REVIEW.md` §7).
- **Que NTFS ne journalise pas la date d'accès** est une hypothèse.
- **Rien d'autre n'a été corrigé** : `ProfileSpec.clusterCount` ignore toujours
  la surcharge de format, `NTFSProfile` n'a pas de `forVolume`, l'allocation
  reste d'un seul tenant, les répertoires n'existent pas.

## Chantier 23 — le lot 4 : écrire sans connaître la taille, et les répertoires

**Fait** · branche `experts`

### Le problème

`LEDGER-EXPERTS.md` range au lot 4 les deux manques structurels que deux
relectures voyaient depuis deux étages. Le premier : **tout fichier naît d'un
seul tenant**. `Allocator.place` alloue chaque fichier en un appel, à sa taille
finale, et l'allocateur sert le meilleur trou pour ce total ; un fichier ne peut
donc se fragmenter que si l'espace libre l'était déjà. Le second : **les
répertoires n'existent pas**. `DirectoryRecord` porte un nom, un parent, un
rang, et aucun cluster ; `dev-2003` compte trente répertoires pour 13 951
fichiers, et aucun ne s'écrit jamais.

L'histogramme du nombre d'extents par fichier, régénéré avant le lot dans les
colonnes de `FILESYSTEM_EXPERT_REVIEW.md` §2 (les chiffres de la revue dataient
d'avant les lots 1 à 3) :

| | 1 extent | 2 | 3–4 | 5–16 | 17–64 | > 64 |
|---|---:|---:|---:|---:|---:|---:|
| `dev-2003` | **13 047** | 2 | 0 | 1 | 3 | 34 |
| `dev-1996` | **5 437** | 38 | 15 | 18 | 15 | 10 |

Bimodale et vide au milieu, comme la revue le disait : sur `dev-2003`, trois
fichiers en 2 à 16 morceaux, trente-quatre en plus de 64.

Trois cibles de `CalibrationTests` étaient manquées, toutes de fragmentation,
et le lot 2 désignait ce lot pour les refermer.
### Les décisions — l'allocation incrémentale

**Un booléen, une question de fait.** `FileSpec.sizeKnownInAdvance` répond à
une seule question : *le programme qui écrit ce fichier savait-il quelle taille
il ferait ?* Il vaut `true` par défaut, et chaque endroit du compilateur de
scénario qui crée un fichier le pose pour **le programme** qui l'écrit — jamais
pour la catégorie, jamais pour le volume.

| fichier | programme | taille connue ? | ce que faisait le programme |
|---|---|---|---|
| fichiers d'une installation, archives d'installation, DLL partagées, ruches | l'installeur | oui | il lit la taille de chaque fichier dans le catalogue de ses archives (`.INF`, répertoire du CAB) |
| `UPD*.DLL` | la mise à jour | oui | un installeur, pour la même raison |
| `DATA*.PAK` d'un jeu | l'installeur du jeu | oui | copiés depuis le CD, la taille est sur le CD |
| `386SPART.PAR`, `pagefile.sys`, `hiberfil.sys` | l'installation | oui | posés à taille fixe |
| `WIN386.SWP` | le gestionnaire de mémoire | oui | il décide d'une taille et la demande — création comme croissance |
| `MODULE.C` | l'éditeur | oui | il écrit un tampon qu'il a en mémoire |
| `PROJET.EXE` | l'éditeur de liens | oui | il a calculé l'adresse de chaque section avant d'émettre un octet |
| photos (2003, 2007) | l'assistant d'import | oui | une copie depuis la carte de l'appareil |
| `M*.OBJ`, `VC.PCH` | le compilateur | **non** | il écrit son objet au fil du code qu'il génère |
| `BUILD.ZIP`, archives entassées | le compresseur, le logiciel de gravure | **non** | la taille d'une archive ne se connaît qu'en la finissant ; une image de CD s'écrit au fil de la lecture |
| cache du navigateur, `index.dat` | le navigateur | **non** | il écrit ce qu'il reçoit, un serveur de l'époque n'annonçant pas toujours sa longueur |
| `DOC*.DOC`, et chaque réenregistrement | Word | **non** | il sérialise son document composé au fil de l'écriture |
| `Outlook.pst` | la messagerie | **non** | une boîte qui grossit au fil du courrier |
| `SAVE.DAT` | le jeu | **non** | il sérialise son état |
| MP3, DivX, vidéo de famille | l'encodeur, le téléchargement, la capture | **non** | trois fichiers dont la fin n'est connue qu'à la fin |
| `PART*.RAR`, `DL`, `EXTRAIT` | le téléchargement, le décompresseur | **non** | écrits à mesure qu'ils arrivent, ou qu'on les décompresse |

Les événements qui suivent la création suivent la même logique sans nouveau
drapeau : un **ajout par la fin** (`append`) est toujours écrit par paquets —
personne ne déclare la taille d'un ajout —, sauf celui du fichier d'échange ;
un **réenregistrement par temporaire** l'est toujours, puisque c'est
l'application qui enregistre qui l'écrit.

**Le paquet est une propriété du format** (`FileSystemProfile.writePacketBytes`).
Sur FAT, un cluster : VFAT, comme MS-DOS, prolonge la chaîne à l'écriture qui
franchit la fin du dernier cluster, et un programme écrit par le tampon de sa
bibliothèque C — 4 Ko chez Microsoft, 512 octets sous MS-DOS —, jamais plus
d'un cluster d'un coup. Sur NTFS, 64 Ko : le *lazy writer* vide le cache par
paquets de cette taille et étend l'allocation du fichier à chaque vidage.
`Allocator.stream` écrit ces paquets comme autant d'`extend` successifs, tout
ou rien.

**Sur FAT, un programme seul ne change rien, et c'est vérifié.** Cluster par
cluster, chacun est le premier libre après le curseur, et le curseur est là où
le précédent l'a laissé : c'est exactement ce qu'un `allocate` du total aurait
pris. `FATAllocator.stream` ne fait donc qu'un appel — un test le confronte au
cluster par cluster sur un volume mité — et les 220 bilans FAT de l'étape
`incr` sont identiques à ceux de `base`, texte pour texte. Tout l'effet est sur
NTFS, où chaque paquet qui ne peut pas prolonger le précédent va dans le trou
le plus juste **pour lui**.

### Les décisions — l'entrelacement, écrit et non retenu

Deux programmes qui écrivent en même temps se disputent le curseur. Le
mécanisme est dans `Simulator` : chaque événement porte le **programme** qui
l'écrit (`Program` — installeur, Explorateur, gestionnaire de mémoire,
environnement de développement, navigateur, traitement de texte, messagerie,
médias, téléchargement, jeu, ce qu'on entasse), une journée se joue en
tourniquet sur les programmes, un tour étant un événement entier ou **un
paquet** d'une écriture par paquets, et un programme écrit ses fichiers l'un
après l'autre. Aucun tirage : l'ordre du tourniquet est celui de l'énumération.
Quand tous les programmes occupés sont au milieu d'une écriture par paquets sur
FAT, les tours jusqu'à la fin de la première sont joués d'un bloc
(`Allocator.takeInWritingOrder`) ; les empreintes des vingt volumes sont les
mêmes qu'en jouant les tours un à un. Le rejeu pas à pas (`HistoryReplay`)
passe par le même ordonnanceur, et raconte les événements dans l'ordre où ils
finissent.

**Il n'est pas retenu** : `DiskGenerator.runsProgramsConcurrently` vaut `false`
pour tous les volumes, avec sa raison. Mesuré (étape `entre`), il donnait à tous
les programmes d'une journée **le même débit** et les faisait tourner ensemble
du matin au soir — ni l'un ni l'autre n'est un fait d'époque, et les deux
ensemble alternaient cluster par cluster un compresseur de 40 Mo et un
compilateur. Résultat, sur `dev-1999` : 437 802 morceaux avant la passe contre
12 739, et une passe de Windows 95 de 58 h 09 au lieu de 6 h 16 ;
`secretaire-1999` montait à 32 %, au-dessus de sa fourchette. C'est une borne
haute, comme l'ordre séquentiel est une borne basse ; trancher entre les deux
demande un débit par programme et une heure dans la journée, que la
chronologie n'a pas. Restreindre aux programmes de fond n'aurait pas suffi : un
téléchargement sur modem contre un compilateur s'alternerait encore cluster par
cluster. La décision a été prise avec Gabriel, sur ces mesures.

### Les décisions — les répertoires

**Un répertoire a sa place** : `DirectoryRecord` porte un `FileEntry`, les
octets de ses entrées en service et leur pointe. Il naît au premier nom qu'on y
écrit — c'est là que le programme fait son `mkdir` — et ses parents avant lui,
chacun recevant l'entrée de son enfant. Il ne rend jamais ses clusters : une
entrée effacée resservira, la chaîne ne raccourcit pas.

- **FAT** : un sous-répertoire naît avec un cluster (`.` et `..`), pris au
  curseur comme n'importe quel fichier, et grandit d'un cluster quand ses
  entrées débordent — au curseur, donc loin des précédents. La racine d'un
  FAT16 vit dans sa région fixe et ne prend rien (ses 512 entrées ne sont pas
  bornées) ; celle d'un FAT32 est un fichier, posé au premier cluster.
- **Noms longs** (`DirectoryFormat`) : sous VFAT et FAT32, une entrée de 32
  octets par tranche de treize caractères du nom long, plus celle du nom court,
  dès que le nom n'est pas un nom court valide en majuscules —
  `Rapport trimestriel 1996.doc` en coûte quatre, `index.dat` deux. Sous MS-DOS,
  une.
- **NTFS** : une entrée d'index de 82 octets plus deux par caractère, arrondie à
  huit, et une seconde pour le nom court que XP et Vista génèrent. L'index tient
  dans l'enregistrement de MFT tant qu'il ne dépasse pas la place d'un fichier
  résident (700 octets, le même kilo-octet), puis prend des tampons de 4 Ko. Le
  remplissage partiel d'un arbre B n'est pas modélisé. Un répertoire consomme
  un enregistrement de MFT.
- Word écrit son temporaire à côté du document : une entrée de plus le temps de
  l'enregistrement.

**L'arborescence gagne deux règles, sans tirage.** Internet Explorer range son
cache dans quatre sous-dossiers — `Cache1` à `Cache4` sous IE 3, quatre noms
tirés au hasard sous `Content.IE5` ensuite — et `index.dat` au-dessus d'eux. Un
logiciel d'extraction range chaque disque encodé dans son dossier, l'assistant
d'import de l'appareil photo chaque transfert : un dossier par séance d'import.
Les manifestes d'installation, eux, gardent un dossier par groupe de fichiers.

**Les trois couches.**

1. `VolumeLayout` perd son approximation. La validation d'un déplacement sur
   FAT écrit l'entrée **là où est le répertoire** — `DefragVolume.entrySector`
   la suit même si le répertoire a été déplacé plus tôt dans la passe —, et
   seules les deux copies de la table restent au début du volume. Au démarrage,
   ouvrir un fichier, c'est lire son chemin depuis la racine : sur FAT chaque
   répertoire est parcouru depuis son début jusqu'au cluster qui porte le nom
   suivant, en suivant sa chaîne (et la table sur FAT32), et gardé en cache ;
   sur NTFS seul le tampon d'index qui porte le nom est lu. `openAccesses` ne
   garde que l'enregistrement de MFT. Les journées et les installations écrivent
   l'entrée au bout de son répertoire, là où s'ajoutent les nouvelles.
2. La carte a une catégorie de plus, `ClusterCategory.directory`, en dernier pour
   que les sept autres gardent leur octet, du jaune des dossiers de
   l'Explorateur, nommée « Répertoires » par la légende et par VoiceOver. Les
   répertoires qui grandissent pendant une journée ou une installation sont
   rapportés à part (`SimulationStep.directoryGrew`, `InstallEntry.directoryGrew`)
   pour prendre cette couleur et non celle de la MFT.
3. Les répertoires sont des éléments de défragmentation, juste avant ce qu'ils
   contiennent, sous un identifiant à bit de poids fort
   (`FileCatalog.itemID(ofDirectory:)`). JkDefrag les range en **zone 0** : son
   découpage en trois bandes en est un de nouveau. `GeneratedDisk.rearranged`
   repose aussi leurs places — sans cela, le démarrage d'un disque rangé aurait
   vu libres les clusters des répertoires. La défragmentation de l'histoire
   (`Simulator.defragment`) les tasse avec le reste, chacun devant son contenu.

### Ce qui valide

- **L'histogramme**, l'observable du lot, étape par étape : `base`, `incr`
  (paquets seuls), `entre` (paquets et entrelacement, non retenu), `dirs` (ce qui
  est livré : paquets et répertoires). Traîne = fichiers en 2 à 16 morceaux,
  rapportés aux fichiers de plus d'un cluster.

  | volume | étape | 1 | 2 | 3–4 | 5–16 | 17–64 | > 64 | traîne |
  |---|---|---:|---:|---:|---:|---:|---:|---:|
  | `dev-2003` | base | 13 047 | 2 | 0 | 1 | 3 | 34 | 0,0 % |
  | | incr | 12 979 | 8 | 5 | 37 | 25 | 33 | 0,5 % |
  | | entre | 12 892 | 4 | 1 | 3 | 15 | 172 | 0,1 % |
  | | **dirs** | **12 966** | 13 | 10 | 30 | 30 | 38 | **0,6 %** |
  | `dev-1996` | base | 5 437 | 38 | 15 | 18 | 15 | 10 | 6,1 % |
  | | incr | 5 437 | 38 | 15 | 18 | 15 | 10 | 6,1 % |
  | | entre | 5 378 | 46 | 16 | 33 | 28 | 19 | 8,2 % |
  | | **dirs** | **5 453** | 26 | 20 | 15 | 23 | 4 | **5,3 %** |
  | `secretaire-2003` | base | 8 962 | 47 | 51 | 74 | 34 | 116 | 1,9 % |
  | | incr | 8 233 | 354 | 309 | 225 | 64 | 99 | 9,6 % |
  | | entre | 5 770 | 1 277 | 859 | 563 | 139 | 676 | 29,2 % |
  | | **dirs** | **8 118** | 378 | 299 | 277 | 96 | 116 | **10,3 %** |
  | `gamer-2007` | base | 13 199 | 38 | 47 | 45 | 40 | 164 | 1,0 % |
  | | **dirs** | **12 783** | 197 | 190 | 213 | 54 | 96 | **4,5 %** |
  | `famille-2007` | base | 11 667 | 89 | 93 | 109 | 60 | 211 | 2,4 % |
  | | **dirs** | **11 374** | 167 | 196 | 276 | 99 | 117 | **5,3 %** |

  Sur NTFS, la traîne se remplit et le mode à un extent baisse — de
  `secretaire-2003` (8 962 → 8 118, traîne ×5) à `famille-2007` —, et les
  miettes au-delà de 64 morceaux **diminuent** : un gros fichier écrit par
  paquets trouve des trous à la taille d'un paquet là où, d'un bloc, il n'en
  trouvait aucun à la sienne et partait en `scatter`. Sur `dev-2003`, presque
  rien : les fichiers qu'un programme y écrit sans en connaître la taille — les
  objets du compilateur — font moins de 64 Ko, un seul vidage du cache. Sur FAT,
  rien ne vient des paquets, et ce qui bouge vient des répertoires. **La traîne
  ne se remplit pas là où le lot 2 l'attendait** : c'est l'entrelacement qui la
  remplissait sur FAT (`dev-1996` 8,2 %, `secretaire-1999` 17,3 %), et il n'est
  pas retenu.
- **Le déterminisme** : deux générations de `secretaire-1999` et de
  `secretaire-2003` donnent les mêmes extents, fichier par fichier et répertoire
  par répertoire (`WritingWhileItGrowsTests`). Le bilan d'un volume porte une
  empreinte de toutes ses extents ; elle a aussi servi à prouver que le jeu d'un
  bloc des tours FAT ne change aucun cluster.
- **Les trois cibles de `CalibrationTests` restent manquées**, les mêmes :
  `dev-1996` à 8 % (au lieu de 35 à 50), `secretaire-1999` à 6 % (15 à 25),
  `famille-2003` à 13 % (40 à 60, 9 % avant le lot). C'est l'information du lot :
  écrire sans connaître la taille ne les referme pas ; les refermer demandait
  l'entrelacement, qui dépassait l'une d'elles pour une raison qui n'est pas un
  fait. Un test change de titre, comme aux lots 1 et 2 : l'écart
  `famille-1999` / `famille-2003` tombe d'une fois et demie à **un quart**
  (16,9 contre 13,0 %), parce que NTFS reçoit désormais par paquets ce que FAT
  recevait déjà cluster par cluster.
- **Les répertoires existent et se fragmentent.** 12 à 46 par volume, et 761,
  1 128 et 1 127 sur `famille-1999`, `famille-2003` et `famille-2007` (un par
  séance d'import). Sur `famille-1999`, 12 sont en plusieurs clusters, les 12
  en morceaux ; sur `famille-2007`, le pire en 447 extents — le cache du
  navigateur, un index qui a grandi par tampons de 4 Ko pendant trois ans.
  **« Plusieurs milliers » sur un FAT vieilli n'est pas atteint** : le générateur
  pose 1 000 à 7 500 fichiers sur un volume FAT, là où un vrai Windows 98 en
  porte dix fois plus, et les installeurs y rangent chaque groupe dans un seul
  dossier. Les répertoires manquants sont ceux des fichiers manquants. Un nom
  long VFAT coûte bien ses quatre entrées, et un répertoire FAT de cent noms
  courts, deux clusters en deux morceaux (`WritingWhileItGrowsTests`).
- **`swift test` : 366 tests passent** (349 avant, dix-sept de plus dans
  `WritingWhileItGrowsTests` et `DirectoryItemsTests`), et
  `DISKCORE_CALIBRATION=1 swift test --filter Calibration` passe avec ses trois
  problèmes connus. Cinq tests existants ont été touchés, chacun pour une raison
  qui tient au lot : la carte d'arrivée d'une installation compte les
  répertoires ; le tassage de `RearrangedDiskTests` les range avec le reste ; le
  démarrage rangé passe de `gamer-1993` à `dev-1993`, où la passe de 95 a de
  quoi déplacer (voir plus bas) ; `CellContents` liste les répertoires d'un
  bloc ; `MFTGrowthTests` voit deux MFT de plus déborder (plus bas).
- **Les treize outils sur les vingt volumes** produisent leurs 260 bilans, et
  l'audit d'allocation du lot 1 (`AllocationInvariantTests`) passe sur des
  volumes qui ont maintenant des répertoires. JkDefrag range les répertoires en
  zone 0 (`DirectoryItemsTests`), la validation FAT écrit l'entrée dans le
  répertoire du fichier, et un démarrage de `secretaire-1999` lit ses
  répertoires là où ils sont.
- **Le simulateur n'a pas pu être regardé.** Le build Release de l'app compile
  (les trois fichiers exclus du paquet compris), mais CoreSimulator s'est figé
  sur la machine pendant la session : même Réglages ne s'y lançait plus. La
  légende et la couleur des répertoires n'ont donc pas été vues à l'écran, ni le
  lancement chronométré — le coût des deux démos vient du rendu hors-ligne,
  même code.

### Ce que chaque mécanisme change, mesuré séparément

Chaque étape est un binaire construit depuis le code final, le mécanisme suivant
coupé, sous `Tools/Measure/` ; `base` vient du commit précédent, avec les
outils de mesure de ce lot.

**Les paquets (`base` → `incr`)** : 220 bilans FAT identiques ; sur NTFS, les
démarrages bougent de −0,4 à +0,3 s et les passes de −54 à +122 % selon l'outil
et le volume, médiane 0 — les volumes sont régénérés. Deux zones MFT de plus
cèdent : `famille-2003` (MFT en 31 extents au lieu d'un) et `famille-2007` (18),
dont les médias et les téléchargements, écrits par paquets, prennent chacun le
trou le plus juste pour un paquet et remplissent autrement le reste du volume.

**L'entrelacement (`incr` → `entre`, non retenu)** : ci-dessus. En plus des
morceaux, il rendait quadratique le planificateur du tassage à la frontière —
`physical()` et `vcn()` parcourent les extents d'un fichier à chaque pas — : 30
minutes de calcul pour la passe de `dev-2007`, sur 1 097 059 morceaux.

**Les répertoires (`incr` → `dirs`)** : les démarrages bougent de −0,7 à
+1,1 s ; les passes de −37 à +175 % selon l'outil et le volume, médiane +1 à
+13 % selon l'outil — `jkDefragMoveUp` est le plus touché. Sur la passe de 95,
le seek moyen baisse sur neuf FAT sur douze (`famille-1999` : 2 059 → 1 604
cylindres, `gamer-1999` : 4 709 → 3 571), l'entrée ne renvoyant plus le bras au
bord ; le nombre de seeks, lui, monte là où les répertoires sont des éléments de
plus à ranger (`dev-1996` : 24 820 → 42 304, la passe de 13 min 42 à 21 min 54).
Et `gamer-1993` passe de 99,96 à 100 % : ses répertoires ont pris les cinq
derniers trous, et le tassage à la frontière, qui avait rangé ce volume en
32 minutes avec deux clusters libres, n'en a plus aucun — il le rend tel quel.

**Les démarrages, contre leur cible** (secondes ; `incr` en écart à `base`) :

| profil | cible | base | incr | dirs | écart |
|---|---:|---:|---:|---:|---:|
| `dev-1993` | 41,8 | 41,8 | 0 | 41,8 | +0,0 % |
| `poweruser-1993` | 42,7 | 42,8 | 0 | 42,8 | +0,2 % |
| `gamer-1993` | 29,5 | 29,1 | 0 | 29,4 | −0,3 % |
| `secretaire-1993` | 36,0 | 36,0 | 0 | 35,9 | −0,3 % |
| `dev-1996` | 58,7 | 58,7 | 0 | 58,6 | −0,2 % |
| `famille-1996` | 54,4 | 54,9 | 0 | 54,2 | −0,4 % |
| `gamer-1996` | 44,0 | 45,3 | 0 | 45,2 | +2,7 % |
| `secretaire-1996` | 55,4 | 54,5 | 0 | 54,6 | −1,4 % |
| `dev-1999` | 57,0 | 56,9 | 0 | 58,0 | +1,8 % |
| `famille-1999` | 66,0 | 63,0 | 0 | 63,8 | −3,3 % |
| `gamer-1999` | 54,8 | 56,8 | 0 | 57,0 | +4,0 % |
| `secretaire-1999` | 56,7 | 56,7 | 0 | 57,6 | +1,6 % |
| `dev-2003` | 49,1 | 50,1 | 0 | 50,4 | +2,6 % |
| `famille-2003` | 28,8 | 29,3 | −0,4 | 29,8 | +3,5 % |
| `gamer-2003` | 70,0 | 69,0 | 0 | 69,4 | −0,9 % |
| `secretaire-2003` | 33,8 | 35,2 | −0,3 | 36,0 | +6,5 % |
| `dev-2007` | 47,0 | 46,0 | −0,1 | 46,6 | −0,9 % |
| `famille-2007` | 38,3 | 38,0 | +0,3 | 39,1 | +2,1 % |
| `gamer-2007` | 29,8 | 31,1 | 0 | 32,0 | +7,4 % |
| `secretaire-2007` | 41,9 | 41,6 | −0,1 | 42,3 | +1,0 % |

La dérive passe de −4,5…+4,4 % à **−3,3…+7,4 %**, et de +2,1 % au plus en somme
par époque. Elle vient presque toute des répertoires : les requêtes d'un
démarrage de `dev-1996` passent de 1 121 à 1 231, de `dev-1999` de 1 961 à
2 236, parce qu'ouvrir un fichier lit désormais son chemin, avec la
table FAT32 que ses répertoires demandent. `ThinkModel` **n'a pas été recalé**.
`fit-think.py` ne désigne d'ailleurs aucune constante : l'une ou l'autre seule
laisse des résidus de ±1,2 à ±2,2 s selon l'époque, avec un léger avantage à
`perFile` — ce qu'on attend d'un coût nouveau par fichier ouvert. Le cache de
piste, qui n'est dans aucun lot, rouvrira ce calage de toute façon ; la dérive
reste dans la bande de ±8 %, et la décision est laissée ouverte.

**Le coût de génération**, meilleure de cinq générations, en release, machine au
calme :

| volume | avant | après | |
|---|---:|---:|---:|
| `dev-1993` (démo de défragmentation) | 46 ms | 51 ms | ×1,1 |
| `secretaire-1999` (démo de démarrage) | 25 ms | 33 ms | ×1,3 |
| `dev-1996` | 168 ms | 197 ms | ×1,2 |
| `dev-1999` | 238 ms | 287 ms | ×1,2 |
| `secretaire-2003` | 114 ms | 175 ms | ×1,5 |
| `dev-2003` | 907 ms | 1 110 ms | ×1,2 |
| `gamer-2007` | 250 ms | 478 ms | ×1,9 |
| `dev-2007` | 1 343 ms | 1 803 ms | ×1,3 |
| `famille-2007` | 651 ms | 2 181 ms | ×3,4 |
| `famille-2003` | 620 ms | 3 247 ms | **×5,2** |

L'ouverture de l'app paie 13 ms de plus pour ses deux démos. Les NTFS pleins
paient bien davantage : chaque paquet de 64 Ko qui ne peut pas prolonger le
précédent lance le best-fit borné de `NTFSAllocator`, et `famille-2003` le fait
des centaines de milliers de fois. Avec l'entrelacement, `famille-2007` montait
à 6 s et `secretaire-1999` à 70 ms ; deux défauts de copie à l'écriture (un flux
resté référencé dans sa file, une copie des extents gardée pour le retour
arrière) avaient d'abord rendu chaque paquet quadratique.

### Le README

Régénéré d'un seul jeu de mesures — `dirs`, 340 bilans, dont les vingt volumes.
`readme-tables.py` produit désormais aussi les tables de défragmentation FAT et
leurs chiffres de prose ; il a été validé en reproduisant, depuis les bilans de
`base`, toutes les lignes de table du README précédent, et ses totaux arrondis à
la minute la plus proche comme le faisait le README (21 h 59, 1 h 23). La table
des trois allocateurs ne passe pas par le simulateur ; `AllocatorComparison`
la redonne à l'identique. Les paragraphes nouveaux disent l'écriture par
paquets, l'entrelacement non retenu, les répertoires et leur couleur ; les
phrases sur l'entrée de répertoire écrite dans la racine ont été retirées. Trois
chiffres de prose non remesurables ont été retirés plutôt que recopiés (les
249 Go et les 187 000 miettes de `famille-2007`, le trou de 22 Go de
`dev-2007`), et la phrase sur les deux volumes pleins à 99 % que le tassage à la
frontière range ne vaut plus que pour `gamer-1996`.

### Laissé ouvert

- **L'entrelacement.** Écrit, testé, coupé. Le reprendre demande un débit par
  programme — modem, disque, processeur — et une heure dans la journée, deux
  faits que la chronologie n'a pas. Entre la borne basse livrée et la borne
  haute mesurée, les trois cibles de calibration se referment ou se dépassent :
  c'est là qu'elles se jouent.
- **Le coût des NTFS pleins** : ×3 à ×5 sur `famille-2003` et `famille-2007`.
  La recherche que lance chaque paquet est celle de `NTFSAllocator`, bornée par
  des fenêtres ancrées au début de la zone de données, qu'un vrai NTFS mènerait
  plutôt près du dernier cluster du fichier. C'est une question sur
  l'allocateur, pas sur ce lot.
- **Le tassage à la frontière est quadratique en morceaux** (`physical()`,
  `vcn()`). Sans entrelacement, il reste dans ses temps ; avec, il ne l'était
  plus. L'app ne le propose que sur FAT.
- **Que Windows ne sache pas déplacer un répertoire FAT** — les vingt échecs de
  `MoveItem` de JkDefrag, puis l'abandon de toute la classe — est du lot 5. Ici
  les répertoires se déplacent comme des fichiers, sur FAT comme sur NTFS, et
  un répertoire FAT déplacé ne réécrit pas l'entrée `..` de ses enfants.
- **Des répertoires encore trop peu nombreux**, faute de fichiers : les
  manifestes rangent chaque groupe dans un seul dossier. Un désinstalleur ne
  retire aucun répertoire, et la racine d'un FAT16 accepte plus de 512 entrées.
- **Les places d'entrée sont approchées** : dans un répertoire, les
  sous-répertoires d'abord puis les fichiers vivants par identifiant, sans les
  trous des entrées effacées. Un démarrage NTFS ne lit pas l'enregistrement de
  MFT d'un répertoire, faute de numéro, et un acte préchargé ne lit pas les
  répertoires — la lecture groupée du préchargeur en tient lieu.
- **Les écritures refusées bougent sur les volumes pleins**, sans que ce soit
  expliqué fichier par fichier : `dev-1996` 461 → 139, `gamer-1999` 92 → 69,
  `famille-1996` 1 523 → 1 480 ; l'entrelacement les aurait presque doublées
  (`famille-1996` 2 896), des écritures simultanées tenant de la place en même
  temps. Les répertoires déplacent le curseur de quelques clusters sur des
  volumes à 93–99 %, ce qui suffit à changer ce qui trouve place.
- **La dérive de calibration** : −3,3 à +7,4 %, non compensée.

## Chantier 24 — le lot 5 : la défragmentation, une fois les volumes justes

**Fait** · branche `experts`

### Le problème

`DEFRAG_REVIEW.md` a été écrit avant les quatre lots. Ses chiffres ont tous été
remesurés sur les volumes d'aujourd'hui (étape `base`, le commit du chantier 23),
et plusieurs ont changé d'ordre de grandeur ; la revue disait où regarder.

| | où | ce qui était faux | remesuré avant ce lot |
|---|---|---|---|
| §4 | `WindowsXPStrategy`, `JKDefragStrategy` | la règle NTFS des clusters retenus n'est appliquée qu'à trois stratégies sur cinq ; XP et JkDefrag, qui relisent le bitmap à chaque trou, réutilisent aussitôt ce qu'ils quittent | avec l'hypothèse de la revue — un seul point de contrôle en fin de passe — XP laisse sur `dev-2007` **66 fichiers cassés et 52 346 morceaux** au lieu de 0 (la revue mesurait 42) |
| §5 | `DefragOperations.firstGap`, `largestGap` | la zone MFT est interdite à tous, y compris à UltraDefrag, qui s'en sert exprès depuis XP | sur `gamer-2007`, la zone porte le plus grand trou du volume : 2 558 846 clusters (9,8 Go) contre 403 007 hors zone ; sur `secretaire-2003`, 319 046 contre 18 610 |
| §3 | `Windows95Strategy.freeRuns` | l'occupant évacué est reposé juste au-dessus de la destination, rattrapé par la frontière et réévacué | jusqu'à **15,9 fois** le contenu du volume (`secretaire-1999`, 4 h 33) ; 9,2 fois sur `dev-1999` (5 h 32) ; 20 h 52 et 172,5 Go sur les douze FAT |
| §6 | `JKDefragStrategy` | les répertoires FAT, créés au lot 4, se déplacent comme des fichiers ; Windows ne sait pas les déplacer | la zone 0 de JkDefrag se range sur FAT comme sur NTFS |
| §7 | `JKDefragStrategy.Pass.defragment` | une tranche qui déborde de la fin du fichier est tenue pour refusée, sans source | 156 tranches débordantes sur `famille-1999` pour 714 tranches recopiées au-delà de la première, 53 sur `secretaire-2003`, 44 sur `gamer-2007` |
| §9 | quatre docstrings, et d'autres | des chiffres de galerie qui ne correspondent plus au générateur | « 260 fichiers réparés sur 299 » : 109 sur 123 ; « 57 sur 141 » : 887 sur 1 181 ; « 244 sur 12 220 » : 870 sur 12 247 ; « 213 Mo en moyenne » : pas remesurable ; « jusqu'à sept fois, cinq heures » : 15,9 fois, 5 h 32 ; « 166 176 visites » : 197 609 ; « 440 fichiers cassés de `gamer-1996` » : 407 |
| §9 | `FrontierCompactionStrategy` | le docstring présente le groupement des validations comme acquis | 1,4 déplacement par lot sur `gamer-1996` (99 %), 1,7 à 12 sous 90 % |

### Les décisions

**La règle des clusters retenus est portée par le volume.**
`DefragVolume.releaseWaitsForCheckpoint` vaut vrai sur NTFS, et
`DefragVolume.relocate` y **refuse** de s'exécuter (`precondition`) : on n'y
déplace qu'avec `relocateHoldingReleased`, qui prend aussi le mode « seuls les
extents qui changent » dont JkDefrag a besoin (l'ancien `relocateChanges`). La
source est Russinovich, *Inside Windows NT Disk Defragmenting* (Windows NT
Magazine, 1997) : « NTFS prevents deallocated clusters from being used again
until NTFS checkpoints the drive's state. Once every few seconds […] only then
can deallocated clusters be reused », et un `FSCTL_MOVE_FILE` vers eux rend
`STATUS_ALREADY_COMMITTED`, « the only remedy is to wait and try again ». Chaque
stratégie choisit sa cadence, et chaque cadence est écrite :

| stratégie | cadence | pourquoi |
|---|---|---|
| XP, JkDefrag, Windows 95 sur NTFS | celle de Windows, **toutes les 5 s** (`NTFSCheckpoints`) | ils relisent le bitmap du volume, donc voient ce que Windows voit |
| UltraDefrag | un par tour de routine | `release_temp_space_regions` : il ne relit sa liste qu'en tête de tour, même si Windows a fait son point de contrôle entre-temps |
| recollage économe | tous les `checkpointMoves` déplacements | le choix du chantier 15 |
| tassage à la frontière | un par lot de validations | le choix du chantier 14 |

**Le chiffre choisi : cinq secondes.** « NTFS writes checkpoint every 5 sec »,
dans les supports de cours tirés de *Windows Internals* (chapitre sur la reprise
de NTFS) ; Russinovich dit « every few seconds ». Un planificateur n'a pas
d'horloge : `OperationSink.plannedSeconds` en estime une, requête par requête —
12,7 ms de positionnement (seek moyen de 8,5 ms et demi-tour à 7 200 tr/min,
les Barracuda 7200.7 et 7200.10 de la galerie) et un transfert à 50 Mo/s. Un
point de contrôle qui tombe pendant un déplacement ne libère que ce que les
déplacements **précédents** ont quitté. Ce que la cadence change, mesuré avec un
binaire jetable dont l'intervalle se règle — fichiers cassés / morceaux restants :

| outil | volume | 1 s | **5 s** | 30 s | un seul, en fin de passe |
|---|---|---:|---:|---:|---:|
| XP | `dev-2003` | 14 / 1 323 | **14 / 1 323** | 15 / 1 339 | 33 / 5 958 |
| XP | `dev-2007` | 0 / 0 | **0 / 0** | 0 / 0 | 66 / 52 346 |
| XP | `famille-2007` | 157 / 134 532 | **157 / 134 532** | 157 / 134 532 | 175 / 139 123 |
| XP | `gamer-2007` | 128 / 28 362 | **129 / 28 364** | 126 / 28 351 | 176 / 37 662 |
| JkDefrag | `secretaire-2003` | 316 / 7 860 | **315 / 7 768** | 329 / 8 091 | 1 043 / 31 545 |
| JkDefrag | `famille-2003` | 51 / 3 409 | **55 / 3 440** | 55 / 3 527 | 319 / 37 877 |
| JkDefrag | `dev-2007` | 0 / 0 | **0 / 0** | 0 / 0 | 98 / 39 478 |

De une à trente secondes, rien ne bouge de plus d'une quinzaine de fichiers :
**le chiffre ne décide pas des conclusions**. Seule l'hypothèse la plus
favorable de la revue les renverse. La raison est mécanique : un gros fichier
cassé se déplace en plus de cinq secondes, et un point de contrôle est passé
quand vient le suivant.

Windows 95 sur NTFS — hors de son époque, mais la galerie l'y fait tourner —
suit la cadence de Windows, et quand ses occupants viennent de quitter la place
d'un fichier, il attend le point de contrôle avant de s'y poser. L'attente n'est
pas jouée, seulement son effet.

**Ce que JkDefrag fait d'une destination retenue.** L'auteur l'écrit dans
`MoveItem4` (`JkDefragLib.cpp:2355-2360`) : l'API ne signale pas d'erreur, elle
déplace ce qu'elle peut et coupe le fichier, que l'outil retente ailleurs. Ce
déplacement partiel n'est pas modélisé, et le cas ne se présente pas : un
binaire jetable a compté **zéro** destination retenue sur les vingt volumes,
chacune venant d'un `FindGap` qui relit le bitmap. Les tris, en revanche,
évacuent une place et relisent le bitmap juste après : sur NTFS ils la trouvent
prise, et posent le fichier plus loin (plus bas).

**La zone MFT est un paramètre de la stratégie.** `firstGap` et `largestGap`
prennent `avoidingMFTZone`, sans valeur par défaut. UltraDefrag : **faux**,
`get_mft_zones_layout` (`analyze.c:259-296`) ne retire la zone des régions
libres que `if(jp->win_version < WINDOWS_XP)`, « since we have MFT optimization
routine ». XP : **vrai, et c'est une hypothèse**, écrite comme telle dans
`WindowsXPStrategy.avoidsMFTZone`. La revue penchait pour l'inverse ; deux
choses penchent de ce côté-ci, sans trancher : `FSCTL_GET_NTFS_VOLUME_DATA` donne
les bornes de la zone aux défragmenteurs, et ceux de NT 4.0 — Diskeeper, dont
`dfrg.msc` est la version allégée — s'en servaient pour l'« identifier »
(Russinovich) ; et UltraDefrag ne justifie son usage de la zone que par sa
routine d'optimisation de la MFT, que l'outil de XP n'avait pas. JkDefrag garde
ses `MftExcludes`, dans sa propre recherche de trou.

**Windows 95 évacue au fond du volume.** Des deux issues, la recherche
descendante : `highestFreeRuns` est sorti de `FrontierCompactionStrategy` pour
`DefragOperations`, et sert aux deux. Ce qui tranche n'est pas une source sur
`DEFRAG.EXE` — il n'y en a pas — mais le code lui-même : le docstring de la
stratégie et le résumé de sa passe à l'écran disaient déjà que l'occupant est
poussé « vers la fin du volume ». Le code faisait l'inverse de sa description,
et c'est le facteur qui n'était pas fidèle — une défragmentation complète d'un
disque de cette taille sous Windows 98 prenait une à trois heures. La nature
sonore de la passe ne change pas : évacuations, retours au bord pour les tables,
même ordre de parcours. Un occupant qui ne trouve pas de place au fond reste où
il est, comme avant.

**Les répertoires FAT, que Windows ne sait pas déplacer.** La source est le
pilote FAT que Microsoft publie (`Windows-driver-samples/filesys/fastfat`,
`fsctrl.c`, `FatMoveFile`) : pour un répertoire, `StartingVcn == 0` rend
`STATUS_INVALID_PARAMETER`, « because sub-directories have this cluster number
in them and there is no safe way to simultaneously update them all » — le
premier cluster ne bouge pas, le reste de la chaîne si. C'est
`DefragVolume.moveFileAccepts`, consulté par les trois outils qui passent par
l'API :

- **JkDefrag** (`MoveItem`, `JkDefragLib.cpp:2482-2545`) essaie, échoue, déclare
  le répertoire immobile et recalcule ses zones ; un succès remet le compteur à
  zéro. Le test est `CannotMoveDirs > 20` : l'abandon vient au **vingt et
  unième** échec, pas au vingtième comme le disait la revue. Ensuite, un
  répertoire est déclaré immobile sans essai ni recalcul, et `CalculateZones`
  les compte tous pour immobiles (`:1940`, `:2004`) ;
- **UltraDefrag** les saute d'emblée : `can_defragment`, `defrag.c:139`,
  « skip FAT directories » — l'écart que son docstring disait non transposable
  faute de catégorie ; elle existe depuis le lot 4 ;
- **XP** déplace les fichiers entiers : l'appel échoue sans rien copier, le
  répertoire reste en morceaux.

Windows 95 et les deux passes écrites ici n'appellent pas l'API ; ils déplacent
toujours les répertoires comme des fichiers. **L'entrée `..` n'est pas
réécrite** : pour les outils de l'API, la question ne se pose plus — c'est
précisément le premier cluster, celui que `..` désigne, que Windows refuse de
déplacer ; pour `DEFRAG.EXE`, qui devait bien la réécrire, elle reste ouverte.

**Une tranche qui déborde est bornée, pas refusée.** Deux sources, une par
format : `FatComputeMoveFileParameter` (`fastfat/fsctrl.c`) ramène le compte à
la taille allouée — « This will be bounded by allocation size on return » — et
la page *Defragmenting Files* de Microsoft écrit « When defragmenting NTFS file
system volumes, defragmenting a virtual cluster beyond the allocation size of a
file is allowed ». La fin du fichier est recopiée dans le trou, puis
`ClustersDone` avance de toute la tranche demandée et la boucle s'arrête. Le
compteur `overrunSlices` compte maintenant les tranches bornées.

**Les chiffres des docstrings : retirés, ou datés.** Un chiffre de galerie dans
un docstring ne se régénère pas ; le README si, d'un seul jeu de mesures, par
`readme-tables.py`. Règle retenue, et appliquée à tous les docstrings de
défragmentation — pas seulement aux quatre de la revue : un fait qui décrit les
volumes d'aujourd'hui **en sort**, et renvoie à la table du README qui le porte ;
un chiffre qui justifie un réglage au moment où il a été choisi **reste, daté**
du chantier qui l'a mesuré ; une constante tirée d'un source (20 Mo, 50 Mo,
5 s) reste telle quelle. Un test qui régénère les docstrings aurait demandé de
générer les vingt volumes en debug, au prix de minutes par volume NTFS, pour
des phrases. Les fourchettes « Mesuré sur la galerie » de l'écran de choix
d'outil étaient de la même espèce, et plusieurs périmées avant ce lot ; elles
ont été reprises des mêmes bilans. Deux textes d'explication de l'app aussi
(l'entrée de répertoire, l'évacuation au fond).

**Les trois points plus petits.** Le groupement des validations du tassage à la
frontière est décrit tel qu'il est mesuré, lot par lot (ci-dessous). La ligne
morte de `recordFreed` a disparu — la dichotomie garantit `stop > cursor`, et le
commentaire le dit. `Windows95Strategy.destination` cherche par dichotomie dans
les plages immobiles, fusionnées au préalable pour que leurs fins soient triées
comme leurs débuts.

### Ce qui valide

- **`swift test` : 377 tests passent** (366 avant). Onze de plus :
  `CheckpointTests` (six, dont le test de sortie qui vérifie que `relocate`
  refuse de s'exécuter sur NTFS, et celui de la règle au niveau du volume : un
  déplacement ne trouve pas, avant le point de contrôle, la place qu'un autre
  vient de quitter), trois dans `DirectoryItemsTests`, un pour la tranche bornée,
  un pour la zone MFT d'UltraDefrag. `DISKCORE_CALIBRATION=1 swift test --filter
  Calibration` passe avec ses trois problèmes connus, les mêmes.
- **L'audit d'allocation du lot 1** (`AllocationInvariantTests`) passe sur les
  treize plans aux deux remplissages, sur le code final ; en cours de lot, les
  suites touchées par chaque correction ont été relancées à part.
- **JkDefrag sur FAT abandonne ses répertoires** : sur trente répertoires cassés,
  vingt et un échecs, vingt et un recalculs de zones, neuf répertoires abandonnés
  sans essai, et le fichier ordinaire recollé ; sur NTFS, aucun échec.
- **Quatre tests existants ont changé**, chacun pour une raison du lot : « la
  passe évacue plus qu'elle ne déplace » (Windows 95) disait exactement le
  facteur que la correction retire — il y a maintenant une évacuation pour deux
  fichiers déplacés, et 1,2 fois le contenu du volume déplacé ; le test d'écoute
  a besoin d'une passe longue et la retrouve par un tampon de 32 Ko ; le
  recollage par tranches de JkDefrag contenait une tranche débordante sans le
  dire, maintenant recopiée ; le test de la zone MFT dit qu'il porte sur XP.
- **Ce qui ne devait pas bouger n'a pas bougé**, étape par étape
  (`compare.py --identical`) :

  | étape | ce qu'elle change | bilans différents | lesquels |
  |---|---|---:|---|
  | `tidy` | ligne morte, dichotomie | 0 sur 340 | — |
  | `held` | clusters retenus | 71 | NTFS seuls : XP, JkDefrag et ses modes, Windows 95 ; ni UltraDefrag, ni le recollage, ni la frontière |
  | `mftzone` | zone MFT d'UltraDefrag | 12 | UltraDefrag seul, sur six NTFS (la zone de `famille-2003` et `famille-2007` a entièrement cédé) |
  | `w95` | évacuation au fond | 18 | Windows 95 seul |
  | `fatdirs` | répertoires FAT | 100 | FAT seuls, XP, UltraDefrag et JkDefrag |
  | `overrun` | tranche bornée | 14 | le mode 2 de JkDefrag seul |

  Les 64 bilans de démarrage, d'installation, de journée et de volume sont
  identiques de `base` à la dernière étape : **ce lot ne touche pas les
  démarrages**, et `ThinkModel` n'a pas bougé.

### Ce que chaque correction change, mesuré séparément

Chaque étape est un binaire de `Tools/Measure/`, construit après sa correction,
mesuré sur les 340 bilans.

**Les clusters retenus (`base` → `held`)** — fichiers cassés / morceaux restants :

| outil | volume | avant | après |
|---|---|---:|---:|
| XP | `dev-2003` | 15 / 1 339 | 14 / 1 323 |
| XP | `secretaire-2003` | 293 / 33 425 | 294 / 33 434 |
| XP | `gamer-2007` | 128 / 28 362 | 129 / 28 364 |
| XP | les cinq autres | inchangés | inchangés |
| JkDefrag | `dev-2003` | 37 / 244 | 39 / 169 |
| JkDefrag | `famille-2003` | 52 / 3 458 | 54 / 3 391 |
| JkDefrag | `gamer-2007` | 162 / 510 | 168 / 521 |

Le chapitre NTFS du README ne comparait pas seulement deux algorithmes mais deux
règles ; il compare maintenant deux algorithmes, et **ses conclusions tiennent** :
XP nettoie toujours entièrement `dev-2007` et `secretaire-2007`. Ce qui bascule,
ce sont les tris de JkDefrag sur NTFS : ils évacuent la place du fichier suivant,
puis la trouvent retenue. Sur `famille-2007`, le tri par nom passait de 173 194
morceaux à 33 728 en 7 h 13 ; il n'en ramène plus que 132 111, en 2 h 27. Sur
`dev-2007`, il en laisse 59 783 au lieu de 12. Et Windows 95 sur NTFS, qui ne
peut plus reprendre aussitôt ce qu'il évacue, déplace moins : `famille-2007`
passe de 142 h 42 à 72 h 26.

**La zone MFT d'UltraDefrag (`held` → `mftzone`)** :

| volume | fichiers cassés restants | morceaux restants | durée |
|---|---:|---:|---:|
| `gamer-2007` | 143 → **107** | 491 → **337** | 39 min 06 → 41 min 53 |
| `secretaire-2003` | 301 → **273** | 28 598 → **18 570** | 5 min 26 → 10 min 32 |
| `dev-2007` | 6 → 4 | 58 → 51 | 1 h 25 → 1 h 21 |
| `dev-2003` | 15 → 15 | 67 → **46** | 6 min 28 → 6 min 31 |

Sur `dev-2007`, le seek moyen tombe de 66 122 à 51 355 cylindres : les
destinations sont moins lointaines. La revue annonçait 92 → 70 fichiers cassés
sur `gamer-2007` ; c'est aujourd'hui 143 → 107.

**Windows 95 au fond du volume (`mftzone` → `w95`)**, sur les FAT où il a du
travail :

| volume | plein | déplacé / contenu | évacuations | durée | morceaux restants |
|---|---:|---:|---:|---:|---:|
| `dev-1993` | 69 % | 2,9 → 1,5 | 4 997 → 2 892 | 31 min 46 → 22 min 18 | 0 → 0 |
| `secretaire-1993` | 88 % | 6,4 → 1,5 | 12 807 → 1 171 | 1 h 48 → 18 min 13 | 0 → 0 |
| `famille-1996` | 89 % | 5,9 → 1,5 | 3 619 → 473 | 58 min 50 → 15 min 48 | 132 → 132 |
| `dev-1996` | 93 % | 1,7 → 0,6 | 1 733 → 1 025 | 21 min 54 → 9 min 29 | 2 218 → 2 208 |
| `dev-1999` | 93 % | 9,2 → 1,4 | 18 922 → 4 228 | 5 h 32 → 1 h 04 | 1 717 → **4 805** |
| `famille-1999` | 96 % | 7,3 → 1,8 | 13 873 → 2 403 | 5 h 16 → 1 h 11 | 27 → 27 |
| `gamer-1999` | 97 % | 0,7 → 0,3 | 1 978 → 636 | 27 min 19 → 14 min 06 | 6 832 → 6 529 |
| `secretaire-1999` | 87 % | **15,9 → 1,7** | 10 273 → 1 362 | 4 h 33 → 35 min 48 | 4 → 4 |

Sur les douze FAT, **20 h 52 → 4 h 46**, et 172,5 → 31,3 Go déplacés. La
facture est sur `dev-1999` : quand la frontière arrive au fond, elle y trouve
ses propres réfugiés et plus de place au-dessus ; le volume sort avec 4 805
morceaux au lieu de 1 717. La revue mesurait 13,4 fois le contenu sur
`gamer-1999` ; le lot 1 l'avait déjà ramené à 0,7, sa passe butant sur des
places qu'elle ne peut plus libérer. Sur NTFS, le même geste ramène `famille-2007`
de 72 h 26 à 20 h 38.

Conséquence pour le chapitre du tassage à la frontière : Windows 95 met
désormais 4 h 46 sur les douze FAT, la frontière 4 h 38. Ce n'est plus la durée
qui les sépare, c'est ce qu'ils laissent sur les volumes pleins — jusqu'à 6 529
morceaux pour l'un, 91 au plus pour l'autre. Le README le dit.

**Les répertoires FAT (`w95` → `fatdirs`)**. Les échecs de JkDefrag, comptés par
un binaire jetable :

| volume | échecs de répertoire | abandonnés sans essai |
|---|---:|---:|
| `dev-1993`, `poweruser-1993`, `secretaire-1993` | 9, 10, 6 | 0 |
| `gamer-1996`, `secretaire-1996` | 5, 11 | 0 |
| `dev-1996`, `famille-1996` | 21, 21 | 2, 2 |
| `dev-1999`, `gamer-1999`, `secretaire-1999` | 21 | 7, 17, 3 |
| `famille-1999` | 21 | **730** |

L'effet sur le mode 2 est faible, de 0 à +14 fichiers cassés (`famille-1999`,
549 → 563). Il est fort sur les tris, où les répertoires immobiles barrent la
reconstruction de la zone 0 : sur `famille-1999`, le tri par nom laissait 156
fichiers cassés, il en laisse 633. XP et UltraDefrag laissent un à vingt-deux
répertoires de plus en morceaux par volume.

**La tranche bornée (`fatdirs` → `overrun`)**, le mode 2 de JkDefrag seul. Sur
`famille-1999`, 152 tranches débordent, pour 738 tranches recopiées au-delà de la
première ; les recopier ramène ce qu'il
laisse de 2 918 à **1 970 morceaux**, pour 563 → 559 fichiers cassés. Sur
`secretaire-1996`, l'inverse : 12 → 67 morceaux, 3 → 8 fichiers cassés, une
tranche bornée recopiant une fin de fichier loin de son début. Ailleurs, de
quelques dizaines de morceaux dans un sens ou dans l'autre. `famille-1999` reste
le plus mauvais score de JkDefrag, et de loin.

**Le groupement des validations du tassage à la frontière**, que ce lot ne
change pas, mesuré sur les douze FAT (déplacements par lot validé) : 12,2 sur
`secretaire-1996` (76 %), 9,7 sur `secretaire-1999` (87 %), 5,9 sur `dev-1993`
(69 %), mais 2,4 sur `poweruser-1993` (86 %) et 1,7 sur `secretaire-1993`
(88 %) ; au-dessus de 90 %, de 2,2 à 3,3 ; et **1,4 sur `gamer-1996`** à 99 %. La
revue comptait 0,7 sur ce dernier, avec un autre décompte des déplacements ;
ici ce sont les déplacements unitaires, tronçons compris. Le
docstring le dit : le groupement cède là où le volume est plein. `gamer-1993`,
plein à 100 % depuis le lot 4, ne déplace rien.

**La borne de visites de `FindBestItem`** n'a mordu nulle part : pic de 197 609
visites (`secretaire-2007`) pour un budget de deux millions.

### Le README

Régénéré d'un seul jeu de mesures, l'étape `final` — le code du commit —, dont
les 340 bilans sont identiques à ceux de `overrun`. `readme-tables.py` a d'abord
été validé en reproduisant, depuis les bilans de `base`, les 72 lignes de table
du README précédent et ses chiffres de prose (les journées au texte « activités »
près, que l'outil ne produit pas). Six tables changent ; démarrages,
installations et journées sont identiques. La prose reprise :

- le chapitre NTFS dit désormais que **tous les outils sont soumis à la même
  règle**, leur cadence, et ce que la cadence change ;
- UltraDefrag et la zone MFT, et l'hypothèse de XP ;
- JkDefrag sur FAT : les répertoires abandonnés et la tranche bornée ;
- les tris sur NTFS, qui rangent à peine ;
- Windows 95 : ses durées (9 min 29 à 1 h 11), l'évacuation au fond, ce qu'elle
  coûte à `dev-1999` ;
- le tassage à la frontière, qui ne se distingue plus de Windows 95 par la durée
  mais par ce qu'il laisse ;
- deux phrases de « Ce qui ne l'est pas » : la durée de `dev-1993` sous 95
  (29 min 24, périmée avant ce lot) et les répertoires FAT.

### Laissé ouvert

- **XP et la zone MFT** : une hypothèse, argumentée, pas une source. Un
  désassemblage de `dfrg.msc` ou un témoignage d'époque trancherait.
- **Le déplacement partiel sur une place retenue** (`MoveItem4`) n'est pas
  modélisé ; le cas ne se présente pas dans la galerie, mais un outil qui ne
  relirait pas le bitmap le rencontrerait.
- **L'attente d'un point de contrôle n'est pas jouée** : Windows 95 sur NTFS
  attend avant de se poser, et la passe n'en dure pas plus. L'horloge des points
  de contrôle est une estimation, calée sur les disques NTFS de la galerie ; elle
  ne suit pas le disque réellement simulé.
- **L'entrée `..` d'un répertoire FAT déplacé par Windows 95** n'est pas
  réécrite, et ses sous-répertoires ne sont pas relus : c'est la moitié du
  travail de `DEFRAG.EXE` sur un répertoire, et le coût n'est pas là.
- **Le plus mauvais score de JkDefrag** reste `famille-1999` : 559 fichiers
  cassés, 1 970 morceaux. Ses 761 répertoires, un par séance d'import de photos,
  y sont pour beaucoup.
- **Windows 95 sur un volume plein** laisse plus de morceaux qu'avant. C'est le
  prix de l'évacuation au fond, et il est mesuré ; un outil d'époque
  demandait de faire de la place avant la passe.
- **Le tassage à la frontière reste quadratique en morceaux** (`physical()`,
  `vcn()`), comme l'a signalé le chantier 23 ; rien n'y a été fait.
- **Les fourchettes de durée de l'écran de choix d'outil** sont recopiées à la
  main des bilans ; `readme-tables.py` pourrait les produire.
- **La dérive de calibration des démarrages** (−3,3 à +7,4 %) est celle du
  chantier 23 : ce lot ne touche aucun démarrage, et `ThinkModel` n'a pas été
  recalé.

## Chantier 25 — le lot 6 : l'acoustique

**Fait** · branche `experts`

### Le problème

Tout vient de `DISK_EXPERT_REVIEW.md` §6, §4.4, §4.5 et §4.6. Ce lot n'a pas de
bilan à battre : les six autres se jugeaient sur des chiffres, celui-ci sur
l'oreille. Ce qui a été mesuré avant d'y toucher (étape `a6base`, le commit du
lot 7) :

| | où | ce qui était faux | mesuré |
|---|---|---|---|
| §6 | `SpindleVoice` | trois résonances fixes, que le régime ne fait glisser que pendant la rampe | à plein régime, les huit fiches du catalogue ont **le même spectre** : 0,0 dB d'écart moyen par tiers d'octave, −32,3 dB RMS pour toutes |
| §6 | `AudioCueBuilder.minimumTickSpacing` | tout micro-transitoire à moins de 18 ms du précédent est supprimé | lecture séquentielle de 64 Mo en requêtes d'un mégaoctet : l'enveloppe bat à **53,6 Hz** sur le Barracuda à une tête (au lieu de 108) et à **37,9 Hz** sur le Fireball à quatre têtes (au lieu de 75,7) — un tic sur deux |
| §4.4 | `IdleBehavior` | pas de recalibration thermique | — |
| §4.6 | `DiskMechanics.init` | mise en route : une rampe, puis le premier accès depuis le moyeu | le « clac » d'ouverture était la première lecture |
| §4.5 | `Scenario.parkDelay` | le bras se parque une seconde après la dernière requête, sur **tous** les scénarios | aucun disque de bureau de cette période ne le faisait |
| §6 | — | ni décollement ni atterrissage des têtes | — |

Le point de `parkDelay` n'était pas dans la liste du lot 6 de
`LEDGER-EXPERTS.md` ; il y entre parce qu'il décide du même son que
l'atterrissage des têtes.

### Les décisions

**Le plateau prend le régime, le nombre de plateaux et le palier**
(`SpindleCharacter`, nouveau fichier de `Sources/Model`, donc testé). La revue
demandait le régime ; il ne suffit pas, et les manuels le disent. Relevés dans
les PDF eux-mêmes — la recherche en ligne en avait donné une version fausse,
2,1 B pour tout l'ATA IV :

| disque | tr/min | plateaux | palier | repos | source |
|---|---|---|---|---|---|
| Conner CFA170A, 1993 | 4 011 | 2 | billes | 42 dBA | TULARC |
| Quantum Fireball TM, 1996 | 5 400 | 2–3 | billes | 32 dBA à 1 m = **3,6 B** | manuel Quantum, tables 4-6 et 4-7 |
| Seagate U8, 1999 | 5 400 | 1 | billes | 3,2 B | manuel U8, rév. B |
| Barracuda ATA IV, 2001 | 7 200 | 1 / 2 | **FDB** | **2,1 / 2,5 B** | manuel ATA IV, rév. B, §1.9 |
| Barracuda 7200.7, 2003 | 7 200 | 1 | FDB | < 2,2 B | manuel 7200.7, rév. N, table 1 |
| Barracuda 7200.10, 320 Go | 7 200 | 2 | FDB | 2,8 B | manuel 7200.10 SATA, rév. A, table 4 |
| Barracuda 7200.11, 1 To | 7 200 | 4 | FDB | 2,9 B | manuel 7200.11, rév. E, table 1 |

Trois choses en sortent. **Le vieux disque lent est le plus bruyant** : le
roulement à billes fait l'essentiel du bruit d'un disque jusqu'en 2000, et
Seagate passe au palier fluide avec l'ATA IV. **Un plateau de plus, c'est
+0,4 B** au même régime sur le même moteur (ATA IV). **L'époque compte** : le
Fireball TM donne pression et puissance du même disque, 4 dB d'écart, qui
convertissent les 42 dBA du Conner en ≈ 4,6 B — un bel de plus qu'en 1996.

Le modèle : un **souffle** d'air — les trois bandes d'avant, dont les
fréquences et les parts de puissance sont gardées pour un 7 200 tr/min —,
glissé avec le régime (nombre de Strouhal constant), incliné vers l'aigu à
mesure que le disque tourne vite (×r pour la bande médiane, ×r² pour la haute),
de puissance en r⁵ et +0,4 B par doublement des plateaux ; pour les disques
d'avant 2001, un **roulement** à 3,6 B à deux plateaux, +1 B en 1993 : un
sifflement large vers 2,9 kHz et un roulage grave qui suit le régime, **modulés
à 35 % à chaque tour** ; une raie de **commutation du moteur** à 24 fois la
rotation. Chaque bande est réglée pour porter exactement sa part de puissance :
le niveau est celui du caractère, quelle que soit la forme du spectre. Le
modèle retrouve les manuels à 0,1 B près, sauf le 7200.10 (2,55 contre 2,8 B).

Deux choses ne viennent d'aucune fiche et sont dites comme telles : les
**24 commutations par tour** (un triphasé à huit pôles, le moteur le plus
courant — les fiches ne donnent pas les pôles) et la **forme des bandes du
roulement**.

**Une licence de mixage, la seule du plateau : le niveau suit les manuels à
moitié en décibels** autour du U8, **au quart au-delà de 3,0 B** — le coude
est venu de l'écoute, voir plus bas. Pris en entier, les 25 dB entre le Conner et
un 7 200 tr/min à un plateau mettaient la voix de rotation de la défragmentation
de `dev-1993` à −12,5 dBFS RMS, 19 dB au-dessus d'avant, crêtes à 1,27 — elle
couvrait ses propres seeks et écrêtait —, et un 2003 sous −45 dBFS. Les seeks,
eux, ne sont calés sur aucune fiche : l'écart idle/seek des manuels (+3 dB sur
le U8, +9 dB sur l'ATA IV) dirait qu'il faudrait les caler aussi, et ce n'est
pas fait. À moitié partout : 12 dB d'écart, et la passe de `dev-1993` à
−24 dBFS, crêtes à 0,54 — ce que l'écoute sur le téléphone a trouvé trop fort
pour les vieux disques et juste pour les récents. Avec le coude à 3,0 B, le plus
bruyant des disques à palier fluide (le 7200.11), les récents ne bougent pas et
les roulements descendent : 8 dB entre le Conner et un 2003, la passe de
`dev-1993` à −26,5 dBFS au plus fort, le repos de 1993 à −28,7 dBFS contre −24,1.

**Les micro-transitoires rapprochés partent en trains, et aucun n'est
supprimé** (`CueStream`, `SeekSynth.renderTickTrain`). La règle est celle des
seeks, héritée de MAME : un tic qui arrive à moins de 30 ms du précédent — avant
qu'il se soit éteint — le rejoint ; un train ne dépasse pas une seconde ; il est
rendu d'un seul passage dans le banc de résonateurs, qui garde son état d'un tic
au suivant. La densité module le train d'elle-même : l'excitation de chaque tic
s'arrête au suivant, qui reprend l'asservissement. Un tic isolé reste un
one-shot mis en cache, rendu exactement comme avant. La décision est causale à
horizon borné, comme celle des seeks : le train se referme dès que le plus
précoce des tics à venir — le premier en attente d'un train de seeks, ou
l'événement qu'on lit — ne peut plus le rejoindre, et `watermark` le retient
jusque-là.

**La mise sous tension en trois temps** (`IdleBehavior.coldStart`,
`StartupSequence`), pour un démarrage et une journée : le moteur ; à 50 ms le
**décollement** des têtes (`DiskEventKind.headUnstick`) ; puis la **recherche de
la piste 0** — une course complète depuis la zone de parcage, quatre pas courts
au bord, deux tours sur chaque arrêt —, calée pour finir quand le disque est
prêt et jamais avant la moitié de la rampe, faute de coussin d'air. Le bras
attend **au bord**. Le secteur d'amorçage étant au cylindre 0, le premier accès
d'un démarrage n'a plus de seek : le « clac » franc d'ouverture est la salve,
comme le dit la revue. Une défragmentation et une installation partent d'un
plateau qui tourne déjà ; leur rampe reste un fondu, sans décollement.

**La recalibration thermique** (`ThermalRecalibration`), pour les disques de
1996 et avant — 1993 et 1996 dans la galerie, pas 1999. Ce que les sources
donnent : « quelques minutes », « une seconde », « avant ~1996 ». Ce qui est
choisi : la première deux minutes après le disque prêt — le plus long démarrage
de la galerie dure 70 s, aucun n'en contient, et `ThinkModel` n'est pas touché —
puis toutes les quatre minutes ; trois zones, bord, moyeu, milieu, deux fois,
avec un aller-retour court autour de chaque repère et deux tours de lecture à
chaque arrêt : 24 arrêts, ≈ 1 s sur un 3 600 tr/min. Elle attend la fin de la
commande en cours, comme le faisaient les disques — c'est ce que les modèles
« AV » évitaient —, et le retard qu'elle impose est compté à part
(`TraceStats.recalibrationSeconds`, et une ligne du bilan). Ses seeks ne sont pas
des seeks demandés ; mais le bras finit ailleurs, et la requête suivante peut en
payer un de plus : c'est pourquoi le nombre de seeks d'une passe de 1993 bouge.

**Le parcage d'une seconde disparaît des scénarios, remplacé par la coupure là
où il y en a une.** Des trois issues proposées — le nommer, le rendre optionnel,
le remplacer —, la troisième, parce que ce lot se juge sur ce que produit la
mécanique réelle. `IdleBehavior.parkAfter` reste, documenté comme la pratique
des disques à rampe des portables ; `IdleBehavior.desktop(year:)` ne s'en sert
pas. La **journée** finit par une vraie coupure (`stopAfter`, une seconde après
la dernière écriture) : le bras se retire au moyeu, le moteur est coupé, le
plateau redescend par la loi du premier ordre de `SpindleTimeline`, et à 40 % du
régime les têtes **se posent** (`headLand`) — le seuil est une estimation, aucune
fiche ne le donne. Une défragmentation, un démarrage et une installation se
referment sur le disque qui tourne, sans dernier mouvement : c'est ce qu'ils
faisaient. La coupure n'étant connue qu'à la fin du travail, `PassEnd` la
porte, et `LivePass` fait ralentir le plateau affiché avec celui qu'on entend ;
`PlatterTrack.wake` montre le bras au bord après la mise en route.

**Décollement et atterrissage** sont deux one-shots du même banc
(`renderUnstick`, `renderLanding`) : un claquement unique plus grave qu'un seek
suivi de 30 ms de frottement ; quatre contacts de plus en plus faibles et
rapprochés, puis 120 ms de frottement qui s'éteint. L'haptique les reçoit, et
un train de tics y devient un frémissement continu piqué de ses pas de piste.

**Ce qui est jugé juste n'a pas bougé** : les fréquences des modes de
l'actionneur sont les mêmes, seule l'excitation varie ; le timbre du plateau
dépend du **régime du plateau**, jamais de la vitesse du bras ; la fusion des
trains de seeks et la décomposition speedup / coast / slowdown / settle ne sont
pas touchées.

### Ce qui valide

- **`swift test` : 390 tests passent** (377 avant) : les treize
  d'`AcousticsTests` — niveaux des manuels, glissement du souffle, partage de la
  puissance, cinq époques distinctes, mise en route, durée d'un démarrage au
  premier seek près, recalibration par époque, interruption et son coût, bureau
  sans parcage, coupure et atterrissage, plateau affiché qui s'arrête, pas de
  piste non décimés.
- **L'identité flux / bloc tient** : `StreamingTests` passe, avec l'oracle du
  calcul d'un bloc mis à la nouvelle règle — ses micro-transitoires ne sont plus
  espacés de 18 ms mais groupés en trains sur la trace entière, et il connaît le
  décollement et l'atterrissage. Le cas synthétique de 20 000 événements, trains
  coupés à la seconde et tics sur leurs bords, se décide comme d'un bloc. Rien
  de ce qui est ajouté ne dépend de la taille des tampons : les trains sont
  décidés sur les événements, et `SpindleVoice` recalcule ses filtres sur un
  changement de caractère comme il le faisait sur un changement de vitesse.
- **Les durées** (`compare.py a6base a6m3`, 340 bilans) : **rien ne bouge en
  1999 et après**, sinon le nombre de repères audio, un événement de moins (le
  parcage) et, sur les démarrages et les journées, un seek de moins (le premier).
  Les démarrages de 1993 et 1996 ne bougent que de ce seek : 0,0 à −0,1 s,
  `ThinkModel` n'est pas recalé. Les passes et installations de 1993 et 1996
  s'allongent de leurs recalibrations : +0,1 à +0,7 %, soit une seconde par
  recalibration (six sur la passe de 95 de `dev-1993`, 22 min 18 → 22 min 24).
  Aucun plan, aucun volume, aucun compte de fichiers ne change.
- **Le temps de rendu d'une passe**, en release sur le Mac, WAV compris :
  défragmentation de `dev-1993` à la frontière (346 s de son), 3,9 → 6,1 s ; de
  `dev-2003` par recollage (200 s), 4,8 → 3,9 s ; démarrage de `gamer-2003`
  (69 s), 0,64 → 0,69 s. Un train d'une seconde — 120 tics — se rend en 3,8 ms :
  c'est le coût que l'application paie, hors fil principal, une fois par seconde
  de lecture séquentielle. Le surcoût de `dev-1993` est de 6 ms par seconde
  écoutée ; il vient des trains qui remplacent des tics en cache.
- **Le CPU sur l'appareil** (iPhone 13 Pro Max, iOS 27, Release), pendant la
  démo de défragmentation (`dev-1993`, 3 600 tr/min, le cas le plus chargé en
  trains), même geste sur les deux versions — le commit d'avant construit dans
  un worktree jetable. `xctrace` Activity Monitor sur 20 s, puis Time Profiler
  sur 10 s :

  | | avant | après |
  |---|---:|---:|
  | CPU de l'app | **45,1 %** d'un cœur | **47,0 %** |
  | voix du plateau (`SpindleVoice`, fil audio) | 3,0 % | 4,7 % |
  | synthèse des transitoires (`SeekSynth`) | 0,2 % | 1,4 %, dont 0,9 % de trains de tics |
  | haptique | 4,5 % | 2,3 % |
  | fil principal (affichage) | 81 % de l'app | 80 % de l'app |

  **+1,9 point au total.** Les trains coûtent ce qu'annonçait le rendu
  hors-ligne ; la voix du plateau, cinq bandes au lieu de trois, un peu plus ;
  l'haptique, qui reçoit un train au lieu d'un motif par tic, moitié moins.
  L'essentiel du CPU reste l'affichage, comme avant le lot. Au repos, l'app
  consomme 0,5 %.

### Ce qui a été entendu

**Gabriel a écouté** les paires ci-dessous au casque sur le Mac — le démarrage
de 1993 et la passe de la démo **en entier** —, puis la démo, deux démarrages et
une journée sur le téléphone. Tout ce qui est décrit plus bas a été entendu
comme prévu, **sauf le ronronnement des vieux disques, trop fort** ; celui des
récents est juste. C'est ce qui a fait resserrer le haut de l'échelle (le coude
à 3,0 B) ; les récents n'ont pas bougé. Réécouté après le coude : juste au
haut-parleur, encore un peu fort au casque, où **20 % de rotation suffisent** —
le préréglage « Casque » passe de 32 à 20 % (et le rendu hors-ligne avec lui,
`SPINDLE_GAIN` par défaut), « Haut-parleur » reste à 50 %. Les niveaux en dBFS
cités dans ce chantier sont mesurés au gain d'avant, 0,32 ; au nouveau, la
rotation est 4 dB plus bas. **La mention « rien n'a été écouté en
entier » du chantier 19 est refermée.**

L'assistant qui a mené ce lot n'entend pas : la description qui suit a été lue
dans les rendus — spectrogrammes, enveloppes, spectres par tiers d'octave — et
écrite avant l'écoute, pour qu'elle la confirme ou la démente. Les niveaux sont
ceux d'après le coude.

- **Le plateau, voix seule.** Avant, le même souffle sombre pour tous
  (centroïde 611–656 Hz). Après, trois familles. Le **1993** est le plus fort
  (−29,3 dB contre −32,3), plus clair (centroïde 1 119 Hz, un quart de l'énergie
  au-dessus de 1,5 kHz) : un sifflement de roulement qui **bat à 60 Hz**, une fois
  par tour, 34 % de modulation — un ronronnement rugueux. Le **1996-1999**, même
  sifflement, battant à 90 Hz, 2 à 3 dB plus bas. Le **2001-2008**, le souffle
  d'avant, lisse (1 % de modulation), de −37,5 à −33,5 dB selon les plateaux.
- **Le démarrage de 1993**, sur les dix premières secondes : avant, le
  ronronnement qui monte, puis à 7,75 s la première lecture, une course complète.
  Après, un **claquement sec** isolé à 0,40 s, dans le silence presque complet
  du moteur qui démarre — le décollement ; la montée d'un plateau plus clair,
  strié à chaque tour ; puis, juste avant 7,55 s, une **courte salve** groupée —
  la recherche de la piste 0 — et les lectures qui suivent partent du bord.
- **La lecture séquentielle.** Avant, sur le Fireball, des tics isolés tous les
  26 ms séparés de silence. Après, une texture continue, rythmée de temps forts
  toutes les 53 ms — le pas de piste — entre lesquels passent trois
  commutations plus faibles : **deux périodicités emboîtées**, 75,7 et 18,9 Hz
  dans l'enveloppe. Sur le Barracuda, la cadence de 108 Hz est une hauteur.
- **La recalibration.** Dans la journée de `dev-1996` au jour 20, à 121,55 s, au
  milieu d'un va-et-vient régulier : 0,6 s de clacs plus forts et irréguliers,
  puis le va-et-vient reprend. Dans une défragmentation de 1993, elle se fond
  dans le crépitement : ce n'est qu'un changement de rythme d'une seconde. Elle
  s'entendra surtout au repos — et une passe n'en a pas.
- **La fin de journée.** Avant, le dernier clac d'écriture puis, une seconde
  plus tard, le parcage, et le plateau qui tourne. Après, le dernier clac, le
  retrait du bras, le ronronnement qui tombe, et 1,0 s après la coupure un
  **petit crac** large bande — l'atterrissage — sur un plateau qui ralentit
  encore, ses stries de rotation s'espaçant jusqu'au silence.

**Écouté**, rendus par `a6base` (avant) et `a6m3` (après) avec
`./Tools/Measure/snapshot.sh` puis `SCENARIO=… rendertrace` :

| paire | ce qui doit différer |
|---|---|
| `SCENARIO=boot:gamer-1993`, avant / après, **en entier** (29 s) | décollement, salve de mise en route, plateau de 1993 |
| `SCENARIO=dev-1993 STRATEGY=frontierCompaction`, avant / après, **en entier** (5 min 47) | la passe de la démo, et sa seule recalibration, à 2 min 01 |
| `SCENARIO=day:dev-1996:20`, après | recalibration à 2 min 02, coupure et atterrissage à la fin |
| `SCENARIO=boot:gamer-2003`, avant / après | le souffle d'un 7 200 à palier fluide, plus bas |
| `SCENARIO=boot:gamer-<année> TRANSIENT_GAIN=0`, les cinq années | se reconnaissent-elles sans l'étiquette ? |

### Laissé ouvert

- **Le niveau des vieux disques après le coude** n'a pas été réécouté ; il est
  4,6 dB plus bas en 1993, 1,5 dB en 1996, sur la foi d'une écoute qui le
  trouvait trop fort sans dire de combien.
- **Le CPU sur l'appareil n'est mesuré que sur un scénario**, la démo de
  défragmentation ; une lecture séquentielle de 2003, où les trains sont plus
  longs, n'a pas été jouée sur le téléphone.
- **Les huit fiches ne se distinguent pas toutes.** Trois familles de timbre ;
  à l'intérieur, 2 dB de niveau par doublement de plateaux, qu'on n'entend qu'en
  comparaison directe. Les deux ATA IV et le 7200.7 sont identiques, et Seagate
  dit qu'ils le sont. Un échantillon par époque vaudrait mieux que tout réglage.
- **Le niveau des seeks n'est calé sur rien**, alors que les manuels donnent
  l'écart repos/seek (+3 dB sur le U8, +9 dB sur l'ATA IV). C'est ce qui oblige à
  la licence de mixage du plateau ; caler les deux ensemble la supprimerait.
- **Les estimations de ce lot**, à trancher sur source : la période et le motif
  de la recalibration, les 24 commutations par tour, le seuil d'atterrissage à
  40 % du régime, les 50 ms du décollement, le passage au palier fluide en 2001
  pour toute la galerie (Seagate ; Maxtor et Western Digital ont suivi plus
  tard), et la conversion dBA → bels du Conner.
- **La salve de mise en route et la recalibration ne sont pas dessinées** : le
  plateau affiché ne connaît que les requêtes. Le bras saute du moyeu au bord à
  l'instant prêt.
- **Le 7200.10 est à 2,55 B dans le modèle et à 2,8 B dans son manuel** : la
  droite par plateau est tirée de l'ATA IV seul.
- **Une recalibration due pendant la queue d'une passe n'est pas jouée** : le
  mécanisme ne regarde qu'à l'arrivée d'une requête, et à la coupure rien.
