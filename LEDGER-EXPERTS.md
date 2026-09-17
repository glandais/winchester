# Trois experts au banc — dépouillement des revues

Ce fichier n'est pas un chantier de correction : **aucune ligne du modèle n'a
bougé**. C'est le dépouillement des trois relectures commandées sur la branche
`experts`, rangé par ce qu'il faut en faire, avec les recoupements que la
lecture séparée ne pouvait pas donner.

| revue | périmètre | commit |
|---|---|---|
| `DISK_EXPERT_REVIEW.md` | mécanique, géométrie, acoustique | `74da38b` |
| `FILESYSTEM_EXPERT_REVIEW.md` | FAT16 / VFAT / FAT32 / NTFS, placement, chemin de lecture | `e1614da` |
| `DEFRAG_REVIEW.md` | les huit stratégies et `DefragVolume` | `e757462` |

Les trois périmètres sont disjoints par construction — la défragmentation est
explicitement hors sujet des deux premières, la mécanique hors sujet de la
troisième — et les trois relecteurs ont **instrumenté le code** plutôt
qu'estimé : sondes temporaires sur `DiskGenerator.generate`, `swift test` sur
cible macOS, outil d'audit compilé en release qui rejoue les huit plans sur les
vingt profils. Les chiffres cités ci-dessous sont les leurs.

---

## Le problème

Le projet a une règle : aucune valeur ne se pose, tout se dérive d'un fait
d'époque vérifiable. Personne ne l'avait jamais vérifiée de l'extérieur. Trois
relectures indépendantes en donnent la première mesure — et le verdict est le
même aux trois : **la forme du modèle est juste et rare**, et c'est justement
pour cela que les écarts comptent.

Ce qui sort n'est pas une liste de réglages. Ce sont trois **fautes** (un plan
qui écrit par-dessus une donnée vivante, un tour de plateau perdu par arrondi,
un curseur qui repart du début), quatre **erreurs de fait** vérifiables contre
une table de `FORMAT`, et une poignée d'endroits où **le commentaire promet une
mécanique que le code n'a pas**.

---

## Ce qui a été trouvé, par gravité

### Fautes — le code fait quelque chose d'impossible

| # | quoi | où | mesuré |
|---|---|---|---|
| F1 | un fichier est écrit par-dessus un autre encore référencé ; le `continue` de l'évacuation laisse l'occupant en place et l'étape 2 se pose quand même | `Windows95Strategy.swift:120-141` | **746 clusters sur 6 fichiers** (`dev-1996`), 85 sur 2 (`gamer-1996`) ; 347 trous avant la passe, **496 après** |
| F2 | la latence rotationnelle suppose le secteur 0 à l'angle 0 sur toutes les pistes, alors que le franchissement de piste suppose l'inverse ; l'arrondi flottant fait perdre **un tour entier** au milieu d'une lecture contiguë | `DiskSimulator.swift:270-285` | Barracuda ATA IV : **12,2 Mo/s** en requêtes de 64 Ko contre 34,3 d'un bloc, 48,6 en théorie |
| F3 | `systemCursor = range.lowerBound` écrase la ligne au-dessus et fait l'inverse de ce que son commentaire annonce trois lignes plus haut | `NTFSAllocator` | chaque fichier système rebalaie la tête saturée depuis le même point |
| F4 | la MFT hors zone s'étend en `bestFitRun(minLength: 1)` sur **tout le volume** : elle consomme les miettes une par une | `NTFSAllocator` | MFT de `dev-2003` : 4 653 clusters en **348 extents** |

F1 et F2 ne sont pas du même ordre que le reste : l'une produit un état de
volume qui ne peut pas exister, l'autre coûte un facteur 2 à 4 sur **tout**
séquentiel.

### Erreurs de fait — vérifiables contre une source

