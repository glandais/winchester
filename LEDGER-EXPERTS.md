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
`ThinkModel`**, avec les corrections du lot 1 déjà en place — une fois ici, et
une dernière fois au lot 7, qui est le seul autre à faire tomber le séquentiel.

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

**Lot 7 — le cache du disque**, que les trois revues ne rangeaient nulle part et
qui est pourtant le troisième des priorités de l'expert disque : « le plus gros
écart conceptuel restant entre ce modèle et un disque réel » (§4.1). Il vient en
dernier parce qu'il refait tomber tout le séquentiel, donc qu'il **rouvre le
calage de `ThinkModel`** — et c'est lui qui le refermera pour de bon.

Quatre mécanismes, qui sont un seul objet :

1. **la lecture anticipée.** Après une lecture, le disque continue de remplir
   son tampon jusqu'à la fin de la piste ; la requête séquentielle suivante est
   servie **à la vitesse du bus, sans latence rotationnelle ni pas de piste**.
   C'est le mécanisme qui, sur un vrai disque, masquait exactement le tour perdu
   corrigé au lot 1 — et c'est pour cela que le corriger sans lui laisse le
   séquentiel trop lent d'un côté et le calage trop haut de l'autre ;
2. **la lecture sans latence** : sur une requête d'une piste entière, le disque
   commence à lire au secteur qui se présente et réordonne dans le tampon. La
   latence moyenne d'une grosse lecture n'est donc pas un demi-tour ;
3. **le cache d'écriture**, activé par défaut sur IDE dès la fin des années 90 :
   une petite écriture est acquittée immédiatement et vidée plus tard, par
   paquets triés. Aujourd'hui toute écriture est synchrone, ce qui allonge les
   installations et les journées, et surtout leur donne un rythme régulier là où
   le vrai disque produisait des **salves** ;
4. **la taille du tampon**, qui est une fiche et non un réglage : 128 Ko
   segmentés sur le Fireball de 1996, 2 Mo sur le Barracuda ATA IV, 16 Mo sur le
   7200.10. C'est elle qui date un disque à l'oreille autant que son régime.

Il faut lui adjoindre ce que §4.2 signale et qui n'a de sens qu'avec lui : **le
débit du bus n'est jamais une borne**. Un cache qui sert « à la vitesse du bus »
exige qu'on sache laquelle — et pour un 1993 en PIO mode 2 (8,3 Mo/s crête, 2 à
3 Mo/s utiles derrière un 486) c'est le bus qui commande, pas le plateau. Le
**coût par commande** (0,1 à 0,3 ms, et bien davantage en PIO où le processeur
transfère mot à mot) vit au même endroit, dans `DriveReference` plutôt que dans
le temps de réflexion du système.

**Deux caches logiciels attendent au même endroit**, tous deux repoussés par un
chantier qui a buté dessus : `SMARTDRV`, que le démarrage de 1993 charge, qui
lisait par éléments de 8 Ko et anticipait (chantier 22, M3) ; et **VCACHE**,
dont l'éviction manque pour que le suivi de chaîne FAT32 produise les *retours
périodiques* à la table que la revue décrit, et non la seule première lecture de
chaque page (chantier 22, M1). Ce sont trois caches différents — celui du
disque, celui du pilote, celui du système — et c'est le premier qui décide des
deux autres.

**Ce qu'il faut mesurer avant de recaler** : un cache déplace le coût d'une
lecture séquentielle vers zéro, donc il **révèle** ce que le plancher processeur
vaut vraiment. Si, après lui, `perMegabyte` doit encore monter pour tenir les
cibles, c'est que les cibles elles-mêmes sont à rediscuter — elles ne sont pas
des mesures d'époque, mais les durées que le modèle donnait avant la relecture.
Ce lot est le bon endroit pour le dire.

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
- **Le cache du disque n'était dans aucune des trois listes de priorités
  ordonnées**, alors que l'expert disque le classe troisième dans sa prose. Il a
  été ajouté en lot 7 après coup, une fois que trois chantiers de suite eurent
  buté dessus : le tour perdu qu'il masquait (lot 1), l'éviction qui manque au
  suivi de chaîne FAT32 et `SMARTDRV` (lot 3), et le calage de `ThinkModel` qu'il
  rouvrira (lots 3 et 4). Une revue dit où regarder ; elle ne dit pas dans quel
  ordre, et l'ordre s'est révélé à l'usage.

