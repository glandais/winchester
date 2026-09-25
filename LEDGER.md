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

Montrer Winchester sur YouTube : un démarrage, une défragmentation, plus tard une
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

## Chantier 26 — le lot 7 : le cache du disque, et le recalage qui solde

**Fait** · branche `experts`

### Le problème

`DiskMechanics` servait tout par la mécanique : pas de tampon, pas de lecture
anticipée, pas de cache d'écriture, un bus infini et des commandes gratuites.
L'expert disque classait ce manque troisième (« le plus gros écart conceptuel
restant », `DISK_EXPERT_REVIEW.md` §4.1), et trois chantiers de suite ont buté
dessus : le tour de plateau corrigé au lot 1, que la lecture anticipée masquait
sur un vrai disque ; `SMARTDRV` et l'éviction de VCACHE, écartés au lot 3 faute
de cache ; et le calage de `ThinkModel`, que les lots 3 et 4 se sont passé.

| | où | ce qui manquait | mesuré avant |
|---|---|---|---|
| §4.1 | `DiskMechanics` | lecture anticipée, lecture sans latence, cache d'écriture, taille du tampon | aucune trace de tampon ; toute écriture synchrone |
| §4.2 | même endroit | le débit du bus n'était jamais une borne, une commande ne coûtait rien | un 1993 derrière un bus ISA lisait comme si son interface suivait tout |
| M3 (ch. 22) | `BootPlanner` | `SMARTDRV`, que le démarrage de 1993 charge | les lectures de MS-DOS au secteur, sans cache |
| M1 (ch. 22) | `BootPlanner.followChain` | l'éviction de VCACHE | une page de table FAT32 lue restait en cache tout le démarrage |
| ch. 22, 23 | `ThinkModel.boot` | le recalage promis | dérive de −3,3 à +7,4 % laissée ouverte |

### Les décisions — les fiches, lues dans les manuels

Le tampon, sa politique par défaut, l'interface et le coût de commande sont
désormais des champs de `DriveReference` (`DriveBuffer`). Chaque valeur vient
d'un manuel constructeur ou de sa fiche, et les PDF sont rangés dans
`~/code/perso/disknoise.resources/manuels/` — le chantier 25 ne les avait pas
gardés. Un disque de la galerie prend la fiche du catalogue la plus proche de
son année.

| fiche | tampon | lecture anticipée | cache d'écriture | interface | ce qui tranche |
|---|---|---|---|---|---|
| Conner CFA170A, 1993 | 64 Ko | oui | **non** | 7,0 Mo/s | TULARC : « 64 KB READ-AHEAD », « 7.000 MB/S ext » |
| Fireball 1080AT, 1996 | 128 Ko, **76 de cache** | oui | oui | PIO 4, 16,67 Mo/s | TULARC : « 128 KB READ/WRITE » ; manuel Fireball TM (81-111394-02, 1996) §5.5.1 et §6 : « DisCache, a 76 K disk cache », « read look-ahead, and write cache enabled » à la mise sous tension |
| Seagate U8, 1999 | 512 Ko | oui | oui | UDMA 4 | manuel U8 (SG35226-001, rév. A) : « Cache buffer 512 Kbytes », « Power-on default has the read look-ahead and write caching features enabled » |
| Barracuda ATA IV, 2001 (×2) | 2 Mo | oui | oui | UDMA 5 | manuel ATA IV (100129212, rév. B), même phrase |
| Barracuda 7200.7, 2003 | 2 Mo | oui | oui | UDMA 5 | manuel 7200.7 (100217279, rév. N) : 2 Mo pour le ST340014A, 8 Mo pour les variantes en …3A |
| Barracuda 7200.10, 2006 | **16 Mo** | oui | oui | UDMA 5 | manuel 7200.10 PATA (100402369, rév. F), table 2 : 16 Mo pour le ST3320620A, 8 Mo pour le ST3320820A |
| Barracuda 7200.11, 2008 | 32 Mo | oui | oui | SATA 300 | manuel 7200.11 (100452348, rév. E), table 1 |

Trois choses que les manuels ne donnent pas, et qui sont dites comme telles :

- **le manuel du Fireball 540/1080AT de 1995** (81-109318-02), la fiche exacte
  du catalogue, est introuvable en ligne ; le détail vient du Fireball TM de
  même capacité, un an plus tard ;
- **la segmentation** : seul le Fireball la décrit (« adaptive segmentation […]
  each segment contains one cache entry »), et le Conner Cougar de 1992
  annonce un tampon « segmentable » géré au plus anciennement utilisé. Les
  manuels Seagate se taisent. Le modèle applique la règle du Fireball à tous :
  aucun nombre de segments n'est posé, il tombe de la taille du tampon devant
  celle d'une piste ;
- **la lecture sans latence** : seul le Fireball l'annonce (« Read-on-arrival
  firmware »), et la phrase peut aussi désigner une lecture commencée avant la
  fin du repositionnement. Les Seagate la reçoivent **par hypothèse**, le Conner
  non.

**Le coût de commande** a une seule mesure de la période : Microsoft Research,
*IDE Ultra/33 Performance: Intel PIIX4E* (1999), sur un Pentium II — « The DMA
setup / cleanup activity takes approximately 200 µs » en lecture, moins de
50 µs en écriture. Le modèle prend 0,2 ms dans les deux sens à partir de 1996.
Le Conner reçoit 0,5 ms, la valeur que Conner publie pour le Cougar CP30204 de
1992 (« Controller Overhead < 500 µs »).

**Le bus de la machine** vient d'une table d'époque (`HostBus`) : 5,0 Mo/s pour
un IDE sur ISA en PIO (brevet US 5 678 064, « burst rates of 5 MByte/sec on the
programmed I/O cycles ») ; PIO 4 en 1996, Windows 95 OSR1 n'ayant pas de pilote
DMA ; en 1999 les salves mesurées par le même rapport, 32,6 Mo/s vers la mémoire
et 21,9 Mo/s dans l'autre sens ; UDMA/100 nominal ensuite. La revue parlait de
« 2 à 3 Mo/s utiles derrière un 486 » : aucune source ne le donne, et le brevet
dit 5 en salve.

### Les décisions — la mécanique

**Deux horloges.** Celle de l'hôte, qui avance à chaque commande acquittée, et
celle du bras, qui peut encore lire ou écrire après. À chaque commande, le
travail de fond est joué jusqu'à l'instant où elle arrive — la lecture anticipée
continue, les écritures acquittées sont posées —, puis la commande est servie par
le tampon ou par le bras. Rien ne dépend des requêtes à venir. Les événements du
travail de fond sont émis dans l'ordre du bras, jamais avant la garde de
`CueStream`, et l'identité flux / bloc tient.

**Sans tampon, rien ne change** (`DriveInterface.direct`) : un binaire dont
toutes les passes prennent `.direct` rend **340 bilans identiques sur 340** à
ceux du commit précédent. La refonte est une étape, pas une réécriture.

**La lecture anticipée lit une piste d'avance.** C'est ce que tient le cache du
Fireball (76 Ko pour une piste externe de 69 Ko), et l'ordre de grandeur de la
revue (« jusqu'à la fin de la piste »). Une requête qui tombe dans la fenêtre la
prolonge d'une piste : une lecture séquentielle ne s'arrête jamais. Une requête
ailleurs l'arrête au secteur près, et ce qu'elle a lu reste une entrée du
tampon. Le franchissement de piste pendant la lecture anticipée est celui d'un
transfert, par le même `angleOf`.

**La lecture sans latence ne sert qu'aux requêtes qui tiennent sur une piste.**
Pour une requête qui déborde, la calculer piste par piste donne exactement le
temps de la lecture ordinaire à la première piste — le tour d'avance se
reperd à attendre le secteur 0 de la suivante — et pire ensuite. Le modèle ne
l'applique donc que là où elle gagne, et le tour qu'elle fait lit aussi la fin
de la piste.

**Le cache d'écriture pose aussitôt que le bras est libre**, comme le décrit le
manuel du Fireball (« the drive immediately writes the cached data to the
disk »), dans l'ordre de l'ascenseur à partir de la tête, en fusionnant ce qui
se touche et a été acquitté. Il pose aussi quand il manque de place, et une
écriture plus grosse que lui passe au travers — les écritures de 128 Ko de
l'installeur de Windows 95 sur le Fireball, par exemple. Une lecture passe avant
les vidages en attente.

### Les décisions — les caches du système

**`SMARTDRV`** (MS-DOS 6.22, `HELP SMARTDRV`) : éléments de 8 Ko, 16 Ko lus
d'avance à chaque lecture qui va au disque, 1 Mo sous MS-DOS et 512 Ko sous
Windows pour une machine de 3 Mo de mémoire étendue. Il est actif à partir de
l'acte qui suit `AUTOEXEC.BAT`. Deux choix : **la machine a 4 Mo**, la
configuration courante d'un 486 sous Windows 3.1 — aucun profil ne dit la
sienne ; et **ses écritures partent aussitôt**, alors que l'aide dit qu'il les
garde jusqu'à la fin de la commande — un démarrage n'en enchaîne pas assez pour
que le délai compte. En passant sous Windows, le cache rétrécit sans rien
garder : le cas le plus défavorable.

**VCACHE** tient les pages de la table FAT32 avec les données des fichiers, dans
une même file au plus anciennement servi (`PageLRU`). **Sa taille est une
hypothèse** : Microsoft dit seulement qu'il se dimensionne sur la mémoire
présente ; le seul chiffre d'époque est la règle de réglage « un quart de la
mémoire, 16 Mo au plus » pour `MaxFileCache`. Le modèle la prend, sur une machine
de 64 Mo en 1999. Le suivi de chaîne relit désormais une page que les données
ont chassée : ce sont les retours périodiques que la revue décrivait.

### Ce qui valide

- **`DriveCacheTests`**, chiffrés en Mo/s, en tours et en vidages :
  - une lecture contiguë servie par le tampon ne paie ni seek, ni latence, ni pas
    de piste, et sort au débit du bus coût de commande compris — **9,17 Mo/s** en
    requêtes de 4 Ko sur le Fireball (bus de 16,6 Mo/s), **17,0 Mo/s** sur le
    7200.10 (100 Mo/s) : à 4 Ko, c'est le coût de commande qui commande ;
  - la lecture anticipée lit sans qu'on le lui demande, et ses transferts sont
    des événements hors de toute requête ;
  - une lecture plus grosse que le tampon le vide ; un seek vide le Fireball,
    dont le cache tient une entrée, et pas le 7200.10, qui en tient des
    dizaines ;
  - une lecture d'une piste entière : **0,000 tour** de latence moyenne avec la
    lecture sans latence, **0,429** sans, sur deux cents pistes ;
  - soixante-quatre écritures de 4 Ko d'affilée : **8 vidages** sur le
    Fireball, dont le cache en tient dix-neuf, **3** sur le 7200.10 ; posés dans
    l'ordre de l'ascenseur ;
  - sans tampon, la mécanique d'avant.
- **`SoftwareCacheTests`** : la file au plus anciennement servi, `SMARTDRV` qui
  ne lit plus que des éléments de 8 Ko à partir de son acte et en sert une
  partie, VCACHE qui relit 99 pages de table sur un démarrage de
  `secretaire-1999`.
- **`StreamingTests` tient avec le tampon** : la défragmentation tourne sur le
  Fireball avec lecture anticipée, lecture sans latence et cache d'écriture, le
  démarrage et l'installation de `gamer-1993` avec la lecture anticipée du
  Conner, et les repères, la carte, les échantillons et l'activité sont ceux du
  calcul d'un bloc, découpés en paquets de 11, 29 et 37 requêtes.
- **`swift test` : 403 tests passent** (390 avant) ; `DISKCORE_CALIBRATION=1
  swift test --filter Calibration` passe avec ses **trois** problèmes connus,
  les mêmes, tous de fragmentation. L'audit d'allocation n'est pas touché : les
  plans ne dépendent pas de la mécanique, et les 260 bilans de passe ne changent
  que de durée et de seeks.
- **Le coût de calcul**, rendu complet WAV compris, meilleur de trois, en
  release : la défragmentation de la démo (`dev-1993`, 347 → 351 s de son),
  4,80 → 4,88 s ; le recollage de `dev-2003` (200 → 168 s), 3,62 → 3,35 s ; le
  démarrage de `gamer-2003` (69 → 68 s), 0,60 → 0,63 s. De +1 à +10 % par
  seconde de son.
- **L'app compile** (Debug, iPhone 17 Pro Max, iOS 26.5) ; elle n'a pas été
  lancée.

### Ce que chaque cache change, mesuré séparément

Chaque étape est un binaire de `Tools/Measure/`, sous
`MEASURE_DIR=.build/measure-lot7` : `base` (le commit du lot 6), `disk` (tampon,
lecture anticipée, lecture sans latence, bus, coût de commande ; cache
d'écriture coupé), `wcache` (+ cache d'écriture), `soft` (+ `SMARTDRV` et
VCACHE), `recal`. `wcache` a été construit depuis le code final, les deux caches
logiciels coupés par un `sed` restauré aussitôt.

**Les démarrages**, en secondes (colonnes : écart à la précédente) :

| profil | cible | base | disk | wcache | soft | recal | écart |
|---|---:|---:|---:|---:|---:|---:|---:|
| `dev-1993` | 41,8 | 41,8 | +0,4 | 0 | +1,7 | 41,8 | +0,0 % |
| `poweruser-1993` | 42,7 | 42,7 | +0,4 | 0 | +1,6 | 42,7 | +0,0 % |
| `gamer-1993` | 29,5 | 29,4 | +0,3 | 0 | +1,1 | 29,8 | +1,0 % |
| `secretaire-1993` | 36,0 | 35,9 | +0,3 | 0 | +1,6 | 36,1 | +0,3 % |
| `dev-1996` | 58,7 | 58,6 | +1,2 | −1,5 | 0 | 58,9 | +0,3 % |
| `famille-1996` | 54,4 | 54,1 | +0,7 | −1,0 | 0 | 54,3 | −0,2 % |
| `gamer-1996` | 44,0 | 45,2 | +0,9 | −0,9 | 0 | 45,7 | +3,9 % |
| `secretaire-1996` | 55,4 | 54,6 | +0,7 | −0,9 | 0 | 54,9 | −0,9 % |
| `dev-1999` | 57,0 | 58,0 | +2,1 | −3,1 | +1,2 | 57,4 | +0,7 % |
| `famille-1999` | 66,0 | 63,8 | +1,4 | −2,6 | +1,2 | 62,8 | −4,8 % |
| `gamer-1999` | 54,8 | 57,0 | +1,5 | −2,1 | +0,8 | 56,3 | +2,7 % |
| `secretaire-1999` | 56,7 | 57,6 | +1,4 | −2,3 | +1,3 | 57,1 | +0,7 % |
| `dev-2003` | 49,1 | 50,4 | −0,5 | −0,6 | 0 | 50,9 | +3,7 % |
| `famille-2003` | 28,8 | 29,8 | −0,7 | −0,6 | 0 | 29,1 | +1,0 % |
| `gamer-2003` | 70,0 | 69,4 | −2,2 | −0,9 | 0 | 68,3 | −2,4 % |
| `secretaire-2003` | 33,8 | 36,0 | −0,9 | −0,7 | 0 | 35,2 | +4,1 % |
| `dev-2007` | 47,0 | 46,6 | −0,7 | −0,5 | 0 | 46,7 | −0,6 % |
| `famille-2007` | 38,3 | 39,0 | −1,0 | −0,5 | 0 | 38,6 | +0,8 % |
| `gamer-2007` | 29,8 | 32,0 | −0,9 | −0,5 | 0 | 31,2 | +4,7 % |
| `secretaire-2007` | 41,9 | 42,2 | −0,8 | −0,4 | 0 | 42,3 | +1,0 % |

**`disk` allonge les démarrages FAT, et c'est la leçon de l'étape.** De +0,3 à
+2,1 s de 1993 à 1999, pendant que 2003 et 2007 raccourcissent de 0,5 à 2,2 s.
Requête par requête sur `secretaire-1999`, la perte est presque toute dans les
**écritures des dates d'accès**, triées et envoyées d'affilée : 216 écritures,
+1,29 s. Sans coût de commande, la suivante tombait sur un secteur qui arrivait
juste ; avec 0,2 ms de commande, elle le manque d'un cheveu et attend un tour.
L'étape `disk` mesure donc un disque qui n'a jamais existé — une lecture
anticipée sans cache d'écriture — et `wcache` rend ce qu'elle avait pris.

**La lecture anticipée vaut de 2,9 à 6,1 s par démarrage.** Un binaire jetable
(`nora`) garde tout le lot sauf elle : le coût de commande y fait manquer le
secteur suivant à chaque requête contiguë, et les vingt démarrages durent de
11,5 à 24,3 s de plus par époque (quatre démarrages). C'est exactement le tour
que le lot 1 a corrigé : il avait disparu parce que la mécanique était idéale,
sans coût de commande ; il revient avec la commande, et c'est la lecture
anticipée qui le masque, comme sur un vrai disque.

**Le cache d'écriture est l'étape qui pèse**, et là où les écritures se
pressent :

| | `disk` → `wcache` |
|---|---|
| installations de 1993 et 1996 | 0 à −2,3 % (Conner sans cache d'écriture ; Fireball de 76 Ko) |
| installations de 1999 à 2007 | **−7 à −22 %** |
| journées | −2 à −3 % |
| passes FAT, somme des douze volumes | Windows 95 4 h 43 → 4 h 00, JkDefrag 1 h 26 → 1 h 07 |
| passes NTFS, somme des huit volumes | XP 2 h 37 → 1 h 28, UltraDefrag 4 h 04 → 2 h 00, JkDefrag 7 h 03 → 4 h 04, recollage économe 1 h 52 → 1 h 40 |

Il transforme le rythme **là où les écritures arrivent plus vite que le disque
ne les pose** : l'outil de XP sur `dev-2007` pose ses 146 350 écritures en
12 347 vidages, douze par salve, et passe de 292 179 seeks à 44 206 et de
1 h 17 à 38 min. Là où un programme calcule entre deux écritures, il ne groupe
presque rien : l'installation de `famille-2003` pose 8 647 écritures en 7 300
vidages, et ne gagne ses 12 % que parce que le disque écrit **pendant** que
l'installeur décompresse. Le recollage économe, dont les destinations sont
éparses, n'en fait qu'une et quart par vidage : il n'est plus la passe NTFS la
plus rapide (1 h 40 contre 1 h 28 pour XP).

**`SMARTDRV` coûte de 1,1 à 1,7 s** à chaque démarrage de 1993 : sur
`dev-1993` il sert 414 éléments et en lit 1 838, soit 3 Mo de plus que ce qui
est demandé, sur un disque à 1,5 Mo/s. **VCACHE ajoute de 0,8 à 1,3 s** aux
quatre démarrages de 1999 : de 68 à 99 pages de table y sont relues après
éviction, sur 221 à 351 lues. La taille de VCACHE, qui est une hypothèse,
décide du nombre de ces retours bien plus que de la durée — binaires jetables,
les quatre démarrages de 1999 :

| VCACHE | pages relues après éviction | durée |
|---|---:|---:|
| 8 Mo | 153 à 228 | +1,0 à +1,5 s |
| **16 Mo** (retenu) | 68 à 99 | — |
| 32 Mo | 10 à 30 | −0,7 à −1,0 s |

Le retour périodique à la table est donc certain ; sa fréquence ne l'est pas.

### La prédiction qui ne tient pas

L'expert annonçait que la pénalité de fragmentation, mesurée contre le témoin
« jamais fragmenté », **se creuserait** : la lecture anticipée sert un fichier
contigu et presque pas un fichier éclaté. C'était la prédiction la plus
falsifiable du lot. Elle ne tient pas — écart au témoin, somme des quatre
démarrages de chaque époque :

| époque | `base` | `nora` | `soft` | `recal` |
|---|---:|---:|---:|---:|
| 1993 | +0,8 s (+0,5 %) | +1,5 s | +1,5 s | +1,8 s (+1,2 %) |
| 1996 | +6,6 s (+3,2 %) | +6,9 s | +6,5 s | +6,8 s (+3,3 %) |
| 1999 | +17,3 s (+7,9 %) | +18,8 s | +18,3 s | +18,6 s (+8,7 %) |
| 2003 | +1,1 s (+0,6 %) | +0,6 s | +1,1 s | +0,8 s (+0,4 %) |
| 2007 | +2,5 s (+1,6 %) | +3,0 s | +2,0 s | +1,8 s (+1,1 %) |

Sur FAT l'écart se creuse d'un peu plus d'une seconde, mais c'est VCACHE et
`SMARTDRV` qui le creusent, pas la lecture anticipée ; sur NTFS il se resserre.
Même contre un disque sans lecture anticipée (`nora`), elle ne creuse rien :
1999 a 18,8 s d'écart sans elle, 18,3 s avec. Le cache marche — les tests le
chiffrent, et `nora` dit ce qu'il vaut. C'est la prémisse qui manque au modèle :

- **l'écart au témoin est fait du placement des fichiers entre eux** et des
  retours à la table FAT32, pas de fichiers coupés. Sur ces volumes, l'immense
  majorité des fichiers qu'un démarrage lit est d'un seul tenant, sur le disque
  vieilli comme sur le témoin, et les deux gagnent autant à la lecture
  anticipée ;
- **ce n'est pas le placement du calcul.** Un binaire jetable a réparti le coût
  au mégaoctet entre les morceaux d'un fichier, comme le ferait un système à
  pagination à la demande : l'écart ne bouge pas davantage (1999 : +7,1 % sans
  tampon, +7,6 % avec).

C'est le même manque que les trois cibles de calibration du lot 4 : pas assez de
fichiers en morceaux là où un démarrage lit. L'entrelacement, écrit et coupé au
chantier 23, est l'endroit où les deux se jouent.

### Le recalage

Les trois caches en place (`soft`), la dérive est de −5,3 à +5,0 %, et par
époque +4,8 % (1993), −0,4 %, +1,2 %, −1,8 % et −1,6 % (2007). `fit-think.py`,
comme au chantier 22 :

| époque | `perMegabyte` seul | résidus | `perFile` seul | résidus |
|---|---:|---:|---:|---:|
| MS-DOS et Windows 3.1 | 0,80 → 0,652 | ±0,2 s | 0,045 → 0,029 | ±0,2 s |
| Windows 95 | 0,41 → 0,417 | ±1,4 s | 0,022 → 0,0226 | ±1,4 s |
| Windows 98 SE | 0,25 → 0,244 | ±2,8 s | 0,015 → 0,014 | ±2,8 s |
| Windows XP | 0,19 → 0,199 | ±1,8 s | 0,009 → 0,0114 | ±1,6 s |
| Windows Vista | 0,15 → 0,157 | ±1,3 s | 0,009 → 0,0101 | ±1,4 s |

**Les résidus ne désignent plus aucune constante** : à un dixième de seconde
près, l'une ou l'autre seule explique autant. Le chantier 22 avait pu dire
laquelle avait absorbé le défaut ; celui-ci ne le peut pas. `perMegabyte` bouge
seul pour une raison physique, et non statistique : ce qu'un cache déplace, c'est
le coût de la lecture séquentielle, au mégaoctet. Valeurs arrondies au centième,
comme la table : 0,65, 0,42, 0,24, **0,20**, **0,16**. Chaque époque tient
ensuite à **±1,1 %** de sa cible en somme (1993 +0,3 %, 1996 +0,6 %, 1999
−0,4 %, 2003 +1,0 %, 2007 +1,1 %, l'arrondi poussant un peu les deux
dernières), et les vingt démarrages entre **−4,8 et +4,7 %**. La part du calcul
passe de 34–70 % à 30–75 %.

**Ce que le recalage révèle.** `perMegabyte` **descend** en 1993 — le bus ISA,
le coût de commande et `SMARTDRV` y ont rendu le disque plus lent — et **monte**
en 2003 et 2007 : le disque servi par son tampon révèle un plancher processeur
plus lourd que celui qu'on lui prêtait. 0,16 s par mégaoctet pour un Vista de
2007, soit 24 s de calcul pour 150 Mo chargés, et 20 % de moins seulement qu'un
XP de 2003 sur des processeurs trois ou quatre fois plus rapides : rien dans la
description ne le justifie. C'était déjà la remarque du chantier 22, elle est
plus nette maintenant que le disque n'a plus rien à absorber. **Ce sont les
cibles de 2003 et 2007 qu'il faut rediscuter** : ce ne sont pas des mesures
d'époque mais les durées que le modèle donnait avant la relecture, et leur
temps, s'il est réel, n'est pas un coût au mégaoctet — c'est de
l'initialisation de services, que `perFile` décrirait mieux si les quatre
profils d'une époque permettaient de séparer les deux. Ils ne le permettent pas.

### Ce qui a été entendu

**Rien n'a encore été écouté par Gabriel.** L'assistant qui a mené ce lot
n'entend pas : ce qui suit est lu dans les rendus de `base` et `recal`, par
l'enveloppe des transitoires (dérivée du signal, trames de 1 ms), et écrit
avant l'écoute pour qu'elle le confirme ou le démente.

| rendu | transitoires | intervalle médian | taille moyenne des salves (écart > 60 ms) | secondes avec une raie de 90–140 Hz |
|---|---:|---:|---:|---:|
| `boot:gamer-2003`, avant | 1 014 | 28 ms | 6,3 | 4 sur 70 |
| après | 1 170 | 18 ms | 8,4 | 2 sur 69 |
| `install:famille-2003`, avant | 9 925 | 39 ms | 3,3 | 36 sur 521 |
| après | 10 229 | 25 ms | 3,8 | 23 sur 459 |

- **Le démarrage** : des transitoires plus serrés et regroupés en salves plus
  longues ; la tête lit aussi pendant que la machine calcule, une piste
  d'avance, et ses pas de piste tombent hors des requêtes. Le rythme de 110 Hz
  que le lot 6 a rendu audible est toujours là, sur moins de secondes : les
  longues lectures sont servies plus vite.
- **L'installation** : 63 s de moins sur 8 min 41, le crépitement plus dense
  (intervalle médian de 39 à 25 ms), mais **peu de salves nouvelles** : le
  disque écrit pendant que l'installeur décompresse, une écriture à la fois.
  Les salves du cache d'écriture s'entendront plutôt dans une passe de XP sur
  NTFS, où les écritures se pressent.

À écouter, rendus par `bin-base` et `bin-recal` de `.build/measure-lot7` :

| paire | ce qui doit différer |
|---|---|
| `SCENARIO=boot:gamer-2003`, avant / après | lecture pendant le calcul, salves plus longues |
| `SCENARIO=install:famille-2003`, avant / après | un crépitement plus serré, une minute de moins |
| `SCENARIO=dev-2007 STRATEGY=windowsXP`, avant / après | les salves : douze écritures par vidage, dans l'ordre du plateau |
| `SCENARIO=boot:dev-1993`, avant / après | `SMARTDRV` et le bus ISA |

### Le README

Régénéré d'un seul jeu de mesures, `recal`, dont le binaire `final` — celui du
commit — redonne les 340 bilans à l'identique. `readme-tables.py` a d'abord été
validé en reproduisant, depuis les bilans de `base`, les 67 lignes de table du
README précédent et ses chiffres de prose, les journées au texte « activités »
près. 61 lignes de table changent. La prose reprise :

- un paragraphe **« Le tampon du disque »**, avec la table des fiches, et le
  schéma de la chaîne qui le nomme ;
- trois conclusions **qui se renversent** : le recollage économe n'est plus la
  passe NTFS la plus rapide ; le tassage à la frontière est désormais plus long
  que Windows 95 sur les douze FAT (4 h 17 contre 4 h 00) ; et sur `dev-2007`,
  le seek moyen d'UltraDefrag n'est plus plus grand que celui de XP (20 090
  contre 21 199 cylindres), le cache posant les écritures des deux dans l'ordre
  de l'ascenseur — l'ancien écart est daté ;
- le recalage, et ce qu'il révèle ; VCACHE et `SMARTDRV` au démarrage ;
- « Ce qui ne l'est pas » : le cache existe, et le système ne le vide jamais.

Trois chiffres étaient **déjà périmés avant ce lot**, et ont été remesurés : la
démo de démarrage de l'en-tête (« 51,0 s, dont 40 % » quand `base` donnait
57,6 s et 43 %), celle de défragmentation (« 1 414 fichiers » quand le bilan en
compte 1 450), et le gain du préchargeur sur `famille-2007` (« 1 051 à 660
seeks » quand `base` en comptait 773), remesuré par un binaire jetable où Vista
lit dans l'ordre du registre : 890 seeks à 44 114 cylindres sans préchargeur,
635 à 18 757 avec, 43,6 s contre 38,6.

Hors du README : les **fourchettes de durée de l'écran de choix d'outil**,
recopiées à la main des bilans comme au chantier 24 ; et l'écran des
instruments, dont « Où passe le temps » gagne une part **tampon** — le temps
qu'une commande servie par lui a pris à l'hôte —, sans quoi le transfert y
aurait fondu sans que rien le dise.

### Laissé ouvert

- **La prédiction de l'écart au témoin** n'est pas confirmée, et la raison est
  dans les volumes, pas dans le cache : trop peu de fichiers en morceaux là où
  un démarrage lit. Elle se rejouera avec l'entrelacement.
- **Les hypothèses de ce lot**, à trancher sur source : la lecture sans latence
  des Seagate ; leur segmentation ; la profondeur de la lecture anticipée (une
  piste) ; un coût de commande de 0,2 ms sur les machines de 2003 et 2007, mesuré
  sur un Pentium II ; l'UDMA/100 nominal de ces machines ; la mémoire de la
  machine de 1993 (4 Mo) et la taille de VCACHE (16 Mo) ; un disque qui pose
  ses écritures dès qu'il est libre.
- **Le système ne vide jamais le cache** : aucun `FLUSH CACHE` aux points de
  contrôle de NTFS ni à la validation d'un déplacement. Si l'outil de XP le
  faisait, ses salves seraient bornées à cinq secondes d'écritures, et une part
  de son gain avec.
- **Ce que le tampon n'a pas** : la lecture anticipée du système — Windows 95 et
  98 lisaient 64 Ko d'avance (« optimisation de la lecture anticipée ») —,
  l'écriture différée de `SMARTDRV`, `SMARTDRV` pendant les installations et les
  journées de 1993, et le cache de NT, qui garde tout un démarrage.
- **`InstallEra.writeRequestSectors` n'est toujours pas plafonné** : le lot 1
  l'avait rendu possible, aucun lot ne l'a fait. Avec un cache d'écriture de
  76 Ko, les écritures de 128 Ko de Windows 95 passent au travers.
- **Le planificateur ignore le tampon** : l'horloge estimée des points de
  contrôle NTFS (`OperationSink.plannedSeconds`) et `AccessCost` supposent
  toujours un disque sans cache, et les passes NTFS durent désormais moitié
  moins que ce qu'ils estiment.
- **L'écoute par Gabriel**, les paires ci-dessus. Le CPU sur l'iPhone n'a pas été
  mesuré ; le rendu hors-ligne dit +1 à +10 % par seconde de son.
- **Les cibles de 2003 et 2007** : à rediscuter, ou à remplacer par des
  mesures d'époque.

## Chantier 27 — le lot 8 : le reste

**Fait** · branche `experts`

### Le problème

Le solde de `LEDGER-EXPERTS.md` rangeait sous « ce qu'aucun lot n'a pris »
six demandes des revues, et deux points que les lots 4 et 7 s'étaient passés :

| | où | ce qui manquait | mesuré avant |
|---|---|---|---|
| système §3, recoupement 2 | `NTFSAllocator` | quatre constantes de calcul qui règlent la fragmentation, ni mesurées ni dites | — |
| ch. 23 | même endroit | la recherche d'une extension partait du curseur, pas du fichier | `famille-2003` : 3 187 ms de génération, ×5,2 depuis le lot 4 |
| disque §3.3 | `sustainedMBs` | un écart au débit des fiches toujours du même côté | +5, +2, +14 %, à 20 % de tolérance |
| disque §4.3 | `SeekProfile.settle` | le même settle en lecture et en écriture | — |
| disque §3.3, ch. 26 | `InstallEra.writeRequestSectors` | 512 Ko et 1 Mo par requête | — |
| système §6.4 | `AllocationHint` | `.temporary` promet un placement à part ; `.boot` n'est produit par rien | — |
| système §6.7, §7 | `ProfileSpec.clusterCount`, `PartitionGeometry`, `BootSession` | ni tables ni `$Boot` déduites ; `$Bitmap` lue là où un fichier est posé ; l'enregistrement MFT est le rang de lecture ; installations et journées arrondies au cluster | `gamer-1999` : 8,4 Mo de tables comptés en clusters |

### Les décisions

**Les constantes de `NTFSAllocator` sont mesurées, et dites dans son en-tête,
pas changées.** Un binaire jetable les lisait dans l'environnement ; chacune a
été bougée seule, sur les huit volumes NTFS (fichiers fragmentés parmi les
fragmentables, code final) :

| réglage | `famille-2003` | `secretaire-2003` | `dev-2007` | `famille-2007` |
|---|---:|---:|---:|---:|
| tel quel (2, 64, 65 536) | 7,6 % | 13,6 % | 9,1 % | 21,1 % |
| `reuseTolerance` = 4 | 9,4 % | 12,4 % | 9,2 % | 20,2 % |
| `reuseTolerance` = `.max` | 5,8 % | 13,1 % | 8,1 % | 16,5 % |
| `searchWindow` = 16 | 12,8 % | 13,6 % | 7,6 % | 18,3 % |
| `searchWindow` = 256 | 11,1 % | 14,2 % | 8,6 % | 19,8 % |
| `searchHorizon` = 16 384 | 21,2 % | 14,7 % | 6,9 % | 21,6 % |
| `searchHorizon` = 262 144 | 4,6 % | 12,6 % | 7,2 % | 12,9 % |

- La revue disait qu'elles « poussent toutes vers la contiguïté ». **Pas
  toutes** : élargir la tolérance jusqu'au best-fit pur, ou l'horizon, *réduit*
  la fragmentation — la borne renonce au trou juste qui était plus loin.
- **L'horizon décide le plus** : ×4,6 sur `famille-2003`, quand la tolérance ne
  va que de 5,8 à 9,4 %.
- **Aucune ne rejoint la cible** de 40 à 60 %.
- **`famille-2003` est chaotique** : réserver `$Bitmap` (trois cents clusters,
  plus bas) l'a fait passer de 10,5 à 7,6 % sans toucher à l'allocateur. Le
  premier balayage, fait avant cette étape, donnait d'autres chiffres pour les
  mêmes conclusions ; la table est celle du code livré.
- Le coût est sans ambiguïté : sans tolérance, la génération de `dev-2007` passe
  de 1,7 à 14,6 s.
- **`growthMarginClusters` a été retiré** : au-delà du `highWater` il n'y a
  qu'un trou, et chercher 64 Ko de marge y rend le même premier cluster. Les
  huit empreintes NTFS étaient identiques à 0 et à 16. Retirer une constante
  inerte n'est pas changer une valeur.

**Une extension cherche près du fichier.** Quand le prolongement en place
échoue, la recherche part du cluster qui suit ce qui vient d'être pris, et non
du curseur ; les fenêtres de repli partent de là et reviennent au début. C'est
ce que fait le pilote NTFS de Linux (`fs/ntfs/attrib.c`,
`ntfs_attr_extend_allocation` : « We want to begin allocating clusters starting
at the last allocated cluster to reduce fragmentation ») ; `ntfs_cluster_alloc`
ne prend la position courante que sans cette indication. Au passage, le
`commit` d'un seul extent ne crée plus de tableau. Les deux ensemble :

| volume | avant | après | |
|---|---:|---:|---:|
| `dev-1993` (démo) | 50 ms | 50 ms | ×1,00 |
| `secretaire-1999` (démo) | 32 ms | 32 ms | ×1,00 |
| `dev-1996` | 193 ms | 194 ms | ×1,01 |
| `dev-1999` | 274 ms | 271 ms | ×0,99 |
| `secretaire-2003` | 171 ms | 164 ms | ×0,96 |
| `dev-2003` | 1 098 ms | 1 061 ms | ×0,97 |
| `gamer-2007` | 468 ms | 384 ms | ×0,82 |
| `dev-2007` | 1 763 ms | 1 647 ms | ×0,93 |
| `famille-2007` | 2 133 ms | 1 488 ms | ×0,70 |
| `famille-2003` | 3 187 ms | 2 113 ms | ×0,66 |

(meilleure de neuf, en alternance, binaires `base` et `fs`, machine au calme.)
FAT n'est pas touché : empreintes identiques. Sur NTFS, les volumes de 2007
gagnent la traîne de fichiers en deux à seize morceaux que la revue système
(§2) réclamait — `dev-2007` de 0,5 à 5,5 % des fragmentables, `famille-2007` de
5,3 à 15,8 % — et `famille-2003` perd un peu de la sienne. `famille-2003` reste
à ×3,4 de ce qu'il coûtait avant l'écriture par paquets : chaque paquet qui ne
prolonge pas lance toujours une recherche bornée.

**Pas de facteur de format.** La mesure l'a écarté. Les secteurs par piste du
modèle sont déduits de la capacité et du nombre de pistes : ce sont déjà des
secteurs de données, et un tour les lit tous, rafales servo comprises. Le biais
était dans la comparaison : `sustainedMBs` est un débit brut, alors que le
« sustained data transfer rate » d'un manuel est celui d'une lecture
séquentielle, qui paie commutations de tête et pas de piste — ce que
`DiskMechanics` simule depuis le lot 1. Lecture simulée de vingt cylindres au
bord, tête posée :

