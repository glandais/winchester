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

**Partiellement fait** · commits `c2b8640`, `794a921`, `faa2bbd`, `47a9abc`

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
| `secretaire-2003` | 94 % | 7 455 | 2 min 23 | 57 | 141 → 84 |
| `famille-2003` | 93 % | 9 190 | 2 min 32 | 39 | 80 → 41 |
| `dev-2003` | 94 % | 19 353 | 5 min 58 | 260 | 299 → 39 |
| `secretaire-2007` | 88 % | 35 408 | 15 min 27 | 186 | 186 → 0 |
| `famille-2007` | 93 % | 78 797 | 23 min 38 | 89 | 244 → 155 |
| `gamer-2007` | 90 % | 76 425 | 27 min 31 | 131 | 192 → 61 |
| `dev-2007` | 86 % | 280 595 | 1 h 12 | 172 | 172 → 0 |

`famille-2007` passe de 28 millions de requêtes et 94 h à **78 797 requêtes et
23 min 38**, et son plan se construit en 1,45 s. Aucune évacuation nulle part.
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

### Ce qui reste

1. **JKDefrag / MyDefrag** : analyse, découpage en trois zones (répertoires,
   fichiers ordinaires, gros fichiers rares), et surtout *fast optimize*, qui ne
   comble que les trous au lieu de tout tasser — donc beaucoup moins
   d'évacuations, et une signature sonore radicalement différente. Chantier
   distinct, et **sans rapport avec NTFS** : la stratégie s'applique aussi bien
   aux volumes FAT.

Deux pièges déjà repérés. `FindBestItem` n'a pour seul
garde-fou contre l'explosion combinatoire qu'un **budget de 0,5 s de temps
réel** (`ALGO.md` §5.2) : inutilisable tel quel, une passe simulée doit être
reproductible, il faudra une borne déterministe et assumer que le plan diverge
de l'original. Et la licence du dépôt amont est **incohérente** — `LICENSE` dit
Apache 2.0, tous les en-têtes source disent GPL v2 / LGPL.

### Pas encore écouté

Tout ce qui précède est mesuré en `PLAN_ONLY`. Aucune passe NTFS n'a été rendue
en audio : la signature sonore décrite ici — pas de « clac » de retour au bord,
des rafales longues de 4 Mo — est déduite du plan, pas entendue.

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

**Partiellement fait**

Fait : le rejeu de la carte tient un décompte par bloc mis à jour par mutation,
au lieu de reparcourir tous les clusters à chaque image.

Reste :

- passer de `Canvas` et d'un `Path` par cellule à un buffer de pixels transformé
  en `CGImage` — au-delà de ~3 000 rectangles, SwiftUI plie ;
- le **plein écran**, avec une grille plus fine (192 × 108 en paysage, soit
  20 736 cellules) ; sur un 320 Go cela fait encore ~4 000 clusters par bloc, et
  une écriture isolée ne change plus un bloc entier de couleur — il faudra une
  teinte proportionnelle plutôt qu'une catégorie majoritaire ;
- la carte par cluster (`initialMap`) pèse 80 Mo sur un volume de 320 Go : à ne
  jamais matérialiser pour ces volumes-là. `GeneratedDisk.cells` montre déjà
  comment agréger sans la construire.