---

## Le solde — ce que huit lots ont fait des trois revues

Écrit à la fin du lot 7, le 18 septembre 2026, soldé au lot 8 le même jour,
relu de l'extérieur le 19 (`AUDIT-EXPERTS.md`) et corrigé au lot 9. Les trois
relectures ont été dépouillées ici en sept lots, plus un huitième fait de ce
qu'aucun n'avait pris ; chacun est devenu un chantier de `LEDGER.md`, qui dit ses
décisions, ses sources et ses mesures. Le neuvième est celui de l'audit : il ne
reprend pas les revues, il rend vrai ce que ce solde en disait. Ce qui suit n'en
répète pas le détail : c'est le compte de ce que les revues demandaient, et de
ce qu'il en reste.

L'audit résumait ce solde, tel que le lot 8 l'avait laissé, en une phrase :
**honnête sur ce qu'il compte, et faux sur ce qu'il croit avoir compté.** Trois
conditions le rendaient vrai — la liste de ce qui reste, la conclusion sur les
cibles de démarrage, la prose du README. Elles sont levées au lot 9 ; ce qui ne
l'est pas est dit comme tel, et l'audit porte l'état de chacune de ses
trouvailles.

| lot | chantier | commit | ce qu'il a fait |
|---|---|---|---|
| 1 | 20 | `f6e29dc` | les quatre fautes : le recouvrement de `Windows95Strategy`, le skew et l'arrondi de latence, le curseur système, la MFT en miettes |
| 2 | 21 | `2f2fb41` | les huit erreurs de fait, de `clusterKB` de 1993 à la commutation de tête |
| 3 | 22 | `baa33b8` | le montage, la lecture à la page, `$LogFile`, la date de dernier accès, le suivi de chaîne FAT32 ; premier recalage |
| 4 | 23 | `3a1a250` | l'écriture par paquets et les répertoires ; l'entrelacement écrit, mesuré et coupé |
| 5 | 24 | `50b5150` | la règle NTFS des clusters retenus portée par le volume, la zone MFT d'UltraDefrag, Windows 95 qui évacue au fond, les répertoires FAT que Windows ne déplace pas, la tranche bornée, les chiffres des docstrings |
| 6 | 25 | `f4c64d2` | le régime dans le timbre, les trains de micro-transitoires, la mise sous tension en trois temps, la recalibration thermique, la coupure et l'atterrissage |
| 7 | 26 | `a2af0e6` | le tampon du disque et sa fiche, le bus et le coût de commande, `SMARTDRV`, l'éviction de VCACHE ; le recalage final |
| 8 | 27 | `d72aa81` | le reste : les constantes de `NTFSAllocator` mesurées et dites, l'extension cherchée près du fichier, le débit comparé à ce que la fiche mesure, le settle d'écriture, le plafond des requêtes, les deux indices morts, la place du format, `$Bitmap`, les numéros de MFT, l'arrondi à la page |
| 9 | 29 | ce commit | l'audit du solde : la prose du README tirée des bilans, quatre tests armés, une cinquième faute trouvée par l'un d'eux et corrigée, `ThinkModel` recalé pour 2003 et 2007, l'horloge des points de contrôle tirée du catalogue, les constantes non sourcées déclarées, le journal sorti du code |

### Ce qui a été corrigé

- **Les quatre fautes** (F1 à F4), toutes au lot 1, chacune avec un test qui
  échouait avant. F2 — le tour de plateau perdu — a été corrigé deux fois : par
  le skew, au lot 1, qui rendait la mécanique idéale ; puis par la lecture
  anticipée, au lot 7, quand le coût de commande a rendu le tour au disque et
  qu'il a fallu ce que les vrais disques avaient pour le masquer. Le lot 9 l'a
  vérifié sur le disque qu'on écoute : avec le tampon d'époque, découper une
  lecture contiguë ne coûte rien, à 10⁻¹⁶ s près.