| disque | brut | simulé | fiche | écart |
|---|---:|---:|---:|---:|
| 7200.7 (2003) | 60,8 | 54,3 | 58 | −6,5 % |
| 7200.10 (2006) | 79,3 | 74,3 | **72** | +3,1 % |
| 7200.11 (2008) | 119,7 | 111,0 | 105 | +5,7 % |

Des deux côtés, et dans les 10 % : **la tolérance descend à 10 %**
(`SequentialThroughputTests`), et le test du débit brut devient une borne
(brut > fiche, à moins de 20 %). Un 0,90 appliqué au transfert aurait mis deux
disques sur trois à −16 %. Les manuels Seagate donnent d'ailleurs le débit du
canal (« internal data transfer rate », 85,4 Mo/s sur le 7200.7, 1 287 Mbit/s
sur le 7200.11) : 0,65 à 0,68 du soutenu, format, codage et commutations
mêlés — rien qui ressemble au 0,90 de la revue, et rien qui s'applique à des
secteurs déjà de données.

**Une erreur de fait, trouvée en relisant la table du 7200.10.** Le catalogue
donnait au ST3320620A 78 Mo/s, 8,5 ms et 1,0 ms : ce sont les chiffres des
750 et 500 Go. La table 2 du manuel (100402369, rév. F), celle des 400 et
320 Go, dit 72 Mo/s (colonnes d'unités interverties dans le PDF),
« Average seek, read <11.0 » et « <0.8 (read) ». Corrigé en étape à part
(`fiche`) : le piste-à-piste des disques de 2007, interpolé entre 2006 et 2008,
passe de 1,0 à 0,9 ms, et les démarrages de 2007 bougent de 0,2 s au plus.

**Le settle d'écriture, pris dans les manuels.** Tous ceux du catalogue sauf le
Conner publient une colonne « Write », relevée dans les PDF de
`disknoise.resources/manuels` :

| fiche | seek moyen L / É | piste-à-piste L / É |
|---|---|---|
| Fireball TM (1080 Mo, un plateau) | 12,0 / 14,0 | 3,0 / — |
| U8 | 10,5 / 11,5 | 1,5 / 2,1 |
| Barracuda ATA IV (un plateau) | 9,0 / 10,0 | 1,0 / 1,2 |
| 7200.7 | 8,5 / 9,5 | 1,0 / 1,2 |
| 7200.10 (320 Go) | 11,0 / 12,0 | 0,8 / 1,0 |
| 7200.11 | 8,5 / 9,5 | 1,0 / 1,2 |

Une seconde loi est calée sur les deux durées d'écriture, sur la même course ;
son excédent sur la loi de lecture, distance par distance, allonge le settle
d'un seek qui précède une écriture — le bras ne va pas plus vite. Le modèle
garde les **rapports** de la table : le U8 annonce 8,9 ms en tête de manuel et
10,5 dans sa table, et un disque de la galerie a son propre seek moyen. Il
prend le rapport de la fiche la plus proche qui le publie ; le Conner n'en a pas
(le manuel du Cougar non plus), et 1993 prend celui du Fireball — hypothèse.
L'ATA IV se contredit (0,95 / 0,76 dans une table, 1,0 / 1,2 dans l'autre) :
l'écriture sous la lecture n'étant pas physique, la seconde est retenue. Seuls
les seeks de positionnement changent ; les pas de piste d'un transfert restent
ceux du skew.

**Le plafond des requêtes d'installation** : 128 secteurs sous MS-DOS (ses
tampons de 64 Ko) et sous XP (le découpage à 64 Ko de la revue), 256 sous
Windows 95, 98 et Vista — la limite d'une commande ATA sans LBA48, que Vista
garde faute de source sur son pilote alors que les disques de 2007 sont en
LBA48. Le docstring justifiait les grandes requêtes par « attendre un demi-tour
de plateau deux cent mille fois » ; il dit maintenant ce que le cache a changé,
mesuré par deux binaires jetables sans cache d'écriture :

| installations (somme des quatre) | sans cache : sans → avec plafond | avec cache (livré) |
|---|---:|---:|
| 1999 | +0,9 % | +0,1 % |
| 2003 | **+12,4 %** | +1,5 % |
| 2007 | **+9,0 %** | +1,2 % |

**`.temporary` et `.boot` sont retirés.** Le premier était traité comme
`.normal` par les deux allocateurs ; le second n'était rendu par aucune
catégorie. La documentation de `AllocationHint` dit pourquoi ni l'un ni l'autre
n'avait à exister. Empreintes des volumes identiques ; le test du chargeur
d'amorçage FAT, qui exerçait une mécanique que rien n'employait, est retiré, et
`AllocatorInvariantTests` passe son fichier contraint en `.system`.

**Le format a sa place, la même pour les deux modules** (`FormatOverhead`,
nouveau fichier du noyau) :

- `ProfileSpec.clusterCount` déduit les secteurs réservés, les deux tables (avec
  leurs deux entrées réservées) et la racine d'un FAT16, par le calcul
  circulaire de `FORMAT` ; `PartitionGeometry` fait le même calcul. Les tables
  de `gamer-1999` font 8,4 Mo, et non 17 : la revue comptait en clusters de
  4 Ko, que le lot 2 a portés à 8. Le plafond du format reste une troncature
  (c'est ce que ferait le disque), mais un test vérifie qu'aucun profil du
  catalogue n'y tombe ;
- sur NTFS, **`$Boot` est le cluster 0** : le modèle réservait seize secteurs
  *en plus* des deux clusters que le générateur lui donne, et décalait tout le
  volume de 8 Ko. La copie du secteur d'amorçage suit le dernier cluster ;
- **`$Bitmap` est posée derrière la zone MFT d'origine**, un bit par cluster,
  arrondi à huit octets — là où `mkntfs` pose ses métafichiers non résidents
  (`allocate_scattered_clusters`, qui part de `g_mft_zone_end`) et où le
  simulateur la lisait déjà, sur des clusters que le générateur donnait au
  premier fichier venu ;
- **`NTFSProfile.forVolume`** porte la table de `FORMAT` que seul
  `FormatRulesTests` connaissait, et les huit descriptions NTFS perdent leur
  `clusterKB`.

**L'enregistrement MFT est celui du volume** (`MFTNumbering`) : derrière les
seize métafichiers, les répertoires puis les fichiers vivants, dans l'ordre de
création. Le démarrage, les dates d'accès et les cinq outils NTFS l'emploient.
La lecture groupée du préchargeur lit les enregistrements triés, une requête
par suite continue. Une date d'accès salit désormais la **page** de 4 Ko de
`$MFT` qui porte l'enregistrement, pas l'enregistrement : `$MFT` passe par le
gestionnaire de cache comme un fichier. Sur un démarrage de `secretaire-2003`
réduit, 994 fichiers horodatés font 430 écritures — 815 à la granularité de
l'enregistrement, moins de 250 quand les numéros suivaient l'ordre de lecture.
Le test qui exigeait un rapport de quatre le tenait d'un artefact ; il exige
deux, et dit pourquoi.

**Installations et journées à la page** : `InstallEra.granularity`, le choix
de `Era.readGranularity` au lot 3 — le secteur sous MS-DOS, 4 Ko ensuite. La
journée 20 de `dev-1996`, en clusters de 32 Ko, lit 142 Mo au lieu de 210.

### Ce que chaque étape change

Binaires sous `MEASURE_DIR=.build/measure-lot8` : `base` (le commit du lot 7,
identique octet pour octet à son `bin-final`, dont les 340 bilans ont été
repris), `hint` (ancrage et `commit`), `settle`, `fiche`, `req`, `fs` (points 6
et 7), `final` (le code du commit, 340 bilans identiques à `fs`). Jetables :
`knobs`, `knobs3` (les constantes), `nowc-cap` et `nowc-nocap` (sans cache
d'écriture), `nomft` (sans numérotation MFT).

| groupe (somme) | base | hint | settle | fiche | req | final |
|---|---:|---:|---:|---:|---:|---:|
| installations 1993 | 56 min 02 | 0 | +0,1 % | 0 | 0 | −0,6 % |
| installations 1996 | 37 min 40 | 0 | 0 | 0 | 0 | −1,2 % |
| installations 1999 | 37 min 11 | 0 | 0 | 0 | +0,1 % | 0 |
| installations 2003 | 37 min 00 | 0 | 0 | 0 | +1,5 % | +2,2 % |
| installations 2007 | 51 min 13 | 0 | 0 | 0 | +1,2 % | +2,6 % |
| journées | 16 min 01 | 0 | 0 | 0 | 0 | −2,5 % |
| Windows 95, douze FAT | 4 h 00 | 0 | +2,2 % | | | +6,6 % |
| tassage à la frontière | 4 h 17 | 0 | +2,3 % | | | −1,7 % |
| XP, huit NTFS | 1 h 28 | +34,5 % | +35,1 % | | | +32,8 % |
| UltraDefrag | 2 h 00 | +16,0 % | | | | +14,4 % |
| JkDefrag NTFS | 4 h 04 | +10,8 % | | | | +12,5 % |
| recollage économe | 1 h 40 | −10,7 % | | | | −11,8 % |

(colonnes : écart cumulé à `base` ; vide = inchangé depuis la précédente.)

- **L'ancrage** ne change que les passes NTFS, parce qu'il change les volumes
  de 2007 : plus de fichiers en quelques morceaux, que XP recopie en entier
  (+33 %) et que le recollage recolle vite (−12 %). Le recollage redevient la
  passe NTFS la plus rapide, conclusion que le lot 7 avait renversée.
- **Le settle d'écriture** pèse peu : +2 % sur les passes FAT, +0,1 % sur les
  installations. Le cache d'écriture du lot 7 pose les écritures en fond ; le
  settle s'allonge sur des seeks que l'hôte n'attend plus. Il s'entend dans
  les vidages, pas dans les durées.
- **Le plafond** coûte ce que la table plus haut mesure.
- **L'étape `fs`** régénère tous les volumes FAT (moins de clusters) et décale
  NTFS : Windows 95 +4 %, le tassage à la frontière −4 %, qui repasse devant
  (4 h 12 contre 4 h 16) — une conclusion du lot 7 renversée par des volumes à
  peine plus petits. `dev-1999` sous Windows 95 passe de 46 min à 1 h 00,
  11 218 Mo déplacés au lieu de 8 602 : à 93 % de remplissage, trois mégaoctets
  de tables en moins suffisent.

### Les démarrages, et ce qui n'a pas été recalé

| époque | cible | lot 7 | lot 8 | écart |
|---|---:|---:|---:|---:|
| 1993 | 150,0 | 150,4 | 149,6 | −0,3 % |
| 1996 | 212,5 | 213,8 | 213,6 | +0,5 % |
| 1999 | 234,5 | 233,6 | 234,3 | −0,1 % |
| 2003 | 181,7 | 183,5 | 187,7 | **+3,3 %** |
| 2007 | 157,0 | 158,8 | 163,4 | **+4,1 %** |

Par profil, de −4,1 % (`famille-1999`) à +8,4 % (`gamer-2007`), contre −4,8 à
+4,7 % au lot 7. **La dérive de 2003 et 2007 vient entière de la numérotation
MFT** : le binaire `nomft`, qui a tout le lot sauf elle, ne bouge aucun
démarrage NTFS de plus de 0,1 s. Avec elle, chaque ouverture va chercher un
enregistrement épars : 503 → 681 seeks sur `dev-2003`, +0,4 à +1,7 s par
démarrage. C'est le sautillement que la revue annonçait, et il coûte.

> *Précisé au chantier 29*, qui a rejoué `nomft` : l'attribution tient par
> époque (sans la numérotation, 2003 et 2007 sont à −0,7 et −0,1 s du lot 7),
> pas au profil près — `famille-2003` bouge de −0,5 s, `dev-2007` de +0,3 s.

**`ThinkModel.boot` n'est pas recalé**, comme demandé : la dérive rejoint des
cibles de 2003 et 2007 que le lot 7 disait suspectes. ~~Si on les garde, un
recalage monterait encore le coût au mégaoctet de XP et de Vista, ce que rien
ne justifie ; c'est aux cibles, pas aux constantes, qu'il faut toucher.~~

> *Corrigé au chantier 29.* Le signe était faux : les sommes de 2003 et 2007
> sont **au-dessus** de leur cible, et un recalage fait **descendre** le coût au
> mégaoctet — `fit-think.py` donne 0,192 et 0,148, les valeurs d'avant le lot 7.
> La hausse du lot 7 compensait les seeks de MFT que ce lot-ci a rendus au
> disque. Le chantier 29 a recalé à 0,19 et 0,15.

**`InstallEra.think` non plus.** Ses constantes n'ont jamais été calées sur
rien — les installations n'ont pas de cible — et le lot les déplace de −1,2 à
+2,6 % par époque. Un recalage n'aurait rien à viser : il demande d'abord des
durées d'installation d'époque.

### Ce qui valide

- **`swift test` : 413 tests passent** (403 avant) : le débit séquentiel à
  10 %, le seek d'écriture plus long sur les sept fiches qui le publient (et
  seulement son settle), aucune requête d'installation au-delà de 256 secteurs
  ni aucune époque qui en demande plus, la fin d'un fichier écrite à la page,
  les clusters et leurs tables qui tiennent sur le disque pour les vingt
  profils (sans un cluster de libre de plus), la partition du simulateur qui
  compte les mêmes clusters, `$Bitmap` réservée et lue au même endroit,
  `$Boot` au cluster 0, un même enregistrement MFT pour le démarrage et le
  défragmenteur, et des ouvertures qui ne lisent plus des enregistrements
  consécutifs.
- L'audit d'allocation (`AllocationInvariantTests`) et l'identité flux / bloc
  (`StreamingTests`) passent sans retouche.
- `DISKCORE_CALIBRATION=1 swift test --filter Calibration` : trois problèmes
  connus, les mêmes — `dev-1996` 8,1 %, `secretaire-1999` 5,5 %,
  `famille-2003` 7,6 % (13,0 avant ; le message du test suit).
- **Le lancement de l'app** (Debug, iPhone 17 Pro Max, iOS 26.5, build de ce
  lot contre celui du lot 7 dans un worktree jetable, en alternance) : premier
  écran en 4,5 à 6,1 s avant, 3,9 à 5,1 s après, et 3,9 à 4,5 s de processeur
  jusqu'au repos pour les deux. Les démos ne changent pas (FAT) ; ce que le
  lot rend, il le rend aux disques NTFS de la galerie, à leur ouverture.

### Le README

Régénéré d'un seul jeu de mesures, `final`. `readme-tables.py` a d'abord
reproduit depuis `base` les 67 lignes de table du README précédent (les
journées au texte « activités » près) ; 57 lignes changent, plus les quatre
journées. La table des trois allocateurs vient d'`AllocatorComparison` (NTFS :
pire fichier 138 → 390 extents, trous 441 → 216). La prose reprise : le seek
d'écriture ; le contrôle du débit à 10 % ; l'exception des constantes NTFS au
principe du résidu ; l'extension près du fichier et `$Bitmap` ; le coût de
génération ; les renversements (recollage économe, frontière contre 95) ; les
requêtes de 4 Mo des défragmenteurs dans « Ce qui ne l'est pas ». Hors du
README, les fourchettes de l'écran de choix d'outil sont recopiées des bilans
de `final`.

### Laissé ouvert

- **Les requêtes des défragmenteurs** — 4 Mo pour XP et JkDefrag, 256 Ko pour
  Windows 95 — ne sont pas découpées. Le plafond est posé dans l'installeur ;
  à sa place logique, l'interface du disque, il vaudrait pour tous.
- **Les constantes de `NTFSAllocator`** sont dites, pas sourcées ; et
  `famille-2003` se montre chaotique à trois cents clusters près.
- **Le Conner de 1993** reçoit le seek d'écriture du Fireball, par hypothèse.
- **Les cibles de démarrage de 2003 et 2007**, plus loin encore (+3,3 et
  +4,1 %), et **des durées d'installation** d'époque, que rien ne donne.
- **La numérotation MFT** est une approximation : NTFS reprend le plus petit
  enregistrement libre, et le rejeu ne le suit pas.
- **Les trois cibles de fragmentation**, toujours entre la borne basse livrée
  et l'entrelacement.

---

## Chantier 28 — le rangement intelligent

**Fait** · branche `rangement-intelligent`

### Le problème

Un rangement pour FAT et NTFS, qui s'adapte aux vingt disques de la galerie
et minimise trois mesures prises **après** la passe : la durée du
démarrage du disque rangé, le nombre de morceaux des fichiers fragmentés, le
nombre de trous de l'espace libre. La durée de la passe n'en est pas.

Aucun outil existant ne visait le démarrage, et aucun bilan ne le mesurait
après une passe : l'app sait démarrer un disque rangé, pas RenderTrace.
`SCENARIO=boot:<profil>` accepte donc une `STRATEGY` — la passe est planifiée
sans être simulée, le disque réarrangé est démarré, et le bilan de la passe
suit celui du démarrage. `Tools/Measure/smart.sh` démarre chaque disque après
chaque outil de son format ; `smart.py`, `passes.py` et `smart-table.py`
tabulent.

Ce que faisaient les outils existants (binaire `base`, commit du lot 8 plus
cette seule mesure), en sommant les douze FAT et les huit NTFS :

| | démarrage FAT | morceaux FAT | trous FAT | démarrage NTFS | morceaux NTFS | trous NTFS |
|---|---:|---:|---:|---:|---:|---:|
| disque livré | 597,5 s | — | — | 351,1 s | — | — |
| Windows 95 / XP | 576,5 s | 15 129 | 1 349 | 348,5 s | 125 927 | 73 089 |
| JkDefrag | 584,3 s | 9 333 | 4 511 | 346,1 s | 13 763 | 8 904 |
| UltraDefrag | 593,2 s | 36 054 | 16 931 | 348,9 s | 34 935 | 44 164 |
| frontière / recollage | 589,0 s | 1 382 | 129 | 355,6 s | 8 411 | 3 451 |

Ranger ne fait presque rien au démarrage : 3 % au mieux sur FAT, et le
recollage économe le **ralentit** sur NTFS.

### Ce qu'il y avait à gagner

Avant d'écrire une stratégie, un rangement posé à la main (un « oracle »
jetable dans RenderTrace) : tous les fichiers bout à bout, dans l'ordre de
l'arborescence, ou les fichiers du démarrage d'abord, dans l'ordre où il les
lit. Le second retire de 3,5 à 6 s aux démarrages FAT et de 1,5 à 2,5 s aux
NTFS par rapport au premier ; y ajouter les répertoires dans l'ordre de leur
première lecture, 0,3 s de plus. Le poser derrière la zone MFT plutôt que
dedans coûte 0,3 s au pire. Ce qui reste du temps de disque est de la lecture
séquentielle et de la latence : la borne est là.

L'information n'est pas un privilège de simulateur. Le préchargeur de
Windows XP écrit dans `Layout.ini` ce que lit un démarrage, et le défragmenteur
de XP range ces fichiers à la suite ; « Réorganiser les fichiers programme »
de Windows 98 lisait les journaux du moniteur de tâches. `BootLayout` est cette
liste, tirée du démarrage planifié (`BootPlan.readOrder`, dans l'ordre de la
première lecture de données, répertoires compris), et confiée par
`ScenarioBuilder.prepared` à qui sait la lire (`BootLayoutConsumer`).

### Les décisions

**Un seul moteur, celui du tassage à la frontière.** C'est déjà lui qui laisse
FAT sans morceau déplaçable et d'un seul trou. La passe y ajoute trois temps
(`SmartDefragStrategy`) :

1. **le bloc de démarrage** : chaque élément de `Layout.ini`, à la frontière,
   dans l'ordre, par `place` ; ce qui gêne est poussé au fond du volume. Une
   fois posé, le bloc devient un obstacle et la frontière repart de zéro. Un
   élément qui ne tient pas devant un obstacle saute l'obstacle : sur
   `dev-2003`, les métafichiers de 8 clusters qui suivent la zone MFT faisaient
   sauter les gros fichiers du lancement, évacués au fond puis rangés là — le
   démarrage était **plus lent** (52,6 s) que celui du disque livré ;
2. **la queue d'abord** (`compactTailFirst`) : les fenêtres qui suivent la
   dernière assez grande pour tout l'espace libre sont balayées avant le reste.
   Tassé vers le début, l'espace libre finissait semé entre les morceaux du
   fichier d'échange (`famille-1996`, 95 trous) ou entre de petits métafichiers
   NTFS (`famille-2007`, 21). Deux pièges en route : pendant ce balayage, tout
   l'espace libre est **derrière** la frontière, où l'évacuation ne cherche que
   dans les refuges — la tête entière en devient un, relu à chaque évacuation ;
   et après lui, la queue pleine doit devenir un obstacle, sans quoi le second
   balayage comptait sur ses fenêtres et abandonnait des fichiers (822 sur
   `famille-1996`) ;
3. **le tassage** du reste.

**Chasser entier, mais seulement ce qui est surtout dans la place**
(`clear`). `place` pousse morceau par morceau, et ce qui part en morceaux au
fond revient en morceaux : sur `famille-2003`, un fichier de 1,3 Go finissait
en 4 495 morceaux. Chasser chaque occupant entier dans le plus petit trou à sa
taille corrigeait cela, mais déménageait aussi un fichier de 500 Mo pour un
cluster qui mordait sur la place : 33 Go déplacés sur `secretaire-1999`, un
volume de 4,5 Go. D'où la règle : entier si plus de la moitié du fichier est
dans la place, sinon le morceau qui gêne.

**Sur NTFS, les géants suivent le bloc** (`giants`, plus du quart de l'espace
libre). `famille-2003` porte 41 imports musicaux de 0,65 et 1,3 Go ; les
métafichiers épars de la fin du volume la découpent en fenêtres, et le
balayage y arrivait avec eux et un espace libre semé en refuges. Première
tentative, les poser d'abord en haut des fenêtres de fin, du plus gros au plus
petit : 64 Go de va-et-vient sur ce volume de 40 Go, 14 géants qui échouaient
quand même, 18 trous. Derrière le bloc, là où la frontière passe de toute
façon : 72 Go en tout au lieu de 93, 14 trous.

**Une zone MFT épuisée n'est plus respectée** (`withoutSpentZone`). Sur
`dev-2003`, plein à 95 %, les fichiers occupent 741 000 des 791 000 clusters de
la zone, et 585 des 589 trous restants étaient entre eux. Au-delà de la moitié
occupée, la zone ne réserve plus rien, et la passe la tasse : 1 trou.

**Le tampon de l'époque** : 256 Ko sur FAT comme Windows 95, 4 Mo sur NTFS
comme XP. Il ne change que la durée de la passe.

**Une seule stratégie, `smart`**, comme UltraDefrag et JkDefrag, et non deux
(`smartFAT`, `smartNTFS`, les noms des étapes de mesure) : tout ce qui sépare
les deux formats — le tampon, les géants, la zone MFT — se lit sur le volume au
moment de planifier. L'écran de choix n'a qu'un outil à proposer, sur les deux
formats.

### Ce que chaque étape a changé

