# Revue critique de la simulation de système de fichiers

Relecture du noyau de simulation **FAT16 / VFAT / FAT32 / NTFS** de DiskNoise,
du point de vue de quelqu'un qui a passé ces systèmes au `DEBUG`, au
`FSCTL_GET_RETRIEVAL_POINTERS` et au `dd` entre 1993 et 2007.

**Périmètre.** Tout ce qui décide de l'état d'un volume et de la traduction
fichier → clusters → LBA :

| Ce qui est relu | |
|---|---|
| `Sources/DiskCore/FileSystemProfile.swift` | formats, clusters, résidence |
| `Sources/DiskCore/Allocator.swift` | protocole, `place`/`grow`/`shrink` |
| `Sources/DiskCore/Allocators/FATAllocator.swift` | FAT16 / VFAT / FAT32 |
| `Sources/DiskCore/Allocators/NTFSAllocator.swift` | NTFS, MFT, zone MFT |
| `Sources/DiskCore/ClusterBitmap.swift` | table d'occupation et recherches |
| `Sources/DiskCore/{Extent,FileCatalog,SizeModel,WritePattern}.swift` | catalogue et motifs |
| `Sources/DiskCore/{EventTimeline,ScenarioCompiler,Simulator}.swift` | histoire et rejeu |
| `Sources/DiskCore/{ProfileSpec,ProfileIssues,DiskGenerator}.swift` | descriptions embarquées |
| `Sources/Model/VolumeLayout.swift` | plan de partition, coût des métadonnées |
| `Sources/Model/BootSession.swift` (chemin de lecture) | montage, ouverture, données |
| `Sources/DiskCore/Resources/scenarios/*.json` | les vingt volumes livrés |

**Hors périmètre, à la demande :** la défragmentation (stratégies JkDefrag,
UltraDefrag, Windows 95/XP, `FrontierCompaction`, `FragmentMerge`, la passe
`defragment()` du `Simulator` et tout `Sources/Model/*Strategy.swift`).

**Mesures.** Les chiffres cités ont été obtenus en générant les scénarios
embarqués avec le code de la branche `develop` (sonde temporaire sur
`DiskGenerator.generate`, supprimée depuis).

---

## 1. Ce qui est juste, et rare

Il faut le dire avant le reste, parce que c'est la partie difficile et qu'elle
est réussie : **le modèle a la bonne forme**. Trois choix en particulier sont
ceux qu'on ferait.