- **Une cinquième, de la famille de F1**, trouvée au lot 9 par l'audit
  d'allocation enfin rejoué sur la galerie : une destination qui recouvre un
  morceau du même fichier pas encore lu l'écrasait (`DefragOperations.move`).
  Le chantier 20 l'avait vue sur un volume construit à la main, et la croyait
  absente de la galerie ; Windows 95 la déclenchait sur huit volumes sur vingt,
  jusqu'à 111 195 clusters sur `famille-2007`. Les tronçons sont désormais
  copiés dans l'ordre d'un `memmove`.
- **Les huit erreurs de fait** (E1 à E8), toutes au lot 2, contre une table de
  `FORMAT`, une fiche ou la documentation de NTFS. Une mesure de la revue a été
  corrigée au passage : l'inversion de la commutation de tête touchait cinq
  fiches sur huit, pas six. E6 corrige l'inversion, pas la valeur : six
  dixièmes du pas de piste sont un ordre de grandeur, que le seul manuel
  publiant les deux temps — le Fireball, 3,0 ms chacun — contredit (lot 9).
- **Les deux manques structurels** : l'allocation incrémentale et les
  répertoires, au lot 4 ; l'entrelacement, écrit, n'est pas retenu (plus bas).
- **Ce que le modèle ne faisait pas, et qui s'entend** : le cache et la lecture
  anticipée (lot 7), `$LogFile` et l'horodatage d'accès (lot 3), la
  recalibration thermique, le régime dans le timbre et le filtre à 18 ms (lot 6),
  le coût de commande et le débit du bus (lot 7), le settle d'écriture (lot 8),
  lu dans les colonnes « Write » des manuels.
- **Les quatre recoupements** : la calibration qui absorbait les artefacts a été
  recalée aux lots 3 et 7, une seule fois par lot, après toutes ses
  corrections, puis au lot 9 pour 2003 et 2007 seulement ; la règle de volume des clusters retenus est portée par le
  volume (lot 5) ; les chiffres de docstrings ont une règle (lot 5 : un fait de
  galerie en sort, un chiffre de réglage reste daté). Le deuxième — le réglage
  de fragmentation que `NTFSAllocator` portait sans le dire — est mesuré et
  écrit dans son en-tête au lot 8. La mesure corrige la revue sur un point :
  les constantes ne poussent pas toutes vers la contiguïté — élargir la
  tolérance ou l'horizon réduit la fragmentation —, et c'est l'horizon qui
  décide le plus (de 4,6 à 21,2 % sur `famille-2003`).

**Ce qui était jugé juste** n'a été retiré par aucun lot ; plusieurs points ont
été revérifiés en passant, et tiennent : la borne de visites de `FindBestItem`
(pic de 197 609 pour deux millions, lot 5), la sortie de la zone MFT par
`Fixup`, la garantie du tassage à la frontière, les modes acoustiques à
fréquences fixes (lot 6). La garantie du tassage n'était rejouée que sur un
volume d'essai de seize mille clusters ; depuis le lot 9 elle l'est sur les
vingt volumes, avec tous les plans de l'application, et elle tient — c'est ce
rejeu qui a trouvé la cinquième faute, chez Windows 95.

### Ce qui a été écarté, et pourquoi

- **L'entrelacement** (lot 4). Mesuré, il donnait à tous les programmes d'une
  journée le même débit et les faisait écrire ensemble du matin au soir : une
  borne haute, comme l'écriture en séquence est une borne basse. Trancher entre
  les deux demande un débit par programme et une heure dans la journée, que la
  chronologie n'a pas. Décision prise avec Gabriel, sur les mesures.
- **Le parcage d'une seconde** (lot 6) n'a pas été « nommé comme une licence »,
  comme la revue le proposait en premier : il a été remplacé par ce qui
  produisait ce son, la coupure.
