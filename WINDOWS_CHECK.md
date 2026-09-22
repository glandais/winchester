# Winchester contre le code de Windows XP SP1

Relevé du 22 septembre 2026, sur `develop` à `0668029`. Il confronte ce que
l'app affirme ou modélise de Windows au code source de **Windows XP SP1**, tel
qu'il a circulé en 2020 (`/Volumes/glandais/winxpscodes/Source/XPSP1/NT`,
chemins ci-dessous relatifs à ce dossier). Le chantier 45 de `LEDGER.md` avait
déjà pris ce code pour source du défragmenteur de XP, et le projet l'assume :
ce n'est pas une source ouverte. Comme alors, rien n'est recopié ici. On ne
cite que des noms, des constantes, une ligne au plus.

Rien n'a été modifié dans le code : ce fichier ne fait que constater. Une
annexe, en fin de fichier, le croise avec l'audit des lots réalisme
([`AUDIT_REALISME.md`](AUDIT_REALISME.md)) et propose un ordre de traitement.

## Méthode

Un workflow a découpé le sujet en six domaines. Chacun est passé par deux
agents :

1. un **vérificateur** relève les affirmations de l'app (Swift, docstrings,
   `README.md`, `LEDGER*.md`), les confronte au code de XP et rend un verdict,
   avec les références des deux côtés ;
2. un **contradicteur** rouvre chaque référence et cherche à réfuter le
   verdict : mauvaise ligne, code mort, branche qui ne s'applique pas,
   confusion entre XP, 9x et Vista. C'est **son verdict qui fait foi**
   ci-dessous. Il a aussi contrôlé chaque lacune signalée.

Les verdicts :

- **confirmé** : le code de XP le montre ;
- **contredit** : le code de XP fait autrement ;
- **nuancé** : vrai en partie, ou vrai d'une autre façon ;
- **non vérifiable** : le code n'en dit rien. C'est le cas de tout ce qui
  touche MS-DOS, Windows 9x, Vista, 7 et le firmware des disques.

**Portée.** XP ne prouve que XP. Tous les volumes FAT de la galerie datent de
1993 à 1999 : VFAT et MS-DOS n'y figurent pas, et `fastfat` (le pilote FAT de
NT) n'est qu'un **indice** pour eux. Quand un constat FAT dit « contredit »,
c'est la généralisation « toute la famille FAT » qui est visée, pas le modèle
9x.

J'ai relu moi-même les deux constats les plus lourds (placement de `$LogFile`
et de `$Bitmap`, `untfs/src/format.cxx:62, 329-341, 585-593, 617-618`) : ils
tiennent.

## Bilan

| domaine | affirmations | confirmé | nuancé | contredit | non vérifiable | lacunes |
|---|---:|---:|---:|---:|---:|---:|
| Format NTFS et disposition initiale | 21 | 8 | 6 | 5 | 2 | 5 |
| Allocation NTFS au fil de l’eau, croissance de la MFT, FSCTL_MOVE_FILE | 21 | 5 | 9 | 7 | 0 | 7 |
| FAT : format et allocation | 24 | 9 | 11 | 3 | 1 | 7 |
| Le défragmenteur de XP (dfrgntfs, dfrgfat), contre-vérification | 26 | 12 | 10 | 3 | 1 | 6 |
| Démarrage : préchargeur, Layout.ini, optimisation du démarrage, dernier accès | 20 | 6 | 9 | 3 | 2 | 8 |
| Gestionnaire de cache et pile de stockage | 14 | 4 | 8 | 1 | 1 | 5 |
| **total** | **126** | **44** | **53** | **22** | **7** | **38** |

Le vérificateur et le contradicteur ont été d'accord sur 121 verdicts sur 126.
Les cinq désaccords portent tous sur le défragmenteur et le FAT. Trois
« contredit » deviennent « nuancé » : le défaut est réel, mais l'app ne
l'affirme pas là où le vérificateur le voyait. Un « confirmé » devient
« nuancé » (l'ordre de visite de XP). Un « nuancé » devient « confirmé » (la
racine NTFS). Les 38 lacunes signalées tiennent toutes.

## Ce qui compte, par ordre d'effet sur le son

### 1. La disposition d'un NTFS formaté par XP n'est pas celle du modèle

- **`$LogFile` est collé devant `$MFT`**, pas au milieu du volume. Sous
  `LOGFILE_PLACEMENT_V1` (défini à `format.cxx:62`), le journal finit deux
  clusters avant la MFT, et le bitmap de la MFT occupe le cluster juste devant
  elle. Sur 40 Go, le journal est vers 2,94 Gio, pas vers 18,6 Gio. La
  disposition du modèle, avec le journal derrière le miroir, est celle de la
  branche `#else` : du code mort sous XP. `LEDGER.md` laissait « la place de
  `$LogFile` depuis XP » ouverte ; le code la tranche. *(ntfs-format-03)*
- **`$Bitmap` est au milieu du volume**, derrière `$MFTMirr`, avec `$AttrDef`,
  `$UpCase` et l'allocation de l'index racine. Elle n'est pas derrière la
  zone MFT : cette règle-là vient de `mkntfs` (Linux). *(ntfs-format-04)*
- **Conséquence** : le modèle a les deux trajets à l'envers. Il met le trajet
  court (MFT ↔ bitmap) sur l'écriture qui revient à chaque validation, et le
  long sur le journal, écrit une validation sur huit. Sous XP, chaque
  validation paie une demi-course vers la bitmap, et le journal est un seek
  court. Cela touche les douze volumes NTFS de la galerie.
- Pour un volume de moins de 24 Gio (aucun dans la galerie, mais possible
  pour un disque personnalisé), la MFT se place selon trois paliers : au tiers
  du volume sous 2 Gio, à 1 Gio de 2 à 6 Gio, à 3 Gio au-delà. Ce n'est pas
  `min(3 Gio, n/8)`. *(ntfs-format-02)*
- **Confirmé** : `$MFT` à 3 Gio (LCN 786 432), ce qui confirme Sedory ;
  `$MFTMirr` à n/2 et de 4 enregistrements ; FRS de 1 Ko ; `$Boot` de 8 Ko ;
  des clusters de 4 Ko sur la galerie ; un journal de 64 Mio au-delà de
  12 Gio. Ce dernier point est nuancé : entre 400 Mo et 12 Gio, la taille
  suit une rampe continue, pas des paliers.

### 2. Le défragmenteur de XP : ce que le chantier 45 a manqué

Les numéros de ligne cités par le chantier 45 sont tous exacts, et le squelette
de la passe l'est aussi : best fit par taille, arrêt au premier fichier sans
trou, région occupée à moins de 75 %, abandon au onzième échec, tassement vers
l'avant par LCN décroissant, blocs de 64 Kio, pas d'appel à
`PartialDefragNtfs`. En revanche :

- **La validation se fait par bloc de 64 Kio, pas par fichier.** Chaque bloc
  est une transaction : commit dans `$LogFile`, écritures USN, pages de bitmap
  et *mapping pairs*. *(xp-defrag-validation, ntfs-alloc-14)*
- **Ce qu'un déplacement quitte est libre tout de suite pour l'outil.**
  `NtfsDeallocateClusters` efface les bits sur-le-champ, et
  `FSCTL_GET_VOLUME_BITMAP` les montre libres. Un `MOVE_FILE` vers ces
  clusters lève `STATUS_DELETE_PENDING`, et non `ALREADY_COMMITTED`.
  `NtfsDefragFile` l'intercepte (jusqu'à dix fois), vide le journal
  (`LfsFlushToLsn`), libère les clusters retenus et réussit. La règle
  « attendre le point de contrôle de 5 s » de `DefragVolume.swift:325-339`
  vient de Russinovich (NT 4, 1997) et ne décrit pas XP SP1. Elle touche XP,
  JkDefrag et UltraDefrag : la disposition, plus un vidage de journal audible
  à chaque réemploi. *(xp-defrag-point-de-controle, ntfs-alloc-15)*
- **`MFTDefrag` agit plus souvent, et vise ailleurs.** Il agit dès que la
  MFT a **deux** extents (`lMFTFragments > 1`), alors que l'app en exige trois
  (`extents.count > 2`). Il lui faut un trou de la taille de la MFT
  **entière**. Ce trou est cherché **hors de la zone MFT** (`MarkBitMapforNTFS`),
  alors que l'app passe `avoidingMFTZone: false`. Une fois recollée, la MFT de
  l'app n'est plus jamais redéplacée, alors que XP la redéplacerait à chaque
  appel. *(xp-defrag-mft-condition, xp-defrag-mft-zone-cible)*
- **L'optimisation du démarrage passe en premier** sur le volume système :
  `ProcessBootOptimise` vient avant `MFTDefrag` dans toute défragmentation
  manuelle. L'app la met hors modèle, et elle le dit. Mais cette phase ouvre
  la passe : elle lit `Layout.ini`, vide la zone et y range les fichiers de
  32 Mo au plus. *(xp-defrag-mft-avant-apres, boot-12)*
- Détails :
  - `ConsolidateFreeSpace` rend « région parcourue sans abandon », et non
    « au moins un fichier parti » ;
  - le vidage de la zone MFT s'arrête au premier échec ;
  - à taille égale, l'app départage par `id` et non par numéro
    d'enregistrement ;
  - en ligne de commande, les 15 % d'espace libre font plus qu'avertir.
- **Sur FAT, XP lance `dfrgfat`**, un autre moteur : six passes de *first
  fit*, défragmentation partielle, bitmap relue après chaque déplacement, et
  `fastfat` qui déplace par tranches de 256 Kio. L'interface ne propose XP
  que sur NTFS, ce qui est juste. Seules les 12 passes « XP sur FAT » des
  mesures (`STRATEGY=windowsXP` sur FAT) ne représentent aucun outil réel.

### 3. L'allocation NTFS au fil de l'eau

- **Pas de curseur pour un fichier neuf** : `HintLcn = UNUSED_LCN`, et XP
  prend le plus petit run qui convient, au plus bas LCN (« maximum
  left-packing »). Le `searchCursor` du modèle étale les écritures.
  *(ntfs-alloc-02)*
- **Pas de préférence pour l'espace vierge.** Le délai de réemploi tient au
  journal. Les clusters libérés sont masqués jusqu'au point de contrôle, puis
  versés dans le cache des runs libres, où le best fit les prend en premier
  s'ils sont justes. *(ntfs-alloc-03)*
- **Surallocation géométrique** : elle se fait dans `NtfsCommonWrite`, pas
  par le lazy writer, qui est exclu par construction (`write.c:1914`). La
  première extension est exacte, puis ×2, ×4, ×8 et ×16 la taille de
  l'écriture, bornée à `FreeClusters/1024 + demande`. Le surplus est rendu
  à la fermeture. Les « paquets de 64 Ko vidés par le cache » du README
  attribuent le mécanisme au mauvais composant. La traîne en 2 à 16
  morceaux mesurée sur `secretaire-2003` est probablement surestimée.
  *(ntfs-alloc-05, io-cache-06)*
- **La zone MFT ne fait pas que rétrécir.** Elle est recalculée à chaque
  montage, regonflée quand l'espace libre repasse au-dessus d'un seizième
  après une réduction, et reposée ailleurs quand la MFT ne peut plus grandir
  d'un seul tenant. Ce mécanisme « nouvelle zone », l'app le réserve à Vista
  et 7 ; il existe déjà dans XP. *(ntfs-format-10, ntfs-alloc-08, ntfs-alloc-10)*
- **`$MFT` grandit par 16 enregistrements** (`MFT_EXTEND_GRANULARITY`), soit
  4 clusters à 4 Ko, dans la zone comme hors zone. Le modèle prend 8 clusters
  hors zone et 1 dans la zone. Une MFT neuve compte 16 enregistrements, et
  non 32. *(ntfs-alloc-09, ntfs-format-12)*
- **Confirmé** : zone de 12,5 % moins la MFT, posée derrière elle ; moitié
  libre la plus éloignée rendue quand le volume est plein ; aucun seuil de
  remplissage ne l'ouvre avant ; un défragmenteur peut écrire dans la zone
  (l'éviter est un choix de l'outil) ; `MOVE_FILE` par 64 Kio ; point de
  contrôle toutes les 5 s.

### 4. Le démarrage

- **Le préchargeur ne trie pas par position.** `pfsvc` range les sections par
  **premier accès** (`PfSvSortSectionNodesByFirstAccess`). Le noyau lit
  fichier après fichier, dans l'ordre du scénario. Le balayage que l'app joue
  existe pourtant, pour deux raisons. Toutes les lectures partent en
  asynchrone, et `atapi` les sert par LBA croissant (C-LOOK,
  `KeRemoveByKeyDeviceQueue`). Et `defrag -b` aligne l'ordre du disque sur
  celui de `Layout.ini`. Le son peut rester ; il faut changer le libellé
  « range la liste par position ». *(boot-01, boot-02)*
- **Historique de 8 démarrages**, pas 6 (`PF_PAGE_HISTORY_SIZE`), avec une
  sensibilité d'au moins 2. *(boot-03, commentaire seulement)*
- **Une date d'accès n'est pas gratuite.** Elle est journalisée
  (`UpdateResidentValue`) et met aussi à jour l'entrée `$FILE_NAME` dans
  l'index du répertoire parent. Au premier démarrage de la journée, il faut
  compter les pages d'index et un aller-retour vers `$LogFile` en plus des
  pages de MFT. *(boot-15)*
- **Confirmé** :
  - `Layout.ini` au plus tous les trois jours, à l'inactivité : 12 min
    d'inactivité, puis 5 contrôles de 30 s ;
  - le défaut `Enable="Y"` de `BootOptimizeFunction` est attesté par la
    source même, et plus seulement par une copie tierce ;
  - zone de démarrage limitée aux fichiers de 32 Mo, et déplacée quand moins
    de 90 % des fichiers y sont ;
  - date d'accès active par défaut sous XP, avec un grain d'une heure sur
    NTFS et d'un jour sur FAT.
- **Nuancé** :
  - XP ne lit pas « les N premiers Ko » d'un fichier, mais exactement les
    pages tracées ;
  - la trace ne se ferme que 30 s après que le shell est prêt ;
  - la zone de démarrage n'est pas « en tête » : elle part de
    `LcnStartLocation`, ou du plus grand trou.

### 5. Le cache et la pile de stockage

- **Le lazy writer** se réveille bien toutes les secondes. Mais il n'écrit
  qu'environ un **huitième** des pages sales à chaque passage
  (`LAZY_WRITER_MAX_AGE_TARGET`), et son premier passage après un repos n'a
  lieu qu'au bout de 3 s. Il vide aussi les données, pas seulement les
  métadonnées. *(io-cache-01, boot-16)*
- **64 Ko par requête** est juste pour ce qui passe par le cache
  (`MAX_WRITE_BEHIND`, regroupement des fautes). Le plafond ne vient pas du
  pilote de port : `atapi` accepte 128 Ko par SRB, en LBA48 comme sans.
  *(io-cache-02 à 04)*
- **La file n'est pas FIFO.** Il n'y a ni NCQ ni *tagged queuing* : c'est
  confirmé, et XP SP1 n'a pas de pilote AHCI. Mais la file logicielle
  d'`atapi` est triée par LBA dès que plusieurs IRP sont en vol : lecture
  anticipée, lazy writer, préchargeur. *(io-cache-09)*
- **Lecture anticipée** : elle s'active dès la troisième lecture séquentielle,
  ou dès le premier défaut à l'offset 0. Le modèle l'ignore. *(io-cache-05)*
- **Cache du disque** : il n'est jamais vidé par les points de contrôle de
  NTFS ni par la validation d'un déplacement, ce qui est confirmé. En
  revanche, le vidage paresseux du registre (5 s après une modification,
  `ZwFlushBuffersFile`) descend jusqu'à un `FLUSH CACHE`. Sur FAT,
  `FatMoveFile` vide le cache du disque à chaque tranche.
- **Confirmé** : `CopyFile` préalloue la cible ; UDMA/100 est le mode le plus
  rapide de la pile IDE de XP SP1 ; `disk.sys` active le cache d'écriture au
  démarrage.

### 6. FAT

- **Le format sur disque est confirmé** : clusters FAT32 de 4 à 32 Ko selon
  des seuils repris de MS-DOS, deux FAT en miroir, racine FAT16 de 512
  entrées hors des clusters, racine FAT32 au cluster 2, `MOVE_FILE` qui
  refuse le premier cluster d'un répertoire et borne une tranche à la taille
  allouée.
- **Nuancé** :
  - les plafonds de clusters sont de 65 526 en FAT16 et 268 435 446 en
    FAT32 ;
  - FSINFO est au secteur 1 ;
  - des secteurs réservés s'ajoutent pour l'alignement ;
  - la règle de déclenchement des noms longs diffère.
- **Ce que fait `fastfat` et ne montre que comme indice pour 9x** : il
  cherche d'abord une plage contiguë de la taille entière ; il prolonge un
  fichier derrière son dernier cluster ; il suralloue jusqu'à ×32 et rend le
  surplus à la fermeture ; en FAT32, il alloue par fenêtres de 65 536
  clusters ; son curseur recule à chaque libération ; il lit toute la FAT au
  montage. Le modèle 9x n'en est pas contredit, seulement privé d'appui.
- **Un écart qui touche des outils réels** : sur FAT, `FSCTL_MOVE_FILE`
  avance par tranches de 256 Kio. Chaque tranche écrit la FAT avant et après
  la copie, puis vide le cache du disque. JkDefrag (4 Mio) et UltraDefrag
  (`moveAtOnce`), quand on les demande sur FAT, ne suivent pas cette coupe.
  SmartDefrag la suit déjà. *(fat-20, xp-defrag-fat-bloc)*

## Commentaires faux, sans effet sur le son

- `DiskGenerator.swift:339-343` : « `$MFTMirr` ramené près du début par
  Windows 2000 » est faux. XP SP1 le pose encore à n/2, et le code de l'app
  aussi. *(ntfs-format-06)*
- `BootSession.swift:254-256` : « six derniers démarrages » ; c'est 8.
- `NTFSAllocator.swift:135-137` : « ne fait que rétrécir ».
- `DefragVolume.swift:325-339` : la citation de Russinovich décrit NT 4.
- `WindowsXPStrategy.swift:384-393` : « la zone MFT comprise, c'est sa
  réserve » ; XP l'exclut.
- `BootSession.swift:977-979` : « NTFS ne journalise pas une simple date ».
- `FileSystemProfile.swift:190-201` et `README.md:636-643` : le lazy writer
  n'alloue rien.
- `README.md:826-830` et `Explanations.swift:67` : « range la liste par
  position ».

## Ce que XP ne permet pas de trancher

Tout ce qui concerne Vista et 7 : zone de 200 Mo, `$MFTMirr` au LCN 2, seuil
de 64 Mo, ReadyBoot, date d'accès désactivée. Tout ce qui concerne MS-DOS et
9x : VCACHE, SMARTDRV, le scan de DOS, le curseur de VFAT. Et la place
qu'avaient NT 4 et 2000. Sur ce dernier point, la branche `#else` de
`format.cxx` décrit la disposition que le modèle prête à NT : c'est un indice
fort, pas une preuve.

---

# Détail

Chaque entrée donne l'affirmation de l'app, les références (app, puis XP),
le constat du vérificateur, l'effet sur le modèle et la contre-vérification.
Quand ils diffèrent, le verdict du vérificateur est indiqué entre
parenthèses.

## Format NTFS et disposition initiale


### `ntfs-format-01` — confirmé

**Affirmation.** Depuis XP, FORMAT pose $MFT à 3 Gio du début (LCN 786 432 en clusters de 4 Ko).

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:85-87, 333-339 ; README.md:669-671`
- XP : `base/fs/utils/untfs/src/format.cxx:591-592 (et :62)`
- Extrait : « MftLcn = (3 * ONE_GB) / ClusterSize; // put it at 3GB for now »

**Constat.** Sous LOGFILE_PLACEMENT_V1 (défini en tête de format.cxx), MftLcn = 3 Gio / taille de cluster pour un volume d'au moins 6 Gio. Avec des clusters de 4 Ko, cela donne 786 432 = 0xC0000. La valeur que le LEDGER tenait d'une seule source secondaire (Sedory) est donc attestée par le code de FORMAT. Tous les NTFS XP de la galerie (40 et 80 Go) tombent dans cette branche.

**Effet.** Aucun pour la galerie.

**Contre-vérification.** Relu format.cxx:62 (#define LOGFILE_PLACEMENT_V1 1) et 587-593 (#if LOGFILE_PLACEMENT_V1 : branche active). MftLcn = 3*ONE_GB/ClusterSize si le volume fait au moins 6 Gio, sans /CVTAREA. 0xC0000000/4096 = 786 432. Côté app, NTFSAllocator.swift:85-87 et 333-339 et README.md:669-671 disent bien cela.


### `ntfs-format-02` — contredit

**Affirmation.** Sur un volume de moins de 3 Gio… en fait de moins de 24 Gio, le modèle pose la MFT au huitième du volume (min(3 Gio, n/8)) ; « une règle du modèle ».

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:333-340, 94-95`
- XP : `base/fs/utils/untfs/src/format.cxx:587-593`
- Extrait : « if (sectors < 2GB) MftLcn = (sectors / 3) / ClusterFactor; else if (< 6GB) MftLcn = ONE_GB / ClusterSize; »

**Constat.** XP a trois paliers, pas un minimum. Sous 2 Gio : MftLcn = secteurs/3, soit le tiers du volume. De 2 à 6 Gio : 1 Gio. À partir de 6 Gio : 3 Gio. Le min(3 Gio, n/8) du modèle place donc mal $MFT pour tout volume XP de moins de 24 Gio. Par exemple, sur 10 Gio, le modèle la met à 1,25 Gio, là où XP la met à 3 Gio ; sur 4 Gio, le modèle dit 0,5 Gio et XP 1 Gio.

**Effet.** Aucun volume de la galerie n'est concerné (tous font 40 Go ou plus). En revanche, un disque personnalisé en NTFS de moins de 24 Gio a une MFT trop près du bord, ce qui fausse l'aller-retour MFT ↔ données, la durée des démarrages et la zone de données devant la MFT.

**Contre-vérification.** Côté app, threeGibibytes = min(3 Gio, clusterCount/8) (NTFSAllocator.swift:336-338) : n/8 < 3 Gio tant que n < 24 Gio, donc l'écart couvre bien tout ce qui est sous 24 Gio. Côté XP (format.cxx:587-593), trois paliers : sectors/3 sous 2 Gio, 1 Gio de 2 à 6 Gio, 3 Gio au-delà. Les exemples (10 Gio : 1,25 contre 3 ; 4 Gio : 0,5 contre 1) sont justes.


### `ntfs-format-03` — contredit

**Affirmation.** $LogFile suit $MFTMirr au milieu du volume sous XP, Vista et 7. Aucune source ne place le journal, c'est un choix du modèle (question laissée ouverte par le LEDGER).

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:318-331, 93-95 ; README.md:678-680`
- XP : `base/fs/utils/untfs/src/format.cxx:617-618, 329-336 ; base/fs/utils/untfs/src/logfile.cxx:231-232`
- Extrait : « LogFileNearLcn = MftLcn - ((MFT_BITMAP_INITIAL_SIZE + (ClusterSize - 1))/ClusterSize); … SetNextAlloc(NearLcn - ClustersInData) »

**Constat.** Le code de XP tranche la question. LogFileNearLcn vaut MftLcn moins les clusters réservés au bitmap de la MFT (8 Ko, donc 2 clusters à 4 Ko). CreateDataAttribute place ensuite le début du journal à NearLcn − ClustersInData. $LogFile finit donc 2 clusters avant $MFT, et le bitmap de la MFT occupe le cluster juste devant elle. Le schéma en tête de fonction le dit aussi : « 3GB || n/3 $LogFile, $Mft Bitmap, $Mft ». Sur 40 Go, XP met le journal vers 2,94 Gio, collé à la MFT, et non vers 18,6 Gio. La disposition du modèle (journal derrière le miroir) est celle de la branche #else, que XP n'utilise plus.

**Effet.** Change le son. Sous XP, la page de journal écrite une validation sur huit et la zone de redémarrage lue et écrite au montage sont à quelques dizaines de Mo de la MFT : un seek court. Le modèle, lui, envoie le bras au milieu du volume à chaque page de journal et à chaque montage. Les rafales espacées que décrit VolumeLayout sont, sous XP, des retours courts vers la MFT et non de longues courses.

**Contre-vérification.** Chaîne vérifiée. format.cxx:618 : LogFileNearLcn = MftLcn − ceil(8 Ko/cluster), soit MftLcn−2. format.cxx:716-717 : LogFile.Create(…, LogFileNearLcn, …) dans le bloc V1, avant MftReflection (757). La création derrière le miroir (794) est sous #if !defined(LOGFILE_PLACEMENT_V1), donc du code mort. logfile.cxx:231-232 : SetNextAlloc(NearLcn − ClustersInData). ntfsbit.cxx:459-460 : NearHere==0 donne _NextAlloc, et la recherche va vers l'avant. mftfile.cxx:291-293 pose le bitmap de la MFT à _FirstLcn − ClustersInMftBitmap (1 cluster). Sur 40 Go, le journal va du LCN 770 046 à 786 429 (≈2,94 Gio), puis un cluster libre, le bitmap de la MFT, et $MFT. Référence complète : format.cxx:329-336, 616-618, 715-718 ; logfile.cxx:223-233 ; mftfile.cxx:289-293.


### `ntfs-format-04` — contredit

**Affirmation.** $Bitmap est posée derrière la zone MFT d'origine, « là où mkntfs la pose ». Le simulateur y lit et y écrit la table à chaque validation.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:286-293, 344-346 ; Sources/Model/VolumeLayout.swift:336-338 ; README.md:685-686`
- XP : `base/fs/utils/untfs/src/format.cxx:337-341, 991 ; base/fs/utils/untfs/src/ntfsbit.cxx:452-454, 585`
- Extrait : « if (NearHere == 0) { NearHere = _NextAlloc; } … _NextAlloc = first_allocated_lcn + RunLength; »

**Constat.** Sous XP, l'allocateur de FORMAT (NTFS_BITMAP::AllocateClusters) cherche vers l'avant à partir de _NextAlloc, qui avance à chaque allocation. $MFTMirr est allouée au milieu du volume (secteurs/2). $AttrDef, l'index de la racine, $Bitmap puis $UpCase sont créés ensuite sans LCN imposé, donc juste derrière le miroir. Le schéma de format.cxx le dit : « n/2 $MftMirr, $AttrDef, $Bitmap, $UpCase, root index allocation ». La règle « derrière la zone » vient de mkntfs (Linux), pas de FORMAT.

**Effet.** C'est l'effet le plus audible du domaine. À chaque validation NTFS, le modèle enchaîne un enregistrement MFT (3 Gio) et un secteur de $Bitmap (vers 7,7 Gio sur 40 Go) : un aller-retour court. Sous XP, $Bitmap est vers 18,6 Gio : une demi-course à chaque validation. Avec ntfs-format-03, les rôles sont inversés. Le modèle met le trajet court sur la bitmap, qui revient à chaque validation, et le long sur le journal, écrit une fois sur huit. XP fait l'inverse.

**Contre-vérification.** mftref.cxx:182 alloue le miroir à n/2 ; ntfsbit.cxx:585 fait avancer _NextAlloc derrière lui. $AttrDef (format.cxx:904) et l'index racine (951) viennent ensuite, puis $Bitmap (991). bitfrs.cxx fait Extents.Resize : extents.cxx:835-846 appelle AllocateClusters(QueryLastLcn()=0 sur une liste vide), donc part de _NextAlloc, juste derrière le miroir. Le schéma de format.cxx:337-341 le confirme. Côté app, la place « derrière la zone » est bien écrite à NTFSAllocator.swift:286-293 et 344-346, VolumeLayout.swift:336-338 et README.md:685-686. Sur 40 Go : ≈7,7 Gio dans le modèle, ≈18,6 Gio sous XP.


### `ntfs-format-05` — confirmé

**Affirmation.** $MFTMirr est au milieu du volume sous XP (et NT 4, Vista), et fait 4 Ko, soit un seul cluster à 4 Ko : la copie des quatre premiers enregistrements.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:309-316, 105`
- XP : `base/fs/utils/untfs/src/mftref.cxx:177-182 ; base/fs/utils/untfs/inc/untfs.hxx:66`
- Extrait : « VolumeBitmap->AllocateClusters( (QueryVolumeSectors()/2)/ClusterFactor, … ) ; #define REFLECTED_MFT_SEGMENTS (4) »

**Constat.** Pour XP, c'est exact. REFLECTED_MFT_SEGMENTS vaut 4, la taille en clusters est arrondie au-dessus de 4 × taille d'un FRS, et l'allocation part de (secteurs du volume / 2) / facteur de cluster. Pour NT 4 et Vista, XP n'est qu'un indice.

**Contre-vérification.** mftref.cxx:177-182 et untfs.hxx:66 (REFLECTED_MFT_SEGMENTS 4) relus. 4 × 1 Ko = 1 cluster à 4 Ko, à (secteurs/2)/facteur. Le modèle, lui, pose clusterCount/2 (NTFSAllocator.swift:309-316) : même point, puisque les clusters valent (secteurs−1)/facteur. Confirmé pour XP seulement.


### `ntfs-format-06` — contredit

**Affirmation.** Docstring de DiskGenerator.formatting : « $MFTMirr est au milieu du volume jusqu'à NT 4, ramené près du début par NTFS 3.0 — c'est-à-dire par Windows 2000, et non par XP ».

- App : `Sources/DiskCore/DiskGenerator.swift:339-343`
- XP : `base/fs/utils/untfs/src/mftref.cxx:182`
- Extrait : « AllocateClusters( (QueryVolumeSectors()/2)/ … »

**Constat.** Le FORMAT de XP SP1 (NTFS 3.1), postérieur à 2000, pose encore le miroir à secteurs/2. Il n'a donc pas été ramené près du début par 2000. Le code de l'app ne suit d'ailleurs pas ce commentaire : Formatting.mirrorInTheMiddle vaut vrai pour .nt, .xp et .vista. Le commentaire contredit à la fois le code de l'app et celui de XP.

**Effet.** Aucun sur le son : le commentaire est seulement trompeur. En revanche, un disque personnalisé daté de 2000 sans champ os passe en .nt (MFT en tête), ce qui reste invérifiable ici.

**Contre-vérification.** Le docstring de DiskGenerator.swift:339-343 attribue à Windows 2000 le retour du miroir près du début. Or formatting(for:) (345-353) envoie une année < 2001 vers .nt, et mirrorInTheMiddle vaut vrai pour .nt, .xp et .vista. Le FORMAT de XP SP1 pose encore le miroir à n/2 (mftref.cxx:182). Le commentaire contredit donc les deux codes.


### `ntfs-format-07` — nuancé

**Affirmation.** Taille de $LogFile : 64 Mio à partir de 12 Gio de volume, 4 Mio de 200 Mio à 12 Gio, 2 Mio en dessous (valeurs de mkntfs).

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:319-330`
- XP : `base/fs/utils/untfs/src/logfile.cxx:48-56, 869-888`
- Extrait : « #define MaximumInitialLogFileSize 0x4000000 /* 64 MB */ … InitialSize = VolumeSize/SecondaryLogFileGrowthRate + 400MB/PrimaryLogFileGrowthRate »

**Constat.** Pour la galerie, le résultat est juste. Pour les volumes moyens, la règle de XP est une rampe continue et non des paliers. Jusqu'à 400 Mo, le journal fait 1 % du volume, avec un minimum de 2 Mo. Au-delà, il fait (V − 400 Mo)/200 + 4 Mo, plafonné à 64 Mo et aligné sur 16 Ko. Le plafond est atteint vers 12,1 Gio, donc les douze NTFS de la galerie ont bien 64 Mio. Mais un volume de 2 Go aurait environ 12 Mo de journal, pas 4 ; un volume de 8 Go environ 42 Mo.

**Effet.** Aucun sur la galerie. Sur un disque personnalisé de 0,4 à 12 Gio, le journal serait trop court dans le modèle, ce qui change seulement le rebouclage des pages. Sa place compte bien plus (ntfs-format-03).

**Contre-vérification.** logfile.cxx:48-56 et 869-888 relus. Sous 400 Mo : 1 %, au moins 2 Mo. Au-delà : (V−400 Mo)/200 + 4 Mo, plafonné à 64 Mo, masque 0x3FFF (16 Ko). Au-delà de 2³² secteurs, 64 Mo d'office. Le plafond est atteint à 400 Mo + 60 Mo × 200 ≈ 12,1 Gio. Les calculs à 2 Go (≈12,2 Mo) et 8 Go (≈43 Mo) sont justes. Pour la galerie, 64 Mio est correct.


### `ntfs-format-08` — nuancé

**Affirmation.** La zone MFT fait 12,5 % du volume sous XP, et le simulateur la pose derrière la MFT initiale.

- App : `Sources/DiskCore/FileSystemProfile.swift:201-215 ; Sources/DiskCore/Allocators/NTFSAllocator.swift:341-343, 87`
- XP : `base/fs/ntfs/bitmpsup.c:42, 8542-8551, 8640-8641`
- Extrait : « DefaultZoneSize = (Vcb->TotalClusters >> NTFS_MFT_ZONE_DEFAULT_SHIFT) * NtfsMftZoneMultiplier; … DefaultZoneSize -= MftClusters; »

**Constat.** L'ordre de grandeur est juste, mais ce n'est pas FORMAT qui fixe la zone : le pilote la calcule à chaque montage (NtfsInitializeClusterAllocation → NtfsInitializeMftZone). La taille par défaut est (TotalClusters >> 3) × NtfsMftZoneMultiplier, moins les clusters déjà pris par la MFT, avec un minimum de 1/16 du volume. La MFT et sa zone font donc 12,5 % ensemble. La zone commence au cluster qui suit le dernier extent de la MFT, si ce cluster est libre. Ses bornes sont alignées sur 32 clusters. Le modèle compte 12,5 % à partir du début de la MFT : l'écart est négligeable sur un volume neuf.

**Effet.** Faible à la création. Le vrai écart est dynamique (voir ntfs-format-10).

**Contre-vérification.** bitmpsup.c:42 (SHIFT 3) et 8542-8551 relus. La zone vaut TotalClusters/8 × multiplicateur − MftClusters, et au moins TotalClusters/16. Elle commence au LCN qui suit le dernier extent de la MFT s'il est libre, sinon au meilleur trou (8559-8620). Elle est alignée sur 32 clusters (8640-8641). La fin de zone du modèle (mftStart + 12,5 %) retombe au même endroit sur un volume neuf.


### `ntfs-format-09` — confirmé

**Affirmation.** Aucun seuil de remplissage n'ouvre la zone. Elle ne cède que quand le reste du volume est plein, et alors elle rend la moitié de sa part libre, la plus éloignée de la MFT.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:10-14, 378-406 ; Sources/DiskCore/FileSystemProfile.swift:204-208`
- XP : `base/fs/ntfs/bitmpsup.c:3992-4001, 1240-1246, 8720, 8776-8786, 8855`
- Extrait : « We didn't find anything.  Let's examine the zone explicitly. … TargetFreeClusters = Int64ShraMod32( FreeClusters, 1 ); »

**Constat.** NtfsFindFreeBitmapRun parcourt d'abord tout ce qui est hors zone et n'examine la zone qu'en dernier. NtfsReduceMftZone n'est appelé que si l'allocation est tombée dans la zone. Il compte les clusters libres de toute la zone depuis MftZoneStart, puis ramène MftZoneEnd au point où la moitié de ces clusters libres est passée. Il garde donc la moitié proche de la MFT. Deux détails que le modèle n'a pas : la réduction est refusée si la zone, ou le volume, a moins de 4 × MFT_EXTEND_GRANULARITY = 64 clusters libres ; et la moitié se compte en clusters libres de toute la zone, pas seulement sur la queue qui suit la fin de la MFT.

**Contre-vérification.** bitmpsup.c:3868-3905 : hors zone d'abord. 3992-4001 : la zone n'est examinée qu'en dernier. 1240-1246 : NtfsReduceMftZone seulement si AllocatedFromZone et que ce n'est pas la MFT qui s'étend. 8720 et 8776 : pas de réduction sous 64 clusters libres (volume ou zone). 8786 et suivantes : on garde la première moitié des clusters libres de la zone, comptée depuis MftZoneStart, donc la moitié proche de la MFT. Les deux détails absents du modèle sont exacts.


### `ntfs-format-10` — contredit

**Affirmation.** La zone MFT courante « ne fait que rétrécir ». Seules Vista et 7 renouvellent une zone quand la MFT a rempli la sienne.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:135-137, 664-679, 88-89`
- XP : `base/fs/ntfs/bitmpsup.c:668, 1265-1277, 1858-1866, 8587-8620`
- Extrait : « If we had shrunk the Mft zone and there is at least 1/16 of the volume now available, then grow the zone back. »

**Constat.** XP renouvelle aussi sa zone, de trois façons : (1) à chaque montage, NtfsInitializeMftZone recalcule une zone complète derrière la fin de la MFT ; (2) après une réduction, dès que l'espace libre dépasse 1/16 du volume (VCB_STATE_REDUCED_MFT), le pilote la regonfle ; (3) quand la MFT grandit et ne trouve pas de place contiguë, le pilote relit toute la bitmap et pose une nouvelle zone, de 12,5 % moins la MFT, sur le meilleur trou par longueur, puis la MFT y continue. Le mécanisme « nouvelle zone ailleurs » que le modèle réserve à Vista et 7 existe donc déjà dans XP, avec une autre taille.

**Effet.** Touche la disposition sur les volumes qui se remplissent (famille-2003, secretaire-2003). Dans le modèle, une zone réduite le reste pour toujours, et la MFT grandit ensuite par paquets de 8 clusters pris au plus près. Sous XP, un redémarrage ou un nettoyage rend une zone, et la MFT se fragmente en peu de gros morceaux plutôt qu'en des dizaines de petits. Il y aurait moins d'extents de MFT, donc moins de sauts pendant les lectures d'enregistrements au démarrage et pendant la défragmentation.

**Contre-vérification.** Les trois voies sont vérifiées. (1) Au montage, NtfsInitializeClusterAllocation appelle NtfsInitializeMftZone (bitmpsup.c:668). (2) Après une réduction, VCB_STATE_REDUCED_MFT est posé si libre < 1/16 (bitmpsup.c:8855 et suivantes) ; dès que le libre dépasse 1/16, le pilote rescanne et réinitialise la zone (1858-1866). (3) Quand la MFT s'étend sans run contigu, il rescanne et appelle NtfsInitializeMftZone (1265-1277), qui choisit un trou par longueur dans le cache (NtfsLookupCachedLcnByLength, 8602-8619). La phrase « ne fait que rétrécir » (NTFSAllocator.swift:135-137) est donc fausse pour XP.


### `ntfs-format-11` — nuancé

**Affirmation.** Hors de sa zone, $MFT grandit par paquets d'au moins huit (enregistrements), soit 8 clusters, « un ordre de grandeur sans source ».

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:193-198`
- XP : `base/fs/ntfs/ntfs.h:415 ; base/fs/ntfs/fsctrl.c:2534-2538`
- Extrait : « #define MFT_EXTEND_GRANULARITY (16) »

**Constat.** XP étend la MFT par MFT_EXTEND_GRANULARITY = 16 enregistrements, relevé à un cluster entier si les clusters sont plus grands. Avec des enregistrements de 1 Ko et des clusters de 4 Ko, cela fait 16 Ko, donc 4 clusters et non 8. La granularité est désormais sourcée : elle vaut la moitié de celle du modèle.

**Effet.** Faible. Le paquet règle surtout l'espacement des demandes de place. Le modèle en prend deux fois trop, ce qui retarde un peu la fragmentation de la MFT hors zone.

**Contre-vérification.** ntfs.h:415 (MFT_EXTEND_GRANULARITY 16) et fsctrl.c:2534-2538 relus. La granularité est bien utilisée pour allouer : bitmpsup.c:6411 et 7441-7442 arrondissent l'allocation au multiple de 16 enregistrements suivant. Avec des enregistrements de 1 Ko et des clusters de 4 Ko, cela fait 4 clusters, contre 8 dans le modèle (NTFSAllocator.swift:193-198). La mention « au moins huit (enregistrements) » du commentaire de l'app est donc aussi fausse.


### `ntfs-format-12` — nuancé

**Affirmation.** Un volume NTFS neuf a une MFT de 32 enregistrements (32 Ko, 8 clusters à 4 Ko).

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:220, 301, 336`
- XP : `base/fs/utils/untfs/src/format.cxx:552, 685 ; base/fs/ntfs/ntfs.h:406`
- Extrait : « MftSize = (FIRST_USER_FILE_NUMBER * FrsSize + (ClusterSize - 1))/ClusterSize; »

**Constat.** FORMAT sous XP crée la MFT avec FIRST_USER_FILE_NUMBER = 16 enregistrements, soit 16 Ko (4 clusters à 4 Ko). Son bitmap tient dans un cluster, posé juste devant elle.

**Effet.** Négligeable : l'installation fait grandir la MFT à des dizaines de Mo.

**Contre-vérification.** format.cxx:552 : MftSize = FIRST_USER_FILE_NUMBER (16) × FrsSize ; 685 : MftFile.Create(FIRST_USER_FILE_NUMBER…) ; ntfs.h:406 : la constante vaut 16. XP crée 16 enregistrements (4 clusters), le modèle 32 (initialMFTRecords = 32, NTFSAllocator.swift:220). Sans effet sonore notable.


### `ntfs-format-13` — confirmé

**Affirmation.** Un enregistrement MFT fait 1 Ko.

- App : `Sources/DiskCore/FileSystemProfile.swift:183-188 ; Sources/Model/VolumeLayout.swift:185-190`
- XP : `base/fs/utils/untfs/inc/untfs.hxx:179 ; base/fs/utils/untfs/src/format.cxx:1368-1370`
- Extrait : « #define SMALL_FRS_SIZE  (1024) »

**Constat.** NTFS_SA::Create passe SMALL_FRS_SIZE = 1024 comme taille de FRS par défaut, relevée à la taille d'un secteur si besoin. Le seuil de résidence de 700 octets n'est, lui, pas vérifiable ici : il dépend des attributs présents.

**Contre-vérification.** untfs.hxx:179 (SMALL_FRS_SIZE 1024) ; format.cxx:1368-1370 le passe à Create. Le seuil de résidence de 700 octets n'est pas vérifiable ici.


### `ntfs-format-14` — nuancé

**Affirmation.** Taille de cluster par défaut : 1 Ko sous 1 Gio, 2 Ko sous 2 Gio, 4 Ko au-delà (le modèle prend 1 Ko sous 512 Mo).

- App : `Sources/DiskCore/FileSystemProfile.swift:216-231 ; Sources/DiskCore/DiskGenerator.swift:334-336`
- XP : `base/fs/utils/untfs/src/ntfssa.cxx:1446-1454`
- Extrait : « if (cbDiskSize > (ULONG) 2*1024*1024*1024) {    // > 2 Gig  cbClusterSize = 4096; »

**Constat.** Les 4 Ko des volumes de la galerie sont confirmés. Les paliers de XP sont : 512 octets jusqu'à 512 Mo, 1 Ko jusqu'à 1 Go, 2 Ko jusqu'à 2 Go, 4 Ko au-delà. Les bornes sont en « > », donc exactement 1 Gio donne 1 Ko et 2 Gio donnent 2 Ko, là où forVolume rend 2 et 4 Ko. Le modèle ne sait pas représenter 512 octets, et il le dit. Enfin, DiskGenerator.ntfsProfile prend clusterKB ?? 4 et non forVolume : un NTFS personnalisé de moins de 2 Gio sans clusterKB reçoit 4 Ko à la génération.

**Effet.** Aucun sur la galerie. Sur un disque personnalisé de moins de 2 Gio, la taille de cluster est incohérente entre le générateur et ProfileSpec.

**Contre-vérification.** ntfssa.cxx:1448-1456 relu. Les bornes sont en « > » : strictement plus de 2 Gio donne 4 Ko, plus de 1 Gio donne 2 Ko, plus de 512 Mo donne 1 Ko, sinon 512 octets. forVolume (FileSystemProfile.swift:224-230) rend 2 Ko à exactement 1 Gio et 4 Ko à exactement 2 Gio : décalage d'un cran aux bornes exactes. DiskGenerator.swift:334-336 fait bien clusterKB ?? 4.


### `ntfs-format-15` — confirmé

**Affirmation.** $Boot occupe les 8 premiers Ko du volume (2 clusters à 4 Ko). Seule la copie du secteur d'amorçage, au dernier secteur, est hors des clusters : un secteur de surcoût, et les clusters valent (secteurs − 1) / secteurs par cluster.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:302-307 ; Sources/DiskCore/FormatOverhead.swift:19-21, 62-66`
- XP : `base/fs/utils/untfs/inc/untfs.hxx:67 ; base/fs/utils/untfs/src/format.cxx:415, 1246, 1446`
- Extrait : « _boot_sector->NumberSectors = (_drive->QuerySectors() - 1).GetLargeInteger(); »

**Constat.** BYTES_IN_BOOT_AREA vaut 0x2000, et ClustersInBootArea est ce nombre arrondi au cluster supérieur. NumberOfSectors vaut QuerySectors() − 1, NumberOfClusters vaut NumberOfSectors / ClusterFactor, et le secteur d'amorçage écrit NumberSectors = secteurs − 1.

**Contre-vérification.** untfs.hxx:67 (BYTES_IN_BOOT_AREA 0x2000) ; format.cxx:501 (ClustersInBootArea arrondi au cluster supérieur), 415 (NumberOfSectors = secteurs−1), 1246 (NumberSectors du secteur d'amorçage = secteurs−1). Correspond à FormatOverhead.swift:62-66 (1 secteur) et à NTFSAllocator.swift:302-307.


### `ntfs-format-16` — confirmé

**Affirmation.** $Bitmap : un bit par cluster, arrondi à huit octets.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:286-287, 344-345`
- XP : `base/fs/utils/untfs/src/bitfrs.cxx:185-199`
- Extrait : « Size = QuadAlign(Size); »

**Constat.** Le calcul est ceil(clusters/8) puis QuadAlign, arrondi ensuite au cluster. Seule la place est fausse (ntfs-format-04).

**Contre-vérification.** bitfrs.cxx:185-199 : ceil(clusters/8), puis QuadAlign, puis arrondi au cluster. Identique à la formule de NTFSAllocator.swift:344-345.


### `ntfs-format-17` — nuancé

**Affirmation.** Monter un NTFS, c'est lire $Boot puis aller vérifier sa copie au tout dernier secteur du volume, lire les 16 premiers enregistrements de la MFT et les comparer à $MFTMirr.

- App : `Sources/Model/VolumeLayout.swift:426-446`
- XP : `base/fs/ntfs/fsctrl.c:5015-5060, 1574-1587`
- Extrait : « Get out if we didn't get an error.  Otherwise try the middle sector. »

**Constat.** La comparaison MFT ↔ $MFTMirr au montage est exacte : pour chaque enregistrement miroité, le pilote lit l'enregistrement de la MFT et celui de Mft2Scb. Mais le pilote ne lit la copie du secteur d'amorçage, au milieu puis au dernier secteur, que si la lecture du secteur 0 échoue ou ne décrit pas un NTFS. Un montage normal ne va pas au fond du disque.

**Effet.** Le modèle ajoute à chaque démarrage NTFS une course complète vers le dernier secteur, puis un retour. XP ne la fait pas. C'est un seek pleine course de trop, audible, au début de chaque montage.

**Contre-vérification.** fsctrl.c:5015-5046 : le secteur 0 est lu, et « if (!Error) return; ». La copie (au milieu, puis au dernier secteur) n'est lue que si cette lecture lève une erreur. Un montage normal ne va donc pas au fond du disque, alors que VolumeLayout.swift:442 le fait à chaque montage. Correction supplémentaire : la comparaison MFT ↔ miroir porte sur 4 enregistrements (boucle i < 4), pas 16. Référence corrigée : fsctrl.c:1561-1587 (et non 1574-1587).


### `ntfs-format-18` — confirmé

**Affirmation.** Les données ordinaires se posent devant $MFT, dans les 3 premiers Gio, puis derrière la zone (inférence que le LEDGER dit contredite « à la lettre » par la KB 961095).

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:95-101, 370-377 ; README.md:673-674`
- XP : `base/fs/ntfs/bitmpsup.c:3872-3905, 656-667`
- Extrait : « Check if we are starting before the Mft zone. … Current point to Zone start / Zone end to end of volume / Start of volume to current »

**Constat.** Le pilote de XP ne réserve que MftZoneStart..MftZoneEnd. Partant d'un point devant la zone, NtfsFindFreeBitmapRun parcourt de ce point au début de la zone, puis de la fin de la zone à la fin du volume, puis du début du volume à ce point. Au montage, LastBitmapHint vaut la première plage libre en cache à partir du LCN 0. L'espace devant une MFT posée à 3 Gio est donc de l'espace ordinaire, servi en premier. L'inférence du modèle est juste pour XP.

**Contre-vérification.** bitmpsup.c:3868-3905 : depuis un point devant la zone, l'ordre est point→début de zone, fin de zone→fin du volume, 0→point. bitmpsup.c:656-667 : au montage, LastBitmapHint = première plage libre en cache depuis 0. Les 3 premiers Gio sont bien de l'espace ordinaire, servi en premier.


### `ntfs-format-19` — confirmé

**Affirmation.** La zone modélisée est celle que renverrait FSCTL_GET_NTFS_VOLUME_DATA.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:135-137`
- XP : `base/fs/ntfs/fsctrl.c:9152-9157`
- Extrait : « VolumeData->MftZoneStart.QuadPart = Vcb->MftZoneStart; »

**Constat.** Le FSCTL renvoie Vcb->MftZoneStart et MftZoneEnd, bornés à TotalClusters : c'est la zone courante, réductions comprises.

**Contre-vérification.** fsctrl.c:9152-9157 : MftZoneStart et MftZoneEnd du Vcb (zone courante), avec la fin bornée à TotalClusters.


### `ntfs-format-20` — non vérifiable

**Affirmation.** Vista : zone de 200 Mo renouvelable. Windows 7 : $MFTMirr au LCN 2.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:88-90, 108-110`
- XP : `—`

**Constat.** Ces affirmations portent sur Vista et Windows 7 : le code de XP SP1 n'en dit rien. XP ne sert que d'indice contraire : zone en huitième du volume, multiplicateur du registre, miroir à n/2. Il montre aussi que le renouvellement de zone existait déjà (ntfs-format-10).

**Contre-vérification.** Vista et Windows 7 sont hors du code de XP SP1.


### `ntfs-format-21` — non vérifiable

**Affirmation.** NT 4 et 2000 : $MFT en tête derrière $Boot, $MFTMirr au milieu, $LogFile juste derrière lui.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:81-84`
- XP : `base/fs/utils/untfs/src/format.cxx:343-356, 594-596`
- Extrait : « MftLcn = ClustersInBootArea + (MFT_BITMAP_INITIAL_SIZE + (ClusterSize - 1))/ClusterSize; »

**Constat.** Ce code est celui de XP. On y trouve un indice fort : la branche #else de LOGFILE_PLACEMENT_V1, désactivée, décrit exactement cette disposition (« 0 $Boot, $Mft Bitmap, $Mft … n/2 $MftMirr, $LogFile »), et pose MftLcn juste derrière la zone d'amorçage. C'est vraisemblablement l'ancienne disposition, mais le code ne dit pas quelle version l'employait.

**Contre-vérification.** La branche #else (format.cxx:343-356 et 594-596, plus mftfile.cxx:291-293 qui met le bitmap au LCN 1) décrit bien MFT en tête et journal derrière le miroir. Elle est inactive, et le code ne dit pas quelle version l'employait. Ce n'est qu'un indice.


### Lacunes — Format NTFS et disposition initiale

- **Le registre NtfsMftZoneReservation (valeurs 1 à 4, sinon 1) multiplie la zone : 12,5, 25, 37,5 ou 50 % du volume, MFT comprise. Le modèle a mftZoneShare, mais aucun volume ne s'en sert.** — `base/fs/ntfs/ntfsinit.c:83, 575-601`. C'est un réglage connu des « optimiseurs » de l'époque, qui change la disposition et le moment où la zone cède. On peut l'ignorer pour la galerie, mais le modèle en a déjà le paramètre. *Contre-vérification :* ntfsinit.c:83 et 575-601 : multiplicateur 1 par défaut, accepté seulement de 1 à 4. Il est utilisé dans bitmpsup.c:8543. Dans l'app, mftZoneShare n'apparaît qu'à FileSystemProfile.swift:208-214 (0,125 par défaut) et à NTFSAllocator.swift:342 : aucun volume ne le change.
- **FORMAT pose $AttrDef, l'allocation de l'index de la racine, $UpCase (128 Ko) et $Secure juste derrière $MFTMirr, au milieu du volume. Le modèle ne connaît comme métafichiers que $Boot, $MFT, $MFTMirr, $LogFile et $Bitmap.** — `base/fs/utils/untfs/src/format.cxx:337-341, 904-1131`. Sous XP, l'index de la racine (C:\) est au milieu du volume. Toute résolution de chemin qui passe par un répertoire non résident de la racine y envoie le bras au montage et au démarrage. $UpCase y est lu au montage. *Contre-vérification :* Tient pour $AttrDef, l'index racine, $Bitmap et $UpCase : ils sont créés en séquence après le miroir, sans LCN imposé, depuis _NextAlloc (format.cxx:337-341, 904, 951, 991, 1131). Pour $Secure/$SDS, je ne l'ai pas vérifié en détail. Aucune mention d'AttrDef ni d'UpCase dans Sources/ ni dans README.md. Nuance : seule l'allocation initiale de l'index racine est au milieu ; ses tampons ajoutés plus tard viennent de l'allocateur du pilote.
- **La zone MFT est recalculée à chaque montage, regonflée quand l'espace libre dépasse 1/16 après une réduction, et reposée ailleurs, sur le meilleur trou par longueur, quand la MFT ne peut plus grandir de façon contiguë.** — `base/fs/ntfs/bitmpsup.c:668, 1265-1277, 1858-1866`. Cela change la fragmentation de la MFT des volumes pleins de 2003, donc le nombre d'extents lus au démarrage et pendant la défragmentation. Voir ntfs-format-10. *Contre-vérification :* Vérifié à bitmpsup.c:668, 1265-1277, 1858-1866 et 8559-8620. L'app ne l'a pas pour XP : zone qui ne fait que rétrécir, et renouvellement réservé à Vista et 7 (NTFSAllocator.swift:135-137, 664-679).
- **Dans l'allocateur du pilote, l'extension d'un fichier part de PrecedingLcn + 1 (ReturnAnyLength). Faute de voisin, il cherche par longueur dans le cache des plages libres (NtfsLookupCachedLcnByLength), puis balaie la bitmap depuis LastBitmapHint en contournant la zone. Cela confirme, depuis le pilote de XP, le « prolongement en place » et la recherche « près de lui » que NTFSAllocator attribue au pilote Linux.** — `base/fs/ntfs/bitmpsup.c:1015-1030, 1185-1205`. Cela fournit une source primaire à des choix aujourd'hui justifiés par Linux-NTFS, et pourrait remplacer les bornes de recherche « sans source » par le cache de plages libres de XP. *Contre-vérification :* bitmpsup.c:1015-1030 et 1180-1205 relus : HintLcn = PrecedingLcn+1 avec ReturnAnyLength ; sinon LastBitmapHint, repoussé à MftZoneEnd s'il tombe dans la zone. L'app attribue ce comportement au pilote Linux (README.md:680-682 et en-tête de NTFSAllocator) et ne cite pas XP.
- **Un volume converti depuis FAT (convert.exe, cas courant des PC OEM sous XP) place la MFT et le journal dans la zone réservée _cvt_zone, et non à 3 Gio.** — `base/fs/utils/untfs/src/format.cxx:555-574`. Cette disposition est différente et assez répandue en 2003. Elle n'est pas modélisée, et la galerie suppose un formatage neuf. *Contre-vérification :* format.cxx:555-574 : utilisé seulement si _cvt_zone et _cvt_zone_size sont non nuls, c'est-à-dire une conversion avec une zone réservée (/CVTAREA). Sinon on retombe sur le placement à 3 Gio. L'app n'a ni « cvt » ni conversion NTFS dans Sources/. Que ce soit « le cas courant des PC OEM » n'est pas vérifiable par le code.

## Allocation NTFS au fil de l’eau, croissance de la MFT, FSCTL_MOVE_FILE


### `ntfs-alloc-01-bestfit` — nuancé

**Affirmation.** NTFS place un fichier neuf en best-fit, mais le modèle ne reprend un trou que s'il fait au plus 2× le besoin (sinon il prend l'espace vierge), n'examine que 64 trous et ne parcourt la bitmap que sur 65 536 clusters. Ces bornes ne sont pas sourcées.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:8-9, 152-185, 463-490`
- XP : `base/fs/ntfs/bitmpsup.c:1073-1102, 3466-3468, 9143-9144, 9577-9661 ; 655 (remplissage du cache au montage)`
- Extrait : « CachedRuns->MaximumSize = 9000; CachedRuns->MinCount = 100; »

**Constat.** Le best-fit est bien celui de XP. Pour un fichier sans run précédent, NtfsAllocateClusters interroge d'abord le cache des runs libres par longueur. NtfsLookupCachedLcnByLength rend le plus petit run au moins aussi long que la demande, sans tolérance et sans préférer le vierge. Le cache contient jusqu'à 9 000 runs, et au moins 100 par classe de petite longueur. XP ne lit la bitmap sur le disque qu'en dernier recours, et c'est alors un premier trou depuis un indice : « pretty dumb ... doesn't try for the best fit ». XP n'a ni fenêtre de 64 trous, ni horizon de 65 536 clusters, ni règle des 2×.

**Effet.** XP comble les trous moyens que le modèle délaisse pour le vierge, dès qu'un trou est le plus petit à convenir. La règle des 2× et l'horizon sont exactement les bornes que la table de l'en-tête montre décisives (de 4,6 à 21,2 % sur famille-2003). La forme réelle serait un best-fit presque global sur 9 000 runs, avec la bitmap en premier trou pour secours.

**Contre-vérification.** Vérifié. NtfsAllocateClusters, pour un fichier sans run précédent, appelle NtfsLookupCachedLcnByLength (bitmpsup.c:1073-1102). Cette fonction rend le premier run d'une longueur au moins égale (9577-9661), avec AllowShorter pour tout ce qui n'est pas $INDEX_ALLOCATION. Il n'y a ni tolérance ×2, ni fenêtre de 64 runs, ni horizon. Le cache est plafonné à 9000 runs, MinCount 100 (9143-9144). Il est rempli au montage par NtfsScanEntireBitmap (bitmpsup.c:655), qui ne retient que « the largest free runs ». Il n'est donc pas exhaustif sur un volume très morcelé. L'expression « best-fit presque global » tient, à cette réserve près. NtfsFindFreeBitmapRun (3466) est bien un premier trou (« pretty dumb »). Les références de l'app (NTFSAllocator.swift:8-9, 152-185, 463-490) sont exactes, et l'en-tête dit lui-même que les bornes n'ont pas de source.


### `ntfs-alloc-02-curseur` — contredit

**Affirmation.** Pour un fichier neuf, la recherche part d'un curseur qui suit la dernière écriture (searchCursor), ce qui répartit les écritures sans se disputer la tête du volume.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:200-203, 468-469, 565-567`
- XP : `base/fs/ntfs/bitmpsup.c:1015-1022 (aussi 13172, 1194, 1370-1375)`
- Extrait : « If we have no PrecedingLcn to use as a hint ... This will left pack things as much as possible. »

**Constat.** Pour un fichier sans run précédent, XP pose HintLcn = UNUSED_LCN, une valeur inférieure à tout LCN. Parmi les runs de la longueur trouvée, le choix va donc au plus petit LCN : « maximum left-packing of the disk ». Le curseur tournant de XP (Vcb->LastBitmapHint) ne sert qu'au dernier recours, la lecture de la bitmap sur le disque, et ne change qu'à cette occasion.

**Effet.** Sous XP, les fichiers neufs se tassent vers le début du volume, dans le plus petit trou qui convient, et non derrière la dernière écriture. Le modèle étale davantage les écritures, donc les courses du bras et la carte.

**Contre-vérification.** Le cœur du verdict tient. HintLcn = UNUSED_LCN pour un fichier sans run précédent (bitmpsup.c:1015-1022), et NtfsPositionCachedLcnByLength documente « maximum left-packing » (13172-13176). Le premier agent se trompe sur un détail : LastBitmapHint ne change pas qu'au dernier recours. Il est mis à FoundLcn à CHAQUE allocation sans PrecedingLcn, que le run vienne du cache ou de la bitmap (bitmpsup.c:1367-1375 : « if (PrecedingLcn == UNUSED_LCN) Vcb->LastBitmapHint = FoundLcn »). En revanche, il n'est LU que dans le repli sur la bitmap (1194). La conclusion ne change pas : pour un fichier neuf, la recherche ne part pas d'un curseur qui suit l'écriture.


### `ntfs-alloc-03-reutilisation-paresseuse` — contredit

**Affirmation.** La « réutilisation paresseuse » de NTFS se modélise par une préférence pour l'espace jamais servi. La libération est immédiate, et un trou libéré n'est repris que s'il convient vraiment ou quand le vierge est épuisé, d'où des trous qui persistent.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:70-75, 610-618`
- XP : `base/fs/ntfs/bitmpsup.c:1750-1761 ; logsup.c:4528`
- Extrait : « And to hold us off from reallocating the clusters right away we'll add this run to the recently deallocated mcb »

**Constat.** XP ne préfère jamais le vierge. Le vrai délai tient au journal. Les clusters libérés sont effacés de la bitmap mais notés dans une liste en mémoire des clusters « recently deallocated », qui les masque aux recherches. Au point de contrôle, NtfsFreeRecentlyDeallocated les verse dans le cache des runs libres (NtfsAddCachedRun). Ils deviennent alors des candidats ordinaires du best-fit par longueur, et même prioritaires s'ils sont petits.

**Effet.** Sous XP, un trou libéré est repris quelques secondes plus tard dès qu'il est le plus juste. Les trous persistants au milieu du volume sont moins nombreux que dans le modèle, et les petits fichiers comblent les trous récents.

**Contre-vérification.** Vérifié. NtfsDeallocateClusters ajoute la plage à la liste des clusters désalloués (bitmpsup.c:1750-1790), puis efface les bits (NtfsFreeBitmapRun, 1798). Les recherches dans la bitmap masquent ces clusters par NtfsAddRecentlyDeallocated (3585, 3719). NtfsFreeRecentlyDeallocated les verse dans le cache par NtfsAddCachedRun (logsup.c:4500-4533). Il ne le fait que pour les lots dont le LSN est antérieur au BaseLsn du point de contrôle : le délai réel va d'un à deux intervalles de point de contrôle, et non « quelques secondes » fixes. Rien dans le code ne préfère l'espace vierge.


### `ntfs-alloc-04-prolongement` — nuancé

**Affirmation.** Agrandir un fichier, c'est d'abord prendre les clusters qui suivent son dernier extent. Quand ils sont pris, le complément est cherché à partir du fichier (règle reprise du pilote Linux).

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:15-23, 570-608 ; README.md:680-684`
- XP : `base/fs/ntfs/bitmpsup.c:1029-1083, 13158 ; 1183-1185`
- Extrait : « ENHANCEMENT - If there is no match for the desired RunLength we currently choose the next higher size without checking for the one with the closest Lcn value. »

**Constat.** La première étape est confirmée : avec un PrecedingLcn, XP cherche d'abord dans le cache le run qui commence à PrecedingLcn+1. Si ce run n'y est pas, XP ne cherche pas « près du fichier ». Il fait un best-fit par longueur, où PrecedingLcn+1 ne départage que les runs de longueur exactement égale ; pour une longueur supérieure, c'est le plus petit LCN qui gagne (commentaire ENHANCEMENT). Seul le dernier recours, la lecture de la bitmap, part de PrecedingLcn+1 en premier trou. La source citée par l'app est Linux, pas Windows.

**Effet.** Sous XP, le complément d'un fichier qui grandit va dans le trou le plus juste, souvent loin du fichier. Le modèle les rapproche trop, ce qui raccourcit les courses du bras à la lecture de ces fichiers.

**Contre-vérification.** Vérifié. Le code interroge d'abord NtfsLookupCachedLcn(PrecedingLcn+1) (bitmpsup.c:1029-1059). Faute de résultat, HintLcn = PrecedingLcn+1 ne sert qu'à départager les runs de même longueur dans la recherche par longueur (1061-1083). Le commentaire ENHANCEMENT (13158-13161) confirme qu'une longueur supérieure est prise sans regarder le LCN. Seul le repli sur la bitmap part de PrecedingLcn+1 avec ReturnAnyLength (1183-1185). L'app cite bien Linux et non Windows (NTFSAllocator.swift:15-23 ; README.md:680-684).


### `ntfs-alloc-05-paquets-ecriture` — contredit

**Affirmation.** Sur NTFS, un fichier dont la taille est inconnue grandit par paquets de 64 Ko, que le gestionnaire de cache vide d'un coup. Le chiffre est présenté comme estimé, sans source.

- App : `README.md:636-643 ; Sources/DiskCore/FileSystemProfile.swift:201`
- XP : `base/fs/ntfs/allocsup.c:1307-1403 ; write.c:2064-2163 ; bitmpsup.c:1165-1178`
- Extrait : « DesiredClusterCount = Int64ShllMod32( ClusterCount, CcbForWriteExtend->WriteExtendCount ); »

**Constat.** XP alloue au moment de l'écriture par l'application, dans NtfsCommonWrite, et non quand le cache se vide. L'appel passe AskForMore = TRUE. NtfsAddAllocation demande alors « ClusterCount << WriteExtendCount » : 1, 2, 4, 8 puis 16 fois la taille de l'écriture, arrondi à 2^n clusters, le compteur étant plafonné à 4 par handle. Ce surplus est un DesiredClusterCount : il est accordé seulement s'il ne coûte pas de run supplémentaire. Il est borné à FreeClusters/1024 + la demande, et ce qui dépasse la taille du fichier est rendu à la fermeture (SCB_STATE_TRUNCATE_ON_CLOSE).

**Effet.** Un fichier écrit par petits morceaux obtient des runs de plus en plus longs, jusqu'à 16× l'écriture, et reste bien plus contigu qu'avec des paquets fixes de 64 Ko en best-fit. La fermeture laisse de petits trous derrière chaque fichier. La traîne de 2 à 16 morceaux mesurée sur secretaire-2003 (27,4 %) est probablement surestimée.

**Contre-vérification.** Le mécanisme est vérifié. NtfsCommonWrite appelle NtfsAddAllocation avec AskForMore = TRUE (write.c:2068, 2148-2153) et pose SCB_STATE_TRUNCATE_ON_CLOSE (2163). Le calcul donne DesiredClusterCount = ClusterCount << WriteExtendCount, arrondi sur 2^n VCN, avec un compteur plafonné à 4 (allocsup.c:1321-1387), puis plafonné à FreeClusters/1024 + la demande (1392-1403). Le compteur part de 0 : la première extension est exacte, puis ×2, ×4, ×8, ×16. Une correction s'impose : le surplus n'est PAS « accordé seulement s'il ne coûte pas de run supplémentaire ». La boucle de NtfsAllocateClusters remplit jusqu'à DesiredEndingVcn tant que le cache répond, éventuellement en plusieurs runs, et n'abandonne le surplus qu'à un défaut de cache (bitmpsup.c:1165-1178, test StartingVcn > EndingVcn). Il y a aussi deux exceptions : un fichier compressé ou avec CompressionUnit alloue au plus juste (write.c:2098-2105), et un quota proche de sa limite fait de même (allocsup.c:1405-1430).


### `ntfs-alloc-06-taille-zone` — confirmé

**Affirmation.** La zone MFT représente 12,5 % du volume à partir du début de $MFT, soit 12,5 % moins la MFT derrière elle, et elle est posée juste derrière la MFT.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:10, 341-343 ; FileSystemProfile.swift:211`
- XP : `base/fs/ntfs/bitmpsup.c:42, 8542-8554, 8566-8568, 8636-8637 ; ntfsinit.c:597-602`
- Extrait : « MinZoneSize = Vcb->TotalClusters >> (NTFS_MFT_ZONE_DEFAULT_SHIFT + 1); DefaultZoneSize = (Vcb->TotalClusters >> NTFS_MFT_ZONE_DEFAULT_SHIFT) * NtfsMftZoneMultiplier; »

**Constat.** NtfsInitializeMftZone calcule DefaultZoneSize = (TotalClusters >> 3) × NtfsMftZoneMultiplier, retire la taille de la MFT, avec un plancher de TotalClusters >> 4. Il cherche d'abord un run libre qui commence juste après le dernier LCN de la MFT. Il aligne ensuite la zone sur 32 clusters. Le multiplicateur vaut 1 par défaut et se règle de 1 à 4 par le registre (NtfsMftZoneReservation). L'app ignore le plancher de 6,25 %, qui ne joue que pour une grosse MFT.

**Effet.** Aucun pour un volume neuf. Pour une MFT qui dépasse 6,25 % du volume, XP garde une zone de 6,25 % quand le modèle la réduit à rien.

**Contre-vérification.** Prouvé. NTFS_MFT_ZONE_DEFAULT_SHIFT vaut 3 (bitmpsup.c:42). Le calcul DefaultZoneSize = (Total >> 3) × multiplicateur, moins MftClusters, avec un plancher de Total >> 4, est en 8542-8554. La recherche d'un run à MFT+1 est en 8566-8608, l'alignement sur 32 en 8636-8637. Le multiplicateur vaut 1 par défaut (ntfsinit.c:575) et se règle de 1 à 4 (597-602). L'app pose zoneEnd = mftStart + 12,5 % (NTFSAllocator.swift:341-343), ce qui revient au même sur un volume neuf. La zone de XP ne couvre que le run libre qui suit la MFT : si ce run est plus court, la zone l'est aussi.


### `ntfs-alloc-07-moitie-zone` — confirmé

**Affirmation.** Quand le reste du volume est plein, la zone cède la moitié de sa partie libre, la plus éloignée de la MFT, et recommence à chaque nouveau remplissage.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:11-14, 378-424`
- XP : `base/fs/ntfs/bitmpsup.c:8720, 8746-8866 ; 1244-1256`
- Extrait : « We want to find the number of free clusters in the Mft zone and return half of them to the pool of clusters for users files. »

**Constat.** NtfsReduceMftZone compte les clusters libres de la zone depuis MftZoneStart, en prend la moitié (Int64ShraMod32(FreeClusters, 1)) et place la nouvelle fin de zone au cluster libre qui atteint ce compte, arrondi à 32. La queue rendue est bien la plus éloignée. La réduction n'a lieu que si la zone garde au moins 64 clusters libres (4 × MFT_EXTEND_GRANULARITY). Elle se déclenche quand la lecture de la bitmap, dernier recours, tombe dans la zone. Le modèle coupe une plage brute, XP compte des bits libres : l'écart est mince.

**Effet.** Faible. Le seuil de 64 clusters et l'alignement sur 32 manquent au modèle.

**Contre-vérification.** Prouvé par NtfsReduceMftZone (bitmpsup.c:8674-8872). Le code compte les bits libres depuis MftZoneStart, en prend la moitié (Int64ShraMod32(FreeClusters,1)), place la fin au cluster libre qui atteint ce compte et l'arrondit à 32. Il ne fait rien si le volume ou la zone ont moins de 64 clusters libres (8720, 8766). Le déclenchement vient d'AllocatedFromZone, dans le repli sur la bitmap, qui n'a lieu que quand le cache n'a plus de run hors zone (1244-1262). Cela correspond au « reste du volume plein » du modèle.


### `ntfs-alloc-08-zone-ne-fait-que-retrecir` — contredit

**Affirmation.** La zone MFT courante « ne fait que rétrécir ». Les passes voient la zone réduite de moitié à chaque remplissage, et non la réserve d'origine.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:135-138 ; README.md:1170-1173`
- XP : `base/fs/ntfs/bitmpsup.c:1851-1868, 668, 8868-8871 ; fsctrl.c:2475`
- Extrait : « If we had shrunk the Mft zone and there is at least 1/16 of the volume now available, then grow the zone back. »

**Constat.** XP recalcule la zone à chaque montage : NtfsInitializeClusterAllocation, appelé depuis NtfsMountVolume, appelle NtfsInitializeMftZone. Il la recalcule aussi dès qu'une libération fait remonter l'espace libre au-dessus de 1/16 du volume après une réduction, puisque VCB_STATE_REDUCED_MFT n'est posé que sous 1/16. La zone se reconstitue à 12,5 % moins la MFT. Si le cluster qui suit la MFT n'est pas libre, elle peut même se reposer ailleurs, sur le run de la bonne longueur le plus proche.

**Effet.** Après un redémarrage, ou dès que de la place se libère, les données sont de nouveau tenues à l'écart d'une zone pleine taille, et les défragmenteurs qui l'évitent (XP, JkDefrag) voient une grande zone. La fragmentation d'un volume longtemps plein et le temps passé par JkDefrag en dépendent.

**Contre-vérification.** Vérifié. NtfsMountVolume appelle NtfsInitializeClusterAllocation (fsctrl.c:2475), qui appelle NtfsInitializeMftZone (bitmpsup.c:668). Après une réduction, une libération qui fait dépasser 1/16 d'espace libre relance NtfsScanEntireBitmap puis NtfsInitializeMftZone (1851-1868). VCB_STATE_REDUCED_MFT n'est posé que sous 1/16 (8868-8871). L'impact est à tempérer : la zone recalculée n'est « pleine taille » que si le run libre qui suit la MFT est assez long. Sinon, elle se limite à ce run (NtfsFindFreeBitmapRun avec ReturnAnyLength, 8590-8600), ou se déplace sur le plus petit run qui atteint la taille par défaut (8606-8618). Un volume dont la moitié rendue a été remplie de données ne retrouve donc pas forcément une grande zone.


### `ntfs-alloc-09-granularite-mft` — contredit

**Affirmation.** $MFT s'agrandit par paquets d'au moins huit clusters hors de sa zone, un ordre de grandeur sans source. Dans sa zone, elle ne prend que ce qu'il lui faut, enregistrement par enregistrement.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:193-198, 645-662, 706-711`
- XP : `base/fs/ntfs/ntfs.h:410-415 ; fsctrl.c:2530-2546 ; bitmpsup.c:6405-6420`
- Extrait : « #define MFT_EXTEND_GRANULARITY (16) »

**Constat.** La granularité est fixée au montage : ExtendGranularity = MFT_EXTEND_GRANULARITY = 16 enregistrements, relevée à un cluster si 16 enregistrements tiennent dans moins. NtfsAllocateRecord arrondit l'allocation au multiple de 16 enregistrements suivant, dans la zone comme ailleurs. Avec des enregistrements de 1 Ko, cela fait 16 Ko, soit 4 clusters à 4 Ko, et non 8. La bitmap de la MFT grandit en parallèle par BITMAP_EXTEND_GRANULARITY, 64 bits.

**Effet.** Sur les volumes en clusters de 4 Ko, la MFT grandit par pas deux fois plus petits hors zone que dans le modèle, et quatre fois plus grands dans la zone. Cela change le nombre d'écritures d'initialisation d'enregistrements et le nombre d'extents d'une MFT fragmentée.

**Contre-vérification.** Vérifié. MFT_EXTEND_GRANULARITY vaut 16 et BITMAP_EXTEND_GRANULARITY 64 (ntfs.h:413-415). ExtendGranularity est relevé à FileRecordsPerCluster si besoin (fsctrl.c:2534-2546). NtfsAllocateRecord arrondit au multiple de 16 enregistrements suivant, dans la zone comme hors zone (bitmpsup.c:6405-6422). Avec des enregistrements de 1 Ko et des clusters de 4 Ko, cela fait 4 clusters : 8 dans le modèle hors zone (NTFSAllocator.swift:198, 710-711), 1 cluster à la fois dans la zone. Les ordres de grandeur de l'impact sont justes.


### `ntfs-alloc-10-mft-hors-zone` — contredit

**Affirmation.** Une MFT qui a rempli sa zone cherche des paquets en premier trou depuis sa fin et se fragmente. Seuls Vista et 7 ouvrent une nouvelle zone de 200 Mo (KB 961095).

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:664-730, 88-90, 110 ; README.md:672-674`
- XP : `base/fs/ntfs/bitmpsup.c:1263-1287, 8570-8620`
- Extrait : « We are extending the Mft. If we didn't get a contiguous run then set up a new zone. »

**Constat.** XP renouvelle déjà sa zone. Quand l'extension de $MFT (ExtendingMft) n'obtient pas de run contigu à PrecedingLcn+1, NtfsAllocateClusters relit toute la bitmap dans le cache (NtfsScanEntireBitmap), appelle NtfsInitializeMftZone et pose le nouvel extent au début de cette nouvelle zone. La nouvelle zone fait 12,5 % du volume moins la MFT, avec un plancher de 6,25 %. Faute de run aussi long, elle prend le plus grand run libre. La taille de 200 Mo propre à Vista ne se vérifie pas dans ce code.

**Effet.** Sous XP, une MFT débordée gagne un seul nouvel extent, puis grandit d'un seul tenant dans une nouvelle réserve qui repousse encore les données. Le modèle produit des extents plus nombreux et en éventail.

**Contre-vérification.** Vérifié (bitmpsup.c:1263-1287). Quand ExtendingMft est vrai et que FoundLcn ≠ PrecedingLcn+1, le code appelle NtfsScanEntireBitmap(TRUE), puis NtfsInitializeMftZone, puis NtfsFindFreeBitmapRun depuis le début de la nouvelle zone. La nouvelle zone suit les règles de 8566-8620. Faute de run libre juste après la MFT, elle prend le plus petit run qui atteint la taille par défaut, ou le plus grand du cache s'il n'y en a pas. Parler du run « le plus proche » n'est vrai qu'à longueur égale. La règle des 200 Mo de Vista est absente de ce code, comme il se doit.


### `ntfs-alloc-11-mft-ne-retrecit-pas` — nuancé

**Affirmation.** La MFT ne rétrécit pas : elle garde la taille de son pic d'enregistrements simultanés, et les enregistrements libérés sont réutilisés.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:130-133, 620-648`
- XP : `base/fs/ntfs/ntfs.h:421-422 ; mftsup.c:1619-1638 ; bitmpsup.c:2337`
- Extrait : « #define MFT_DEFRAG_UPPER_THRESHOLD (3) // Defrag if 1/8 of free space »

**Constat.** La réutilisation est confirmée : NtfsAllocateRecord prend le premier bit libre de la bitmap de la MFT, et la MFT ne grandit qu'au-delà. Mais XP peut rendre des clusters de la MFT. Si les enregistrements libres, comptés en clusters, dépassent 1/8 de l'espace libre du volume, VCB_MFT_DEFRAG_TRIGGERED se déclenche. La MFT est alors défragmentée et NtfsCreateMftHole perce des trous de MFT_HOLE_GRANULARITY enregistrements, jusqu'à redescendre sous 1/16.

**Effet.** Cela ne joue que sur un volume presque plein qui a beaucoup effacé. Des clusters de MFT redeviennent libres, donc de nouveaux trous au milieu de la MFT.

**Contre-vérification.** Vérifié. Les seuils sont en ntfs.h:421-422 et le déclenchement en mftsup.c:1610-1640, qui compare (MftFreeRecords − MftHoleRecords) en clusters à FreeClusters>>3, puis >>4. NtfsCreateMftHole est en bitmpsup.c:2337. Le perçage est de plus conditionné aux drapeaux VCB_MFT_DEFRAG_PERMITTED et ENABLED, testés au point de contrôle (logsup.c:1059-1060). C'est donc un mécanisme réel, mais rare. L'app ne le modélise pas.


### `ntfs-alloc-12-rang-enregistrement` — nuancé

**Affirmation.** L'enregistrement MFT d'un fichier est désigné par son rang de création : 16 plus le nombre de fichiers créés avant lui, les seize premiers étant ceux du système.

- App : `Sources/Model/MachineWriter.swift:47-49, 158-163 ; DefragVolume.swift:273-274`
- XP : `base/fs/ntfs/ntfs.h:406 ; bitmpsup.c:5339, 5777, 7819-7822 (app : aussi Sources/Model/GeneratedVolume.swift:64-84)`
- Extrait : « RecordAllocationContext->StartingHint = FIRST_USER_FILE_NUMBER; »

**Constat.** FIRST_USER_FILE_NUMBER vaut bien 16, et la recherche de la MFT part de là. Mais un numéro libéré est réutilisé en premier : NtfsDeallocateRecordsComplete ramène StartingHint vers le bas, et RtlFindClearBits prend le premier bit libre depuis ce point.

**Effet.** Sur un volume qui a vécu, un fichier neuf prend un vieil enregistrement au milieu de la MFT. Le modèle, qui écrit toujours plus loin dans la MFT, sous-estime la dispersion des écritures d'enregistrements.

**Contre-vérification.** Vérifié. FIRST_USER_FILE_NUMBER vaut 16 (ntfs.h:406) et StartingHint est initialisé à 16 pour la MFT (bitmpsup.c:5339). RtlFindClearBits part de ce Hint (5777). NtfsDeallocateRecordsComplete ramène StartingHint à LowestDeallocatedIndex (7819-7822). Côté app, le problème va plus loin que MachineWriter : MFTNumbering (GeneratedVolume.swift:64-84) numérote de façon compacte les répertoires vivants, puis les fichiers vivants, à partir de 16. Une MFT sans trous est incompatible avec la réutilisation au premier bit libre, et avec la MFT de taille maximale que tient NTFSAllocator (mftPeakRecords).


### `ntfs-alloc-13-move-64k` — confirmé

**Affirmation.** FSCTL_MOVE_FILE copie par blocs de 64 Kio (LARGE_BUFFER_SIZE), bornés à l'extent source : une lecture puis une écriture synchrones, puis une validation de transaction, et ainsi pour chaque bloc.

- App : `Sources/Model/WindowsXPStrategy.swift:49-53, 89-93`
- XP : `base/fs/ntfs/ntfsdata.h:345 ; deviosup.c:10291-10295, 10508, 10563, 10587, 10617-10618`
- Extrait : « #define LARGE_BUFFER_SIZE (0x10000) »

**Constat.** Dans NtfsDefragFile, BufferLength vaut LARGE_BUFFER_SIZE (0x10000), ou un cluster s'il est plus grand. TransferSize est borné par le run courant et par ce qui reste à déplacer. Suivent deux NtfsSingleAsync sur le périphérique, en lecture puis en écriture, chacun attendu (NtfsWaitSync), puis NtfsReallocateRange et NtfsCheckpointCurrentTransaction. La copie contourne le cache. La zone située au-delà de ValidDataLength n'est pas copiée, seulement réallouée.

**Effet.** Le modèle est juste. Un détail manque : la partie au-delà de la VDL, comme la fin préallouée d'un fichier, se déplace sans I/O de données.

**Contre-vérification.** Prouvé. LARGE_BUFFER_SIZE vaut 0x10000 (ntfsdata.h:345). BufferLength est fixé en deviosup.c:10291-10299. TransferSize est borné par le run source (issu de NtfsLookupAllocation), par MoveData->ClusterCount et par BufferLength (10499-10510). Suivent une lecture et une écriture NtfsSingleAsync sur TargetDeviceObject, chacune suivie de NtfsWaitSync (10563-10600). Viennent ensuite NtfsReallocateRange et NtfsCheckpointCurrentTransaction (10617-10618). La copie est sautée au-delà de la VDL (10530-10561).


### `ntfs-alloc-14-validation` — nuancé

**Affirmation.** Valider un déplacement réécrit un enregistrement MFT de 1 Ko et les secteurs de $Bitmap couverts, une fois par fichier déplacé. Une validation sur huit écrit aussi une page de journal de 4 Ko (environ un demi-kilo d'enregistrements par validation, un ordre de grandeur).

- App : `Sources/Model/VolumeLayout.swift:231-239, 318-336 ; Sources/Model/WindowsXPStrategy.swift:52-53`
- XP : `base/fs/ntfs/logsup.c:2951-2956 ; bitmpsup.c:3071-3075 ; attrsup.c:6561 ; allocsup.c:2340`
- Extrait : « if (FlagOn( IrpContext->TopLevelIrpContext->State, IRP_CONTEXT_STATE_WRITE_THROUGH ) && ...) LfsFlushToLsn( Vcb->LogHandle, CommitLsn ); »

**Constat.** L'unité de XP est le bloc de 64 Ko, pas le fichier. Chaque bloc est une transaction : NtfsDeallocateClusters et NtfsAllocateClusters, qui journalisent ClearBits et SetBitsInNonresidentBitMap par page de bitmap, puis la réécriture des mapping pairs (UpdateMappingPairs), puis un commit. Le commit ne vide le journal que pour une IRP en write-through, et MOVE_FILE n'en est pas une. L'enregistrement MFT et les pages de $Bitmap sont modifiés en cache et partent avec le lazy writer, par pages de 4 Ko, et non par secteur à chaque validation.

**Effet.** Pour un gros fichier, XP produit beaucoup plus de journal que le modèle (un jeu d'enregistrements redo/undo par 64 Ko), mais aucune écriture de MFT ou de bitmap synchrone du déplacement. Les rafales de métadonnées devraient venir du lazy writer et du point de contrôle, groupées, plutôt qu'après chaque fichier.

**Contre-vérification.** Vérifié. Le commit ne vide le journal (LfsFlushToLsn) qu'en write-through (logsup.c:2951-2956). Chaque modification de la bitmap est journalisée (SetBitsInNonresidentBitMap, bitmpsup.c:3068-3080). Chaque bloc de 64 Ko est une transaction (deviosup.c:10617-10618). Le modèle compte une réécriture MFT et bitmap par fichier, plus une page de journal toutes les huit validations (VolumeLayout.swift:231-239, 318-336). Ce schéma d'écritures synchrones par fichier ne correspond pas au code. Je n'ai pas vérifié si l'IRP de FSCTL_MOVE_FILE porte l'état write-through ; rien ne l'indique dans NtfsDefragFile.


### `ntfs-alloc-15-clusters-retenus` — contredit

**Affirmation.** Sur NTFS, les clusters qu'un déplacement quitte restent occupés dans la bitmap que relit le défragmenteur jusqu'au prochain point de contrôle, et un FSCTL_MOVE_FILE vers eux échoue en STATUS_ALREADY_COMMITTED.

- App : `Sources/Model/DefragVolume.swift:326-339 ; README.md:1036-1040`
- XP : `base/fs/ntfs/bitmpsup.c:1798, 9046-9067 ; fsctrl.c:9458 ; deviosup.c:10303, 10380-10388, 10756-10785`
- Extrait : « If any bit is set now, raise STATUS_DELETE_PENDING to indicate that the space will soon be free (or can be made free). »

**Constat.** NtfsDeallocateClusters efface tout de suite les bits de $Bitmap (NtfsFreeBitmapRun) et garde la plage dans une liste en mémoire. FSCTL_GET_VOLUME_BITMAP copie les pages brutes de la bitmap : l'outil voit donc ces clusters libres. Un MOVE_FILE vers eux lève STATUS_DELETE_PENDING dans NtfsRunIsClear ; ALREADY_COMMITTED est réservé aux clusters vraiment alloués. NtfsDefragFile intercepte DELETE_PENDING jusqu'à dix fois. Il prend alors tous les fichiers, vide le journal (LfsFlushToLsn), libère les clusters retenus (NtfsFreeRecentlyDeallocated avec CleanVolume) et recommence : le déplacement réussit.

**Effet.** Pour XP et JkDefrag, la règle « attendre 5 s » est fausse : ils peuvent réutiliser aussitôt ce qu'ils viennent de quitter. En contrepartie, chaque cas coûte un vidage forcé de $LogFile, audible, et une sérialisation. Le README tire de cette règle des chiffres (769 fichiers cassés dans l'hypothèse d'un point de contrôle unique) dont la base est à revoir.

**Contre-vérification.** Prouvé. NtfsPreAllocateClusters (bitmpsup.c:1954-2002) appelle NtfsRunIsClear. Celui-ci lève ALREADY_COMMITTED si un bit est posé dans la bitmap brute, puis DELETE_PENDING si le bit n'apparaît qu'après NtfsAddRecentlyDeallocated (9046-9067). NtfsGetVolumeBitmap copie les pages brutes, sans masquer les clusters désalloués (fsctrl.c:9222-9470). NtfsDefragExceptionFilter intercepte DELETE_PENDING dix fois (deviosup.c:10303, 10745-10790). La tentative suivante prend tous les fichiers, fait LfsFlushToLsn puis NtfsFreeRecentlyDeallocated(CleanVolume=TRUE) (10360-10390, 10671). La citation de Russinovich (1997, NT 4) utilisée par l'app (DefragVolume.swift:326-339) ne décrit pas XP SP1.


### `ntfs-alloc-16-point-controle-5s` — confirmé

**Affirmation.** NTFS fait un point de contrôle toutes les cinq secondes, et c'est là que les clusters désalloués redeviennent réutilisables par l'allocateur.

- App : `Sources/Model/DefragStrategy.swift:577-580 ; README.md:1037-1038`
- XP : `base/fs/ntfs/logsup.c:902-906, 2260, 4500-4533 ; verfysup.c:1470-1490`
- Extrait : « LONGLONG FiveSecondsFromNow = -5*1000*1000*10; »

**Constat.** Le minuteur VolumeCheckpointTimer est armé à -5 s (FiveSecondsFromNow) dès qu'un volume est sali. À la fin du point de contrôle, NtfsFreeRecentlyDeallocated rend au cache des runs libres les plages dont le LSN est dépassé. Pour l'allocateur ordinaire, le délai est donc réel. Seul MOVE_FILE le contourne (voir ntfs-alloc-15).

**Contre-vérification.** Prouvé. Le minuteur est armé à −5 s quand un volume est sali (logsup.c:902-906). Il est réarmé à chaque point de contrôle, à 5 s, ou à 2 s si le précédent n'est pas fini (verfysup.c:1470-1490). La libération se fait dans NtfsFreeRecentlyDeallocated, appelé en fin de point de contrôle (logsup.c:2260). Seuls les lots dont le LSN précède le BaseLsn sont rendus (4502-4505) : un cluster désalloué peut attendre jusqu'à deux intervalles.


### `ntfs-alloc-17-move-vers-zone` — confirmé

**Affirmation.** Windows laisse un défragmenteur écrire dans la zone MFT : l'éviter est un choix de l'outil.

- App : `Sources/Model/DefragStrategy.swift:634-643`
- XP : `base/fs/ntfs/bitmpsup.c:833-862`
- Extrait : « Check to see if we are defragmenting ... goto Defragment; »

**Constat.** Avec un TargetLcn, NtfsAllocateClusters vérifie seulement que la plage est libre (NtfsRunIsClear), puis saute directement à l'allocation (goto Defragment). Aucun test ne porte sur MftZoneStart ou MftZoneEnd.

**Contre-vérification.** Prouvé. Avec TargetLcn, NtfsAllocateClusters appelle NtfsRunIsClear puis va à Defragment (bitmpsup.c:829-862 → 1328). NtfsPreAllocateClusters et NtfsRunIsClear ne testent ni MftZoneStart ni MftZoneEnd. De son côté, l'outil de XP passe MftZoneStart et MftZoneEnd à FindFreeSpaceChunk (dfrgntfs/mftdefrag.cpp:124-125) : l'évitement de la zone relève bien de l'outil.


### `ntfs-alloc-18-move-mft` — nuancé

**Affirmation.** MFTDefrag déplace la queue de $MFT, tout sauf son premier extent, vers un bloc neuf. Ce qu'elle quitte attend le point de contrôle, comme pour un fichier.

- App : `Sources/Model/DefragVolume.swift:397-413 ; WindowsXPStrategy.swift:384-403`
- XP : `base/fs/ntfs/deviosup.c:10112-10125, 10426-10431 ; base/fs/utils/dfrg/dfrgntfs/mftdefrag.cpp:118-133, 280-288`
- Extrait : « For the MFT we disallow moving the first 16 non-user files »

**Constat.** Le pilote accepte de déplacer $MFT au-delà des 16 premiers enregistrements (VCN ≥ FIRST_USER_FILE_NUMBER × taille d'enregistrement), et le premier extent d'origine, de 32 enregistrements ou plus, les contient bien. Il refuse les autres métafichiers système, $Bitmap, le fichier d'échange et le journal USN. Pour $MFT, chaque bloc prend tous les fichiers du volume et MftFlushResource. L'attente du point de contrôle appelle la même correction que ntfs-alloc-15.

**Effet.** La règle de déplacement est juste. L'opération est plus lourde que celle d'un fichier : tout le volume est sérialisé.

**Contre-vérification.** Le filtre du pilote est vérifié (deviosup.c:10112-10125). J'ai aussi ouvert l'outil lui-même, dfrgntfs/mftdefrag.cpp (le premier agent ne l'avait pas lu). Il ne déplace que la queue, tout sauf le premier extent, et seulement si ce premier extent dépasse 16 enregistrements (118-120) ; cela confirme le modèle. Deux écarts avec WindowsXPStrategy.swift:384-403 : XP agit dès que la MFT a plus d'un fragment (lMFTFragments > 1, ligne 122), là où l'app exige plus de deux extents (extents.count > 2) ; et XP cherche un trou de la taille de la MFT ENTIÈRE (GetMFTSize rend la taille totale, 283-288, et ne retranche le premier extent qu'après la recherche, ligne 131), là où l'app cherche la taille de la queue. Pour $MFT, chaque bloc prend tous les fichiers et MftFlushResource (deviosup.c:10426-10431).


### `ntfs-alloc-19-disposition-format` — nuancé

**Affirmation.** Sous XP, FORMAT pose $MFT à 3 Gio, ou au huitième du volume quand celui-ci est plus petit. $LogFile suit le miroir au milieu du volume (choix du modèle), et $Bitmap se pose derrière la zone MFT.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:84-101, 318-346`
- XP : `base/fs/utils/untfs/src/format.cxx:62, 329-340, 585-593, 618 ; logfile.cxx:231-233`
- Extrait : « MftLcn = (3 * ONE_GB) / ClusterSize; // put it at 3GB for now ... LogFileNearLcn = MftLcn - ((MFT_BITMAP_INITIAL_SIZE + ... »

**Constat.** C'est le code de FORMAT (untfs), pas le pilote. LOGFILE_PLACEMENT_V1 est défini. $MFT est à 3 Go (LCN 786 432 en clusters de 4 Ko, ce qui confirme Sedory) si le volume fait au moins 6 Go, à 1 Go entre 2 et 6 Go, au tiers en dessous de 2 Go. La règle « un huitième » est fausse : un volume de 6 à 24 Gio a sa MFT à 3 Gio, pas plus bas. Surtout, $LogFile est posé juste devant la bitmap de la MFT, elle-même devant $MFT, soit vers 3 Go et non au milieu du volume. Le plan en commentaire met $MftMirr, $AttrDef, $Bitmap et $UpCase à n/2.

**Effet.** Ce point est important pour le son d'une validation. Sous XP, journal et MFT sont voisins, à quelques dizaines de Mo, alors que le modèle fait courir le bras de 3 Go au milieu du disque pour chaque page de journal. $Bitmap serait au milieu, pas derrière la zone MFT.

**Contre-vérification.** Vérifié dans untfs. LOGFILE_PLACEMENT_V1 est défini dans chacun des fichiers qui l'utilisent : format.cxx:62, logfile.cxx:42, mftfile.cxx:51. Le code n'est donc pas mort. MftLcn vaut 3 Gio si le volume fait au moins 6 Gio, 1 Gio entre 2 et 6 Gio, n/3 en dessous (format.cxx:585-593). LogFileNearLcn = MftLcn − la bitmap de la MFT (618), et SetNextAlloc(NearLcn − taille) place le journal juste devant (logfile.cxx:225-233). $MFTMirr est à n/2 (mftref.cxx:182). $AttrDef, la racine et $Bitmap sont créés après lui (format.cxx:757, 904, 991) : ils suivent _NextAlloc (ntfsbit.cxx:460, 585), donc vers n/2. L'erreur du « huitième » ne touche aucun disque de la galerie : tous les volumes XP font 40 ou 80 Go. L'écart qui compte est celui de $LogFile et de $Bitmap.


### `ntfs-alloc-20-fichier-echange` — nuancé

**Affirmation.** pagefile.sys et hiberfil.sys à taille fixe sont posés d'un seul tenant tant que le volume a un bloc capable de les recevoir.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:429-434`
- XP : `base/fs/ntfs/bitmpsup.c:1110-1133`
- Extrait : « this code tries to prevent the paging file allocations from becoming fragmented. »

**Constat.** XP a bien une règle propre au fichier d'échange (FCB_STATE_PAGING_FILE) : si le run trouvé dans le cache fait moins de la moitié de ce qui reste, XP lit la bitmap et ne revient au cache que si le plus grand run de la bitmap ne suffit pas. Cette lecture est un premier trou depuis LastBitmapHint, pas une recherche du meilleur bloc. hiberfil.sys n'a pas ce drapeau et passe par l'allocation ordinaire.

**Effet.** Faible. Le fichier d'échange est contigu quand un run de la bitmap le permet, mais il n'est pas forcément dans le plus petit bloc.

**Contre-vérification.** Vérifié (bitmpsup.c:1110-1133). La règle FCB_STATE_PAGING_FILE bascule vers la bitmap quand le run trouvé fait moins de la moitié de ce qui reste. Le repli part de LastBitmapHint (1194-1201) et rend un premier trou. hiberfil.sys n'a pas ce drapeau. L'app les traite tous deux en .reservedContiguous (NTFSAllocator.swift:429-434).


### `ntfs-alloc-21-volume-plein` — nuancé

**Affirmation.** Quand aucun bloc ne tient le fichier hors de la zone, il est réparti sur les morceaux libres pris dans l'ordre du volume (scatter). La zone ne cède que si même cela échoue.

- App : `Sources/DiskCore/Allocators/NTFSAllocator.swift:411-424, 537-555`
- XP : `base/fs/ntfs/bitmpsup.c:9652-9661, 1076-1102 ; ntfsdata.h:393`
- Extrait : « There are no larger entries, but there might be smaller ones ... The entry at the end of the list should be the largest available. »

**Constat.** L'ordre des étapes est confirmé : XP fragmente avant de toucher à la zone, qui est retirée du cache (NtfsRemoveCachedLcn). Mais pour un fichier de données, NtfsLookupCachedLcnByLength est appelé avec AllowShorter : faute de run assez long, XP prend le plus grand run du cache, puis recommence pour le reste. Un appel s'arrête à MAXIMUM_RUNS_AT_ONCE, soit 128 runs. XP ne lit la bitmap, et ne réduit la zone, que quand le cache est vide.

**Effet.** Sur un volume plein, XP découpe un fichier en morceaux pris du plus grand au plus petit, donc peu nombreux et grands. Le scatter du modèle prend les premiers morceaux venus, petits compris, et fait plus d'extents.

**Contre-vérification.** Vérifié. AllowShorter vaut (type ≠ $INDEX_ALLOCATION) (bitmpsup.c:1076-1083). Faute de run assez long, la recherche prend le dernier de la liste par longueur, donc le plus grand (9652-9661). Tout run qui chevauche la zone est retiré du cache (1085-1100). La limite est MAXIMUM_RUNS_AT_ONCE = 128 (ntfsdata.h:393), sauf AllocateAll. Le scatter de l'app (NTFSAllocator.swift:540-557) prend les morceaux dans l'ordre du volume. XP les prend du plus grand au plus petit, et seulement quand aucun run du cache ne suffit : cela arrive dès qu'aucun trou n'est assez grand, pas seulement quand le volume est plein.


### Lacunes — Allocation NTFS au fil de l’eau, croissance de la MFT, FSCTL_MOVE_FILE

- **Au montage, la zone MFT est recalculée. Si le cluster qui suit la MFT n'est pas libre, la zone se repose sur le run de la bonne longueur le plus proche, n'importe où dans le volume. La réserve peut donc se déplacer d'un démarrage à l'autre.** — `base/fs/ntfs/bitmpsup.c:8566-8620 ; fsctrl.c:2475`. Change la disposition d'un volume qui a vécu (où les données sont tenues à l'écart) et le trou que les défragmenteurs évitent. *Contre-vérification :* Vérifié : fsctrl.c:2475 → bitmpsup.c:668, puis 1851-1868 et 8566-8620. L'app garde une zone qui ne fait que rétrécir (NTFSAllocator.swift:135-138, yieldMFTZone) et ne recalcule jamais. Correction : la zone reposée n'est pas le run « le plus proche de la bonne longueur ». C'est d'abord le run libre qui suit la MFT, quelle que soit sa longueur. À défaut, c'est le plus petit run qui atteint la taille par défaut ; le LCN ne départage qu'à longueur égale (ENHANCEMENT, 13158).
- **Surallocation progressive des fichiers écrits en plusieurs fois (×2, ×4, ×8, ×16 la taille de l'écriture, par handle), rendue à la fermeture (TRUNCATE_ON_CLOSE).** — `base/fs/ntfs/allocsup.c:1321-1400 ; write.c:2059, 2163`. Mécanisme majeur de contiguïté des fichiers qui grandissent. Il remplacerait le paquet fixe de 64 Ko et changerait la traîne de fragmentation mesurée. *Contre-vérification :* Vérifié : allocsup.c:1321-1403, write.c:2068-2163. Il n'y en a aucune trace dans Sources/ ni dans README.md, où writePacketBytes est un paquet fixe de 64 Ko (FileSystemProfile.swift:201). Précisions : la première extension ne reçoit aucun surplus (le compteur part de 0) ; le surplus peut coûter des runs supplémentaires tant que le cache répond ; les fichiers compressés et les quotas proches de leur limite allouent au plus juste.
- **Quand un MOVE_FILE vise des clusters tout juste libérés : DELETE_PENDING, puis acquisition de tous les fichiers, vidage forcé de $LogFile (LfsFlushToLsn) et libération immédiate des clusters retenus, avant une nouvelle tentative.** — `base/fs/ntfs/deviosup.c:10380-10388 ; bitmpsup.c:9061-9067`. Une écriture de journal audible, qui se produit précisément quand un défragmenteur réutilise ce qu'il vient de quitter, sans les 5 s d'attente que le modèle impose. *Contre-vérification :* Vérifié : bitmpsup.c:9061-9067, deviosup.c:10360-10390, 10671, 10745-10790 (dix tentatives). L'app impose au contraire la règle inverse : un refus jusqu'au point de contrôle (DefragVolume.swift:326-339 ; README.md:1034-1040).
- **Les runs libérés n'entrent dans le cache des runs libres qu'au point de contrôle. Dès lors, ce sont eux que le best-fit par longueur choisit en premier quand ils sont justes.** — `base/fs/ntfs/logsup.c:4513-4533 ; bitmpsup.c:4548-4633`. Les trous récents se comblent en quelques secondes, à l'opposé des trous persistants que produit la préférence du modèle pour le vierge. *Contre-vérification :* Vérifié : logsup.c:4500-4533 (NtfsAddCachedRun), bitmpsup.c:4548-4633. Seuls les lots dont le LSN précède le BaseLsn sont versés. L'app libère immédiatement et préfère le vierge (NTFSAllocator.swift:70-75, 616-618).
- **Perçage de trous dans la MFT (NtfsCreateMftHole) quand les enregistrements libres dépassent 1/8 de l'espace libre du volume.** — `base/fs/ntfs/mftsup.c:1619-1638 ; bitmpsup.c:2337 ; ntfs.h:414, 421-422`. Sur les volumes pleins qui ont beaucoup effacé, la MFT rend des clusters et devient trouée, ce qui touche la disposition et les lectures de la MFT au montage. *Contre-vérification :* Vérifié : mftsup.c:1610-1640, ntfs.h:414 et 421-422, bitmpsup.c:2337. Le mécanisme est conditionné à VCB_MFT_DEFRAG_PERMITTED et ENABLED (logsup.c:1059-1060), donc rare. L'app l'ignore : la MFT ne rétrécit jamais (NTFSAllocator.swift:130-133).
- **Un appel d'allocation s'arrête à 128 runs (MAXIMUM_RUNS_AT_ONCE). Pour un fichier non creux, l'appelant boucle, en autant de transactions séparées.** — `base/fs/ntfs/ntfsdata.h:393 ; bitmpsup.c:769-772, 970`. Borne la fragmentation par transaction et rythme le journal pour les très gros fichiers écrits sur un volume en miettes. *Contre-vérification :* La limite est vérifiée : ntfsdata.h:393, bitmpsup.c:769-772 et la boucle en 970-980. NtfsAddAllocation reboucle (allocsup.c:1475-1600). Les « transactions séparées » ne sont pas établies : le code de l'action de haut niveau qui les aurait découpées est commenté (allocsup.c:1476-1500 et 1560-1590), et les passages semblent rester dans la même transaction. L'app n'a pas cette borne.
- **La copie de MOVE_FILE s'arrête à la ValidDataLength : au-delà, les clusters sont réalloués sans aucune lecture ni écriture de données.** — `base/fs/ntfs/deviosup.c:10530-10560`. Un fichier préalloué, ou la queue non écrite d'un fichier, se déplace en silence, ce qui change la durée et le son de ces déplacements. *Contre-vérification :* Vérifié : deviosup.c:10530-10561. Le test porte sur UpperBound (VDL, ou ValidDataToDisk pour un flux compressé), et au-delà NtfsReallocateRange agit seul. Rien dans Sources/ ni dans README.md ne modélise la VDL.

## FAT : format et allocation


### `fat-01` — confirmé

**Affirmation.** FAT32 : la taille de cluster par défaut est une table en dur, fonction de la taille du volume en Gio : 4 Ko sous 8 Gio, 8 Ko jusqu'à 16, 16 Ko jusqu'à 32, 32 Ko au-delà.

- App : `Sources/DiskCore/FileSystemProfile.swift:151-167`
- XP : `base/fs/utils/ufat/src/rfatsa.cxx:1440-1452 (ComputeDefaultClusterSize, appelée par SetBpb l.1842)`
- Extrait : « // They match the ones that MS-DOS/Win95 use for FAT32 drives ... if (Sectors >= 64*1024*1024) sec_per_clus = 64; // >= 32GB »

**Constat.** ComputeDefaultClusterSize (et ComputeSecClus) de l'outil de formatage de XP applique exactement ces seuils en secteurs de 512 octets (≥ 16 Mi secteurs → 8 Ko, ≥ 32 Mi → 16 Ko, ≥ 64 Mi → 32 Ko, sinon 4 Ko), et le commentaire dit que ces seuils sont repris de MS-DOS/Win95 : ce qui en fait aussi une confirmation pour Windows 98, et pas seulement un indice. Les bornes sont des ≥, comme les `..<` de l'app. XP refuse en outre de formater un FAT32 de plus de 32 Go, ce qui ne touche aucun volume de la galerie (8,4 Go au plus).

**Contre-vérification.** Seuils relus : ≥ 64 Mi secteurs → 64 secteurs par cluster, ≥ 32 Mi → 32, ≥ 16 Mi → 16, sinon 8, avec le commentaire « They match the ones that MS-DOS/Win95 use for FAT32 drives ». Les `..<` de l'app (FileSystemProfile.swift:159-166) collent aux ≥. Deux réserves. (1) La seconde référence (4450-4459) est REAL_FAT_SA::ComputeSecClus : ses seuls appels, dans entry.cxx:819-823 et 1011-1015, sont sous `#if 0`. C'est du code mort, qui ne doit pas servir de preuve. (2) « XP refuse de formater un FAT32 de plus de 32 Go » n'est prouvé ni par ufat ni par le code cité. ufat ne refuse qu'au-delà de 2^32 secteurs (entry.cxx:825, rfatsa.cxx:1688). Seul un commentaire de fastfat/write.c (~1730) dit « we plan to disallow in format for FAT32 ». Il faut retirer cette incise ou la marquer non sourcée.


### `fat-02` — nuancé

**Affirmation.** FAT16 : FORMAT prend la plus petite puissance de deux (à partir de 2 Ko) qui garde le volume sous 65 524 clusters, en divisant la taille brute du volume par celle du cluster.

- App : `Sources/DiskCore/FileSystemProfile.swift:113-125`
- XP : `base/fs/utils/ufat/src/rfatsa.cxx:60 ; 1459-1460 ; 1049-1098 ; 1534-1553`
- Extrait : « #define MAX_CLUS_BIG       65526    // Maximum number of clusters for FAT16 ... case LARGE16: sec_per_clus = 1; »

**Constat.** Le format de XP part de 1 secteur par cluster (512 octets), et non de 2 Ko. Il double la taille tant que ValidateClusterSize répond TOO_SMALL. Il compte les clusters après avoir déduit les secteurs réservés, la racine et les deux FAT, et accepte jusqu'à 65 526 clusters (MAX_CLUS_BIG), là où l'app plafonne à 65 524 sur la taille brute. Sur les volumes de la galerie (170, 210, 340, 850 et 1 080 Mo), les deux calculs donnent la même taille : 4, 4, 8, 16 et 32 Ko. L'écart n'apparaît qu'à une frontière exacte : 1 Gio tout rond donne 16 Ko à XP et 32 Ko à l'app. Le point de départ à 2 Ko correspond à la table de MS-DOS, que XP ne recopie pas (XP descend à 512 octets sous 32 Mo). Pour DOS et 9x, XP ne vaut donc qu'indice.

**Effet.** Aucun sur la galerie. Un volume FAT16 dont la taille tombe pile sur une puissance de deux recevrait un cluster deux fois trop gros.

**Contre-vérification.** Tout est vérifié. LARGE16 part de sec_per_clus = 1, ValidateClusterSize compte les clusters après la zone réservée, la racine et les FAT (ComputeClusters), puis rend TOO_SMALL au-delà de MAX_CLUS_BIG = 65526, et la boucle de 1543-1553 double la taille. Le calcul pour 1 Gio tient : environ 65 518 clusters de 16 Ko, sous 65 526, donc 16 Ko chez XP et 32 Ko dans l'app. Détail : ComputeSecClus (code mort, voir fat-01) ferait comme l'app, sur la taille brute avec un seuil de 65 526. Le chemin réellement appelé est celui qu'a décrit le vérificateur.


### `fat-03` — nuancé

**Affirmation.** FAT16 adresse au plus 65 524 clusters, et FAT32 au plus 268 435 444.

- App : `Sources/DiskCore/FileSystemProfile.swift:93, 138`
- XP : `base/fs/utils/ufat/src/rfatsa.cxx:59-63 ; base/fs/fastfat/fat.h:498-499`
- Extrait : « #define MAX_CLUS_BIG32     0x0FFFFFF6 ... (IsBpbFat32(B) ? 32 : (FatNumberOfClusters(B) < 4087 ? 12 : 16)) »

**Constat.** Les plafonds de XP sont 65 526 clusters en FAT16 (MAX_CLUS_BIG) et 0x0FFFFFF6, soit 268 435 446, en FAT32. Côté pilote, fastfat n'impose pas de plafond au FAT16 : le type se déduit du BPB (FAT32 si le BPB le dit, FAT12 sous 4 087 clusters, FAT16 sinon). Les valeurs de l'app sont celles de la spécification publiée par Microsoft ; celles de XP les dépassent de deux clusters.

**Effet.** Négligeable.

**Contre-vérification.** MAX_CLUS_BIG = 65526 et MAX_CLUS_BIG32 = 0x0FFFFFF6 sont confirmés. La macro FatIndexBitSize déduit le type du BPB : FAT32 si IsBpbFat32, 12 bits sous 4 087 clusters, 16 sinon. Les références de l'app (lignes 93 et 138) sont exactes.


### `fat-04` — nuancé

**Affirmation.** Secteurs réservés en tête de partition : un seul en FAT16, trente-deux en FAT32.

- App : `Sources/DiskCore/FormatOverhead.swift:27-34 ; Sources/Model/VolumeLayout.swift:43-51`
- XP : `base/fs/utils/ufat/src/rfatsa.cxx:394 ; 1698-1711 ; 76 ; 972-996 et 1066-1088 ; 1935-1944`
- Extrait : « _sec_per_boot = max((32 * 512) / sector_size, 32); ... #define FAT_FIRST_DATA_CLUSTER_ALIGNMENT    (4*1024) »

**Constat.** Les deux valeurs de base sont justes. _sec_per_boot vaut max(1, 512/taille de secteur) en FAT12/16, et max(32·512/taille de secteur, 32) en FAT32. Mais le format de XP ajoute ensuite des secteurs réservés (_AdditionalReservedSectors) pour aligner le début de la zone de données sur 4 Ko (FAT_FIRST_DATA_CLUSTER_ALIGNMENT). Rien ne dit que le FORMAT de 9x/DOS faisait ce bourrage : pour la galerie (9x), 1 et 32 restent la bonne valeur ; ce bourrage est propre à XP.

**Effet.** Un volume formaté sous XP décale ses tables et ses données de 0 à 7 secteurs. Inaudible.

**Contre-vérification.** _sec_per_boot vaut max(1, 512/taille de secteur), puis max(32·512/taille de secteur, 32) pour FAT32. _AdditionalReservedSectors vient de la boucle d'alignement sur 4 Ko et s'ajoute à ReservedSectors, sauf pour un Sony Memory Stick. La boucle existe aussi en FAT16 (1066-1088), et ne s'applique pas aux disquettes. Pour 9x, XP n'est qu'un indice.


### `fat-05` — nuancé

**Affirmation.** FAT32 : l'amorçage occupe trois secteurs, FSINFO les suit, une copie de secours est posée au secteur 6. Au montage, le pilote lit deux secteurs en tête : l'amorçage et FSINFO.

- App : `Sources/Model/VolumeLayout.swift:45-48 ; 414-423`
- XP : `base/fs/utils/ufat/src/rfatsa.cxx:1932-1933 ; 2996-3024 (disposition du code d'amorçage) ; 3039-3045 (sauvegarde vers 6-8) ; base/fs/fastfat/verfysup.c:750-765`
- Extrait : « _sector_zero.Bpb.FSInfoSec = 1; _sector_zero.Bpb.BkUpBootSec = max(6, ...); // Backup the first 3 sectors to sectors 6-8 »

**Constat.** FSINFO est au secteur 1 (FSInfoSec = 1), entre les secteurs du code d'amorçage : XP écrit le premier secteur de code au secteur 0, le deuxième au secteur 1 (celui qui porte FSINFO), la signature du troisième au secteur 2, et le reste du code au secteur 12. Il sauvegarde les secteurs 0 à 2 aux secteurs 6 à 8 (BkUpBootSec = 6). « FSINFO suit » les trois secteurs d'amorçage est donc inexact. En revanche, lire deux secteurs à partir du début (mountAccesses) couvre bien l'amorçage et FSINFO. Le pilote de XP réécrit d'ailleurs ces deux secteurs d'un seul coup parce que FSINFO est au secteur 1.

**Effet.** Aucun sur le son. Seul le docstring est à corriger.

**Contre-vérification.** FSInfoSec = 1 et BkUpBootSec = 6 sont confirmés. Le deuxième bloc de 512 octets du code d'amorçage va au pseudo-secteur 1, la signature au secteur 2, le reste au secteur 12. Les secteurs 0 à 2 sont recopiés en 6 à 8 (l.3044, pas dans 3003-3029). Le pilote réécrit les secteurs 0 et 1 d'un seul coup quand FsInfoSector == 1. Le docstring de VolumeLayout.swift:44-47 (« FSINFO suit » trois secteurs d'amorçage) est donc inexact. mountAccesses (2 secteurs depuis startLBA, l.419) couvre bien l'amorçage et FSINFO.


### `fat-06` — confirmé

**Affirmation.** Deux copies de la table d'allocation. Chaque validation réécrit, dans FAT1 puis dans FAT2, les mêmes secteurs de table.

- App : `Sources/DiskCore/FormatOverhead.swift:13-15, 67 ; Sources/Model/VolumeLayout.swift:296-312`
- XP : `base/fs/utils/ufat/src/rfatsa.cxx:1711, 1928 (ExtFlags = 0) ; base/fs/fastfat/write.c:759-779`
- Extrait : « IoRuns[Fat].Lbo = Fat * BytesPerFat + StartingDirtyVbo; »

**Constat.** Le format pose Fats = 2. Quand fastfat écrit la FAT, il émet une E/S par copie, au même décalage à l'intérieur de chaque copie (Lbo = Fat·BytesPerFat + décalage), et pour la même longueur. Le miroir vaut aussi pour le FAT32 formaté par XP : ExtFlags = 0, donc miroir actif.

**Contre-vérification.** Un IoRun par copie, Lbo = Fat·BytesPerFat + StartingDirtyVbo, même longueur. Nuance mineure : fastfat émet les deux écritures par FatMultipleAsync, en parallèle, et pas « FAT1 puis FAT2 ». L'ordre physique reste celui du disque. Le modèle (VolumeLayout.swift:309-311) fait la même chose.


### `fat-07` — confirmé

**Affirmation.** Taille d'une copie de la table : (n + 2) entrées de 2 octets (FAT16) ou de 4 octets (FAT32), arrondie au secteur. Le calcul est circulaire et se résout par itérations, comme dans FORMAT.

- App : `Sources/DiskCore/FormatOverhead.swift:43-59, 72-93`
- XP : `base/fs/utils/ufat/src/rfatsa.cxx:976-986 ; 1070-1076 ; ComputeClusters 1202-1300`
- Extrait : « *FatSize = RoundUpDiv((clusters+2) * fat_entry_size , SectorSize); »

**Constat.** ValidateClusterSize calcule FatSize = RoundUpDiv((clusters+2)·taille d'entrée, SectorSize), à partir des clusters obtenus par ComputeClusters sur les secteurs qui restent après la zone réservée et la racine. La boucle de XP porte sur le bourrage d'alignement plutôt que sur une convergence du nombre de clusters, mais le résultat est le même.

**Contre-vérification.** FatSize = RoundUpDiv((clusters+2)·taille d'entrée, SectorSize) est confirmé. ComputeClusters procède lui-même par pas successifs (incréments doublés), si bien que « se résout par itérations » est juste aussi pour XP. Seul le bourrage d'alignement propre à XP peut décaler le compte de quelques clusters.


### `fat-08` — confirmé

**Affirmation.** La racine d'un FAT16 a une taille fixe de 512 entrées de 32 octets (32 secteurs), posée entre la seconde FAT et les données. Elle ne prend aucun cluster.

- App : `Sources/DiskCore/FormatOverhead.swift:24-41 ; Sources/Model/VolumeLayout.swift:128-136`
- XP : `base/fs/utils/ufat/src/rfatsa.cxx:4363-4412 ; 445-449`
- Extrait : « if (_ft == LARGE32) { return 0; } ... return 512; »

**Constat.** ComputeRootEntries renvoie 512 pour un disque dur (les autres valeurs ne concernent que les disquettes), et 0 en FAT32. Le début des données se calcule comme réservés + FAT·nombre de FAT + entrées de racine·32, dans cet ordre.

**Contre-vérification.** ComputeRootEntries rend 0 en FAT32, 112, 224, 240, 192 ou 68 pour les disquettes, et 512 sinon. Le décalage des données vaut réservés + FAT·nombre de FAT + entrées de racine·32. Dans l'app, rootLBA et dataStartLBA (VolumeLayout.swift:129-137) suivent le même ordre.


### `fat-09` — confirmé

**Affirmation.** La racine d'un FAT16 ne grandit jamais, mais le modèle ne refuse pas la 513ᵉ entrée.

- App : `Sources/DiskCore/Simulator.swift:805-810`
- XP : `base/fs/fastfat/dirsup.c:326-340 (FatDefragDirectory) ; 374-385 (STATUS_CANNOT_MAKE) ; base/fs/fastfat/cachesup.c:500-505 (STATUS_DISK_FULL)`
- Extrait : « Make sure we are not trying to expand the root directory on non FAT32.  FAT16 and FAT12 have fixed size allocations. »

**Constat.** XP refuse d'agrandir la racine d'un FAT12/16 (STATUS_CANNOT_MAKE à la création, STATUS_DISK_FULL dans FatPrepareWriteDirectoryFile). Il tente d'abord de compacter la racine (FatDefragDirectory) quand l'échec ne vient que de l'éparpillement des entrées effacées. L'app reconnaît qu'elle n'applique pas cette borne. Pour MS-DOS et 9x, le fait vient du format et ne dépend pas du pilote.

**Effet.** Un scénario qui poserait plus de 512 entrées (noms longs compris) à la racine d'un FAT16 produirait un volume impossible. Dans la galerie, c'est peu probable.

**Contre-vérification.** Vérifié. FatDefragDirectory n'est tentée que pour la racine d'un non-FAT32 de 0x40000 octets au plus. L'aveu de l'app se trouve à Simulator.swift:806-808 (« le modèle ne refuse pas la 513ᵉ »), et fit() sort sans rien faire pour une racine sans clusters.


### `fat-10` — confirmé

**Affirmation.** En FAT32, la racine est une chaîne de clusters comme un répertoire ordinaire. Le formatage la pose au premier cluster de données.

- App : `Sources/DiskCore/DiskGenerator.swift:301-310 ; Sources/DiskCore/Simulator.swift:795-800`
- XP : `base/fs/utils/ufat/src/rfatsa.cxx:1931 ; base/fs/fastfat/fsctrl.c:5200-5201, 5217-5220`
- Extrait : « _sector_zero.Bpb.RootDirStrtClus = 2; ... We'll allow movefile on the root dir if its fat32, since the root dir is a real chained file there. »

**Constat.** Le format de XP écrit RootDirStrtClus = 2, le premier cluster de données : c'est le cluster 0 de la bitmap de l'app, où tombe la racine matérialisée à curseur nul. WriteNewFats peut décaler ce cluster s'il est défectueux. fastfat traite la racine FAT32 comme un fichier chaîné, et FSCTL_MOVE_FILE l'accepte (sauf pour son premier cluster).

**Contre-vérification.** RootDirStrtClus = 2 et le FAT32 accepté par FatMoveFile pour la racine sont confirmés. Côté app, DiskGenerator.swift:306-309 donne fixedRoot = false au FAT32, et Simulator.swift:796-799 le dit. Que la racine tombe au cluster 0 de la bitmap suppose qu'elle soit matérialisée avant toute autre allocation. addEntry précède l'allocation du fichier, c'est donc plausible, mais je ne l'ai pas prouvé de bout en bout.


### `fat-11` — nuancé

**Affirmation.** VFAT et FAT32 allouent à partir d'un curseur next-free : dernier cluster servi plus un, persisté dans FSINFO. Une libération ne déplace pas le curseur.

- App : `Sources/DiskCore/Allocators/FATAllocator.swift:14-18, 48-49, 149, 204-209`
- XP : `base/fs/fastfat/allocsup.c:243-282 ; 2841 (FatUnreserveClusters dans FatDeallocateDiskSpace) ; 597-603 ; base/fs/fastfat/verfysup.c:856-863`
- Extrait : « if ((FAT_INDEX) < (VCB)->ClusterHint) { (VCB)->ClusterHint = (FAT_INDEX); } ... deference for Win9x FAT32 - NT will never look at this information. »

**Constat.** Chez XP, le curseur (Vcb->ClusterHint) avance bien derrière chaque allocation (FatReserveClusters, qui le recale sur le prochain bit libre s'il tombe sur un cluster occupé). Mais toute libération le ramène au cluster libéré s'il est plus bas (FatUnreserveClusters, appelé par FatDeallocateDiskSpace). Au montage, il repart du premier cluster libre du volume. Et NT ne lit jamais le NextFreeCluster de FSINFO : il ne l'écrit que par égard pour Win9x. Sous XP, la texture est donc plus proche d'un premier-libre roulant, qui rebouche les trous dès qu'ils s'ouvrent, que de vagues séparées par des retours au début. Pour Windows 95/98 (les scénarios VFAT et FAT32), XP n'est qu'un indice. Le commentaire sur FSINFO laisse entendre que 9x s'en sert, mais le code ne dit rien du comportement de VFAT sur libération.

**Effet.** Pour un FAT monté sous XP (et défragmenté par les outils de l'API), c'est un tout autre schéma de fragmentation : moins de vagues, trous rebouchés au fil de l'eau. Pour la galerie 9x, l'hypothèse reste plausible mais sans source ; elle mériterait d'être signalée comme telle.

**Contre-vérification.** Tout est confirmé. J'ajoute une précision. Sur un FAT32 à plusieurs fenêtres, ClusterHint est relatif à la fenêtre courante. Au montage, il vaut le premier cluster libre de la fenêtre choisie par FatSelectBestWindow, pas celui du volume. FatUnreserveClusters n'est appelée, avec un indice relatif à la fenêtre, que pour les clusters de la fenêtre courante. FSINFO.NextFreeCluster est écrit depuis ce ClusterHint relatif, et aucune lecture de ces champs n'existe dans fastfat (le seul accès est dans verfysup.c).


### `fat-12` — contredit

**Affirmation.** Toute la famille FAT sert les premiers clusters libres rencontrés depuis le curseur, morceau par morceau, sans chercher de plage contiguë et sans rien réserver. Seul le fichier d'échange cherche un trou d'un seul tenant.

- App : `Sources/DiskCore/Allocators/FATAllocator.swift:5-7, 103-151`
- XP : `base/fs/fastfat/allocsup.c:297-303 ; 2093-2115 ; 2270-2345 ; base/ntos/rtl/bitmap.c:455-470`
- Extrait : « Index = RtlFindClearBits( &Vcb->FreeClusterBitMap,  ClustersRemaining,  0); ... ClustersFound = RtlFindLongestRunClear( &Vcb->FreeClusterBitMap, &Index ); »

**Constat.** FatAllocateDiskSpace de XP cherche d'abord une plage contiguë de la taille entière demandée à partir du curseur, en repartant au début si besoin (FatFindFreeClusterRun → RtlFindClearBits, qui repart du début de la bitmap). Faute de plage, il prend ce qui est libre du curseur jusqu'à la fin de la fenêtre. Ensuite, il prend la première plage capable de tout contenir depuis le début de la fenêtre, et seulement en dernier recours les plus longues plages libres (RtlFindLongestRunClear). Le « first-fit contigu », que l'app réserve au fichier d'échange, est donc sous XP la règle de toute allocation dont la taille est connue. Rien n'en dit autant de VFAT (9x) : non vérifiable pour la galerie.

**Effet.** Sur un FAT écrit par XP, les fichiers copiés d'un bloc resteraient contigus tant qu'un trou assez grand existe : beaucoup moins de fichiers éclatés que dans le modèle. Sans effet sur la galerie 9x si VFAT se comportait vraiment comme l'app le suppose.

**Contre-vérification.** Le code est lu correctement. Premier essai : une plage contiguë de la taille entière depuis le curseur, par RtlFindClearBits, qui repart au début de la bitmap. Sinon : la plage curseur → fin de fenêtre, si elle est entièrement libre ; puis RtlFindClearBits depuis 0 ; puis RtlFindLongestRunClear. Le verdict vise la généralisation de l'app : « toute la famille FAT » partage ce mécanisme. Un pilote FAT réel (NT) fait autrement. La politique relève donc du pilote, pas du format. Pour les scénarios modélisés (DOS et 9x, puisque tous les volumes FAT de la galerie datent de 1993 à 1999 et que ceux de 2003 sont en NTFS), le comportement reste non vérifiable.


### `fat-13` — contredit

**Affirmation.** FAT ne réserve rien : agrandir un fichier, c'est allouer de nouveau au curseur, si bien que la suite d'un fichier peut atterrir à l'autre bout du volume.

- App : `Sources/DiskCore/Allocators/FATAllocator.swift:159-170`
- XP : `base/fs/fastfat/allocsup.c:1283-1312 ; 2086-2110 (le premier essai n'est gardé que si StartingCluster == indice) ; 2270-2330`
- Extrait : « Get the first cluster following the current allocation. ... FatAllocateDiskSpace( IrpContext, Vcb, FatGetIndexFromLbo(Vcb,LastAllocatedLbo + 1), ... »

**Constat.** FatAddFileAllocation de XP passe à FatAllocateDiskSpace le cluster qui suit la fin actuelle du fichier comme indice absolu. Si ce cluster est libre, le fichier est prolongé en place. Sinon le pilote tente la plage indice→fin de fenêtre, puis passe au « pot luck » : la première plage capable de tout contenir depuis le début de la fenêtre, ou la plus longue. Le curseur du volume n'intervient pas. C'est le comportement de NT ; pour VFAT (9x), non vérifiable.

**Effet.** Sous XP, un .doc réenregistré ou un répertoire qui grandit reste contigu bien plus souvent. Le modèle 9x n'est pas contredit par ce code, seulement privé d'appui.

**Contre-vérification.** Confirmé. Quand un indice absolu est passé, le premier essai n'est accepté que s'il tombe exactement sur l'indice, c'est-à-dire en prolongement direct. Sinon le pilote tente indice → fin de fenêtre, puis passe au « pot luck ». Même portée que pour fat-12 : contredit comme généralisation « FAT », non vérifiable pour 9x et DOS, les seuls modélisés.


### `fat-14` — nuancé (vérificateur : contredit)

**Affirmation.** Un programme qui ne connaît pas la taille de son fichier le fait grandir par paquets d'un cluster sur FAT : le pilote prolonge la chaîne à chaque écriture qui franchit la fin du dernier cluster.

- App : `Sources/DiskCore/FileSystemProfile.swift:98-105 ; README.md:636-651`
- XP : `base/fs/fastfat/write.c:1664-1760`
- Extrait : « We are going to try and allocate a bigger chunk than we actually need in order to maximize FastIo usage. ... if (Multiplier > 32) { Multiplier = 32; } »

**Constat.** fastfat, sur une écriture qui étend un fichier déjà alloué, alloue par anticipation jusqu'à 32 fois l'extension nécessaire (multiplicateur fonction de l'espace libre), puis marque le fichier FCB_STATE_TRUNCATE_ON_CLOSE : le surplus est rendu à la fermeture. Seule la toute première allocation d'un fichier se fait à la taille exacte. L'app parle de VFAT et de MS-DOS : pour eux, XP n'est qu'un indice et l'affirmation reste non vérifiable, mais elle n'est pas vraie de NT.

**Effet.** Sur un FAT écrit par XP, un fichier produit en flux se poserait en quelques grands morceaux contigus, pas cluster par cluster.

**Contre-vérification.** Le code est bien lu : allocation anticipée jusqu'à ×32 dès la deuxième allocation d'un fichier, FCB_STATE_TRUNCATE_ON_CLOSE, rien de tel à la première allocation. Mais l'affirmation de l'app, dans son docstring (FileSystemProfile.swift:98-104), porte explicitement sur « VFAT, comme le pilote de MS-DOS », pas sur NT. Le code de XP ne la contredit donc pas : il montre qu'elle est fausse pour NT et ne dit rien pour DOS et 9x. Seul le README (l.636-639, « un cluster sur FAT, où le pilote prolonge la chaîne ») généralise à tort. D'où « nuancé » plutôt que « contredit ».


### `fat-15` — nuancé

**Affirmation.** Le curseur de FAT32 va jusqu'à la fin du volume, puis revient au début : chaque retour est une vague de fragmentation.

- App : `Sources/DiskCore/Allocators/FATAllocator.swift:14-18, 130-141 ; Sources/DiskCore/ClusterBitmap.swift:366-368`
- XP : `base/fs/fastfat/allocsup.c:305-320 ; 344-420 ; 553-572 ; 2280-2300, 2335-2345, 2350-2420`
- Extrait : « If there are more clusters on the volume than can be represented by this many bytes of bitmap, the FAT will be split into "buckets" ... 1.  First window with >50% free clusters »

**Constat.** Sous XP, un FAT32 de plus de 65 536 clusters est découpé en fenêtres de 2^16 clusters (256 Mo en clusters de 4 Ko). La bitmap de clusters libres ne décrit que la fenêtre courante, et le retour au début se fait au début de cette fenêtre, pas du volume. Quand une fenêtre est pleine, le pilote passe à la suivante s'il écrivait de façon contiguë, sinon à la première fenêtre libre à plus de 50 % (à défaut la première vide, puis la plus libre) : c'est FatSelectBestWindow. Au montage, il choisit aussi la fenêtre par cette règle. Pour Windows 98, non vérifiable.

**Effet.** Sur un FAT32 géré par XP, l'écriture reste concentrée dans une tranche de 256 Mo et y rebouche ses trous ; le bras ne balaie pas tout le volume avant de revenir.

**Contre-vérification.** Les fenêtres de 2^16 clusters, le retour au début dans la bitmap de la fenêtre et la fenêtre suivante quand l'écriture est contiguë sont confirmés. FatSelectBestWindow se lit plus précisément ainsi : les fenêtres entièrement vides sont écartées de la première règle. Le pilote prend la première fenêtre non vide libre à au moins 50 % (≥, pas >). À défaut, la première fenêtre vide ; sinon, la plus libre. Les FAT32 de la galerie (4,3 à 8,4 Go en clusters de 4 Ko) auraient 16 à 32 fenêtres sous XP. Pour Windows 98, non vérifiable.


### `fat-16` — nuancé

**Affirmation.** Au montage d'un FAT32, le pilote lit FSINFO (compte de clusters libres et curseur next-free), précisément pour ne pas parcourir la table, puis le premier secteur de la FAT. Il met ensuite les secteurs de la table en cache à la demande.

- App : `Sources/Model/VolumeLayout.swift:414-423`
- XP : `base/fs/fastfat/allocsup.c:553-596 ; base/fs/fastfat/verfysup.c:856-863`
- Extrait : « Read the fat and count up free clusters. ... NT will never look at this information. »

**Constat.** Pour Windows 98 (le système des scénarios FAT32), c'est plausible, et le commentaire de fastfat confirme en creux que FSINFO existe pour Win9x. XP fait l'inverse : FatSetupAllocationSupport parcourt toute la FAT au montage (FatExamineFatEntries de 2 à N) pour compter les clusters libres de chaque fenêtre et bâtir la bitmap. Il ne lit jamais FSINFO, qu'il se contente de réécrire quand le volume redevient propre.

**Effet.** Aucun pour la galerie (Win98). Un démarrage XP sur FAT32 lirait au montage toute la table, plusieurs mégaoctets, en tête du volume : une longue lecture séquentielle au bord.

**Contre-vérification.** Confirmé. Même avec une seule fenêtre, le passage à la fenêtre par FatExamineFatEntries (l.587-594) lit toute la FAT pour bâtir la bitmap. Sous XP, un montage lit donc toujours la table entière. L'app le fait déjà pour FAT16 (VolumeLayout.swift:410-412), pas pour FAT32, ce qui convient à Win98.


### `fat-17` — nuancé

**Affirmation.** En montant un volume FAT, le pilote le déclare en service en écrivant un seul secteur : l'octet d'état en tête de la première table.

- App : `Sources/Model/VolumeLayout.swift:262-268`
- XP : `base/fs/fastfat/verfysup.c:636-641 ; 800-830 ; 952-960`
- Extrait : « For compatibility with Win9x, we manipulate both the historical DOS (on==clean in index 1 of the FAT) and NT (on==dirty in the CurrentHead field of the BPB) dirty bits. »

**Constat.** XP manipule les deux marques : le bit « sale » du BPB (champ CurrentHead du secteur 0, marque NT) et le bit « propre » de l'entrée 1 de la FAT (marque historique de DOS, que XP garde pour Win9x). L'entrée 1 passe par la FAT, donc par ses deux copies. Au passage à l'état propre, le secteur 0 est réécrit avec FSINFO (deux secteurs). La marque en FAT[1] est bien celle de DOS/9x, ce qui confirme l'app pour la galerie. Sous XP, il faut y ajouter l'écriture du secteur d'amorçage.

**Effet.** Négligeable pour 9x. Sous XP, une ou deux écritures de plus en tête du volume à chaque bascule propre ou sale.

**Contre-vérification.** Confirmé : CurrentHead du secteur d'amorçage pour NT et FAT_DIRTY_BIT_INDEX de la FAT pour DOS et 9x. L'entrée de FAT passe par FatSetFatEntry, donc par les deux copies. À noter aussi que le passage à l'état sale réécrit lui aussi le secteur d'amorçage, pour positionner FAT_BOOT_SECTOR_DIRTY.


### `fat-18` — confirmé

**Affirmation.** FSCTL_MOVE_FILE sur FAT refuse de déplacer le premier cluster d'un répertoire (StartingVcn == 0), parce que les sous-répertoires portent ce numéro dans leur entrée `..`. Le reste de la chaîne se déplace.

- App : `Sources/Model/DefragVolume.swift:306-321`
- XP : `base/fs/fastfat/fsctrl.c:5190-5227 ; app Sources/Model/DefragVolume.swift:306-324`
- Extrait : « we cannot move the first cluster because sub-directories have this cluster number in them and there is no safe way to simultaneously update them all. »

**Constat.** FatMoveFile renvoie STATUS_INVALID_PARAMETER pour un répertoire dès que StartingVcn vaut 0, avec le commentaire cité par l'app. La racine d'un FAT16 est refusée entière ; celle d'un FAT32 est acceptée, sauf son premier cluster. Le code de l'app ne distingue pas la racine FAT16, ce qui n'a pas d'importance puisqu'elle ne vit pas dans les clusters.

**Contre-vérification.** Condition relue : UserDirectoryOpen && (racine d'un non-FAT32 || StartingVcn == 0) → STATUS_INVALID_PARAMETER. Le commentaire est cité mot pour mot par l'app. moveFileAccepts ne distingue pas la racine d'un FAT16, ce qui est sans effet puisqu'elle n'est pas dans les clusters.


### `fat-19` — confirmé

**Affirmation.** Une tranche de FSCTL_MOVE_FILE qui dépasse la fin du fichier n'est pas refusée : FatComputeMoveFileParameter la borne à la taille allouée.

- App : `Sources/Model/JKDefragStrategy.swift:835-846 ; LEDGER-EXPERTS.md:463`
- XP : `base/fs/fastfat/fsctrl.c:5880-5970 (FatComputeMoveFileParameter)`
- Extrait : « ByteCount - Supplies the request length to reallocate.  This will be bounded by allocation size on return. ... BytesToReallocate - ... bounded by the file allocation size and a 0x40000 boundry. »

**Constat.** ByteCount est ramené à AllocationSize − FileOffset, ou à 0 si l'on part au-delà. Il y a en plus un découpage que l'app ne mentionne pas : chaque passage est limité à une frontière de 0x40000 octets (256 Ko) du fichier (BytesToReallocate), et FatMoveFile boucle jusqu'à épuiser la demande.

**Effet.** Voir fat-20 pour l'effet du découpage de 256 Ko.

**Contre-vérification.** ByteCount est borné à AllocationSize − FileOffset, ou à 0 au-delà, et BytesToReallocate à la frontière de 0x40000. Les références de l'app, JKDefragStrategy.swift:835-846 et LEDGER-EXPERTS.md:463 (table des questions tranchées), sont exactes.


### `fat-20` — contredit

**Affirmation.** FSCTL_MOVE_FILE confie la copie au système de fichiers, par blocs de 64 Kio (LARGE_BUFFER_SIZE, ntfsdata.h). Valider un déplacement coûte ensuite une écriture de chaque copie de la table et de l'entrée de répertoire (une validation par déplacement). Le modèle applique cette règle aussi aux volumes FAT.

- App : `Sources/Model/WindowsXPStrategy.swift:49-52, 93, 420-424 ; Sources/Model/DefragStrategy.swift:501-526 ; Sources/Model/VolumeLayout.swift:291-312`
- XP : `base/fs/fastfat/fsctrl.c:5384-5430 ; 5440-5545 ; 5560-5620`
- Extrait : « FatFlushFatEntries( IrpContext, Vcb, TargetCluster, BytesToReallocate >> ClusterShift ); ... SetFlag( IoGetNextIrpStackLocation(IoIrp)->Flags, SL_WRITE_THROUGH ); »

**Constat.** Sur un volume FAT, c'est fastfat qui déplace, pas NTFS. Pour chaque tranche de 256 Ko au plus, FatMoveFile fait dans l'ordre : allocation exacte de la cible ; écriture immédiate des entrées FAT de la cible (FatFlushFatEntries) ; lecture de la source par le cache ; écriture de toute la tranche en une seule E/S synchrone write-through ; écriture de la seconde soudure de chaîne ; écriture de l'entrée de répertoire (si le premier cluster bouge) ou de la première soudure ; libération de la source ; vidage du cache du disque (FatHijackIrpAndFlushDevice). Les 64 Kio de ntfsdata.h ne concernent que NTFS.

**Effet.** Pour XP, JkDefrag et UltraDefrag sur les volumes FAT de la galerie : le bras revient à la table en tête du volume trois fois par tranche de 256 Ko (avant et après la copie), et non une fois par fichier. Les gros fichiers produisent donc un va-et-vient régulier entre données et table, et la copie se fait en écritures de 256 Ko, pas de 64 Ko.

**Contre-vérification.** La séquence est confirmée : FatAllocateDiskSpace(ExactMatchRequired = TRUE), puis FatFlushFatEntries de la cible, puis CcMapData de la source, puis une écriture synchrone SL_WRITE_THROUGH de toute la tranche, puis la seconde soudure et son vidage, puis l'entrée de répertoire (si le premier cluster bouge) ou la première soudure, puis FatDeallocateDiskSpace (non vidé tout de suite : « We don't have to commit this right now »), puis FatHijackIrpAndFlushDevice. Deux corrections. Les retours à la table sont deux ou trois par tranche, pas toujours trois : quand le premier cluster bouge, c'est l'entrée de répertoire qui est écrite. Et la libération de la source n'est pas écrite de façon synchrone. Pertinence : pour un FAT, DefragJob.strategy(for:) choisit Windows95Strategy, mais XP, JkDefrag et UltraDefrag restent proposés sur demande (DefragJob.all). Le modèle leur applique alors des blocs de 64 Kio (XP) ou 4 Mo (JkDefrag), jamais la tranche de 256 Ko de fastfat.


### `fat-21` — confirmé

**Affirmation.** Un sous-répertoire FAT naît avec un cluster, celui qui porte `.` et `..`, pris au curseur comme n'importe quel fichier.

- App : `Sources/DiskCore/Simulator.swift:795-800 ; Sources/DiskCore/FileCatalog.swift:162-167`
- XP : `base/fs/fastfat/dirsup.c:596-620 ; base/fs/fastfat/allocsup.c:1250-1256 (FatAllocateDiskSpace avec indice 0) ; 2059-2072 (indice pris dans Vcb->ClusterHint)`
- Extrait : « note that we prepare write 2 entries: one for "." and one for "..". »

**Constat.** FatInitializeDirectoryDirent prépare en écriture les deux premières entrées d'un répertoire neuf (allocation nulle au départ). L'allocation d'un cluster qui en résulte part du curseur du volume, faute d'indice : c'est la première allocation du fichier. C'est ce que fait XP ; pour 9x, le format impose le même cluster, et seul l'emplacement n'est qu'un indice.

**Contre-vérification.** Vérifié : première allocation sans indice, donc Vcb->ClusterHint, et un cluster (FatPrepareWriteDirectoryFile sur 64 octets, arrondis au cluster et mis à zéro). Pour 9x, le fait vient du format ; l'emplacement reste un indice.


### `fat-22` — nuancé

**Affirmation.** Un répertoire FAT grandit d'un cluster quand ses entrées débordent, au curseur, donc loin de ses premiers clusters. La place d'une entrée effacée resservira, et le répertoire ne raccourcit jamais.

- App : `README.md:654-658 ; Sources/DiskCore/Simulator.swift:786-793, 821-845`
- XP : `base/fs/fastfat/dirsup.c:290-322 ; 360-420 ; base/fs/fastfat/cachesup.c:499-514 ; allocsup.c:1283-1312`
- Extrait : « march from the DeletedDirentHint looking for a deleted dirent.  If we get to EOF without finding one, we will have to allocate a new cluster. »

**Constat.** Trois points sont confirmés. FatLocateFreeDirent prend d'abord les entrées jamais utilisées de l'allocation, puis cherche des entrées effacées à partir de DeletedDirentHint, et n'alloue qu'en dernier recours. La croissance se fait d'un cluster (FatPrepareWriteDirectoryFile → FatAddFileAllocation sur un octet de plus). Aucun code ne raccourcit un répertoire. En revanche, « au curseur » est faux sous XP : FatAddFileAllocation prolonge le répertoire juste derrière son dernier cluster si c'est libre (voir fat-13). Deux autres limites valent sous XP : les entrées d'un nom long doivent être contiguës (RtlFindClearBits sur DirentsNeeded), ce que le compteur d'octets de l'app ignore ; et un répertoire est plafonné à 65 536 entrées. Pour 9x, l'emplacement de la croissance n'est pas vérifiable.

**Effet.** Sous XP, les répertoires seraient bien moins fragmentés, et lire un chemin coûterait moins de sauts.

**Contre-vérification.** Confirmé. La place d'une entrée effacée est réutilisée par RtlFindClearBits sur DirentsNeeded contigus, à partir de DeletedHint. La croissance se fait par FatPrepareWriteDirectoryFile(UnusedVbo, 1), puis FatAddFileAllocation, qui passe le cluster suivant comme indice. La limite de 64·1024 entrées est bien là. L'app raisonne par pic d'octets (peakEntryBytes) et ignore que les entrées d'un nom long doivent être contiguës.


### `fat-23` — nuancé

**Affirmation.** Sous VFAT, un nom coûte une entrée de nom court, plus une entrée par tranche de treize caractères du nom long, dès que le nom n'est pas un 8.3 valide en majuscules (un nom en minuscules a besoin d'un nom long pour garder sa casse).

- App : `Sources/DiskCore/FileCatalog.swift:176-192`
- XP : `base/fs/fastfat/lfn.h:62 ; base/fs/fastfat/namesup.c:~905-945`
- Extrait : « #define FAT_LFN_DIRENTS_NEEDED(NAME) (((NAME)->Length/sizeof(WCHAR) + 12)/13) ... *CreateLfn = (Lowers != 0) && (Uppers != 0); »

**Constat.** Le compte de treize caractères par entrée est confirmé (FAT_LFN_DIRENTS_NEEDED). La règle de déclenchement diffère sous XP : un nom 8.3 dont la base et l'extension sont chacune d'une seule casse (tout en minuscules, ou minuscules d'un côté et majuscules de l'autre) n'a pas besoin de nom long. XP pose alors des drapeaux de casse dans le NtByte de l'entrée courte. Seul un mélange de casses à l'intérieur d'un même composant force un nom long. La règle de l'app est celle de Windows 95/98 : XP n'en est qu'un indice, et il diffère.

**Effet.** Aucun sur la galerie (9x). Sur un FAT écrit par XP, les noms tout en minuscules coûteraient une seule entrée.

**Contre-vérification.** FAT_LFN_DIRENTS_NEEDED = (longueur + 12)/13 est confirmé, et CreateLfn = (Lowers != 0) && (Uppers != 0) par composant. L'app (FileCatalog.swift:185-188) appelle isShortName(caseSensitive: true), soit la règle de 9x. XP diffère sur les noms d'une seule casse.


### `fat-24` — non vérifiable

**Affirmation.** MS-DOS alloue par un scan complet depuis le premier cluster de données à chaque écriture (et, entre deux démarrages, par un pointeur « dernier alloué » volatil dans le DPB).

- App : `Sources/DiskCore/Allocators/FATAllocator.swift:26-38 ; README.md:466-468`
- XP : `base/fs/fastfat/allocsup.c:2296-2303`
- Extrait : « FAT 12/16 - we've run up against the end of the volume.  Clear the hint, since we now have no idea where to look. »

**Constat.** Ce comportement relève de MS-DOS (IO.SYS/MSDOS.SYS), pas de NT : le code XP n'en dit rien. Seule parenté dans fastfat : pour FAT12/16, quand une allocation contiguë atteint la fin du volume, le pilote efface son indice et repart en « pot luck », c'est-à-dire en first-fit depuis le début de la bitmap.

**Contre-vérification.** C'est un comportement de MS-DOS, absent du code NT. La parenté citée (l'indice effacé en FAT12/16 en fin de volume, puis le « pot luck ») est exacte, mais ne prouve rien pour DOS. Les références de l'app (FATAllocator.swift:26-38 et README.md:466-467) sont exactes.


### Lacunes — FAT : format et allocation

- **Sous XP, FSCTL_MOVE_FILE sur FAT déplace par tranches de 256 Ko. Chaque tranche écrit les entrées FAT de la cible avant la copie, puis les deux soudures ou l'entrée de répertoire après, puis vide le cache du disque. Toutes ces écritures sont synchrones et vont aux deux copies de la table.** — `base/fs/fastfat/fsctrl.c:5424-5430, 5570-5645, 5960-5966`. Son : la signature d'une passe XP, JkDefrag ou UltraDefrag sur les FAT de la galerie devient un aller-retour table↔données toutes les 256 Ko, au lieu d'une validation par fichier. *Contre-vérification :* Confirmé par fsctrl.c:5384-5620 et 5960-5966. L'app l'ignore : aucune trace de 0x40000, de FatMoveFile côté copie ni de FlushFatEntries dans Sources/ ou le README. commitAccesses se fait une fois par déplacement. Précision : deux ou trois retours à la table par tranche, et la libération de la source n'est pas écrite tout de suite.
- **Le curseur d'allocation (ClusterHint) recule au cluster libéré le plus bas à chaque libération (FatUnreserveClusters). Au montage, il repart du premier cluster libre, sans jamais lire FSINFO.** — `base/fs/fastfat/allocsup.c:243-249, 597-603 ; base/fs/fastfat/verfysup.c:856-857`. Disposition : sur un FAT monté sous XP, les trous se rebouchent au fil des suppressions. Il n'y a pas de fragmentation par vagues. *Contre-vérification :* Confirmé (allocsup.c:243-249, 2841, 597-603 ; verfysup.c:856-863). À préciser : sur un FAT32 à plusieurs fenêtres, l'indice est relatif à la fenêtre courante et le montage repart du premier libre de la fenêtre choisie, pas du volume. L'app garde un curseur qui ne recule pas (FATAllocator.free ne touche pas nextFreeHint).
- **Toute allocation cherche d'abord une plage contiguë de la taille entière (RtlFindClearBits), puis la plus longue plage libre. Un fichier existant est prolongé derrière son dernier cluster.** — `base/fs/fastfat/allocsup.c:2093-2115, 2327-2362, 1300-1318`. Disposition : sous XP, les fichiers FAT de taille connue et les répertoires qui grandissent restent contigus, bien plus que dans le modèle. *Contre-vérification :* Confirmé (allocsup.c:2086-2115, 2270-2345, 1283-1312). L'app ne cherche une plage d'un seul tenant que pour .reservedContiguous. Sans objet pour la galerie, qui n'a aucun FAT sous NT.
- **Sur une écriture qui étend un fichier, l'allocation anticipée va jusqu'à 32 fois l'extension, et le surplus est rendu à la fermeture (FCB_STATE_TRUNCATE_ON_CLOSE).** — `base/fs/fastfat/write.c:1676-1800`. Disposition : les fichiers écrits en flux sous XP se posent en grands morceaux ; les écritures de table sont aussi moins fréquentes. *Contre-vérification :* Confirmé (write.c:1664-1760), seulement à partir de la deuxième allocation d'un fichier. L'app garde writePacketBytes = 1 cluster sur FAT et ne mentionne pas ce mécanisme.
- **En FAT32 sous XP, l'allocation se fait par fenêtres de 65 536 clusters, choisies par FatSelectBestWindow : la première fenêtre libre à plus de 50 %, sinon la première vide, sinon la plus libre.** — `base/fs/fastfat/allocsup.c:305-420, 2405-2450`. Disposition et son : l'écriture se concentre dans une tranche de 256 Mo, et le curseur ne parcourt pas tout le volume. *Contre-vérification :* Confirmé (allocsup.c:305-420, 553-572, 2350-2420). Règle exacte : première fenêtre non vide libre à au moins 50 %, les fenêtres vides étant écartées à cette étape ; sinon la première vide ; sinon la plus libre. L'app n'a aucune notion de fenêtre : le retour au début porte sur tout le volume (ClusterBitmap.swift:366-367).
- **Une allocation par FSCTL_MOVE_FILE, faite avec ExactMatchRequired, passe elle aussi par FatReserveClusters, qui recale le curseur global juste derrière la cible du déplacement.** — `base/fs/fastfat/allocsup.c:264-282 ; base/fs/fastfat/fsctrl.c:5390-5397`. Disposition : après une défragmentation par l'API, les fichiers écrits ensuite se posent derrière la zone tassée. *Contre-vérification :* Confirmé : FatAllocateDiskSpace avec ExactMatchRequired passe par FatReserveClusters (allocsup.c:2115), qui fixe ClusterHint à _AfterRun ; si la cible sort de la fenêtre courante, le pilote change de fenêtre (l.~1960). Côté app, FATAllocator.claim ne touche pas nextFreeHint.
- **Au montage sous XP, toute la FAT est lue (FatExamineFatEntries de 2 à N) pour bâtir la bitmap et compter les clusters libres.** — `base/fs/fastfat/allocsup.c:553-571`. Son d'un montage : une lecture de plusieurs Mo en tête du volume sur un FAT32 monté sous XP. Aucun scénario ne le fait aujourd'hui. *Contre-vérification :* Confirmé, et plus largement que dit : même avec une seule fenêtre, FatExamineFatEntries sur la fenêtre lit toute la table (allocsup.c:587-594). L'app lit la FAT entière au montage pour FAT16 (VolumeLayout.swift:410-412), mais pas pour FAT32 (un secteur). Cela convient à Win98, et aucun scénario FAT n'est monté sous XP.

## Le défragmenteur de XP (dfrgntfs, dfrgfat), contre-vérification


### `xp-defrag-lignes` — confirmé

**Affirmation.** Les numéros de ligne cités par le chantier 45 : DefragNtfs 4189-4299, FreeSpaceErrorLevel à fssubs.cpp:1239, LARGE_BUFFER_SIZE à ntfsdata.h:345, « Sigh. No free space chunk » à 3334, tri « in REVERSE order » à 478, PartialDefragNtfs à 4371 sans appelant, 25 / (uMoveFilesCount * 2) à 4287.

- App : `LEDGER.md:7512-7517`
- XP : `base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:4201-4310 (DefragNtfs) ; fssubs.cpp:1239 ; base/fs/ntfs/ntfsdata.h:345 ; dfrgntfs.cpp:3334, 478, 4287, 4371 ; inc/dfrgntfs.h:126`
- Extrait : « #define LARGE_BUFFER_SIZE (0x10000) ; DWORD dwFreeSpaceErrorLevel = 15; »

**Constat.** Tous les numéros tombent juste. Seul détail : la plage 4189-4299 part du commentaire d'en-tête (4186-4189). La fonction commence à 4201 et finit vers 4309 ; 4299 est le dernier ConsolidateFreeSpace(0, 100, TRUE, 1). PartialDefragNtfs (4371) n'a aucun appelant dans dfrgntfs. La ligne 4287 est exactement `MoveFilesForward(25 / (uMoveFilesCount * 2))`, et ce paramètre ne règle que la barre de progression.

**Effet.** Aucun.

**Contre-vérification.** J'ai relu chaque ligne citée. fssubs.cpp:1239 donne `DWORD dwFreeSpaceErrorLevel = 15;`, ntfsdata.h:345 `#define LARGE_BUFFER_SIZE (0x10000)`, dfrgntfs.cpp:3334 « Sigh. No free space chunk », 478 « in REVERSE order », 4287 `MoveFilesForward(25 / (uMoveFilesCount * 2))`, 4371 `PartialDefragNtfs(`. Un grep sur tout dfrg ne trouve PartialDefragNtfs que dans sa définition et dans la déclaration de inc/dfrgntfs.h:126 : aucun appelant. DefragNtfs commence à 4201 ; la plage 4189-4299 part de l'en-tête de commentaire et s'arrête au dernier ConsolidateFreeSpace(0,100,TRUE,1), alors que la fonction va jusqu'au `return TRUE` (~4310).


### `xp-defrag-boucles` — confirmé

**Affirmation.** L'enchaînement des phases suit DefragNtfs : boucle intérieure défragmenter/consolider tant que le nombre de fragmentés baisse, avec vidage de la zone MFT après une consolidation réussie ; boucle extérieure tasser puis consolider ; si tout est réparé, zone MFT puis tassement final. Pas de plafond de passes dans la source.

- App : `Sources/Model/WindowsXPStrategy.swift:42-47, 183-215`
- XP : `base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:4215-4303`
- Extrait : « bDone = DefragmentFiles(45, &MinimumLength); … bConsolidate = ConsolidateFreeSpace(MinimumLength, 75, FALSE, consolidateProgress); »

**Constat.** C'est la structure de DefragNtfs : do/while imbriqués sans compteur limite, arrêt sur bDone ou sur un NumFragmentedFiles égal à PreviousFragmented (intérieure) ou à PreviousFragmented2 (extérieure). Écart négligeable : les compteurs précédents valent 0 au départ dans XP et -1 dans l'app. Le plafond de 32 tours est propre au modèle, et il le dit.

**Effet.** Aucun.

**Contre-vérification.** Les deux boucles de 4215-4290 correspondent à la lettre à WindowsXPStrategy.swift:183-215. Boucle intérieure : DefragmentFiles, sortie sur bDone ou quand le compte égale PreviousFragmented, ConsolidateFreeSpace(MinimumLength,75), sortie si FALSE, puis la zone MFT si elle n'est pas encore faite. Boucle extérieure : sortie sur bDone ou quand le compte égale PreviousFragmented2, puis MoveFilesForward et ConsolidateFreeSpace. Après la boucle, si bDone : zone MFT puis MoveFilesForward. La source n'a aucun plafond. Les compteurs partent de 0 dans XP et de -1 dans l'app, sans effet réel : un compte nul veut déjà dire bDone.


### `xp-defrag-mft-avant-apres` — nuancé

**Affirmation.** La MFT est recollée d'abord, puis à nouveau à la fin (MFTDefrag avant et après).

- App : `Sources/Model/WindowsXPStrategy.swift:19-21, 181, 215`
- XP : `base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:2852-2861, 2906, 3048`
- Extrait : « dwLayoutErrorCode = ProcessBootOptimise(); … MFTDefrag(VolData.hVolume, …) »

**Constat.** MFTDefrag est bien appelé avant DefragNtfs (2906) et après (3048). Mais sur le volume de démarrage, DefragThread lance ProcessBootOptimise avant MFTDefrag (2861). Il déplace les fichiers de layout.ini dans une zone de démarrage et en expulse les autres fichiers. La première phase qui déplace des données n'est donc pas la MFT.

**Effet.** Sur un volume système, il manque au début de la passe une salve de déplacements vers la zone de démarrage, avec évictions.

**Contre-vérification.** Confirmé : ProcessBootOptimise() à 2861, avant MFTDefrag (2906), et MFTDefrag de nouveau à 3048, « since all our file-moves above could have potentially fragmented it again ». Le commentaire de 2852-2853 limite l'optimisation au volume de démarrage (« we currently only do this for the boot volume »). La nuance ne vaut donc que pour un volume système.


### `xp-defrag-mft-condition` — contredit

**Affirmation.** MFTDefrag : si la queue de la MFT (tout sauf le premier extent) est en plus d'un morceau, elle part d'un bloc vers le premier trou qui tient la queue (condition `extents.count > 2`, besoin = taille de la queue).

- App : `Sources/Model/WindowsXPStrategy.swift:384-404`
- XP : `base/fs/utils/dfrg/dfrgntfs/mftdefrag.cpp:119-133 (GetMFTSize : 277-288) ; defragcommon.cpp:150-167`
- Extrait : « if(lMFTFragments > 1) //mft fragmented go ahead and try and move »

**Constat.** Le code teste `lMFTFragments > 1`, où lMFTFragments est l'ExtentCount de toute la MFT, premier extent compris. XP déplace donc la queue dès que la MFT compte deux extents, même si la queue est d'un seul tenant. Il cherche un trou d'au moins la taille de la MFT entière : FindFreeSpaceChunk reçoit ulMFTsize avant qu'on en retire le premier extent (mftdefrag.cpp:131). Il faut aussi que le premier extent dépasse 16 enregistrements. Le commentaire du fichier (« in two fragments ») ne dit pas la même chose que le code. Détail : si aucun trou ne convient, FindFreeSpaceChunk rend le début du dernier trou examiné au lieu de 0.

**Effet.** Une MFT en deux extents (cas courant) voit sa queue déplacée à chaque passe, deux fois, vers le premier trou assez grand pour toute la MFT, qui peut se trouver derrière elle. Le modèle ne joue pas ces copies. Sur une MFT très fragmentée et un volume plein, un trou de la taille de la queue ne suffit pas à XP.

**Contre-vérification.** Vérifié dans les deux sources. Dans GetMFTSize, lMFTFragments = ExtentCount de toute la MFT. La boucle i=1… part de StartingVcn=0 : la somme vaut donc la taille de la MFT entière, premier extent compris, dès qu'il y a deux extents. Le test est `lMFTFragments > 1` (mftdefrag.cpp:122). FindFreeSpaceChunk reçoit ulMFTsize entier (126) ; le premier extent n'est retiré qu'après (131). Il faut aussi `lMFTStartingVcn > ClustersPerFRS*16` (120). Côté app, `volume.mftExtents` contient le premier extent (DefragVolume.swift:245, et relocateMFTTail qui fait `[mftExtents[0], extent]` à 412), et le test `extents.count > 2` (WindowsXPStrategy.swift:386) exige donc trois extents. Conséquence aggravante : après un déplacement, la MFT de l'app compte deux extents et n'est plus jamais redéplacée, alors que XP la redéplacerait à chaque appel.


### `xp-defrag-mft-zone-cible` — contredit

**Affirmation.** La queue de la MFT va vers le premier trou qui la tient, « la zone MFT comprise, c'est sa réserve » (firstGap avec avoidingMFTZone: false).

- App : `Sources/Model/WindowsXPStrategy.swift:384-393`
- XP : `base/fs/utils/dfrg/defragcommon.cpp:147-168, 193-219 ; dfrgntfs/mftdefrag.cpp:125-126`
- Extrait : « //mark the bit map used for the mft in NTFS  MarkBitMapforNTFS(pBitmap, MftZoneStart, MftZoneEnd); »

**Constat.** FindFreeSpaceChunk appelle MarkBitMapforNTFS, qui marque toute la zone MFT comme occupée dans sa copie de la bitmap avant de chercher. La queue de la MFT ne va donc jamais dans la zone MFT : XP prend le premier trou hors zone, dans l'ordre des LCN, d'au moins la taille de la MFT.

**Effet.** Dans le modèle, la MFT peut atterrir au début de la zone MFT, souvent contre le premier extent, donc près de la bonne place. Dans XP elle part hors de la zone, souvent loin. La disposition finale diffère, ainsi que la longueur du seek de cette copie et des lectures de MFT qui suivent.

**Contre-vérification.** FindFreeSpaceChunk est appelé avec IsNtfs=TRUE (mftdefrag.cpp:126). À defragcommon.cpp:150-153, MarkBitMapforNTFS marque toute la zone MFT comme occupée dans la copie de la bitmap avant de chercher. L'app appelle firstGap(avoidingMFTZone: false) (WindowsXPStrategy.swift:391) et affirme le contraire dans son commentaire (« la zone MFT comprise, c'est sa réserve »). Précision : la recherche va dans l'ordre des LCN depuis 0 et prend le premier trou d'au moins la taille de toute la MFT, zone de démarrage non exclue ; s'il n'en trouve pas, elle rend le début du dernier trou examiné, et MoveFileLocation est tout de même tenté.


### `xp-defrag-tri` — nuancé (vérificateur : confirmé)

**Affirmation.** Les fichiers et répertoires fragmentés sont visités par taille croissante, puis par numéro d'enregistrement (FileEntrySizeCompareRoutine).

- App : `Sources/Model/WindowsXPStrategy.swift:22-23, 134-143, 617-619`
- XP : `base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:395-432, 627-631 ; app : WindowsXPStrategy.swift:617-619, GeneratedVolume.swift:64-83, FileCatalog.swift:279`
- Extrait : « // Sort by ClusterCount … use the FileRecordNumber as the secondary key. »

**Constat.** En mode défragmentation, FragmentedFileTable est un arbre AVL trié par FileEntrySizeCompareRoutine : ClusterCount, puis FileRecordNumber. En analyse seule, la table est triée par nombre de fragments, ce qui ne touche pas la passe. Les répertoires entrent dans ces tables (ScanNtfs, « also includes moveable directories »).

**Effet.** Aucun.

**Contre-vérification.** La règle de XP est bien ClusterCount, puis FileRecordNumber (dfrgntfs.cpp:395-432, FragmentedFileTable à 627-631). Mais l'app départage sur `a.id` (WindowsXPStrategy.swift:617-619) et non sur `mftRecord`, que le modèle possède pourtant (DefragVolume.swift:33). Les deux ne suivent pas le même ordre. Un répertoire a pour id `0x8000_0000 | id` (FileCatalog.swift:279) et passe après tous les fichiers de même taille, alors que MFTNumbering (GeneratedVolume.swift:64-83) numérote tous les répertoires avant les fichiers ; les fichiers eux-mêmes y sont numérotés dans l'ordre des emplacements (liveIDs), pas des id. À taille égale, l'ordre de visite diffère donc de celui de XP. L'effet est faible.


### `xp-defrag-bestfit` — confirmé

**Affirmation.** Chaque fichier cassé va entier dans le plus petit trou qui le tient, pris dans une liste triée par taille ; le reste du trou y revient.

- App : `Sources/Model/WindowsXPStrategy.swift:24-25, 336-356, 417-432`
- XP : `base/fs/utils/dfrg/freespace.cpp:949-1003 ; dfrgntfs/dfrgntfs.cpp:3180, 3288-3312`
- Extrait : « pFreeSpaceEntry->StartingLcn += VolData.NumberOfClusters; pFreeSpaceEntry->ClusterCount -= VolData.NumberOfClusters; »

**Constat.** FindFreeSpace(table, TRUE, …) parcourt l'arbre trié par taille (départage par LCN) et prend la première entrée assez grande : c'est bien un best fit. Le fichier est posé au début du trou. UpdateFileTables raccourcit l'entrée sur place sans la retrier dans l'arbre, et DeleteUnusedEntries supprime les entrées devenues trop petites. Comme les fichiers passent par taille croissante, le résultat est le même que la réinsertion faite par l'app. MoveFile déplace chaque flux d'un seul FSCTL_MOVE_FILE, donc le fichier est bien copié entier.

**Effet.** Aucun.

**Contre-vérification.** FindFreeSpace(&FreeSpaceTable, TRUE, TotalClusters) (dfrgntfs.cpp:3290) parcourt la table triée par taille (BuildFreeSpaceList(…, NumberOfClusters, TRUE) à 3180, bSortBySize), supprime les entrées trop petites et prend la première assez grande. MaxStartingLcn = TotalClusters ne coupe jamais. J'ai vérifié qu'un reste rogné sur place sans retri donne le même choix que la réinsertion de l'app : le reste est en tête de l'arbre, et aucune entrée de longueur comprise entre s1 et L ne peut exister.


### `xp-defrag-arret-minimum` — confirmé

**Affirmation.** Au premier fichier sans trou, la phase de défragmentation s'arrête (les suivants sont plus gros) et retient sa taille dans MinimumLength.

- App : `Sources/Model/WindowsXPStrategy.swift:25-27, 425-431`
- XP : `base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:3176-3180, 3330-3343`
- Extrait : « Sigh.  No free space chunk that's big enough to hold all the extents of this file. »

**Constat.** Branche « Sigh. No free space chunk… It's no point enumerating more files » : *pSmallestFragmentedFileSize = NumberOfClusters, puis break. Autre point : la liste des trous ignore d'emblée ceux qui sont plus petits que le plus petit fichier fragmenté (BuildFreeSpaceList avec MinClusterCount), sans effet sur le résultat.

**Effet.** Aucun.

**Contre-vérification.** À dfrgntfs.cpp:3330-3343 : `*pSmallestFragmentedFileSize = VolData.NumberOfClusters; … break;`. C'est bien ce que fait l'app (WindowsXPStrategy.swift:425-431). BuildFreeSpaceList ignore les trous plus petits que le plus petit fichier fragmenté (3176-3180), sans effet sur le choix.


### `xp-defrag-zone-mft-rognee` — nuancé

**Affirmation.** Les trous de la zone MFT sont rognés de toutes les listes (BuildFreeSpaceList) : l'outil n'y range rien.

- App : `Sources/Model/WindowsXPStrategy.swift:95-98, 305-332`
- XP : `base/fs/utils/dfrg/freespace.cpp:296-333 ; inc/freespace.h:29-45`
- Extrait : « //0.0E00 If NTFS clip the free space extent to exclude the MFT zone »

**Constat.** C'est vrai pour BuildFreeSpaceList (bIgnoreMftZone = FALSE par défaut), BuildFreeSpaceListWithExclude (bExcludeMftZone = TRUE par défaut) et BuildFreeSpaceListWithMultipleTrees : les trois rognent la zone MFT. Mais sur NTFS, les trois rognent aussi la zone d'optimisation du démarrage (BootOptimizeBegin/EndClusterExclude), et le modèle ne le fait pas.

**Effet.** Sur un volume système, XP ne range ni ne tasse rien dans la zone de démarrage : aucun fichier n'y entre, même pour la consolidation ou le tassement. Le modèle y voit des trous utilisables.

**Contre-vérification.** La nuance du vérificateur est confirmée : freespace.cpp:320-333 rogne aussi la zone de démarrage. J'ajoute une particularité du code que ni l'app ni le vérificateur ne mentionnent. Un trou qui chevauche toute la zone MFT (début avant, fin après) n'en garde que la partie d'avant : la branche `StartingLcn < MftZoneStart` fait `EndingLcn = MftZoneStart` et perd la partie d'après (freespace.cpp:305-318). La même règle vaut pour la zone de démarrage. L'app, elle, garde les deux morceaux (WindowsXPStrategy.swift:309-322). Le seuil MinClusterCount est aussi testé avant le rognage (298-300), si bien qu'un trou rogné peut devenir plus petit que ce minimum.


### `xp-defrag-region` — nuancé

**Affirmation.** FindRegionToConsolidate : la plus longue suite ininterrompue de trous et de fichiers contigus exactement adjacents, d'au moins MinimumLength, plus longue que le plus grand trou, occupée à moins de 75 %, avec au moins un fichier.

- App : `Sources/Model/WindowsXPStrategy.swift:28-31, 449-513`
- XP : `base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:3451, 3478-3530`
- Extrait : « if ((regionLength > biggestFree) && (regionLength > bestRegionLength) && (dwBytesInUsePercent < dwDesparationFactor)) »

**Constat.** Les critères sont exacts : bytesInUse > 0, regionLength >= MinimumLength, > biggestFree, > best, pourcentage < dwDesparationFactor (75), et la coupure sur un fichier plus gros que le plus grand trou. En revanche, chez XP une région commence toujours par un trou (regionStart = pFree->StartingLcn), et les fichiers placés avant le premier trou sont sautés. L'app ouvre aussi une région sur un fichier contigu. Détail : une coupure sur un fichier trop gros fait reculer currentLcn d'un cluster.

**Effet.** Faible. L'app peut choisir une région un peu plus longue, qui commence par des fichiers, et donc évacuer quelques fichiers de plus que XP.

**Contre-vérification.** Vérifié à dfrgntfs.cpp:3478-3530. Les critères sont `bytesInUse > 0`, `regionLength >= MinimumLength`, `> biggestFree`, `> bestRegionLength` et `< dwDesparationFactor`. regionStart = pFree->StartingLcn : une région commence toujours par un trou. Coupure `pFile->ClusterCount > biggestFree` avec `--currentLcn`. Autre particularité : si les fichiers et les trous sont épuisés en même temps, currentLcn passe à TotalClusters (3505-3509). biggestFree vient d'une liste où la zone MFT est rognée. L'app ouvre une région sur un fichier contigu (extend avec current == nil à la rencontre d'un fichier, WindowsXPStrategy.swift:478-483, 500-501), ce qui confirme l'écart.


### `xp-defrag-consolidation-ordre` — confirmé

**Affirmation.** Les fichiers d'une région en partent de la fin vers le début (LCN décroissant), chacun vers le plus petit trou qui le tient hors de la région, n'importe où, y compris après elle.

- App : `Sources/Model/WindowsXPStrategy.swift:31-34, 539-552`
- XP : `base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:3657-3668, 3744-3830 ; freespace.cpp:1012-1050`
- Extrait : « compare based on starting LCN in REVERSE order »

**Constat.** ContiguousFileTable est triée par LCN décroissant (« in REVERSE order »). L'énumération repart d'une entrée factice placée à RegionEndLcn et s'arrête sous RegionStartLcn. FindSortedFreeSpace prend la plus petite entrée assez grande d'une liste triée par taille, qui exclut la région et la zone MFT. Le reste du trou y est supprimé puis réinséré correctement. Le commentaire « If it's before the file » n'est pas appliqué : le trou peut être après.

**Effet.** Aucun.

**Contre-vérification.** ConsolidateFreeSpace (3570-3897) : BuildFreeSpaceListWithExclude(…, RegionStartLcn, RegionEndLcn, TRUE) exclut la région et la zone MFT. L'énumération de ContiguousFileTable (LCN décroissant) repart de RegionEndLcn et s'arrête sur `StartingLcn < RegionStartLcn`. FindSortedFreeSpace (freespace.cpp:1012-1050) prend la première entrée de taille au moins égale au besoin. Le reste du trou est supprimé puis réinséré (3761-3830). Rien n'exige que le trou soit placé avant le fichier.


### `xp-defrag-abandon-dix` — nuancé

**Affirmation.** Plus de dix fichiers sans destination, et la région est abandonnée ; consolider « rend true si au moins un fichier est parti ».

- App : `Sources/Model/WindowsXPStrategy.swift:34, 127, 539-558`
- XP : `base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:3858-3866, 3895-3897 ; 4261-4266`
- Extrait : « if ((bDefragMftZone) || (++iCount > 10)) { bSuccess = FALSE; … »

**Constat.** Le seuil est exact : `++iCount > 10` abandonne au onzième échec, comme `failures > 10` dans l'app. La valeur rendue diffère. ConsolidateFreeSpace rend bSuccess, qui vaut TRUE si la région a été parcourue sans abandon, même sans aucun déplacement, et FALSE après un abandon, même si des fichiers sont déjà partis. L'app rend `moved > 0`.

**Effet.** Après une région abandonnée qui a quand même évacué des fichiers, XP sort de la boucle intérieure et passe au tassement. L'app, elle, redéfragmente, reconsolide et tente la zone MFT. L'ordre des phases, donc des salves sonores, peut diverger sur les volumes pleins.

**Contre-vérification.** Confirmé : `if ((bDefragMftZone) || (++iCount > 10)) { bSuccess = FALSE; bResult = FALSE; break; }`, puis `return bSuccess` (3897). bSuccess reste TRUE quand la boucle se termine normalement (plus de fichier, ou fichier sous RegionStartLcn), même sans aucun déplacement. L'app rend `moved > 0` (WindowsXPStrategy.swift:558). Les deux valeurs divergent dans les deux sens : région parcourue sans rien déplacer (XP rend TRUE, l'app false) et région abandonnée après des déplacements (XP rend FALSE, l'app true).


### `xp-defrag-zone-mft-une-fois` — nuancé

**Affirmation.** La zone MFT est vidée de la même façon, une fois par passe (tolérance de dix échecs, faite dès qu'un fichier est parti).

- App : `Sources/Model/WindowsXPStrategy.swift:35, 203, 212, 527-537`
- XP : `base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:3625-3643, 3816-3820, 3858-3866, 4268-4272, 4297-4300 ; app : WindowsXPStrategy.swift:203, 212, 527-558`
- Extrait : « else if (bDefragMftZone) { bResult = FALSE; bSuccess = FALSE; break; } »

**Constat.** XP appelle ConsolidateFreeSpace(0, 100, TRUE, 1) : la région est la zone MFT, rognée de la zone de démarrage. Avec bDefragMftZone, le premier échec (aucun trou, ou FSCTL refusé hors ERROR_RETRY) arrête tout et rend FALSE. bMftZoneDefragmented reste alors faux, et la tentative est refaite à chaque tour de la boucle intérieure où une consolidation a réussi, puis une fois de plus à la fin si bDone. Il n'y a pas de tolérance de dix échecs.

**Effet.** Sur un volume plein, XP vide la zone MFT par morceaux, jusqu'au premier fichier sans place, et recommence à chaque tour. L'app fait un seul essai qui continue malgré les échecs. Le nombre et le moment des évacuations de la zone diffèrent.

**Contre-vérification.** Confirmé côté XP : bDefragMftZone arrête tout au premier échec, faute de trou (3862) comme en cas de MoveNtfsFile refusé hors ERROR_RETRY (3816-3820). La tentative est refaite à chaque tour intérieur tant que bMftZoneDefragmented reste FALSE (4268-4272), puis une fois de plus à la fin si bDone (4297-4300). Une correction sur l'app : elle ne fait pas « un seul essai ». `mftZoneDone = pass.consolidateMFTZone()` se refait tant que l'appel rend false, c'est-à-dire tant que rien n'est parti (moved == 0). Mais un seul fichier déplacé suffit à clore la zone, alors que chez XP un seul échec la laisse ouverte. Et l'app tolère dix échecs dans la zone, là où XP n'en tolère aucun.


### `xp-defrag-tassement` — confirmé

**Affirmation.** MoveFilesForward : les fichiers contigus du dernier cluster au premier, chacun vers le trou de plus petit numéro qui le tient et commence avant lui ; après un échec, les fichiers au moins aussi gros sont sautés ; arrêt quand un fichier d'un cluster ne trouve rien.

- App : `Sources/Model/WindowsXPStrategy.swift:36-40, 562-606`
- XP : `base/fs/utils/dfrg/freespace.cpp:698-816 ; dfrgntfs/dfrgntfs.cpp:3911-3925, 3969, 4057-4068, 4130-4150 ; ntfssubs.cpp:2972-2983`
- Extrait : « No free space before this file that's big enough … skip trying to find a free space chunk for any file that's bigger »

**Constat.** Dix arbres de trous par classe de taille, chacun trié par LCN. FindFreeSpaceWithMultipleTrees prend le premier trou assez grand de la classe du fichier et le premier trou de chaque classe supérieure, et garde le plus bas en LCN sous MaxStartingLcn : au total, c'est le premier trou qui tient avant le fichier. Après un échec, MaxFreeSpaceChunkSize = CurrentFileSize, et GetNextNtfsFile saute les fichiers `ClusterCount >= ClusterCount`. `if (1 >= CurrentFileSize)` arrête la phase. La liste exclut la zone MFT et la zone de démarrage, et les fichiers FLE_BOOTOPTIMISE de la zone de démarrage sont sautés.

**Effet.** Aucun, sauf l'exclusion de la zone de démarrage (voir les lacunes).

**Contre-vérification.** Vérifié. FindFreeSpaceWithMultipleTrees (freespace.cpp:698-816) : dix classes triées par LCN. Dans la classe du fichier, on prend le premier trou assez grand avant MaxStartingLcn ; dans chaque classe supérieure, le premier trou, où toute entrée tient forcément. Le résultat est le premier trou avant le fichier qui le contient. GetNextNtfsFile saute les fichiers `ClusterCount >= MaxFreeSpaceChunkSize` (ntfssubs.cpp:2983). MaxFreeSpaceChunkSize vaut d'abord TotalClusters (dfrgntfs.cpp, déclaration de MoveFilesForward), et BuildFreeSpaceListWithMultipleTrees ne le relève que s'il y a plus grand : il n'y a donc pas de coupure initiale, comme le UInt32.max de l'app. `if (1 >= CurrentFileSize)` arrête la phase (4135-4145), sinon MaxFreeSpaceChunkSize = CurrentFileSize (4148).


### `xp-defrag-liste-par-phase` — confirmé

**Affirmation.** La liste des trous d'une phase est bâtie une fois, à son début, et consommée ; ce qu'une phase libère ne sert qu'à la suivante.

- App : `Sources/Model/WindowsXPStrategy.swift:55-57, 305-306`
- XP : `base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:3180, 3451, 3657, 3969 ; freespace.cpp:278`
- Extrait : « bResult = BuildFreeSpaceListWithExclude(&VolData.FreeSpaceTable, 0, RegionStartLcn, RegionEndLcn, TRUE); »

**Constat.** DefragmentFiles, ConsolidateFreeSpace et MoveFilesForward bâtissent chacune une liste une fois, depuis la bitmap relue par GetVolumeBitmap, puis la mettent à jour en mémoire au fil des déplacements. FindRegionToConsolidate bâtit sa propre liste juste avant. Les clusters libérés pendant la phase n'y entrent pas.

**Effet.** Aucun.

**Contre-vérification.** Chaque phase bâtit sa liste une fois : 3180 (DefragmentFiles), 3657 (ConsolidateFreeSpace), 3969 (MoveFilesForward) ; FindRegionToConsolidate a la sienne à 3451. BuildFreeSpaceList appelle GetVolumeBitmap (freespace.cpp:278) ; la liste est ensuite tenue à jour en mémoire. Reste une nuance, qui renvoie à xp-defrag-point-de-controle : dans XP, la bitmap relue au début d'une phase montre libres les clusters quittés par la phase précédente, alors que l'app en retient une partie jusqu'au point de contrôle suivant.


### `xp-defrag-64k` — confirmé

**Affirmation.** FSCTL_MOVE_FILE copie par blocs de 64 Kio (LARGE_BUFFER_SIZE), bornés à l'extent source, avec une lecture puis une écriture synchrones par bloc, puis un point de contrôle de transaction.

- App : `Sources/Model/WindowsXPStrategy.swift:49-52, 89-93`
- XP : `base/fs/ntfs/deviosup.c:10289-10294, 10500-10510, 10540-10569, 10588-10618`
- Extrait : « if (TransferSize > BufferLength ) { TransferSize = BufferLength; } »

**Constat.** NtfsDefragFile prend BufferLength = LARGE_BUFFER_SIZE (ou un cluster s'il est plus grand) et borne TransferSize à la plage d'allocation courante (ClusterCount de NtfsLookupAllocation) et au tampon. Pour chaque bloc : NtfsSingleAsync IRP_MJ_READ + NtfsWaitSync, puis IRP_MJ_WRITE + NtfsWaitSync, puis NtfsReallocateRange et NtfsCheckpointCurrentTransaction. Nuance : au-delà de la ValidDataLength, les clusters sont réalloués sans aucune lecture ni écriture.

**Effet.** Pour un fichier préalloué au-delà de ses données valides (fichiers d'installation, bases de données), XP copie moins que ce que le modèle joue.

**Contre-vérification.** Vérifié à deviosup.c:10289-10294 : BufferLength = LARGE_BUFFER_SIZE, ou un cluster s'il est plus grand. TransferSize est borné par ClusterCount/MoveData->ClusterCount puis par BufferLength (10500-10510). La lecture ne se fait que si `StartingVcn <= UpperBound` (ValidDataLength, 10540-10549) : NtfsSingleAsync READ + NtfsWaitSync, puis WRITE + NtfsWaitSync (10588-10595). Viennent ensuite NtfsReallocateRange et NtfsCheckpointCurrentTransaction (10617-10618).


### `xp-defrag-validation` — nuancé

**Affirmation.** Valider un déplacement réécrit un enregistrement de MFT et un secteur de $Bitmap, une fois par fichier, jamais le cluster 0.

- App : `Sources/Model/WindowsXPStrategy.swift:52-53, 368-370`
- XP : `base/fs/ntfs/deviosup.c:10617-10618 ; base/fs/ntfs/logsup.c:2979-3014 ; app : Sources/Model/VolumeLayout.swift:313-330`
- Extrait : « This routine checkpoints the current transaction by commiting it to the log »

**Constat.** La validation n'a pas lieu une fois par fichier mais une fois par bloc de 64 Kio. NtfsReallocateRange puis NtfsCheckpointCurrentTransaction font NtfsCommitCurrentTransaction, qui écrit un enregistrement de commit dans $LogFile, et NtfsWriteUsnJournalChanges quand il y a des raisons USN. La mise à jour de l'enregistrement MFT et de la page de $Bitmap salit le cache et part par l'écriture paresseuse. Quels secteurs touchent le disque, et quand, n'est pas lisible dans ce code, puisque cela dépend du gestionnaire de cache et de LFS.

**Effet.** Des écritures dans $LogFile, intercalées entre les blocs d'un gros fichier, et des écritures paresseuses de MFT/$Bitmap décalées dans le temps manquent sans doute. Sur un gros fichier, le son pourrait comporter des allers-retours vers le journal que le modèle n'a pas.

**Contre-vérification.** NtfsCheckpointCurrentTransaction (logsup.c:2979) appelle NtfsWriteUsnJournalChanges s'il y a des raisons USN, puis NtfsCommitCurrentTransaction (logsup.c:3014), une fois par bloc de 64 Kio. Le vérificateur va trop loin sur le son : un commit LFS écrit dans le tampon du journal, pas forcément sur le disque. L'app n'ignore pas non plus le journal : VolumeLayout.commitAccesses (VolumeLayout.swift:313-330) ajoute une page de journal toutes les huit validations. Mais elle compte ces validations par fichier, et non par bloc.


### `xp-defrag-point-de-controle` — contredit

**Affirmation.** Sur NTFS, ce qu'un déplacement quitte n'est libre qu'au point de contrôle suivant (5 s) : un FSCTL_MOVE_FILE vers ces clusters échoue en STATUS_ALREADY_COMMITTED, et la bitmap que relit un défragmenteur les montre occupés.

- App : `Sources/Model/DefragVolume.swift:325-339 ; Sources/Model/DefragStrategy.swift:595-614 ; Sources/Model/WindowsXPStrategy.swift:54-55, 371-376`
- XP : `base/fs/ntfs/bitmpsup.c:1619, 1798, 9045-9067 ; base/fs/ntfs/fsctrl.c:9222-9460 ; base/fs/ntfs/deviosup.c:10380-10388, 10661-10671, 10780-10795`
- Extrait : « If any bit is set now, raise STATUS_DELETE_PENDING to indicate that the space will soon be free (or can be made free). »

**Constat.** C'est la description de Russinovich pour NT4 (1997), pas le comportement de XP SP1. NtfsDeallocateClusters libère aussitôt les bits de la bitmap (NtfsFreeBitmapRun), si bien que FSCTL_GET_VOLUME_BITMAP montre ces clusters libres. Les clusters désalloués récemment sont suivis à part. Un déplacement vers eux lève STATUS_DELETE_PENDING, et non ALREADY_COMMITTED, que NtfsRunIsClear réserve aux bits réellement occupés. NtfsDefragFile l'intercepte (NtfsDefragExceptionFilter), vide le journal (LfsFlushToLsn), libère les clusters désalloués (NtfsFreeRecentlyDeallocated) et réessaie, jusqu'à 10 fois.

**Effet.** Dans XP, une phase voit libre tout ce que la phase précédente a quitté, même moins de 5 s avant. Le modèle le cache jusqu'au prochain multiple de 5 s, ce qui change quels trous sont choisis et donc la disposition. Chaque réutilisation d'un cluster tout juste quitté coûte en plus un vidage forcé de $LogFile, une écriture que le modèle ne joue pas.

**Contre-vérification.** Vérifié. NtfsDeallocateClusters (bitmpsup.c:1619) appelle NtfsFreeBitmapRun à 1798, et la bitmap se trouve libérée aussitôt. NtfsGetVolumeBitmap (fsctrl.c:9222) copie les pages de $Bitmap telles quelles, sans y ajouter les clusters « recently deallocated » : FSCTL_GET_VOLUME_BITMAP les montre donc libres. STATUS_ALREADY_COMMITTED n'est levé que sur des bits vraiment occupés (bitmpsup.c:9047-9050). Vers des clusters récemment désalloués, c'est STATUS_DELETE_PENDING (9061-9067), que NtfsDefragExceptionFilter intercepte (deviosup.c:10785-10790). Suivent LfsFlushToLsn et NtfsFreeRecentlyDeallocated (10387-10388), puis un nouvel essai. La citation de Russinovich dans DefragVolume.swift:325-339 ne décrit pas XP SP1.


### `xp-defrag-15pct` — nuancé

**Affirmation.** Les « 15 % d'espace libre » ne sont qu'un seuil d'avertissement (FreeSpaceErrorLevel) : le moteur ne change rien en dessous.

- App : `Sources/Model/WindowsXPStrategy.swift:62-64`
- XP : `base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:2938-2965 ; fssubs.cpp:1239-1276`
- Extrait : « unlike the snap-in, the user doesn't get to answer y/n in the command-line; he has to re-run this with the /f flag »

**Constat.** Le moteur ne change en effet aucun algorithme sous le seuil. Mais ce n'est un simple avertissement que dans la console MMC : CVolume::WarnFutility y pose une question oui/non. En ligne de commande (defrag.exe sans -f), DefragThread appelle ValidateFreeSpace et abandonne avec ENGERR_LOW_FREESPACE. Le seuil vaut 15 par défaut et se règle dans le registre entre 0 et 50.

**Effet.** Aucun pour une passe lancée depuis l'interface graphique, ce que le modèle suppose.

**Contre-vérification.** Confirmé : ValidateFreeSpace et l'abandon ENGERR_LOW_FREESPACE sont gardés par `(bCommandLineMode) && (!bCommandLineForceFlag)` (dfrgntfs.cpp:2938-2965). La valeur de registre est plafonnée à 50 (fssubs.cpp, `if (dwFreeSpaceErrorLevel > 50)`). Aucun algorithme ne change sous le seuil. Pour une passe lancée depuis l'interface graphique, l'affirmation de l'app tient.


### `xp-defrag-demarrage` — confirmé

**Affirmation.** La source donne une zone d'optimisation du démarrage (layout.ini, 32 Mo par fichier au plus, zone déplacée sous 90 %), hors de portée des trois mécanismes ; le modèle ne la fait pas dans la passe XP.

- App : `Sources/Model/WindowsXPStrategy.swift:59-61 ; LEDGER.md:7616-7618`
- XP : `base/fs/utils/dfrg/dfrgntfs/bootoptimizentfs.cpp:67, 71, 744-745, 1724, 1823-1837 ; app : WindowsXPStrategy.swift:59-61 ; LEDGER.md:7559-7561, 7602`
- Extrait : « #define BOOT_OPTIMISE_ZONE_RELOCATE_THRESHOLD    (90) »

**Constat.** Les constantes BOOT_OPTIMIZE_MAX_FILE_SIZE_BYTES (32 Mio) et BOOT_OPTIMISE_ZONE_RELOCATE_THRESHOLD (90) sont bien là. La zone est placée au plus grand trou si moins de 90 % des fichiers y sont déjà ; sinon ses intrus sont expulsés (EvictFile). Elle est rognée de toutes les listes de trous, et ses fichiers sont sautés par la consolidation et le tassement. Le modèle en a conscience et le dit, mais n'applique pas l'exclusion (voir les lacunes).

**Effet.** Voir les lacunes.

**Contre-vérification.** Les constantes sont vérifiées à bootoptimizentfs.cpp:67 et 71. Le seuil de 90 % est à 1823 ; BootOptimizeBeginClusterExclude est posé à 1724 et 1837, et relu depuis le registre (ntfssubs.cpp:2348-2371). La référence au journal est fausse : LEDGER.md:7616-7618 parle des durées de passe. La zone de démarrage est évoquée à LEDGER.md:7559-7561 et 7602.


### `xp-defrag-non-deplacables` — confirmé (vérificateur : nuancé)

**Affirmation.** Le fichier d'échange est ouvert par Windows ; les métafichiers autres que la MFT ne bougent pas.

- App : `Sources/Model/WindowsXPStrategy.swift:253-257`
- XP : `base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:2046-2111, 2287-2295 ; app : WindowsXPStrategy.swift:253-261, GeneratedVolume.swift:165-177, DiskCore/FileCatalog.swift:171-174`
- Extrait : « // Count the root directory as one of the directories. »

**Constat.** ScanNtfs commence à FIRST_USER_FILE_NUMBER, donc les métafichiers 0-15 sont hors des tables. Le fichier d'échange et les exclus de CheckFileForExclude(TRUE) vont dans NonMovableFileTable. Mais le répertoire racine (enregistrement 5, un métafichier) est traité à part avant la boucle et entre dans FragmentedFileTable ou ContiguousFileTable : il est déplaçable.

**Effet.** Faible. Si le modèle classe la racine NTFS en réservé, une racine fragmentée ou mal placée reste en place alors que XP la déplacerait.

**Contre-vérification.** Côté XP, le constat tient : la racine (enregistrement 5) entre dans les tables et elle est déplaçable. Mais la condition posée par le vérificateur (« si le modèle classe la racine en réservé ») n'est pas remplie. Sur NTFS, rootTakesClusters vaut true (FileCatalog.swift:171-174) ; la racine est un répertoire du catalogue, de catégorie .directory et isMovable: true (GeneratedVolume.swift:165-177), donc canTouch l'accepte. Les métafichiers 0-15 ne sont pas des éléments du volume du modèle. Le comportement de l'app est donc celui de XP. Seul son commentaire reste imprécis.


### `xp-defrag-partiel` — confirmé

**Affirmation.** Sur NTFS l'outil déplace chaque fichier entier, jamais en partie ; PartialDefragNtfs n'a pas d'appelant.

- App : `LEDGER.md:7517 ; Sources/Model/WindowsXPStrategy.swift:24, 360-367`
- XP : `base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:4371 ; inc/dfrgntfs.h:126 ; dfrgfat/dfrgfat.cpp:2344-2345, 2512`
- Extrait : « BOOL PartialDefragNtfs( ) »

**Constat.** PartialDefragNtfs est défini mais jamais appelé dans dfrgntfs. dfrgfat, lui, appelle PartialDefragFat en dernier recours (passes 2 et 4).

**Effet.** Aucun sur NTFS. Voir xp-defrag-fat-moteur pour FAT.

**Contre-vérification.** Le grep sur tout dfrg ne trouve pour PartialDefragNtfs que la définition (4371) et la déclaration (inc/dfrgntfs.h:126). PartialDefragFat est bien appelé à dfrgfat.cpp:2345 et défini à 2512.


### `xp-defrag-fat-moteur` — nuancé (vérificateur : contredit)

**Affirmation.** La même WindowsXPStrategy (best fit par taille, consolidation de région, tassement) sert de « passe XP sur FAT » : les mesures lancent 12 passes XP sur des volumes FAT par STRATEGY, et la stratégie contient du code propre à FAT.

- App : `LEDGER.md:7568 ; Sources/Model/WindowsXPStrategy.swift:422-424, 495-496 ; Sources/UI/DefragToolChoice.swift:102-105`
- XP : `base/fs/utils/dfrg/dfrgfat/dfrgfat.cpp:2016-2063, 2268-2378 ; app : Sources/Model/DefragJob.swift:188-192, Sources/UI/DefragToolChoice.swift:92-106, LEDGER.md:7568`
- Extrait : « case 2: case 4: … VolData.ProcessFilesDirection = FORWARD; … dwMoveFlags = MOVE_FRAGMENTED; »

**Constat.** Sur FAT, XP lance dfrgfat, un autre moteur. DefragFat fait six passes fixes. Passe 1 : fichiers contigus, de la fin vers le début, chacun au premier trou avant lui (FindFreeSpace(EARLIER), first fit). Passes 2 et 4 : fichiers fragmentés, du début vers la fin : EARLIER, puis FIRST_FIT n'importe où, puis défragmentation partielle (FindLastFreeSpaceChunks + PartialDefragFat). Passes 3 et 5 : tous les fichiers, de la fin vers le début, en EARLIER. La passe 5 est refaite jusqu'à six fois tant qu'un fichier bouge. La bitmap est relue après chaque déplacement (movefile.cpp:328). Il n'y a ni tri par taille, ni best fit, ni région à 75 %, ni zone MFT. L'interface ne propose XP que sur NTFS (« NTFS only »), ce qui est juste ; seules les mesures sont en cause.

**Effet.** Les 12 passes XP sur FAT des mesures ne représentent pas l'outil de XP sur FAT : durées, nombre de déplacements, disposition finale (tassement first fit complet, fichiers en morceaux vers la fin du disque) et son sont ceux d'un autre algorithme.

**Contre-vérification.** Le fait est exact : DefragFat, six passes, la passe 5 refaite jusqu'à six fois (dfrgfat.cpp:2016-2063), c'est un autre moteur. Mais « contredit » vise une affirmation que l'app ne fait pas. L'interface limite XP au NTFS (DefragToolChoice.swift:92-106, `onlyOn: .ntfs`), et DefragJob.strategy(for:) donne Windows95Strategy à tout FAT (DefragJob.swift:188-192). Le README ne compare XP que sur NTFS (README.md:1407-1410, readme-tables.py « scénario NTFS »). Aucun disque d'époque ne met XP sur FAT : les FAT sont de 1993 à 1999, et les disques 2003 sont tous en NTFS (scenarios/*-2003.json). Seules les 12 passes XP sur FAT des mesures (LEDGER.md:7568) sont hors modèle, et il faut les lire comme un artefact de STRATEGY, pas comme l'outil de XP sur FAT.


### `xp-defrag-fat-bloc` — nuancé (vérificateur : contredit)

**Affirmation.** Les blocs de 64 Kio (bufferBytes) valent pour tout FSCTL_MOVE_FILE, y compris sur FAT.

- App : `Sources/Model/WindowsXPStrategy.swift:89-93, 364-367`
- XP : `base/fs/fastfat/fsctrl.c:5429, 5461, 5959-5968 ; app : JKDefragStrategy.swift:146, UltraDefragStrategy.swift:165, SmartDefragStrategy.swift:49-51`
- Extrait : « if ((FileOffset & 0x3ffff) + *ByteCount > 0x40000) { *BytesToReallocate = 0x40000 - (FileOffset & 0x3ffff); »

**Constat.** LARGE_BUFFER_SIZE vaut pour NTFS seulement. Sur FAT, FatMoveFile avance par tranches d'au plus 0x40000 octets (256 Kio), alignées sur des multiples de 256 Kio dans le fichier (FatComputeMoveFileParameter). La source est lue par le cache (CcMapData), écrite par IoCallDriver, et FatFlushFatEntries réécrit la FAT à chaque tranche.

**Effet.** Toute passe par l'API de Windows sur FAT jouée en 64 Kio compte quatre fois trop de paires lecture/écriture, avec des écritures de FAT à chaque tranche. Cela touche la durée et le rythme sonore.

**Contre-vérification.** Le fait côté fastfat est exact : FatComputeMoveFileParameter coupe en tranches de 0x40000 alignées (fsctrl.c:5959-5968), et FatFlushFatEntries tourne à chaque tranche (5429). L'app, en revanche, n'affirme nulle part que 64 Kio vaut sur FAT : bufferBytes n'appartient qu'à WindowsXPStrategy, que l'interface réserve au NTFS. L'impact « toute passe par l'API de Windows sur FAT jouée en 64 Kio » est faux. Sur FAT, JkDefrag prend 4 Mio (JKDefragStrategy.swift:146) et UltraDefrag moveAtOnce ; aucun des deux ne suit donc la coupe à 256 Kio de fastfat. Un écart réel, mais il concerne ces outils, pas XP. SmartDefrag, lui, prend déjà 256 Kio sur FAT (SmartDefragStrategy.swift:49-51).


### `xp-defrag-fat-repertoires` — confirmé

**Affirmation.** Sur FAT, FSCTL_MOVE_FILE refuse de déplacer le premier cluster d'un répertoire (moveFileAccepts).

- App : `Sources/Model/DefragVolume.swift:306-323`
- XP : `base/fs/fastfat/fsctrl.c:5194-5225`
- Extrait : « We cannot move the first cluster because sub-directories have this cluster number in them »

**Constat.** Le commentaire de FatMoveFile le dit mot pour mot : pas le premier cluster d'un sous-répertoire, parce que les enfants portent son numéro. Nuance : sur FAT32, le déplacement de la racine est permis, puisque c'est une vraie chaîne.

**Effet.** Aucun.

**Contre-vérification.** La condition est à fsctrl.c:5216-5220 : `(TypeOfOpen == UserDirectoryOpen) && ((racine && !FatIsFat32) || StartingVcn == 0)`. La nuance du vérificateur sur la racine FAT32 induit en erreur : la racine FAT32 échappe au refus global, mais le test `StartingVcn == 0` s'applique à elle comme à tout répertoire. Son premier cluster ne bouge pas non plus. La règle de l'app (DefragVolume.swift:321-323 : répertoire, FAT, vcn 0) est donc exactement celle de fastfat.


### `xp-defrag-vista7` — non vérifiable

**Affirmation.** Vista et Windows 7 : même moteur que XP, avec les fragments de 64 Mo et plus laissés en place (KB 942092).

- App : `Sources/Model/WindowsXPStrategy.swift:66-69, 106-119`
- XP : `—`

**Constat.** Le code de XP SP1 ne dit rien de Vista ni de 7. On n'y trouve aucun seuil de 64 Mo ; XP recolle tout (FindFreeSpace exige un trou pour le fichier entier). XP ne vaut ici que comme indice de l'ancêtre : dire que Vista et 7 gardent le même moteur reste une hypothèse.

**Effet.** Inconnu.

**Contre-vérification.** Le code de XP SP1 ne couvre ni Vista ni 7. Aucun seuil de 64 Mo dans dfrgntfs : FindFreeSpace exige un trou pour le fichier entier. KB 942092 et « même moteur » restent invérifiables avec cette source.


### Lacunes — Le défragmenteur de XP (dfrgntfs, dfrgfat), contre-vérification

- **L'optimisation du démarrage passe avant tout le reste sur le volume système (ProcessBootOptimise, avant MFTDefrag). Elle place ou déplace la zone (au plus grand trou si moins de 90 % des fichiers y sont), expulse les intrus (EvictFile) et y range les fichiers de layout.ini (32 Mio au plus chacun). La zone est ensuite rognée de toutes les listes de trous, et ses fichiers sont sautés par la consolidation et le tassement.** — `base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:2861 ; bootoptimizentfs.cpp:1740-2031 ; freespace.cpp:320-333, 446-459, 567-580 ; dfrgntfs.cpp:3758-3763, 4062-4068`. Disposition : un bloc de fichiers de démarrage contigus que rien ne dérange, et des trous interdits. Son : une salve initiale de déplacements et d'évictions que la passe XP modélisée n'a pas. *Contre-vérification :* Confirmé : dfrgntfs.cpp:2861 passe avant MFTDefrag (2906), sur le volume de démarrage seulement (commentaire à 2852-2853). La zone de démarrage est rognée dans les trois constructeurs de listes (freespace.cpp:320-333 et ses équivalents), et les fichiers FLE_BOOTOPTIMISE sont sautés dans ConsolidateFreeSpace et MoveFilesForward. Dans Sources/, BootLayout ne sert qu'à SmartDefragStrategy (BootLayoutConsumer), et WindowsXPStrategy n'en fait rien : la lacune est réelle, et le docstring (59-61) la reconnaît.
- **Un cluster tout juste quitté est réutilisé aussitôt au prix d'un vidage du journal : STATUS_DELETE_PENDING, puis LfsFlushToLsn et NtfsFreeRecentlyDeallocated, puis nouvel essai (10 au plus).** — `base/fs/ntfs/deviosup.c:10380-10388, 10661-10671 ; bitmpsup.c:9061-9067`. Son : une écriture forcée de $LogFile à chaque réutilisation immédiate. Disposition : des trous visibles plus tôt que dans le modèle (5 s de rétention). *Contre-vérification :* Vérifié à bitmpsup.c:9061-9067 et deviosup.c:10387-10388 et 10785-10790. L'app fait l'inverse : elle retient ces clusters jusqu'au prochain point de contrôle de 5 s (NTFSCheckpoints, DefragStrategy.swift:595-614 ; releaseWaitsForCheckpoint, DefragVolume.swift:339). Nuance : il n'y a vidage que si la cible recoupe des clusters récemment désalloués et encore suivis ; le décompte est DeletePendingFailureCountsLeft.
- **Un commit de transaction (et les écritures USN) à chaque bloc de 64 Kio, pas une validation par fichier.** — `base/fs/ntfs/deviosup.c:10614-10618 ; base/fs/ntfs/logsup.c:2979-3010`. Son : sur un gros fichier, des écritures de journal entre les blocs, qui peuvent ajouter des seeks vers $LogFile. *Contre-vérification :* Tient dans le code : NtfsCheckpointCurrentTransaction à chaque bloc (deviosup.c:10618 → logsup.c:3014). La lacune n'est que partielle : l'app joue déjà une page de journal toutes les huit validations (VolumeLayout.swift:313-330), mais elle en compte une validation par fichier. Qu'un commit LFS devienne une écriture disque immédiate, avec seek, n'est pas établi : LFS met en tampon.
- **Pas de copie au-delà de la ValidDataLength : ces clusters sont seulement réalloués.** — `base/fs/ntfs/deviosup.c:10540-10549`. Durée et son : les fichiers préalloués se déplacent plus vite que ce que le modèle joue. *Contre-vérification :* Vérifié à deviosup.c:10540-10549 : lecture et écriture n'ont lieu que si StartingVcn <= UpperBound (VDL). Aucune trace de VDL dans Sources/ : le modèle copie toujours tout ce qui est alloué.
- **MFTDefrag déplace la queue de la MFT dès qu'elle a deux extents, vers le premier trou hors zone MFT de la taille de la MFT entière, avant et après la passe.** — `base/fs/utils/dfrg/dfrgntfs/mftdefrag.cpp:120-133 ; defragcommon.cpp:150-167`. Disposition de la MFT et deux longues copies par passe que le modèle ne joue pas quand la queue est d'un seul tenant. *Contre-vérification :* Confirmé : mftdefrag.cpp:120-133, GetMFTSize à 277-288, MarkBitMapforNTFS à defragcommon.cpp:150-153. L'app exige trois extents (WindowsXPStrategy.swift:386), cherche la taille de la queue seule et accepte la zone MFT (avoidingMFTZone: false). Une fois la MFT recollée en deux extents, l'app ne la déplace plus, alors que XP la redéplacerait à chaque appel. Il faut aussi que le premier extent dépasse 16 enregistrements.
- **Le moteur FAT de XP (dfrgfat) : six passes de first fit (EARLIER/FIRST_FIT), défragmentation partielle vers les derniers trous, bitmap relue après chaque déplacement ; fastfat déplace par tranches de 256 Kio et réécrit la FAT à chaque tranche.** — `base/fs/utils/dfrg/dfrgfat/dfrgfat.cpp:2016-2378 ; base/fs/fastfat/fsctrl.c:5429, 5959-5968`. Seul modèle fidèle pour une passe « Windows XP sur FAT32 » (disques 2003 en FAT32) : disposition, nombre de déplacements, rythme des blocs. *Contre-vérification :* Le fait tient et l'app ne le modélise pas. La pertinence annoncée est fausse, en revanche : aucun disque d'époque ne passe XP sur FAT. Les disques 2003 sont tous en NTFS (scenarios/*-2003.json), les FAT32 sont de 1999, et DefragJob.strategy(for:) donne Windows95Strategy à tout FAT. Cela ne touche que les 12 passes XP sur FAT des mesures (LEDGER.md:7568). Les 256 Kio de fastfat concernent plutôt JkDefrag (4 Mio) et UltraDefrag sur FAT, que l'app joue en blocs plus grands.

## Démarrage : préchargeur, Layout.ini, optimisation du démarrage, dernier accès


### `boot-01` — contredit

**Affirmation.** Le préchargeur de démarrage de XP range la liste de ce qu'il relit par position sur le disque (BootOrder.byPosition, tri par premier LCN après le tirage).

- App : `Sources/Model/BootSession.swift:108-113, 252-260, 716-725 ; README.md:826-830 ; Sources/UI/Explanations.swift:67`
- XP : `admin/services/sched/service/daytona/pfsvc.c:2631-2635 ; base/ntos/cache/prefetch.c:5281 (un seul MmPrefetchPages par lot, sections dans l'ordre du scénario) ; base/ntos/mm/pfsup.c:878-880 ; drivers/storage/ide/atapi/internal.c:3877-3878 ; drivers/storage/classpnp/xferpkt.c:399-406`
- Extrait : « // Sort remaining sections by first access. / « our caller always passes ordered lists of logical block offsets within a given file » »

**Constat.** Ni le service ni le noyau ne trient par LCN. Pfsvc range les sections (fichiers) du scénario par ordre de premier accès pendant la trace. Le noyau construit une liste de lecture par fichier, dans l'ordre du scénario, avec les pages de chaque fichier par offset croissant, puis appelle MmPrefetchPages. L'ordre « par position » n'existe que de deux façons indirectes : (1) defrag -b pose les fichiers de Layout.ini dans cet ordre de premier accès, si bien qu'après optimisation l'ordre du scénario coïncide à peu près avec celui du disque ; (2) les lectures partent toutes en asynchrone, et le pilote de port IDE les sert par clé LBA croissante (voir boot-02).

**Effet.** Sur un volume XP livré sans optimisation du démarrage, l'ordre de demande n'est pas l'ordre du disque. Le son reste pourtant proche d'un balayage, grâce à l'ascenseur du pilote (boot-02). Le libellé « range la liste par position » est à corriger : c'est le pilote de port qui ordonne, et le défragmenteur qui aligne les deux ordres.

**Contre-vérification.** J'ai relu les deux côtés. Côté app, BootSession.swift:108-113 et 716-725 trient bien `chosen` par premier LCN. Explanations.swift:66-67 et README.md:826-830 disent « range la liste par position ». Côté XP, pfsvc.c:2632-2635 appelle PfSvSortSectionNodesByFirstAccess avant PfSvWriteScenario. CcPfPrefetchSections parcourt les sections dans l'ordre du scénario et passe tout le lot à MmPrefetchPages (prefetch.c:5281). pfsup.c:878-880 suppose des offsets croissants à l'intérieur d'un fichier. Aucun tri par LCN, ni côté service ni côté noyau : le « range par position » est contredit à la lettre. Le résultat audible (un balayage) tient quand même, par l'ascenseur à sens unique d'atapi : KeRemoveByKeyDeviceQueue à partir de CurrentKey, avec la clé = LBA posée par classpnp (commentaire en xferpkt.c:399-400 : « sort the SRBs by the logical block address so that disk seeks are minimized »). Il tient aussi par defrag -b après optimisation.


### `boot-02` — nuancé

**Affirmation.** Le préchargeur relit tout « d'une seule course du bras ».

- App : `Sources/Model/BootSession.swift:108-111, 252-258 ; README.md:828-829`
- XP : `base/ntos/mm/pfsup.c:318-338 (toutes les lectures émises) puis 370-388 (attente) ; pfsup.c:55-61 (SEEK_THRESHOLD, défini ligne 61) et 1103 ; base/ntos/cache/prefboot.c:482-490, 722, 742-829, 855-929 ; drivers/storage/ide/atapi/internal.c:3877, 3959`
- Extrait : « Pkt->Srb.QueueSortKey = logicalBlockAddr; / // First we will prefetch data pages, then image pages. / #define SEEK_THRESHOLD ((128 * 1024) / PAGE_SIZE) »

**Constat.** MmPrefetchPages met toutes les pages en transition et émet toutes les lectures d'un lot en asynchrone (IoAsynchronousPageRead) avant d'attendre. Le port IDE d'XP (atapi) garde une file triée par clé et la sert par KeRemoveByKeyDeviceQueue depuis CurrentKey. La clé est la LBA, posée par classpnp : c'est un ascenseur à sens unique. Il n'y a pourtant pas une seule course. On a d'abord un lot de métadonnées (MFT, répertoires), puis, pour chaque phase de préchargement, un lot de pages de données suivi d'un lot de pages d'image. Les phases sont : pilotes système, tout le reste avant SMSS (si la mémoire suffit, sinon une phase par étape de démarrage), puis une phase en parallèle de l'initialisation vidéo. Chaque lot fait son propre balayage. Et un trou de moins de 128 Ko entre deux pages est lu quand même (page factice) plutôt que de couper la requête.

**Effet.** Le démarrage XP devrait faire entendre quelques balayages successifs (métadonnées, données, images, par phase), pas un seul. Les petits trous sont lus et non sautés, ce qui fait moins de requêtes, plus longues.

**Contre-vérification.** Vérifié. MmPrefetchPages met en transition et émet via MiPfExecuteReadList toutes les listes du lot (pfsup.c:318-338), puis attend chacune (pfsup.c:370-388). Chaque phase fait un appel CcPfPrefetchSections pour le curseur données, puis un autre pour le curseur images (prefboot.c:855-929), plus le lot de métadonnées en tête (722). On a donc plusieurs balayages. Deux corrections de détail. SEEK_THRESHOLD est défini à pfsup.c:61, pas 56-58 (là, c'est le commentaire). Le seuil de 128 Ko se mesure en offset **dans le fichier** (distance entre PTE prototypes, pfsup.c:1103), pas en distance sur le disque. Une réserve : sous forte charge, classpnp peut différer des IRP dans une liste FIFO (clntirp.c:38, DeferredClientIrpList), mais il alloue d'ordinaire ses paquets à la demande. L'ascenseur reste donc le cas normal.


### `boot-03` — contredit

**Affirmation.** Le préchargeur garde la trace des six derniers démarrages.

- App : `Sources/Model/BootSession.swift:254-256`
- XP : `public/internal/base/inc/prefetch.h:180, 187 ; admin/services/sched/service/daytona/pfsvc.c:4301-4311 ; pfsvc.h:55`
- Extrait : « #define PF_PAGE_HISTORY_SIZE 8 / // Don't let the boot scenario's sensitivity to fall below 2. »

**Constat.** L'historique d'usage de chaque page porte sur 8 lancements (PF_PAGE_HISTORY_SIZE). Une page n'est préchargée que si elle a servi dans au moins « Sensitivity » de ces lancements. Cette sensibilité s'ajuste selon le taux de réussite (90 %) et ne descend jamais sous 2 pour le démarrage.

**Effet.** Aucun effet sur le son (le modèle ne simule pas l'historique). Il suffit de corriger le chiffre dans le commentaire : 8 démarrages, et une page vue au moins 2 fois.

**Contre-vérification.** PF_PAGE_HISTORY_SIZE vaut 8 (prefetch.h:180), et UsageHistory est un champ de 8 bits (prefetch.h:450). Le plancher de sensibilité à 2 pour le démarrage est en pfsvc.c:4301-4311, et PFSVC_MIN_HIT_PERCENTAGE 90 en pfsvc.h:55. Le « six derniers démarrages » de BootSession.swift:254-256 est faux. Aucun effet sur le son.


### `boot-04` — nuancé

**Affirmation.** Un acte préchargé lit d'abord les enregistrements de MFT des fichiers, dans l'ordre de la MFT, d'une requête par suite contiguë, avant toute donnée.

- App : `Sources/Model/BootSession.swift:870-925`
- XP : `base/ntos/cache/prefboot.c:722 ; base/ntos/cache/prefetch.c:4605 (CcPfPrefetchMetadata aussi au lancement d'une application), 5455-5470 ; base/fs/ntfs/fsctrl.c:19228-19230, 19334-19340, 19356-19362, 19433`
- Extrait : « //  Round down to page boundary. / // Walk through the contents of the directories sequentially »

**Constat.** Confirmé sur le principe : CcPfPrefetchMetadata passe avant les curseurs de données et d'images. NTFS (FSCTL_FILE_PREFETCH, réservé à la MFT) trie les numéros d'enregistrement, les arrondit à la page de 4 Ko, supprime les doublons et confie la liste à MmPrefetchPages. Deux écarts avec le modèle. D'abord, la lecture est par pages, et un trou de moins de 128 Ko entre deux pages est lu d'un seul tenant (page factice), là où le modèle coupe à chaque discontinuité. Ensuite, le préchargement des métadonnées parcourt aussi le contenu des répertoires, parents avant enfants. Enfin, il ne se fait qu'une fois pour tout le démarrage, pas une fois par acte.

**Effet.** Moins de requêtes de MFT et plus longues : les suites séparées de quelques Ko se fondent. Un seul bloc de métadonnées en tête de démarrage au lieu d'un par acte (pilotes, session, application). Le modèle surestime un peu les seeks courts vers la MFT.

**Contre-vérification.** Confirmé côté source : l'arrondi à la page de 4 Ko (fsctrl.c:19336-19340), l'insertion triée (19356-19362), puis MmPrefetchPages(1, &ReadList) (19433). Le parcours des répertoires, parents avant enfants, est en prefetch.c:5462-5470. Je corrige une partie de l'impact. Au démarrage, CcPfPrefetchMetadata n'est appelé qu'une fois (prefboot.c:722). Mais un lancement d'application est un scénario distinct, qui refait son propre préchargement de métadonnées (prefetch.c:4605). « Un seul bloc au lieu d'un par acte (pilotes, session, application) » est donc juste pour pilotes et session, pas pour l'application quand elle est lancée par son propre scénario. Côté app, BootSession.swift:870-925 coupe bien à chaque discontinuité d'enregistrement, sans arrondi à la page ni comblement des trous.


### `boot-05` — nuancé

**Affirmation.** Ce qu'on lit d'un fichier au démarrage est plafonné (bytesPerFile), lu depuis le début du fichier, à la granularité de la page de 4 Ko.

- App : `Sources/Model/BootSession.swift:268-273, 506-530, 930-940`
- XP : `base/ntos/cache/prefparm.c:259-261 ; base/ntos/cache/prefetch.c:4650-4668 ; base/ntos/mm/pfsup.c:61, 1103`
- Extrait : « TraceLimits->MaxNumPages = 128000; TraceLimits->MaxNumSections = 4080; »

**Constat.** La granularité de 4 Ko est confirmée : la trace et le préchargement travaillent en pages. En revanche XP ne lit pas « les N premiers Ko » : il relit exactement les pages de la trace, éparses dans le fichier, par offset croissant, avec les trous de moins de 128 Ko comblés. Pour une image, la page d'en-tête est lue avec les données. Le plafond de la trace de démarrage est de 128 000 pages et 4 080 sections (fichiers).

**Effet.** Lectures intra-fichier plus fragmentées que le modèle ne le suppose sur les grosses DLL, mais fondues par le seuil de 128 Ko. L'effet sonore est faible. Le plafond de 4 080 fichiers dépasse largement les budgets de l'ère XP (600 + 110 + 180).

**Contre-vérification.** Les plafonds du scénario de démarrage sont vérifiés : 128 000 pages et 4 080 sections, avec des périodes de 12 s (prefparm.c:259-261). Le commentaire de CcPfPrefetchSections (prefetch.c:4661-4665) confirme que les pages d'en-tête des images partent avec les données. Côté app, `touched = min(logicalSize, bytesPerFile)` est lu depuis le début des extents (BootSession.swift:930-940) : c'est un modèle, pas une relecture de pages tracées. Le verdict nuancé tient.


### `boot-06` — nuancé

**Affirmation.** Sous XP, seuls les actes pilotes, ouverture de session et application sont préchargés. Le noyau part du plus gros d'abord, les services et la fin de démarrage dans un ordre « déclaré » (aléatoire), acte après acte avec le calcul entre deux.

- App : `Sources/Model/BootSession.swift:381-404, 492-540`
- XP : `base/ntos/cache/prefboot.c:350-397 (minuteries de fin de trace), 742-829, 855-965 ; base/ntos/cache/prefparm.c:261 ; public/internal/base/inc/prefetch.h:151 ; admin/services/sched/service/daytona/pfsvc.c:6149-6155, 13619-13622`
- Extrait : « TraceLimits->TimerPeriod = (-1 * 12000 * 1000 * 10); / #define PF_MAX_NUM_TRACE_PERIODS 10 / MaxWaitTime ... // 30 seconds. »

**Constat.** Pour le noyau, c'est juste en substance : ntoskrnl, HAL, la ruche SYSTEM et les pilotes de démarrage sont chargés par NTLDR avant que le préchargeur existe. C'est pourquoi pfsvc les met en tête de Layout.ini. Mais la trace de démarrage couvre tout, de l'initialisation des pilotes système jusqu'à 30 s après que le shell est prêt (ou 60 s après l'acceptation du démarrage), dans la limite de 10 périodes de 12 s. Les fichiers des services et de la session y sont donc aussi, et sont préchargés. Et le préchargement n'accompagne pas chaque acte : un fil de travail précharge par grandes phases (pilotes système, puis tout le reste avant SMSS si MmAvailablePages le permet, puis une part en parallèle de la vidéo). Le démarrage attend la fin de chaque phase par événement.

**Effet.** Sur une machine XP bien pourvue en mémoire, presque tout le disque du démarrage se lit en une rafale au début (pilotes, puis le reste), et le reste du démarrage se fait en fautes douces, presque silencieuses. Le modèle garde l'acte des services en va-et-vient aléatoire : il surestime le crépitement des services sous XP et étale le bruit sur toute la durée.

**Contre-vérification.** Vérifié. PfSvBuildBootLoaderFilesList nomme ntoskrnl.exe, hal.dll, config\system et config\software (pfsvc.c:13619-13622), et ces fichiers passent en tête de Layout.ini (6149). Les phases de préchargement et leurs événements sont en prefboot.c:742-829 et 930-955. Le repli par phase quand la mémoire manque est en 776-810. Côté app, l'acte des services reste `.declared`, non préchargé (BootSession.swift, acte 4 dans `acts(launching:)`, vers les lignes 510-516), et chaque acte émet ses lectures entre deux temps de calcul. L'écart décrit par le vérificateur est réel.


### `boot-07` — confirmé

**Affirmation.** Le préchargeur passe layout.ini au défragmenteur « tous les trois jours au plus, à l'inactivité ».

- App : `LEDGER-REALISME.md:128-129, 442`
- XP : `admin/services/sched/service/daytona/pfsvc.h:207 ; pfsvc.c:590-603, 740-757, 5728-5760 (Layout.ini écrit avant le contrôle de fréquence), 5770-5850, 5987 ; admin/services/sched/idletask/server/idletsks.h:39, 49-50, 76, 83`
- Extrait : « #define PFSVC_MIN_TIME_BEFORE_DISK_RELAYOUT (1i64 * 3 * 24 * PFSVC_NUM_100NS_IN_AN_HOUR) / if (NumMissingFiles <= 20) { »

**Constat.** Le délai minimal entre deux réorganisations est de 3 × 24 h (modifiable par MinRelayoutHours). La tâche passe par le service des tâches à l'inactivité (ItOptimalDiskLayoutTaskId). Elle est enregistrée au démarrage du service, puis de nouveau toutes les 32 traces traitées avec succès. L'inactivité suppose 12 min de détection, puis 5 vérifications de 30 s, avec processeur et disque inactifs à 90 % au moins. Il y a trois exceptions au délai de 3 jours : l'appel explicite (ProcessIdleTasks), un Layout.ini supprimé puis recréé, et la toute première optimisation après le traitement d'une trace de démarrage. Et Layout.ini n'est réécrit, et le défragmenteur lancé, que si plus de 20 fichiers manquent à la disposition courante.

**Effet.** Confirme que l'état livré d'un disque XP porte déjà une optimisation du démarrage. La première arrive même dès la première inactivité qui suit un démarrage tracé, sans attendre trois jours.

**Contre-vérification.** Tout est vérifié : 3 × 24 h, MinRelayoutHours, la réinscription toutes les 32 traces, 12 min d'inactivité puis 5 × 30 s, 90 % CPU et disque, les trois exceptions, et le seuil de NumMissingFiles <= 20. Une précision : le délai de 3 jours ne bride que le lancement du défragmenteur. Layout.ini, lui, est réécrit (PfSvSaveLayout, pfsvc.c:5760) dès que la disposition a changé, avant le contrôle de fréquence.


### `boot-08` — confirmé

**Affirmation.** Le défaut Enable=Y de BootOptimizeFunction sous XP n'est attesté que par une copie tierce de dfrg.inf (hypothèse).

- App : `LEDGER-REALISME.md:442`
- XP : `mergedcomponents/setupinfs/dfrg.inx:23-27 ; base/fs/utils/dfrg/dfrg.reg:23-26 ; base/fs/utils/dfrg/sld/disk_defragmenter_core_{1693078d-...}.sld:738-763 ; base/fs/utils/dfrg/dfrgntfs/bootoptimizentfs.cpp:1600-1625 ; admin/services/sched/service/daytona/pfsvc.c:10219-10246, 10290`
- Extrait : « [HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Dfrg\BootOptimizeFunction] "Enable"="Y" »

**Constat.** Le fichier d'enregistrement du défragmenteur, dans la source, écrit Enable="Y" (REG_SZ) sous HKLM\SOFTWARE\Microsoft\Dfrg\BootOptimizeFunction. Le composant de setup (.sld) déclare la même clé. Le moteur NTFS renonce si la clé manque ou si le premier caractère n'est pas 'Y'. Côté service, EnableAutoLayout (clé OptimalLayout) est absent par défaut, ce qui vaut « autorisé ». Le lancement est réservé aux postes de travail (VER_NT_WORKSTATION), et à condition qu'un type de préchargement soit actif.

**Effet.** La réserve du LEDGER peut être levée : le réglage est actif par défaut, d'après la source elle-même.

**Contre-vérification.** La preuve est plus forte que ce que citait le vérificateur. La source d'installation de dfrg.inf elle-même (mergedcomponents/setupinfs/dfrg.inx:23) écrit `HKLM,"SOFTWARE\Microsoft\Dfrg\BootOptimizeFunction","Enable",0x00000000,"Y"`, avec LcnStartLocation = "0", LcnEndLocation = "0" et OptimizeComplete = "No" (lignes 24-27). C'est la source primaire du .inf que le LEDGER ne connaissait que par une copie tierce. La réserve peut être levée.


### `boot-09` — nuancé

**Affirmation.** Layout.ini contient ce qu'un démarrage lit, dans l'ordre où il le lit (BootLayout = readOrder du démarrage planifié, application lancée comprise).

- App : `Sources/Model/BootLayout.swift:4-8, 21-23 ; Sources/Model/BootSession.swift:558-561 ; README.md:1363-1366`
- XP : `admin/services/sched/service/daytona/pfsvc.c:6149-6180, 6318-6362, 6003-6020, 13563-13660`
- Extrait : « // Add boot loader files to optimal layout. / // Go through all the other scenario files. / // First add the directories that need to be accessed. »

**Constat.** PfSvDetermineOptimalLayout écrit dans l'ordre suivant. D'abord les fichiers du chargeur : ntoskrnl, hal, config\system, NLS et polices du chargeur, pilotes de démarrage d'après le gestionnaire de services, puis la ruche SOFTWARE. Ensuite le scénario de démarrage, avec tous ses répertoires d'abord, puis ses fichiers dans l'ordre de premier accès. Enfin tous les autres scénarios .pf (lancements d'applications), chacun répertoires puis fichiers. Ce n'est donc pas l'ordre de lecture fichier par fichier, et la liste va bien au-delà du démarrage. En mise à jour, les nouveaux fichiers s'ajoutent à la fin de l'ancienne liste, qui n'est refaite que si un quart en est périmé.

**Effet.** Chez XP, la zone de démarrage contient aussi les applications souvent lancées et les répertoires groupés en tête de chaque scénario. Le rangement intelligent (inspiré, pas imité) n'en est pas faux, mais « c'est ce que XP écrit » est approximatif.

**Contre-vérification.** L'ordre d'écriture est vérifié : chargeur, puis scénario de démarrage (répertoires d'abord, puis fichiers dans l'ordre de premier accès, puisque pfsvc les a triés ainsi), puis les autres .pf. En mise à jour, l'ajout se fait en fin de liste, et la liste est reconstruite si au moins un quart en est périmé (6006). J'ajoute un écart côté app que le vérificateur n'a pas relevé. BootLayout reprend `readOrder` (BootLayout.swift:21-23), qui s'alimente dans `emit` après le tri `.byPosition` (BootSession.swift:716-725, 940). Pour les actes préchargés, le Layout.ini du modèle est donc l'ordre **actuel sur le disque**, pas l'ordre de premier accès comme chez XP. La liste se reproduit elle-même au lieu de réordonner.


### `boot-10` — confirmé

**Affirmation.** La zone d'optimisation du démarrage de XP ne prend que les fichiers de 32 Mo au plus, et reste hors de portée des trois mécanismes de la passe XP.

- App : `Sources/Model/WindowsXPStrategy.swift:59-62`
- XP : `base/fs/utils/dfrg/dfrgntfs/bootoptimizentfs.cpp:67, 1920-1931 ; base/fs/utils/dfrg/freespace.cpp:327-330, 449-452, 571-574 ; base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:3634-3636 ; base/fs/utils/dfrg/movefile.cpp:111-114`
- Extrait : « #define BOOT_OPTIMIZE_MAX_FILE_SIZE_BYTES (32 * 1024 * 1024) »

**Constat.** BOOT_OPTIMIZE_MAX_FILE_SIZE_BYTES vaut 32 Mo : un fichier plus gros est écarté à la lecture de Layout.ini, puis au déplacement. La MFT (FRN 0) est ignorée. La zone [BootOptimizeBeginClusterExclude, BootOptimizeEndClusterExclude] est exclue des listes d'espace libre de la passe.

**Effet.** —

**Contre-vérification.** La constante de 32 Mo et l'exclusion de la MFT (FRN 0) sont confirmées. La référence de l'exclusion était mauvaise : bootoptimizentfs.cpp:1027-1028 ne fait que compter les fichiers déjà dans la zone (BootOptimiseFilesAlreadyInZoneSize). L'exclusion de la zone des listes d'espace libre se fait dans freespace.cpp (327-330, 449-452, 571-574) et dfrgntfs.cpp:3634-3636. movefile.cpp:111-114 traite les extents situés dans la zone. Le fait est vrai.


### `boot-11` — nuancé

**Affirmation.** Le rangement pour démarrer pose le bloc de démarrage en tête du volume (devant $MFT), dans l'ordre de Layout.ini. C'est ce que fait l'idée de XP.

- App : `README.md:1363-1370 ; Sources/Model/SmartDefragStrategy.swift:24-28`
- XP : `base/fs/utils/dfrg/dfrgntfs/bootoptimizentfs.cpp:67-72, 1696-1725, 1817-1838, 2006-2031 ; mergedcomponents/setupinfs/dfrg.inx:24-25`
- Extrait : « #define BOOT_OPTIMISE_ZONE_RELOCATE_THRESHOLD (90) / #define BOOT_OPTIMIZE_MAX_ZONE_SIZE_MB ((LONGLONG) (4 * 1024)) »

**Constat.** L'ordre de Layout.ini est bien celui du déplacement (pBootOptimiseFrnList, fichier après fichier). La place, elle, n'est pas « en tête ». La zone part de LcnStartLocation, gardé dans le registre (0 au premier passage). Si moins de 90 % des fichiers de la liste y sont déjà, et qu'un trou libre plus grand que leur total existe, la zone est déplacée au début du plus grand trou libre. Sinon, les fichiers étrangers à la liste sont évacués de la zone. Quand un fichier ne trouve pas de place, la zone grandit de 150 % du manque (100 Mo au moins), dans la limite de 4 Go et de 50 % du volume. Elle est ensuite mémorisée (LcnStart/EndLocation) pour le passage suivant.

**Effet.** Sur un XP réel, le bloc de démarrage atterrit le plus souvent au début du plus grand trou (souvent au milieu ou en fin de données), pas au LCN 0. Le choix « en tête » du rangement intelligent est à présenter comme celui du projet. Un XP livré modélisé fidèlement aurait un bloc contigu mais excentré : un seek d'accès, puis un balayage court.

**Contre-vérification.** Le mécanisme est vérifié. La zone part de LcnStartLocation (0 d'après dfrg.inx:24). Elle est relogée au début du plus grand trou si celui-ci dépasse le total des fichiers et que moins de 90 % y sont déjà. Précision sur la croissance : le minimum de 100 Mo s'applique au manque **avant** le facteur 150 % (2022-2027), si bien que la zone grandit d'au moins 150 Mo. « Le plus souvent au milieu ou en fin de données » est une inférence, pas du code. Côté app, une incohérence à signaler : README.md:1366-1367 dit « en tête du volume — devant `$MFT` », alors que SmartDefragStrategy.swift:24-25 dit « derrière la zone MFT sur NTFS ».


### `boot-12` — nuancé

**Affirmation.** La passe XP modélisée n'inclut pas l'optimisation du démarrage (« Ce que la source donne aussi, et que le modèle ne fait pas »).

- App : `Sources/Model/WindowsXPStrategy.swift:59-62`
- XP : `base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:2007-2013, 2852-2893, 2906 ; base/fs/utils/dfrg/dfrgntfs/bootoptimizentfs.cpp:1774-1777 ; base/fs/utils/dfrg/defrag/defrag.cpp:351-354, 873-877 ; admin/services/sched/service/daytona/pfsvc.c:6947`
- Extrait : « // If command line was boot optimize -b /b, do the boot optimise only / DoLayoutParameter = L"-b "; »

**Constat.** L'aveu est exact, mais il y a plus. Sur le volume de démarrage, une défragmentation manuelle (hors analyse) active bBootOptimise et appelle ProcessBootOptimise en premier (état DEFRAG_STATE_BOOT_OPTIMIZING), avant la MFT et la passe ordinaire. Avec -b (le lancement par le préchargeur), le moteur ne fait que cela et sort. Le défragmenteur est donc lancé de deux façons : automatiquement en -b (boot seul, à l'inactivité, au plus tous les 3 jours) et manuellement. Chaque passe manuelle commence par la zone de démarrage.

**Effet.** Il manque à la passe XP une phase d'ouverture : lecture de Layout.ini, évacuation de la zone, fichiers de démarrage recopiés à la suite. Cette phase change à la fois le son du début de passe et la disposition finale (bloc groupé).

**Contre-vérification.** Vérifié. Hors analyse, sur le volume de démarrage, bBootOptimise est vrai (2007-2008). ProcessBootOptimise passe (état DEFRAG_STATE_BOOT_OPTIMIZING, 2856-2861) avant MFTDefrag (2906) et la passe ordinaire (2973). En -b, on sort juste après (2873-2893). ProcessBootOptimise ne fait rien si la zone n'a pas été initialisée (bootoptimizentfs.cpp:1774-1777, ENGERR_BAD_PARAM), par exemple sur un autre volume ou sans Layout.ini. L'aveu de WindowsXPStrategy.swift:59-62 est exact, et la lacune est réelle.


### `boot-13` — confirmé

**Affirmation.** Sous NT, jusqu'à XP inclus, la date de dernier accès est mise à jour à chaque lecture. C'est actif par défaut (désactivable par NtfsDisableLastAccessUpdate).

- App : `Sources/Model/BootSession.swift:275-296 ; README.md:835-837`
- XP : `base/fs/ntfs/ntfsinit.c:79, 554-567 ; base/fs/ntfs/read.c:2366-2380 ; base/fs/ntfs/create.c:5953-5960 ; base/fs/ntfs/filobsup.c:250-253, 318-323 ; base/fs/ntfs/cleanup.c:2282-2319`
- Extrait : « //  If we didn't find the value or the value is zero then don't update last access times. (commentaire trompeur : le code ne désactive que si la valeur vaut 1) »

**Constat.** NTFS ne coupe la mise à jour que si la valeur NtfsDisableLastAccessUpdate existe et vaut 1. Absente, elle laisse la mise à jour active. Une lecture réussie pose FO_FILE_FAST_IO_READ, une ouverture avec FILE_EXECUTE aussi (images, pilotes). Au nettoyage du handle, cela devient FCB_INFO_UPDATE_LAST_ACCESS. Les fichiers système NTFS sont exclus de la mise à jour des doublons.

**Effet.** —

**Contre-vérification.** L'actif par défaut est prouvé : le flag n'est posé que si la valeur existe et vaut 1 (ntfsinit.c:566-567). Le commentaire de la ligne 562 est bien trompeur. Une nuance au « toute lecture » de l'app : il faut une lecture non paginée réussie (read.c:2366, `if (!PagingIo)`) ou une ouverture FILE_EXECUTE. Un fichier de données seulement mappé, ou lu par pagination (préchargement compris), ne marque pas sa date. Pour les images et pilotes d'un démarrage, cela revient au même.


### `boot-14` — confirmé

**Affirmation.** NTFS ne réécrit la date que si elle a changé d'au moins une heure. FAT ne note que le jour. D'où des dates réécrites au premier démarrage de la journée, et jamais à un redémarrage rapproché.

- App : `Sources/Model/BootSession.swift:282-288`
- XP : `base/fs/ntfs/ntfsdata.h:368 ; base/fs/ntfs/ntfsinit.c:169 ; base/fs/ntfs/ntfsproc.h:5598-5601 ; base/fs/fastfat/dirsup.c:2549-2570`
- Extrait : « #define LAST_ACCESS_INCREMENT_MINUTES (60) »

**Constat.** NtfsLastAccess vaut 60 minutes, et NtfsCheckLastAccess n'écrit que si l'écart dépasse cette valeur. Sur FAT (fastfat de XP), la date n'est réécrite que si le jour local a changé, et seulement pour une lecture en cache (FO_FILE_FAST_IO_READ). Pour VFAT de Windows 95/98, le code XP n'est qu'un indice : non vérifiable ici.

**Effet.** —

**Contre-vérification.** Vérifié : LAST_ACCESS_INCREMENT_MINUTES vaut 60, et NtfsCheckLastAccess exige un écart supérieur à 1 h. Sur fastfat, la date n'est réécrite que si le jour local change, à condition que ChicagoMode soit actif et que le fichier ait été lu (FO_FILE_FAST_IO_READ, posé par une lecture non paginée, pas seulement « en cache ») ou écrit. Pour VFAT 9x : non vérifiable, comme le dit le vérificateur.


### `boot-15` — contredit

**Affirmation.** La date d'accès salit seulement la page de 4 Ko de MFT qui porte l'enregistrement. Le vidage la réécrit, et aucune page de journal ne l'accompagne (« NTFS ne journalise pas une simple date », hypothèse sans source).

- App : `Sources/Model/BootSession.swift:961-990`
- XP : `base/fs/ntfs/cleanup.c:2282-2319, 2331-2348 ; base/fs/ntfs/attrsup.c:1681, 1805-1815, 3398-3405, 8172-8400 (appel de NtfsUpdateFileNameInIndex vers 8400) ; base/fs/ntfs/ntfsstru.h:2587-2594 ; base/fs/ntfs/indexsup.c:611, 724-730, 820-826`
- Extrait : « #define FCB_INFO_DUPLICATE_FLAGS (... FCB_INFO_CHANGED_LAST_ACCESS | ...) / UpdateResidentValue, »

**Constat.** La mise à jour passe par NtfsUpdateStandardInformation, puis NtfsChangeAttributeValue, qui écrit un enregistrement UpdateResidentValue dans $LogFile. Ce n'est pas tout : FCB_INFO_CHANGED_LAST_ACCESS fait partie de FCB_INFO_DUPLICATE_FLAGS. Au nettoyage, NTFS met donc aussi à jour l'information dupliquée ($FILE_NAME) dans l'index du répertoire parent (NtfsUpdateDuplicateInfo, puis NtfsUpdateFileNameInIndex), là aussi journalisée (UpdateFileNameRoot/Allocation). Une date d'accès salit ainsi trois choses : la page MFT du fichier, la page d'index (INDX) ou l'enregistrement du répertoire parent, et le journal.

**Effet.** Sur gamer-2003 et les autres XP, le modèle sous-estime les écritures du premier démarrage de la journée. Aux pages MFT (384 écritures sur gamer-2003) s'ajoutent les pages d'index des répertoires parents, peu nombreuses car les fichiers d'un démarrage partagent quelques répertoires (system32, drivers), et des écritures séquentielles dans $LogFile, qui ramènent le bras vers le journal à chaque vidage. Cela fait plus de seeks d'écriture, et un aller-retour vers $LogFile audible.

**Contre-vérification.** Vérifié. Au nettoyage, NtfsCheckLastAccess pose FCB_STATE_UPDATE_STD_INFO et FCB_INFO_CHANGED_LAST_ACCESS (cleanup.c:2296-2299). NtfsUpdateStandardInformation passe ensuite par NtfsChangeAttributeValue, qui écrit un UpdateResidentValue dans le journal (attrsup.c:3398-3405). Et FCB_INFO_CHANGED_LAST_ACCESS appartient à FCB_INFO_DUPLICATE_FLAGS, d'où NtfsUpdateDuplicateInfo, puis NtfsUpdateFileNameInIndex, journalisé en UpdateFileNameAllocation ou UpdateFileNameRoot. L'hypothèse de BootSession.swift:977-979 (« NTFS ne journalise pas une simple date ») est contredite. Réserves : les fichiers système sont exclus (FCB_STATE_SYSTEM_FILE), et tout se fait à la fermeture du handle, pas à la lecture.


### `boot-16` — nuancé

**Affirmation.** Les métadonnées salies sont vidées toutes les secondes sous XP (InstallEra.flush = 1 s), groupées dans l'ordre du disque.

- App : `Sources/Model/BootSession.swift:193-196, 213-217, 970-1000 ; Sources/Model/InstallSession.swift:105`
- XP : `base/ntos/cache/cc.h:380, 387 ; base/ntos/cache/lazyrite.c:326-327 ; base/ntos/cache/cachedat.c:68`
- Extrait : « #define LAZY_WRITER_IDLE_DELAY ((LONG)(10000000)) / #define LAZY_WRITER_MAX_AGE_TARGET ((ULONG)(8)) »

**Constat.** L'écrivain paresseux du gestionnaire de cache se réveille toutes les secondes (LAZY_WRITER_IDLE_DELAY). Il vise cependant un âge de 8 passages (LAZY_WRITER_MAX_AGE_TARGET) : à chaque réveil, il n'écrit qu'environ un huitième des pages sales. Une page de MFT peut donc attendre plusieurs secondes, et le regroupement réel est plus large que celui d'une fenêtre d'une seconde.

**Effet.** Les écritures de dates seraient un peu moins nombreuses et plus groupées que dans le modèle (plus de pages voisines par vidage). L'effet sur le compte de 384 écritures est probablement modéré.

**Contre-vérification.** LAZY_WRITER_IDLE_DELAY vaut 1 s (cc.h:380, pas 381), et LAZY_WRITER_MAX_AGE_TARGET vaut 8 (cc.h:387). lazyrite.c:326-327 divise les pages à écrire par 8 quand il y en a plus de 8. Le vidage « toutes les secondes » d'InstallSession.swift:105 correspond au réveil, pas à l'âge des pages. Ajout : les pages de MFT portent un LSN, et le journal doit être posé avant elles (write-ahead). Cela renforce boot-15 : une écriture de $LogFile précède les pages de métadonnées.


### `boot-17` — confirmé

**Affirmation.** Défragmenter n'accélérait pas le démarrage : Windows a confié ce rôle à un rangement à part, layout.ini, qui passe par le préchargeur puis le défragmenteur.

- App : `README.md:811-814 ; Sources/Model/BootLayout.swift:4-13`
- XP : `admin/services/sched/service/daytona/pfsvc.h:102-113 ; pfsvc.c:5760, 5868, 6945-6947 ; base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:2873-2893`
- Extrait : « #define PFSVC_OPTIMAL_LAYOUT_FILE_DEFAULT_NAME L"Layout.ini" »

**Constat.** Le service de préchargement (pfsvc, dans le service des tâches planifiées) détermine la disposition optimale à partir des scénarios .pf et l'écrit dans Layout.ini (chemin sous la clé OptimalLayout\LayoutFilePath). Il lance ensuite defrag.exe -b, qui ne fait que ProcessBootOptimise. C'est bien le système qui fournit la liste au défragmenteur.

**Effet.** —

**Contre-vérification.** Vérifié : OptimalLayout\LayoutFilePath et Layout.ini (pfsvc.h:107-112), la commande « defrag.exe -b » (pfsvc.c:6946-6947), et la sortie après ProcessBootOptimise quand bCommandLineBootOptimizeFlag est posé.


### `boot-18` — nuancé

**Affirmation.** À l'étape « Bureau au repos », XP réécrit son fichier de préchargement (« Prefetch rewritten »), dans les 4 s de silence final.

- App : `Sources/Model/BootSession.swift:200-201, 402-403`
- XP : `base/ntos/cache/prefboot.c:350-386 (60 s après PfBootAcceptedRegistryInitPhase), 388-397 (30 s après PfUserShellReadyPhase) ; base/ntos/cache/prefparm.c:261 ; public/internal/base/inc/prefetch.h:122-123, 151`
- Extrait : « MaxWaitTime.QuadPart = -1i64 * 30 * 1000 * 1000 * 10; // 30 seconds. »

**Constat.** La trace de démarrage ne se ferme qu'à l'expiration d'une minuterie : 30 s après PfUserShellReadyPhase (le shell est prêt), ou 60 s après l'acceptation du démarrage si personne n'ouvre de session. Elle est de toute façon bornée à 10 périodes de 12 s. Le service traite ensuite la trace et écrit NTOSBOOT-B00DFAAD.pf. Cette écriture tombe donc au moins 30 s après le bureau, bien après les 4 s de queue du modèle.

**Effet.** L'écriture du .pf (et le traitement de trace qui la précède) devrait arriver une demi-minute après le bureau. Le modèle la place dans l'étape finale : c'est un décalage de temps, pas de nature.

**Contre-vérification.** Vérifié. La minuterie de 60 s est posée à la phase PfBootAcceptedRegistryInitPhase, celle de 30 s à PfUserShellReadyPhase, et la première échue ferme la trace. La borne est de 10 périodes de 12 s. Le nom NTOSBOOT et le hachage B00DFAAD sont en prefetch.h:122-123. Côté app, « Prefetch rewritten » n'est qu'un libellé (boot.settled.xp.detail) posé sur l'acte 7 générique : c'est un décalage de temps d'au moins 30 s, pas une erreur de nature.


### `boot-19` — non vérifiable

**Affirmation.** Vista a désactivé la mise à jour de la date d'accès par défaut, et Windows 7 l'a gardée désactivée.

- App : `Sources/Model/BootSession.swift:278-281, 294-296 ; README.md:836-838`
- XP : `base/fs/ntfs/ntfsinit.c:79`

**Constat.** Cela concerne Vista et Windows 7, que le code XP SP1 ne couvre pas. Le seul indice est que sous XP le réglage existe déjà (NtfsDisableLastAccessUpdate) et vaut « actif » par défaut.

**Contre-vérification.** Il s'agit de Vista et de Windows 7, hors du code XP SP1. Seul indice : sous XP, NtfsDisableLastAccessUpdate existe déjà et reste inactif par défaut (ntfsinit.c:79, 566).


### `boot-20` — non vérifiable

**Affirmation.** Vista (SuperFetch) et Windows 7 (ReadyBoot) relisent la trace des démarrages précédents dans l'ordre du disque, comme le préchargeur de XP.

- App : `Sources/Model/BootSession.swift:411, 431-439, 448`
- XP : `—`

**Constat.** Il s'agit de Vista et Windows 7. Le code XP n'est qu'un indice, et il va plutôt contre la comparaison : le préchargeur de XP lui-même ne trie pas par position (boot-01). L'ordre du disque y vient de l'ascenseur du pilote de port et de defrag -b.

**Effet.** « comme le préchargeur de XP » est à reformuler, quoi que fassent Vista et 7.

**Contre-vérification.** Il s'agit de Vista et de Windows 7. La comparaison « comme le préchargeur de XP » (BootSession.swift, commentaire avant l'ère win7-sp1) repose sur un XP qui trierait par position, ce que boot-01 contredit. Elle est à reformuler dans tous les cas.


### Lacunes — Démarrage : préchargeur, Layout.ini, optimisation du démarrage, dernier accès

- **Sous XP, le préchargement du démarrage se fait en quelques grandes rafales au début, par un fil de travail : pilotes système, puis tout le reste avant SMSS si la mémoire le permet, puis une part pendant l'initialisation vidéo. Il est limité par MmAvailablePages moins 512 pages moins 8 Mo, faute de quoi il est tronqué ou découpé par phase. Le démarrage attend chaque phase, puis travaille surtout en fautes douces.** — `base/ntos/cache/prefboot.c:531-538, 762-810, 855-965`. Le son d'un démarrage XP : une longue salve de lecture en tête, puis un calme relatif. Aujourd'hui le bruit est réparti acte par acte, avec le calcul entre deux. Sur les machines de 2003 (128 à 256 Mo), la troncature par la mémoire disponible est plausible. *Contre-vérification :* Vérifié dans prefboot.c:522-538 (ajustement de 512 pages + 8 Mo), 761-810 (une passe ou une par phase) et 855-955 (vérification de la mémoire avant SMSS, événements). L'app découpe par acte, avec le calcul entre deux (BootSession.swift, `acts(launching:)` et `emit`), et ne modélise ni rafale initiale ni troncature par la mémoire. La lacune est réelle.
- **Dans chaque phase, toutes les pages de données sont préchargées d'abord (avec la page d'en-tête des images), puis toutes les pages d'image. Ce sont deux lots d'E/S distincts, chacun servi par l'ascenseur du port IDE.** — `base/ntos/cache/prefboot.c:482, 870-930 ; base/ntos/cache/prefetch.c:4660-4668`. Deux balayages par phase au lieu d'un. C'est audible sur un volume dont les fichiers de démarrage sont étalés. *Contre-vérification :* prefboot.c:482-490 (curseurs DataCursor puis ImageCursor) et 870-929 (deux CcPfPrefetchSections par phase). Chacun finit par un MmPrefetchPages qui émet tout, puis attend (pfsup.c:318-388). L'app ne connaît pas cette distinction.
- **Les lectures en attente sont servies par l'ascenseur à sens unique du port IDE : KeRemoveByKeyDeviceQueue depuis CurrentKey, clé = LBA posée par classpnp. Cela vaut pour toute rafale d'E/S asynchrones sous NT, pas seulement pour le préchargeur.** — `drivers/storage/ide/atapi/internal.c:3877, 3959 ; drivers/storage/classpnp/xferpkt.c:406`. C'est le vrai mécanisme de l'ordre « par position » sous XP. Il touche aussi les vidages du cache et les écritures groupées (journal, dates d'accès) : l'ordre de service ne dépend pas de l'ordre d'émission dès que plusieurs requêtes sont en file. *Contre-vérification :* Vérifié : atapi/internal.c:3877-3878 et 3959, classpnp/xferpkt.c:399-406. L'app n'en tient pas compte, et l'écarte même explicitement : README.md:1507-1510 dit « Pas de réordonnancement des commandes… File FIFO : représentatif d'un contrôleur IDE de l'époque… les lectures, elles, partent dans l'ordre où on les demande ». Sous NT/XP, c'est faux côté hôte : un seul ordre en vol au disque, mais une file triée par LBA dans le pilote de port. DiskSimulator.swift ne connaît l'ascenseur que pour le cache d'écriture du disque. La lacune est confirmée et contredit une affirmation du README pour les ères NT.
- **Tâche d'inactivité du préchargeur : après 12 min d'inactivité, puis 5 vérifications de 30 s (processeur et disque inactifs à 90 %), pfsvc réécrit Layout.ini et lance defrag -b, au plus tous les 3 jours. La première fois, cela se fait dès qu'une trace de démarrage a été traitée.** — `admin/services/sched/idletask/server/idletsks.h:39-50, 76, 83 ; admin/services/sched/service/daytona/pfsvc.c:598-601, 5800-5850`. Le disque XP livré devrait déjà porter un bloc de démarrage groupé (comme le note LEDGER-REALISME). Une journée (DaySession) où la machine reste inactive devrait parfois faire entendre une passe -b. Aucune des deux n'est modélisée. *Contre-vérification :* Vérifié : idletsks.h:39-50, pfsvc.c:590-603 et 5770-5850. Aucune trace d'une passe -b ni d'une tâche à l'inactivité dans DaySession.swift. LEDGER-REALISME.md:127-131 note déjà que l'état livré ignore ce réglage.
- **Une défragmentation manuelle de XP sur le volume de démarrage commence par ProcessBootOptimise : lecture de Layout.ini, évacuation de la zone, déplacement des fichiers de 32 Mo au plus. Viennent ensuite la MFT et la passe ordinaire.** — `base/fs/utils/dfrg/dfrgntfs/dfrgntfs.cpp:2008-2013, 2851-2861`. WindowsXPStrategy n'a pas cette phase d'ouverture. Elle change le son du début de passe et laisse un bloc de démarrage contigu dans la disposition finale. *Contre-vérification :* dfrgntfs.cpp:2007-2013, 2856-2861, puis MFTDefrag en 2906. WindowsXPStrategy.swift:59-62 reconnaît ne pas le faire : aucune phase d'ouverture de ce genre dans la stratégie.
- **La zone d'optimisation se déplace au début du plus grand trou libre quand moins de 90 % des fichiers de Layout.ini y sont déjà. Elle grandit de 150 % du manque (100 Mo au moins, dans la limite de 4 Go et de 50 % du volume), et sa position est gardée dans le registre d'une passe à l'autre.** — `base/fs/utils/dfrg/dfrgntfs/bootoptimizentfs.cpp:68-72, 1818-1838, 2010-2035`. La place réelle du bloc de démarrage sous XP (souvent excentrée) fixe la longueur du seek d'accès au démarrage et la place des trous que laisse l'évacuation. *Contre-vérification :* bootoptimizentfs.cpp:67-72, 1817-1838 et 2006-2031. Le plancher de 100 Mo porte sur le manque avant ×1,5. L'app ne modélise pas XP ici, et SmartDefragStrategy pose le bloc en tête, choix du projet (avec en plus une contradiction README / SmartDefragStrategy sur devant ou derrière la MFT).
- **Une date d'accès NTFS met aussi à jour l'entrée $FILE_NAME dans l'index du répertoire parent, et journalise les deux changements dans $LogFile.** — `base/fs/ntfs/cleanup.c:2331-2348 ; base/fs/ntfs/indexsup.c:611-830 ; base/fs/ntfs/attrsup.c:3405`. Il manque des écritures au premier démarrage de la journée sur les disques XP : pages INDX de system32 et des autres répertoires, et journal séquentiel ailleurs sur le volume. *Contre-vérification :* cleanup.c:2331-2348, attrsup.c:3398-3405, indexsup.c:724-730 et 820-826. BootSession.swift:961-990 ne salit que la page MFT, et affirme dans son commentaire qu'aucune page de journal n'accompagne la date.
- **Layout.ini inclut les fichiers de tous les scénarios de lancement d'application (.pf, au plus 128 sur un poste), chacun avec ses répertoires d'abord. Les fichiers du chargeur (noyau, HAL, ruches SYSTEM et SOFTWARE, pilotes de démarrage) passent en tête.** — `admin/services/sched/service/daytona/pfsvc.c:6149-6180, 13619-13700 ; pfsvc.h:95-97`. La zone optimisée de XP couvre aussi les applications fréquentes : le lancement d'application d'une journée en profite, pas seulement le démarrage. *Contre-vérification :* pfsvc.c:6149-6180, 6318-6362, 13619-13622 ; pfsvc.h:89-97 (128 est le plafond de .pf dans le répertoire Prefetch, en build non DBG). BootLayout.swift:21-23 ne prend que le readOrder du démarrage planifié, avec la seule application lancée. De plus, cet ordre est l'ordre du disque et non celui de premier accès (voir boot-09).

## Gestionnaire de cache et pile de stockage


### `io-cache-01` — nuancé

**Affirmation.** Sous XP, le cache (le lazy writer) vide les métadonnées salies toutes les secondes, et les vide entièrement à chaque passage.

- App : `Sources/Model/InstallSession.swift:105 (flush: .every(seconds: 1)) ; Sources/Model/MachineWriter.swift:170-201 (flushMetadata vide tout `dirty`) ; BootSession.swift:193-195`
- XP : `base/ntos/cache/cc.h:381 ; base/ntos/cache/cachedat.c:65 ; base/ntos/cache/lazyrite.c:85-99,325-327,415-420,447-453 ; base/ntos/cache/cachesub.c:3994-3998 ; base/fs/ntfs/fsctrl.c:2251`
- Extrait : « #define LAZY_WRITER_IDLE_DELAY ((LONG)(10000000)) / CcFirstDelay = {(ULONG)-(3*LAZY_WRITER_IDLE_DELAY), -1} / PagesToWrite /= LAZY_WRITER_MAX_AGE_TARGET; »

**Constat.** La période d'une seconde est exacte : LAZY_WRITER_IDLE_DELAY vaut 10 000 000 × 100 ns, et le balayage est réarmé à ce délai. Trois écarts toutefois. (1) Quand le lazy writer sort du repos, son premier passage n'a lieu qu'après 3 s (CcFirstDelay), pour « laisser l'application finir d'enregistrer ». (2) Chaque passage ne vise qu'un huitième du total des pages sales (LAZY_WRITER_MAX_AGE_TARGET = 8), plus un rattrapage si la cible CcDirtyPageTarget serait dépassée. Ce budget global borne les données utilisateur, via Mbcb->PagesToWrite. (3) Les flux de métadonnées épinglés (MFT, $Bitmap) reçoivent en revanche PagesToWrite = DirtyPages, donc tout. Un flux MODIFIED_WRITE_DISABLED qui porte au moins 256 Ko de pages sales n'en écrit qu'un huitième, et un tel flux n'est visité qu'un passage sur seize s'il en porte moins. Le modèle est donc juste pour les tables de la MFT, mais il ignore le délai de 3 s au départ et l'étalement des données sur environ 8 s.

**Effet.** Faible sur les tables. La première salve de métadonnées d'une installation part environ 2 s trop tôt. Les données, elles, ne sont pas du tout différées dans le modèle (voir gaps).

**Contre-vérification.** J'ai tout relu. LAZY_WRITER_IDLE_DELAY vaut 10 000 000 (cc.h:381), CcFirstDelay 3 × ce délai (cachedat.c:65). Ce délai de 3 s s'applique à la sortie du repos (lazyrite.c:85-99, avec le commentaire « let the app finish saving its file » ; aussi vacbsup.c:3191). Le passage divise par LAZY_WRITER_MAX_AGE_TARGET (lazyrite.c:325-327) et Mbcb->PagesToWrite est borné par CcPagesYetToWrite (cachesub.c:3994-3998). J'ajoute une précision qui renforce le verdict. La MFT n'est pas MODIFIED_WRITE_DISABLED en régime normal : NTFS la remonte par CcSetAdditionalCacheAttributes(Mft, TRUE, FALSE), qui rétablit l'écriture différée (fsctrl.c:2251). Elle est donc bien vidée entière à chaque passage. Le « un huitième, un passage sur seize » (lazyrite.c:415-420 et 447-453) ne vaut que pour les flux dont l'écriture différée est coupée : $LogFile (fsctrl.c:1728), $Boot, et les flux ouverts pendant un redémarrage (restrsup.c:4604). Côté app, les références sont justes : InstallSession.swift:105, MachineWriter.swift:173-201 et BootSession.swift:193-195.


### `io-cache-02` — nuancé

**Affirmation.** Le pilote de port de Windows XP découpait les requêtes à 64 Ko, d'où writeRequestSectors = 128 pour XP.

- App : `Sources/Model/InstallSession.swift:60-66 et :107`
- XP : `drivers/storage/ide/inc/idep.h:31 ; drivers/storage/ide/atapi/init.c:198-209 ; drivers/storage/classpnp/xferpkt.c:60,74 ; drivers/storage/ide/pciidex/bm.c:741 ; base/ntos/cache/cc.h:159,175 ; base/ntos/inc/mm.h:93`
- Extrait : « #define MAX_TRANSFER_SIZE_PER_SRB (0x100 * 0x200) // 128k ATA limits / #define MAX_WRITE_BEHIND (MM_MAXIMUM_DISK_IO_SIZE) »

**Constat.** La valeur de 64 Ko est juste pour les E/S qui passent par le cache, mais elle ne vient pas du pilote de port. atapi annonce 128 Ko par SRB (MAX_TRANSFER_SIZE_PER_SRB = 0x100 × 0x200, « 128k ATA limits »), et classpnp découpe à HwMaxXferLen = min(MaximumTransferLength, pages physiques), soit 128 Ko sur IDE. cc.h le dit lui-même : « some drivers, such as AT, break up transfers >= 128kb ». Les 64 Ko viennent d'en haut : MAX_WRITE_BEHIND = MM_MAXIMUM_DISK_IO_SIZE = 0x10000, qui borne chaque écriture du lazy writer, et BASE_COPY_FILE_CHUNK = 64 Ko pour CopyFile.

**Effet.** Aucun sur le son tant que les écritures passent par le cache. Seules des E/S non cachées, ou une application qui écrirait par blocs de 128 Ko en non caché, pourraient envoyer 128 Ko au disque en une commande. Il faut corriger l'attribution dans la docstring et dans DISK_EXPERT_REVIEW.

**Contre-vérification.** J'ai relu idep.h:31 (MAX_TRANSFER_SIZE_PER_SRB = 0x100 × 0x200), init.c:198-204 et cc.h:159,175. Le « 64 Ko » ne vient pas du pilote de port, mais du cache et de Mm (MAX_WRITE_BEHIND = MM_MAXIMUM_DISK_IO_SIZE = 0x10000, mm.h:93) et de BASE_COPY_FILE_CHUNK. Je corrige un point. classpnp ne découpe pas à 128 Ko, mais à HwMaxXferLen = MIN(MaximumTransferLength, (MaximumPhysicalPages − 1) pages) (xferpkt.c:60 et 74). atapi annonce MaximumPhysicalPages = BYTES_TO_PAGES(128 Ko) = 32 (init.c:209), donc hwMaxPages vaut 31 et HwMaxXferLen 124 Ko. De même, pciidex borne MaxTransferByteSize à (registres de carte − 1) × 4 Ko (bm.c:741). Une E/S non cachée de 128 Ko part donc en 124 Ko + 4 Ko, du moins avec le nombre de registres de carte que rend une HAL ordinaire. Côté app, la docstring d'InstallSession.swift:61-64 est bien fausse sur l'attribution au pilote de port.


### `io-cache-03` — nuancé

**Affirmation.** Une commande tient au plus 256 secteurs sans LBA48, soit 64 Ko sous XP ; le LBA48 des disques de 2007 lève ce plafond.

- App : `README.md:1454-1459 ; Sources/Model/InstallSession.swift:61-67`
- XP : `drivers/storage/ide/inc/idep.h:31 ; drivers/storage/ide/atapi/init.c:198-204 ; drivers/storage/ide/atapi/sources:84 ; drivers/storage/classpnp/xferpkt.c:60,74`
- Extrait : « if (sectorCount > 0x100) { / C_DEFINES=$(C_DEFINES) -DENABLE_48BIT_LBA »

**Constat.** Le plafond ATA sans LBA48 est bien de 0x100 secteurs : atapi vérifie sectorCount > 0x100 sur ce chemin. Mais XP SP1 compile atapi avec ENABLE_48BIT_LBA, et même en LBA48 il garde MAX_TRANSFER_SIZE_PER_SRB = 128 Ko : le LBA48 ne lève pas le plafond côté système. Sous XP, le « 64 Ko » est une limite du cache et de Mm, pas de l'ATA. Ce que faisait Vista reste non vérifiable ici : XP n'en est qu'un indice, et il penche vers un plafond logiciel maintenu.

**Effet.** Aucun pour XP. Pour Vista, les 256 secteurs posés restent une hypothèse.

**Contre-vérification.** Le fond tient : ENABLE_48BIT_LBA est activé (sources:84) et le plafond par SRB reste à 128 Ko (idep.h:31). En revanche, la référence atapi.c:4639 est fausse. Elle tombe dans IdeVerify, la commande VERIFY, et non sur le chemin des lectures et écritures (IdeReadWrite/IdeReadWriteExt, vers atapi.c:3870) : « verify too many sectors ». Pour les lectures et écritures, le plafond de 256 secteurs n'est pas un test explicite : il vient de MaximumTransferLength = MAX_TRANSFER_SIZE_PER_SRB, qui est même réduit à 124 Ko par classpnp (voir io-cache-02). Côté app, README.md:1454-1459 et InstallSession.swift:61-67 sont exacts.


### `io-cache-04` — nuancé

**Affirmation.** Les lectures (démarrage, relectures des installations) sont découpées en requêtes de 128 secteurs au plus, parce que les pilotes découpaient en tampons de quelques dizaines de Ko.

- App : `Sources/Model/BootSession.swift:582-586 ; Sources/Model/MachineWriter.swift:21-22,88-90`
- XP : `base/ntos/inc/mm.h:62,1135-1140 ; base/ntos/mm/mminit.c:194-196,1482-1512 ; base/ntos/mm/pagfault.c:2811,2826-2870`
- Extrait : « #define MM_MAXIMUM_READ_CLUSTER_SIZE (15) / MmDataClusterSize = 3; MmCodeClusterSize = 7; »

**Constat.** Pour une lecture cachée, 64 Ko par E/S est exact. La faute de page d'une vue du cache regroupe au plus MM_MAXIMUM_READ_CLUSTER_SIZE + 1 = 16 pages, et Cc règle ReadClusterSize par MmSetPageFaultReadAhead, plafonné à 15. Pour les images en revanche (EXE, DLL, pilotes chargés par Mm), le regroupement est plus fin sur une machine de plus de 19 Mo : MmCodeClusterSize = 7, soit 8 pages (32 Ko), et MmDataClusterSize = 3, soit 4 pages (16 Ko). Sur une machine plus petite, c'est 2 et 1 pages de plus que la page fautive.

**Effet.** Une DLL lue par fautes de page produirait deux à quatre fois plus de requêtes que le modèle n'en émet, donc un crépitement plus dense. Le préchargeur de XP, qui lit par blocs, atténue cet écart au démarrage : c'est l'autre domaine.

**Contre-vérification.** J'ai vérifié MmSetPageFaultReadAhead, plafonné à MM_MAXIMUM_READ_CLUSTER_SIZE = 15 (mm.h:62 et 1135-1140), puis les réglages de mminit.c. Au-delà de MM_MEDIUM_SYSTEM = 19 Mo (mminit.c:196), MmDataClusterSize vaut 3 et MmCodeClusterSize 7 (mminit.c:1511-1512). Dans pagfault.c, ReadSize part d'une page (la page fautive) et la boucle en ajoute au plus ClusterSize (lignes 2811, 2852-2870). On obtient donc bien 8 pages pour le code et 4 pour les données. Sous 13 Mo, c'est 0 et 1 page de plus ; entre 13 et 19 Mo, 1 et 2. L'écart reste soumis à deux conditions : la mémoire disponible (AvailablePages > MmFreeGoal×2, ou > 31 pour une image) et la frontière de table de pages. Côté app, BootSession.swift:582-586 et MachineWriter.swift:21-22,88-90 sont justes.


### `io-cache-05` — nuancé

**Affirmation.** Derrière le cache de Windows, on lit au moins une page de 4 Ko et pas davantage : lire les 2 Ko d'un .ini coûte 4 Ko, et on ne lit que les octets demandés, arrondis à la page.

- App : `Sources/Model/BootSession.swift:262-273 ; Sources/Model/InstallSession.swift:78-80`
- XP : `base/ntos/cache/copysup.c:562-566 ; base/ntos/cache/cachesub.c:1338,1432-1468 ; base/fs/ntfs/ntfsdata.h:374 ; base/fs/fastfat/fatdata.h:97`
- Extrait : « if (GotAMiss && !FlagOn(FileObject->Flags, FO_RANDOM_ACCESS) && !PrivateCacheMap->Flags.ReadAheadEnabled) / #define READ_AHEAD_GRANULARITY (0x10000) »

**Constat.** La page est bien l'unité. Mais sous XP, le premier CcCopyRead qui fait défaut active la lecture anticipée du fichier (GotAMiss, puis PRIVATE_CACHE_MAP_READ_AHEAD_ENABLED et CcScheduleReadAhead). Une lecture à l'offset 0 passe le test « troisième lecture séquentielle ». NTFS et FAT règlent la granularité à 64 Ko (READ_AHEAD_GRANULARITY 0x10000) : le cache lit donc d'avance jusqu'à la frontière de 64 Ko suivante, bornée par la fin du fichier. La partie « Windows 95 » n'est pas vérifiable ici.

**Effet.** Un fichier de 4 à 64 Ko dont on ne lit que le début serait lu en entier, en une E/S asynchrone de plus. Plus d'octets lus, mais moins de retours ultérieurs sur ce fichier. Cela touche les plafonds bytesPerFile du démarrage et les relectures partielles.

**Contre-vérification.** J'ai relu copysup.c:562-566 (GotAMiss, lecture anticipée activée puis CcScheduleReadAhead), les deux READ_AHEAD_GRANULARITY à 0x10000, et les appels CcSetReadAheadGranularity (ntfs/read.c:1978, fastfat/read.c:1321). Je corrige un détail. Pour une première lecture courte à l'offset 0, cachesub.c:1459-1468 fixe l'offset de lecture anticipée à ROUND_TO_PAGES(Length), et sa longueur à ReadAheadSize = Length arrondi à 64 Ko (cachesub.c:1338). On lit donc 64 Ko à partir de la page qui suit la lecture, et non « jusqu'à la frontière de 64 Ko suivante ». La lecture est ensuite bornée par la fin du fichier. La conclusion ne change pas : un fichier de 4 à 68 Ko est lu en entier.


### `io-cache-06` — contredit

**Affirmation.** NTFS ne prend pas ses clusters à chaque écriture du programme : le lazy writer vide le cache par paquets de 64 Ko et étend l'allocation du fichier à chaque vidage, si bien qu'un fichier de taille inconnue grandit de 64 Ko en 64 Ko.

- App : `Sources/DiskCore/FileSystemProfile.swift:190-201 ; README.md:636-643`
- XP : `base/fs/ntfs/write.c:1914,2064-2163 ; base/fs/ntfs/allocsup.c:1315-1400`
- Extrait : « DesiredClusterCount = Int64ShllMod32( ClusterCount, CcbForWriteExtend->WriteExtendCount ); / if (CcbForWriteExtend->WriteExtendCount < 4) »

**Constat.** Chez NTFS, l'allocation se fait dans NtfsCommonWrite, au moment où l'écriture de l'application dépasse AllocationSize (NtfsAddAllocation, AskForMore = TRUE), et non quand le lazy writer vide le cache. Le montant suit une heuristique géométrique propre au handle : à la n-ième extension, la demande est multipliée par 2^n et arrondie à 2^n clusters, avec n plafonné à 4, donc ×16. Tout est borné par FreeClusters/1024. Le surplus est rendu à la fermeture (SCB_STATE_TRUNCATE_ON_CLOSE). Le lazy writer écrit bien par morceaux d'au plus 64 Ko, mais il n'alloue rien.

**Effet.** Un programme qui écrit par 4 Ko sur des clusters de 4 Ko obtient des extensions de 4, 8, 16, 32 puis 64 Ko : le régime permanent retombe sur les 64 Ko du modèle. Mais le paquet dépend de la taille d'écriture du programme : des écritures de 64 Ko donnent des extensions de 1 Mo, et de petits clusters en donnent de plus petites. La traîne des fichiers en 2 à 16 morceaux sur NTFS est donc sensible à ce mécanisme, que le modèle attribue au mauvais composant.

**Contre-vérification.** Confirmé, et le code est plus explicite encore que le vérificateur ne le dit. Le bloc d'allocation de NtfsCommonWrite est gardé par `if (DoingIoAtEof && !FlagOn(IrpContext->State, IRP_CONTEXT_STATE_LAZY_WRITE))` (write.c:1914) : le lazy writer est exclu par construction. Il appelle ensuite NtfsAddAllocation(…, AskForMore = TRUE, Ccb) (write.c:2064-2150). Dans allocsup.c:1315-1360, la première extension (WriteExtendCount = 0) prend exactement ce qui est demandé. Les suivantes décalent de n et arrondissent à 2^n clusters, avec n plafonné à 4. Deux corrections. La borne est FreeClusters/1024 + ClusterCount (allocsup.c:1395), et non FreeClusters/1024 seul. Et le surplus n'est rendu qu'à la fermeture, par SCB_STATE_TRUNCATE_ON_CLOSE (write.c:~2160). La docstring de FileSystemProfile.swift:190-201 et README.md:636-643 attribuent donc le mécanisme au mauvais composant.


### `io-cache-07` — confirmé

**Affirmation.** Écriture anticipée : la page de journal part avant les tables qu'elle décrit, et le lazy writer remplit une page de journal de plusieurs validations avant de l'écrire.

- App : `Sources/Model/VolumeLayout.swift:14-21 ; Sources/Model/MachineWriter.swift:188-196`
- XP : `base/fs/ntfs/fsctrl.c:1809,1813 ; base/fs/ntfs/cachesup.c:322 ; base/ntos/cache/cachesub.c:3619,3696 ; base/fs/ntfs/logsup.c:2944-2957`
- Extrait : « (*SharedCacheMap->FlushToLsnRoutine) ( SharedCacheMap->LogHandle, / if (FlagOn( IrpContext->TopLevelIrpContext->State, IRP_CONTEXT_STATE_WRITE_THROUGH ) ... »

**Constat.** NTFS enregistre LfsFlushToLsn comme routine de vidage auprès de Cc pour la MFT. Avant d'écrire une page de métadonnées, Cc appelle FlushToLsnRoutine jusqu'au LSN de la page. La validation d'une transaction ne force pas le journal, sauf en écriture immédiate (« we do not really have to do write-through - flushing the updates to the log is enough »). Plusieurs validations s'accumulent donc dans la page de journal jusqu'à l'écriture des métadonnées ou jusqu'au point de contrôle. Une nuance : c'est LFS qui groupe, et le lazy writer n'en est que le déclencheur.

**Effet.** Aucun : le mécanisme sonore (rafales espacées vers $LogFile) est fondé.

**Contre-vérification.** Prouvé par le code. CcSetLogHandleForFile(…, &LfsFlushToLsn) est posé pour la MFT et son miroir (fsctrl.c:1809,1813), et pour tous les flux internes de métadonnées (cachesup.c:322). Cc retient le plus grand NewestLsn des Bcb qu'il va écrire, puis appelle FlushToLsnRoutine avant l'écriture (cachesub.c:3619-3622 et 3696). La validation ne force le journal qu'en écriture immédiate (logsup.c:2944-2957). Le groupement est bien fait par LFS, et le lazy writer en est le déclencheur.


### `io-cache-08` — nuancé

**Affirmation.** Le cache écrit les tables salies dans l'ordre du disque, en fusionnant ce qui se touche.

- App : `Sources/Model/MachineWriter.swift:175-185`
- XP : `base/ntos/cache/cachesub.c:3211,3479-3481 ; base/ntos/cache/lazyrite.c:405-460,728-742 ; base/ntos/cache/fssup.c:145-168`
- Extrait : « while (((*MaskPtr & Mask) != 0) && (*Length < (MAX_WRITE_BEHIND / PAGE_SIZE)) && / (*Length + Bcb->ByteLength > MAX_WRITE_BEHIND) || »

**Constat.** Cc écrit flux par flux (un SharedCacheMap après l'autre, dans l'ordre de la liste du lazy writer). Dans un flux, il suit l'ordre des offsets et prend des plages contiguës de pages ou de Bcb sales d'au plus MAX_WRITE_BEHIND (64 Ko). Il n'existe pas de tri global par LBA entre la MFT, $Bitmap, les index de répertoire et le journal. Et ces écritures sont synchrones (MmFlushSection), si bien que l'ascenseur d'atapi n'a rien à réordonner entre deux flux.

**Effet.** Faible à modéré : un vidage réel peut aller du journal à la MFT, puis à $Bitmap, puis revenir vers un répertoire. Le modèle fait un seul balayage croissant, donc des courses de bras un peu plus courtes et plus régulières que la réalité. Les plages de plus de 64 Ko seraient aussi coupées.

**Contre-vérification.** Le verdict tient : le vidage se fait flux par flux, dans l'ordre des offsets, par plages de 64 Ko au plus (cachesub.c:3211 et 3479-3481). J'y ajoute une réfutation. L'affirmation « ces écritures sont synchrones, si bien que l'ascenseur d'atapi n'a rien à réordonner entre deux flux » est fausse. Le lazy writer poste un élément de travail par SharedCacheMap, et ces éléments sont servis par CcNumberWorkerThreads threads : ExCriticalWorkerThreads − 1 ou − 2 (fssup.c:145-168), mis en file sur la CriticalWorkQueue (lazyrite.c:728-742). Plusieurs flux (MFT, $Bitmap, index) peuvent donc être vidés en même temps, et les requêtes en attente sont alors triées par LBA par atapi (voir io-cache-09). Le vrai ordre sur le disque est ainsi un mélange : séquentiel par flux, et en partie trié par l'ascenseur entre flux concurrents.


### `io-cache-09` — nuancé

**Affirmation.** Pas de réordonnancement des commandes ni de NCQ : une file FIFO, représentative d'un contrôleur IDE de l'époque.

- App : `README.md:1507-1510 ; Sources/Model/DiskSimulator.swift:295-298`
- XP : `drivers/storage/ide/atapi/init.c:206 ; drivers/storage/ide/atapi/chanfdo.c:1741 ; drivers/storage/classpnp/xferpkt.c:406 ; drivers/storage/ide/atapi/internal.c:3877,3959-3965,4698 ; base/ntos/ke/devquobj.c:320-333`
- Extrait : « Pkt->Srb.QueueSortKey = logicalBlockAddr; / packet = KeRemoveByKeyDeviceQueue(&LogicalUnit->DeviceObject->DeviceQueue, LogicalUnit->CurrentKey); »

**Constat.** L'absence de file matérielle est confirmée : atapi déclare TaggedQueuing = FALSE et CommandQueueing = FALSE, une commande à la fois par unité, et XP SP1 n'a pas de pilote AHCI. En revanche la file logicielle d'atapi n'est pas FIFO. Chaque SRB porte QueueSortKey = LBA, il est inséré par KeInsertByKeyDeviceQueue, et le suivant est retiré par KeRemoveByKeyDeviceQueue à partir de CurrentKey, la LBA de la commande précédente : c'est un ascenseur à sens unique (C-LOOK) sur les requêtes en attente.

**Effet.** Nul tant qu'une seule requête est en vol, comme dans le modèle, qui est sériel. Dès que plusieurs E/S sont en attente (lecture anticipée asynchrone de Cc, lazy writer pendant qu'un programme lit, plusieurs threads), XP les trie par LBA : moins de seeks et un crépitement moins dense que ce que la FIFO produirait.

**Contre-vérification.** Tout est vérifié. TaggedQueuing = FALSE (init.c:206) et CommandQueueing = FALSE (chanfdo.c:1741). Srb.QueueSortKey = logicalBlockAddr (xferpkt.c:406). atapi insère ses requêtes par KeInsertByKeyDeviceQueue (internal.c:4698, 4962, 5180 ; devpdo.c:2051) et les retire par KeRemoveByKeyDeviceQueue(CurrentKey) (internal.c:3877). KeRemoveByKeyDeviceQueue rend la première entrée ≥ SortKey, sinon la première de la file (devquobj.c:320-333). Il s'agit bien d'un C-LOOK. Détail : CurrentKey est ensuite incrémenté de 1 pour éviter la famine (internal.c:3959-3965). Côté app, README.md:1507-1510 et DiskSimulator.swift:295-298 sont justes.


### `io-cache-10` — nuancé

**Affirmation.** Le cache d'écriture du disque n'est jamais vidé par le système : ni FLUSH CACHE aux points de contrôle de NTFS, ni à la validation d'un déplacement.

- App : `README.md:1511-1516`
- XP : `base/fs/ntfs/verfysup.c:1480-1484 ; base/fs/ntfs/flush.c:596-611 ; drivers/storage/classpnp/xferpkt.c:435-441 ; base/ntos/config/cmworker.c:41,523-535 ; base/ntos/config/cmwrapr.c:1036-1048 ; base/ntos/config/hivesync.c:2419-2420 ; drivers/storage/disk/disk.c:3406-3411 ; drivers/storage/ide/atapi/atapi.c:5564`
- Extrait : « NewTimerValue = -5*1000*1000*10; / #define LAZY_FLUSH_INTERVAL_IN_SECONDS 5 / srb->Cdb[0] = SCSIOP_SYNCHRONIZE_CACHE; »

**Constat.** Pour NTFS, c'est vrai. Le point de contrôle (toutes les 5 s) n'envoie pas d'IRP_MJ_FLUSH_BUFFERS au périphérique : seul NtfsCommonFlushBuffers, c'est-à-dire un FlushFileBuffers, le transmet. Les écritures « write-through » (journal : SL_WRITE_THROUGH) reçoivent le bit FUA dans classpnp, mais atapi l'ignore et n'émet que WRITE DMA ou WRITE DMA EXT. Pourtant XP vide bien le cache du disque ailleurs. Le registre vide ses ruches paresseusement 5 s après une modification, et appelle ZwFlushBuffersFile pour les journaux .LOG et les ruches qui grandissent. Ce flush traverse NTFS, puis disk.sys, qui envoie SYNCHRONIZE_CACHE si le cache d'écriture est actif, puis atapi, qui en fait un FLUSH CACHE (0xE7 ou EXT). Même chose à l'arrêt.

**Effet.** Nul pour une passe de défragmentation, qui n'écrit pas le registre. Pendant les installations, les journées et les démarrages sous XP, chaque écriture de registre produit dans les 5 s un FLUSH CACHE. Le disque pose alors d'un coup ce qu'il a acquitté, et les longues salves du cache d'écriture sont bornées.

**Contre-vérification.** J'ai vérifié chaque maillon. Le point de contrôle n'est qu'un timer de 5 s ou 2 s (verfysup.c:1480-1484). NtfsCommonFlushBuffers fait suivre l'IRP au TargetDeviceObject (flush.c:199, 596-611). classpnp pose le bit FUA pour SL_WRITE_THROUGH (xferpkt.c:435-441), et aucun ForceUnitAccess ni FUA n'apparaît dans atapi. disk.sys envoie SYNCHRONIZE_CACHE si DEV_WRITE_CACHE est posé (disk.c:3406-3411), et atapi le traite (atapi.c:5564). Pour le registre, LAZY_FLUSH_INTERVAL_IN_SECONDS = 5 (cmworker.c:41, armé en 523-535). Une précision : la ruche principale, en vues mappées, est vidée par CcFlushCache, sans FLUSH CACHE (cmwrapr.c:1036-1040). ZwFlushBuffersFile ne sert qu'aux fichiers hors cache, dont les .LOG (cmwrapr.c:1045-1048), et à la ruche qui grandit (hivesync.c:2419-2420). Cela reste assez pour qu'une modification du registre aboutisse à un FLUSH CACHE.


### `io-cache-11` — confirmé

**Affirmation.** Le cache d'écriture du disque suit sa politique à la mise sous tension (colonne « cache d'écriture » de la fiche).

- App : `Sources/Model/DriveCache.swift:7-9 ; README.md:248-256 ; Sources/DiskCore/DriveCatalog.swift:351-597`
- XP : `drivers/storage/disk/pnp.c:1280-1340`
- Extrait : « // We enable write cache if this device has no specific issues / writeCacheOverride = DiskWriteCacheEnable; »

**Constat.** Sous XP, disk.sys lit l'état du cache au démarrage du périphérique. Sauf réglage de l'utilisateur ou disque amovible, il l'active s'il est coupé (DiskWriteCacheEnable). Tous les disques de la galerie de 1996 à 2012 ont déjà writeCache: true, et le seul qui l'a coupé (le Conner de 1993) tourne sous MS-DOS : XP ne change donc rien.

**Effet.** Aucun. À retenir si un profil XP recevait un disque dont le cache est coupé à la mise sous tension : XP l'allumerait.

**Contre-vérification.** J'ai relu pnp.c:1280-1340. Sans override, writeCacheOverride = DiskWriteCacheEnable ; il est coupé pour un périphérique ou un média amovible à chaud. Si le cache est coupé, il est allumé par DiskSetCacheInformation. Dans DriveCatalog.swift, seule la première fiche (ligne 351, le disque de 1993) a writeCache: false, et toutes les autres (368 à 674) ont true. La conclusion tient.


### `io-cache-12` — confirmé

**Affirmation.** Une copie (CopyFile) déclare la taille avant d'écrire (SetEndOfFile) et obtient sa place d'un coup.

- App : `Sources/DiskCore/EventTimeline.swift:15-26`
- XP : `base/win32/client/fileopcr.c:3355,4847-4870 ; base/win32/client/basedll.h:129`
- Extrait : « // Preallocate the size of this file/stream so that extends do not occur. / #define BASE_COPY_FILE_CHUNK (64*1024) »

**Constat.** BaseCopyStream préalloue le fichier cible par NtSetInformationFile(FileEndOfFileInformation) avant la boucle de copie (« Preallocate the size of this file/stream so that extends do not occur »). La copie se fait ensuite par morceaux de BASE_COPY_FILE_CHUNK = 64 Ko (60 Ko vers un fichier distant).

**Effet.** Aucun : c'est aussi ce qui justifie les écritures de 64 Ko des installations XP.

**Contre-vérification.** J'ai relu fileopcr.c:4856-4870 (NtSetInformationFile FileEndOfFileInformation, avec le commentaire « Preallocate … so that extends do not occur ») et basedll.h:129 (BASE_COPY_FILE_CHUNK 64 Ko, par défaut en fileopcr.c:3355). Les 60 Ko (CHUNK − 4096) ne s'appliquent qu'à un fichier distant (fileopcr.c:4847-4849 et 3466-3467), ce qui concorde. La préallocation est sautée seulement pour une reprise de copie redémarrable ou pour un fichier de taille nulle. La docstring d'EventTimeline.swift:19 dit bien « SetEndOfFile », ce qui équivaut à FileEndOfFileInformation.


### `io-cache-13` — confirmé

**Affirmation.** Bus de 2003 : Ultra DMA/100 (100 Mo/s), sur un contrôleur IDE.

- App : `Sources/Model/DriveCache.swift:96 et :126`
- XP : `drivers/storage/ide/inc/ideuser.h:93,101,119`
- Extrait : « #define UDMA100_SUPPORT (UDMA_MODE5 ) / #define MAX_XFER_MODE 17 »

**Constat.** Le mode le plus rapide que connaît la pile IDE de XP SP1 est UDMA_MODE5, soit UDMA100_SUPPORT ; il n'existe pas de mode 6 (MAX_XFER_MODE vaut 17 modes, de PIO0 à UDMA5). drivers/storage ne contient aucun pilote AHCI : un disque SATA sous XP passe par l'émulation IDE. Hors du code XP, un détail de la table : l'UDMA/100 relève d'ATA/ATAPI-6 et non d'ATA-5.

**Effet.** Aucun sur le son. Seule la source citée dans la table serait à corriger.

**Contre-vérification.** UDMA_MODE5 est le plus haut mode défini (ideuser.h:93), UDMA100_SUPPORT = UDMA_MODE5 (ideuser.h:101), MAX_XFER_MODE = 17 (ideuser.h:119). drivers/storage/ide ne contient que atapi, pciidex, miniport, inc et share : aucun pilote AHCI. Le verdict ne vaut que pour 2003, sous XP. La même ligne de la table de l'app (DriveCache.swift) couvre aussi 2007, sous Vista, que ce code ne peut pas confirmer.


### `io-cache-14` — non vérifiable

**Affirmation.** Caches de MS-DOS et Windows 9x : SMARTDRV (éléments de 8 Ko, 16 Ko lus d'avance, 1 Mo puis 512 Ko), VCACHE (un quart de la mémoire, 16 Mo au plus) et vidage des tables toutes les 3 s sous 95 et 98.

- App : `Sources/Model/SoftwareCache.swift:96-227 ; Sources/Model/InstallSession.swift:94-102`
- XP : `base/ntos/cache/fssup.c:145-178`
- Extrait : « CcDirtyPageThreshold = MmNumberOfPhysicalPages / 8; »

**Constat.** Ces affirmations portent sur MS-DOS 6.22 et Windows 9x, dont l'arborescence XP ne contient pas le code (VCACHE est un VxD de 9x). Le gestionnaire de cache de NT est un autre composant : période de 1 s, un huitième des pages sales, seuil de pages sales entre un huitième et trois huitièmes de la mémoire selon la taille du système. Il ne vaut pas indice pour VCACHE.

**Effet.** Aucun à tirer de XP.

**Contre-vérification.** Il s'agit de MS-DOS et de 9x, absents de l'arbre. Je corrige l'explication annexe : le seuil de CcDirtyPageThreshold n'est pas en pratique « un huitième à trois huitièmes de la mémoire ». Dès que le working set maximal du cache dépasse 4 Mo, il est remplacé par MaximumWorkingSetSize − 2 Mo (fssup.c:172-175), et CcDirtyPageTarget en vaut les trois quarts.


### Lacunes — Gestionnaire de cache et pile de stockage

- **Lecture anticipée du gestionnaire de cache. Dès la troisième lecture séquentielle d'un fichier (ou la première à l'offset 0 qui fait défaut), Cc programme de façon asynchrone, sur un thread de travail, la lecture de la tranche suivante alignée sur 64 Ko, de la taille de la dernière lecture arrondie à 64 Ko et plafonnée à 8 Mo (MAX_READ_AHEAD). Les lectures à pas constant sont aussi détectées (cas 2). Côté NT, l'app ne modélise que la lecture anticipée du disque.** — `base/ntos/cache/cachesub.c:1426-1520 ; base/ntos/cache/cc.h:169 ; base/ntos/cache/copysup.c:149`. Sous XP, le disque lit pendant que le programme calcule, alors que le modèle sérialise le temps de calcul (thinkTime) et les requêtes. Les durées de lecture séquentielle hors préchargeur (lancement d'application, compilation, journées) sont surestimées, et les silences entre deux requêtes d'un même fichier seraient comblés par des lectures de 64 Ko émises d'avance. *Contre-vérification :* Confirmé dans cachesub.c:1338-1520 (cas 1 séquentiel, cas 2 à pas constant), copysup.c:562-566, avec MAX_READ_AHEAD = 8 Mo (cc.h:169). L'app ne modélise que la lecture anticipée du disque (DiskSimulator.swift:103, 600-604) et celle de SMARTDRV (BootSession.swift:1177-1180). Aucune lecture anticipée asynchrone du système sous NT : le thinkTime est sérialisé avec les requêtes (DiskSimulator.swift:559-563). La lacune tient.
- **Écriture différée des données, et non des seules métadonnées. Un WriteFile caché ne fait que salir des pages. Le lazy writer les écrit au plus tôt 3 s après la sortie du repos, puis toutes les secondes, un huitième du total des pages sales par passage (plus un rattrapage), par plages d'au plus 64 Ko dans l'ordre des offsets du fichier. Au-delà de CcDirtyPageThreshold, CcCanIWrite bride l'écrivain. MachineWriter.write émet au contraire les données aussitôt, entre deux temps de calcul.** — `base/ntos/cache/lazyrite.c:94-99,325-363 ; base/ntos/cache/cachedat.c:65 ; base/ntos/cache/fssup.c:150-178`. Pendant une installation ou une copie sous XP, les données partiraient en pulsations d'une seconde, décalées de quelques secondes sur la lecture de la source, et non au fil de l'eau. C'est un rythme audible différent, et une superposition avec les vidages de tables que le modèle ne produit pas. *Contre-vérification :* MachineWriter.write (MachineWriter.swift:81-85) émet aussitôt ; seules les métadonnées passent par dirty/flushMetadata. Le code XP confirme CcFirstDelay, le huitième par passage et le budget par Mbcb. Une correction : le seuil de bridage CcDirtyPageThreshold est en général le working set maximal du cache moins 2 Mo (fssup.c:172-175), et non une fraction de la mémoire. S'y ajoute un point que la lacune ne dit pas : plusieurs threads de travail écrivent en parallèle (fssup.c:145-168).
- **Vidage paresseux du registre : 5 s après une modification, CmpLazyFlush écrit les ruches et leurs .LOG, puis appelle ZwFlushBuffersFile. Le flush descend jusqu'à un FLUSH CACHE ATA sur les disques dont le cache d'écriture est actif, c'est-à-dire tous sous XP.** — `base/ntos/config/cmworker.c:41,523-535 ; base/ntos/config/cmwrapr.c:1048 ; base/ntos/config/hivesync.c:2420 ; drivers/storage/disk/disk.c:3406-3411`. L'app réécrit le registre en bloc après chaque logiciel, sans vidage du disque. Sous XP, chaque modification du registre (installation, démarrage, services) produirait une écriture de ruche et de .LOG dans les 5 s, puis un vidage forcé du cache du disque. Les longues salves d'écriture sont coupées et des pauses de vidage s'entendent. *Contre-vérification :* Le délai de 5 s est confirmé (cmworker.c:41, 523-535). Nuance : la ruche principale mappée est vidée par CcFlushCache, sans FLUSH CACHE (cmwrapr.c:1036-1040). Le FLUSH CACHE vient des .LOG et des fichiers hors cache, par ZwFlushBuffersFile (cmwrapr.c:1045-1048), et de la ruche qui grandit (hivesync.c:2419-2420). L'app réécrit le registre en bloc sans aucun vidage du disque (README.md:886-887, 1511-1516), et aucune occurrence de FLUSH CACHE modélisé dans Sources/Model. La lacune tient.
- **Tri des requêtes en attente par LBA dans atapi (C-LOOK via KeRemoveByKeyDeviceQueue), dès que plusieurs IRP sont en vol : lecture anticipée asynchrone, lazy writer concurrent d'un programme, préchargeur qui émet ses lectures en rafale.** — `drivers/storage/ide/atapi/internal.c:3877,3959 ; drivers/storage/classpnp/xferpkt.c:406`. Si l'app modélisait un jour des E/S concurrentes (tourniquet de programmes, lazy writer asynchrone), la file devrait être triée par LBA sous XP et non FIFO. L'ordre des seeks, donc le timbre du crépitement, en dépend. *Contre-vérification :* Confirmé (internal.c:3877, 4698 ; devquobj.c:320-333). L'app est explicitement FIFO (DiskSimulator.swift:295-298, README.md:1507-1510). Je le renforce : même sans nouvelle modélisation, le lazy writer XP vide plusieurs flux en parallèle par ses threads de travail (lazyrite.c:728-742), ce qui produit déjà des E/S concurrentes.
- **Regroupement des fautes de page des images : 8 pages (32 Ko) pour le code et 4 pages (16 Ko) pour les données des EXE et DLL sur une machine de plus de 19 Mo. Le démarrage de l'app lit tous les fichiers par requêtes de 64 Ko.** — `base/ntos/mm/mminit.c:1511-1513 ; base/ntos/mm/pagfault.c:2839-2850`. Hors préchargeur, charger une DLL de 1 Mo produit de 32 à 64 E/S, et non 16. C'est pertinent pour les lancements d'application et tout ce que le préchargeur de XP n'a pas couvert. *Contre-vérification :* Confirmé : mminit.c:1511-1512 et pagfault.c:2811, 2852-2870, soit la page fautive plus ClusterSize pages. L'app lit tout par requêtes de 128 secteurs (BootSession.swift:586, MachineWriter.swift:22) et ne modélise aucune faute de page. La lacune tient, sous réserve du préchargeur de XP (autre domaine) et de la condition de mémoire disponible.

---

# Annexe — croisement avec l'audit des lots réalisme

Le 22 septembre 2026, un sous-agent a croisé ce fichier (A) avec l'audit en
lecture seule de `079b244..1cd42cc`, qui couvre les lots réalisme A à H.
Cet audit est versé dans le dépôt : **[`AUDIT_REALISME.md`](AUDIT_REALISME.md)**.
Ses 51 constats bruts, 43 après dédoublonnage, ont chacun été vérifiés par un
sceptique. Dans ce qui suit, **B** désigne le détail de ces constats, et
`B#n` le constat n° n de ce fichier. **C** désigne la synthèse placée en tête
du même fichier ; les sections citées (`C§1`…) sont ses défauts de
comportement numérotés. Tout est vérifié à `112a9a9`. Aucun fichier n'a été
modifié, et ni `swift test` ni aucun rendu n'a été lancé.

## 1. Les affirmations de C tiennent-elles à HEAD ?

Depuis `1cd42cc`, il n'y a que deux commits : `0668029` (allure d'écoute) et
`112a9a9` (ce fichier). Aucun ne touche NTFS, XP, la MFT, les JSON ni
`ProfileSpec`. Toutes les affirmations de C sur lesquelles repose ce
croisement sont vraies à HEAD, aux mêmes lignes.

| C | Vérifié à HEAD |
|---|---|
| 1. `sizeMB` de 2012 | `dev-2012.json:28` et `gamer-2012.json:25` valent `476940`. `ProfileSpec.swift:139` vaut `sizeMB * 1_000_000`. La doc à `:119` dit encore « Mio entiers ». |
| 2. Deux plages | `NTFSAllocator.swift:418` : la boucle `for range in dataRanges` fait `place` en entier, `scatter` compris (`:460`), sur la plage avant, avant de passer à la plage arrière. `preferredRun` et `scatter` sont bornés à la plage (`:474`, `:540-555`). À `:450`, le curseur système est ramené à `frontRange.upperBound`. |
| 3. `relocateMFTTail` | `DefragVolume.swift:214` : `let partition`. `:399-413` ne met à jour que `mftExtents` et `systemExtents`. `mftRecordLBA` lit `partition.mftExtents` (`VolumeLayout.swift:94, 210-226`), posé une seule fois à `GeneratedVolume.swift:125`. |
| 4. Avancement | `WindowsXPStrategy.swift:420/546/579` posent des plages fixes, rappelées dans les boucles `:192-215`. |
| 5. Analyse | `DefragStrategy.swift:145` parcourt `volume.systemExtents`, qui valent `[bootExtent] + mft.extents + [mftMirror, logFile, volumeBitmap]` (`NTFSAllocator.swift:361-363`). `scanAccesses` relit déjà `$Boot` et le dernier secteur (`VolumeLayout.swift:471-472`). |
| Mineur | `Scenario.swift:724` prend bien `hardware.year`. `DefragToolChoice.swift:106` affiche toujours « a few seconds to 45 min ». |

Seules les lignes du README ont bougé, de +1 à +13 : `:1082` devient
`:1083`, `:1335` devient `:1337`, `:1892` devient `:1905`, `:703` devient
`:704`.

## 2. Recoupements

### MFTDefrag et `relocateMFTTail`

- B#15 et B#9 (la partition reste périmée) se **complètent** avec A
  `xp-defrag-mft-condition`, `xp-defrag-mft-zone-cible` et `ntfs-alloc-18`
  (condition `>1` et non `>2`, un trou de la taille de la MFT **entière**,
  hors zone). Ce ne sont pas les mêmes défauts : B porte sur l'adressage
  après le déplacement, A sur le moment du déplacement et sur sa cible.
- A **aggrave** B. Avec la règle de XP, la queue repart à chaque passe, avant
  et après, dès que la MFT a deux extents, et elle part loin, hors zone. Si
  l'on applique A sans B#15, les écritures d'enregistrements visent
  l'ancienne queue sur presque toutes les passes XP, et plus loin
  qu'aujourd'hui.

### Commentaire de `DiskGenerator.swift:339`

B#10 = A `ntfs-format-06`, mot pour mot : le miroir « ramené par
Windows 2000 ». Les deux se **renforcent** : le commentaire est faux contre le
code de l'app comme contre celui de XP.

### Disposition NTFS : `$LogFile` et `$Bitmap`

B#10 (les commentaires de `VolumeLayout.swift:87-88, 314-315` sont faux)
recoupe A `ntfs-format-03` et `ntfs-format-04`. Les deux divergent sur le sens
de la correction (§3.1).

### Deux plages, `scatter`, curseur

- B#6 (`scatter` dans les 3 premiers Gio avant la plage arrière) et A
  `ntfs-alloc-01` et `ntfs-alloc-21` se **renforcent** sur le diagnostic.
  Chez XP, `NtfsLookupCachedLcnByLength` prend le plus petit run au moins
  aussi long que la demande, dans tout le cache hors zone. Il ne découpe
  (`AllowShorter`, du plus grand run au plus petit) que si **aucun** run ne
  suffit. Le cas de B#6 ne se produit donc pas sous XP.
- A ajoute que `scatter` lui-même est faux : il prend les morceaux dans
  l'ordre du volume, alors que XP les prend du plus grand au plus petit
  (`ntfs-alloc-21`).
- B#7 (curseur système ramené à 3 Gio) et A `ntfs-alloc-02` (pas de curseur
  pour un fichier neuf, *left-packing*) se **complètent**. Si l'on remplace
  les curseurs par la règle de XP, B#7 disparaît.

### Zone MFT renouvelée

B#8 et A `ntfs-format-10`, `ntfs-alloc-08` et `ntfs-alloc-10` se
**complètent**.

- B#8 : le renouvellement Vista/7 sort le milieu du volume de `dataRanges`
  (`NTFSAllocator.swift:374` et `:677`).
- A : XP renouvelle aussi sa zone, au montage, quand l'espace libre repasse
  au-dessus d'un seizième, et quand la MFT s'étend sans run contigu.

L'ordre de traitement est impératif (§4).

### Point de contrôle

B#9 et B#15 raisonnent avec la rétention de 5 s : les clusters sont
« libérés au point de contrôle et peuvent être réoccupés ». A
`xp-defrag-point-de-controle` et `ntfs-alloc-15` réfutent cette rétention pour
XP : `STATUS_DELETE_PENDING`, vidage du journal, réemploi immédiat. Le défaut
de B tient, et il devient même plus probable sous XP.

### Blocs de 64 Kio et commentaires sur l'ancien XP

- B#22 (`UltraDefragStrategy.swift:121` dit « 4 Mo », et la ligne 38
  « n'évacue personne ») est **renforcé** par A `xp-defrag-64k`,
  `xp-defrag-boucles` et `xp-defrag-consolidation-ordre`.
- `DefragPlannerTests:591` parle d'« une hypothèse ». A
  `xp-defrag-zone-mft-rognee` montre que c'est un fait de la source, avec en
  plus la zone de démarrage.
- `:829-831` (« pas de réorganisation à chaud ») est contredit par A
  `ntfs-alloc-18`.
- `:1030` (« XP suit les numéros d'enregistrement ») : selon A
  `xp-defrag-tri`, XP trie par taille, puis par numéro d'enregistrement.

### Arrêt au premier fichier sans trou

- B#21 et A `xp-defrag-arret-minimum` se **complètent**. A confirme le
  `break` pour l'ordre par taille, qui est celui de XP. B montre qu'il fausse
  les autres ordres, rejoués en mesure.
- A `xp-defrag-tri` ajoute que `.sizeThenRecord` départage par `id` et non
  par `mftRecord` (`WindowsXPStrategy.swift:617-621`). `.mftRecord` prend
  aussi `a.id`.

### Répertoires FAT

B#30 relève que le test ne vérifie plus que les répertoires restent en place.
A `xp-defrag-fat-repertoires` confirme la règle. A `xp-defrag-fat-moteur`
ajoute que « XP sur FAT » ne représente aucun outil réel, puisque dfrgfat est
un autre moteur. Le test porte donc sur un cas hors modèle.

### Site et fiche de l'outil XP

B#18, B#27 et B#49 (le site décrit l'ancien XP) sont **renforcés** par A
`xp-defrag-boucles` et `xp-defrag-64k` : le nouveau libellé « 64 KB copies…
packing » est le bon.

### famille-2003

B#37 relève que le README annonce 24 % alors que `CalibrationTests` attend
moins de 16 %. A `ntfs-alloc-01` cite la même fourchette (4,6 à 21,2 %) et
conteste les bornes qui la décident.

Un lien est probable, mais n'a pas été vérifié : B#6 et la phrase « 24 % »
arrivent dans le **même commit** (lot F, `c7cda33`, « deux plages de données,
le vierge borné à la sienne »), et le scénario de B#6 est justement
famille-2003.

## 3. Contradictions tranchées

1. **Le sens de la correction de B#10.** B veut aligner le commentaire de
   `VolumeLayout.swift:314-315` (« derrière les 64 Mo du journal ») sur le
   code, qui pose le journal derrière le miroir (`NTFSAllocator.swift:331`,
   `logFile = Extent(start: mirror.end, …)`). Or A (`format.cxx:618`,
   `logfile.cxx:231-232`) montre que, sous XP, le journal finit deux clusters
   **avant** `$MFT`.
   Verdict : ce commentaire est **juste pour XP**, et faux quand il dit
   « près du début » (c'est à 3 Gio). Il faut corriger le **code** d'après A,
   puis le commentaire, et non réécrire le commentaire dans le sens du modèle
   actuel.
2. **La référence de B#6.** B juge `place` d'après la règle de l'en-tête, qui
   préfère l'espace vierge (`NTFSAllocator.swift:70-75`). A `ntfs-alloc-03`
   réfute cette règle pour XP. Le défaut tient des deux côtés, mais la
   correction ne doit pas « essayer le vierge arrière avant `scatter` ». Elle
   doit faire un *best fit* global sur les deux plages hors zone, puis
   découper du plus grand morceau au plus petit.
3. **B#24 : « l'analyse ne devrait lire que la MFT ».** C'est trop étroit.
   Le code de XP, relu, montre ce que dfrgntfs lit :
   - l'attribut `$BITMAP` de la MFT, par `DasdReadClusters`
     (`dfrgntfs.cpp:4588-4613`) ; sous XP, ce bitmap est un cluster devant
     `$MFT` (A `ntfs-format-03`) ;
   - la MFT, par tampons `MFT_BUFFER_SIZE`, extent par extent
     (`:5110-5160`) ;
   - la bitmap du volume, par `FSCTL_GET_VOLUME_BITMAP`
     (`freespace.cpp:1345`), à chaque phase (A `xp-defrag-liste-par-phase`).

   Rien ne lit `$LogFile` ni `$MFTMirr`. Verdict : B a raison pour les
   64 Mio du journal, pour le miroir et pour `$Boot` relu. Lire `$Bitmap`
   est légitime, même si son passage par le cache n'est pas tranché.
4. **Monotonie de l'avancement (B#16).** B s'appuie sur le LEDGER, et XP lui
   donne raison : `dfrgntfs.cpp:981-985`, `if (uPercentDone <
   uLastPercentDone) uPercentDone = uLastPercentDone`. La barre de XP ne
   recule jamais. Correction : borner la valeur de la même façon.
5. **A `ntfs-format-17` et `VolumeLayout.swift:442`.** Pas de conflit avec B.
   B#24 relève le `$Boot` relu, sans voir que `scanAccesses` lit aussi le
   dernier secteur (`:472`). C'est le même aller-retour sur toute la course
   que A réfute au montage. Il ne figure pas non plus dans la lecture de la
   MFT par dfrgntfs. Il est donc à retirer lui aussi.

En dehors du sens des corrections (points 1 et 2), il n'y a aucun cas où A
tient pour juste ce que B déclare faux sur le même mécanisme.

## 4. Interactions et ordre de traitement

- **B#15 avant la correction de MFTDefrag.** A multiplie les recollages :
  condition `>1`, deux appels par passe, cible hors zone, donc loin. Il faut
  d'abord que `mftRecordLBA` suive `DefragVolume.mftExtents`, soit en passant
  `partition` en `var`, soit en transmettant les extents au `commit`.
- **Le recollage d'A suppose le point de contrôle réglé.** `relocateMFTTail`
  retient la queue dans `heldClusters`. Si l'on remplace la rétention par
  `DELETE_PENDING` (A), sa libération change aussi.
- **B#8 avant le renouvellement de zone pour XP.** Étendre à XP le
  renouvellement prouvé par A, avec la définition actuelle de `dataRanges`,
  ferait perdre le milieu du volume aux **volumes XP de la galerie**
  (famille-2003 et secretaire-2003, qui se remplissent). `dataRanges` doit
  exclure la zone courante, pas tout ce qui la précède.
- **L'allocateur avant MFTDefrag.** A `ntfs-format-10` et `ntfs-alloc-09`
  changent le nombre d'extents de la MFT : il y en a moins, et ils sont plus
  gros. Cela décide quels volumes déclenchent MFTDefrag et combien de lectures
  fait l'analyse (B#24).
- **La disposition avant B#24 et avant les commentaires.** Déplacer
  `$LogFile` près de `$MFT` et `$Bitmap` à n/2 se fait dans le seul
  `NTFSAllocator.layout`, que `VolumeLayout.ntfsLayout` réutilise. Tant que
  B#24 n'est pas corrigé, l'analyse lirait toujours les 64 Mio du journal,
  simplement plus près.
- **B#5 (capacité 2012) et la disposition.** Les deux déplacent le miroir et
  changent le nombre de clusters des volumes 2012. Pour Windows 7, A ne
  vérifie rien : le miroir au LCN 2 est non vérifiable. Un seul lot de
  rendus suffit, mais il n'y a pas de dépendance logique.
- **Les documents en dernier.** B#19 et B#26 (durées « measured »), B#20 et
  B#38 à B#44 (prose du README), B#18, B#27 et B#49 (site) seront à refaire
  après chaque correction d'A qui change les passes XP. Il faut d'abord
  corriger les **gabarits** de `readme-tables.py` (verbes et comparatifs
  calculés), puis régénérer.

Ordre proposé :

1. Les corrections sans dépendance :
   - B#16 : borner l'avancement comme XP ;
   - B#15 : faire suivre la MFT déplacée aux lectures ;
   - B#5 : la capacité 2012, dans un lot de rendus à part ;
   - B#25 : dater l'outil par la chronologie du scénario.
2. La disposition au formatage (A `ntfs-format-03`, `04`, `02`, `12`, `17`),
   avec B#24.
3. L'allocateur : B#8 d'abord, puis B#6, B#7, et A `ntfs-alloc-01`, `02`,
   `03`, `05`, `09`, `21`, `ntfs-format-10`. Recaler ensuite
   `CalibrationTests` et le README (B#37).
4. Le moteur XP, avec B#17 et B#21 :
   - MFTDefrag : sa condition et sa cible ;
   - le point de contrôle et `DELETE_PENDING` ;
   - la validation par bloc de 64 Kio ;
   - la valeur rendue par la consolidation ;
   - le vidage de la zone MFT, arrêté au premier échec ;
   - la zone de démarrage.
5. Remesurer, puis les documents :
   - B#19 et B#26 ;
   - les gabarits du README ;
   - le site ;
   - l'arborescence (B#46) ;
   - les commentaires : B#10 dans le sens d'A, B#22, et la liste
     « Commentaires faux » d'A.

## 5. Ce qui n'est que dans l'un (par effet sur le son)

**Seulement dans A**

1. `$LogFile` collé devant `$MFT`, `$Bitmap` à n/2. Les trajets de chaque
   validation sont inversés, sur les 12 volumes NTFS.
2. Point de contrôle : réemploi immédiat des clusters, avec un vidage de
   journal audible. Cela touche XP, JkDefrag et UltraDefrag.
3. Validation par bloc de 64 Kio, avec la MFT et `$Bitmap` écrits par le lazy
   writer, et non une fois par fichier (`ntfs-alloc-14`).
4. Le montage ne va pas au dernier secteur (`ntfs-format-17`) : le modèle
   ajoute une course complète à chaque démarrage.
5. Allocation :
   - un *best fit* sur le cache des runs libres ;
   - pas de curseur ;
   - pas de préférence pour l'espace vierge ;
   - une surallocation de ×2 à ×16 à l'écriture.
6. L'optimisation du démarrage ouvre la passe XP.
7. Pile de stockage : file triée par LBA dans `atapi`, lazy writer qui vide
   un huitième des pages sales, lecture anticipée.
8. Démarrage : ordre de premier accès (libellé), historique de 8 démarrages,
   date d'accès journalisée.
9. FAT : tranches de 256 Kio pour JkDefrag et UltraDefrag.

**Seulement dans B/C**

1. B#24 : 64 Mio de journal lus pendant l'analyse, soit environ 3 s de son en
   trop par passe NTFS.
2. B#5 : volumes 2012 plus petits de 4,6 %, donc une course utile plus
   courte.
3. B#25 : l'outil suit l'année du disque (`rendertrace` avec `DRIVE=`,
   mesures).
4. B#16 : avancement (interface seulement).
5. B#17 (compte « déjà en place »), B#23 (pluriels), B#37 (test probablement
   rouge, non lancé).
6. Pourboires, site et README : B#31 à B#36, B#45, et la prose de B#38 à
   B#44.
7. Outillage : `wav-md5.py` (B#51).

## Tableau

| priorité | sujet | A | B/C | action proposée |
|---|---|---|---|---|
| 1 | MFT déplacée, lectures à l'ancienne place | `ntfs-alloc-18` (les règles du pilote tiennent) | B#15/#9, C§3 | Faire suivre `DefragVolume.mftExtents` à `mftRecordLBA`, **avant** toute correction de MFTDefrag |
| 1 | Place de `$LogFile` et `$Bitmap` | `ntfs-format-03`, `04`, `ntfs-alloc-19` | B#10 (commentaires) | Corriger `NTFSAllocator.layout` (journal devant la MFT, bitmap derrière le miroir), puis les commentaires dans le sens de XP |
| 1 | Analyse NTFS | — (code XP relu : `dfrgntfs.cpp:4588-4613, 5110-5160`, `freespace.cpp:1345`) | B#24, C§5 | Lire les extents de `$MFT` et son `$BITMAP`, garder la bitmap du volume ; retirer journal, miroir, `$Boot` relu et dernier secteur |
| 1 | Point de contrôle de 5 s | `xp-defrag-point-de-controle`, `ntfs-alloc-15` | (hypothèse sous-jacente de B#9/#15) | `DELETE_PENDING` avec vidage du journal ; revoir `relocateMFTTail` et `heldClusters` |
| 2 | Zone MFT renouvelée | `ntfs-format-10`, `ntfs-alloc-08`, `ntfs-alloc-10` | B#8 | Corriger `dataRanges` (**d'abord**), puis étendre le renouvellement à XP |
| 2 | Deux plages, `scatter`, curseurs | `ntfs-alloc-01`, `02`, `03`, `21`, `ntfs-format-18` | B#6, B#7, C§2 | *Best fit* global hors zone, découpage du plus grand au plus petit, pas de curseur ; remplace les deux correctifs de B |
| 2 | MFTDefrag : condition et cible | `xp-defrag-mft-condition`, `mft-zone-cible` | — | `count > 1`, trou de la MFT entière, hors zone ; après la ligne 1 et l'allocateur |
| 2 | famille-2003 : 24 % contre < 16 % | `ntfs-alloc-01` (bornes contestées) | B#37 | Lancer `swift test` ; recaler le test et le README après l'allocateur (probablement causé par B#6, lot F) |
| 2 | Capacité 2012 | — | B#5, B#12, C§1 | `sizeMB: 500107` dans les deux JSON, doc de `DiskSpec(reference:)` ; lot de rendus à part |
| 3 | Validation par fichier | `ntfs-alloc-14`, `xp-defrag-validation` | — | Commit par bloc de 64 Kio, métadonnées au lazy writer |
| 3 | Dernier secteur à chaque montage | `ntfs-format-17` | — | Retirer de `mountAccesses` (et de `scanAccesses`) |
| 3 | Avancement XP qui recule | — (XP le borne : `dfrgntfs.cpp:981-985`) | B#16, C§4 | Borner la valeur comme XP |
| 3 | Consolidation, zone MFT, zone de démarrage | `xp-defrag-abandon-dix`, `zone-mft-une-fois`, `zone-mft-rognee`, `mft-avant-apres` | B#17, B#21 | Aligner la valeur rendue et l'arrêt au premier échec ; compter « déjà en place » comme les autres outils ; limiter le `break` à l'ordre par taille |
| 3 | Départage par `id` | `xp-defrag-tri` | B#22 (test :1030) | Départager par `mftRecord` |
| 3 | Outil daté par le disque | `xp-defrag-vista7` (non vérifiable) | B#25 | Dater par `timeline.start.year` |
| 4 | Commentaires sur l'ancien XP et la disposition | liste « Commentaires faux » d'A | B#10, #22, #48 | Après les corrections, dans le sens d'A |
| 4 | Durées affichées, prose du README, site | — | B#18-#20, #26, #27, #38-#44, #46, #49 | Corriger les gabarits de `readme-tables.py`, remesurer, puis les textes |
| 4 | XP sur FAT dans les mesures | `xp-defrag-fat-moteur`, `fat-bloc` | B#30 | Marquer les 12 passes comme artefact ; test comparant les extents des répertoires avant et après |

Le lien entre B#6 et les 24 % de famille-2003 reste une hypothèse : il n'a pas
été mesuré.