**La séparation format / pilote.** `FileSystemProfile` porte la géométrie
logique (taille de cluster, plafond d'adressage, résidence), `Allocator` porte
la politique de placement. C'est exactement la bonne ligne de coupe : le même
FAT16 en clusters de 32 Ko servi par le pilote MS-DOS ou par VFAT donne deux
volumes qui n'ont rien à voir, et c'est le pilote qui change. Les trois
`FATAllocator.Scan` — `fromVolumeStart` pour MS-DOS, `fromLastAllocated` pour
VFAT puis FAT32 — sont la bonne abstraction, et le `wrapCount` qui compte les
retours au début du volume est exactement l'observable qui explique la
fragmentation « par vagues » de FAT32. Peu de simulateurs vont jusque-là.

**Le plafond de 65 524 clusters comme cause, pas comme conséquence.**
`FAT16Profile.forVolume` recalcule la taille de cluster que `FORMAT` aurait
choisie, au lieu de la poser en paramètre. C'est le bon sens de la causalité :
les 32 Ko de 1996 ne sont pas une décision de l'époque, ce sont les 65 524
entrées d'une table sur 16 bits. Et le slack qui en découle est mesuré, pas
décrété : **12,3 % du volume sur `dev-1996`**, ce qui est du bon ordre.

**L'ordre des opérations dans `replaceViaTemporary`.** Écrire le temporaire
*pendant* que l'original occupe encore ses clusters, et ne libérer qu'ensuite,
c'est la seule façon d'obtenir le comportement réel de Word 6 à 97 : le document
ne retombe jamais à sa place et laisse un trou de son ancienne taille. Cet ordre
est faux dans la plupart des modèles qu'on croise, il est juste ici, et le
commentaire dit pourquoi.

À porter au crédit également : la coalescence au fil de l'eau qui **ne trie
pas** les extents (`Array<Extent>.coalesced()`) — l'ordre logique du fichier est
préservé, donc le comptage de fragments et le temps de lecture séquentielle
restent justes ; le `sortByDay` par comptage stable ; et `AllocationMetrics`
qui distingue les fichiers *fragmentables* (plus d'un cluster) des autres. Ce
dernier point est subtil et presque toujours raté : sur un FAT16 en clusters de
32 Ko, la majorité des fichiers d'un volume ne pourra jamais être fragmentée, et
un taux rapporté à l'ensemble mesure d'abord la démographie du volume.

---

## 2. Le problème central : tout fichier naît d'un seul tenant

C'est le point qui domine tous les autres, et il explique à lui seul les deux
cibles manquées que `CalibrationTests.swift` documente honnêtement en bas de
fichier.

### Ce que le modèle produit

Histogramme du nombre d'extents par fichier, volumes générés tels quels :

| | 1 extent | 2 | 3–4 | 5–16 | 17–64 | > 64 |
|---|---|---|---|---|---|---|
| `dev-2003` (NTFS, 40 Go, 95 % plein, 3 ans) | **13 047** | 1 | 2 | 7 | 5 | 25 |
| `dev-1996` (FAT16 32 Ko, 1 Go, 95 % plein, 18 mois) | **5 381** | 62 | 32 | 34 | 16 | 8 |

Autrement dit : **99,7 % des fichiers de `dev-2003` sont parfaitement contigus**
après trois ans d'usage sur un volume rempli à 95 %, et une trentaine de
fichiers sont en morceaux — jusqu'à 1 781 extents. La distribution n'est pas
« un peu trop propre », elle est **bimodale et vide au milieu**. Sur un vrai
volume XP de développeur à 95 %, la distribution est continue : une longue traîne
de fichiers en 2, 3, 7, 20 morceaux. C'est cette traîne qui manque, et c'est elle
qui fait le bruit d'un disque fatigué — un fichier en trois morceaux, c'est deux
seeks courts par lecture, et il y en a des milliers.

### Pourquoi

La note de `CalibrationTests` attribue l'écart à la démographie du volume
(« 3 000 fichiers viennent de l'installation, écrits d'affilée sur un disque
vierge »). C'est vrai mais second : même le reste du volume ne fragmente pas.
La cause est dans `Allocator.place(file:)` :

```swift
file.extents = allocate(clusterCount: profile.clusters(forBytes: file.logicalSize),
                        hint: file.hint)
```

**Chaque fichier est alloué en un seul appel, à sa taille finale, et l'allocateur
sert le meilleur trou pour ce total.** Tant que le volume possède un trou de la
bonne taille, le fichier est en un extent. Un fichier ne peut donc être
fragmenté que si *l'espace libre* l'était déjà — la fragmentation ne peut pas
naître de l'écriture elle-même.

Or c'est l'inverse qui s'est passé sur ces disques. Les deux mécanismes réels,
tous deux absents :

1. **L'allocation incrémentale.** Un programme qui écrit un fichier sans
   déclarer sa taille finale — un téléchargement, une capture, un journal, un
   `.obj` sorti d'un compilateur, une archive en cours d'extraction — fait
   grandir le fichier par paquets. FAT alloue alors **cluster par cluster** au
   fil de la chaîne ; NTFS alloue par rafales de ce que le gestionnaire de cache
   lui vide (quelques dizaines à quelques centaines de kilo-octets). C'est
   précisément la différence, bien connue à l'époque, entre un fichier copié par
   `CopyFile` — qui appelle `SetEndOfFile` et obtient donc une allocation d'un
   bloc, quasi contiguë — et le même fichier téléchargé, qui finit en centaines
   de fragments. Le modèle traite **toutes** les écritures comme si la taille
   avait été déclarée.

2. **L'entrelacement.** Deux écritures simultanées se disputent le même curseur
   d'allocation. Sur VFAT, le fichier d'échange qui gonfle pendant que Word écrit
   son temporaire pendant que le cache du navigateur se remplit donnait des
   chaînes littéralement alternées, cluster par cluster. Ici la timeline est une
   suite d'événements atomiques : à la granularité de la journée, tout est
   séquentiel, jamais concurrent. `PatternWriter` place les sollicitations sur
   des jours, `Simulator` les applique une par une jusqu'au bout.

Ces deux absences se conjuguent, et c'est pour cela que la traîne manque. Le
diagnostic actuel — « il faudrait bien plus de remplacements de fichiers
système » — conduirait à gonfler `maintenance.filesPerUpdate` jusqu'à obtenir le
chiffre voulu, c'est-à-dire à régler le résultat par l'entrée. Le modèle mérite
mieux, d'autant que le principe affiché est justement l'inverse.

### Ce que je ferais

Ajouter au `WritePattern` (ou au `FileSpec`) **un seul attribut booléen** :
la taille est-elle connue à l'avance ? Puis, dans `Allocator.place`, router :

- taille déclarée (copie depuis un CD, installation, `CopyFile`) → le
  comportement actuel, un seul appel ;
- taille inconnue (`.obj`, cache, téléchargement, `.pak` extrait, capture
  vidéo) → une boucle d'`extend` par paquets, la taille du paquet étant une
  propriété du **format** : 1 cluster pour FAT, `min(64 Ko, reste)` pour NTFS.

Sur FAT, cela suffit déjà à tout changer, parce que le curseur `nextFreeHint`
est partagé : deux fichiers dont les paquets s'intercalent dans la même journée
s'entrelacent d'eux-mêmes. Et pour obtenir l'entrelacement franc, il suffit que
`Simulator` traite les créations d'une même journée **en round-robin sur les
paquets** plutôt que fichier par fichier — sans aucun tirage supplémentaire, donc
sans perte de déterminisme.

Aucun taux de fragmentation n'entre dans cette description : on dit « ce
programme ne savait pas quelle taille son fichier ferait », ce qui est un fait
d'époque vérifiable, et la traîne tombe toute seule. C'est la modification qui a,
de loin, le meilleur rapport fidélité / lignes de code de cette liste.

---

## 3. Les constantes qui décident, en réalité, de la fragmentation

Le projet affiche partout — README, en-têtes, un test dédié — que la
fragmentation n'est jamais un paramètre. C'est vrai des vingt descriptions
JSON. Ce n'est pas vrai de `NTFSAllocator`, qui porte quatre constantes
introduites pour le coût de calcul et qui **poussent toutes vers la
contiguïté** :

```swift
private let reuseTolerance: UInt32 = 2          // ligne 67
private let growthMarginClusters: UInt32 = 16   // ligne 72
private let searchWindow = 64                   // ligne 79
private let searchHorizon: UInt32 = 1 << 16     // ligne 89
```

- `reuseTolerance = 2` : un trou plus grand que le double du besoin est
  **refusé**, l'allocateur préfère l'espace vierge. C'est le contraire du
  best-fit qu'annonce la documentation de la classe, et c'est un anti-fragmenteur
  direct : les grands trous ne sont jamais coupés tant qu'il reste du vierge, et
  quand le vierge est épuisé les fichiers vont dans des trous à leur mesure.
- `growthMarginClusters = 16` : on cherche 64 Ko de marge derrière chaque
  fichier neuf pour que ses extensions futures tombent à sa suite. NTFS ne fait
  pas cela.
- `searchWindow` / `searchHorizon` bornent la recherche ; l'argument de fidélité
  donné dans les commentaires (« un vrai NTFS travaille sur un cache partiel de
  sa table d'occupation ») est bon, mais l'effet net va aussi dans le sens de la
  propreté : renoncer à chercher, c'est aller chercher du vierge.

Ces quatre valeurs sont défendables une par une. Ensemble, elles constituent le
réglage de fragmentation que le projet dit ne pas avoir. Deux choses à faire, et
elles sont cheap :

1. le **dire** dans l'en-tête de `NTFSAllocator`, au même endroit où les trois
   mécanismes sont annoncés — c'est la seule entorse au principe de tout le
   noyau, elle mérite son paragraphe ;
2. les **mesurer** : un test qui génère `famille-2003` avec `reuseTolerance` à
   2, 4 et `.max` et imprime les trois taux dirait en trois lignes quelle part du
   résultat vient de là. Aujourd'hui personne ne le sait.

---

## 4. Ce qui manque structurellement

### 4.1 Les répertoires n'existent pas

`DirectoryRecord` porte un nom, un parent, un rang — et **aucun cluster**. Un
répertoire ne consomme rien, ne se fragmente pas, ne s'écrit jamais. Or :

- Sur FAT, un sous-répertoire **est un fichier**, alloué comme les autres, qui
  grandit d'un cluster dès que ses entrées de 32 octets débordent. Sur un volume
  en clusters de 32 Ko, un répertoire de 400 fichiers fait déjà deux clusters —
  et il les a obtenus à deux moments très éloignés, donc il est fragmenté, et
  *chaque* parcours de ce répertoire paie un seek. Les répertoires fragmentés
  étaient une plaie reconnaissable des volumes Win95 : c'est ce qui rendait
  `dir` lent bien plus que la lecture des fichiers.
- VFAT, en plus, consomme **une entrée de 32 octets par tranche de 13
  caractères** du nom long, plus l'entrée 8.3 d'alias. `Mes documents\Rapport
  trimestriel 1996.doc` coûte quatre entrées, pas une. C'est la raison pour
  laquelle les répertoires de Win95 grossissaient trois fois plus vite que ceux
  de DOS, à population égale.
- Sur NTFS, un répertoire est un enregistrement MFT avec un `$INDEX_ROOT`
  résident tant qu'il est petit, puis un `$INDEX_ALLOCATION` **qui alloue des
  clusters** en B-tree dès qu'il dépasse quelques kilo-octets.

Le champ `FileSystemProfile.directoryEntryBytes` existe et vaut bien 32 pour FAT
et 1 024 pour NTFS — mais **il n'est lu que par `NTFSAllocator.noteFileCreated`**
pour dimensionner la MFT. Les 32 octets de FAT ne servent à rien.

Conséquence mesurée : `dev-2003` compte **30 répertoires** pour 13 951 fichiers.
Un XP avec Visual Studio .NET et Office XP en compte plusieurs milliers. Ce n'est
pas qu'un défaut de réalisme cosmétique : les répertoires sont, sur FAT, une
population de fichiers petits, réécrits sans arrêt et donc fragmentés — c'est-à-dire
exactement la population qui manque à l'histogramme du § 2, et exactement celle
qui produit les seeks courts et répétés qu'on entend.

La modélisation est peu coûteuse et se branche au bon endroit : donner à
`DirectoryRecord` un `FileEntry`, et faire de `FileCatalog.makeDirectory` /
`insert` des événements d'allocation. Elle supprime au passage la seule
approximation que `VolumeLayout.openAccesses` reconnaît (« faute de savoir où
l'allocateur a posé ses clusters »), puisqu'on le saurait.

### 4.2 Les métafichiers NTFS s'arrêtent à trois

`NTFSAllocator.systemExtents` rend `$Boot` (1 cluster), `$MFT` et `$MFTMirr`
(4 clusters). Il manque, par ordre d'importance sur un volume de l'époque :

| Métafichier | Taille réelle sur 250 Go / clusters 4 Ko | Effet |
|---|---|---|
| `$LogFile` | de l'ordre de 64 Mo, **fixe et immobile** | bloc en tête de volume ; **chaque** validation de métadonnées y écrit |
| `$Bitmap` | `clusterCount / 8` = ~7,6 Mo | écrit à chaque allocation |
| `$Secure`, `$UsnJrnl` | quelques Mo à quelques dizaines de Mo | `$UsnJrnl` est réécrit en continu sous Vista |
| `$AttrDef`, `$Volume`, `$BadClus`, `$Extend` | quelques clusters | négligeable en place, pas en nombre |
| copie du secteur d'amorçage | 1 secteur **en fin de volume** | un accès isolé au fond du disque au montage |

Les tailles comptent peu (80 Mo sur 250 Go). Ce qui compte, c'est que
`$LogFile` est un **point de passage obligé et fixe** : sur NTFS, valider une
opération de métadonnées écrit dans le journal, pas seulement dans
l'enregistrement MFT. `VolumeLayout.commitAccesses` ne modélise que
`$MFT` + `$Bitmap`, et l'en-tête de `VolumeFormat` en tire la conclusion que
« le bras n'a aucune raison de revenir au bord ». C'est trop favorable à NTFS :
il y revient, simplement le *lazy writer* regroupe et diffère ces écritures, ce
qui change leur **rythme** (rafales espacées) et non leur existence. Une passe
NTFS n'est pas silencieuse côté métadonnées, elle est *groupée* — et c'est une
signature sonore différente, plus intéressante que l'absence.

Un troisième `MetadataAccess` dans `commitAccesses`, à LBA fixe, groupé un coup
sur N, rendrait ce comportement pour trois lignes.

### 4.3 Pas d'horodatage d'accès

Sous Windows NT jusqu'à XP inclus, **toute lecture de fichier met à jour
`LastAccessTime` dans son enregistrement MFT**. Un démarrage qui touche 2 000
fichiers produit donc 2 000 écritures de métadonnées, différées et regroupées par
le *lazy writer*. C'est une des raisons majeures du bruit d'un démarrage XP, et
c'est précisément ce que Vista a désactivé par défaut
(`NtfsDisableLastAccessUpdate`) — un écart d'époque audible, gratuit à
modéliser, et qui distingue 2003 de 2007 mieux que n'importe quel réglage de
débit. Le modèle a bien un `query.writeBack` dans `BootSession`, mais il réécrit
*les données* au lieu des métadonnées : les accès tombent au même endroit que la
lecture, donc sans seek, donc sans le bruit caractéristique.

FAT a le même mécanisme depuis Win95 (champ de date de dernier accès dans
l'entrée de répertoire), avec le même effet sur le répertoire.

### 4.4 Divers, par ordre décroissant

- **Enregistrements MFT supplémentaires.** Un fichier dont la liste d'extents
  dépasse la place d'un enregistrement de 1 Ko obtient un `$ATTRIBUTE_LIST` et
  des enregistrements additionnels. Les 25 fichiers de `dev-2003` à plus de
  64 extents (jusqu'à 1 781 !) en consommeraient des dizaines chacun, et leur
  lecture paierait autant de sauts dans la MFT. `mftRecordCount` compte un
  enregistrement par fichier, point.
- **Liens physiques de WinSxS.** Le résumé de `dev-2007` dit « Vista, WinSxS » :
  or le magasin de composants de Vista est construit sur des **liens physiques
  NTFS**, donc des dizaines de milliers d'entrées de répertoire qui partagent les
  mêmes clusters. Le modèle les compterait comme autant de copies. Comme
  l'installation de Vista est la plus grosse population de fichiers de tous les
  scénarios, l'effet sur l'occupation n'est pas marginal.
- **Compression NTFS** (les `.cab` et répertoires compressés de 2003 : alloués
  par unités de 16 clusters, fragmentation quasi garantie), **fichiers creux**,
  **flux additionnels** : absents. Défendable pour un spike, à dire.
- **Plafond de 512 entrées de la racine FAT16** : `PartitionGeometry` le
  dimensionne correctement (32 secteurs), mais rien ne l'applique côté
  allocation. Un scénario qui poserait 600 fichiers à la racine passerait sans
  broncher là où `FORMAT`… enfin, là où DOS aurait refusé.
- **Secteurs réservés FAT32** : `PartitionGeometry.bootSectors = 1`, alors que
  FAT32 en réserve **32** (secteur d'amorçage, `FSINFO`, copie de secours en
  secteur 6). Décale tout le plan du volume de 15,5 Ko — inaudible, mais faux, et
  gratuit à corriger.
- **`FSINFO`** : FAT32 y persiste le compte de clusters libres et le hint
  `next-free`. Le modèle a bien le hint en mémoire (`nextFreeHint`), mais rien ne
  l'écrit — donc rien ne se réinitialise au démontage. Détail, sauf qu'il
  explique pourquoi un volume FAT32 redémarré ne reprenait pas toujours où il
  s'était arrêté.

---

## 5. Erreurs de fait

Vérifiables, chacune contre la table de `FORMAT` ou la documentation d'époque.

### 5.1 Les trois volumes de 1993 ont des clusters trop gros

| Scénario | Volume | JSON | `FORMAT` aurait donné | Vérifié par le code lui-même |
|---|---|---|---|---|
| `secretaire-1993` | 170 Mo | `clusterKB: 8` | **4 Ko** | `FAT16Profile.forVolume(170 Mo)` → 4 Ko |
| `dev-1993` | 210 Mo | `clusterKB: 8` | **4 Ko** | → 4 Ko |
| `gamer-1993` | 210 Mo | `clusterKB: 8` | **4 Ko** | → 4 Ko |
| `poweruser-1993` | 340 Mo | `clusterKB: 8` | 8 Ko ✓ | → 8 Ko |

La table de `FORMAT` pour FAT16 place la frontière 4 Ko / 8 Ko à 256 Mo
(128–256 Mo → 4 Ko, 256–512 Mo → 8 Ko). Les trois premiers scénarios
**contredisent la règle que le modèle implémente correctement par ailleurs** :
il suffit de retirer `clusterKB` du JSON pour que `forVolume` retombe sur la
bonne valeur. Conséquence : le slack de 1993 est surestimé d'un facteur deux, et
le nombre de clusters divisé par deux — ce qui change aussi la granularité de la
carte affichée.

### 5.2 `gamer-1999` : 8,2 Go en clusters de 4 Ko

`sizeMB: 8400` avec `clusterKB: 4`. La table FAT32 place la frontière à 8 Go :
au-delà, **8 Ko**. 8 400 Mo = 8,20 Gio, donc Windows aurait formaté en 8 Ko. Les
trois autres scénarios de 1999 (4 300 et 6 400 Mo) sont corrects.

À noter : contrairement à FAT16, `FAT32Profile` n'a **pas** de `forVolume` — la
taille de cluster est toujours imposée par le JSON, avec 4 Ko par défaut. Ajouter
la table FAT32 (< 8 Go → 4 Ko, < 16 Go → 8 Ko, < 32 Go → 16 Ko, au-delà → 32 Ko)
ôterait la possibilité de se tromper, exactement comme pour FAT16.

### 5.3 `$MFTMirr` : mauvaise taille, et « près du début » n'est pas près du début

```swift
case .nearStart: min(self.mftZone.upperBound, clusterCount - 4)
```

`mftZone.upperBound` vaut **12,5 % du volume** à la construction. Sur le 250 Go
de `dev-2007`, le miroir est donc posé à 31 Go du début — ni au milieu (NT 3.1 à
2000), ni près du début (XP et au-delà), et exactement sur le premier cluster où
les données ont le droit d'aller, qu'il coupe en deux. Pour « près du début », la
valeur est de l'ordre du cluster 16, juste derrière `$Boot`.

Par ailleurs `$MFTMirr` ne contient que **les quatre premiers enregistrements de
la MFT**, soit 4 Ko, soit **un** cluster à 4 Ko — pas quatre clusters comme
alloué ici. Et `$Boot` fait 8 Ko (2 clusters à 4 Ko), pas 1, avec une copie du
secteur d'amorçage au tout dernier secteur du volume.

### 5.4 La bascule du miroir est datée d'un an trop tard

```swift
spec.timeline.start.year >= 2001 ? .nearStart : .volumeMiddle
```

Le déplacement accompagne NTFS 3.0, c'est-à-dire **Windows 2000**, pas XP. Aucun
scénario embarqué ne démarre en 2000, donc l'effet est nul aujourd'hui — mais un
disque personnalisé daté de 2000 sera traité comme un NT 4.

### 5.5 `WIN386.SWP` n'était pas à la racine

`ScenarioCompiler.installSwapFile` le pose dans `catalog.rootDirectory`. Le
fichier d'échange de Windows 95/98 vivait par défaut dans le répertoire Windows
(`C:\WINDOWS\WIN386.SWP`) ; c'est `386SPART.PAR`, le fichier permanent de
Windows 3.1, qui était bien à la racine — et le modèle le place correctement.
Sans effet sur l'allocation (le répertoire ne coûte rien, cf. § 4.1), mais
visible dans les chemins affichés.

### 5.6 MS-DOS gardait quand même un hint

`FATAllocator.Scan.fromVolumeStart` est présenté comme le comportement MS-DOS :
scan complet depuis le premier cluster de données, à chaque allocation. En
réalité, depuis DOS 3, le DPB portait un pointeur « dernier cluster alloué » et
la recherche partait de là — mais ce pointeur était **volatile** : réinitialisé
au démarrage, au changement de média, et perdu dès qu'un programme mal élevé
touchait la FAT. Le comportement réel est donc entre les deux modes : plutôt
`fromLastAllocated` à l'intérieur d'une session, plutôt `fromVolumeStart` d'un
démarrage à l'autre — ce qui, sur des machines qu'on éteignait chaque soir,
donne bien la texture « gruyère dense en tête de volume » que le modèle produit.
La modélisation est la bonne, la justification dans le commentaire est fausse ;
et une remise à zéro du hint à chaque journée de la timeline serait plus fidèle
encore, pour un `if`.

---

## 6. Bugs et incohérences code / commentaire

### 6.1 Sur FAT, tous les fichiers système sont alloués depuis le cluster 0

```swift
private func origin(for hint: AllocationHint) -> UInt32 {
    switch hint {
    case .boot, .system: return 0           // ← même en VFAT et FAT32
    ...
```

Le commentaire ne parle que d'`IO.SYS` et du chargeur d'amorçage, ce qui est
juste. Mais `FileCategory.systemCore.hint == .system`, et `systemCore` est la
catégorie de **toutes les DLL, tous les pilotes, toutes les bibliothèques
partagées et tous les fichiers de remplacement des vagues de mise à jour**. Le
pilote VFAT/FAT32 ne connaît rien de tel : il sert son curseur `next-free`, pour
tout le monde.

Mesuré sur `gamer-1999` (FAT32, 8,4 Go) : les 786 `UPD*.DLL` produits par les
mises à jour ont une position moyenne à **1 % du volume**, maximum 40 %, et
3,1 extents chacun. Le devant du volume est donc re-mité en permanence par un
mécanisme qui n'existait pas. Sur `dev-1996` (VFAT) : 306 fichiers, position
moyenne 10 %.

Correction : `.system` ne doit valoir 0 que pour `scan == .fromVolumeStart`,
comme `.normal` — deux mots à déplacer dans le `switch`.

### 6.2 `NTFSAllocator` : écriture morte, et le curseur système revient au début

```swift
// La tête du volume est pleine : ...
systemCursor = min(systemCursor &+ searchHorizon, range.upperBound)
systemCursor = range.lowerBound                    // ← écrase la ligne au-dessus
```

La première affectation ne sert à rien. Surtout, l'effet obtenu est l'inverse de
ce qu'annonce le commentaire trois lignes plus haut (« Le curseur système avance
même quand il ne trouve rien : sinon chaque mise à jour rebalaie la même zone
pleine depuis le début ») : il **repart** du début de la plage de données à
chaque échec. Sur un volume dont la tête est saturée — c'est-à-dire tous les
scénarios NTFS après quelques mois — chaque fichier système paie un balayage
depuis le même point. C'est à la fois un coût et un biais de placement.

### 6.3 La croissance de la MFT hors zone est maximalement fragmentante

```swift
while remaining > 0 {
    guard let run = bitmap.bestFitRun(minLength: 1, in: 0..<bitmap.clusterCount) else { break }
```

`minLength: 1` sur **tout le volume**, sans fenêtre ni horizon : le best-fit rend
donc le *plus petit trou du disque*, presque toujours de un cluster. La boucle
consomme les miettes une par une, et chaque tour rebalaie le volume entier.

Mesuré : la MFT de `dev-2003` fait 4 653 clusters en **348 extents**. Une MFT de
18 Mo en 348 morceaux, c'est le symptôme d'un volume maltraité pendant des
années ; ici c'est le premier dépassement de zone qui la produit d'un coup. Un
vrai NTFS étend `$MFT` par blocs (au moins 8 enregistrements, et il cherche du
contigu), ce qui donne typiquement quelques dizaines de fragments au pire. À
comparer : `secretaire-2007`, moins agressif, en a 50.

Correction : demander `minLength: min(remaining, 8)` puis retomber sur 1 en
dernier recours, et borner la recherche avec les mêmes `searchWindow` /
`searchHorizon` que le reste de la classe. Elle réduit aussi le coût de
génération.

### 6.4 Deux `AllocationHint` sont mortes

- `.boot` : aucune `FileCategory` ne le rend (vérifié : la liste est vide), et
  aucun appelant ne le passe. Les branches `.boot` de `FATAllocator.origin` et de
  `NTFSAllocator.place` — dont un scan complet non borné du volume — ne
  s'exécutent jamais.
- `.temporary` : dans les deux allocateurs, traité **exactement** comme
  `.normal`. Or son commentaire annonce le contraire : « Ce sont eux qui creusent
  les trous, et les placer à part change la texture du volume. » Rien n'est placé
  à part.

Le comportement est le bon — aucun système de fichiers de l'époque ne ségrégeait
les temporaires — mais la documentation promet une mécanique qui n'existe pas. À
corriger dans le commentaire, ou à supprimer avec le cas.

### 6.5 Sur NTFS, `.boot` ne peut pas être près du début

`place` cherche `.boot` depuis `range.lowerBound`, or `dataRange` commence
**après** la zone MFT, soit 12,5 % du volume. Un fichier d'amorçage n'a donc
aucun moyen d'être au début. Sans effet aujourd'hui (§ 6.4), mais le jour où
`Layout.ini` sera modélisé, c'est là que ça coincera : les fichiers de démarrage
de XP vont dans la première zone du volume, devant la zone MFT, pas derrière.

### 6.6 `yieldMFTZone` : la MFT sortie de sa zone

```swift
let mftEnd = mft.extents.map(\.end).filter { mftZone.contains($0) }.max()
    ?? mftZone.lowerBound
```

Si la MFT a déjà débordé (§ 6.3), aucun de ses `end` n'est dans la zone, donc
`mftEnd` retombe sur `mftZone.lowerBound` et **toute** la zone est cédée d'un
coup au lieu de la moitié. Pas de corruption (la bitmap protège les clusters de
la MFT), mais `mftZoneHalvings` ne veut plus dire ce qu'il dit, et la règle
« moitié à chaque fois » est court-circuitée dans le cas précis où elle est le
plus intéressante.

### 6.7 `ProfileSpec.clusterCount` ignore la surcharge du format

```swift
let count = disk.sizeBytes / UInt64(profile.clusterBytes)
```

Ni les secteurs réservés, ni les deux copies de la FAT, ni la racine FAT16, ni
les 8 Ko de `$Boot` ne sont déduits. Sur `gamer-1999`, les deux FAT font 17 Mo :
le volume généré est donc 17 Mo plus grand que ce que la géométrie de
`PartitionGeometry` pourrait contenir, et `totalSectors` dépasse la capacité du
disque porteur. Sans conséquence audible, mais les deux modules ne décrivent plus
le même volume. Une cohérence à rétablir dans `PartitionGeometry.init(startLBA:
clusterCount:…)` ou en amont.

Au passage, le clamp `min(count, maxClusterCount)` est une troncature
silencieuse : un FAT16 de 4 Go en clusters de 32 Ko donne un volume de 2 Go sans
que rien dans le noyau ne le signale — seul `ProfileIssues` prévient, et
uniquement pour les profils passés par l'interface.

### 6.8 La résidence NTFS échappe à la comptabilité de remplissage

`FileSystemProfile.allocatedBytes` rend **0** pour un fichier résident, ce qui
est correct côté clusters. Mais `ScenarioCompiler.occupancy` s'appuie dessus pour
tenir `committedBytes`, donc le seuil « l'utilisateur fait du ménage » ignore
complètement la MFT — alors qu'un profil développeur avec 20 000 sources
résidentes lui fait peser 20 Mo. À l'inverse, un fichier résident consomme
1 Ko de MFT et non 0 octet de disque. `occupancy` devrait rendre
`directoryEntryBytes` pour un résident.

Accessoirement : `secretaire-2007` compte **0 fichier résident** sur 17 011,
parce qu'aucune distribution de `SizeModel` ne descend sous 700 octets. La
résidence, qui est *le* trait distinctif de NTFS et à laquelle
`FileSystemProfile` consacre trois champs, ne se manifeste donc que sur les
profils développeur (864 fichiers sur `dev-2003`). Un vrai volume NTFS en a des
dizaines de milliers : raccourcis, `.ini`, `desktop.ini`, entrées de registre
exportées, en-têtes. C'est aussi ce qui fait qu'un NTFS chargé de petits fichiers
est *rapide* à parcourir — tout est dans la MFT.

---

## 7. Le chemin de lecture : ce que le montage et l'ouverture coûtent

Cette partie a un effet direct sur ce qu'on entend, et deux hypothèses y sont
trop généreuses.

**Le montage relit toute la FAT, deux fois.**

```swift
case .fat16, .fat32:
    var accesses = [MetadataAccess(lba: startLBA, sectors: 1),
                    MetadataAccess(lba: fat1LBA, sectors: fatSectors),
                    MetadataAccess(lba: fat2LBA, sectors: fatSectors)]
```

Deux problèmes. D'abord, **la copie de secours n'est jamais lue** : FAT2 n'est
consultée que si FAT1 est illisible. Ensuite, le pilote ne lit pas la table
entière : VFAT met en cache les secteurs de FAT **à la demande**. Pour un FAT16
de 1996 (128 Ko de table) la différence est théorique. Pour `gamer-1999`
(8,4 Go, 8,6 Mo de table), le modèle fait lire **17 Mo au montage**, soit une
seconde et demie de transfert qui n'a jamais eu lieu.

Et le corollaire est plus intéressant que la correction : puisque la FAT de FAT32
ne tenait pas en cache, **lire un fichier fragmenté provoquait des retours
périodiques vers la table**, en tête de volume, pour suivre la chaîne. Le
commentaire de `openAccesses` affirme l'inverse (« la table est lue une fois au
montage et tient en mémoire »), ce qui est vrai de FAT16 et faux de FAT32 — or
c'est exactement le va-et-vient qui donnait leur son aux volumes Windows 98
fatigués. Un accès à `fat1LBA + fatSector(forCluster:)` toutes les N sauts
d'extent le restituerait.

**Le montage NTFS lit 2 Mo de MFT.**

```swift
let mftSectors = max(clusterCount / 8, 1) * mftRecordSectors / 8
return [MetadataAccess(lba: startLBA, sectors: 16),
        MetadataAccess(lba: dataStartLBA, sectors: min(mftSectors, 4_096))]
```

La formule n'a pas de sens physique et le plafond de 4 096 secteurs fait lire
2 Mo de MFT d'un trait. Monter un volume NTFS, c'est lire `$Boot`, les premiers
enregistrements de `$MFT` (les 16 métafichiers), `$MFTMirr` pour vérification,
rejouer `$LogFile` s'il est sale, et ouvrir `$Bitmap` — quelques dizaines de
kilo-octets, plus le journal. Beaucoup plus court, mais **réparti** sur trois
zones du volume, donc plus bruyant en seeks et moins en transfert. Le modèle
actuel a exactement le profil inverse.

**Les lectures de données sont arrondies au cluster.**

```swift
var remaining = partition.clusters(forBytes: max(limit, 1))
```

Lire 2 Ko d'un fichier sur `dev-1996` (clusters de 32 Ko) émet une requête de
32 Ko. Le gestionnaire de cache de Windows lit par pages de 4 Ko, pas par
clusters ; DOS lisait les secteurs demandés. L'amplification va jusqu'à 16× sur
les volumes de 1996, ce qui se voit sur les durées de démarrage — et fausse
précisément la comparaison avec le témoin `freshlyInstalled()`, puisqu'elle
s'applique aux deux mais pas dans les mêmes proportions (un volume contigu paie
l'arrondi en transfert séquentiel, un volume mité le paie en seeks).

**`fileIndex` n'est pas un numéro d'enregistrement MFT.** Dans `BootSession`,
`fileIndex` est le rang du fichier **dans l'ordre de lecture du démarrage** ; il
sert d'adresse d'enregistrement MFT dans `openAccesses` et `commitAccesses`.
Deux conséquences : les enregistrements lus sont toujours parfaitement
séquentiels (d'où l'optimisation `bulk`, qui est du coup un peu tautologique), et
le même fichier a une adresse différente selon le scénario qui le lit. Le
catalogue connaît le vrai rang de création, qui est une bien meilleure
approximation du numéro d'enregistrement — et il n'est pas séquentiel dans
l'ordre de lecture, ce qui redonne à la MFT le sautillement qu'elle avait.

---

## 8. Récapitulatif, par rendement décroissant

| # | Ce qu'il faut faire | Effort | Gain |
|---|---|---|---|
| 1 | Allocation incrémentale pour les écritures de taille non déclarée, entrelacée dans la journée (§ 2) | moyen | comble le trou central de l'histogramme ; débloque les deux cibles de calibration sans toucher aux entrées |
| 2 | Retirer `clusterKB` des trois scénarios de 1993 ; ajouter la table FAT32 et corriger `gamer-1999` (§ 5.1, 5.2) | trivial | quatre volumes sur vingt cessent d'être impossibles |
| 3 | `.system` ne force le cluster 0 que sur `fromVolumeStart` (§ 6.1) | trivial | supprime un mitage inventé du devant des volumes FAT32/VFAT |
| 4 | Croissance de la MFT par blocs et recherche bornée (§ 6.3) | petit | MFT de 348 → quelques dizaines d'extents ; génération plus rapide |
| 5 | Répertoires alloués comme des fichiers, entrées de 32 octets et LFN VFAT (§ 4.1) | moyen | une population entière de petits fichiers réécrits, donc fragmentés ; supprime la dernière approximation de `openAccesses` |
| 6 | `$LogFile` dans `systemExtents` et dans `commitAccesses` (§ 4.2) | petit | rend à NTFS son trafic de métadonnées groupé |
| 7 | Horodatage d'accès NTFS jusqu'à XP, désactivé sous Vista (§ 4.3) | petit | un écart d'époque audible, gratuit |
| 8 | Montage : ne pas lire FAT2, ne pas lire toute la FAT32, resserrer le montage NTFS (§ 7) | petit | supprime jusqu'à 17 Mo de lecture fantôme par démarrage |
| 9 | Suivi de chaîne FAT32 : accès périodique à la table pendant la lecture d'un fichier fragmenté (§ 7) | petit | restitue la signature sonore de Windows 98 |
| 10 | Corriger `$MFTMirr` (taille, position, année de bascule), `$Boot`, secteurs réservés FAT32 (§ 5.3–5.4, § 4.4) | trivial | exactitude |
| 11 | Écriture morte et curseur système de `NTFSAllocator` (§ 6.2) | trivial | le code fait ce que son commentaire annonce |
| 12 | `.boot` / `.temporary` : documenter l'inertie ou retirer (§ 6.4) | trivial | la doc arrête de promettre |
| 13 | Documenter et mesurer `reuseTolerance` & consorts (§ 3) | petit | le principe « aucun paramètre de fragmentation » redevient vrai, ou assumé |
| 14 | `occupancy` d'un résident = 1 Ko de MFT ; élargir `SizeModel` sous 700 octets (§ 6.8) | petit | la résidence NTFS cesse d'être décorative |

Les points 2, 3, 4 et 10 sont des corrections de quelques lignes qui portent sur
des faits vérifiables. Le point 1 est le seul qui demande une décision de
conception — et c'est celui qui décide si les volumes ressemblent à ce qu'on a
entendu.