- **La phrase « une bonne minute pour un Vista »** (lot 3) a été retirée plutôt
  que corrigée : elle promettait ce que les cibles ne disaient pas.
- **Le facteur de format sur le débit** (lot 8). Mesuré, il n'avait pas lieu
  d'être : les secteurs par piste du modèle sont déduits de la capacité, ce
  sont déjà des secteurs de données. L'écart toujours du même côté venait de
  la comparaison — un débit brut contre le débit d'une lecture séquentielle,
  qui paie ses commutations. Comparée à ce que la fiche mesure, la lecture
  simulée tombe à −6,5, +3,1 et +5,7 %, et la tolérance est passée à 10 %. Un
  0,90 aurait mis deux disques sur trois à −16 %.
- **`growthMarginClusters`** (lot 8) a été retiré, pas mesuré à 0 et 16 : il
  ne changeait aucun cluster, les huit empreintes NTFS le prouvent.
- **La commutation de tête prise au Fireball** (lot 9) : un seul manuel publie
  les deux temps, et en faire la règle des huit fiches serait tourner une
  constante sur un point. Déclarée, mesurée (0 à 0,8 s par démarrage), pas
  changée.
- **`yieldMFTZone` quand la MFT a débordé** (revue système, § 6.6) : la zone ne
  cède pas « tout d'un coup » mais la moitié de ce qui lui reste, comptée depuis
  son début. La lecture de la revue était fausse ; le docstring le dit.

### Ce qui reste

**Les quatre questions à trancher sur source**, une par une :

| question | état |
|---|---|
| `FSCTL_MOVE_FILE` et une tranche qui dépasse la fin du fichier | **tranchée** au lot 5 : bornée, pas refusée — `FatComputeMoveFileParameter` (`fastfat`) et la page *Defragmenting Files* de Microsoft |
| `dfrg.msc` respectait-il la zone MFT ? | **hypothèse**, argumentée au lot 5 (oui) ; un désassemblage ou un témoignage d'époque trancherait |
| le piste-à-piste du Fireball, 3,0 ms | **tranchée** au lot 7 : c'est la valeur publiée — fiche TULARC du 540/1080AT (« 12.0/3.0 ms »), manuel du Fireball TM (« Track-to-track Typical 3.0 ms, Maximum 4.0 ms »). Les 16 % du temps de lecture passés en franchissements sont ceux de la fiche |
| la position de `$MFT` selon la version de Windows et la taille du volume | **ouverte** |