Binaires sous `MEASURE_DIR=.build/measure-smart` : `base`, `s1` (bloc, frontière
qui continue derrière lui), `s2` (bloc en obstacle et repartir de zéro, chasser
entier, géants en haut du volume), `s3` (zone épuisée, queue d'abord), `s4`
(chasser seulement ce qui est surtout dans la place, géants derrière le bloc,
tampons), `final` (identique à `s4` en mesures), `one` (la même passe sous un
seul identifiant : bilans identiques à `final`, au nom de l'outil près).

| étape | démarrage FAT | trous FAT | démarrage NTFS | morceaux NTFS | trous NTFS | passes FAT / NTFS |
|---|---:|---:|---:|---:|---:|---:|
| s1 | 519,9 s | 114 | 329,3 s | 4 471 | 800 | |
| s2 | 518,5 s | 123 | 323,9 s | 0 | 646 | |
| s3 | 518,5 s | 46 | 323,3 s | 0 | 42 | 10 h 22 / 29 h 54 |
| final | 518,5 s | 49 | 323,3 s | 0 | 38 | 4 h 41 / 15 h 43 |

Les morceaux FAT restent à 1 382 d'un bout à l'autre : ce sont tous ceux des
fichiers d'échange, et les 990 de `gamer-1993`, plein à 100 %.

### Ce qui valide

- **Par volume** (table du README) : le démarrage est le plus court des cinq
  outils de son format sur les vingt disques, sauf `gamer-1993` où rien ne
  bouge. Les morceaux sont au plus ceux du meilleur autre outil — zéro sur les
  huit NTFS. Les trous aussi, sauf `gamer-1999` : 24 contre 18 à la frontière
  seule.
- Le bloc atteint la borne de l'oracle : 50,0 s sur `dev-2003`, 37,1 s sur
  `dev-1993`, 52,0 s sur `famille-1999`, 35,1 s sur `famille-2007`.
- **Rien d'autre ne bouge** : les 12 passes de la frontière et les 20
  démarrages des disques livrés sont identiques à `base` au bilan près — les
  deux retouches du moteur (`place(far:)`, `repairInHoles` depuis la frontière)
  ne changent rien quand la frontière part de zéro.
- `swift test` : tout passe, dont cinq tests nouveaux (le bloc dans l'ordre de
  lecture, les fenêtres de queue remplies, la zone épuisée tassée et la zone
  vide respectée, une passe complète sur le volume vieilli, `Layout.ini` qui
  nomme chaque élément une fois) ; l'invariant « aucun plan n'écrit sur une
  donnée vivante » couvre désormais les quinze stratégies.
- L'app compile ; l'écran « Avec quel outil ? » propose le rangement sur les
  deux formats, avec les fourchettes mesurées.

### Laissé ouvert

- **La durée des passes NTFS** : un tassage complet, 1,3 To et 15 h 43 pour les
  huit volumes. Combler les trous par des fichiers pris au-delà de la fin
  prévue, plutôt que faire glisser la suite, déplacerait à peu près l'espace
  libre seulement ; greffé sur le moteur de la frontière, l'essai a ramené
  `secretaire-2007` de 254 à 81 Go mais laissé 10 trous au lieu d'un sur
  `dev-2003`. Il faudrait un moteur à lui.
- **`gamer-1999`** (24 trous) et **`famille-2003`** (14) : l'espace libre ne
  tient dans aucune fenêtre seule, ou les géants laissent des refuges.
- **Les lectures partielles** : un gros fichier dont le démarrage ne lit que la
  tête est posé entier dans le bloc, et la tête saute sa queue.
- **`Layout.ini` est parfait ici** : il vient du démarrage planifié, exactement
  celui qu'on mesure ensuite. Le vrai retient les six derniers démarrages, et
  ne connaît pas l'application du jour.

---

## Chantier 29 — le lot 9 : l'audit du solde

**Fait** · branche `experts`

### Le problème

`AUDIT-EXPERTS.md` a relu de l'extérieur les huit lots des chantiers 20 à 27,
et son verdict tient en une phrase : **le solde est honnête sur ce qu'il compte,
et faux sur ce qu'il croit avoir compté.** Les chiffres des journaux se
reproduisent au dixième de seconde, les tables du README à la ligne ; mais trois
choses que le solde affirmait ne tenaient pas, et ce sont les trois conditions
du verdict :

| | où | ce que le solde disait | ce que l'audit a mesuré |
|---|---|---|---|
| T3 | `LEDGER-EXPERTS.md` | « Ce qu'aucun lot n'a pris : plus rien » | sept demandes de la revue système de fichiers ni faites ni écartées, huit points laissés ouverts par un chantier et jamais remontés |
| T1 | solde, chantier 27, README, `ThinkModel` | un recalage « monterait encore » le coût au mégaoctet de XP et de Vista | `fit-think.py` le fait **descendre** : 0,20 → 0,192, 0,16 → 0,148, les valeurs d'avant le lot 7 |
| T2 | README | la prose suit les tables | dix-sept chiffres démentis par la table voisine |

Et douze trouvailles de moindre gravité : quatre tests qui ne contraignent pas ce
qu'on leur prête (T4, T5, T8, T13), cinq constantes non sourcées ou mal sourcées
(T6, T7, T10, T11, T12), la règle des docstrings appliquée à moitié (T9), du
journal dans le code (T14), des détails (T15). Le lot ne touche presque pas au
modèle : son livrable est que le code, les journaux et le README disent la même
chose, et que les tests contraignent ce qu'on leur prête.

### Les décisions — que le README ne puisse plus mentir

**La prose sort de `readme-tables.py`**, comme les tables. Une table y est
reconnue à sa ligne d'en-tête ; une phrase y est écrite telle qu'elle est dans
le README, chaque chiffre tiré d'un bilan étant un champ `{nom}`. Le modèle
retrouve la phrase — un retour à la ligne du README vaut une espace — et seuls
les champs sont comparés (`--check`) ou réécrits (`--write`) : le texte autour
reste celui qu'on a écrit. Trois raffinements, chacun appelé par un cas réel :

- **les binaires jetables** : quelques phrases comparent la galerie à un modèle
  privé d'un mécanisme — sans lecture anticipée, sans préchargeur, sans
  `SMARTDRV`, la commutation de tête égale au pas de piste, les points de
  contrôle à une seconde, à trente ou en fin de passe. Leurs bilans sont nommés
  en argument (`nora=fnora …`) ; sans eux, la phrase est dite **non vérifiée**,
  pas fausse ;
- **les coûts de génération** dépendent de la machine et de sa charge : ils se
  vérifient à 10 % près et ne se réécrivent qu'au-delà ;
- **la table du rangement intelligent** et sa prose, qui viennent de `smart.sh`
  et `passes.py` et non de `run.sh full`, n'y entrent que si leurs bilans sont
  là.

**Validé comme les chantiers 23 à 27 : sur les bilans de `base`** (le commit du
lot 8 plus le chantier 28, 340 bilans identiques à ceux de l'audit et du lot 8),
contre le README de `base`. Les **63 lignes de table** — les quatre journées
comprises, dont la colonne « activités » est reprise du README — sortent
identiques. Des 57 phrases, **28 portaient au moins un champ faux, 55 champs en
tout** : les dix-sept de l'audit, et d'autres qu'il n'avait pas vus —

| README | écrit | mesuré à `base` |
|---|---|---|
| salves du cache, XP sur `dev-2007` | douze écritures par vidage | 4,9 |
| sans lecture anticipée, les démarrages dureraient | 2 à 7 s de plus | 1,7 à 11,2 |
| `SMARTDRV` coûte par démarrage | 1,1 à 1,7 s | 1,2 à 1,8 |
| pages de FAT32 lues au démarrage | 220 à 350 | 220 à 355 |
| Windows 95 sur `gamer-1996` | « n'évacue que trois occupants » | quatre |
| JkDefrag contre UltraDefrag sur NTFS | mieux sur deux volumes, moins bien sur trois | l'inverse : trois et deux |
| JkDefrag sur `gamer-2003` | 3,9 Go | 4,0 |
| JkDefrag sur les FAT de 1999 | 1 100 à 1 850 morceaux, 790 à 1 110 trous | 1 108 à 1 824, 789 à 1 101 |
| XP avec un seul point de contrôle, `dev-2007` | 66 fichiers en morceaux | 769 (binaire `cpend`) |
| sans préchargeur, `famille-2007` | 890 seeks, 44 114 cylindres, 43,6 s | 1 448, 15 240, 46,2 (binaire `nopf`) |

et une convention : le total de la frontière était « 4 h 13 » dans un
paragraphe et « 4 h 12 » dans un autre, les totaux du recollage arrondis à la
minute d'avant. Tous les totaux s'arrondissent désormais à la minute la plus
proche, comme le script le disait déjà pour l'un d'eux.

**Réécrire la prose, ensuite**, là où elle disait ce que le modèle n'est plus,
ou pourquoi il l'est devenu : les « jusqu'au chantier 25 », les renversements
datés des chantiers 26 et 27, la conclusion sur les cibles (plus bas), la
lecture sans latence (T7), le tampon qui est une file (T15), la commutation de
tête (T6), les estimations (T11). Les chiffres y ont été posés par
`readme-tables.py --write`, d'un seul jeu de mesures.

### Les décisions — `ThinkModel`, mesuré, puis décidé par Gabriel

`fit-think.py` sur `base` redonne l'ajustement de l'audit : 0,192 et 0,148, aux
résidus de ±1,3 à ±1,9 s. Deux issues ont été préparées et chiffrées, sur un
binaire jetable (`think19`) :

| | 2003 | 2007 | vingt démarrages |
|---|---:|---:|---:|
| garder 0,20 / 0,16 | +3,3 % | +4,1 % | −4,1 à +8,4 % |
| revenir à 0,19 / 0,15 | +0,6 % | +1,0 % | −4,1 à +5,7 % |

(écart de la somme des quatre démarrages de chaque époque à sa cible ; 1993 à
1999 ne bougent pas.) **Gabriel a choisi 0,19 / 0,15.** Ce qu'on en retient : le
lot 7 avait recalé pour compenser un manque — les seeks de MFT épars — que le
lot 8 a rendu au disque, et les deux lots se compensaient. Le niveau n'en est
pas plus justifié ; le docstring, le README et le solde le disent sans compter
les calages, et renvoient ici pour leur histoire.

Le **signe du chantier 27** est corrigé dans son texte, barré, avec une note qui
renvoie ici.

### Les décisions — armer les tests

**T4, l'invariant du tour perdu, avec le disque qu'on écoute.**
`TrackSkewTests` ne l'énonçait que sans tampon, en `.direct`, alors que tous les
scénarios passent `.era(year:)`. Le même test avec `.era(year: 2001)` : *N*
requêtes contiguës coûtent **exactement** ce que coûte une requête de *N* fois la
taille — 10⁻¹⁶ s d'écart pour 8 à 128 requêtes —, commandes comprises, puisque
la tête lit d'avance pendant que l'hôte envoie la suivante. Un test compagnon,
le même disque sans lecture anticipée, mesure ce qu'il en coûterait : 1,4 à
2,2 ms par requête (0,17 à 0,26 tour, la lecture sans latence en rattrapant une
part), quand la commande en coûte 0,2. C'est lui qui prouve que le premier
contraint.

**T5, la borne FAT32 / NTFS remise à ×2**, fixe. Le docstring dit pourquoi elle
ne suivra plus la mesure. Elle **échoue sur le code du lot 7** (`a2af0e6` :
16,9 % contre 13,0 %, ×1,3), que la borne de ×1,25 laissait passer, et passe à
`HEAD` (18,8 % contre 7,6 %, ×2,5). Au passage : les fourchettes de
non-régression de `secretaire-1999` (3–10 %) et de `famille-2003` (4–16 %,
large de son chaos) deviennent bilatérales ; le problème connu de
`secretaire-1999` vise sa cible, 15 %, et non 10 ; « deux d'entre elles »
devient « trois ».

**T8, l'audit d'allocation sur la galerie**, en release
(`GalleryAllocationAuditTests`, derrière `DEFRAG_GALLERY_AUDIT`) : les vingt
volumes, vingt-quatre plans chacun — les quatorze stratégies de
`DefragPlanner.all`, `Layout.ini` fourni au rangement intelligent, et en blocs
pleins les dix qui en ont l'option. Pour s'assurer qu'il contraint, la faute F1
a été réintroduite dans un worktree jetable : il casse sur `dev-1996`
(1 040 écritures sur une donnée vivante) et `gamer-1996`.

**Et sur le code du lot, il a cassé aussi.** Windows 95 écrivait sur une donnée
vivante sur huit volumes sur vingt :

| volume | écritures fautives | clusters |
|---|---:|---:|
| `poweruser-1993` | 23 | 348 |
| `famille-1996` | 8 | 32 |
| `secretaire-1999` | 378 | 15 182 |
| `dev-2003` | 1 | 6 |
| `secretaire-2003` | 340 | 21 415 |
| `dev-2007` | 7 | 89 |
| `famille-2007` | 1 816 | 111 195 |
| `secretaire-2007` | 6 | 78 |

Un diagnostic jetable l'a qualifiée : **tous** les clusters écrasés étaient
relus ensuite par le même déplacement. C'est le second recouvrement que le
chantier 20 avait trouvé sur un volume construit à la main et laissé ouvert, en
le croyant absent de la galerie — il ne l'avait cherché que sur le volume
d'essai. `DefragOperations.move` copie tronçon par tronçon dans l'ordre du
fichier ; quand la place visée recouvre un morceau du même fichier situé plus
loin dans le fichier mais plus tôt sur le disque, le premier tronçon l'écrase
avant qu'on l'ait lu. Windows 95 vise une place contiguë à la frontière, que le
fichier occupe souvent déjà en partie : c'est lui qui la déclenche. Avec
l'accord de Gabriel, **la correction est dans `move`** : les tronçons sont
copiés dans l'ordre d'un `memmove` (`DefragOperations.safeOrder`) — l'ordre du
fichier chaque fois qu'il est sûr, sinon un tronçon passe après ceux dont il
recouvre la source ; un cycle, deux morceaux qui s'échangent, est lu entier
avant d'être écrit. Un test minimal (`moveNeverOverwritesUnreadSource` : un
glissement de deux clusters, un second morceau au début de la place, un
échange) échoue sur ses trois cas sans la correction et passe avec.
`MoveTests`, dont l'oracle comparait les mutations dans l'ordre du fichier, suit
désormais le même ordre sûr : ce qu'il vérifie, les clusters libérés, n'a pas
changé.

**T13, `concurrent` sans défaut.** Des vingt constructions de `Simulator` dans
les tests, trois demandent l'entrelacement — les trois tests du tourniquet — et
dix-sept le chemin de la production. Aucune ne dépendait du défaut : toutes
passent.

### Les décisions — sourcer ou déclarer

- **T6, la commutation de tête** : déclarée, pas dérivée. La table 4-3 du
  Fireball donne 3,0 ms pour la tête comme pour le cylindre, et la table 5-3 le
  confirme (décalages de 21 et 28 intervalles servo, calés sur 3 et 4 ms). Un
  seul manuel publie les deux ; en faire la règle des huit fiches serait tourner
  une constante sur un point. Le binaire `fhs10` mesure ce que changerait
  l'égalité : **0 à 0,8 s** de plus par démarrage.
- **T7, la lecture sans latence** : le « Read-on-arrival » du Fireball qualifie
  un seek — 12,0 ms en lecture contre 14,0 en écriture, la lecture commençant
  avant la fin de l'asservissement — et le manuel le désactive pour tenir ses
  taux d'erreur. Retiré comme source ; le mécanisme est une hypothèse pour
  toutes les fiches sauf le Conner.
- **T10, l'horloge des points de contrôle**, tirée du catalogue : seek moyen et
  débit soutenu des fiches de 2003 à 2006, ramené au milieu du plateau par
  `DriveCatalog.innerRatio` (rendu public). **13,9 ms et 49,4 Mo/s**, au lieu des
  12,7 ms et 50 Mo/s calculés sur l'ancienne fiche du 7200.10. La cadence de cinq
  secondes a été remesurée à une et à trente (`cp1`, `cp30`) : XP et JkDefrag
  laissent au plus 17 fichiers cassés de plus ou de moins sur les huit NTFS ;
  un seul point de contrôle, en fin de passe, en laisse 769 à XP sur `dev-2007`
  (le README disait 66, mesuré avant le lot 8).
- **T11, les constantes justifiées par la cible seule**, déclarées dans leur
  code : le paquet d'écriture de 64 Ko, le bloc de huit clusters de la MFT, les
  seize fenêtres du dernier recours, la redescente de 3,5 s face aux dix
  secondes du Fireball, les bandes et le battement du roulement, le coût de
  commande prêté au Fireball de 1996. Le README en fait une ligne de « Ce qui ne
  l'est pas », le solde les liste. Le niveau des seeks, que l'audit dit
  sourçable, ne l'est pas ici : le sourcer changerait le son.
- **T12, les bornes de `NTFSAllocator`**, injectables (`SearchBounds`, valeurs
  de la galerie inchangées) : `CalibrationTests.ntfsSearchBoundsWeighOnFragmentation`
  régénère la table de l'en-tête, et **ses vingt-huit valeurs sortent
  identiques** à celles des binaires jetables du chantier 27. L'en-tête dit
  qu'aucune ne vient d'une source, nomme la quatrième, et a perdu son journal.

### Le reste

- **T9** : les docstrings des huit fichiers de l'audit — les faits de galerie en
  sortent ou renvoient au README ; un chiffre de réglage reste daté
  (`dataBandInches`, contre l'ancienne fiche du 7200.10).
- **T14** : le journal sorti du code dans quatorze fichiers, et du README ; les
  renvois au journal restent.
- **T15** : le tampon dit une file ; `SpindleVoice` tire ses bandes une fois par
  disque et réécrit ses tableaux en place (deux WAV — un démarrage à froid,
  une journée — identiques au bit près avant et après) ; `snapshot.sh`
  construit dans le dossier de l'étape ; `compare.py --identical` sort en erreur
  sur une étape vide, un bilan qui diffère ou qui manque, et ignore les lignes
  vides (le chantier 28 en avait ajouté au milieu des bilans) ; `run.sh` signale
  un bilan tronqué ; `SmartDrive.read` rend une lecture vide sans planter.
- **Deux demandes de la revue système de fichiers soldées par écrit** : le
  commentaire de `fromVolumeStart` (§ 5.6), et « compression, fichiers creux,
  flux : à dire » (§ 4.4), dit dans le README avec `$UsnJrnl`, `$Secure`,
  `$ATTRIBUTE_LIST` et WinSxS. `yieldMFTZone` (§ 6.6) est écartée : relue, la
  zone cède la moitié de ce qui lui reste, pas tout.

### Ce que chaque étape change

Binaires sous `MEASURE_DIR=.build/measure-lot9` : `base` (le commit d'avant, dont
les 340 bilans sont identiques à ceux de l'audit et du lot 8), `neutral` (tout
le lot sauf ses trois changements de modèle), `plan` (+ l'horloge des points de
contrôle), `move` (+ la faute corrigée), `final` (+ `ThinkModel`, le code du
commit). Jetables : `think19`, `hs10`, `cp1`, `cp30`, `cpend`, `nora`, `nopf`,
`nosd`, `nomft` et leurs reconstructions sur le code final (`fnora`, `fnopf`,
`fnosd`, `fhs10`), `lot7` (reconstruit depuis `a2af0e6`).

| étape | ce qu'elle ajoute | bilans changés | ce qui bouge |
|---|---|---:|---|
| `neutral` | tout le lot sauf ses trois changements de modèle | 0 sur 340 | rien : les bornes injectables, `concurrent`, `SmartDrive`, les docstrings ne changent aucun bilan |
| `plan` | l'horloge des points de contrôle, 13,9 ms et 49,4 Mo/s | 74 | les passes NTFS des outils qui la suivent. XP : +0,2 % en somme, un ou deux fichiers de moins laissés sur trois volumes. JkDefrag, mode 2 : −0,1 %, de 0 à 9 fichiers. Ses tris et `MoveUp` : +4,6 % en somme, de −9 à +31 % par passe — un tri évacue une place qui ne se libère qu'au point de contrôle suivant, et l'horloge décide lequel. Windows 95 sur NTFS : +0,1 % |
| `move` | les tronçons dans l'ordre sûr | 8 | les huit passes de Windows 95 où la faute tombait, et rien d'autre : mêmes requêtes, mêmes morceaux, mêmes trous ; de 0 à +0,05 % de durée, quelques centaines de seeks de plus au pire, les lectures reprises dans l'ordre |
| `final` | `ThinkModel` à 0,19 / 0,15 | 17 | les huit démarrages NTFS (2003 : 187,7 → 182,7 s pour 181,7 visés ; 2007 : 163,4 → 158,6 s pour 157,0), les installations de 2003 et 2007 par leurs redémarrages (−0,6 %), la journée de `famille-2003` (98,2 → 96,5 s) |

`final` redonne les vingt démarrages de `think19` à l'identique : le recalage
n'est que les deux littéraux.

### Ce que l'audit n'avait pas pu vérifier

- **L'ajustement du chantier 26** (0,199 / 0,157) : refait sur ses propres
  bilans (`measure-lot7/out-soft`, constantes d'avant son recalage), à
  l'identique, résidus compris (±0,2 / 1,4 / 2,8 / 1,8 / 1,3 s). Le binaire du
  lot 7 reconstruit depuis `a2af0e6` par `snapshot.sh` diffère du `bin-final`
  d'alors octet à octet — il a été construit dans un autre worktree, et le
  chemin s'inscrit dans l'exécutable — mais redonne ses vingt démarrages à
  l'identique.
- **`nomft`**, reconstruit depuis `HEAD` : ses vingt démarrages sont ceux du
  binaire du chantier 27, la coupure est donc bien celle qu'il décrit.
  L'attribution de la dérive tient **par époque** (sans la numérotation, 2003 et
  2007 sont à −0,7 et −0,1 s du lot 7), pas au profil près comme il l'écrivait :
  `famille-2003` bouge de −0,5 s, `dev-2007` de +0,3. Le chantier 27 porte une
  note.
- **`knobs`** : la table des constantes NTFS, régénérée par un test (plus haut),
  identique.
- **`nora`**, reconstruit : sans lecture anticipée, les démarrages durent de
  11,6 à 24,9 s de plus par époque (le chantier 26 écrivait 11,5 à 24,3 sur le
  code du lot 7), et de 1,7 à 11,4 s par démarrage — le README disait 2 à 7.
- **« sans préchargeur » et « point de contrôle unique »** : remesurés
  (`fnopf`, `cpend`), tous deux faux dans le README et corrigés.
- **L'invariant de T4 avec le cache** : écrit.
- **Les sources hors du dossier** (TULARC, le brevet du bus ISA, `HELP
  SMARTDRV`, `mkntfs`, `JkDefragLib.cpp`, `fastfat`, *Windows Internals*) : pas
  relues ; elles le restent par écrit.
- **`Sources/Audio`, `Haptics`, `UI`** ne sont toujours dans aucune cible de
  test ; le seul changement du lot qui y touche, `SpindleVoice`, est vérifié par
  les WAV.

### Ce qui valide

- **`swift test` : 424 tests passent** (413 avant) : l'invariant du tour perdu
  avec le tampon d'époque et son compagnon (huit cas), le déplacement qui ne
  recouvre pas ce qu'il n'a pas lu (trois cas), la lecture vide de `SMARTDRV`, et
  les tests de `Simulator` rendus explicites. Chacun des tests armés a été vu
  **échouer** là où il devait : T5 sur le code du lot 7, T8 avec la faute F1
  réintroduite et, sur le code du lot, avec la faute que personne n'avait vue,
  le test de `move` sans sa correction, T4 par son compagnon.
- **`DISKCORE_CALIBRATION=1 swift test -c release --filter Calibration`** : les
  trois problèmes connus, les mêmes — `dev-1996` 8,1 %, `secretaire-1999`
  5,5 %, `famille-2003` 7,6 % —, et la table de `NTFSAllocator` régénérée.
- **`DEFRAG_GALLERY_AUDIT=1 swift test -c release --filter GalleryAllocationAudit`** :
  les vingt volumes, 480 plans, aucune écriture sur une donnée vivante, aucun
  cluster référencé deux fois ; seize minutes, dont neuf pour `famille-2007`.
- **`compare.py --identical`**, étape par étape : `base` = l'audit = le lot 8
  (340 sur 340), `neutral` = `base` (340 sur 340), puis 74, 8 et 17 bilans
  changés, chacun là où l'étape devait agir et nulle part ailleurs (tableau
  plus haut). Le binaire reconstruit depuis le code du commit diffère de
  `bin-final` octet à octet — deux commentaires retouchés après la mesure ont
  décalé des lignes — et redonne ses 340 bilans à l'identique.
- **`readme-tables.py final nora=fnora nopf=fnopf nosd=fnosd hs10=fhs10 cp1=cp1
  cp30=cp30 cpend=cpend --check`** : 83 lignes de table, 70 phrases, **aucun
  écart, aucune non vérifiée**.
- **Le son** : un démarrage à froid (`boot:gamer-1993`) et une journée
  (`day:dev-1996:20`) rendus par `base` et `final` donnent des WAV identiques au
  bit près — la rampe et la redescente passent par `SpindleVoice`.
- **L'app compile** (Debug, iPhone 17 Pro Max, iOS 26.5, après `xcodegen
  generate`) ; elle n'a pas été lancée.

### Le README

Régénéré d'un seul jeu de mesures, `final`, par `readme-tables.py --write` —
les tables, la prose, et la table du rangement intelligent, refaite par
`smart.sh` et `passes.py` sur `final` : ses douze lignes FAT n'ont pas bougé,
ses huit lignes NTFS suivent `ThinkModel`. La table des trois allocateurs
(`AllocatorComparison`) est inchangée, rien de la génération n'ayant bougé. La
prose reprise, en plus des chiffres :

- **le recalage** et ce qu'il dit, sans l'histoire des calages ;
- **la lecture sans latence**, une hypothèse ; **le tampon**, une file ; **la
  commutation de tête**, un ordre de grandeur, avec ce que coûterait de
  l'égaler ; le **paquet de 64 Ko**, une estimation ; les **deux licences** de
  mixage du plateau ; la seconde avant la coupure et la redescente ;
- **l'horloge des points de contrôle**, et la cadence remesurée ;
- **les renversements datés** des chantiers 26 et 27 (la frontière contre 95, le
  recollage contre XP) remplacés par ce qui les explique ;
- dans « Ce qui ne l'est pas » : les constantes non sourcées, et ce que NTFS
  n'a pas (compression, fichiers creux, flux, `$UsnJrnl`, `$Secure`,
  `$ATTRIBUTE_LIST`, liens de WinSxS) ;
- « Mesurer un changement » : `--check` et `--write`, les binaires jetables
  nommés en argument, `compare.py` qui sort en erreur.

Hors du README, les **fourchettes de l'écran de choix d'outil** ont été
confrontées aux bilans de `final` : quatre ne tenaient plus, toutes des tris de
JkDefrag sur NTFS, que l'horloge des points de contrôle a déplacés (par dernier
accès : jusqu'à 3 h 49 au lieu de 3 h 09). Recopiées, arrondies aux cinq
minutes comme les autres. `UX_REVIEW.md` relève d'autres écarts de cet écran ;
c'est son chantier.

### Laissé ouvert

- **Rien n'a encore été écouté.** Gabriel n'a entendu ni le lot 6, ni le lot 7,
  ni ce qui a suivi ; c'est la validation qui manque à tout le lot 6, et le
  troisième journal d'affilée à le dire. Ce lot ne change rien au son, hors les
  passes de Windows 95 des huit volumes corrigés, qui ne lisent plus ce qu'elles
  avaient écrasé.
- **Le niveau de `ThinkModel`** pour 2003 et 2007, recalé mais toujours
  injustifié : seules des mesures d'époque le trancheraient.
- **La commutation de tête**, un ordre de grandeur que le seul manuel qui la
  publie contredit ; **le niveau des seeks**, sourçable sur les manuels du
  dossier, pour un chantier d'écoute.
- **Les demandes de la revue système de fichiers** en attente (le solde en
  tient la table) : la résidence NTFS — 0 résident sur six des huit NTFS —, la
  remise à zéro du hint de MS-DOS chaque journée, `$UsnJrnl` et `$Secure`,
  `$ATTRIBUTE_LIST` et WinSxS, la numérotation MFT de `MachineWriter` et
  `InstallSession`.
- **Ce que les chantiers avaient laissé** et qui reste : `DEFRAG.EXE` par
  tronçons, la racine FAT16 à 512 entrées, le planificateur quadratique de la
  frontière, `MoveItem4` et l'entrée `..`, le piste-à-piste du Conner, la
  position de départ du bras.
- **Des chiffres de prose que l'outil ne vérifie pas**, parce qu'ils viennent de
  compteurs internes ou de binaires qui ne sont plus : les vingt et un échecs de
  répertoires de JkDefrag et les 730 répertoires abandonnés sur `famille-1999`,
  les validations par lot de la frontière, ce que la recalibration thermique
  ajoute aux passes, les 0,4 s de noms uniques, le coût de `famille-2003` avant
  l'écriture par paquets. Ils sont datés, pas démentis ; ils ne sont pas
  garantis.
- **Les fourchettes de l'écran de choix d'outil** sont recopiées à la main des
  bilans : `readme-tables.py` ne les vérifie pas.
- ~~`UX_REVIEW.md`, hors du périmètre de ce lot, attend son propre chantier.~~
  Fait : chantier 30, branche `parcours`, trois lots — les unités et les
  libellés, l'état du disque gardé d'un lancement à l'autre, la navigation.
  Six pistes sur sept prises ; le détail est dans `LEDGER-UI.md`.

## Chantier 31 — le site

**Fait** · branche `site`

### Le problème

La fiche du store cite trois adresses — `https://glandais.github.io/Winchester/`,
`…/support/`, `…/privacy/` — et aucune n'existait. Une revue qui suit le lien
de confidentialité et tombe sur une 404 refuse l'app. Il fallait un site qui
dise vrai sur une app qui ne collecte rien, sans le démentir en chargeant une
police chez Google.

### Les décisions

- **Le modèle est `whereiwas/docs/`**, en ligne et accepté par la revue : même
  structure (`index.html`, `privacy/`, `support/`, `how-it-works/`,
  `assets/style.css`, `.nojekyll`), même grille à colonne d'étiquettes, même
  ton juridique sobre pour la confidentialité, même mécanisme de contact —
  issues GitHub (`glandais/winchester`) et la même adresse e-mail. Le contenu,
  lui, est écrit pour Winchester.
- **Anglais seul, exprès**, comme WhereIWas : la fiche est en deux langues,
  le site en une ; il le dit dans `CLAUDE.md`.
- **Aucun JavaScript, aucune ressource externe.** Les polices de WhereIWas
  (Archivo, IBM Plex Mono) n'ont pas de fichier de licence à côté d'elles : on
  ne les recopie pas, le site prend la pile système — SF sur les appareils de
  l'app, arrondie pour les titres comme les `ScreenTitle` de l'app.
- **L'identité visuelle est celle de l'app** : le fond `#0E0F12` et le panneau
  de `Theme`, l'ambre `Theme.read` et le turquoise `Theme.write`, et, en tête,
  une carte de clusters en SVG inline aux couleurs exactes de `ClusterPalette`
  (teinte sombre d'un seul tenant incluse) — un FAT à moitié rangé, avec son
  fichier d'échange rouge. Sombre par défaut ; une variante claire suit le
  réglage du système, la carte restant sombre puisqu'elle est un écran de
  l'app. Quelques cases s'allument en ambre ou turquoise puis s'éteignent en
  un tiers de seconde ; rien n'est animé sous « Réduire les animations ».
- **Liens relatifs à `index.html` explicite** : un lien vers un dossier nu
  (`../`) marche sur Pages mais pas en `file://`.
- **Les libellés sont ceux du catalogue** (unités `en`) : `Disks`, `Pass`,
  `Instruments`, `Settings`, `Start`, `Relive this disk`, `Listen to day N`,
  `Build a used disk`, `With which tool?`, `Share the report`… Chaque
  affirmation a été relue contre `Sources/` ou le `README.md` ; ce qui ne s'y
  trouvait pas n'a pas été écrit.
- **La confidentialité décrit ce que le code écrit**, et rien d'autre :
  `disques.json` (les disques construits, leur recette seule) et
  `passes.json` (les 120 derniers résumés de passe, qui portent l'état d'un
  disque) dans Application Support, le mixage et l'accueil vu dans
  `UserDefaults`. Rien ne sort que par l'utilisateur ou le système : le
  texte du bilan confié à la feuille de partage, le titre de la passe sur
  l'écran verrouillé, la sauvegarde de l'appareil. Date d'effet : 21
  septembre 2026.
- **Pas de lien App Store** tant que l'app n'est pas publiée : un commentaire
  HTML marque sa place dans l'en-tête de l'index.
- Une ligne de pied de page dit que les noms de Windows, des outils et des
  disques appartiennent à leurs propriétaires, et que l'app ne leur est pas
  affiliée.

Un écart relevé en chemin, laissé tel quel puisque `metadata/` n'est pas de
ce chantier : la description du store dit du seek « its pitch set by the
distance travelled », alors que le banc de résonateurs est à fréquences fixes
et que la distance change la forme et le niveau du son. Le site dit ce que dit
le README.

### Ce qui valide

- Un serveur local (`python3 -m http.server`, arrêté ensuite), servi à la
  racine puis sous un sous-chemin `/Winchester/` comme sur Pages : un
  explorateur de liens suit chaque `href`, `src` et `url()` interne depuis les
  quatre pages — 11 adresses, **toutes à 200**, aucune ancre absente, balises
  équilibrées, `lang`, titre, description, viewport et `theme-color` sur
  chaque page, un `alt` sur chaque image. Tous les liens relatifs existent sur
  le disque, donc marchent en `file://`.
- Des captures par Chrome sans interface, à 1280 px et à 390 px (dans des
  iframes : la fenêtre sans interface ne descend pas sous 500 px) : pas de
  défilement horizontal hors des tableaux, qui défilent dans leur cadre. Elles
  ont fait corriger les étiquettes de section, que `.sheet h2` écrasait, et
  les ancres, qui tombaient sous l'en-tête collant.
- Les icônes 180 et 512 sortent de `AppIcon-1024.png` par `sips`, sans canal
  alpha.

### Laissé ouvert

- **Activer GitHub Pages** : source `develop`, dossier `/docs`. Rien n'est en
  ligne tant que ce n'est pas fait, et rien n'a été poussé.
- **La casse** : le dépôt s'appelle `winchester`, les trois adresses du store
  `Winchester`. Pages sert un site de projet sous le nom du dépôt ; que
  `/Winchester/` y réponde aussi n'est pas vérifié — à contrôler dès
  l'activation, et sinon renommer le dépôt ou corriger les trois adresses de
  `metadata/` (et les `canonical` du site).
- **Le lien App Store** à poser à la publication, à la place du commentaire.
- **Non vérifié sur un appareil** : le rendu dans Safari iOS, le mode clair,
  et le chemin « Réglages → Winchester → Language » que la FAQ indique pour
  changer de langue sans changer celle de l'appareil.

## Chantier 32 — les vidéos de l'App Store

**Fait** · branche `app-previews`

### Le problème

Winchester est une app qu'on écoute, et sa fiche ne montrait que six images
fixes : ni le son, ni le mouvement qui le porte — la frontière qui avance sur
la carte, le bras qui balaie le plateau. Une app preview (15 à 30 s, en tête de
la fiche, jouée d'office dans les résultats de recherche) est le seul endroit du
store qui puisse faire entendre un seek. Deux contraintes d'Apple fixent le
reste : **des images de l'app seulement** — les vidéos de `Tools/RenderVideo`,
redessinées en Core Graphics, sont exclues — et une lecture **muette** jusqu'à
ce qu'on touche.

### Les décisions

- **L'image dans l'app, le son dans le rendu.** `simctl io recordVideo` ne filme
  que l'écran, et le mode capture coupe le son exprès. Mais la démo est
  déterministe : `ScreenshotMode` l'avance à la seconde demandée puis la joue
  en temps réel, et `RenderTrace` rend le même son du même modèle
  (`SCENARIO=defrag`). Chaque plan prend son son aux mêmes secondes de passe.
  Enregistrer le son du Mac aurait demandé un pilote de bouclage, et donné un
  son moins propre que celui dont il est la copie.
- **Synchroniser par l'horloge du Mac**, que le simulateur partage.
  `ScreenshotMode` note l'instant où la lecture part — pas celui de l'appel à
  `play()`, qui attend parfois que la passe ait pris de l'avance — ;
  `scripts/sim-record.py` note celui où `recordVideo` annonce sa première image,
  trois quarts de seconde après son lancement. Reste la latence d'affichage :
  30 et 55 ms mesurés en corrélant le mouvement du bras aux attaques des seeks,
  d'où `LATENCY = 0,04`.
- **Remotion pour l'habillage**, plutôt que Motion Canvas ou Revideo : c'est le
  seul des trois fait pour monter de la vidéo capturée avec plusieurs pistes de
  son. Habillage léger — le titre de la carte Koubou de chaque plan, une
  invitation « Turn the sound on » sur le premier (la vidéo part muette), une
  carte de fin où le son du dernier plan s'éteint. L'interface reste plein
  cadre, sans appareil autour : la définition d'App Store Connect (886 × 1920,
  1200 × 1600) est celle du simulateur, à l'échelle près.
- **Les textes restent ceux des cartes** : table `Koubou` de
  `i18n/translations.json`, une clé de plus pour l'invitation.
- **Trois plans** (`previews/montage.txt`) : la carte plein écran à 150 s, comme
  la première capture — à 60 s la passe affiche encore 0 % —, le plateau à
  210 s, la passe à 300 s ; 29,5 s avec les fondus et la carte de fin.
- **Rien de ce qui sort n'est versionné** : la vidéo se refait à l'identique, et
  App Store Connect garde l'exemplaire envoyé.
- `screenshots.sh` et `previews.sh` partagent `scripts/sim-capture.sh` : la
  règle d'un seul simulateur ne s'écrit qu'une fois.

### Ce qui valide

- Sur les vidéos finales elles-mêmes, la corrélation du mouvement du bras (plan
  `platter`) avec l'énergie du son culmine à **-10, -20 et +5 ms** (trois
  rendus d'iPhone), pour une image de 33 ms.
- Le jeu complet — deux appareils, deux langues — en 25 minutes environ ; l'iPad
  éteint à la fin, l'iPhone rallumé, un seul simulateur à la fois.
- `screenshots.sh`, réécrit sur `sim-capture.sh`, rend ses six captures.
- `previews.sh` vérifie chaque fichier par `ffprobe` : définition, H.264,
  30 i/s constants, 15 à 30 s, une piste AAC stéréo.
- `i18n.py import` puis `check` : aller-retour exact à l'octet.
- Envoyées le 21 septembre 2026 sur la 1.0.0 (quatre jeux, traitement
  `COMPLETE`), affiche reposée à 2 s ; `asc validate` : aucune erreur.

### Laissé ouvert

- **L'écoute** : la synchro est mesurée, pas encore écoutée sur un iPhone.
- `i18n.py export` ne reproduit pas `i18n/translations.json` tel qu'il est sur
  `develop` : les douze traductions françaises de la table `Koubou` y sont des
  objets `{value, state}`, que l'export écrit en chaînes. L'écart précède ce
  chantier ; `import` et `check` n'en souffrent pas.

## Chantier 33 — un disque nommé : le WD VelociRaptor WD1000DHTZ

**Fait** · branche `velociraptor`

### Le problème

Tous les disques du modèle se déduisent d'une année, d'une capacité et d'un
régime. `DriveGeometry.era` interpole entre les huit fiches du catalogue, toutes
des plateaux de 3,5 pouces, la dernière de 2008. Un **WD VelociRaptor
WD1000DHTZ** (2012 : 10 000 tr/min, trois plateaux de 2,5 pouces dans un radiateur
IcePack de 3,5, 64 Mo de tampon, SATA 6 Gb/s) sort de cette courbe de trois
façons à la fois. Voici ce que le modèle en aurait fait, prolongé depuis 2012 :

| | fiche et mesures | prolongé depuis 2012 |
|---|---|---|
| têtes | 6 | 3 |
| débit bord → moyeu | 209,1 → 114,7 Mo/s | 414 → 215 Mo/s |
| seek moyen / piste-à-piste | ≈ 3,8 / 0,7 ms | 8,5 / 1,0 ms |
| tampon | 64 Mo | 32 Mo, celui du 7200.11 |
| repos | 30 dBA = 3,0 B | 3,26 B au régime seul |
| parcage | rampe NoTouch | contact |

Il y avait un défaut de plus : `DriveReference.geometry` ne lisait pas les
pistes par face de sa propre fiche. Elle repassait par l'année, donc par
l'interpolation. Une fiche hors de la courbe ne pouvait donc pas être fidèle.

### Les sources

Toutes sont rangées dans `~/code/perso/disknoise.resources/manuels/`, en PDF et en
texte :

- **Fiche WD 2879-701284-A05** (avril 2012, `wd-velociraptor-specsheet`) :
  1 953 525 168 secteurs, 10 000 tr/min, 200 Mo/s soutenus, 64 Mo de cache,
  SATA 6 Gb/s, 30 dBA au repos et 37 en seek (« Sound power level »), rampe
  NoTouch (« The recording head never touches the disk media »). Ni seek, ni
  densité.
- **Fiche WD 2879-701284-A00** (2008, WD3000HLFS, `wd-velociraptor-rs`) : seek
  4,2 / 4,7 ms, piste-à-piste 0,7 ms au maximum, tampon « Read: Adaptive »,
  cache d'écriture actif. C'est la seule fiche VelociRaptor qui publie le
  piste-à-piste.
- **Fiche WD 2879-701284-A02** (2010, WD6000HLHX, `wd-velociraptor-ggsdata`) :
  27 / 34 dBA pour la génération précédente.
- **Tom's Hardware**, *Western Digital VelociRaptor WD1000DHTZ Review* (2012) :
  plateaux de 2,5", trois plateaux ; 209,1 Mo/s au maximum, 114,7 au minimum ;
  accès en lecture 6,78 ms, en écriture 8,83 ms.
- **Base de plateaux rml527** : WD1000DHTZ-xxN21Vx, 1 To, 3 plateaux et 6 têtes,
  334 Go par plateau.

### Les décisions

**Une liste à part, `DriveCatalog.named`.** Le VelociRaptor n'est ni une ancre, ni
le voisin d'une année : `nearest(year: 2012)` rend toujours le 7200.11. Le mettre
dans `all` aurait tordu la densité, le seek et le tampon de tous les disques
déduits d'une année, et les tests qui parcourent `all` pour vérifier la courbe.

**La géométrie vient de la fiche quand les plateaux ne font pas 3,5 pouces.**
`DriveGeometry.era` délègue à `DriveGeometry.zoned`, qui prend une densité
explicite. `DriveReference.geometry` passe la sienne (pistes par face, octets
par face, rapport interne) quand `followsEra` est faux. Les huit fiches de 3,5
pouces gardent exactement leur chemin.

**Les valeurs de la fiche du VelociRaptor :**
- 171 600 pistes par face. Elles viennent du débit mesuré au bord, 209,1 Mo/s,
  soit 2 450 secteurs à 10 000 tr/min, du rapport interne 0,55 (114,7 / 209,1)
  et de la capacité par face ;
- seek moyen 3,8 ms, soit l'accès en lecture mesuré moins 3,0 ms de latence
  moyenne. La fiche de 2008 annonçait 4,2 ms pour la génération d'avant ;
- piste-à-piste 0,7 ms.

**Le souffle suit la vitesse au bord, pas le régime.** `SpindleCharacter` prend le
diamètre des plateaux. `speedRatio` vaut désormais (tr/min × rayon externe) /
(7 200 × 1,831). Un plateau de 2,5 pouces s'arrête vers 1,25 pouce, et le
VelociRaptor brasse l'air à 0,95 fois la vitesse d'un 7 200 tr/min de 3,5 pouces.
C'est la raison même de ses petits plateaux. Au régime seul, il aurait fait
3,50 B, plus que le 7200.11 ; le modèle donne 2,67 B contre 3,0 B sur la fiche.
L'écart de −0,33 B est celui que le modèle a déjà sur le 7200.10 (−0,25 B). Les
raies qui suivent le régime montent d'elles-mêmes : rotation à 166,7 Hz,
commutation à 4 kHz. Pour un 3,5 pouces, rien ne change (`speedRatio` inchangé,
vérifié par les tests).

**Le disque dans sa machine.** `GeneratedVolumeBridge.drive(for:atLeast:)` rend
un `DriveHardware` : géométrie, loi de seek, `DriveInterface` et **année du
disque**. Pour un disque nommé, le tampon vient de sa fiche, et l'année (2012)
va au palier et à la recalibration. L'année du scénario garde le logiciel et le
bus. Un disque SATA impose un contrôleur SATA : `HostBus.era(year:serial:)` donne
150 Mo/s avant 2006, 300 avant 2011, 600 ensuite, aux débits de la norme. Un
disque déduit d'une année reçoit exactement ce qu'il recevait.

**La rampe.** `IdleBehavior.rampLoad` supprime le décollement à la mise sous
tension et l'atterrissage à la coupure. C'est ce que dit la fiche : les têtes ne
touchent jamais le plateau.

**Choisir le disque.** `DiskSpec.model` est facultatif, et les 20 profils JSON se
décodent tels quels. `DiskSpec(reference:)` recopie la fiche, capacité en Mio
entiers. L'assistant gagne un choix « Libre / VelociRaptor » : avec une fiche,
capacité, régime et seek passent en lecture seule, et le panneau montre la
géométrie de la fiche. La galerie écrit « VelociRaptor 1 To · 10 000 tr/min ».
`rendertrace` accepte `DRIVE=VelociRaptor`, qui pose le même volume en tête du
disque nommé.

### Ce qui valide

- `NamedDriveTests`, 7 tests :
  - débit du modèle de 208,9 → 114,9 Mo/s, contre 209,1 → 114,7 mesurés ;
  - 6 têtes ;
  - la loi de seek passe par 3,80 et 0,70 ms (pleine course 6,85 ms, commutation
    de tête 0,42 ms) et reste croissante ;
  - le disque reste hors des époques ;
  - un profil qui le nomme prend sa fiche entière, et un profil qui ne le nomme
    pas reste sur l'UDMA/100 de 2007 ;
  - le JSON avec et sans `model` se décode ;
  - la vitesse au bord ;
  - la rampe.
- La suite existante passe sans modification.
- **Les 340 bilans de `run.sh full` sont identiques** avant et après, à la durée
  de génération près, qui est un chronomètre. Le chantier ne change rien aux
  disques d'une année.
- Le VelociRaptor sous les huit volumes NTFS de la galerie (`DRIVE=VelociRaptor`,
  même volume, même travail : les requêtes sont les mêmes au nombre près) :

| profil | démarrage (dont disque) | installation | défragmentation XP | seek moyen de la passe |
|---|---|---|---|---|
| dev-2003 | 50,9 (10,8) → 48,2 s (8,1) | 652,8 → 627,7 s | 169,5 → 58,6 s | 13 925 → 1 070 cyl. |
| famille-2003 | 29,1 (10,5) → 26,1 s (7,5) | 458,1 → 438,6 s | 143,0 → 58,6 s | 7 216 → 566 cyl. |
| gamer-2003 | 68,3 (13,3) → 64,3 s (9,3) | 695,4 → 667,5 s | 8,4 → 8,2 s | 7 978 → 2 543 cyl. |
| secretaire-2003 | 35,2 (10,9) → 31,8 s (7,5) | 414,2 → 397,8 s | 87,4 → 38,0 s | 9 283 → 424 cyl. |
| dev-2007 | 46,7 (12,8) → 43,5 s (9,5) | 638,1 → 589,6 s | 2 276 → 817 s | 21 199 → 5 771 cyl. |
| famille-2007 | 38,6 (12,6) → 35,3 s (9,3) | 714,6 → 663,2 s | 975 → 450 s | 18 536 → 5 940 cyl. |
| gamer-2007 | 31,2 (11,6) → 28,6 s (8,9) | 1 113 → 1 010 s | 1 043 → 474 s | 21 173 → 6 860 cyl. |
| secretaire-2007 | 42,3 (12,1) → 39,4 s (9,2) | 607,7 → 562,3 s | 607 → 228 s | 28 027 → 7 588 cyl. |

Un démarrage ne gagne que 3 à 4 s : le calcul l'emporte, et le disque n'y
comptait déjà que pour 21 à 42 % de l'attente. Une défragmentation va 2 à 3 fois
plus vite. Plusieurs raisons s'additionnent, **non séparées** ici :
- le volume n'occupe que le premier tiers du disque, et le bras ne parcourt plus
  qu'un tiers de sa course ;
- le seek moyen passe de 8,5 à 3,8 ms ;
- la latence passe de 4,2 à 3,0 ms ;
- le bus passe de 100 à 300 Mo/s.

### Laissé ouvert

- **Séparer les quatre effets** de la défragmentation (course, seek, latence, bus),
  chacun par un binaire jetable.
- **Le NCQ** : un disque SATA de 2012 réordonne jusqu'à 32 commandes. Le modèle
  n'en a pas.
- **Les modes du bras** (`SeekSynth`) sont ceux d'un 3,5 pouces. Un bras de
  2,5 pouces est plus court et plus raide, et ses résonances devraient monter.
  Aucune source.
- **Le clic de chargement sur la rampe** n'a pas de voix, et la rampe supprime
  seulement des contacts. Aucune source ne décrit ce son.
- **Le seek en écriture**, 8,83 ms d'accès mesurés contre 6,78 ms en lecture, n'est
  pas modélisé. La loi est la même dans les deux sens, comme pour les autres fiches.
- **Le secteur de 4 Ko** (Advanced Format, émulé en 512 octets) est ignoré : le
  modèle adresse en 512.
- **Le niveau en seek**, 37 dBA sur la fiche, n'est calé sur rien, comme pour
  toute la galerie.
- **L'époque logicielle de 2012** (Windows 7) n'existe pas. Le VelociRaptor s'essaie
  sous les profils de 2003 et 2007, dans une machine SATA de leur année, et
  l'assistant s'arrête toujours en 2008.
- **L'écoute par Gabriel** : `DRIVE=VelociRaptor SCENARIO=gamer-2007` contre le
  même profil sans `DRIVE`.

## Chantier 34 — 2012 : Windows 7, le 7200.14, et le 10 000 tr/min pour tous

**Fait** · branche `velociraptor`

### Le problème

Le chantier 33 avait posé le VelociRaptor **à part** : une fiche nommée, choisie
dans l'assistant par un « Libre / VelociRaptor » qui verrouillait capacité,
régime et seek. Trois choses manquaient :

| | avant | ce qui manquait |
|---|---|---|
| assistant | régimes 3 600 à 7 200, seek de 7 à 25 ms, 488 Go, 1990 à 2008 | construire soi-même un 10 000 tr/min, un disque de 1 To, un disque de 2012 |
| galerie | cinq époques, la dernière en 2007 | un disque de 2012, et le VelociRaptor dans la machine de son époque |
| catalogue | la courbe s'arrête au 7200.11 de 2008 | le disque de bureau de 2012 : au-delà, tout était extrapolé (seek de 3,5 ms, piste-à-piste de 1,4) |

Trois tables retombaient en silence sur Vista pour tout système inconnu
(`ThinkModel.boot`, `Era.matching`, `stampsAccess`, qui aurait réactivé les dates
d'accès d'XP), et `HostBus.era` restait à l'UDMA/100 après 2001.

### Les sources

Rangées dans `~/code/perso/disknoise.resources/manuels/` :

- **Manuel Seagate Barracuda 7200.14** (100686584, rév. G, octobre 2012,
  `7200.14-100686584g`) : ST1000DM003, 1 plateau et 2 têtes, 352 ktracks/in,
  1 807 kFCI, 210 Mo/s au bord et **156 Mo/s en moyenne**, 64 Mo, SATA
  600 Mo/s, seeks 8,5 / 9,5 ms et 1,0 / 1,2 ms, 2,2 B au repos, « Load/Unload
  cycles 300,000 ». Le ST500DM002 de la même révision est d'une autre
  génération (329 Gb/in², 16 Mo) : il n'est pas repris.
- **Fiche WD 2879-701284-A05** (déjà là) : 976 773 168 secteurs pour le
  WD5000HHTZ, mêmes régime, débit et tampon que le WD1000DHTZ.
- **Base de plateaux rml527** : WD5000HHTZ, 2 plateaux de 334 Go, 3 têtes ; les
  Raptor d'avant 2008 en 3,5 pouces de facteur de forme, sans taille de plateau.

### Les décisions

**Le 7200.14 ancre 2012.** Il entre dans `DriveCatalog.all`, et la courbe ne
bouge qu'au-delà de 2008 : les disques de 2007 interpolent toujours entre 2006
et 2008. 387 200 pistes par face (352 ktracks/in sur la bande de 1,10 pouce,
comme les autres fiches Seagate). Son rapport interne vient de son manuel : sur
une bande où les secteurs par piste décroissent linéairement, moyenne = bord ×
(1 + rapport) / 2, soit 0,486 — le seul point de `innerRatioByYear` tiré d'une
fiche. Le modèle en tire 208,7 → 101,4 Mo/s bruts et **−9,3 %** en lecture
séquentielle simulée : dans les 10 % du test, et le brut passe 1 % sous les
210 publiés. La borne « brut > fiche » est élargie à 2 %, en le disant.

**Un 10 000 tr/min déduit prend la mécanique du VelociRaptor à partir de 2008**
(`DriveCatalog.mechanics`) : des faces qui portent, par rapport au disque de
bureau de l'année, ce que le WD1000DHTZ portait par rapport au 7200.14 — 44 %
des pistes et 33 % des octets —, des plateaux de 2,5 pouces, son piste-à-piste
et sa rampe. En 2012, il retrouve la fiche à 1 % près (test). **Une seule fiche
porte cette règle** ; avant 2008, un Raptor reste sur la courbe des 3,5 pouces,
faute de source sur la taille de ses plateaux.

**Toucher à un réglage quitte la fiche.** L'assistant va de 1990 à 2012, de
20 Mo à 2 To, de 3 600 à 10 000 tr/min, avec un seek jusqu'à 3 ms. « Fiche »
propose les deux VelociRaptor ; changer la capacité, le régime ou le seek remet
le disque en déduit (`model` et `trackToTrackMs` effacés). Passer à
10 000 tr/min pose le seek de la fiche (3,8 ms), en revenir le seek de bureau de
l'année. Comme la mécanique déduite retombe sur la fiche en 2012, quitter la
fiche ne change presque rien.

**Le bus suit le disque.** `DriveInterface.era(year:)` prend le bus SATA quand
la fiche de l'année est SATA ; 2007 garde le 7200.10 PATA (à égale distance de
2006 et 2008, `nearest` rend le premier). La carte écrit « SATA » ou « IDE »
d'après ce bus. La rampe d'un disque déduit est celle de la fiche la plus
proche : rien ne change avant 2012.

**Windows 7** (`win7-sp1`) : une époque de démarrage (ReadyBoot par position,
dates d'accès éteintes, 1 300 pilotes et 240 services au plus), une installation
depuis le DVD en deux redémarrages, avec les ruches de Vista un peu plus
grosses, une journée à 25 Mo/s de carte et 2 Mo/s d'ADSL2+, `pagefile.sys` à
4 Go et `hiberfil.sys` à 3 Go. **Les constantes de calcul sont celles de Vista
divisées par 1,5** (`ThinkModel.boot`, `InstallEra`) : une hypothèse sans
cible, puisque le modèle d'avant la relecture ne connaissait pas 2012.
`Era.matching` rend Windows 7 à partir de 2010, `InstallEra` et `DayScript`
aussi ; un système inconnu d'avant reste traité comme avant.

**Le logiciel de 2012** : Windows 7 SP1 64 bits (`\Program Files (x86)`, le
magasin de pilotes, 128 traces de préchargement), Office 2010 et `\MSOCache`,
Visual Studio 2010, Battlefield 3 (dix-huit `cas` d'un gigaoctet et 1 200 `sb`),
Skyrim (douze `bsa`), iTunes 10 ; des photos de 5 Mo, des jeux de cinq à quinze
gigaoctets, des films entassés de 700 Mo. Ordres de grandeur, comme les autres
manifestes.

**Les quatre disques.** Joueur et développeur sur un **WD5000HHTZ** — le
500 Go, la capacité qu'on achetait pour un disque système ; la famille sur un
1 To déduit, qui est le 7200.14 ; la secrétaire sur un 500 Go déduit de la même
année. `gamer-2012` installe Battlefield 3 avant Skyrim (octobre puis novembre
2011) : c'est le jeu gardé qui est lancé au démarrage. Le volume entassé est
réglé pour finir entre 85 et 93 %, comme en 2007.

| profil | disque | plein | fragmentés | démarrage (disque) | témoin | installation | XP | génération |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `dev-2007` | IDE 250 Go | 86 % | 9,1 % | 46,7 s (34 %) | +2 % | 10 min 52 | 44 min 12 | 1,7 s |
| `dev-2012` | VelociRaptor 500 Go | 85 % | 1,3 % | 39,4 s (26 %) | +1 % | 11 min 16 | 38 min 35 | 2,1 s |
| `famille-2007` | IDE 320 Go | 93 % | 21,1 % | 38,8 s (40 %) | +3 % | 12 min 07 | 20 min 52 | 1,5 s |
| `famille-2012` | SATA 1 To | 91 % | 20,4 % | 30,0 s (45 %) | +6 % | 9 min 53 | 36 min 04 | 2,2 s |
| `gamer-2007` | IDE 320 Go | 90 % | 12,5 % | 31,5 s (45 %) | +4 % | 18 min 54 | 25 min 55 | 0,4 s |
| `gamer-2012` | VelociRaptor 500 Go | 92 % | 17,8 % | 44,0 s (26 %) | +2 % | 25 min 12 | 7 min 43 | 0,5 s |
| `secretaire-2007` | IDE 250 Go | 88 % | 2,3 % | 41,6 s (34 %) | −0 % | 10 min 22 | 19 min 06 | 0,4 s |
| `secretaire-2012` | SATA 500 Go | 93 % | 2,5 % | 33,8 s (36 %) | −1 % | 8 min 42 | 2 min 35 | 0,5 s |

Ce que le VelociRaptor change, à volume égal (le même profil sur un 500 Go
déduit à 7 200 tr/min, binaire jetable) :

| profil | démarrage, 7 200 → 10 000 | passe XP | vidages du cache d'écriture |
|---|---:|---:|---:|
| `dev-2012` | 41,1 → 39,4 s | 36 min 07 → **38 min 35** | 2 676 → 30 563 |
| `gamer-2012` | 46,2 → 44,0 s | 8 min 55 → 7 min 43 | 7 906 → 10 519 |

Le démarrage gagne 2 s : le calcul y pèse les trois quarts. Sur `dev-2012`, la
passe **ralentit**. Ce n'est pas le bras, c'est la politique de vidage :
`advanceBackground` lance un vidage dès qu'un trou s'ouvre entre deux commandes,
à condition qu'il **commence** avant la suivante, pas qu'il finisse. Un bras plus
rapide trouve plus de trous : il pose ses écritures une à une, loin des lectures
(3,3 par vidage contre 37), et chaque lecture suivante attend le retour. Le
7 200 tr/min, toujours occupé, les laisse s'accumuler et les pose d'une traite.

### Ce qui valide

- **Les 340 bilans de 1993 à 2007 sont identiques** à ceux de `develop`
  (`compare.py base e2 --identical`) : ni le 7200.14, ni la règle des
  10 000 tr/min, ni Windows 7 ne touchent une époque existante.
- `run.sh full` fait 412 bilans ; `readme-tables.py --check` : 0 écart.
- `NamedDriveTests` : un 10 000 tr/min de 2012 retrouve la fiche, celui de 2003
  reste en 3,5 pouces, les quatre disques de 2012 ont SATA 6 Gb/s, 64 Mo et la
  rampe, un système inconnu de 2012 démarre sous Windows 7.
- `SequentialThroughputTests` : quatre manuels, dans les 10 %.
- L'assistant et la galerie, vus sur le simulateur : fiche, sortie de fiche,
  10 000 tr/min déduit en 2012 (2 × 2,5″, 3 têtes, 209 Mo/s).

Au passage : `readme-tables.py --write` remplaçait les tables dans l'ordre de
déclaration, et une table qui gagnait une ligne décalait celles d'en dessous. Il
les remplace désormais du bas vers le haut. Et la ligne « débit bord → moyeu »
de l'assistant partageait sa clé avec une tuile des Instruments, dont elle ne
recevait que le premier nombre : clé à part. Le nombre de têtes a pris sa clé à
pluriel (`wizard.hw.heads`) : « 1 têtes » devient « 1 tête ».

### Laissé ouvert

- **La politique de vidage** du cache d'écriture : attendre un vrai repos avant
  de vider, ou laisser la pression du cache décider, rendrait au VelociRaptor ce
  qu'un bras rapide doit donner. Ça touche toutes les époques : à mesurer seul.
- **Un démarrage peut lancer une application désinstallée** :
  `launchedApplication` prend la première application installée sans regarder
  les désinstallations. `gamer-2007` « lance » Crysis, désinstallé en 2009, et
  en lit 0 Mo. Corriger change un démarrage calé de 2007.
- **Les constantes de Windows 7** (Vista ÷ 1,5) n'ont ni cible ni mesure.
- **Le NCQ**, que tout disque SATA de 2012 fait sous AHCI, et le pilote AHCI de
  Windows 7, dont le découpage des requêtes est inconnu (256 secteurs gardés).
- **La partition de 100 Mo** « Réservé au système » que Windows 7 crée devant
  le volume n'est pas modélisée.
- **Le rangement intelligent** n'a pas été joué sur les disques de 2012 (le
  README le dit sous sa table).
- **Le site et les captures** annoncent vingt disques de 1993 à 2007 : ils
  décrivent la version publiée, et changeront avec celle qui portera 2012.
- **L'écoute** : `SCENARIO=gamer-2012` contre `gamer-2007`, et un 10 000 tr/min
  de 2003 contre un de 2012 dans l'assistant.

## Chantier 35 — le lien Ko-fi

### Le problème

L'app est gratuite, sans achat intégré, et ni elle ni le site ne disaient où
laisser un pourboire : `https://ko-fi.com/gabylandais`.

### Les décisions

- **Dans l'app, une ligne des Réglages**, sous « Revoir l'accueil » :
  `settings.support.title` (« Support Winchester » / « Soutenir Winchester ») et
  `settings.support.note`, qui dit d'avance que le navigateur va s'ouvrir. C'est
  un `Link` : iOS ouvre Safari, l'app ne fait toujours aucune requête. La
  flèche ↗ remplace le chevron des lignes qui restent dans l'app.
- **Rien n'est débloqué en échange** : pas d'état « merci », pas de réglage
  caché. Un pourboire qui ouvrirait quoi que ce soit devrait passer par l'achat
  intégré (directive 3.1.1).
- **Sur le site**, « Support on Ko-fi » au pied des quatre pages, et une phrase à
  la fin de « Details » sur l'accueil.
- **La page confidentialité le dit** (« The Ko-fi link »), et « The app makes no
  network request » devient « The app itself… ». La date d'effet était déjà le
  21 septembre 2026.
- **Les notes de revue le disent aussi** : un relecteur qui lit « no network
  access at all » puis trouve un lien sortant doit l'avoir lu d'abord.

### Ce qui valide

- `./scripts/xcb.sh strings`, `i18n.py export` / `import` / `check` : 898 clés,
  aller-retour exact à l'octet.
- Sur le simulateur, en français : la ligne tient sur l'iPhone 17 Pro Max, et
  le tap ouvre Safari sur `ko-fi.com`.

### Laissé ouvert

- **Le risque de revue** : Apple refuse parfois un lien de don vers le
  développeur hors achat intégré. Si la 1.0.0 revient pour cela, retirer la
  ligne de l'app (le site peut la garder) ou passer à un pourboire StoreKit.
- **Les notes de revue ne sont pas poussées** : `asc review details-update`
  reste à lancer, avec le build qui portera la ligne.
- Le build 4 ne contient pas la ligne : il faut un build 5.

## Chantier 36 — le lien Ko-fi quitte l'app

### Le problème

La directive 3.1.1 le dit en toutes lettres : un pourboire au développeur,
dans l'app, passe par l'achat intégré — qu'il débloque quelque chose ou non. Et
3.1.1(a) interdit, hors storefront américain, tout lien vers un autre moyen de
paiement. La ligne du chantier 35 exposait la 1.0.0 à un refus.

### Les décisions

- **Plus de ligne « Soutenir Winchester »** dans les Réglages : la vue, la
  constante et les clés `settings.support.title` / `settings.support.note`
  (retirées de `i18n/translations.json`, puis `i18n.py import`) s'en vont.
- **Le site garde Ko-fi** (pied des quatre pages, phrase de l'accueil) : c'est
  hors de l'app et de ses métadonnées. Le README l'indique aussi.
- **La page confidentialité** perd « The Ko-fi link » et redit « The app makes
  no network request ». **Les notes de revue** ne mentionnent plus de lien
  sortant.

### Ce qui valide

- `./scripts/i18n.py check` : 896 clés, aller-retour exact à l'octet.
- `./scripts/xcb.sh build` réussit.

### Laissé ouvert

- Un pourboire StoreKit (consommables) reste possible, au prix de l'accord
  Paid Applications et du statut de professionnel (DSA) dans l'UE.
- Les notes de revue ne sont toujours pas poussées (`asc review details-update`).

## Chantier 37 — les liens croisés : app, site, dépôt, App Store

### Le problème

L'app, le site, le dépôt et la fiche de l'App Store (`6814382619`) ne se
citaient qu'à moitié : le site n'avait ni lien vers la fiche ni bannière Safari,
l'accueil gardait un commentaire à la place du bouton de téléchargement, le
README ne donnait aucune adresse en tête, et l'app n'en donnait aucune depuis
le départ de la ligne Ko-fi (chantier 36).

### Les décisions

- **Une section « À propos » en bas des Réglages** (`Sources/UI/AboutLinks.swift`,
  appelée par `SettingsScreen`) : site, assistance, confidentialité, code source
  sur GitHub, « Noter sur l'App Store » (`?action=write-review`) et « Autres apps
  du développeur » (page développeur `1891310404`). Les six adresses vivent
  dans `AboutLink`, seul endroit à les porter. Ce sont des `Link` : Safari ou
  l'App Store s'ouvrent, l'app ne fait toujours aucune requête, et une note sous
  le panneau le dit.
- **Toujours aucun lien de don dans l'app** (3.1.1) : Ko-fi reste sur le site et
  dans le README.
- **Huit clés** `settings.about.*`, en anglais et en français, par le cycle
  habituel (`xcb.sh strings`, `i18n.py export`, remplir, `import`).
- **Le lien vers la fiche est posé avant la publication**, par décision : il
  répond 404 tant que l'app n'est pas en vente.
- **Le site** : `<meta name="apple-itunes-app">` sur les quatre pages ; au pied,
  « App Store » à côté de « Source », et une ligne vers les trois autres apps
  (Aether, DepthWeaver, WhereIWas) et la page développeur. Sur l'accueil, le
  commentaire du héros devient un bouton « Download on the App Store » dessiné
  par la feuille de style (`.cta`), sans l'image d'Apple.
- **Le README** ouvre sur une ligne de liens : App Store, site, assistance,
  confidentialité, code source, autres apps, Ko-fi.
- **La page confidentialité** gagne « The About links » ; sa date d'effet ne
  bouge pas, rien de ce que l'app garde ou envoie n'ayant changé. **Les notes de
  revue** nomment ces liens sortants.

### Ce qui valide

- `./scripts/i18n.py check` : aller-retour exact à l'octet.
- `./scripts/xcb.sh build` réussit.
- Les quatre pages portent la balise et les liens (vérifié par `grep`).

### Laissé ouvert

- Pas vu sur le simulateur : la section n'a pas été regardée à l'écran ni en
  grand corps de texte.
- Les notes de revue ne sont toujours pas poussées (`asc review details-update`),
  et le build 4 ne porte pas la section : il faut un nouveau build.

## Chantier 38 — les pourboires par l'achat intégré

### Le problème

Le chantier 36 avait retiré le lien Ko-fi de l'app : un pourboire au
développeur, dans l'app, passe par l'achat intégré (directive 3.1.1). Restait à
offrir ce pourboire par la voie permise.

### Les décisions

- **Trois consommables** dans App Store Connect, créés le 22 septembre 2026 :
  `io.github.glandais.winchester.tip.small` (0,99 €, ID `6814712124`),
  `.medium` (2,99 €, `6814712555`) et `.large` (4,99 €, `6814712862`). Pays de
  base la France, disponibles dans les 175 pays, noms et descriptions en anglais
  et en français, note de revue sur chacun. Ils ne débloquent rien : il n'y a
  rien à restaurer, donc pas de bouton de restauration.
- **`Sources/Tips/TipJar.swift`** est copié du fichier de référence commun aux
  apps du développeur (hors de ce dépôt). Les identifiants sont tirés du bundle.
  Un achat vérifié est fini tout de suite, puis l'app dit merci. `start()`
  écoute `Transaction.updates` dès le lancement (`WinchesterApp`), pour finir un
  pourboire approuvé plus tard (Ask to Buy) ou interrompu.
- **`TipSheet`**, une feuille au style de « Son et vibrations », s'ouvre depuis
  une ligne « Soutenir Winchester » des Réglages, sous « Revoir l'accueil ». Elle
  a un chevron et pas la flèche ↗ : on reste dans l'app. Les noms et les prix
  viennent du store (`displayName`, `displayPrice`), dans la langue et la devise
  de l'acheteur, et le catalogue n'en porte aucun. Les achats passent par
  `@Environment(\.purchase)`.
- **Neuf clés** : `settings.support.title` / `.note` et `tip.*` (titre,
  en-tête, merci, en attente, échec, indisponible, réessayer), en anglais et en
  français.
- **`Support/Tips.storekit`** reprend les trois produits. Il est branché sur les
  schémas `Winchester` et `Winchester-Screenshots` par `storeKitConfiguration`
  (`project.yml`). Il ne vaut **que depuis Xcode** : `xcb.sh run` lance l'app par
  `simctl`, sans configuration StoreKit, et la feuille dit alors
  « indisponible » tant que les produits ne sont pas validés.
- **Page confidentialité** : un paragraphe « Tips » (Apple traite le paiement,
  le développeur ne reçoit rien de nominatif), en vigueur au 22 septembre 2026.
  **Notes de revue** : les trois identifiants, et qu'ils ne débloquent rien.

### Ce qui valide

- `./scripts/xcb.sh strings`, `i18n.py export` / `import` / `check` : aller-retour
  exact à l'octet.
- Sur l'iPhone 17 Pro Max, lancé depuis Xcode avec `Tips.storekit`, en français :
  la feuille liste 0,99 €, 2,99 € et 4,99 €. Un petit pourboire passe par la
  feuille de paiement de test, puis « Merci ! » s'affiche.

### Laissé ouvert

- ~~Les captures pour la revue~~ : la feuille en français, envoyée sur les
  trois produits le 22 septembre 2026. Les trois sont « Prêts à soumettre ».
- **La soumission** : le premier achat intégré part avec une version de l'app.
  Joindre les trois à la 1.0.0, avec un build 5 qui porte ce chantier.
- Pas vu : l'attente d'approbation (Ask to Buy), l'échec simulé, l'anglais,
  l'iPad et les grands corps de texte.
- Les notes de revue ne sont toujours pas poussées (`asc review details-update`).

## Chantier 39 — réalisme, lot A : le son

Premier lot de `LEDGER-REALISME.md`, et celui qui pose le protocole des
suivants : un état de référence, une prédiction écrite avant de mesurer, et la
mesure qui la juge. Branche `realisme`.

### Le problème

Trois fautes du dépouillement ne touchaient que le rendu : F1 (les résonateurs
de la broche vidés à chaque recalage), F8 (un peigne à −18 dB en mono) et F6
(la journée sous tension en 1,2 s quand le démarrage du même disque en met 4,4
à 7,4). Aucune n'a de test possible dans le paquet : `Sources/Audio` et
`Scenario.swift` n'y entrent pas. La vérification est donc le rendu hors-ligne.

### L'état de référence

Sous `.build/measure-realisme/`, sur `079b244` : `bin-base`, les 412 bilans de
`run.sh base full`, et — nouveau — **58 rendus sonores hachés**
(`wav-md5.py <étape>` : les deux démos, vingt-quatre démarrages, vingt-quatre
installations, les quatre journées du README, les quatre passes de 1993), en
1 min 36. `readme-tables.py base --check` reproduit le README, à une durée de
génération près (1,9 s mesurée machine chargée, pour 1,7).

### Les décisions

- **F1 : `Biquad.setBandpass`**, qui recale les coefficients sans toucher à
  `z1`/`z2`. La faute était réelle et le commentaire mentait ; **son effet
  était très en dessous de ce que le dépouillement annonçait**. Mesuré sur la
  broche seule (`TRANSIENT_GAIN=0`, `boot:dev-1999`) : niveau identique à
  0,1 dB près par demi-seconde, y compris sous 250 Hz, et un écart entre les
  deux rendus 20 à 25 dB sous un signal lui-même à −58…−42 dBFS. La raison : le
  recalage n'a lieu à chaque bloc que tant que la vitesse bouge de plus de
  0,004 par bloc de 512, soit sous 37 % du régime (τ = rampe / 3,2), là où
  l'enveloppe en v^1,6 est déjà presque muette ; ensuite il s'espace. « Le grave
  ne s'établit jamais pendant la première moitié de la rampe » était un calcul
  juste sur une prémisse fausse.
- **F8 : un élargissement milieu/côté.** Le signal retardé de 0,33 ms est
  ajouté à gauche et retranché à droite (`stereoSide = 0,6`, normalisé par
  √(1 + 0,36)) au lieu d'être posé sur le seul canal droit. Le calcul avait
  d'abord écarté l'autre piste : aucun retard ne passe entre sept modes étalés
  de 760 à 7 200 Hz (de 16 à 3 échantillons, le pire mode perd toujours 13 à
  18 dB ; à 2 il n'y a plus de largeur). Replié en mono, le côté s'annule.
- **F6 : une seule rampe, `BootScript.Era.spinUpDuration`** (`post − 0,6`),
  que prennent le démarrage et la journée. **Et la sonde a trouvé plus que la
  faute** : `DayPlanner` comptait déjà le POST en temps de calcul
  (`writer.think(boot.post)`), *après* le disque prêt. Avec 1,2 s de rampe la
  première lecture tombait à `post + 1,55 s` contre `post − 0,25 s` pour le
  démarrage seul ; aligner la rampe sans retirer ce `think` aurait compté le
  POST deux fois (+5,2 s, vu sur la longueur du WAV avant tout bilan). Le
  `think` est retiré : le POST *est* la montée en régime.
- **L'exposant de l'enveloppe n'est pas touché.** v^1,6 contre les v^2,5 de
  `windageBels` : juste pour le souffle, faux pour un roulement. La bonne
  correction est une enveloppe par bande, et c'est une décision d'écoute —
  avec le lot D.

### Ce qui valide

| prédiction, écrite avant | mesuré |
|---|---|
| F8 : mono(A) = gauche(base) / √1,36 | écart max **0,92 LSB** sur 2,8 M d'images ; crête 0,403 contre 0,373 |
| F1 : la broche seule ne diffère que pendant les rampes | différences de 0,38 à 14,5 s sur 58 s, puis identique au bit |
| les 58 `md5` changent tous (tout scénario a une rampe et des seeks) | 0 identique sur 58 |
| seules les journées changent de durée | les quatre, de −1,78 à −1,80 s ; aucune autre |
| 408 bilans identiques, quatre journées à −1,8 s | `compare.py base a --identical` : 408 / 4 |

**La première prédiction sur F6 était fausse** (« les bilans des journées ne
bougent pas ») : c'est elle qui a fait trouver le POST compté deux fois. Une
journée de `famille-2003` perd aussi un repère audio sur 826 : la salve de
recherche de la piste 0 tient maintenant dans la rampe au lieu d'être repoussée
par sa moitié.

`swift test` : 301 tests, dont `coldSpinUpFollowsThePost`. `xcb.sh build`
passe. README : les quatre durées de la table des journées (5 min 21, 6 min 33,
1 min 35, 1 min 58), par `readme-tables.py a --write`.

### Laissé ouvert

- **L'écoute.** `stereoSide = 0,6` est réglé au calcul (corrélation entre
  canaux 0,47, contre 0,14 avant : l'image est moins large, et centrée au lieu
  de tirer à gauche). Les paires avant/après sont dans
  `.build/measure-realisme/ecoute/` : stéréo, mono, et la mise sous tension
  d'une journée.
- **Aucun test ne garde F1 ni F8** : `Sources/Audio` n'est dans aucune cible du
  paquet. Y faire entrer `Biquad.swift` demanderait une cible de plus.
- **Les vidéos de l'App Store** portent le son d'avant. Leur bande vient de
  `RenderTrace` : les refaire donnerait un mono sans peigne — c'est là que F8
  s'entendait le plus.

## Chantier 40 — réalisme, lot B : les faits du catalogue

Second lot de `LEDGER-REALISME.md`, sur la branche `realisme`, après le lot A.
Sept constats de fait (E2 à E7, F7) et la fiche du Conner, que la relecture sur
source du 21 septembre avait ajoutée au lot.

### Le problème

Trois fiches contredisaient le manuel cité sur la ligne d'à côté (E2, E3, E4),
une constante morte se donnait pour le seul paramètre libre du modèle (F7), une
égalité d'année se tranchait par l'ordre de déclaration (E5), quatre logiciels
s'installaient avant leur sortie sans qu'on le dise (E6), et l'outil de 1993
portait le nom de Windows 95 (E7). Et la fiche de l'ancre de 1993 portait la
géométrie **CHS de translation** du Conner CFA170A — 1 806 × 4 × 46 — comme si
c'était sa mécanique : le vrai disque a un plateau, deux têtes, 2 111 pistes et
67 à 91 secteurs par piste (fiche BBS Conner, manuel 00532-001 transcrit par
TULARC). Les « 46 secteurs par piste de TULARC (45,96) sans y avoir été
poussé » que ce journal comptait parmi les points justes étaient la
reproduction exacte d'une fiction du BIOS.

### Les décisions

- **Le Conner à un plateau** : `heads: 2`, `tracksPerFace: 2_111`. Sa face
  porte deux fois plus d'octets qu'avant, donc `bestHeadCount` donne aux
  quatre volumes de 1993 la moitié de leurs têtes — `poweruser-1993` retombe
  seul sur les 4 têtes du vrai CFA340A : les « plateaux fantômes » du
  dépouillement étaient une erreur de fiche, pas un défaut de la déduction.
  Le roulement de 1993 est recalé pour que le Conner à **un** plateau garde
  ses 42 dBA ≈ 4,6 B (`1,4 × era` au lieu de `1 × era`) ; les 1993 à deux
  plateaux sonnent 5,0 B, comme avant.
- **E2, E3** : les capacités sont les secteurs garantis × 512 — U8
  `8_622_931_968`, ATA IV `20_020_396_032` — et un test le garde pour les
  fiches Seagate.
- **E4 et E5 ensemble : une fiche SATA du 7200.10** (ST3320620AS, manuel
  100402371 rév. F et K, rangés), même mécanique, même tampon, hôte SATA,
  8,5 ms « in performance mode » quand la fiche PATA garde ses 11,0 « in
  quiet mode ». Les deux sont de 2006 ; la SATA est déclarée devant, et
  `nearest` départage désormais une égalité en faveur du disque **déjà en
  vente** (le plus ancien) — une machine de 1998 porte un disque de 1996, pas
  de 1999. Une machine de 2007 reçoit donc le 7200.10 SATA, ni le PATA ni le
  7200.11. Le commentaire de la fiche PATA est corrigé (781 kBPI ; 78 Mo/s
  pour le seul 750 Go). La question « 8,5 ou 11,0 » n'est plus à trancher :
  chaque manuel a sa fiche, et les JSON de 2007 écrivent 8,5.
- **E6** : `AppManifest.releaseDate`, posé sur les quatre logiciels que le
  dépouillement nommait (MS-DOS 6.22, Quake, Netscape 3, Crysis) et sur eux
  seuls, et un avertissement de `ProfileIssues` quand l'installation le
  précède. **Les JSON de la galerie ne bougent pas** : quatre profils
  avertissent, et c'est écrit dans le test. Déplacer leurs dates change les
  volumes — lot F.
- **E7** : `Windows95Strategy(year:)` porte `strategy.msdos6` (« MS-DOS 6
  DEFRAG » / « DEFRAG de MS-DOS 6 ») avant 1995, `strategy.windows95` après.
  Seul le libellé change ; l'algorithme est un. `STRATEGY=windows95` passe par
  `chosen` et garde l'ancien nom — aucun bilan n'en dépend.
- **F7** : `dataBandInches` supprimée, son commentaire réécrit pour dire ce
  qu'elle était.

### Ce qui valide

| prédiction, écrite avant | mesuré |
|---|---|
| tous les bilans de 1993 et de 2007 changent, les `disk-*` jamais | oui : 60 et 68, et 24 `disk-*` identiques |
| tous les bilans de 1999 changent (+2,4 % de secteurs par piste) | **faux** : `dev` et `famille` seulement (30 sur 61). L'ancre ne fixe que le nombre de têtes ; tant que la densité reste dans la bande de ±20 %, la géométrie d'un volume ne bouge pas |
| 1996, 2003, 2012 et trois journées identiques | oui : 254 identiques, 158 différents |
| 27 `md5` sonores identiques | 33 — les deux 1999 inchangés et leur journée |

Les 1993 sont **plus rapides** de 8 à 20 % (dev-1993 sous l'outil de 95 :
23 min 36 → 21 min 43), ce qui surprend pour une course allongée : `STATS=1`
le ventile — transfert 308 → 217 s, latence 367 → 352, seek 668 → 672. Deux
têtes et 2 111 pistes font 79 secteurs par piste au lieu de 46, dans les
« 67-91 » de la fiche : le disque de 1993 lit 1,7 fois plus vite, et c'était
lui le vrai. Les 2007 gagnent 1 à 13 % par l'hôte SATA (transferts), et
« IDE » devient « SATA » sur leurs cartes.

`swift test` : 301 tests. Trois suites indexaient le catalogue par rang
(`all[7]`) et cassaient avec la fiche de plus : elles nomment maintenant la
fiche. README : 58 lignes réécrites par `readme-tables.py b --write`, dont la
table des plateaux (Conner : 1). Les trois durées de génération (1,7 s ; 50
et 32 ms) sont **gardées** : le lot ne change pas la génération, et la mesure
a été prise machine chargée — `--check` les compte en écart, comme avant.

### Laissé ouvert

- **Les JSON anachroniques** (E6) : les quatre profils avertissent, le README
  promet que « ce qui est anachronique avertit », et c'est vrai — mais un
  profil livré ne devrait pas avoir à avertir. À déplacer avec le lot F.
- **La pleine course du Conner (25 ms) et du U8 (23 ms pour 10,5)** attendent
  `fullStrokeMs` — lot E. Le U8 garde 8,9 jusque-là.
- **Le commentaire du tampon du Conner** dit « adaptive, segmented » : le
  modèle ne segmente pas.

## Chantier 41 — réalisme, lot C : les fautes de métadonnées

Troisième lot de `LEDGER-REALISME.md`, branche `realisme`, après A et B : F3,
F4 et F5, trois endroits où le code ne faisait pas ce que son commentaire
annonçait.

### Le problème

- **F3** — une validation FAT écrivait deux secteurs de table par copie, quel
  que soit le fichier : la chaîne d'un fichier contigu de 50 Mo en clusters
  de 4 Ko en occupe 100.
- **F4** — l'analyse d'une passe lisait la MFT « d'une traite » puis la
  plafonnait à 4 096 secteurs (0,16 % sur un 320 Go), lisait les répertoires
  à des clusters **tirés au hasard** alors que le volume connaît leurs
  extents, et minutait le tout en dur : 4,4 à 4,8 s sur tous les volumes, du
  FAT16 de 210 Mo au NTFS de 1 To (mesuré sur `b` avant d'écrire).
- **F5** — `HeadSample.time` est daté latence purgée, et `Platter`
  reconstruisait le départ du bras à rebours depuis cette date : le bras
  partait à l'écran une latence rotationnelle **après** le clic qu'on entend
  (4,2 ms à 7 200 tr/min, 8 sur un disque de 1993).

### Les décisions

- **F3 : `commitAccesses(for extents:)`.** La validation reçoit les extents
  de la nouvelle position, plus un cluster ; sur FAT, chaque extent réécrit
  les secteurs de table de son premier à son dernier cluster (un cluster
  seul : un secteur, plus deux), et l'entrée une fois ; sur NTFS, la bitmap
  aussi sur toute la longueur. Les huit stratégies, `MachineWriter` et
  `InstallSession` passent ce qu'elles savent — `[target]`, le refuge, les
  destinations, les extents du fichier. Un fichier en miettes coûte un accès
  par extent, comme avant.
- **F4 : `analysis(volume:)`.** La MFT se lit là où le volume la porte
  (`systemExtents`, extent par extent — 26 sur `famille-2007`), entière ; un
  volume d'essai qui ne la publie pas la lit d'un bloc, un enregistrement par
  fichier. Les répertoires se lisent à leurs extents, tous. Entre deux
  lectures, un calcul **nommé comme hypothèse** : 50 ms après une table, 10 ms
  après un répertoire — aucune durée d'analyse d'époque n'existe dans les
  sources relues. Le forfait de 4 096 secteurs sort de `scanAccesses`.
  Découverte en passant : sur NTFS, presque tous les répertoires sont
  **résidents** dans leur enregistrement de MFT — `famille-2007` n'en a que
  18 hors MFT, en 830 extents (le pire en 426), pour 1 127 au catalogue. Les
  1 127 lectures au hasard d'avant lisaient donc surtout des répertoires que
  la MFT contenait déjà.
- **F5 : `HeadSample.latency`**, un `Float16` dans les deux octets qui
  restaient du pas de 24 (un test le garde), et `arrivalTime = time −
  latency`. `Platter` fait arriver le bras à `arrivalTime`, puis l'y laisse
  immobile jusqu'à `time` : le clic se produit à l'arrivée, et l'attente du
  secteur se voit — sur un disque de 1993, 8 ms, un quart d'image.

### Ce qui valide

| prédiction, écrite avant | mesuré |
|---|---|
| toutes les passes (312 + 24 `full-*`) changent par F4 | oui |
| les 24 installations changent (F3, tables sales) | oui — durées identiques au dixième : les tables sales se fusionnent |
| les 4 journées changent | **3** : `famille-2003_400` n'écrit aucun fichier de plus de 4 096 clusters, la bitmap ne bouge pas |
| démarrages et `disk-*` identiques | oui : 49 identiques, 363 différents |
| 25 `md5` sonores identiques | 26 (la même journée) |

La phase d'analyse est maintenant faite par le disque : `secretaire-2003`
3,3 s pour 80 Mo de MFT, `famille-2007` 7,0 s pour 100 Mo et 854 lectures,
`famille-2012` 15,3 s pour 134 Mo ; `dev-1993` 1,6 s et `dev-1996` 1,4 s au
lieu de 4,4. F3 pèse peu sur les passes (`dev-1999` : +12 s sur 59 min) : ce
sont les seeks qui les font, pas les secteurs de table. Effet de bord
légitime : une analyse plus longue déplace l'horloge des points de contrôle
NTFS, et XP répare 112 fichiers sur `dev-2003` au lieu de 115.

`swift test` : 304 tests, dont la chaîne FAT (100 secteurs pour 50 Mo, 9 quand
elle chevauche un secteur), l'analyse à sa place, le bras qui attend, le pas
de 24 octets. `xcb.sh build` passe. README : 88 lignes réécrites, générations
gardées.

### Laissé ouvert

- **Les 50 et 10 ms de calcul** de l'analyse sont une hypothèse à régler à
  l'oreille — c'est le seul temps de la phase 0 qui ne vienne pas du disque.
- **Regarder le bras** dans le simulateur sur un démarrage de 1993 (F5).
- **La MFT lue ici est celle du formatage plus les extents publiés** ; F2
  (les enregistrements adressés comme si `$MFT` était d'un seul tenant) reste
  au lot F.

## Chantier 42 — réalisme, lot E : la pleine course

Quatrième lot de `LEDGER-REALISME.md`, branche `realisme`, après A, B et C.

### Le problème

`calibrated(averageSeekMs:trackToTrackMs:cylinders:)` ne recalait que la
branche courte de la loi sur la fiche ; la longue venait de `referenceShape`
étirée, si bien que **pleine course / seek moyen valait 1,80 pour tous les
disques** — 16,06 ms sur un U8 dont le manuel dit 23,0. Le « seek moyen »
était T(N/3), quand quatre manuels le définissent comme une moyenne
statistique de seeks aléatoires (E[T]), ce qui rendait le disque simulé 2,7 à
3,9 % plus rapide que sa fiche en accès aléatoire. Le U8 portait 8,9 ms, le
chiffre non défini de sa table de tête, contre 10,5 dans la table qui définit
et publie la pleine course. Et les trois fiches à rampe se parquaient au
moyeu, avec une pleine course en ouverture et en fermeture qu'elles ne font
pas — la rampe d'un 3,5 pouces est au diamètre extérieur.

### Les décisions

- **Le seek moyen est l'espérance.** `averageSeekMs(cylinders:)` somme la loi
  sur la distribution 2(N − d)/N² de la distance entre deux cylindres
  uniformes ; `RandomSeekWeights` en fait quatre sommes, calculées une fois,
  après quoi l'espérance est linéaire dans les quatre constantes.
- **Trois durées, quatre équations, en fermé** :
  `calibrated(averageSeekMs:trackToTrackMs:fullStrokeMs:cylinders:)` fait
  passer la branche courte par (1, piste-à-piste), la joint à la longue au
  croisement (gardé à 15 % de la course), fait passer la longue par (N − 1,
  pleine course) et donne à l'espérance le seek moyen. Sans pleine course
  publiée, celle de la forme de référence dans son rapport à E[T] : **1,855**
  (et non 1,80 : le rapport change avec la définition du moyen). L'ancien
  calage reste en repli, sous le nom qu'il mérite (`roughlyCalibrated`).
- **`fullStrokeMs` sur trois fiches** : Conner 25,0 (TULARC ; 26 sur le
  manuel préliminaire du CP30174), Fireball 21,0 (table 4-3, colonne des
  « one-disk drives », celle des 12,0 ms retenus), U8 23,0 (§1.5). Les
  rapports vont de 1,75 à 2,19 : une forme unique ne les tenait pas. Un disque
  de la galerie emprunte le rapport de la fiche la plus proche
  (`fullStrokeRatio`), comme il empruntait déjà le seek d'écriture. Le U8
  publie aussi 25,0 en écriture : `WriteSeek` porte les deux pleines courses,
  et la loi d'écriture est calée à trois durées elle aussi.
- **Le U8 à 10,5 ms**, la seule des deux valeurs définie et appariée. Aucun
  scénario ne lit son `seekModel` (les JSON de 1999 écrivent 9,0) ; ce qui
  bouge est le rapport de pleine course des volumes de 1999 (2,19), et la
  valeur par défaut de l'assistant vers 1997-2000.
- **`parkCylinder(rampLoad:)`** : 0 pour une rampe, le moyeu sinon.
  `DiskMechanics`, `PlatterTrack` (par `LivePass.rampLoad`, depuis
  `setup.idle`) et le parcage final le prennent. Le commentaire « ou une rampe
  juste au-delà » est corrigé.

### Ce qui valide

| prédiction, écrite avant | mesuré |
|---|---|
| tout ce qui fait un seek change (388), les 24 `disk-*` jamais | 373 changés, 39 identiques : les 24 `disk-*`, plus 15 bilans qui ne bougent pas **au dixième** (deux démarrages de 1993, les treize passes de `gamer-1996`, qui n'ont rien à ranger) |
| 0 `md5` sonore identique | 0 sur 58 |
| sens global incertain, ±3 % | **+0,1 à +1,1 %** selon l'année et le type : E[T] est tenu par construction, et ce que la loi perd à N/3 elle le rend sur les courses longues |

Le modèle donne maintenant 16,7 ms de pleine course à l'ATA IV et 7,05 au
VelociRaptor (contre 16 et 6,85) — le README les dit comme des sorties du
modèle, ce qu'ils sont. `swift test` : 305 tests, dont la pleine course des
trois fiches et de l'écriture du U8, et le disque à rampe qui part du bord.
`xcb.sh build` passe. README : 97 lignes réécrites, générations gardées.

### Laissé ouvert

- **Le croisement à 15 %** de la course, quand Ruemmler & Wilkes se croisent
  vers 20 % : non touché, il faudrait une mesure pour trancher.
- **Le Fireball 1080AT** porte 4 têtes et les seeks de la colonne « one-disk »
  de son manuel : la fiche mélange deux modèles de la gamme, comme avant.
- **Les rapports de 1993 à 1999 sont ceux de trois disques** ; entre 2001 et
  2012, tout le monde reçoit 1,855, faute d'un manuel Seagate qui publie sa
  pleine course.

## Chantier 43 — réalisme, lot D : la voix de la tête par disque

Cinquième lot de `LEDGER-REALISME.md`, branche `realisme`, après A, B, C et
E. Le chantier d'écoute que quatre journaux d'affilée réclamaient.

### Le problème

`SeekSynth` était le même pour les vingt-quatre disques : `modes` est un
`let`, l'initialiseur ne recevait rien du disque, et `load` n'écrivait que
`spindle.character`. Les manuels publient pourtant la puissance acoustique en
seek, et, le repos retranché, le bras seul va de 3,20 B sur le U8 à 1,97 sur
le 7200.14 — douze décibels que rien ne disait. Le coude du gain de la broche
compensait côté plateau ce qui ne variait pas côté tête.

### Les décisions

- **`Acoustics` sur les fiches** : `idleBels`, `seekBels`, la source. Neuf
  fiches en publient (U8, ATA IV, 7200.7, 7200.10 PATA et SATA, 7200.11,
  7200.14, les deux VelociRaptor) ; ni le Conner ni le Fireball TM (son manuel
  ne donne que le repos). `seekOnlyBels` retranche le repos en puissance.
  Le PATA du 7200.10 ne publie que le *quiet seek* (3,0), le SATA le
  *performance* (3,7) : chaque fiche porte ce que son manuel dit, et la
  machine de 2007 reçoit la SATA.
- **`SeekCharacter`**, à côté de `SpindleCharacter` : un niveau, pas un
  timbre — aucune fiche ne publie un spectre. `init(geometry:year:)` emprunte
  à la fiche la plus proche qui publie (`DriveCatalog.acoustics(year:)`,
  comme `writeSeek`) : 1993 et 1996 au U8, 2012 au 7200.14, un 10 000 tr/min
  à petits plateaux au VelociRaptor. Le gain est **à moitié en décibels**, le
  U8 à 1 — le même parti qu'au plateau sous son coude : six décibels à
  l'écoute pour douze aux manuels.
- **`SeekSynth.headGain`**, immuable comme le reste du synthétiseur, appliqué
  aux seeks, aux trains, aux tics — pas au décollement ni à l'atterrissage,
  qui sont des contacts. `WinchesterEngine.load(feed:character:seek:)`
  refait le synthétiseur et vide ses caches quand le gain change ;
  `StreamingMixer` le reçoit à la construction. `PassSetup.seekCharacter`.
- **Le coude de la broche n'est pas desserré** : c'est l'autre moitié de la
  décision d'écoute, à prendre après avoir entendu celle-ci.

### Ce qui valide

| prédiction, écrite avant | mesuré |
|---|---|
| 412 bilans identiques (un gain ne change aucune requête) | 412 |
| 33 rendus identiques au bit : tout ce qui emprunte au U8 (1993, 1996, 1999, les deux démos, trois journées) | 33 ; les 25 changés sont 2003, 2007, 2012 et `famille-2003_400` |

`swift test` : 306 tests, dont les niveaux contre les manuels (3,20 / 1,97 /
3,64 B, six décibels pour douze) et les emprunts par année. `xcb.sh gen` puis
`build` : `SeekCharacter.swift` entre dans le projet et dans
`Tools/build-render.sh`. README : la table des niveaux sous « Timbre de la
tête ».

### Laissé ouvert

- **L'écoute**, enfin : `.build/measure-realisme/ecoute-d/` porte trois
  démarrages avant et après — `secretaire-2003` (−0,8 dB), `famille-2007`
  (+2,2), `famille-2012` (−6,2). C'est le 2012 qui juge le parti de la
  moitié : s'il disparaît sous sa broche, le quart ; s'il reste trop fort, le
  coude de la broche est à desserrer, pas la tête à monter.
- **Le timbre reste commun.** Un `SeekCharacter` pourrait porter un dosage
  de modes par époque (un bras de 1993 n'a pas les résonances d'un 2012) ;
  sans source, ce serait de l'oreille.
- **La gestion acoustique** (*quiet seek*, trajectoires sinusoïdales) n'est
  pas modélisée, et le README le dit maintenant.

## Chantier 44 — réalisme, lot F : ce qui change les volumes

Sixième lot de `LEDGER-REALISME.md`, branche `realisme`, le seul qui touche
aux vingt-quatre disques eux-mêmes — d'où sa place en dernier, et un seul
recalage.

### Le problème

- **E1** — `sizeBytes = sizeMB × 2²⁰`, quand l'étiquette est décimale :
  vingt-et-un volumes sur vingt-quatre étaient 4,86 % plus gros que le disque
  affiché (un 1 To simulait 1 048,6 Go).
- **La place de `$MFT`** — la branche `.nearStart` posait la MFT derrière les
  64 Mo du journal, vers le cluster 16 400, et interdisait toute donnée avant
  12,5 % du volume. Aucune disposition Windows attestée ne fait cela (la
  relecture sur source du 21 septembre).
- **F2** — les enregistrements de MFT étaient adressés `mftLBA + n × 2`,
  comme si `$MFT` était d'un seul tenant, alors qu'elle se fragmente (31
  extents sur `famille-2003`) et que le générateur publie ses extents.
- **E6, la suite** — quatre profils installaient un logiciel avant sa sortie.

### Les décisions

- **`sizeMB` est le mégaoctet de l'étiquette**, décimal ; les JSON ne
  bougent pas, `sizeBytes = sizeMB × 10⁶`, `DiskSpec(reference:)` divise par
  10⁶. Ce que le système montre ensuite est en mébioctets, comme CHKDSK : un
  210 Mo de 1993 en affiche 200, et c'est ce qu'il affichait. La phrase de
  `CLAUDE.md` sur le 2²⁰ « sans quoi un 210 Mo ne retrouverait pas ses 210 »
  décrivait ce défaut ; elle est à relire.
- **`NTFSAllocator.Formatting`** — `.nt`, `.xp`, `.vista`, `.win7`, choisi
  par le champ `os` du profil, l'année en repli. `$MFT` en tête sous NT, **à
  3 Gio** depuis XP (Sedory, une source secondaire ; au huitième d'un volume
  plus petit, une règle du modèle) ; `$MFTMirr` au milieu jusqu'à Vista, au
  LCN 2 sous Windows 7 ; zone de 12,5 % jusqu'à XP, **200 Mo renouvelables**
  depuis Vista (KB 961095, primaire : quand la MFT a rempli sa tranche, une
  tranche neuve et contiguë est réservée derrière le vierge, et la MFT y
  continue d'un seul tenant). **Les données se posent devant `$MFT`**, dans
  les trois premiers gigaoctets, puis derrière la zone : c'est ce que montre
  un `fsutil` moderne, et c'est une hypothèse pour XP — la KB 961095 dit le
  contraire à la lettre. `$LogFile` derrière le miroir, comme `mkntfs`,
  faute de source. Tout cela est écrit dans l'allocateur et le README.
  Mécaniquement : deux plages de données au lieu d'une, le `highWater` qui
  part devant la MFT, et le vierge borné à sa plage — la zone est libre dans
  la bitmap, un premier trou pouvait y déborder.
- **`PartitionGeometry.mftRecordLBA(_:)`** : l'enregistrement *n* est *n*
  kilo-octets dans la suite des extents de `$MFT` (`GeneratedDisk.mftFileExtents`),
  et au-delà du dernier, derrière lui. Les validations, les lectures groupées
  d'un démarrage (coupées à chaque extent) et les dates d'accès y passent.
- **`MFTNumbering` reste le rang parmi les vivants.** L'autre approximation
  — compter les disparus, chaque fichier gardant le rang de sa création — a
  été écrite et **écartée** : elle suppose que rien n'a été effacé avant la
  dernière création, et elle défait ce qui s'entend, des fichiers créés à la
  suite dans des enregistrements voisins qui partagent leur page de 4 Ko
  quand XP les horodate. Le catalogue ne date pas les suppressions ; la
  reprise du plus petit enregistrement libre ne se rejoue pas, et le
  commentaire le dit.
- **Les dates** : `gamer-1996` et `famille-1996` commencent le 1ᵉʳ septembre
  1996 (Quake, Netscape 3), `gamer-2007` le 15 novembre 2007 (Crysis), leurs
  fins déplacées d'autant. MS-DOS 6.22 devient **MS-DOS 6** — le 6.0 est de
  mars 1993, et le manifeste décrit la famille ; `osName` et le site suivent.
  Aucun profil de la galerie n'avertit plus, et un test le garde.
- **Le recalage** : `perMegabyte` seul, par époque, sur `f0` — 1993 0,65 →
  0,93, 1996 0,42 → 0,41, 1999 0,24, 2003 0,19 → 0,185, 2007 0,15 → 0,146.
  Le 0,93 de 1993 est **le prix des cibles** : la fiche du Conner (chantier
  40) a rendu au disque ses 79 secteurs par piste et quatre secondes de
  démarrage, que la cible n'accorde pas ; le processeur les reprend, et le
  plancher de calcul de 1993 passe de 15 à 19 s sur 42. Le commentaire de
  `ThinkModel.boot` le dit.

### Ce qui valide

| prédiction | mesuré |
|---|---|
| 412 bilans différents, 0 identique (tous les volumes rétrécissent) | 412 / 0 |
| 0 rendu identique | 0 sur 58 |
| les démarrages retombent près de leurs cibles, sauf là où la disposition déplace chaque profil différemment | dix-sept des vingt sur ±5 % ; `famille-2003` +18 %, `famille-2007` +13 %, `dev-2007` −10 % — la MFT à 3 Gio et les données devant elle changent le nombre de seeks (`famille-2003` : 741 → 1 062) sans qu'une constante d'époque puisse le suivre |

`swift test` : 306 tests. Ceux de la disposition sont refaits : `$MFT` à
3 Gio (LCN 786 432 sur 250 Go, un premier fichier devant elle), le miroir
selon l'époque, la zone selon le système, la disposition selon `os`, le
montage en quatre ou cinq zones. Le test des dates d'accès de 2003 garde
son sens avec un seuil desserré (994 fichiers, 567 écritures : le cache vide
plus souvent depuis que la MFT est loin des données). README : 173 lignes,
et les trois passages sur la zone MFT réécrits. `xcb.sh build` passe.

Un accident de méthode : retoucher un commentaire de `BootSession.swift`
pendant que `snapshot.sh` compilait a donné un binaire qui plantait
(« modified during the build ») — refait, sans toucher aux sources.

### Laissé ouvert

- **Trois démarrages loin de leur cible** (`famille-2003`, `famille-2007`,
  `dev-2007`) : la disposition de la MFT n'est pas un coût au mégaoctet, et
  le recalage ne peut pas l'absorber. C'est l'endroit où les cibles — les
  durées d'avant la relecture — cessent d'être une référence.
- **Les données devant `$MFT` sous XP** : une hypothèse, contre la lettre
  d'une KB. Un `fsutil` et une carte de défragmenteur d'un volume XP frais
  trancheraient.
- **La place de `$LogFile`** depuis XP : inconnue.
- `GalleryAllocationAudit` en release, sur les deux plages de données, a
  passé (21 min) : l'invariant d'allocation tient sur les vingt-quatre
  volumes.

## Chantier 45 — réalisme, lot G : le défragmenteur de XP, d'après son code

Septième lot de `LEDGER-REALISME.md`, branche `realisme`, après F. Le seul qui
repose sur une source que le projet n'avait jamais utilisée : **le code de
Windows XP SP1** tel qu'il a circulé en 2020, ici `Source/XPSP1/NT/base/fs/`
(`utils/dfrg/dfrgntfs/dfrgntfs.cpp`, `mftdefrag.cpp`, `bootoptimizentfs.cpp`,
`utils/dfrg/fssubs.cpp`, `freespace.cpp`, `movefile.cpp`, `ntfs/deviosup.c`,
`ntfsdata.h`). Gabriel l'a décidé, et l'assume : ce n'est pas une source
ouverte comme JkDefrag ou UltraDefrag ; le README le dit là où il décrit
l'outil, et ce fichier ici. Le code n'est pas recopié — ce qui suit reconstitue
un comportement — et les extraits rangés hors du dépôt
(`../disknoise.resources/sources-realisme/xpsp1-*.txt`, avec la synthèse
`xp-dfrg-evacuation-synthese-xpsp1.md`) ont été relus contre l'arborescence
avant d'écrire une ligne : `DefragNtfs` aux lignes 4189-4299,
`FreeSpaceErrorLevel = 15` à `fssubs.cpp:1239`, `LARGE_BUFFER_SIZE` à
`ntfsdata.h:345`, « Sigh. No free space chunk » à 3334, le tri « in REVERSE
order » à 478, `PartialDefragNtfs` à 4371 sans appelant. Une broutille dans la
synthèse : la ligne 4287 lit `25 / (uMoveFilesCount * 2)`, sans `++`.

### Le problème

Le README disait de l'outil de XP qu'il « n'évacue personne », sur douze
colonnes ; c'était une hypothèse énoncée comme un fait, et le dépouillement
l'avait relevée. La documentation ouverte (Windows Server 2003, le Resource
Kit de XP) disait déjà que l'outil consolidait l'espace libre et recollait la
MFT dès XP ; elle ne disait pas comment. Le code le dit.

### Les décisions

- **`WindowsXPStrategy` réécrite d'après `DefragNtfs`**, phase par phase :
  la MFT recollée avant et après (`MFTDefrag` : sa queue en plus d'un morceau
  part d'un bloc vers le premier trou qui la tient — `DefragVolume` porte
  maintenant `mftExtents` et `relocateMFTTail`) ; les fichiers cassés par
  taille croissante puis numéro d'enregistrement, chacun entier dans **le plus
  petit trou qui le tient** (*best fit* sur une liste triée par taille, bâtie
  une fois par phase et consommée — l'outil relisait la bitmap entre deux
  phases), arrêt au premier sans trou (`MinimumLength`) ; **la consolidation
  d'une région** — la plus longue suite de trous et de fichiers contigus
  adjacents, d'au moins `MinimumLength`, plus longue que le plus grand trou,
  occupée à moins de 75 %, vidée de la fin vers le début, chaque fichier vers
  le plus petit trou hors d'elle, abandonnée après dix échecs ; **la zone MFT
  vidée** une fois ; **le tassement vers l'avant** — les fichiers contigus par
  LCN décroissant, chacun vers le trou de plus petit numéro qui le tient devant
  lui, les fichiers au moins aussi gros que le dernier échec sautés, arrêt
  quand un fichier d'un cluster ne trouve plus rien. Les boucles sont celles
  de la source, plafonnées par le modèle (32 tours) là où elle ne l'est pas.
- **64 Kio par bloc** (`LARGE_BUFFER_SIZE`, une lecture puis une écriture par
  bloc dans `NtfsDefragFile`), au lieu des 4 Mo empruntés à UltraDefrag.
- **La zone MFT respectée** n'est plus une hypothèse : `BuildFreeSpaceList` en
  rogne les trous. Les 15 % de `FreeSpaceErrorLevel` ne sont qu'un seuil
  d'avertissement ; le moteur ne change rien en dessous, le modèle non plus.
- **Vista et Windows 7** : le même moteur, daté par `WindowsXPStrategy.dated`
  (`year`, comme l'outil de 95), avec le seuil de 64 Mo de KB 942092 — un
  fichier dont le plus petit fragment atteint 64 Mo reste en place, une
  approximation dite (l'outil ne recollait que les petits morceaux). Les
  cartes et la passe le nomment « Windows Vista Defragmenter », « Windows 7
  Defragmenter » (`strategy.vista`, `strategy.win7`, `tool.vista.*`,
  `tool.win7.*`) ; les phases « Consolidating free space » et « Moving files
  forward » portent les noms du journal de l'outil.
- **Ce que la source donne et que le modèle ne fait pas**, dit dans le
  docstring : la zone d'optimisation du démarrage (`layout.ini`, 32 Mo par
  fichier), que `BootLayout` traite à part ; le point de contrôle de
  transaction par bloc de 64 Kio, dont on ne sait pas s'il force une écriture
  du journal.

### Ce qui valide

| prédiction, écrite avant | mesuré |
|---|---|
| les 12 passes XP et les 12 `full-*-windowsXP` changent, le reste non | **36** : les 12 passes XP sur FAT aussi, oubliées de la prédiction — l'outil s'y demande par `STRATEGY` |
| 58 rendus identiques (aucun ne joue une passe XP) | 58 |
| les durées XP montent d'un ordre de grandeur | de 2 à 3 fois : `secretaire-2007` 28 → 55 min, `gamer-2007` 49 min → 2 h 19, `dev-2007` 53 min → 2 h 41, `famille-2012` 37 min → 2 h 11. Les requêtes, de 7 à 60 fois (`dev-2007` : 245 298 → 6 175 438) |
| le temps de planification explose | **non** : les 412 bilans en 5 min, comme avant |

Ce que les douze passes disent maintenant : `dev-2003` répare 185 fichiers
sur 192 au lieu de 170, en 1 959 évacuations et 14 Go déplacés au lieu de 5 ;
les trous restants tombent de 2 700 à 381 sur `dev-2003`, de 9 705 à 1 935
sur `dev-2007`, de 21 114 à 8 043 sur `famille-2012` — sans jamais tomber à
zéro, parce que le tassement est en *first fit* et laisse les petits trous,
comme la source le laisse prévoir. Un volume que l'outil nettoyait
entièrement (`secretaire-2007`, `dev-2012`) en garde un ou deux fichiers : le
*best fit* et la région vidée ne rendent pas le même volume que le premier
trou qui tient. Les écritures partent en salves de 97 par vidage sur
`dev-2007`, contre 6 : des blocs de 64 Kio arrivent plus vite que le disque
ne les pose.

`swift test` : 306 tests. Les tests qui vérifiaient une **absence** (« n'évacue
personne », « n'est pas ramené vers le début », « seuls les fragmentés sont
touchés ») sont retournés en leur contraire, avec un volume où la région se
vide et un où le tassement ramène un fichier ; les comptes de requêtes suivent
les 64 Kio. `xcb.sh build` passe ; 925 clés, quatorze neuves ou réécrites
(`summary.windowsXP` dit maintenant ce qu'il déloge et ce qu'il tasse) ; le
site suit l'unité `en` de `tool.windowsXP.principle`. README : 75 lignes, la
description de l'outil, « ne déloge personne » retiré, « respecte la zone »
sourcé, « 64 Kio » dans « Ce qui ne l'est pas ».

### Laissé ouvert

- **L'écoute** : le tassement vers l'avant est un long balayage que la passe
  de XP n'avait pas ; `SCENARIO=dev-2007 STRATEGY=windowsXP` contre `f`.
- **Vista et 7** ne recollent que les petits morceaux ; le modèle déplace le
  fichier entier ou pas du tout. Le point de contrôle par bloc, le délai entre
  deux fichiers, le cache : non sourcés, comme avant.
- **La zone d'optimisation du démarrage** : `BootLayout` la range à sa façon
  (chantier 28), pas à celle de `ProcessBootOptimise` (32 Mo par fichier,
  zone déplacée sous 90 %) — à rapprocher.
- **Le rangement intelligent** (`smart`) mesurait son gain contre un XP qui
  n'évacuait pas ; sa table du README n'a pas été refaite (les douze
  « non vérifiées » de `--check`).

## Chantier 46 — le variateur : écouter une passe à ×0,5, ×1, ×2, ×4 ou ×8

**Fait** · branche `variateur`

### Le problème

Une passe dure ce qu'elle durait : 5 min 56 pour la démo, 44 min 12 pour
`dev-2007`, 57 min 12 pour `famille-1999`, de 7 à 25 minutes pour une
installation. Le README affirmait même qu'une passe « n'est jamais accélérée ».
C'est vrai du modèle, et ça doit le rester ; rien n'obligeait l'écoute à s'y
tenir.

### Les décisions

**C'est l'horloge qui change d'allure, pas le disque.** Le temps de passe ne
rejoignait le temps réel qu'en deux endroits de `WinchesterEngine` : `tick()`,
qui lit l'horloge du player, et `schedule()`, qui y date un tampon. Les deux
passent désormais par `PlaybackClock` (`Sources/Model/`, pour être testée par
`swift test`) : `passTime = offset + elapsed × allure`, et l'inverse. Les
marges du moteur — 0,70 s d'avance de programmation, 50 ms de tolérance — sont
des durées **réelles** et passent par `passSpan`. Le rendu hors-ligne ne
compile pas le moteur : il n'en sait rien, par construction.

**Changer d'allure, c'est se ré-ancrer**, ce que faisait déjà une pause suivie
d'une reprise : le player s'arrête — ce qui efface les transitoires datés à
l'ancienne allure —, `offset` prend le temps de passe atteint, et ce qui avait
été confié au player sans être joué lui est reconfié. L'instant se lit sur
l'horloge du player et non sur `currentTime`, vieux d'un tour de pompe : ce
retard aurait rejoué les transitoires d'entre-deux.

**Le son garde son timbre.** Les seeks sont des tampons pré-rendus dont seules
les dates se resserrent ; la rotation est procédurale, réglée par une consigne
et non par une date, et ne monte pas d'une octave. Ses rampes durent
`durée / allure`, pour rester d'accord avec le plateau à l'écran.
`AudioSnippets` (RenderVideo) avait choisi des extraits en fondu pour la même
question ; ici la carte et le son doivent rester synchrones, ce que des
extraits ne permettent pas.

**L'avance du producteur est une avance réelle.** Huit secondes de passe n'en
font plus qu'une à ×8 : `PassSession.setPace` porte l'horizon à `8 × allure`
(jamais moins de 8), et réveille le producteur.

**Ce qui est réglé pour l'œil reste en temps réel.** Compté en temps de passe,
tout aurait fondu à ×8 : `LivePass.pace` multiplie la mémoire du plateau et de
la carte, la rémanence (`MapTrail.window`), le surlignage d'un bloc, la traînée
et la lueur des faces. Et — trouvé en route — la **rotation affichée** : à ×8 un
7 200 tr/min aurait fait 57,6° par image, au ras du repliement stroboscopique
que `rotationSlowdown` est là pour éviter. `turns` est divisé par l'allure. Le
bandeau d'activité reste en temps de passe : c'est un axe, pas une rémanence.

**Un bouton, pas un menu.** La première version était un `Menu`. Ouvert pendant
la lecture, il fige l'app : tant qu'un menu est présenté, chaque image relance
un balayage complet du focus d'UIKit (`_focusEnvironmentDidAppear` →
`updateFocusIfNeeded`), le fil principal reste à 100 % et ne traite plus un
toucher. Le focus n'existe que clavier branché — le simulateur, et un iPad avec
son clavier. Le bouton fait le tour des allures d'un tap (×1 → ×2 → ×4 → ×8 →
×0,5), et VoiceOver le règle par incrément. Son jumeau invisible, qui garde la
lecture au centre, est une étiquette inerte.

**Chaque passe repart à ×1** (`load`), et rien n'entre dans `UserDefaults` :
l'écoute fidèle reste le défaut. Le mode capture ne touche jamais à l'allure.

### Ce qui valide

| | |
|---|---|
| rendu hors-ligne, `SCENARIO=defrag` | `md5` identique avant et après (`ac8f6994…`) |
| `swift test` | 151 + 307 tests ; neufs : `PlaybackClockTests`, l'horizon qui suit l'allure, la rotation affichée |
| ×8, Release, simulateur | 68 s de passe en 8,6 s réelles (×7,9), 43 % de CPU |
| ×0,5 | 4 s de passe en 8,5 s (×0,47, à la seconde d'affichage près) |
| bascules en pleine lecture, pause, reprise, fin de passe et bilan à ×8, relance → ×1 | vus sur le simulateur |
| chaîne complète optimisée | 357 s de passe rendues en 5,3 s sur le Mac : ×8 y coûte ~12 % d'un cœur |

En **Debug**, ×8 double le CPU (66 % → 128 %) : huit secondes de trains à
synthétiser par seconde, sans optimisation. Ce n'est pas l'app que reçoit
l'utilisateur, mais c'est celle qu'on pilote : juger l'allure en Release.

### Laissé ouvert

- **L'écoute.** Le simulateur ne dit rien du son : ×2, ×4 et ×8 sont à entendre
  sur l'appareil. Au-delà de ×2 les transitoires se chevauchent — le
  regroupement en trains (`AudioCue`) se fait en temps de passe. Si c'est
  désagréable, éclaircir les repères trop proches en temps réel, dans le moteur
  seul.
- **L'haptique à ×8** : huit fois plus de chocs par seconde, non essayé.
- **Les gros NTFS à ×8** (`dev-2007`, JkDefrag) : le producteur doit tenir
  8 s de passe par seconde sur un iPhone ; s'il décroche, la lecture se met en
  attente comme elle le fait déjà. Non mesuré sur l'appareil.
- **L'iPad** : le transport n'a pas été vu sur l'iPad, que seul
  `screenshots.sh` démarre.
- **Les autres `Menu`** présentés pendant une lecture (la minuterie du mode
  ambiance) le sont peut-être aussi, clavier branché : essai non concluant.
- **Le site** (`docs/support/`) ne parle pas de l'allure : il décrit la version
  publiée, et changera avec le build qui la portera. Les captures aussi.

## Chantier 47 — XP à la lettre : les défauts sans dépendance

**Fait** · branche `xp`, partie de `develop` à `2a15ed2` · plan : `LEDGER-XP.md`

### Le problème

Le premier des six chantiers de `LEDGER-XP.md` : les défauts de l'audit
(`AUDIT_REALISME.md`) et du relevé contre le code de XP SP1
(`WINDOWS_CHECK.md`) qui ne dépendent de rien d'autre. B#15 passe avant tout :
le chantier 50 fera recoller la MFT à presque chaque passe XP, et les
validations doivent d'abord suivre la MFT déplacée (`WINDOWS_CHECK.md`, §4).

### Les décisions

- **B#15** : `DefragVolume.partition` devient `private(set) var`, et
  `relocateMFTTail` y reporte les extents de la MFT. `mftRecordLBA`, qui
  situe l'enregistrement de chaque validation, suit donc la MFT déplacée
  (l'autre voie, passer les extents au `commit`, touchait toutes les
  stratégies). Le plan rend la partition d'après la passe.
- **B#16** : l'avancement de la passe XP ne descend plus
  (`Pass.advance(to:)`, un `max`), comme `SendStatusData`
  (`dfrgntfs.cpp:981-985`) borne le pourcentage envoyé sur
  `uLastPercentDone`. La barre plafonne au lieu de retomber à zéro à chaque
  tour.
- **B#17** : « déjà en place » compte les fichiers contigus au départ, que
  l'outil a le droit de déplacer (`canTouch`), et qu'aucune phase n'a
  déplacés. Ni le fichier d'échange ni les métafichiers, ni ce que la
  consolidation ou le tassement emmènent.
- **B#21** : l'arrêt au premier fichier sans trou (« Sigh. No free space
  chunk ») reste réservé à l'ordre de XP ; un autre ordre passe au suivant
  et retient le plus petit échec comme `MinimumLength`.
- **`xp-defrag-tri`** : `FileEntrySizeCompareRoutine`
  (`dfrgntfs.cpp:395-432`) départage par `FileRecordNumber`. `Order.precedes`
  reçoit l'enregistrement de chaque fichier (`DefragVolume.mftRecord(of:)`)
  et départage par lui, pour `.sizeThenRecord` comme pour `.mftRecord`.
- **B#25** : sans outil demandé, `build(generated:)` prend celui de l'année
  **du scénario** (`timeline.start`), comme l'écran de choix, et le passe par
  `prepared`. `assembleDefrag` ne choisit plus rien. L'année d'un disque
  nommé reste celle de sa voix.
- **B#35** : `TipJar.sheetClosed()`, appelé à la fermeture de la feuille,
  remet l'état au repos sauf pendant un achat. Le fichier diverge donc de la
  copie de référence commune aux apps (dépôt `donations`) : à y reporter.
- **B#51** : `wav-md5.py` rend chaque scénario dans un environnement propre
  (`PATH`, `HOME`, `TMPDIR`, `USER` et `SCENARIO`), efface le WAV d'avant,
  imprime l'erreur d'un rendu raté et sort en erreur s'il y en a un.
- **Décision 3** : `run.sh` ne lance plus l'outil de XP sur les douze FAT
  (400 bilans) ; `compare.py` dit « absent » d'un bilan que la seconde étape
  ne fait plus au lieu de planter ; `readme-tables.py` ne lisait aucune de ces
  passes. Le test de B#30 ne porte plus que sur UltraDefrag et compare les
  extents de chaque répertoire, avant et après.
- **B#5 et B#12**, dans leur propre étape (`47a` sans, `47` avec) :
  `sizeMB: 500107` pour `dev-2012` et `gamer-2012`, et la doc de
  `DiskSpec(reference:)` dit des mégaoctets décimaux.

Tests neufs (`WindowsXPLetterTests`) : la validation qui suit la MFT déplacée,
l'avancement qui ne recule pas (sur un volume tiré d'un générateur
déterministe : le premier essai, trop simple, passait aussi sur l'ancien
code), « déjà en place », l'ordre qui ne s'arrête pas, le départage par
enregistrement. Les cinq échouent sur le code d'avant, vérifié en y
remettant `WindowsXPStrategy.swift` et `DefragVolume.swift` de `2a15ed2`.
Trois comptes « déjà en place » des tests existants suivent B#17 : 1 → 0,
2 → 0, 12 000 → 450.

### Ce qui valide

Mesures sous `.build/measure-xp` (dépôt principal), prédiction écrite avant
dans `prediction-47.md`.

| prédiction, écrite avant | mesuré |
|---|---|
| 47a : 400 bilans, 12 absents | 400, 12 absents |
| 47a : les 24 passes XP sur NTFS changent, par « déjà en place » partout | **24**, et **seulement** par « déjà en place » et la durée : requêtes, déplacements, évacuations, morceaux et trous identiques partout |
| 47a : durées XP qui bougent sur les 7 volumes à MFT morcelée (B#15), et un peu ailleurs par le tri | B#15 : **4** volumes sur 7 (voir plus bas) ; le tri : 12 bilans, de −2,8 à +0,6 s |
| 47a : 376 identiques | 376 |
| 47a : 58 md5 identiques | 58 |
| 47 contre 47a : « 34 bilans » dev-2012 et gamer-2012 | **36** : la liste de la prédiction était juste (2 volumes, 2 démarrages, 2 installations, 26 passes, 4 pleines), son addition fausse |
| 47 : 54 md5 identiques, les démarrages et installations 2012 changent | 54 ; `boot-` et `install-` de dev-2012 et gamer-2012 |
| contre base : 346 identiques | **344** (la même erreur d'addition) ; 56 changent, 12 absents |
| Calibration en Release : les mêmes échecs | les mêmes 4 tests, les mêmes 8 constats (dont 3 connus), **aux mêmes chiffres** sur `2a15ed2` et sur 47 |

**B#15 sur 4 volumes, pas 7.** Une sonde jetable (Release) montre que
`MFTDefrag` recolle bien la queue sur les sept, mais qu'une validation n'en
change que si un fichier déplacé a son enregistrement dans la queue. Or le
premier extent de la MFT tient 4 enregistrements par cluster : 7 024 sur
famille-2003 pour 5 320 enregistrements au plus, 21 512 sur dev-2007 pour
20 981, 16 704 sur famille-2007 pour 13 368. Sur dev-2003 (13 612 pour
13 941), secretaire-2007, dev-2012 et secretaire-2012, la queue porte des
fichiers : −0,9 s, −4,0 s, +0,4 s et −1,9 s. Un binaire sans le départage
(`notri`) sépare les deux effets : sans lui, les seize passes des huit autres
volumes sont identiques à base hors « déjà en place ».

**« Déjà en place »** tombe partout, le tassement emmenant la moitié des
fichiers contigus ou plus : dev-2003 12 857 → 5 662, dev-2007 18 582 →
8 519, famille-2012 15 564 → 6 100.

**La capacité 2012.** 116 440 429 → 122 096 435 clusters (+4,86 %).
`dev-2012` passe de 90 à 85 % plein ; sa passe XP de 1 h 10 à 51 min 26, et
les tris de JkDefrag de +12 à +93 %. `gamer-2012` passe de 91 à **92 %** :
il amasse 160 Go par an et range à 95 % (`hoarding.tidiesUpAt`), si bien que
son remplissage final dépend de l'endroit où tombe la fin du cycle ; sa passe
XP passe de 2 h 12 à 2 h 24. Les démarrages perdent 1,4 et 1,7 s ; les
installations, moins d'une seconde.

`swift test` : 157 + 318 tests, verts. `xcb.sh build` passe ; aucune clé
neuve. README : les tables XP, du recollage économe et des démarrages suivent
les mesures de 47 ; « 400 bilans » ; le paragraphe de `DRIVE` dit que l'outil
par défaut suit l'année du scénario. `readme-tables.py 47 --check` : un seul
écart, la durée de génération de `dev-2007` (1,7 s au README), qu'une
machine chargée à 150 ne permet pas de mesurer. Elle était déjà hors
tolérance à base (2,5 s), et le volume n'a pas bougé (empreinte identique).
Les durées de génération ont été restaurées comme d'habitude.

### Laissé ouvert

- **La durée de génération de `dev-2012`** a pu changer avec sa capacité ; la
  machine chargée ne permet pas de le dire. Le README garde 2,5 s, dans la
  tolérance de `--check`.
- **Les tests qui parlent de l'ancien XP** : `DefragPlannerTests` dit encore
  « XP suit les numéros d'enregistrement » (B#22, chantier 50).
- **La table du rangement intelligent** (douze non vérifiées) n'est pas
  refaite, comme au chantier 45.
- **`TipJar`** : reporter `sheetClosed()` dans la copie de référence
  (`donations`) et dans les autres apps. Rien n'a été vu dans le simulateur.
- **B#15 aggravé plus tard** : avec la condition de XP (chantier 50,
  `> 1` extent, avant et après), la queue repartira plus souvent. La
  correction d'aujourd'hui l'y attend.

## Chantier 48 — XP à la lettre : la disposition NTFS au formatage

**Fait** · branche `xp`, partie de `831fcd5` (chantier 47) · plan : `LEDGER-XP.md`

### Le problème

Le modèle posait un NTFS de XP comme `mkntfs` : `$LogFile` derrière le
miroir au milieu du volume, `$Bitmap` derrière la zone MFT, la MFT au
huitième d'un volume de moins de 24 Gio, 32 enregistrements. Le code de
`FORMAT` de XP SP1 dit autre chose (`WINDOWS_CHECK.md`, `ntfs-format-02`,
`03`, `04`, `07`, `12`, `ntfs-alloc-19`, la lacune « métafichiers ») : les
deux trajets d'une validation étaient à l'envers. Le montage allait lire le
dernier secteur (`ntfs-format-17`), et l'analyse de tout défragmenteur
lisait les 64 Mio du journal, le miroir et `$Boot` une seconde fois (B#24).
Les commentaires de `VolumeLayout` et de `DiskGenerator` (B#10) décrivaient
un XP qui n'a pas existé.

### Les décisions

Chaque référence a été relue dans `base/fs/utils/untfs`, `base/fs/ntfs` et
`base/fs/utils/dfrg`.

- **B#24, pour tous les NTFS et tous les outils** (étape `48a`) : l'analyse
  lit la bitmap de la MFT, la bitmap du volume, puis les extents de `$MFT`,
  dans l'ordre de `dfrgntfs` (`GetMftBitmap`, `dfrgntfs.cpp:4588-4613`,
  appelé ligne 1780 ; `GetVolumeBitmap`, `freespace.cpp:1345`, ligne 1832 ;
  `ScanNtfs`, `dfrgntfs.cpp:5110-5160`, ligne 2500). `scanAccesses` ne lit
  plus rien sur NTFS : la géométrie vient de `FSCTL_GET_NTFS_VOLUME_DATA`
  (`ntfssubs.cpp:2296`), servie de mémoire. L'analyse est commune aux
  stratégies, et aucun outil ne lit le journal : la correction ne se limite
  pas à `Formatting.xp`, et c'est la seule.
- **La disposition de `FORMAT`, `Formatting.xp` seulement**
  (`NTFSAllocator.xpLayout`, `LOGFILE_PLACEMENT_V1`, `format.cxx:62`) :
  `$MFT` à 3 Gio, à 1 Gio de 2 à 6 Gio, au tiers en dessous
  (`format.cxx:585-593`), 16 enregistrements (`FIRST_USER_FILE_NUMBER`,
  `format.cxx:552, 685`, `ntfs.h:406`) ; sa bitmap, un cluster, juste devant
  (`mftfile.cxx:289-293`) ; `$LogFile` qui finit à `MftLcn` moins les 8 Ko
  réservés (`format.cxx:617-618`, `logfile.cxx:223-233`), un cluster libre
  entre les deux à 4 Ko ; sa taille selon la rampe (`logfile.cxx:48-56,
  869-888`, 64 Mio sur toute la galerie) ; `$MFTMirr` au milieu
  (`mftref.cxx:177-182`), puis `$AttrDef` (2 560 octets), `$Bitmap`,
  `$UpCase` (128 Ko) et l'allocation de l'index racine (4 Ko), que
  `_NextAlloc` pose à la suite (`format.cxx:329-341, 904, 991, 1131, 1175` ;
  `ntfsbit.cxx:452-460, 585`). **L'ordre du plan était faux** : la racine
  vient en dernier, quand l'index est sauvé, pas avant `$Bitmap`.
- **La racine reprend son tampon d'index** : l'allocateur le prend au
  formatage (`formattedRootIndex`, nouvelle exigence d'`Allocator`, `nil`
  hors XP), le simulateur le donne à la racine quand elle naît et le
  rapporte comme croissance de répertoire, pour que le journal d'une
  installation et le rejeu d'une vie retrouvent la bitmap au cluster près.
  La racine grandit ensuite derrière lui.
- **Le montage de XP** (`NtfsMountVolume`) : secteur 0 (la copie n'est lue
  que si celui-ci est illisible, `fsctrl.c:5015-5046`), MFT et miroir
  (`fsctrl.c:1561-1587`), zone de redémarrage du journal (1718-1801),
  `$UpCase` entière (2384-2412 ; `$AttrDef` n'est plus lue, 2330-2370 en
  commentaire), `$Bitmap` entière (`NtfsInitializeClusterAllocation`,
  `fsctrl.c:2475`, `bitmpsup.c:655, 2006-2121`). Ces deux-là, par vues de
  64 Ko : lue d'un trait, la bitmap d'un 40 Go faisait une requête de 2 400
  secteurs, ce que `InstallSessionTests` a refusé (commit à part). NT,
  Vista et 7 gardent l'ancien montage, dernier secteur compris.
- **Le reste de l'allocateur ne bouge pas** (chantier 49) : la zone MFT
  reste 12,5 % comptés depuis `$MFT`, les deux plages de données aussi. La
  plage de devant va de `$Boot` à `$MFT` et contient donc le journal et la
  bitmap de la MFT, occupés dans la bitmap comme n'importe quel fichier ; le
  cluster libre entre eux est de l'espace ordinaire, comme chez XP. Deux
  bords que seul un disque personnalisé atteint : entre 6 et 8 Gio, la zone
  recouvre le milieu (XP la borne au premier cluster occupé, le modèle
  non) ; à 2 ou 6 Gio tout juste, le milieu tombe sur la MFT, et la suite
  saute derrière elle comme l'allocateur de `FORMAT` cherche vers l'avant.
- **B#10** : `VolumeLayout` (l'en-tête, `ntfsFormatting`, la validation,
  `bitmapLBA`, le montage) et `DiskGenerator.formatting(for:)` disent la
  disposition de XP ; celle de Vista et 7 est dite « le modèle d'avant ».

Tests neufs : les paliers de la MFT, la disposition de XP cluster par
cluster, la rampe du journal, le montage de XP (trois zones, pas de dernier
secteur, bitmap et `$UpCase` entières, aucune requête de plus de 128
secteurs), l'analyse qui ne lit ni journal, ni miroir, ni `$Boot`, la
racine qui reprend le tampon de `FORMAT`. Refaits en citant la source :
la MFT au huitième (maintenant Vista seulement), `$Bitmap` derrière la zone
(Vista), le montage à quatre ou cinq zones (Vista).

### Ce qui valide

Mesures sous `.build/measure-xp` (dépôt principal) ; `bin-47` reconstruit
depuis `831fcd5` : identique octet pour octet. Prédiction écrite avant dans
`prediction-48.md`.

| prédiction, écrite avant | mesuré |
|---|---|
| 48a : les 180 passes NTFS changent, 220 identiques | **180 / 220** |
| 48a : l'analyse perd 64 Mio partout, 1 à 2 s | 66,5 à 67,4 Mo (64 Mio = 67,1 Mo), 0,4 à 1,8 s |
| 48a : plans identiques | **faux** : 105 plans changent (voir plus bas) |
| 48a : 58 md5 identiques | 58 |
| 48 contre 48a : 73 changent, 327 identiques (FAT, Vista, 7 en entier) | **73 / 327**, tous sur les quatre volumes de 2003 |
| volumes : remplissage au point près, famille-2003 bouge le plus | remplissage inchangé ; famille-2003 23,5 → 24,4 %, secretaire 31,7 → 31,8 %, dev 2,1 → 2,0 %, gamer 0,1 → 0,0 % ; **MFT de dev-2003 : 57 → 6 extents** |
| démarrages : moins d'une seconde | 0,0 à +0,3 s |
| installations et journée : ±5 %, plutôt en baisse | installations **à ±0,1 s**, journée +0,5 s |
| passes : plus longues sur les 40 Go, nettement sur gamer-2003 | gamer-2003 **+34 %** (XP), +16 % (UltraDefrag) ; sur les 40 Go, **pas plus longues** : médianes −4,6 % (dev), −3,1 % (famille), +1,2 % (secretaire) |
| 49 md5 identiques ; changent boot, install ×4 et la journée | 49, exactement ceux-là |
| contre 47 : 207 identiques | **207** ; 193 changent |

**Les plans de 48a.** L'analyse ne décide rien, mais elle avance
l'horloge : `NTFSCheckpoints` libère les clusters retenus sur une grille de
5 s de temps planifié (`plannedSeconds`). Deux secondes d'analyse en moins
décalent la grille, et le plan d'un outil qui la suit diverge. Touchés :
XP (16 sur 24), JkDefrag et ses modes (82 sur 84), Windows 95 sur NTFS (7
sur 12) ; intacts, ceux qui ont leur comptabilité : UltraDefrag, tassage à
la frontière, recollage économe, JkDefrag en remplissage forcé. L'écart
peut être grand : `gamer-2012` XP passe de 2 h 24 à 2 h 54,
`secretaire-2007` au tri par nom perd 42 min. Preuve par deux binaires
jetables, 47 et 48a avec `NTFSCheckpoints.interval` à 10¹² (plus aucun
point de contrôle) : sur les six passes qui bougeaient le plus, **plans
identiques**. C'est la rétention de 5 s que le chantier 50 retire.

**Les passes des 40 Go.** Le seek moyen s'allonge comme prévu (dev-2003 XP
22 546 → 24 777 cylindres, famille-2003 7 481 → 9 188), mais la durée suit
surtout la quantité déplacée, qui change avec le volume : dev-2003 XP
déplace 13 455 → 12 789 Mo (−5 %) pour −7 % de durée, secretaire-2003
6 456 → 6 376 Mo pour −0,6 %. Le coût par mégaoctet bouge à peine :
l'aller vers la bitmap est une écriture différée, que le cache du disque
pose par salves dans l'ordre de l'ascenseur. C'est une explication, pas
une mesure : l'effet n'a pas été isolé. gamer-2003, lui, a ses données dans
les 13 premiers Gio et sa bitmap à 37 Gio (12,3 Gio avant) : +34 %.

**La MFT de dev-2003** : 57 extents, puis 6. Les trois cents clusters de
`$Bitmap` posés à la fin de la zone MFT étaient un mur : la MFT qui débordait
de sa zone repartait par paquets de huit clusters ailleurs. Le mur parti,
elle continue d'un tenant derrière la zone. Son analyse passe de 3,5 à
1,7 s, et XP n'y laisse plus un seul morceau en trop (119 à 47).

**Installations** : leur durée est celle de la source (CD) ; le disque
suit. Les seeks baissent de 29 à 42 par installation.

`swift test` : 160 + 320 tests, verts (le premier passage a trouvé la
requête de 2 400 secteurs du montage ; les bilans de 48 sont ceux du binaire
corrigé). Calibration en Release, lancée sur
`831fcd5` et sur 48 : **3 tests en échec et 8 constats dont 3 connus, aux
deux étapes** (le « 4 tests » de `LEDGER-XP.md` compte autrement ; la
structure est la même). Chiffres : famille-2003, remplissage 88,71 % aux
deux, fragmentés 23,5 → **24,4 %** ; le rapport FAT32/NTFS 16,4 contre
23,5 → 16,4 contre **24,4 %** ; gamer-2003 garde son fichier en 4 morceaux ;
les autres aux mêmes chiffres. Rien n'est recalé (chantier 49).
`GalleryAllocationAudit` en Release (21 min) : **20 volumes propres, 4 en
échec** — `dev-2007`, `secretaire-2007`, `dev-2012`, `secretaire-2012`, la
passe de XP seule (848, 595, 905 et 772 clusters « posés sur un extent
système », aucune écriture sur une donnée vivante, aucun cluster en double).
**Déjà là à 47** : l'audit relancé sur `831fcd5` donne les mêmes chiffres.
Ce sont les quatre volumes où `MFTDefrag` déplace une queue de MFT qui porte
des enregistrements (chantier 47), et l'audit jugeait l'arrivée sur les
extents système **de départ** : un fichier rangé là où était l'ancienne
queue, libérée, comptait comme posé sur le système. L'audit prend désormais
la MFT d'arrivée (`plan.partition.mftExtents`) ; relancé sur les quatre, il
est propre. Les vingt autres l'étaient sous l'ancienne règle, plus sévère.

README : la disposition de XP (paragraphe de l'allocateur, carte, tables
de l'installation et de la validation), le montage et l'analyse ; tables et
prose de `readme-tables.py 48 --write`, les durées de génération rendues
(1,7 s ; 2,5 et 2,2 s ; 1,8 s pour `famille-2003`, dont le volume a changé
mais que la machine chargée ne permet pas de mesurer). `--check`, les
volumes remesurés machine au repos : un seul écart, `dev-2007` (1,7 s au
README, 2,3 s mesurés), comme au chantier 47 — son volume n'a pas bougé. « Ce qui ne l'est
pas » ne citait rien de ce que ce chantier source.

**Écoute proposée, non faite.** `dev-2007` (celui du plan) est formaté
Vista : il ne change qu'à l'analyse. Les volumes à écouter sont ceux de
2003 : `SCENARIO=gamer-2003 STRATEGY=windowsXP`, où chaque validation va
chercher la bitmap à 37 Gio (seek moyen 3 539 → 7 774 cylindres, 10 → 14 s),
et `boot:famille-2003`, dont le montage ne va plus au fond du disque mais
lit la racine, `$UpCase` et la bitmap au milieu (33 seeks de plus,
+0,3 s). Rien n'a été écouté.

### Laissé ouvert

- **Les répertoires à l'analyse** : `dfrgntfs` ne semble lire que la MFT
  (ses seules lectures directes sont celles de B#24 et des listes
  d'attributs, `ntfssubs.cpp:1472`) ; le modèle lit encore chaque
  répertoire sur NTFS. Non tranché ici.
- **`$Secure`, `$Extend` et les fichiers que le pilote crée au premier
  montage** ne sont pas posés : `FORMAT` de XP ne les crée pas
  (`format.cxx`), et le code du pilote qui le fait n'a pas été suivi.
- **Les entrées de métafichiers dans l'index racine** (onze noms) ne sont
  pas comptées : la racine naît vide dans son tampon de 4 Ko.
- **La zone MFT de XP** (bornée au premier cluster occupé, recalculée au
  montage) et tout l'allocateur : chantier 49. **La rétention de 5 s**, qui
  rend les plans sensibles à l'horloge : chantier 50.
- **Le « 4 tests » de Calibration** dans `LEDGER-XP.md` : à recompter au
  chantier 49, qui recale ces cibles.

## Chantier 49 — XP à la lettre : l'allocateur NTFS de XP

**Fait** · branche `xp`, partie de `452c0ff` (chantier 48) · plan : `LEDGER-XP.md`

### Le problème

L'allocateur NTFS du modèle n'avait aucune source pour ses décisions : une
préférence pour l'espace jamais servi (un trou n'était repris qu'à deux fois
le besoin au plus), quatre bornes de recherche qui réglaient la
fragmentation (de 4,6 à 21,2 % sur `famille-2003` selon l'horizon), un
curseur pour les fichiers neufs, un curseur système, un prolongement « près
du fichier » pris au pilote de Linux, des paquets d'écriture de 64 Ko
attribués au lazy writer, une zone MFT qui ne faisait que rétrécir et une
MFT qui grandissait par huit clusters hors zone. `WINDOWS_CHECK.md` les
contredit tous contre le code de XP SP1 (`ntfs-alloc-01` à `05`, `08` à
`10`, `12`, `21`, `ntfs-format-10`, `11`, `io-cache-06`) ; l'audit y ajoute
B#6, B#7 et B#8, et B#37 (le README à 24 % contre un test à 16 %). La suite
`Calibration` était rouge en Release : trois tests, huit constats dont trois
connus.

### Les décisions

Chaque référence a été relue dans `base/fs/ntfs` (et `base/crts/crtw32`
pour l'écriture de 4 Ko). La décision 1 de `LEDGER-XP.md` s'applique :
`Formatting.xp` suit XP à la lettre ; NT 4, Vista et 7 gardent le modèle
d'avant, dit comme tel. B#8 vaut pour tous.

- **49a — B#8** : les plages de données excluent la zone **courante**, et non
  tout ce qui précède `$MFT` (`bitmpsup.c:3872-3905`). **La galerie est
  touchée**, contrairement à ce que disait l'audit : sur les quatre volumes de
  Vista et 7 dont l'histoire contient des défragmentations (`dev-2007`,
  `secretaire-2007`, `dev-2012`, `secretaire-2012`), la passe de l'histoire
  tasse des fichiers dans la zone, la MFT ne peut plus y grandir, et la
  tranche de 200 Mo est renouvelée (sonde : zone finale à 56 M clusters sur
  `secretaire-2007`, deux renouvellements sur `dev-2012`).
- **49b — l'allocateur de `NtfsAllocateClusters`**
  (`NTFSAllocator+XP.swift`) :
  - un **cache des runs libres** (`NTFSFreeRunCache`, `NTFS_CACHED_RUNS`) :
    9 000 runs au plus (`bitmpsup.c:9143`), et plein, un run neuf n'entre
    qu'en chassant un run plus court d'une longueur de 1 à 32 tenue à plus de
    100 exemplaires, sinon il est ignoré (`10562-10636`) ; rebâti au montage
    des **64 plus longs runs de chaque page** de 32 768 clusters (`2143`),
    nourri ensuite des 16 plus longs de chaque page lue (`3662, 3789, 4125,
    4926`) et des runs libérés au point de contrôle ; fondu à chaque ajout
    avec ce qu'il touche (`NtfsInsertCachedLcn`), coupé à chaque retrait ;
  - pour chaque trou : le run qui commence derrière le dernier cluster du
    fichier (`1029-1059`) ; sinon le **plus petit run au moins aussi long que
    la demande**, à longueur égale le plus proche du fichier, et pour un
    fichier neuf le plus petit LCN (« maximum left-packing »,
    `13133-13540`) ; d'une longueur supérieure, son plus petit LCN (le
    commentaire « ENHANCEMENT ») ; faute de run assez long, **le plus long**,
    et le reste au trou suivant (`AllowShorter`, `9652-9661`), 128 runs par
    appel (`ntfsdata.h:393`) ;
  - un run qui chevauche la zone en fait retirer la zone (`1085-1100`) ; le
    cache vide, la **bitmap page par page** depuis `LastBitmapHint` — le
    premier trou venu, la zone en dernier —, puis la zone qui cède
    (`NtfsFindFreeBitmapRun`, `NtfsScanBitmapRange`, `3450-4150`) ; la
    lecture anticipée derrière une allocation en plusieurs runs
    (`4851-4975`) ; la règle du fichier d'échange (`1110-1133`) ;
  - pas de curseur, pas de préférence pour le vierge, pas de bornes : B#6 et
    B#7 disparaissent avec le mécanisme qu'ils corrigeaient ;
  - **les clusters libérés sont masqués jusqu'au point de contrôle**, puis
    versés au cache par ordre de LCN, jusqu'à ce qu'il soit plein
    (`logsup.c:4500-4533`) ; un déplacement de défragmenteur vers eux les rend
    tous (`DELETE_PENDING`, `deviosup.c:10360-10390`) ; faute de place hors
    d'eux, l'allocateur force le point de contrôle (`STATUS_LOG_FILE_FULL`).
- **La traduction du temps**, faute d'horloge plus fine que l'événement :
  le simulateur annonce un **montage au premier événement de chaque
  journée** (la machine éteinte la nuit : le cache rebâti, la zone
  recalculée) et **un point de contrôle entre deux événements** — ce qu'un
  événement libère, le suivant peut le prendre, lui seul ne le peut pas
  (`Allocator.mount`, `Allocator.checkpoint`). XP en fait un toutes les cinq
  secondes : une installation de quarante fichiers par seconde en ferait bien
  moins que le modèle. C'est la seule traduction du chantier qui ne vienne
  pas du code, et le README la range dans « Ce qui ne l'est pas ».
- **49c — la surallocation de `NtfsCommonWrite`** : un fichier écrit sans
  taille connue est étendu à chaque écriture du programme qui dépasse son
  allocation — pas par le lazy writer, exclu par `write.c:1914` —, par
  écritures de 4 Ko (`_INTERNAL_BUFSIZ`, `crtw32/h/stdio.h:265`, la même
  hypothèse que pour FAT) : la première exacte, puis `ClusterCount <<
  WriteExtendCount` arrondi à 2ⁿ clusters, le compteur plafonné à 4 par
  handle (`allocsup.c:1321-1387`), borné à un millième de l'espace libre plus
  la demande (`1392-1403`), pris tant que le cache répond (`bitmpsup.c:1165-
  1178`), **rendu à la fermeture** (`SCB_STATE_TRUNCATE_ON_CLOSE`,
  `write.c:2163`). Un appel de `stream` est un handle ; l'entrelacement, qui
  ne sert à aucun volume de la galerie, ouvrirait un handle par paquet. Les
  extensions de régime établi que le run suivant sert en entier sont prises
  d'un coup (`fastExtensions`) : empreintes identiques avec et sans, et
  `famille-2003` se génère en 1,7 s au lieu de 13,9. Vista et 7 gardent les
  paquets de 64 Ko, que la doc de `NTFSProfile` n'attribue plus au lazy
  writer.
- **49d — la zone et la croissance de la MFT** :
  `NtfsInitializeMftZone` au montage, quand une zone réduite regonfle et
  quand la MFT ne peut plus grandir sur place — un huitième du volume moins
  la MFT, au moins un seizième, sur le run qui suit la MFT, sinon sur le
  plus petit run du cache qui atteint cette taille, aligné sur 32
  (`8491-8660`) ; `NtfsReduceMftZone`, la moitié des clusters libres de la
  zone comptés depuis son début, rien sous 64, `REDUCED_MFT` sous un
  seizième libre (`8674-8872`), regonflée au-dessus (`1851-1868`) ; `$MFT`
  par 16 enregistrements (`ntfs.h:415`, `6405-6422`), le run qui la suit ou
  une zone neuve (`1263-1287`). Le disque généré rapporte la zone qu'un
  montage recalculerait : celle que voit un défragmenteur. Le registre
  `NtfsMftZoneReservation` n'est gardé que par `mftZoneShare`, dont aucun
  profil ne se sert (le multiplicateur en est déduit).
- **49e — les enregistrements repris par le bas** (`ntfs-alloc-12`) :
  `NtfsAllocateRecord` rejoué, le plus petit libre à partir du seizième,
  l'indice ramené vers le bas à chaque libération (`5339, 5777,
  7819-7822`), la racine en 5 ; `FileRecord.mftRecord` et
  `DirectoryRecord.mftRecord` le portent, `MFTNumbering` et `MachineWriter`
  s'en servent sous XP. Le déclencheur de `NtfsCreateMftHole`
  (enregistrements libres au-delà d'un huitième de l'espace libre,
  `mftsup.c:1610-1640`) est compté : **jamais rempli** sur la galerie ; le
  perçage n'est pas modélisé.

Tests neufs (`NTFSXPAllocationTests`, `NTFSFreeRunCacheTests`) : B#8, la
fusion et le découpage du cache, la recherche par longueur, le cache plein,
le best fit à gauche, pas de préférence pour le vierge, le découpage du plus
grand au plus petit, l'extension par le cache, la surallocation (1, 3, 4, 8,
16, la fin rendue), la MFT par 16 enregistrements et sa zone neuve, la zone
réduite puis recalculée au montage, les enregistrements repris par le bas,
le déplacement vers des clusters retenus. `ProfilingAllocator` relaie les
nouveaux points d'entrée, et le rejeu des tests d'allocateur fait un point de
contrôle par événement, comme le simulateur.

### Ce qui valide

Mesures sous `.build/measure-xp` (dépôt principal) ; `bin-48` reconstruit
depuis `452c0ff` : identique, binaire et ressources. Prédictions écrites
avant chaque mesure dans `prediction-49.md` (sauf les chiffres de volume de
49c, qu'une sonde d'équivalence avait imprimés avant : dit dans le fichier).

| étape | prédit | mesuré |
|---|---|---|
| 49a | 400 identiques, 58 md5 | **faux** : 68 changent (4 volumes Vista/7 à défragmentations d'histoire), 54 md5 (leurs démarrages) |
| 49b | 73 changent (les 2003), 49 md5 | **73 / 327**, **49 md5** ; fragmentation en hausse prédite, **en baisse** sur famille (24,4 → 4,3 %) et secretaire (31,8 → 25,0 %) |
| 49c | 73 changent, 49 md5 (volumes vus avant) | 68 : les installations n'écrivent que des tailles connues ; 54 md5 ; passes de secretaire plus longues : conforme |
| 49d | 73 changent, 49 md5 ; MFT en moins d'extents ; famille en hausse | 70 (trois passes de gamer intactes) ; 49 md5 ; MFT famille 45 → 2, dev 6 → 3 : conforme ; famille 16,2 → 16,2 % : **faux** |
| 49e | volumes identiques, 69 changent, 49 md5 | volumes identiques ; 65 (la passe de Windows 95, qui adresse par position) ; 49 md5 |
| 49 | identique à 49e | **400 / 400**, md5 identiques |
| contre 48 | — | 259 identiques, 141 changent ; 45 md5 identiques |

**Les volumes NTFS, 48 → 49** (fragmentés parmi les fragmentables, MFT,
trous libres, pire fichier) :

| volume | 48 | 49 |
|---|---|---|
| `dev-2003` | 2,0 %, 6 extents, 2 048, 465 | 7,6 %, 3 extents, 1 607, 169 |
| `famille-2003` | 24,4 %, 38 extents, 3 570, 3 888 | 16,2 %, 2 extents, 3 414, 2 448 |
| `gamer-2003` | 0,0 %, 1 extent, 10, 4 | 0,2 %, 1 extent, 6, 7 |
| `secretaire-2003` | 31,8 %, 1 extent, 652, 865 | 64,0 %, 1 extent, 2 315, 1 267 |
| `dev-2007` | 9,1 %, 28 extents, 2 418, 2 225 | 9,2 %, 25 extents, 1 753, 2 616 |
| `secretaire-2007` | 5,0 %, 29 extents, 743, 844 | 3,5 %, 3 extents, 756, 1 216 |
| `dev-2012` | 5,8 %, 15 extents, 5 391, 8 384 | 7,2 %, 3 extents, 4 425, 2 462 |
| `secretaire-2012` | 5,0 %, 9 extents, 970, 2 036 | 1,7 %, 6 extents, 1 527, 1 562 |
| les quatre autres | inchangés | inchangés |

**Ce qui fait bouger les volumes de XP.** Le best fit sans préférence pour
le vierge reprend les trous dès le point de contrôle suivant, et le
découpage prend les grands morceaux d'abord : `famille-2003` tombe de 24,4 à
4,3 % (49b). La surallocation le fait remonter à 16,2 % (49c) : la première
écriture de 4 Ko d'un fichier va dans le plus petit trou qui lui suffit, un
cluster s'il le faut, et la deuxième, faute de place derrière, dans le trou
de trois clusters le plus proche. C'est ce qui porte `secretaire-2003`, dont
les documents Word sont réenregistrés sans taille connue, de 25,0 à 64,0 %.
Les sauvegardes de `gamer-2003` y passent aussi (six fichiers, sept morceaux
au plus) ; son installation, en tailles connues, reste d'un seul tenant. La
MFT, qui ouvre une zone neuve plutôt que de s'éparpiller par huit clusters,
tombe à 2 et 3 extents.

**Les passes et le son.** Démarrages et installations des 2003 à ±0,3 s ; la
journée `famille-2003:400` 94,2 → 97,6 s. Les passes suivent les volumes :
`secretaire-2003` XP 929 → 1 036 s, JkDefrag 980 → 1 595 s, UltraDefrag
629 → 1 374 s ; `famille-2003` XP 520 → 372 s, JkDefrag 982 → 1 190 s ;
`dev-2003` XP **1 323 → 2 109 s** : à 49d, sa phase « Moving files forward »
passe de 604 à 1 796 s et de 12 à 40 Go lus et écrits. La zone qu'un montage
recalcule suit le dernier extent de la MFT, qui est depuis 49d dans une zone
neuve vers 94 % du volume (sonde : 9 232 288 à 9 498 816) ; c'est
l'explication probable, **non isolée**. Rien n'a été écouté.

**Durées de génération.** Les volumes de XP coûtent plus : `dev-2003` 1,3 →
3,2 s, `secretaire-2003` 0,2 → 0,5 s, `gamer-2003` 2 → 5 ms ; `famille-2003`
1,8 → 1,6 s grâce au raccourci de régime établi (13,9 s sans). Vista et 7 à
±12 % (`dev-2012` 2,6 → 2,9 s, son volume a changé à 49a). Pas d'explosion ; `dev-2003` est désormais le plus lent des 2003.

**Calibration en Release** (`calibration-49e.log` avant recalage,
`calibration-49.log` après) :

| cible | 48 | 49, avant recalage | après recalage, et pourquoi |
|---|---|---|---|
| famille-2003 remplissage > 90 % | 88,7 %, rouge | 88,7 %, rouge | **known issue** : la fin du cycle de rangement du profil (`tidiesUpAt` 0,99), les mêmes 161 écritures refusées ; pas l'allocateur, hors du chantier |
| famille-2003 40 à 60 % (known issue) | 24,4 % | 16,2 % | **retirée** : cible du cahier des charges ; XP à la lettre en produit 16 %, et rien dans son code ne dit 40 |
| famille-2003 de 4 à 16 % | 24,4 %, rouge | 16,2 %, rouge | **retirée** : une fourchette qui suivait la mesure, sans mécanisme |
| famille-2003 pire fichier > 500 | 3 888 | 2 448 | **gardée** : `AllowShorter`, 128 runs par appel, autant d'appels qu'il faut (`bitmpsup.c:9652-9661`, `allocsup.c:1475-1600`) |
| FAT32 > 2 × NTFS | 16,4 contre 24,4, rouge | 16,4 contre 16,2, rouge | **retirée** : la première écriture de 4 Ko de XP va au plus petit trou ; aucun mécanisme ne fixe le rapport ; le remplissage NTFS en known issue |
| gamer-2003 < 5 % | 0,0 % | 0,2 % | gardée |
| gamer-2003 pire fichier = 1 | 4, rouge | 7, rouge | **remplacée** : « l'installation d'un seul tenant » (`NtfsLookupCachedLcnByLength` ne découpe que si aucun run ne suffit) ; les sauvegardes, par 4 Ko dans les trous, peuvent se découper |
| bornes de recherche | table sur famille-2003 | horizon non décisif sur XP | **refaite** : XP n'en dépend pas (vérifié), sur Vista l'horizon décide le plus |

Résultat : **15 tests, verts, 4 known issues** (les deux cibles FAT d'avant,
le remplissage de `famille-2003` deux fois). `swift test` : 174 + 320 tests,
verts. `GalleryAllocationAudit` en Release (19 min 25) : **propre sur les
vingt-quatre volumes**.

README : l'exception des bornes (hors XP), l'écriture sans taille connue, la
stratégie NTFS (cache, best fit, point de contrôle, zone de XP), `gamer-2003`,
les cibles (B#37 : `famille-2003` retirée, la phrase « NTFS place encore bien
à 95 % » supprimée), le coût, la zone des passes, « Ce qui ne l'est pas » (le
point de contrôle et le montage du modèle) ; la table des trois allocateurs
refaite (`AllocatorComparison` : NTFS 1,4 %, pire fichier 4, 78 trous) ;
`readme-tables.py 49 --write`, deux gabarits réécrits, la durée de génération
de `dev-2007` rendue (1,7 s) ; `--check` : un seul écart, celui-là.

### Laissé ouvert

- **Le temps du modèle** : un point de contrôle entre deux événements, un
  montage par journée. XP en fait un toutes les cinq secondes ; une
  installation de quarante fichiers par seconde en ferait bien moins. Une
  heure dans la journée (chantier 51 et suivants) permettrait de les placer.
- **L'écriture de 4 Ko** vaut pour tout programme qui ne connaît pas sa
  taille ; un programme qui écrit par 64 Ko étendrait par 16, puis jusqu'à
  256 clusters. Le catalogue ne le distingue pas.
- **`dev-2003` : la passe XP de 1 323 à 2 109 s**, par la phase de
  tassement à 49d ; l'explication par la zone recalculée derrière la MFT
  déplacée n'est pas isolée.
- **`NtfsCreateMftHole`** n'est pas modélisé (condition jamais remplie) ;
  la croissance de la bitmap de la MFT (`BITMAP_EXTEND_GRANULARITY`) non
  plus ; un index de répertoire n'a pas `AllowShorter`, ce qui ne change rien
  tant qu'il grandit d'un cluster.
- **La défragmentation de l'histoire** (`Simulator.defragment`) tasse dans
  la zone MFT ; c'est elle qui déclenche les renouvellements de Vista et 7
  (49a). Elle n'imite aucun outil daté ; à revoir avec le moteur (chantier 50).
- **Les défragmenteurs** gardent leur rétention de 5 s (`heldClusters`) :
  l'allocateur de XP applique déjà `DELETE_PENDING` à la défragmentation de
  l'histoire, pas aux stratégies (chantier 50).
- **Le remplissage de `famille-2003`** (88,7 % pour plus de 90 %) : une
  question de profil, en known issue.
- **Vista et 7** gardent un modèle sans source : bornes de recherche,
  préférence pour le vierge, paquets de 64 Ko, MFT par huit clusters.
- **Durées de génération** : `dev-2003` passe à 3,2 s en release ; sur un
  téléphone, à mesurer. La durée de `dev-2012` (2,9 s) est celle d'un volume
  changé à 49a ; celle de `dev-2007` reste hors de `--check`.
- **Écoute proposée, non faite** : `boot:secretaire-2003` et
  `SCENARIO=secretaire-2003 STRATEGY=ultraDefrag` (deux fois plus long), et
  `SCENARIO=dev-2003 STRATEGY=windowsXP`.
- Le reste de la prose du README (tables du rangement intelligent,
  argumentaires) : chantier 52.

### Reprise de 49c — l'écriture par programme

**Fait** le 25 septembre 2026 · branche `xp`, partie de `572e37c` · étapes
`49f` (`5a19c62`) et `49g` (`4702214`).

**Le problème.** 49c faisait écrire tout programme de taille inconnue par
`WriteFile` de 4 Ko, avec la surallocation de `NtfsCommonWrite`. C'est ce
qui portait `secretaire-2003` de 25,0 à 64,0 % : ses 5 317 documents Word,
réenregistrés, sortaient tous en morceaux (1, 3, 4, 8 clusters), et le
`.pst` (223 → 679 extents) et `index.dat` (361 → 835) suivaient. Les sondes
de l'enquête : écritures de 64 Ko, 31,3 % ; Word à taille connue, 6,3 % ;
sans point de contrôle entre événements, inchangé ; sans le raccourci
`fastExtensions`, identique. Or l'écriture de 4 Ko n'est sourcée pour aucun
programme : elle vient de la bibliothèque C, qu'on ne sait pas être celle de
Word.

**Les sources** (`.build/measure-xp/source-word-ole32.md`) :

- **Word — attesté** (KB Q89247, Word 97 ; KB 211632 rév. 8, Word 2000 à
  2010) : un enregistrement complet écrit `~wrdxxxx.tmp` dans le dossier du
  document, en fichier composé **direct**, supprime l'original et renomme ;
  l'enregistrement rapide est décoché par défaut depuis Word 97 SR-1/SR-2
  (KB Q192480, point 7). Pour 2002/2003, pas de KB : déduit.
- **Word → ole32 — déduit, forte présomption** : les `~dftxxxx.tmp` des KB
  portent le préfixe d'ole32 (`com/ole32/stg/h/filest.hxx:398`,
  `exp/filest32.cxx:342-378`) ; aucune trace publiée ne montre Word appeler
  `StgCreateDocfile`. Excel y passe (Wine, bogue 13822, commentaires 12 et
  17-21), mais le catalogue n'a pas d'Excel : les documents sont tous de
  Word.
- **ole32 de XP SP1 — attesté par le code** : fichier projeté
  (`USE_FILEMAPPING`, `h/filest.hxx:79-81` ; `filest32.cxx:285-296`), créé à
  512 octets (`MakeFileStub`, `1199-1222`), engagé par blocs de 16 Ko
  (`COMMIT_BLOCK`, `h/filest.hxx:394`, `filest32.cxx:1492-1580`), d'où
  `MmExtendSection` → `FsRtlSetFileSize` → `SetEndOfFile` au multiple de
  16 Ko (`mm/allocvm.c:1193-1231`, `mm/extsect.c:470-481`,
  `fsrtl/fastio.c:4199-4203`) ; ramené à la taille à la fermeture
  (`TurnOffMapping`, `filest32.cxx:1316-1415`).
- **NTFS — attesté** : `NtfsSetEndOfFileInfo` alloue exactement
  (`NtfsAddAllocation`, `AskForMore = FALSE`, `fileinfo.c:8017-8023`), sans
  la surallocation réservée au chemin d'écriture (`allocsup.c:1321-1403`,
  `write.c:2148`). La première extension convertit l'attribut résident de
  512 octets : le fichier étant projeté, `NtfsConvertToNonresident` garde la
  valeur résidente (`attrsup.c:4554-4560`) et `NtfsAllocateAttribute` lui
  donne **un cluster, comme à un fichier neuf** (`allocsup.c:1036-1056`),
  avant d'ajouter le reste du premier pas (`fileinfo.c:7893-7902, 8017`).
  Relu pour cette reprise.
- **`index.dat` — attesté par le code** (`inetcore/wininet/urlcache`) :
  `GlobalMapFileGrowSize` = `PAGE_SIZE × ALLOC_PAGES` = 16 Ko
  (`global.h:51`, `cachedef.h:40-41`) ; créé à 16 Ko par `SetFilePointer` +
  `SetEndOfFile` (`filemap.cxx:1186-1211`), étendu de 16 Ko quand la carte
  des blocs est pleine (`AllocateEntry`, `1455-1459` ; `GrowMapFile`,
  `671-750`), une entrée de plus de 16 Ko l'étendant d'un multiple ; sa
  taille reste un multiple de 16 Ko (`1172`), jamais ramenée.
- **`.pst` — hypothèse** : Office n'est pas dans le code de XP. [MS-PST],
  « Growing the PST File », veut qu'il grandisse par multiples de ce que
  couvre une page AMap (environ 248 Ko), sans dire par quel appel. Gardé à
  4 Ko avec surallocation, dit comme tel dans `ScenarioCompiler`.

**Les décisions.**

- `StreamedGrowth` (`WritePattern.swift`), porté par `FileSpec` et
  `FileRecord`, passé à `Allocator.stream`, `placeStreamed`,
  `growStreamed` : `.buffered` (4 Ko et surallocation, le défaut, une
  hypothèse), `.compoundFile` (Word), `.urlCacheIndex` (`index.dat`). Seul
  le NTFS de XP le lit ; FAT, NT 4, Vista et 7 l'ignorent.
- **49f** — `xpStreamMapped` : un cluster pour le stub, placé comme un
  fichier neuf, puis des extensions exactes jusqu'au multiple suivant de
  16 Ko, chacune derrière le fichier si le cache y a un run, sinon au plus
  petit run qui suffit ; la fermeture rend ce qui dépasse la taille.
- **49g** — `index.dat` : même chemin sans stub, et sa taille arrondie au
  multiple de 16 Ko sous XP (`Allocator.streamedFileBytes`) — l'histoire
  garde ses ajouts d'environ 24 Ko, `wininet` les range par pas.
- Tous les autres programmes, les tailles connues et les installations :
  inchangés.

Tests neufs (`NTFSXPAllocationTests`) : le fichier composé (1, 3, puis 4
clusters exacts, la fin rendue) et `index.dat` (16 Ko, multiples, rien hors
de XP).

**Ce qui valide.** Référence `bin-49` : reconstruit depuis `572e37c`,
identique octet pour octet (binaire et ressources). Prédictions écrites
avant chaque mesure (`prediction-49f.md`).

| étape | prédit | mesuré |
|---|---|---|
| 49f | 35 changent (famille et secretaire 2003 hors installation, la journée), 55 md5 ; part inchangée, morceaux en hausse | **35 / 365**, **55 md5** ; secretaire 64,0 → 64,0 %, documents 23 289 → 29 556 extents : conforme |
| 49g | 52 changent (dev, famille, secretaire 2003), 54 md5 ; `index.dat` en baisse (dev 50-120, famille et secretaire 300-600) | **52 / 348**, **54 md5** ; `index.dat` 150 → 84, 852 → 418, 786 → 316 : conforme |
| contre 49 | — | 348 identiques, 52 changent ; 54 md5 identiques |

**Les volumes de XP, 48 → 49 → reprise** (fragmentés parmi les
fragmentables, pire fichier, trous libres, MFT) :

| volume | 48 | 49 | reprise (49g) |
|---|---|---|---|
| `dev-2003` | 2,0 %, 465, 2 048, 6 | 7,6 %, 169, 1 607, 3 | 7,6 %, 175, 1 595, 3 |
| `famille-2003` | 24,4 %, 3 888, 3 570, 38 | 16,2 %, 2 448, 3 414, 2 | 16,2 %, 2 426, 3 552, 3 |
| `gamer-2003` | 0,0 %, 4, 10, 1 | 0,2 %, 7, 6, 1 | identique à 49 |
| `secretaire-2003` | 31,8 %, 865, 652, 1 | 64,0 %, 1 267, 2 315, 1 | 64,0 %, 1 048, 2 089, 1 |
| Vista, 7, FAT | — | — | identiques à 49 |

Par fichier (sonde `DUMP`, jetable), documents Word / `.pst` /
`index.dat` : `secretaire-2003` 49 : 23 289 / 695 / 829 extents ;
reprise : 29 610 / 425 / 316 ; `famille-2003` 49 : 2 316 / 708 / 864 ;
reprise : 3 243 / 658 / 418 ; `dev-2003` `index.dat` 150 → 84.

**Ce que dit la reprise.** Les 64,0 % de `secretaire-2003` ne venaient pas
de l'écriture de 4 Ko mais de son **début** : un cluster d'abord, au plus
petit trou qui suffit — souvent un trou d'un cluster —, puis le reste
ailleurs. ole32 commence de la même façon, par le cluster de ses 512 octets
résidents, et 5 316 documents sur 5 317 restent en morceaux ; ils en ont
plus (29 610 extents au lieu de 23 289), parce que chaque pas de 16 Ko est
une demande de 4 clusters au lieu de 8 et 16. `index.dat`, étendu par
16 Ko exacts derrière lui, tombe à un tiers ou à la moitié de ses
morceaux ; la part des fichiers fragmentés n'en bouge pas.

**La sonde de 64 Ko** (Word par pas de 64 Ko, binaire jetable
`bin-sonde-ole64`, non commité) : `secretaire-2003` 64,0 %, documents
**14 104** extents (2 morceaux pour 3 333 d'entre eux) ; `famille-2003`
16,2 %, 1 426. La part non sourcée — la taille des écritures de Word —
décide du nombre de morceaux, du simple au double, pas de la part des
fichiers fragmentés, que le stub fixe.

**Passes et son.** Démarrages à ±0,2 s ; la journée `famille-2003:400`
97,6 → 97,4 s. Passes XP : `dev-2003` 2 109 → 2 175 s, `famille-2003` 372 →
340 s, `secretaire-2003` 1 036 → 1 096 s ; UltraDefrag sur
`secretaire-2003` 1 374 → 1 414 s. Rien n'a été écouté.

**Durées de génération** (release, `run.sh 49g disks`, puis rejoué au
calme avec le même binaire, bilans identiques hors durée) : `dev-2003`
3,25 → 3,44 puis 3,20 s, `famille-2003` 1,64 → 1,75 puis 1,61 s,
`secretaire-2003` 0,49 → 0,58 puis 0,54 s ; les autres à la mesure près.
Pas d'explosion.

**Tests.** `swift test` : 176 + 320, verts, après un recalage :
« 2003 horodate ses accès, 2007 non » bornait les écritures de dates à deux
tiers des fichiers lus ; sur son `secretaire-2003` réduit, 660 écritures
pour 994 fichiers à 49, 656 à 49f, **666 à 49g** — la borne (662) tombait
entre deux, selon les enregistrements que prennent documents et
`index.dat`. Les deux tiers n'avaient pas de source ; la borne redevient ce
que dit le mécanisme, moins d'écritures que de fichiers (décision 1).
Gabriel a validé cette borne le 25 septembre 2026.
Calibration en Release (`calibration-49g.log`) : **15 tests, verts, les
mêmes 4 known issues**, la table des bornes de recherche identique (16,2 et
64,0 %), `famille-2003` toujours à 88,7 %. `GalleryAllocationAudit` en
Release (19 min 17) : **propre sur les vingt-quatre volumes**. Binaire
reconstruit après la dernière retouche (un commentaire) : identique à
`bin-49g`.

**README** : l'écriture sans taille connue par programme (Word, `index.dat`,
les autres en hypothèse), la première place d'un fichier, « Ce qui ne l'est
pas » (les 4 Ko des programmes non lus, le `.pst` compris, et le pas de Word)
; `readme-tables.py 49g --write`, la durée de `dev-2007` rendue (1,7 s ;
2,1 mesurés, machine chargée) : `--check`, un seul écart, celui-là, comme
au chantier 49. Les tables des passes de 2003 bougent (XP sur
`secretaire-2003` 17 min 16 → 18 min 16, morceaux restants 7 110 → 4 787).

### Laissé ouvert, après la reprise

- **Le pas de Word** : 16 Ko est le minimum d'ole32 ; la taille réelle des
  écritures de Word n'est dite nulle part. Elle décide du nombre de morceaux
  (÷2 à 64 Ko), pas de la part des fichiers fragmentés.
- **Le lien Word → ole32** reste déduit. Une trace d'époque (FileMon sur
  Word 2002/2003) le trancherait.
- **Le premier cluster** fixe la part : ole32 comme `WriteFile` commencent
  par un cluster placé au plus petit trou, et `secretaire-2003` reste à
  64 %. C'est ce que dit le code de NTFS lu ici ; qu'un vrai XP ait eu autant
  de runs d'un cluster dans son cache n'est pas vérifié.
- **L'enregistrement rapide** : le modèle réenregistre chaque document par
  temporaire (`writeTempThenRename`), avec le gonflement d'un *fast save* ;
  décoché par défaut depuis Word 97 SR-1 (KB Q192480), il fusionnerait en
  place. À revoir avec la prose (chantier 52).
- **Le `.pst`** : [MS-PST] donne le grain (une page AMap, environ 248 Ko),
  pas l'appel ; 4 Ko et surallocation en hypothèse.
- **Les autres programmes** (compilateur, cache du navigateur, encodeur,
  jeu, téléchargement) gardent l'hypothèse de 4 Ko ; aucun code lu.
- **L'entrelacement** (inutilisé par la galerie) appelle `stream` paquet par
  paquet : chaque paquet d'un fichier projeté y serait un *handle*, arrondi
  au pas puis ramené.
- Vista et 7 : inchangés, paquets de 64 Ko pour tous, sans source.


## Chantier 50 — XP à la lettre : le moteur du défragmenteur de XP

**Fait** · branche `xp`, partie de `e2b778c` (chantier 49 et sa reprise) ·
plan : `LEDGER-XP.md`

### Le problème

Le moteur de `WindowsXPStrategy` suivait `DefragNtfs` depuis le chantier 45,
mais `WINDOWS_CHECK.md` en relevait ce qui restait faux contre le code de
XP SP1 : `MFTDefrag` qui n'agissait qu'à trois extents et cherchait la
taille de la queue, zone MFT comprise (`xp-defrag-mft-condition`,
`mft-zone-cible`) ; la rétention de cinq secondes de NT 4 appliquée au
pilote de XP (`xp-defrag-point-de-controle`, `ntfs-alloc-15`) ; une
validation par fichier écrite aussitôt au lieu d'une transaction par bloc
de 64 Kio (`xp-defrag-validation`, `ntfs-alloc-14`) ; la copie au-delà de
la `ValidDataLength` ; la consolidation (`abandon-dix`, `zone-mft-une-fois`,
`zone-mft-rognee`) ; `ProcessBootOptimise`, absent (`xp-defrag-mft-avant-
apres`, `boot-10` à `12`) ; les 15 % (`xp-defrag-15pct`) ; et les
commentaires et tests de l'ancien XP (B#22). En tête, une enquête avait
trouvé que la défragmentation de l'histoire tassait les fichiers à travers
la zone MFT, et que c'était elle qui envoyait la MFT de `dev-2003` dans une
zone neuve à 94 % du volume (la passe XP de 1 029 à 2 109 s au chantier 49).

### Les décisions

Chaque référence a été relue dans `base/fs/utils/dfrg` (`dfrgntfs/`,
`defragcommon.cpp`, `freespace.cpp`, `fssubs.cpp`, `movefile.cpp`,
`dfrgui/`), `base/fs/ntfs` et `base/fs/lfs`. Le code de l'outil
(`dfrgntfs`) vaut pour le moteur commun, que Vista et 7 reprennent ici par
hypothèse (chantier 45) ; le code du pilote (`ntfs`, `lfs`) vaut pour les
volumes formatés par XP seulement — Vista et 7 gardent le modèle d'avant,
dit comme tel (décision 1). Ordre des étapes : l'historique d'abord (il
change les volumes), puis la rétention **avant** `MFTDefrag` et avant tout
ce qui touche au temps — la rétention rendait les décisions dépendantes de
l'horloge planifiée (chantier 48) ; retirée, chaque étape suivante se
mesure sur des plans stables, et une étape qui ne change que des
entrées-sorties (50d) se prouve par des décisions identiques.

- **50a — la défragmentation de l'histoire laisse la zone MFT vide**
  (`Simulator.defragment`) : un trou dans la zone fait reprendre la
  recherche derrière elle, un trou qui y entre est coupé, comme les listes
  de l'outil (`BuildFreeSpaceList`, `freespace.cpp:305-318`) et
  `MftExcludes` de JkDefrag. La zone est celle que publie l'allocateur
  (`Allocator.defragmentExcludedZone`, celle de
  `FSCTL_GET_NTFS_VOLUME_DATA`) ; sous Vista et 7, celle du modèle. La
  sonde de l'enquête (`bin-sonde-defragzone`, sur l'état de `572e37c`) a
  été reprise proprement, sans ses traces.
- **50b — sous XP, la place quittée est libre tout de suite.**
  `NtfsDeallocateClusters` efface les bits sur-le-champ (`bitmpsup.c:1798`),
  `FSCTL_GET_VOLUME_BITMAP` copie les pages brutes (`fsctrl.c:9222-9470`) ;
  un `MOVE_FILE` vers ces clusters lève `STATUS_DELETE_PENDING`
  (`bitmpsup.c:9046-9067`), que `NtfsDefragFile` intercepte dix fois au
  plus (`deviosup.c:10303, 10745-10790`) : tous les fichiers pris,
  `LfsFlushToLsn(LiMax)`, `NtfsFreeRecentlyDeallocated(CleanVolume)`, et le
  bloc recommence (10360-10390). `DefragVolume.reusesWithDeletePending`,
  `recentlyDeallocated`, `DefragOperations.deletePending` (le vidage, compté
  au bilan : ligne `journal`) ; `NTFSCheckpoints` oublie ce que le pilote
  suit toutes les 5 s (`logsup.c:902-906, 2260, 4500-4533`). XP, JkDefrag et
  UltraDefrag s'y soumettent ; **UltraDefrag garde sa propre rétention**
  jusqu'au tour suivant (`move.c:36-50, 719-727` : un choix de l'outil, sur
  NTFS quel que soit le pilote). Windows 95 sur NTFS suit la bitmap, sans
  vidage (`DEFRAG.EXE` n'a pas de `MOVE_FILE`) ; le tassage à la frontière
  et le recollage économe gardent leur comptabilité. `relocateMFTTail` rend
  la queue quittée comme un fichier.
- **50c — `MFTDefrag`** (`mftdefrag.cpp:78-160`, `GetMFTSize` 277-330) :
  dès deux extents (`lMFTFragments > 1`, 122 ; le commentaire d'en-tête dit
  « in two fragments ») ; premier extent au-delà de `ClustersPerFRS × 16`
  (120) — mais `ClustersPerFRS` est `ClustersPerFileRecordSegment`, que le
  pilote laisse à zéro quand un enregistrement est plus petit qu'un cluster
  (`fsctrl.c:1283-1292, 9148`) : sur des clusters de 4 Ko, un premier
  extent non vide suffit ; le pilote refuse de toute façon les seize
  premiers enregistrements (`deviosup.c:10112-10125`). Un trou de la taille
  de **toute** la MFT, premier dans l'ordre des LCN, zone MFT marquée
  occupée (`FindFreeSpaceChunk`, `MarkBitMapforNTFS`,
  `defragcommon.cpp:80-168`) ; `FindFreeExtent` remet son résultat à zéro à
  chaque appel et zéro veut dire « rien » (`freespace.cpp:1637-1765`) : faute
  de trou, l'outil rend le début du dernier trou examiné **seulement s'il
  touche la fin du volume**, et le déplacement est tenté — `MOVE_FILE` pose
  des blocs de 64 Kio jusqu'à buter sur la fin du volume
  (`STATUS_ALREADY_COMMITTED`, `deviosup.c:10499-10523`) : une partie de la
  queue bouge, le reste non ; sinon rien. `relocateMFTTail` accepte un
  déplacement partiel et fond deux extents contigus.
- **50d — une transaction par bloc de 64 Kio**, sous XP, pour les outils
  qui passent par `FSCTL_MOVE_FILE` (`DefragOperations.moveFile`) :
  `NtfsReallocateRange` puis `NtfsCheckpointCurrentTransaction` par bloc
  (`deviosup.c:10614-10618`, `logsup.c:2979-3014`, bits journalisés
  `bitmpsup.c:3068-3080`) ; pas de *write-through* (`logsup.c:2951-2956`) :
  l'enregistrement de MFT (sa page de 4 Ko) et les pages de `$Bitmap`
  (source et destination) sont salis et écrits par un *lazy writer* chaque
  seconde planifiée (la cadence qu'avaient déjà les installations de XP,
  `InstallEra`) ; LFS écrit « paresseusement » (`lfs/write.c:185-190`) :
  le journal part d'un trait avant le lazy writer (écriture anticipée), au
  point de contrôle de 5 s avec la zone de redémarrage
  (`LfsWriteRestartArea`, `lfs/restart.c:380-425`), avant un
  `DELETE_PENDING` et en fin de passe ; huit transactions par page, l'ordre
  de grandeur d'avant (`validationsPerLogPage`). Au-delà de la
  `ValidDataLength`, un bloc réalloué sans copie (`deviosup.c:10530-10561`,
  « `StartingVcn <= UpperBound` ») — sans effet sur la galerie, où aucun
  fichier n'est alloué au-delà de sa taille (sonde sur six volumes).
  `OperationSink.carry` porte les mutations d'un bloc sans écriture.
- **50e — la consolidation** : `ConsolidateFreeSpace` rend `bSuccess`
  (`dfrgntfs.cpp:3897`), « région parcourue sans abandon » ; vider la zone
  MFT s'arrête au premier fichier sans trou (3858-3866) et ne prend que les
  fichiers qui commencent dans la zone (3706-3712), retentée tant qu'elle
  n'a pas réussi (4268-4272, 4297-4300) ; les listes rognent comme l'outil
  — un trou qui traverse une zone n'en garde que la partie d'avant
  (`freespace.cpp:305-318, 434-476`).
- **50f — `ProcessBootOptimise` ouvre la passe de XP**
  (`dfrgntfs.cpp:2007-2013, 2851-2861`, avant `MFTDefrag` à 2906 ;
  `bootoptimizentfs.cpp:1664-2046`) : zone au registre, 0 et 0 à la
  première passe (`dfrg.inx`) ; fichiers de `Layout.ini` — ici `BootLayout`,
  l'ordre de lecture d'un démarrage planifié — qui existent, hors fichier
  d'échange, 32 Mo au plus (`IsAValidFile`, 624-775) ; zone reposée au
  début du plus grand trou (liste **sans** rognage de la zone MFT,
  `bIgnoreMftZone`, 1797-1803) s'il dépasse leur total et que moins de 90 %
  y sont (1817-1839) ; sinon intrus chassés au plus petit trou qui les
  tient (`EvictFile`, 1067-1312) — n'est intrus qu'un fichier dont un
  extent **autre que le premier** entre dans la zone : `CollapseExtentList`
  ne teste pas le premier (`fssubs.cpp:325-347`) ; puis chaque fichier, dans
  l'ordre, au premier trou de la zone qui le tient (`MoveBootOptimiseFile`,
  `FindFreeSpaceWithMultipleTrees`, `freespace.cpp:698-816`) ; faute de
  place, la zone grandit de 150 % du manque, 100 Mo au moins, sous 4 Go et
  la moitié du volume, sinon elle finit au dernier fichier rangé
  (1995-2031). Ensuite la zone est rognée de toutes les listes et de la
  zone MFT à vider (3625-3643), et ses fichiers, quand ils commencent
  **strictement** dans la zone, sont sautés par la consolidation et le
  tassement (3758-3763, 4061-4066) — le premier, à la borne même, ne l'est
  pas. `MFTDefrag` ne marque pas la zone de démarrage. XP seulement (Vista
  et 7 : pas de source) ; phase affichée « Defragmenting », comme l'écran de
  XP (`dfrgui/vollist.cpp:1242-1245`, `IDS_LABEL_DEFRAGMENTINGDDD`) : aucune
  clé neuve. Le rangement intelligent (`SmartDefragStrategy`) n'est pas
  touché : sa tête de volume reste un choix du projet, dit dans son
  commentaire.
- **50g — les 15 %, B#22, la doc.** La passe de l'app est celle de la
  console (`dfrg.msc`, ce que le code et le README nomment) : sous le seuil
  (`FreeSpaceErrorLevel`, 15, `fssubs.cpp:1239`, `dfrg.inx`),
  `CVolume::WarnFutility` met le moteur en pause et pose une question
  (`dfrgui/vollist.cpp:1329-1366`, appelé à `postmsgc.cpp:444-456`) ; le
  modèle y répond oui sans jouer l'attente. La ligne de commande sans `-f`
  refuserait (`dfrgntfs.cpp:2930-2965`) : ce n'est pas ce que l'app imite.
  B#22 : UltraDefrag ne « n'évacue personne comme XP », le noyau copie par
  64 Kio et non 4 Mo, `DefragStrategy`, le rangement intelligent, le
  recollage économe, Windows 95 ; dans `DefragPlannerTests`, le test « n'est
  pas défragmenté » renommé, « c'est une hypothèse » devenu la source,
  « la MFT ne se réorganise pas à chaud » et « XP suit les numéros
  d'enregistrement » corrigés, le message « une passe qui n'évacue rien ».

Tests neufs : l'histoire qui laisse la zone vide (`SimulatorTests`) ; sous
XP, la place quittée libre et le vidage, le point de contrôle qui oublie, la
queue de MFT libérée (`CheckpointTests`, dont les tests de rétention passent
sur un volume de Vista) ; `MFTDefrag` dès deux extents, vers un trou de
toute la MFT hors zone, le dernier trou au fond puis rien ; la transaction
par bloc et le lazy writer, la VDL et sa borne ; la zone MFT arrêtée au
premier échec, le trou qui traverse la zone ; l'optimisation du démarrage
(zone reposée, premier fichier ramené, intrus en morceaux seuls chassés)
(`WindowsXPLetterTests`). Ceux de 50a et de 50e échouent sur le code
d'avant (vérifié en y remettant l'ancien fichier) ; les autres n'ont pas
été rejoués contre lui. Retournés en
citant la source : le test de XP qui ne se pose pas sur la place quittée
(Vista seulement), « faute de trou », le recollage en blocs pleins,
`commitStaysAwayFromTheEdge` (Vista), la nuance de la carte
(`ClusterMapTests`, jugée en fin de passe sous XP), `MFTGrowthTests`
(dev-2003 et secretaire-2007 gardent leur MFT d'un tenant).

### Ce qui valide

Mesures sous `.build/measure-xp` (dépôt principal) ; `bin-49g` reconstruit
depuis `e2b778c` : identique, binaire et ressources. Prédictions écrites
avant chaque mesure dans `prediction-50.md` (sauf 50f, dont une sonde avait
imprimé les chiffres avant : dit dans le fichier).

| étape | prédit | mesuré |
|---|---|---|
| 50a | 85 changent, 53 md5 ; dev-2003 XP 1 100-1 250 s ; Vista et 7 à ±1 point | **85 / 315, 53 md5** ; MFT d'un tenant sur les cinq ; dev-2003 2 175 → **1 839 s** (la sonde tournait sur le volume de 49) ; secretaire-2007 3,5 → **5,0 %**, secretaire-2012 1,7 → **5,0 %**, dev-2012 7,2 → **5,6 %** : faux |
| 50b | 48-52 changent ; UltraDefrag : décisions identiques ; vidages par centaines ou milliers ; ±25-30 % | **43 / 357** (remplissage forcé jamais sur une place quittée) ; UltraDefrag conforme ; vidages 0 à 776 ; tris de JkDefrag **+130 à +620 %** : faux |
| horloge | sans point de contrôle, mêmes décisions sous XP | **40 / 40** identiques (`bin-50b-nocp`) ; seuls les vidages changent |
| 50c | 4 changent ; XP famille +0 à +15 % | **4 / 396** ; durées ±0,2 s : faux (le premier extent tient tous les enregistrements) |
| 50d | 48 changent, décisions identiques ; durées en baisse | **48 / 352**, décisions identiques ; XP **+2 à +23 %** : faux (160 Mo de journal sur les 20 Go de dev-2003) |
| 50e | 18 à 24 changent | **12 / 388** : faux ; sous Vista et 7, sens opposés entre une passe et sa variante en blocs pleins (l'horloge) |
| 50f | 8 changent ; gamer ×5-10, secretaire +10-30 % | **8 / 392** ; gamer ×8,2, secretaire +26 % : conforme (sonde vue avant) |
| 50g | 400 identiques ; 58 md5 à 50a | **400 / 400**, **58 / 58** |
| contre 49g | — | 268 identiques, 132 changent ; 53 md5 identiques (les 5 démarrages de 50a) |

Deux versions de 50d ont été mesurées puis reprises : la première écrivait
la page de journal pleine sur-le-champ, une par huit blocs (XP +15 à +23 %
par des allers-retours que le code ne montre pas : LFS écrit
paresseusement) ; la deuxième revidait en fin de passe le journal des
outils hors `MOVE_FILE` (+7 Mo pour le tassage à la frontière). Les
chiffres ci-dessus sont ceux de la troisième.

**Les volumes à défragmentations d'histoire, 49g → 50** (fragmentés parmi
les fragmentables, MFT, trous libres) :

| volume | 49g | 50 |
|---|---|---|
| `dev-2003` | 7,6 %, 3 extents, 1 595 | 7,6 %, 1 extent (`786432+4644`, zone 791 072..1 094 464 au lieu de 9 232 288..9 498 816), 1 743 |
| `dev-2007` | 9,2 %, 25 extents, 1 753 | 9,0 %, 1 extent, 2 039 |
| `secretaire-2007` | 3,5 %, 3 extents, 756 | 5,0 %, 1 extent, 615 |
| `dev-2012` | 7,2 %, 3 extents, 4 425 | 5,6 %, 1 extent, 4 206 |
| `secretaire-2012` | 1,7 %, 6 extents, 1 527 | 5,0 %, 1 extent, 893 |

Sur Vista et 7, les fichiers qui passent en morceaux sont des documents
réenregistrés et des fichiers système (sonde `DUMP`) : l'allocateur du
modèle, sans source, sur un paysage libre changé — la zone de 200 Mo
restée à 3 Gio au lieu de tranches renouvelées derrière le vierge. Non
isolé plus avant.

**Les passes, 49g → 50** (défragmentation seule ; blocs pleins dans les
bilans) :

| volume | XP | JkDefrag | UltraDefrag |
|---|---|---|---|
| `dev-2003` | 36 min 15 → 39 min 00 (+8 %) | 10 min 26 → 9 min 57 (−5 %) | 9 min 00 → 8 min 09 (−9 %) |
| `famille-2003` | 5 min 40 → 6 min 30 (+15 %) | 17 min 32 → 21 min 06 (+20 %) | 7 min 31 → 7 min 47 (+4 %) |
| `gamer-2003` | 11 s → 1 min 38 (×8,9) | 3 min 56 → 3 min 54 (−1 %) | 6 s → 6 s |
| `secretaire-2003` | 18 min 16 → 30 min 23 (+66 %) | 26 min 46 → 28 min 49 (+8 %) | 23 min 34 → 24 min 22 (+3 %) |
| `dev-2007` | 2 h 04 → 2 h 22 (+14 %) | 57 min 29 → 1 h 21 (+42 %) | 33 min 14 → 45 min 25 (+37 %) |
| `famille-2007` | 30 min 18 → 29 min 21 (−3 %) | 36 min 42 → 36 min 42 | 20 min 19 → 20 min 19 |
| `gamer-2007` | 2 h 40 → 2 h 19 (−13 %) | 1 h 54 → 1 h 54 | 46 min 17 → 46 min 17 |
| `secretaire-2007` | 48 min 05 → 51 min 03 (+6 %) | 36 min 48 → 40 min 24 (+10 %) | 24 min 27 → 28 min 21 (+16 %) |
| `dev-2012` | 55 min 57 → 55 min 48 (−0 %) | 50 min 29 → 48 min 30 (−4 %) | 22 min 26 → 25 min 25 (+13 %) |
| `famille-2012` | 2 h 10 → 3 h 03 (+40 %) | 1 h 10 → 1 h 10 | 40 min 05 → 40 min 05 |
| `gamer-2012` | 2 h 53 → 3 h 57 (+36 %) | 1 h 11 → 1 h 11 | 27 min 49 → 27 min 49 |
| `secretaire-2012` | 52 min 25 → 1 h 01 (+18 %) | 34 min 59 → 36 min 43 (+5 %) | 20 min 18 → 23 min 10 (+14 %) |

Et les tris de JkDefrag sur les 2003 (par nom, date d'accès, taille) :
`dev-2003` 9 min 06 → 57 min 02, 7 min 01 → 26 min 31, 6 min 33 →
28 min 29 ; `famille-2003` 11 min 01 → 35 min 04, 12 min 09 → 46 min 16,
10 min 57 → 36 min 55 ; `secretaire-2003` 6 min 41 → 28 min 56, 7 min 16 →
43 min 50, 9 min 49 → 23 min 23 ; `gamer-2003` +4 à +10 %. La rétention
empêchait `Vacate` de libérer la place d'un fichier avant de l'y poser : le
tri s'arrêtait à mi-course ; sous XP il va au bout (secretaire, tri par
date d'accès : 32 770 → 3 015 morceaux après).

**XP sur les 2003, étape par étape** (secondes) : `dev-2003` 2 175 (49g),
1 839 (50a), 1 838, 1 838, 2 251 (50d), 2 251, 2 340 (50f) ;
`famille-2003` 340, 340, 344, 343, 396, 396, 390 ; `gamer-2003` 11 jusqu'à
50e, 98 à 50f ; `secretaire-2003` 1 096, 1 096, 1 275 (50b), 1 275, 1 462,
1 449, 1 823. Ce que dit l'arrivée (49g → 50) : `dev-2003` fragmentés
après 1 → 0, trous 260 → 205, 27 vidages forcés ; `famille-2003` trous
3 689 → 3 746 ; `gamer-2003` trous 99 → 202 (916 fichiers de démarrage
posés à 9 766 256, au début du grand trou de la fin du volume) ;
`secretaire-2003` fragmentés 365 → 286, morceaux 4 787 → 4 166, trous
3 034 → 3 888, 83 vidages, sa zone de démarrage posée **dans la zone MFT**
(788 980), parce que la liste de `ProcessBootOptimise` ne rogne pas celle-ci.

**La sensibilité à l'horloge** (chantier 48) : sous XP, les décisions des
outils ne dépendent plus du temps planifié. Un binaire jetable sans aucun
point de contrôle (`NTFSCheckpoints.interval` = 10¹², `bin-50b-nocp`) donne
les mêmes décisions sur les 40 passes de XP, UltraDefrag, JkDefrag et
Windows 95 des 2003 ; seuls les vidages (XP secretaire 76 → 137) et la
durée, de 0 à 2 s, changent. Sous Vista et 7, la rétention du modèle reste,
et avec elle la sensibilité : à 50e, la même correction allonge la passe de
`famille-2012` de 40 % et raccourcit sa variante en blocs pleins de 3 %.

**Durées de génération** (release, `run.sh 50g`, machine au calme ; 50a
mesuré sous une charge de 40 à 80) : `dev-2003` 3 195 → 3 281 ms,
`dev-2007` 2 103 → 2 121 ms, `secretaire-2007` 473 → 488 ms, `dev-2012`
3 024 → **2 602 ms** (volume changé à 50a), `secretaire-2012` 664 →
606 ms ; les autres à la mesure près. Pas d'explosion ; côte à côte, 49g et
50a font 3 749 / 3 826 et 3 658 / 3 897 ms sur `dev-2003`.

**Le son** (rien n'est écouté ; rendu hors-ligne `SCENARIO=dev-2003
STRATEGY=windowsXP`, `bin-49g` et `bin-50g`) : 2 176 → 2 340 s ; seeks
40 183 → 75 569, moyenne 29 961 → 20 611 cylindres ; repères audio 44 982
→ 49 145 ; RMS médian −33,9 → −32,5 dBFS (p95 −32,5 → −31,5) ; attaques
(trames de 10 ms au-dessus de trois fois la médiane) 10,0 → 13,6 par
seconde. Deux fois plus de seeks, plus courts : un aller-retour par
seconde vers le journal et les tables, à 3 Gio, et le rangement du
démarrage à 3 695 443.

`swift test` : 177 + 334 tests, verts. Calibration en Release
(`calibration-50g.log`) : **15 tests, verts, les mêmes 4 known issues**.
`GalleryAllocationAudit` en Release (`audit-50g.log`, 19 min 24) :
**propre sur les vingt-quatre volumes**. Binaire reconstruit après la
dernière retouche : identique à `bin-50g`, binaire et ressources.
md5 : 53 identiques à 49g (les cinq démarrages des volumes de 50a), 58 à
50a. README : `readme-tables.py 50g --write`, la durée de génération de
`dev-2007` rendue (1,7 s ; 2,1 mesurés) ; `--check`, un seul écart,
celui-là. La description de l'outil de XP (« Huit défragmenteurs »), la
règle du volume sous XP et hors XP, et « Ce qui ne l'est pas » (le lazy
writer d'une seconde, huit blocs par page, la première passe de sa
machine, les 15 %, Vista et 7) suivent ; le reste de la prose est au
chantier 52.

### Laissé ouvert

- **Vista et 7** : rétention de 5 s, validation par fichier, allocateur
  sans source ; leurs passes restent sensibles à l'horloge. Le moteur de
  l'outil y est celui de XP par hypothèse (MFTDefrag, consolidation), sans
  l'optimisation du démarrage.
- **Le lazy writer** : chaque seconde, tout ce qui est sale ; le vrai en
  écrit un huitième par passage et commence à 3 s (chantier 51). Le poids
  du journal (huit transactions par page) reste un ordre de grandeur, et
  il fait l'allongement des passes de XP à 50d.
- **La zone de démarrage d'une vraie machine** : le préchargeur lance
  `defrag -b` à l'inactivité, au plus tous les trois jours ; le modèle ne
  le rejoue pas, et chaque passe manuelle est une première passe. `Layout.ini`
  est l'ordre d'un démarrage planifié, sans les programmes lancés ensuite
  (chantier 51).
- **La question des 15 %** met le moteur en pause jusqu'à la réponse ;
  l'attente n'est pas jouée.
- **Deux nuances de `FindRegionToConsolidate`** (une région commence
  toujours par un trou ; la coupure sur un fichier trop gros recule d'un
  cluster, `xp-defrag-region`) ne sont pas reprises ; la zone de démarrage
  y coupe une région comme la zone MFT, là où l'outil peut y prolonger une
  région par des fichiers contigus à sa borne.
- **`NtfsAcquireAllFiles`** à chaque bloc de la MFT, et la dernière
  retentative de `DELETE_PENDING` qui échoue, ne sont pas joués.
- **Le rangement intelligent** et sa table du README (douze non vérifiées)
  ne sont pas remesurés ; `SmartDefragStrategy` est inchangé.
- **Écoute proposée, non faite** : `SCENARIO=gamer-2003 STRATEGY=windowsXP`
  (98 s au lieu de 11, le rangement du démarrage au milieu d'un 80 Go),
  `SCENARIO=dev-2003 STRATEGY=windowsXP` (l'aller-retour par seconde vers le
  journal), et un tri de JkDefrag sur `secretaire-2003`.


## Chantier 51 — XP à la lettre : démarrage, cache et pile d'E/S de XP

**Fait** · branche `xp`, partie de `7a8c0ab` (chantier 50) · plan :
`LEDGER-XP.md`

### Le problème

Le démarrage de XP, ses installations et ses journées reposaient sur un
modèle que `WINDOWS_CHECK.md` contredit contre le code de XP SP1 : un
préchargeur qui « range la liste par position » et relit les six derniers
démarrages (`boot-01` à `03`), les « N premiers Ko » d'un fichier (`boot-05`),
un acte des services lu au hasard après le préchargement (`boot-06`), une
date d'accès qui ne salit que la page de MFT, sans journal (`boot-15`), un
*lazy writer* qui écrit tout, chaque seconde, et seulement les tables
(`io-cache-01`, `boot-16` — le chantier 50 l'avait posé ainsi pour les
passes), pas de lecture anticipée du cache (`io-cache-05`), 64 Ko attribués
au pilote de port (`io-cache-02` à `04`), une file FIFO (`io-cache-09`),
aucun `FLUSH CACHE` (`io-cache-10`), et sur FAT, `FSCTL_MOVE_FILE` joué comme
sur NTFS (`fat-20`, `xp-defrag-fat-bloc`). Huit lacunes du domaine
« Démarrage », cinq du domaine « Cache et pile de stockage ».

### Les décisions

Chaque référence a été relue dans `base/ntos/cache`, `base/ntos/mm`,
`base/fs/ntfs`, `base/fs/fastfat`, `base/ntos/config`, `base/ntos/ex`,
`base/hals/halx86`, `drivers/storage/{ide,classpnp,disk}` et
`admin/services/sched/service/daytona` (décision 1). Tout ce qui suit ne vaut
que pour l'époque XP (`winxp-sp1`, et le pilote de XP pour les passes) ;
Vista et 7 gardent leur modèle, dit comme tel.

**L'ordre**, pour isoler les effets : la file d'abord (elle décide de
l'ordre de tout ce qui est émis ensemble), puis le préchargeur, qui en est le
premier client ; les tailles de requête, qui ne changent que le découpage ;
le *lazy writer* des tables, avant celui des données qui partage son
budget ; la date d'accès, qui passe par lui ; la lecture anticipée, qui
suppose le cache ; le registre et `FLUSH CACHE`, dont `fastfat` se sert
ensuite.

- **51a — la file d'`atapi`** (`AtapiQueue`). Chaque SRB porte sa LBA pour
  clé (`classpnp/xferpkt.c:399-406`) ; `atapi` insère par clé et, à chaque fin
  de commande, retire la première de clé ≥ `CurrentKey`, sinon la première
  (`KeRemoveByKeyDeviceQueue`, `internal.c:3877-3878`, `ke/devquobj.c:320-333`),
  puis `CurrentKey` = clé + 1 (`3959-3965`) ; une requête arrivée disque au
  repos part sans toucher la clé (`devpdo.c:2051-2056`) ; clé remise à zéro
  à la mise sous tension (`pdopower.c:322`). Pas de NCQ ni de *tagged
  queuing* (`init.c:207`, `chanfdo.c:1741`), pas d'AHCI. Le simulateur sert
  une commande à la fois dans l'ordre du plan : **la file est jouée par le
  planificateur**, sur ce qu'il sait émis ensemble (une rafale, ou des fils
  synchrones dont chacun émet sa suivante après le retrait). Il gagne
  `RequestFlow` : premier plan, arrière-plan (le calcul de l'hôte court
  pendant que le disque sert ce qu'il n'attend pas), barrière. Sous XP, les
  actes préchargés du modèle d'avant émettent leurs lots d'un bloc
  (`MmPrefetchPages`, `pfsup.c:318-388`).
- **51b — le préchargeur à la lettre** (`emitWithXPPrefetcher`,
  `BootOrder.firstAccess`). `CcPfBootWorker` (`prefboot.c:440-1000`) : les
  métadonnées une fois (`prefboot.c:722`) — pages de MFT des fichiers et
  répertoires de la trace, arrondies, triées, sans doublon
  (`ntfs/fsctrl.c:19334-19433`), écarts de 128 Ko comblés (`SEEK_THRESHOLD`,
  `pfsup.c:55-61, 1103`), puis le contenu de chaque répertoire, les parents
  d'abord (`prefetch.c:5455-5470, 5687-5800`) ; la phase des pilotes, puis
  tout ce qui précède `SMSS` en un passage (« plenty of available memory »,
  761-773), chacune en deux lots, données puis images, l'en-tête des images
  avec les données (`prefetch.c:4930-4960`) ; les pilotes s'initialisent
  pendant le second lot, `SMSS` l'attend (936-955). Services et session :
  du calcul et des écritures. L'application : son propre scénario
  (`CcPfPrefetchScenario`, `prefetch.c:4605-4640`). Ordre du premier accès
  (`pfsvc.c:2631-2635`) : c'est la file qui balaie. `Layout.ini` :
  répertoires puis fichiers, sans le dernier acte (`pfsvc.c:6149-6180`).
  Historique de 8 démarrages, sensibilité ≥ 2 (`prefetch.h:180`,
  `pfsvc.c:4301-4311`) : commentaire corrigé ; le modèle n'a pas
  d'historique. Libellés corrigés en anglais et en français
  (`explanation.prefetch.text`, `pass.boot.prefetch`, trois détails d'actes
  de XP).
- **51c — les tailles de requête.** `classpnp` coupe à `HwMaxXferLen` =
  min(128 Ko, 31 pages) = **124 Ko** (`xferpkt.c:60-74` ; `idep.h:31`,
  `atapi/init.c:198-209` ; la HAL donne 33 registres à un maître PCI de
  128 Ko, `ixisasup.c:1006-1008`, `pciidex/bm.c:741`) : ce que le
  préchargeur lit hors cache part par 124 Ko ; ce qui passe par le cache
  reste à 64 Ko (`MAX_WRITE_BEHIND`, `cc.h:159, 175` ; `mm.h:62`) ; une image
  lue hors préchargement fait des fautes de 32 Ko (`mminit.c:1511-1512`,
  `pagfault.c:2852-2870`) — le modèle ne connaît pas les sections, et lit
  tout comme du code (16 Ko pour les données) ; sans effet sur la galerie.
  La doc d'`InstallEra` n'attribue plus les 64 Ko au pilote de port.
- **51d — le *lazy writer*** (`LazyWriter`). Un passage par seconde
  (`LAZY_WRITER_IDLE_DELAY`, `cc.h:380`) tant qu'il reste des pages sales ;
  3 s après la sortie du repos (`CcFirstDelay`, `cachedat.c:65`,
  `lazyrite.c:85-99`) ; un huitième du total, plus le rattrapage vers
  `CcDirtyPageTarget` (`lazyrite.c:325-363`), **dépensé flux par flux** depuis
  le curseur : un flux de métadonnées part en entier, celui qui épuise le
  budget aussi, les suivants attendent (436-506) — le « un huitième des pages
  de chaque flux » que suggérait `WINDOWS_CHECK.md` n'est pas ce que dit le
  code ; trois fils de travail (`fssup.c:145-168`, `ex/worker.c:312-340`,
  `mminit.c:1520-1530`) dans la file d'`atapi` ; le journal avant les tables
  (`cachesub.c:3619-3622, 3696`) ; plages de 64 Ko. Pour les passes (50d),
  les installations, les journées et les dates d'accès ; plus de vidage forcé
  entre deux séances ou deux étapes, seulement à l'arrêt.
- **51e — les données aussi.** Une écriture de programme salit des pages
  (`CopyFile` par 64 Ko, `fileopcr.c:4847-4870`) ; un flux de données écrit
  ce qui reste du budget, là où il s'était arrêté (`cachesub.c:3002-3007,
  3296-3320, 3994-3998`) ; une lecture de pages sales est servie par le
  cache ; un fichier effacé perd ses pages sans qu'elles soient écrites
  (`ntfs/cleanup.c:1576, 1930, 2515`). `RequestFlow.backgroundBarrier` :
  après un lot du préchargeur, les délais du *lazy writer* comptent de sa
  fin. La fenêtre d'un démarrage s'arrête avec son silence final.
- **51f — la date d'accès journalisée** (`stampXP`). À la fermeture
  (`cleanup.c:2282-2348`) : la page de MFT, par `NtfsChangeAttributeValue`
  (`UpdateResidentValue`, `attrsup.c:3398-3405`), et l'entrée `$FILE_NAME` du
  répertoire parent (`FCB_INFO_DUPLICATE_FLAGS`, `ntfsstru.h:2587-2594` ;
  `NtfsUpdateFileNameInIndex`, `attrsup.c:8172-8400`, `indexsup.c:611-830`),
  journalisée ; fichiers système exclus (`FCB_STATE_SYSTEM_FILE`) — aucun au
  catalogue. Deux enregistrements par date, seize par page de journal (huit
  validations de deux, l'ordre de grandeur du modèle). Le nom court d'un
  fichier, seconde entrée, n'est pas connu.
- **51g — la lecture anticipée** (`CcReadAhead`). Activée au premier défaut
  (`copysup.c:560-575`), décidée à chaque lecture sans lecture d'avance en
  attente (149-150) : troisième lecture séquentielle, la première à l'offset
  0 comprise ; la tranche de la taille de la lecture arrondie à 64 Ko après
  la prochaine frontière, ou dès la page suivante après une première lecture
  courte (`cachesub.c:1330-1520`, `ntfsdata.h:374`), bornée par la fin du
  fichier. Archives des installations, lectures des journées, dernier acte du
  démarrage. Le cas 2 (pas constant) n'est pas joué ; la taille d'une
  lecture de programme est supposée de 64 Ko.
- **51h — le registre et `FLUSH CACHE`.** `DiskMechanics` sert `FLUSH CACHE`
  (une écriture de zéro secteur : tout ce qui est acquitté est posé avant la
  réponse ; `disk.c:3406-3411`, `atapi.c:5564`). Sous XP, une ruche salie
  part 5 s après la dernière modification (`cmworker.c:41, 523-535`, réarmé
  par `HvMarkDirty`, `hivesync.c:659-662`), en arrière-plan, et avant chaque
  redémarrage au premier plan ; son `.LOG` écrit trois fois, chaque fois
  suivi de `ZwFlushBuffersFile` → `FLUSH CACHE` (`hivesync.c:2542-2810`,
  `cmwrapr.c:1045-1048`), puis la ruche par le cache (1036-1040). Le catalogue
  n'a pas de `.LOG` : seuls ses trois `FLUSH CACHE` sont joués. Installations
  seulement.
- **51i — `FSCTL_MOVE_FILE` sur FAT** (`fatMoveFile`). `FatMoveFile`
  (`fastfat/fsctrl.c:5290-5645`) : tranches de 256 Kio alignées dans le
  fichier (5959-5968) ; FAT de la cible écrite avant (les deux copies,
  `write.c:749-790`) ; source lue par le cache ; la tranche d'une requête
  synchrone en paquets de 124 Ko ; seconde soudure ; entrée de répertoire si
  le premier cluster bouge, sinon première soudure ; source rendue sans
  écriture immédiate ; `FLUSH CACHE`. Pour JkDefrag et UltraDefrag sur FAT ;
  plus de validation par fichier. La première soudure d'un déplacement
  partiel prend un secteur voisin de la source : le cluster qui précède
  n'est pas connu du modèle.

**Les témoins et les cibles de démarrage** (décision 1). `ThinkModel.boot`
n'est pas recalé : ses cibles sont les durées du modèle d'avant la relecture,
pas des mesures d'époque, et les retrouver serait aligner le modèle corrigé
sur l'ancien. Le témoin (le même contenu d'un tenant) passe par le même
préchargeur ; ses écarts se resserrent (tableau). La phrase du README qui
donne l'ajustement (« 0,19 ») dit maintenant que la constante est restée à
0,185.

Tests neufs : `AtapiQueueTests` (C-LOOK, clé inchangée au repos, secteur
répété, fils synchrones), `LazyWriterTests` (3 s puis 1 s, huitième par flux,
reprise des données, lecture anticipée), `FatMoveFileTests` (tranches,
`FLUSH CACHE`, soudures et entrée), `DriveCacheTests` (`FLUSH CACHE`).
Retournés en citant la source : l'ordre du préchargeur par époque
(`BootSessionTests`, XP en premier accès), les enregistrements de MFT lus
par pages sous XP (Vista garde les ouvertures une à une), `InstallSessionTests`
(une écriture de zéro secteur est un `FLUSH CACHE`), et **« 2003 horodate ses
accès, 2007 non »** : sa borne, validée le 25 septembre 2026 (« moins
d'écritures que de fichiers lus »), tombe à 51f — une date salit deux pages
(MFT et index du parent) ; 994 dates, 1 028 écritures. La borne suit le
mécanisme : moins d'écritures que de pages salies, et le journal en quelques
pages, avant elles. Gabriel a validé cette borne le 25 septembre 2026.

### Ce qui valide

Mesures sous `.build/measure-xp` ; `bin-50g` reconstruit depuis `7a8c0ab` :
identique, binaire et ressources. Prédictions écrites avant chaque mesure
(`prediction-51.md`). Les commits de 51b à 51i ont été faits avant leur
mesure, puis amendés avec elle ; 51a a été reconstruit depuis `7a8c0ab` et
prouvé par ses bilans (binaire différent de 4 Ko : les chemins).

| étape | prédit | mesuré |
|---|---|---|
| 51a | 9 changent, 49 md5 ; démarrages de XP ±5 % | **9 / 391, 49 md5** ; −0,9 à +0,6 % : conforme |
| 51b | 17 changent (dont les 8 passes de XP de 2003), 49 md5 ; démarrages −10 à −30 %, seeks en baisse | **17 / 383, 49 md5** ; démarrages **−0,7 à −5,8 %**, seeks **en hausse** (énumération des répertoires, deux balayages par phase) : faux sur l'ampleur |
| 51c | 9 changent, 49 md5 ; requêtes −10 à −30 %, durées ±1 % | **9 / 391, 49 md5** ; requêtes −17 à −31 %, durées −0,3 % au plus : conforme |
| 51d | 57 changent (48 passes), 49 md5 ; passes ±3 %, installations et journée −1 à −5 % | **57 / 343, 49 md5** ; passes −1,9 à +1,8 %, démarrages −0,3 % ; installations **−0,1 %**, journée **−10,1 %** : faux |
| 51e | 9 changent, 49 md5 ; installations −5 à −12 % | première version (`out-51e-v1`) : démarrages +6 à +19 %, deux défauts corrigés avant de remesurer ; puis **9 / 391, 49 md5**, installations **−3,7 à −8,9 %**, journée −0,5 %, démarrages ±0,3 % |
| 51f | 5 changent, 53 md5 ; écritures des dates +30 à +100 % | **5 / 395, 53 md5** ; +28 à +62 %, durées +0,6 % au plus : conforme (gamer juste dessous) |
| 51g | 9 changent, 49 md5 ; installations −1 à −5 % | **7 / 393, 51 md5** : deux démarrages ne lisent rien que la lecture anticipée touche ; installations −1,0 à −2,1 % |
| 51h | 4 changent, 54 md5 ; installations ±3 % | **4 / 396, 54 md5** ; +0,4 à +0,6 %, 72 à 90 `FLUSH CACHE` : conforme |
| 51i | ≤ 120 changent, 58 md5 ; passes FAT de JkDefrag et UltraDefrag +30 à +150 % | **107 / 293, 58 md5** ; **−18,6 à +277,9 %** : faux sur l'ampleur |
| contre 50g | — | 236 identiques, 164 changent ; 49 md5 identiques |

**Démarrages et témoins, 50g → 51i** (secondes ; les vingt autres volumes
sont identiques) :

| volume | démarrage | témoin (écart) |
|---|---|---|
| `dev-2003` | 51,5 → 49,8 | 52,0 (−1 %) → 49,8 (−0 %) |
| `famille-2003` | 34,6 → 32,4 | 36,3 (−5 %) → 32,6 (−1 %) |
| `gamer-2003` | 66,3 → 66,0 | 67,6 (−2 %) → 66,3 (−0 %) |
| `secretaire-2003` | 35,0 → 34,3 | 34,7 (+1 %) → 34,0 (+1 %) |

Le calcul fait 67 à 72 % d'un démarrage de XP, et il ne rétrécit pas : le
préchargeur ne gagne que ce que ses lots font gagner au disque, et le
recouvrement du lot d'avant `SMSS`. Les seeks montent (`famille-2003` 868 →
1 346) mais raccourcissent (14 584 → 2 264 cylindres en moyenne) : un
démarrage de XP est une suite de balayages — métadonnées, répertoires,
données, images —, plus une énumération de répertoires, puis du calcul.

**Sessions, 50g → 51i** : installations `dev-2003` 657,5 → 621,6 s,
`famille-2003` 459,8 → 440,0, `gamer-2003` 710,2 → 638,9,
`secretaire-2003` 416,2 → 395,4 (les données posées par le *lazy writer*
pendant que le CD se lit) ; journée `famille-2003:400` 97,4 → 79,9 s ; les
autres installations et journées identiques. Passes : XP sur les 2003 +0,4
à +2,4 % ; JkDefrag et UltraDefrag sur les 2003 −1,3 à +0,3 % ; sur les
FAT, de −18,6 à +277,9 % (`dev-1999` JkDefrag 676 → 1 752 s, 15 782 `FLUSH
CACHE`).

**Le son** (rien n'est écouté ; rendu hors-ligne, `bin-50g` et `bin-51i`,
trames de 10 ms, attaques au-dessus de trois fois la médiane) :
`boot:famille-2003` 35,6 → 33,4 s, seeks 868 → 1 346 (moyenne 14 584 →
2 264 cylindres), RMS médian −41,0 → −41,4 dBFS, p95 −26,7 → −29,8,
attaques 6,6 → 4,8 par seconde : des balayages plus courts, moins
d'attaques fortes. `dev-1993` JkDefrag : 254 → 354 s, requêtes 5 189 →
12 363, seeks 5 042 → 8 724, RMS médian −31,5 → −31,2, attaques 0,4 → 0,8
par seconde : les retours à la table deux ou trois fois par tranche, et le
disque qui vide son cache.

`swift test` : **177 + 346 tests, verts**. Calibration en Release
(`calibration-51i.log`) : **15 tests, verts, les mêmes 4 known issues**.
`GalleryAllocationAudit` en Release (`audit-51i.log`, 19 min 28) : **propre
sur les vingt-quatre volumes** — il audite les plans des passes, donc le
chemin FAT de 51i. Binaire reconstruit après la dernière retouche (un
commentaire de `DiskSimulator`) : `bin-51final`, 400 bilans identiques à
51i.
Volumes : les vingt-quatre empreintes identiques à 50g (le chantier ne
touche pas `DiskCore`) ; durées de génération à la mesure près (`dev-2003`
3 281 → 3 279 ms, `famille-2003` 1 617 → 1 643, `dev-2007` 2 121 → 2 123,
`dev-2012` 2 602 → 2 627).

README : `readme-tables.py 51i --write`, la durée de génération de
`dev-2007` rendue (1,7 s ; 2,1 mesurés) ; `--check` : un seul écart,
celui-là. Prose corrigée : le préchargeur (ni tri, ni « six derniers »), la
date d'accès journalisée, les tables et le registre des installations, le
*lazy writer* de la passe de XP, `Layout.ini`, la constante de XP, « Ce qui
ne l'est pas » (tailles de requête, file d'`atapi`, `FLUSH CACHE`, les trous
du démarrage de XP, le registre sans `.LOG`). Le reste est au chantier 52.

### Laissé ouvert

- **La file d'`atapi` est jouée par le planificateur**, sur ce qu'il émet
  ensemble. Une requête du premier plan arrivée pendant qu'un lot attend
  passe après lui au lieu d'être triée avec lui ; il faudrait une vraie file
  dans `DiskMechanics`, qui verrait les requêtes à venir.
- **La trace du préchargeur n'existe pas** : on lit le budget de l'acte,
  d'un tenant. La troncature par la mémoire, la phase parallèle à
  l'initialisation vidéo, l'application dans la trace du démarrage, les
  sections des images (des lectures coupées à chaque sous-section) ne sont
  pas joués.
- **La mémoire de la machine** n'est dite nulle part : le seuil de
  rattrapage du *lazy writer* suppose plus de 220 Mo. Rien ne survit d'une
  séance à l'autre (pas de pages propres en cache sous NT).
- **Le `.LOG` des ruches** n'est pas au catalogue ; seuls les installations
  vident le registre ; la ruche est réécrite en entier.
- **Les dates d'accès des journées**, et l'index d'un répertoire où naît un
  fichier, ne sont pas joués.
- **Les tailles de lecture des programmes** : 64 Ko, faute de mieux.
- **`ThinkModel`** garde ses constantes ; les cibles de démarrage restent
  celles du modèle d'avant la relecture, qu'aucune mesure d'époque ne
  remplace.
- **Écoute proposée, non faite** : `boot:famille-2003` (lots puis silence),
  `SCENARIO=dev-1999 STRATEGY=jkDefrag` (le va-et-vient de `fastfat`),
  `install:gamer-2003` (les pulsations du *lazy writer* pendant la copie).


## Chantier 52 — XP à la lettre : les documents

**Fait** · branche `xp`, partie de `20e38ea` (chantier 51) · plan :
`LEDGER-XP.md`

### Le problème

Les chantiers 47 à 51 ont fait suivre au modèle le code de XP SP1 ; les
documents, eux, décrivaient encore le modèle d'avant, ou se contredisaient
avec leurs propres tables. `AUDIT_REALISME.md` en relevait une vingtaine de
constats (B#1 à B#4, B#11, B#13, B#14, B#18 à B#20, B#23, B#26 à B#29, B#38
à B#44, B#46 à B#50), `WINDOWS_CHECK.md` une liste de « Commentaires faux ».
Le dernier chantier du plan ne touche pas au modèle.

### Ce qui a été corrigé, par constat

- **B#20, B#38 à B#44 — `readme-tables.py`** : les gabarits calculent
  maintenant leurs verbes et leurs comparatifs d'après les chiffres —
  `times` (« 7,7 fois moins », jamais « 0,1 fois plus »), `versus` (« moins
  de morceaux que XP mais plus qu'UltraDefrag et JkDefrag »), l'élision
  (« qu'un occupant »), « tous deux à 91 % » au lieu de « 91-91 % », le
  volume que XP nettoie et qu'UltraDefrag ne nettoie pas, l'exception de la
  frontière (`gamer-1996`, quatre fichiers de plus en morceaux), le volume
  plein où l'outil de 95 laisse le plus de morceaux (`famille-1996`, 5 108),
  le volume FAT où la frontière laisse le plus de trous (`dev-1996`, 115,
  contre 2 au rangement). Un champ capturé peut porter une proposition entière
  (240 caractères au lieu de 40) ; deux gabarits qui finissaient sur un champ
  ont gagné un mot d'ancrage. La prose qui les entoure a été récrite là où
  elle contredisait ses tables : le recollage économe (« qui se compensent »,
  « la qualité à durée voisine », « XP et JkDefrag finissent sans un
  morceau »), la frontière contre Windows 95 (1,4 fois moins de données,
  19 min d'écart, les mêmes morceaux mais 59 trous contre 2), `gamer-1993`
  (99 %, rangé par la frontière : 838 morceaux à 0), le prix des volumes
  pleins de 95, UltraDefrag contre XP (« plus lointaines » devant un seek plus
  court). Le tri de JkDefrag dit maintenant la règle de XP (la place quittée
  est libre, le tri va au bout ; `secretaire-2003`, 15 875 morceaux contre 769
  au mode 2) à côté de celle de Vista et 7.
- **B#39 — le rangement intelligent, remesuré.** `smart.sh` et
  `passes.py <étape>:smart` rejoués sur `bin-51i` (le binaire mesuré du
  chantier 51, les 400 bilans de 52 le prouvent identique), par un script du
  scratchpad restreint aux profils — `smart.sh` n'a pas de filtre —, en
  environnement propre : 168 bilans (`rboot-`, `pass-`) rangés dans
  `out-51i`. La table passe aux **vingt-quatre** volumes, 2012 compris
  (`SMART_ORDER`), et la prose suit : douze NTFS, 3,7 To déplacés et 26 h 45
  de passes ; démarrages FAT 596,7 → 569,0 → **516,3 s**, NTFS 485,5 →
  471,6 → **446,6 s** ; trous 127 → 14 (FAT), 1 799 → 42 (NTFS) ;
  l'exception n'est plus `gamer-1999` mais `famille-1999` (1 trou au mieux,
  2 au rangement). La clé `max` sur les NTFS plantait sur un volume absent de la
  table : corrigée. Le README dit d'où vient la table et que l'ancienne datait
  d'avant les lots réalisme.
- **B#46 — l'arborescence** : `WindowsXPStrategy` décrit comme au chantier
  50 ; `NTFSAllocator+XP`, `NTFSFreeRunCache`, `AtapiQueue`, `LazyWriter`,
  `SeekCharacter`, `SpindleCharacter`, `ProfileIssues`, `RearrangedDisk`,
  `CellPartition`, `CellContents`, `FrenchUnits`, `MapZones`, `SoundMix`,
  `PassRecord`, `PassDigest`, `PassHistory`, `CustomDiskStore`,
  `DiskLibraryModel`, `DisplayFormat`, `NowPlaying`, `Sources/Tips/TipJar`,
  `AboutLinks` et `TipSheet` y entrent, et les deux dossiers de tests, avec
  `WindowsXPLetterTests`, `NTFSXPAllocationTests`, `AtapiQueueTests`,
  `LazyWriterTests`, `FatMoveFileTests`. Le catalogue compte douze fiches.
- **README, le reste** : « Huit défragmenteurs » devient « Sept » (il y en a
  sept, et « les six outils précédents » le disait déjà) et nomme MS-DOS 6
  DEFRAG, Vista et 7 ; le seek (B#2) n'est plus « 8,7 ms, un tiers de
  course » ; « Ce qui ne l'est pas » relu en entier contre 47-51 : rien n'y
  était devenu sourcé qui n'en fût déjà sorti ; y entrent le découpage de
  64 Kio de `NtfsDefragFile` que JkDefrag et UltraDefrag ne suivent pas sous
  XP (le modèle leur garde une requête et une transaction par 4 Mo), les
  nuances du moteur de XP laissées au chantier 50, la MFT jamais trouée, et
  Word, dont le document grossit comme sous l'enregistrement rapide ; sur FAT,
  l'outil de XP n'est plus parmi ceux qui passent par l'API. La section
  « Mesurer un changement » donne la vraie commande de `smart.sh`.
- **B#19, B#26 — les fiches d'outils** : les vingt-quatre durées
  « measured » recalculées sur les bilans de `51i` (toute la galerie de leur
  format, arrondies aux cinq minutes au-delà d'une heure) : XP « 2 min to
  3 h 55 » au lieu de « a few seconds to 45 min », Windows 95 « a few
  seconds to 1 h » au lieu de « 6 min to 1 h », le rangement intelligent
  « 5 min to 4 h 20 » (2012 compris). Le commentaire des clés dit
  « vingt-quatre disques, bilans du chantier 51 ».
- **B#18, B#27, B#49 — le site** : la page support décrit l'outil de XP par
  l'unité `en` du catalogue et dit l'outil de chaque époque ; la table de
  l'accueil gagne MS-DOS 6 DEFRAG, Vista et 7, et chaque cellule y est
  maintenant le texte exact du catalogue (origines et principes, qui étaient
  abrégés) ; « How it works » gagne une section « The system » (préchargeur,
  file d'`atapi`, *lazy writer*, défragmenteur de XP), l'allocateur de XP et
  le niveau de la tête pris aux manuels. Liens relatifs vérifiés (aucun
  cassé, ancres comprises) ; chaque `<span class="ui">` est une valeur `en`
  du catalogue.
- **Commentaires** : B#1 (la plage des niveaux, 1,97 à 3,64 B, 16,7 dB),
  B#2 (`SeekModel` : le paragraphe orphelin du « tiers de course » retiré,
  son histoire rendue à `roughlyCalibrated`), B#3 (`SpindleVoice`, d'après la
  mesure du chantier 39), B#4 (la doc de `windageFollowsSpeed` rendue ; le
  test des niveaux vérifie enfin 1996), B#11 (la doc de `writeSeek` rendue),
  B#14 (`ProfileIssuesTests`, `DriveModelTests`), B#28 (le POST de la
  journée), B#48 (`FrenchUnits` et `DisplayFormat` : le 2²⁰ est celui de
  l'affichage, l'étiquette est décimale). **La liste « Commentaires faux » de
  `WINDOWS_CHECK.md` était déjà soldée** : les huit y sont corrigés par les
  chantiers 48 à 51 (vérifié un par un).
- **B#13 — les remarques de l'assistant** : `ProfileIssue` porte sa nature
  (`Kind`), plus de phrase ; `DiskCore` ne se traduit pas. La phrase est
  composée dans `DisplayFormat.swift` (`ProfileIssue.message`), treize clés
  `profile.issue.*`, en et fr, tailles et date formatées par la langue ;
  l'assistant l'affiche par `Text(verbatim:)`. Les tests vérifient la nature,
  plus la phrase française.
- **B#23 — `summary.windowsXP`** : quatre substitutions plurielles
  (`%#@repaired@`, `broken`, `evicted`, `moved`), en et fr, et
  `summary.windowsXP.remaining` au pluriel ; vérifié sur le catalogue
  compilé par `xcstringstool` : « repairs 1 file out of 1 … 1 file moved in
  all », « 1 fichier déplacé en tout », « 1 reste en morceaux ». Le test ne
  fige plus « 1 files » : il lit les nombres, la forme `other` étant ce que
  rend `defaultValue` hors de l'app.
- **B#29** : l'assistant propose « MS-DOS 6 et Windows 3.1 », le nom du
  démarrage ; `CLAUDE.md` dit que ce nom s'affiche.
- **B#47 et la construction — `CLAUDE.md`** : la 1.0.0 n'est pas prête ; ce
  qui manque avant (fusion, nouveau build, hors plan) ; `Calibration` et
  `GalleryAllocationAudit` et comment les lancer ; `swift test` ne voit pas
  un fichier oublié dans `build-render.sh`, et `xcb.sh gen` après un fichier
  neuf.
- **B#50** : le renvoi au chantier 40. Et, dans l'entrée du chantier 51, la
  validation de la borne de « 2003 horodate ses accès » par Gabriel.

Clés de traduction : treize neuves (`profile.issue.*`), vingt-six modifiées
(`summary.windowsXP`, `summary.windowsXP.remaining`, les vingt-quatre
`tool.*.measured`). `xcb.sh strings` a aussi retiré
`extractionState: extracted_with_value` de onze clés existantes (`phase.*`,
`strategy.vista`, `strategy.win7`, `tool.vista.*`, `tool.win7.*`) : c'est ce
que rend `xcstringstool` sur le code actuel, laissé tel quel.

### Ce qui valide

Prédiction (`prediction-52.md`, écrite pendant que la mesure tournait, avant de
la lire) : 400 bilans et 58 md5 identiques à `51i`, un binaire différent.

- `snapshot.sh 52` après la dernière retouche d'une source, rien touché
  pendant la compilation ; `run.sh 52 full` : **400 bilans, identiques à
  `51i`** (`compare.py --identical` par préfixe : `boot-` 24, `install-` 24,
  `day-` 4, `defrag-` 300, `full-` 24, `disk-` 24) ; `wav-md5.py 52` : **58
  md5 identiques**. Aucune chaîne de bilan ne change.
- `swift test` : **177 + 346 tests, verts**.
- `./scripts/xcb.sh gen` puis `./scripts/xcb.sh build` : réussi.
- `./scripts/i18n.py check` : aller-retour exact ; `export` : 0 chaîne pas
  encore migrée, 955 clés, 1 910 localisations.
- `readme-tables.py 51i --check` : 101 lignes de table, 76 phrases ; **un
  écart**, la durée de génération de `dev-2007` (1,7 s au README, rendue
  comme aux chantiers 47 à 51 ; 2,1 s mesurés, 2,14 et 2,16 s rejoués sur
  `bin-52`) : `--check` sort donc en erreur sur cette seule ligne.
  `readme-tables.py 52 --check` : le même écart, et la table du rangement
  non vérifiée (ses bilans sont dans `out-51i`).
- Calibration et `GalleryAllocationAudit` : non relancées (aucun allocateur
  ni stratégie touchés, et les bilans le prouvent).

### Laissé ouvert

- **Le nom de système de 1993** s'affiche en français (« et ») dans l'app
  anglaise, comme les jours de la journée (« Jour N », `NowPlaying`,
  `SimulationModel`) et le « puis » des installations (`Scenario`) : à
  traduire à l'affichage sans toucher au nom que relit `readme-tables.py`.
- **Les autres bilans de stratégie** (`summary.*`) gardent des `%lld` sans
  pluriel (« 1 files ») : B#23 ne visait que XP ; l'audit en comptait 42.
- **JkDefrag et UltraDefrag sous XP** : le pilote découpe tout `MOVE_FILE`
  par 64 Kio, une transaction chacun ; le modèle leur garde 4 Mo. Dit dans
  « Ce qui ne l'est pas » ; un changement de modèle, hors de ce chantier.
- **La durée de génération de `dev-2007`** (1,7 s au README, 2,1 s mesurés
  depuis le chantier 48) : à remesurer machine au repos, ou à réécrire.
- **Hors plan** : B#31 à B#34, B#36 et B#45 (« sans achat intégré », Ko-fi,
  « no network access », le commentaire d'`AboutLink`), que Gabriel corrigera.
- **Rien n'a été vu dans le simulateur** : les remarques de l'assistant et
  les fiches d'outils dans les deux langues restent à regarder.

## Chantier 53 — les pourboires, partout

### Le problème

Le chantier 38 a ajouté trois pourboires par l'achat intégré, et n'a relu que
la page confidentialité et les notes de revue. Six constats de
l'`AUDIT_REALISME.md`, laissés hors du plan XP, disaient encore l'app sans
achat intégré, Ko-fi comme seule voie de pourboire, et l'app jamais en ligne,
alors que la feuille des pourboires interroge l'App Store par StoreKit.

### Les décisions

- **Ko-fi reste sur le site et dans le README**, comme l'ont décidé les
  chantiers 36 et 37, et toujours hors de l'app. Il n'y est plus la seule
  voie : l'achat intégré est cité d'abord.
- **Ce qui passe par le réseau est dit tel quel** : l'app n'ouvre aucune
  connexion à elle ; StoreKit demande à l'App Store les noms et les prix des
  trois pourboires à l'ouverture de la feuille, confie un achat à la feuille de
  paiement d'Apple, et signale à l'app, pendant qu'elle tourne, un pourboire
  approuvé plus tard. `TipJar` ne garde rien : son état vit en mémoire et
  revient au repos à la fermeture de la feuille (B#35), sans `UserDefaults`.
- **B#31** (`docs/index.html`) : « Free, with no in-app purchase » devient
  « Free, with everything included », et les trois pourboires facultatifs qui
  ne débloquent rien ; la vignette « No account, no network » devient « No
  account, no data collected ».
- **B#32 et B#45** (`README.md`, « Soutenir ») : « gratuit, sans achat intégré »
  devient la ligne « Soutenir Winchester » des Réglages, puis Ko-fi, hors de
  l'app.
- **B#33** : l'accueil du site ne dit plus « free and stays free » mais
  « a tip unlocks nothing », et renvoie à « Settings → Support Winchester »
  avant Ko-fi. Les notes de revue disent que l'app ne porte aucun lien de don
  externe, et que le site, l'un des liens « About », mentionne une page Ko-fi.
- **B#34** : la page confidentialité (description, « In short », « Tips »,
  « There is no other path »), la ligne de l'accueil, les notes de revue, et
  `settings.about.note` (« The app itself never goes online » devient « The
  app sends nothing along with them », en anglais et en français) décrivent
  l'échange StoreKit. Date d'effet de la confidentialité : 25 septembre 2026.
  Les commentaires de `docs/assets/style.css` et de `PrivacyInfo.xcprivacy`
  suivent ; les déclarations du manifeste ne bougent pas.
- **B#36** : le commentaire d'`AboutLink` renvoie à `TipSheet` et au
  chantier 38, au présent.
- Les métadonnées du store (`metadata/app-info`, `metadata/version`) ne
  parlaient ni d'achat intégré ni de réseau : rien à changer.

### Ce qui valide

- `./scripts/i18n.py import` puis `check` : aller-retour exact à l'octet ;
  `metadata/` inchangé.
- `./scripts/xcb.sh gen` puis `./scripts/xcb.sh build` : réussi. `swift test` :
  346 tests en 52 suites, tous verts.
- Les liens relatifs et les ancres des quatre pages du site : aucun cassé.
- `readme-tables.py --check` n'a pas été relancé : les bilans de `.build/measure`
  n'existent plus dans ce worktree, et la section changée ne porte ni table ni
  chiffre.

### Laissé ouvert

- **Les notes de revue ne sont pas poussées** (`asc review details-update`) :
  à faire par Gabriel au moment de soumettre.
- **« Data Not Collected »** reste vrai : Apple traite l'achat, l'app ne
  reçoit ni ne garde rien de l'acheteur, et StoreKit n'est pas une API à raison
  déclarée. Le manifeste est celui de DepthWeaver à la lettre près (aucun
  pistage, aucune donnée collectée, `UserDefaults` en `CA92.1`).
  `metadata/app-privacy.json` le dit autrement : `"dataUsages": []`, là où
  DepthWeaver écrit une entrée `DATA_NOT_COLLECTED` ; la déclaration publiée
  sur le store (faite dans le navigateur) est la même, seul le fichier diffère.
  Laissé tel quel.
- La nouvelle `settings.about.note` n'a pas été vue à l'écran.

### Aligné sur DepthWeaver

Décision de Gabriel, le 25 septembre 2026 : **Ko-fi reste sur le site, le
pourboire passe par l'achat intégré, comme dans DepthWeaver**, dont la
version 1.2.1, publiée, a été validée par Apple avec ce schéma. DepthWeaver
ne cite Ko-fi que dans le pied de ses pages, sous « Buy me a coffee » ; seule
sa page confidentialité parle des pourboires ; ses notes de revue décrivent
les trois consommables et disent qu'il n'y a aucun lien de don dans l'app,
sans parler du site.

- **Pied des quatre pages** (`docs/`) : « Support on Ko-fi » devient « Buy me
  a coffee », `rel="noopener"`, à la même place.
- **Accueil** : la phrase « … leave one in the app … or on Ko-fi » disparaît,
  et les deux lignes « Details » ne parlent plus des pourboires ni de StoreKit
  (« Free, with everything included » ; « no network connection of its own »).
- **Confidentialité** : le paragraphe « Tips » reprend celui de DepthWeaver
  (trois pourboires en achat intégré, rien de débloqué, paiement tout entier
  chez Apple, ni nom, ni adresse, ni moyen de paiement reçus, aucune trace de
  l'achat dans l'app), plus une phrase sur StoreKit, seule voie réseau. Le fond
  ne change pas : date d'effet toujours au 25 septembre 2026.
- **Notes de revue** : le premier paragraphe ne dit plus que l'app, ses liens
  « About » et l'absence de réseau propre ; une section `TIPS (IN-APP
  PURCHASE)` sur le modèle de DepthWeaver porte les trois identifiants, le
  chemin Settings → Support Winchester, rien de débloqué, rien à restaurer,
  aucun lien de don dans l'app, et l'échange StoreKit. La phrase sur le Ko-fi
  du site est retirée.
- **README** : « Offrir un café » dans la ligne de liens, et la section
  « Soutenir » dit le pourboire de l'app puis Ko-fi en une ligne.
- **L'app ne change pas** : `TipJar` est le fichier commun du dépôt
  `donations`, comme chez DepthWeaver (plus `sheetClosed`, B#35), et
  `TipSheet` porte les mêmes clés `tip.*` et le même texte. Aucun lien Ko-fi
  ni de don dans `Sources/`. DepthWeaver range la feuille sous « À propos »,
  Winchester dans une ligne des Réglages : sans effet pour la revue.
- `CLAUDE.md` fixe la règle dans « Publier ».
