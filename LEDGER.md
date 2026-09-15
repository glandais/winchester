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

La lecture de `COMPARAISON-DEFRAGMENTEURS.md` a refait le classement. Ce qui
était un point unique — « JKDefrag / MyDefrag » — en fait trois, et le plus
intéressant n'est pas celui qu'on croyait. Toutes ces stratégies sont
**indépendantes du format** : elles s'appliquent aux volumes FAT comme aux NTFS.

**1. La défragmentation partielle d'UltraDefrag.** C'est la seule qui réponde à
un échec déjà mesuré. `famille-2007` laisse 155 fichiers sur 244 en morceaux
parce que ses gros fichiers — 213 Mo en moyenne — ne trouvent aucun trou à leur
taille. Le `defrag_routine` d'UltraDefrag traite les fichiers les plus
fragmentés d'abord et, sur un gros fichier, **ne fusionne que les petits
fragments** au lieu de déplacer des gigaoctets pour gagner peu. La comparaison
note que JKDefrag n'a pas cet équivalent. C'est donc la seule des trois dont le
gain se chiffre d'avance, et elle change le son autant que le résultat : des
rafales courtes sur les bords d'un fichier, au lieu d'un long transfert.

**2. Le comblement de trous d'`OptimizeVolume`.** La signature de placement la
plus caractéristique de JKDefrag : pour chaque trou, chercher d'abord une
**combinaison de fichiers qui le comble exactement** (`FindBestItem`), sinon le
plus gros qui tient (`FindHighestItem`). Beaucoup moins d'évacuations que le
tassage de 95.

Piège identifié : `FindBestItem` n'a pour seul garde-fou contre l'explosion
combinatoire qu'un **budget de 0,5 s de temps réel** (`ALGO.md` §5.2).
Inutilisable tel quel — une passe simulée doit être reproductible. Il faudra une
borne déterministe, en nombre de candidats ou d'itérations, et assumer que le
plan diverge de l'original.

**3. Les trois zones et les tris.** `CalculateZones` découpe le volume en
répertoires / fichiers ordinaires / *space hogs*, avec une réserve d'espace
libre après les deux premières et une itération à point fixe plafonnée à dix
passes. S'y ajoutent les cinq tris complets du disque (nom, taille, dernier
accès, dernière modification, création), `ForcedFill` et `OptimizeUp`. Le plus
gros morceau, et le moins urgent.

### Deux petits points, et une mise au point de vocabulaire

**Une passe qui n'a rien à faire ne devrait pas se lancer.** `gamer-2003` est
plein à 8 % et n'a pas un fichier fragmenté : il rend une passe de 17 requêtes
et 7,8 s. UltraDefrag a exactement la garde qui manque —
`check_fragmentation_level` annule le job sous un seuil. C'est quelques lignes,
et c'est plus juste que sept secondes de bruit.

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