| # | quoi | correction |
|---|---|---|
| E1 | les trois volumes de 1993 portent `clusterKB: 8` là où `FORMAT` donnait 4 Ko sous 256 Mo — et `FAT16Profile.forVolume`, interrogé, répond bien 4 Ko | retirer `clusterKB` des trois JSON : le modèle a déjà raison |
| E2 | `gamer-1999` : 8 400 Mo en clusters de 4 Ko, alors que la table FAT32 bascule à 8 Ko au-delà de 8 Go ; `FAT32Profile` n'a pas de `forVolume` | ajouter la table FAT32, comme pour FAT16 |
| E3 | `$MFTMirr` « près du début » est posé à `mftZone.upperBound`, soit **31 Go** du début sur `dev-2007` ; et il fait 1 cluster, pas 4. `$Boot` fait 2 clusters, pas 1 | corriger taille et position ; la copie du secteur d'amorçage est en **fin** de volume |
| E4 | la bascule du miroir est datée 2001 ; elle accompagne NTFS 3.0, donc Windows 2000 | `>= 2000` |
| E5 | `.system` force le cluster 0 même en VFAT et FAT32, alors que seul le chargeur d'amorçage l'exige — or `systemCore` est la catégorie de **toutes** les DLL et de tous les fichiers de mise à jour | `.system` ne vaut 0 que pour `scan == .fromVolumeStart` |
| E6 | la commutation de tête (2,0 ms, mise à l'échelle par le seek moyen) est **plus lente que le seek d'une piste** sur six disques du catalogue sur huit | la dériver du piste-à-piste dans `calibrated(averageSeekMs:trackToTrackMs:)` |
| E7 | `WIN386.SWP` est posé à la racine ; il vivait dans `C:\WINDOWS` | une ligne de `ScenarioCompiler` |
| E8 | secteurs réservés FAT32 : 1 au lieu de 32 | inaudible, gratuit |

E5 se mesure : sur `gamer-1999`, les 786 `UPD*.DLL` des mises à jour ont une
position moyenne à **1 % du volume**. Le devant des volumes FAT32 est re-mité en
permanence par un mécanisme qui n'a jamais existé.

### Les deux manques structurels

Ce sont les seuls points qui demandent une décision de conception, et chacun est
vu par deux experts depuis deux étages différents.

**Tout fichier naît d'un seul tenant.** `Allocator.place` alloue chaque fichier
en un appel, à sa taille finale : un fichier ne peut donc être fragmenté que si
*l'espace libre* l'était déjà. La distribution qui en sort est bimodale et vide
au milieu — **99,7 % des fichiers de `dev-2003` sont parfaitement contigus**
après trois ans à 95 % de remplissage, et une trentaine sont en miettes, jusqu'à
1 781 extents. Il manque la traîne continue des fichiers en 2, 3, 7 morceaux,
qui est exactement ce qui fait le bruit d'un disque fatigué. Les deux mécanismes
réels absents sont l'**allocation incrémentale** (un fichier dont la taille
n'est pas déclarée grandit par paquets) et l'**entrelacement** (deux écritures
d'une même journée se disputent le curseur). Un booléen « la taille est-elle
connue à l'avance ? » sur le `WritePattern`, une boucle d'`extend` par paquets,
et un round-robin dans la journée : aucun taux de fragmentation n'entre dans
cette description, et la traîne tombe toute seule.

**Les répertoires n'existent pas.** `DirectoryRecord` porte un nom, un parent,
un rang, et aucun cluster ; `directoryEntryBytes` vaut bien 32 pour FAT mais
n'est lu que pour dimensionner la MFT. `dev-2003` compte **30 répertoires pour
13 951 fichiers**. Coût aux trois étages :

- système de fichiers — sur FAT un répertoire *est* un fichier, qui grandit d'un
  cluster quand ses entrées débordent, à des moments éloignés, donc fragmenté ;
  VFAT consomme une entrée par tranche de 13 caractères de nom long. C'est
  précisément la population de petits fichiers réécrits sans arrêt qui manque à
  l'histogramme ci-dessus ;
- défragmentation — la **zone 0 de JkDefrag est toujours vide** (`zone: hog ? 2 : 1`,
  jamais 0) : le découpage en trois bandes qui fait la signature de l'outil est
  un découpage en deux. Et le cas FAT le plus caractéristique de JkDefrag —
  vingt échecs de déplacement de répertoire puis abandon de toute la classe,
  vingt recalculs de zones compris — ne peut pas se produire, faute d'objet à
  qui échouer ;
- mécanique — l'entrée de répertoire est écrite dans la racine, donc le bras
  revient au tout début du volume à chaque validation, y compris en FAT32 où
  c'était faux.

Le même ajout supprime aussi la seule approximation que `openAccesses`
reconnaît.

### Ce que le modèle ne fait pas, et qui s'entend

| quoi | effet attendu |
|---|---|
| **cache disque et lecture anticipée** — absent de `DiskMechanics` ; c'est le mécanisme qui, en vrai, masquait exactement F2 | le plus gros écart conceptuel restant ; change qualitativement le son d'une lecture séquentielle |
| **`$LogFile`** — absent de `systemExtents` et de `commitAccesses` ; l'en-tête de `VolumeFormat` en conclut que le bras ne revient pas au bord, ce qui est faux de toute écriture | rend à NTFS son trafic de métadonnées **groupé**, qui est une signature plus intéressante que le silence |
| **horodatage d'accès** jusqu'à XP, désactivé sous Vista | un écart d'époque audible, gratuit, qui distingue 2003 de 2007 mieux qu'un réglage de débit |
| **recalibration thermique** des disques d'avant 1996 | pour le Conner et le Fireball, l'ajout le plus payant à l'oreille ; `IdleBehavior` a déjà tout ce qu'il faut |
| **le régime dans le timbre du plateau** — à plein régime un 3 600 et un 7 200 tr/min ont aujourd'hui exactement le même timbre | meilleur rapport effort/effet sur toute la galerie |
| **le filtre à 18 ms** décime un franchissement de piste sur deux là où la cadence réelle est de 120 Hz — une hauteur, pas un cliquetis | rendre le train dense en continu, comme `renderChatter` le fait déjà pour les seeks |
| **coût par commande, débit de bus, settle d'écriture** | `serve()` connaît déjà `request.isWrite` |

---

## Ce que les trois voient du même endroit

Quatre recoupements que la lecture séparée ne donnait pas.

1. **La calibration absorbe les artefacts.** Les constantes de `ThinkModel` ont
   été calées « pour que le total tombe sur les durées d'alors » — elles
   absorbent donc aujourd'hui F2 (facteur 2 à 4 sur le séquentiel) et les 17 Mo
   de FAT lue pour rien au montage de `gamer-1999`. Corriger l'un ou l'autre
   fera tomber les vingt démarrages sous leur cible. **Il faut donc grouper tout
   ce qui change une durée de démarrage et ne recaler `ThinkModel` qu'une fois,
   après.**
2. **Le principe « aucun paramètre de fragmentation » a une exception.**
   `NTFSAllocator` porte `reuseTolerance = 2`, `growthMarginClusters = 16`,
   `searchWindow`, `searchHorizon` — quatre valeurs introduites pour le coût de
   calcul, défendables une par une, et qui **poussent toutes vers la
   contiguïté**. C'est le réglage de fragmentation que le projet dit ne pas
   avoir. À dire dans l'en-tête, et à mesurer : générer `famille-2003` avec
   `reuseTolerance` à 2, 4 et `.max` dirait en trois lignes quelle part du
   résultat vient de là. Aujourd'hui personne ne le sait.
3. **Des docstrings qui promettent ce que le code ne fait pas.** `.temporary`
   annonce « les placer à part change la texture du volume » et est traité
   exactement comme `.normal` ; `.boot` n'est rendu par aucune catégorie ;
   `VolumeFormat` affirme que NTFS ne revient pas au bord ; `WindowsXPStrategy`
   annonce « 260 fichiers sur 299 » là où on mesure 35 sur 40 ; le tassage à la
   frontière présente son groupement de validations comme acquis alors qu'il
   tombe à 0,7 déplacement par validation à 99 % de remplissage. Le
   raisonnement de ces commentaires reste juste ; ce sont les chiffres qui ont
   dérivé, et un lecteur qui vérifie ne les retrouve pas.
4. **Une règle de volume appliquée comme une règle d'outil.** Les clusters que
   `FSCTL_MOVE_FILE` libère restent alloués jusqu'au point de contrôle : c'est
   une propriété de NTFS, et trois stratégies sur cinq seulement l'appliquent.
   Les deux qui l'ignorent — XP et JkDefrag — sont précisément celles qui
   appellent vraiment l'API. Sur `dev-2007`, le README annonce **`176 → 0`** en
   gras ; avec la règle que le projet applique déjà à UltraDefrag, l'outil de XP
   en laisse **42 cassés et 43 651 morceaux**. Le chapitre NTFS du README
   compare donc deux algorithmes *et* deux règles.

---

## L'ordre des travaux

Les dépendances comptent autant que les priorités : trois corrections d'ici
changent une durée de démarrage, et deux autres n'ont de sens qu'après une
troisième.

**Lot 1 — les fautes, indépendantes les unes des autres.**

1. F1, recouvrement de `Windows95Strategy` : trois lignes (`blockedHere`,
   la frontière saute la place, le trou reste comme en 1995) **plus une
   assertion `volume.bitmap.isFree(target)` valable pour les huit stratégies**.
   L'audit qui l'a trouvée tient en cinquante lignes et a sa place dans
   `Tests/DefragKitTests`.
2. F2, skew et arrondi : `trackSkew = seek(1)/revolution`,
   `headSkew = headSwitch/revolution`, un `angleOf(position)` unique servant la
   latence **et** le transfert, et `if delta < -1e-9`. Test de non-régression
   évident : *N* requêtes contiguës doivent coûter ce que coûte une requête de
   *N* fois la taille. Il échoue aujourd'hui d'un facteur 3.
3. F3 et F4 : quelques lignes, et F4 accélère la génération.

**Lot 2 — les faits, triviaux, à faire d'un bloc.** E1 à E8. Quatre volumes sur
vingt cessent d'être impossibles.

**Lot 3 — ce qui change une durée de démarrage.** Montage (ne pas lire FAT2, ne
pas lire toute la FAT32, resserrer le montage NTFS de ses 2 Mo d'un trait),
lectures arrondies au cluster (jusqu'à 16× d'amplification sur les volumes de
1996), `$LogFile`, horodatage d'accès, suivi de chaîne FAT32. **Puis recaler
`ThinkModel` une seule fois**, avec les corrections du lot 1 déjà en place.

**Lot 4 — les deux décisions de conception.** Allocation incrémentale et
entrelacement d'abord (c'est elle qui débloque les deux cibles de
`CalibrationTests` sans toucher aux entrées), répertoires ensuite.

**Lot 5 — la défragmentation, une fois les volumes justes.** Trancher la règle
des clusters retenus au niveau de `DefragVolume` ; rendre la zone MFT à
UltraDefrag (le source le dit en toutes lettres : la zone n'est retirée des
régions libres que **sous XP** — dix gigaoctets d'un seul tenant sur
`gamer-2007`) ; évacuer vers le fond du volume dans `Windows95Strategy`, ou
assumer le facteur 12 dans le docstring.

**Lot 6 — l'acoustique**, qui ne dépend d'aucun des précédents : le régime dans
le timbre, le filtre à 18 ms, la recalibration thermique, l'atterrissage des
têtes.

**À ne faire qu'après le lot 1** : plafonner `InstallEra.writeRequestSectors`
à 128 ou 256 secteurs (aucune pile de l'époque n'émettait le mégaoctet actuel).
Avant, le nombre de frontières de requêtes explose et la durée avec.

---

## Ce qui est jugé juste, et qu'aucune correction ne doit casser

À écrire comme tests avant de toucher au reste, faute de quoi les lots 3 et 4
les emporteront sans qu'on le voie :

- **la géométrie zonée** avec conversion LBA→CHS par dichotomie : le débit en
  tombe au lieu d'être postulé, et l'effet « le début du volume est deux fois
  plus rapide que la fin » est gratuit ;
- **la latence rotationnelle angulaire et continue**, contre une horloge absolue
  et non tirée au sort — c'est ce qui fait qu'un fichier éclaté coûte vraiment
  plus cher, et pas seulement statistiquement ;
- **l'ordre LBA** qui remplit tout un cylindre avant de changer de cylindre, et
  la distinction commutation de tête / pas de piste ;
- **la séparation format / pilote** et les trois `FATAllocator.Scan` : le même
  FAT16 servi par MS-DOS ou par VFAT donne deux volumes qui n'ont rien à voir,
  et c'est le pilote qui change ;
- **le plafond de 65 524 clusters comme cause et non comme conséquence** : les
  32 Ko de 1996 ne sont pas une décision, ce sont les entrées d'une table sur
  16 bits — et le slack qui en découle est mesuré (12,3 % sur `dev-1996`) ;
- **l'ordre de `replaceViaTemporary`** : écrire le temporaire pendant que
  l'original occupe encore ses clusters. Cet ordre est faux dans la plupart des
  modèles ; il est juste ici ;
- **lire un fichier fragmenté sur FAT16 ne coûte pas d'accès à la table**,
  parce que la FAT entière était en mémoire. Beaucoup de simulations se trompent
  là-dessus ;
- **la coalescence qui ne trie pas** les extents, donc préserve l'ordre logique,
  et `fragmentCount` qui compte les morceaux et non les extents ;
- **`FindBestItem` et `FindHighestItem`** rendus avec leur rembobinage et leur
  `TotalItemsSize` mesuré contre le trou entier — relus ligne à ligne contre
  `JkDefragLib.cpp`, y compris le tri qui contredit son propre commentaire ;
- **la borne de visites ne mord pas** : `perfectFitsExhausted` vaut zéro sur les
  vingt volumes, pic à 88 954 visites pour un budget de 2 000 000. Le
  remplacement du chronomètre de l'original par un compteur — indispensable au
  déterminisme — ne coûte aucune divergence. C'est vérifié, pas supposé ;
- **la sortie de la zone MFT par `Fixup`** : sur `dev-2007`, JkDefrag ramène à
  zéro les 697 297 clusters ordinaires posés dans la zone, là où XP et
  UltraDefrag les y laissent tous. Et **la garantie du tassage à la frontière**
  tient : sur les douze volumes FAT, aucune écriture sur une donnée encore
  référencée, aucun recouvrement final ;
- **les modes acoustiques à fréquences fixes** avec seule l'excitation qui
  varie : c'est ce qui sépare une simulation d'un échantillon transposé.

---

## Ce qui reste à trancher sur source

Quatre points donnés comme hypothèses par les relecteurs eux-mêmes. Aucun ne
doit être corrigé « au jugé » — c'est justement la règle du projet.

| question | qui en dépend |
|---|---|
| que fait `FSCTL_MOVE_FILE` d'un `ClusterCount` qui dépasse la fin du fichier — refus ou troncature ? | **135 des 551 tranches de `famille-1999`**, et `famille-1999` est le volume où JkDefrag fait son plus mauvais score de la galerie (874 → 479). L'hypothèse la moins solide du portage décide du résultat le plus défavorable |
| `dfrg.msc` respectait-il la zone MFT ? | certitude acquise pour UltraDefrag seulement ; le noyau cède la zone dès ~87 % de remplissage, ce que le générateur modélise déjà |
| le piste-à-piste du Fireball 1080AT — 3,0 ms, la même valeur ronde que le Conner de 1993 | le grain du crépitement, et 16,3 % du temps de lecture séquentielle passé en franchissements contre 5 à 8 % attendus |
| la position de `$MFT` selon la version de Windows et la taille du volume | tout le son d'un démarrage NTFS vient de l'aller-retour enregistrement MFT → données |

---

## Laissé ouvert

- **Rien n'a été corrigé.** La branche `experts` ne porte que les trois revues.
- **Les trois périmètres sont disjoints, donc la couche audio n'a été relue que
  d'un côté** : la mécanique, par l'expert disque. Le rendu, la carte et
  l'interface n'ont eu aucun relecteur.
- **Les mesures des revues sont datées du commit `b1d8e09`** pour la
  défragmentation et de `develop` pour le reste. Elles vieilliront comme ont
  vieilli les chiffres des docstrings — c'est exactement le défaut qu'elles
  signalent. Le test qui régénère ses propres chiffres vaudrait mieux qu'une
  relecture de plus.
- **Deux estimations de coût manquent** : ce que l'allocation incrémentale fait
  au temps de génération des vingt volumes, et ce qu'un cache de piste fait au
  temps de rendu d'une passe. Les deux sont dans le chemin chaud.