**Les trois cibles de calibration** restent manquées depuis le lot 2 :
`dev-1996` à 8 % de fichiers fragmentés (35 à 50 visés), `secretaire-1999` à 6 %
(15 à 25), `famille-2003` à 8 % (40 à 60 ; 13 % jusqu'au lot 7). Le lot 8 a
montré qu'aucune des constantes de `NTFSAllocator` n'en rapproche la dernière. Elles se jouent entre la borne basse
livrée et la borne haute de l'entrelacement. Le lot 7 y ajoute une conséquence :
la pénalité de fragmentation d'un démarrage ne s'est pas creusée avec la lecture
anticipée, comme la revue le prédisait, parce que les fichiers qu'un démarrage
lit sont presque tous d'un seul tenant — le même manque, vu d'ailleurs.

**L'entrelacement**, écrit et coupé au lot 4 : le code est là, derrière
`DiskGenerator.runsProgramsConcurrently`. Depuis le lot 9, `Simulator` n'a plus
de valeur par défaut : seuls les trois tests du tourniquet le demandent.

**Les estimations du lot 6**, à trancher sur source : la période et le motif de
la recalibration thermique, les 24 commutations du moteur par tour, le seuil
d'atterrissage à 40 % du régime, les 50 ms du décollement, le palier fluide en
2001 pour toute la galerie, la conversion dBA → bels du Conner, les bandes et le
battement du roulement ; et le niveau des seeks, qui oblige à une licence de
mixage du plateau. Celui-là n'est pas « calé sur rien » : les manuels du dossier
donnent la puissance acoustique en seek à côté de celle du repos (U8 3,5 B contre
3,2, ATA IV 2,8 et 3,3, 7200.7 3,4, 7200.10 3,2, 7200.11 3,2). Le sourcer
changerait le son ; c'est un chantier d'écoute.

**Les hypothèses du lot 7** : la lecture sans latence — pour **toutes** les
fiches qui l'ont, le Fireball compris, dont le « Read-on-arrival » qualifie un
seek et non un réordonnancement —, la segmentation des Seagate, qui est une
file là où le Conner annonce « au plus anciennement utilisé », la profondeur de
la lecture anticipée, le coût de commande hors de 1999 (avant comme après), le
bus des machines de 2003 et 2007, la mémoire de la machine de 1993 et la taille
de VCACHE, un cache d'écriture que le système ne vide jamais.

**Les cibles de durée de démarrage** ne sont pas des mesures d'époque : ce sont
les durées que le modèle donnait avant la relecture, et caler dessus revient à
demander au modèle corrigé de retomber sur le modèle fautif. Le lot 7 avait
monté le coût au mégaoctet de XP et de Vista (0,19 → 0,20, 0,15 → 0,16) et en
concluait que le cache révélait un plancher processeur plus lourd. C'était un
disque à qui manquaient les seeks de MFT que le lot 8 lui a rendus : à `HEAD` du
lot 8, l'ajustement **redescend** à 0,192 et 0,148. Le lot 9 a recalé à 0,19 et
0,15, sur décision de Gabriel — le lot 7 avait compensé un manque que le lot 8 a
corrigé. Le **niveau**, lui, reste injustifié : 0,15 s par mégaoctet pour un
Vista, à peine sous un XP sur des processeurs trois ou quatre fois plus
rapides. Il date du lot 3 (0,09 → 0,15), et seules des mesures d'époque le
trancheraient.

**Ce qu'aucun lot n'a pris.** Le solde du lot 8 disait « plus rien ». C'était
faux : il soldait une liste que personne n'avait refaite depuis les revues.
L'audit l'a refaite (`AUDIT-EXPERTS.md`, § 4) ; la voici, chaque ligne avec son
état.

*Demandes de la revue système de fichiers, ni faites ni écartées par écrit
jusqu'au lot 9* :

| § de la revue | demande | état |
|---|---|---|
| § 8 n° 14, § 6.8 | un fichier résident compte 1 Ko de MFT dans le remplissage ; `SizeModel` descend sous 700 octets | **en attente.** `secretaire-2007` compte 0 résident sur 17 011 fichiers, et seuls les profils développeur en ont (864 sur `dev-2003`, 947 sur `dev-2007`) : la résidence, le trait distinctif de NTFS, reste décorative. Elle change les volumes, donc tout ce qui s'y mesure |
| § 6.6 | `yieldMFTZone` quand la MFT a débordé | **écartée** au lot 9 : la zone cède la moitié de ce qui lui reste, pas tout (plus haut) |
| § 5.6 | le commentaire de `fromVolumeStart` ; le hint de MS-DOS remis à zéro chaque journée | **commentaire corrigé** au lot 9 ; la remise à zéro par journée **en attente** — elle change les volumes de 1993 |
| § 4.2 | `$UsnJrnl`, réécrit en continu sous Vista, et `$Secure` | **en attente**, dit dans le README (« Ce qui ne l'est pas ») |
| § 4.4 | `$ATTRIBUTE_LIST` pour les fichiers aux extents trop nombreux ; les liens physiques de WinSxS comptés comme des copies | **en attente**, dits dans le README |
| § 4.4 | compression, fichiers creux, flux additionnels : « défendable, à dire » | **dit** dans le README au lot 9 |
| § 7 | numéro de MFT distinct du rang d'écriture | fait au lot 8 pour le démarrage et les défragmenteurs ; **en attente** pour `MachineWriter` et `InstallSession`, qui numérotent encore par rang |

*Points qu'un chantier avait laissés ouverts sans qu'ils remontent ici* :

| chantier | point | état |
|---|---|---|
| 20 | le second recouvrement de `DefragOperations.move` | **corrigé** au lot 9 — c'était une faute, et la galerie la déclenchait |
| 20 | `DEFRAG.EXE` déplaçait par tronçons, pas par fichiers entiers ; la passe de 95 ne fait rien sur les volumes à 99 % | en attente |
| 23 | la racine FAT16 à 512 entrées, que rien n'applique à l'allocation ; trente répertoires pour un XP qui en compte des milliers | en attente |
| 23, 24 | le planificateur du tassage à la frontière, quadratique | en attente |
| 24 | `MoveItem4`, l'entrée `..` des répertoires FAT, l'attente du point de contrôle non jouée | en attente |
| 21 | le piste-à-piste du Conner, emprunté | en attente |
| 25 | la position de départ du bras sur un plateau qui tourne déjà : le moyeu, alors qu'aucun disque de bureau ne s'y parque | **dit** au lot 9 (`DriveGeometry.parkCylinder`, README) ; en attente sur le fond, le modèle ne sait pas où le dernier accès l'a laissé |
| 25, 26, 27 | **l'écoute** : Gabriel n'a rien entendu des lots 6 et 7, ni de ce qui a suivi | en attente — c'est la seule validation qui manque à tout le lot 6, et le troisième journal d'affilée à la porter |

*Trouvés par le lot 8 en faisant le reste, et qui ne sont pas des demandes des
revues* :

- **les requêtes des défragmenteurs** — 4 Mo pour XP et JkDefrag — ne sont pas
  découpées à 256 secteurs comme celles de l'installeur ; le découpage
  appartient à l'interface du disque, où il vaudrait pour tous ;
- **les constantes de `NTFSAllocator`** sont dites et mesurées, pas sourcées,
  et `famille-2003` s'y montre chaotique : trois cents clusters de `$Bitmap`
  l'ont fait passer de 10,5 à 7,6 %. Depuis le lot 9, la table se régénère par
  un test.

*Des constantes que seule la cible justifie*, déclarées au lot 9 dans leur code
et dans le README : la commutation de tête (six dixièmes du pas de piste), la
lecture sans latence, le coût de commande hors de 1999, le paquet d'écriture de
64 Ko de NTFS, le bloc de huit clusters de la MFT, une validation de journal sur
huit, les quatre bornes de recherche de `NTFSAllocator`, les bandes et le
battement du roulement, le délai de coupure et la redescente du plateau (le
Fireball donne dix secondes d'arrêt, le modèle 3,5), le préréglage « Casque »,
seconde licence de mixage. Aucune n'a été tournée ; chacune dit ce qu'elle est.

Le lot 8 a aussi trouvé **une erreur de fait** dans le catalogue — le 7200.10
portait les seeks et le débit des 750 Go —, corrigée sur son manuel, et ajouté
**une hypothèse** : le seek d'écriture du Conner de 1993, que rien ne publie,
est pris au Fireball. Il déplaçait les démarrages NTFS de +3,3 % (2003) et
+4,1 % (2007) par la numérotation MFT : la dérive que le lot 9 a recalée. Un
littéral en dépendait sans le dire — l'horloge des points de contrôle, calculée
sur l'ancienne fiche ; elle est tirée du catalogue depuis le lot 9.

**Ce que les revues n'ont pas relu** : le rendu, la carte et l'interface n'ont
eu aucun relecteur ; la couche audio ne l'a été que du côté de la mécanique.

**Le défaut que les revues signalaient vaut pour elles.** Leurs chiffres
dataient du commit qu'elles relisaient, et presque tous ont changé d'ordre de
grandeur en sept lots — le README a été régénéré d'un seul jeu de mesures à
chaque chantier, et cinq chantiers sur huit y ont trouvé des chiffres de prose
déjà périmés avant d'y toucher. L'audit en a compté dix-sept ; l'outil, une fois
chargé de la prose, en a trouvé davantage. Une relecture dit où regarder ; seul
un chiffre régénéré par l'outil qui le produit reste vrai — et depuis le lot 9,
c'est le cas de la prose du README comme de ses tables
(`readme-tables.py --check`).
