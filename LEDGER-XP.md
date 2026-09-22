# XP à la lettre : plan des chantiers 47 à 52

Ce fichier n'est pas un chantier : **aucune ligne du modèle n'a bougé**. Il
range en chantiers trois retours du 22 septembre 2026, pris sur `develop` à
`96c8778` :

- **`AUDIT_REALISME.md`** : l'audit des lots réalisme (`079b244..1cd42cc`).
  Il compte 51 constats, numérotés `B#1` à `B#51` ;
- **`WINDOWS_CHECK.md`** : 126 affirmations de l'app confrontées au code de
  Windows XP SP1, et 38 comportements de XP que le modèle ignore. Les
  identifiants sont du type `ntfs-format-03`. Son annexe croise les deux
  documents ;
- **la suite `Calibration`**, sautée en Debug et **rouge en Release**
  (`swift test -c release --filter CalibrationTests`). Quatre tests y
  échouent, sur huit anomalies relevées dont trois déjà connues :
  - famille-2003 : remplissage de 88 % pour une exigence de plus de 90 %,
    et 23,5 % de fichiers fragmentés pour un plafond de 16 % ;
  - le rapport FAT32/NTFS s'inverse (16,4 % contre 23,5 %) ;
  - gamer-2003, installé d'une traite, a un fichier en plusieurs morceaux.

## Les décisions (Gabriel, 22 septembre 2026)

1. **Suivre XP à la lettre.** Le code de XP SP1 fait foi pour tout ce qui est
   daté XP, y compris l'allocateur NTFS, comme au chantier 45. Tous les
   bilans NTFS bougeront.
   Les cibles de `CalibrationTests` se reposent **d'après ce que fait XP**,
   pas d'après la mesure. Si l'allocateur de XP fragmente moins que les 40 %
   visés sur famille-2003, ou moins que la moitié de FAT32, c'est la cible
   qui est fausse, et le chantier le dit avec sa source.
   NT 4, Vista et 7 ne sont pas vérifiables dans ce code : ils gardent leur
   modèle, dit comme tel.
2. **Les six chantiers passent avant la soumission de la 1.0.0.** Elle attend
   donc les chantiers 47 à 52, et le `CLAUDE.md` qui la dit prête (B#47) est
   faux d'ici là.
   **Une exception** : le site et le README qui disent « gratuit, sans achat
   intégré », et le Ko-fi (B#31 à B#34, B#45). Ce détail se corrigera plus
   tard, **hors du chantier 52** et hors de ce plan.
3. **Les 12 passes « XP sur FAT » sont supprimées des mesures.** Sur FAT, XP
   lance `dfrgfat`, un autre moteur (`xp-defrag-fat-moteur`), et
   l'interface ne propose déjà XP que sur NTFS. Le test B#30 (« UltraDefrag
   et XP laissent les répertoires FAT en place ») perd sa moitié XP et
   redevient une vraie assertion : les extents des répertoires, avant et
   après, sont les mêmes.

## L'ordre, et pourquoi

Les dépendances viennent de l'annexe de `WINDOWS_CHECK.md` (§4) :

- **B#15 avant MFTDefrag.** Suivi à la lettre, MFTDefrag recollera la MFT à
  presque chaque passe. Les lectures doivent d'abord suivre la MFT déplacée.
- **B#8 avant la zone MFT renouvelée.** Sinon, famille-2003 et
  secretaire-2003 perdent le milieu du volume.
- **La disposition et l'allocateur avant MFTDefrag.** Ils décident combien
  d'extents a la MFT, donc qui déclenche MFTDefrag.
- **Les documents en dernier.** Ils changent avec chaque chantier.

Chaque chantier suit le protocole des lots réalisme :

1. créer un worktree ;
2. `snapshot.sh` ;
3. écrire la prédiction avant la mesure ;
4. lancer les 400 bilans (412 moins les 12 passes supprimées au chantier 47),
   puis `wav-md5.py` et `compare.py` ;
5. lancer `swift test`, **et la suite `Calibration` en Release** à partir du
   chantier 49 ;
6. écrire l'entrée de `LEDGER.md`.

## Chantier 47 : les défauts sans dépendance

- **B#15** : `mftRecordLBA` suit `DefragVolume.mftExtents` après
  `relocateMFTTail`, soit par une `partition` mutable, soit par les extents
  passés au `commit`.
- **B#16** : l'avancement de la passe XP ne recule plus
  (`dfrgntfs.cpp:981-985` : borne sur la dernière valeur).
- **B#25** : l'outil par défaut est daté par l'année du scénario, et non par
  celle du disque nommé.
- **B#17** : `filesAlreadyInPlace` ne compte ni les fichiers qui seront
  déplacés ni les intouchables.
- **B#21** : l'arrêt au premier fichier sans trou est limité à l'ordre par
  taille.
- **`xp-defrag-tri`** : départager par `mftRecord`, non par `id`.
- **B#35** : l'état de `TipJar` est remis à zéro à la fermeture de la
  feuille.
- **B#51** : `wav-md5.py` part d'un environnement propre et sort en erreur
  quand un rendu échoue.
- **Décision 3** : retirer les 12 passes XP sur FAT des mesures, et refaire
  le test de B#30.
- **B#5 et B#12**, dans leur propre lot de rendus : `sizeMB: 500107` pour
  `dev-2012` et `gamer-2012`, et la doc de `DiskSpec(reference:)`.

Prédiction attendue : seules les passes XP et les volumes 2012 bougent.

## Chantier 48 : la disposition NTFS au formatage, `Formatting.xp` seul

- `$LogFile` finit deux clusters avant `$MFT`, avec le bitmap de la MFT
  juste devant elle (`ntfs-format-03`).
- `$MFTMirr` est à n/2, suivi de `$AttrDef`, de l'index de la racine, de
  `$Bitmap` et de `$UpCase` (`ntfs-format-04`, lacune « métafichiers »).
- `$MFT` au tiers du volume sous 2 Gio, à 1 Gio de 2 à 6 Gio, à 3 Gio
  au-delà (`ntfs-format-02`). Une MFT neuve compte 16 enregistrements
  (`ntfs-format-12`).
- La taille de `$LogFile` suit la rampe de XP (`ntfs-format-07`). Cela ne
  change rien pour la galerie, seulement pour les disques personnalisés.
- Le montage ne lit plus le dernier secteur (`ntfs-format-17`). La copie du
  secteur d'amorçage n'est lue que si la lecture de `$Boot` échoue.
- **B#24** : l'analyse lit les extents de `$MFT`, son `$BITMAP` et la bitmap
  du volume. Elle ne lit plus `$LogFile`, `$MFTMirr`, ni `$Boot` une
  seconde fois (`dfrgntfs.cpp:4588-4613, 5110-5160`,
  `freespace.cpp:1345`).
- **B#10** : les commentaires de `VolumeLayout` et de `DiskGenerator` sont
  corrigés **dans le sens de XP**.

À écouter : `dev-2007`, dont chaque validation va maintenant vers une bitmap
à mi-volume, avec le journal tout proche. `GalleryAllocationAudit` doit être
lancé en Release.

## Chantier 49 : l'allocateur NTFS de XP

1. **B#8** : `dataRanges` exclut la zone MFT courante, et non tout ce qui la
   précède.
2. **Best fit global hors zone** : le plus petit run au moins aussi long que
   la demande, dans le cache des runs libres, au plus petit LCN. Il n'y a
   pas de curseur pour un fichier neuf, et l'extension part de
   `PrecedingLcn + 1` (`ntfs-alloc-01`, `02`, `04`). Cela remplace B#6 et
   B#7, qu'il ne faut pas appliquer tels quels.
3. **Découpage** du plus grand run au plus petit (`AllowShorter`), seulement
   si aucun run ne suffit (`ntfs-alloc-21`).
4. **Pas de préférence pour l'espace vierge.** Les clusters libérés restent
   masqués jusqu'au point de contrôle, puis entrent dans le cache
   (`ntfs-alloc-03`).
5. **Surallocation** à l'écriture : exacte d'abord, puis ×2, ×4, ×8 et ×16,
   bornée à `FreeClusters/1024 + demande`, et rendue à la fermeture
   (`ntfs-alloc-05`, `io-cache-06`). La doc de `FileSystemProfile` et le
   README cessent de l'attribuer au lazy writer.
6. **Zone MFT** recalculée au montage, regonflée au-dessus d'un seizième
   d'espace libre, reposée ailleurs quand la MFT ne peut plus s'étendre
   d'un seul tenant (`ntfs-format-10`, `ntfs-alloc-08`, `10`). Le registre
   `NtfsMftZoneReservation` n'est gardé que si un profil s'en sert.
7. **Croissance de la MFT** par 16 enregistrements, dans la zone comme
   ailleurs (`ntfs-alloc-09`). Les enregistrements libérés sont réutilisés
   par le bas (`ntfs-alloc-12`). La MFT est trouée quand les
   enregistrements libres dépassent un huitième de l'espace libre (lacune
   `NtfsCreateMftHole`).
8. **Recaler `CalibrationTests`** selon la décision 1, avec la source de
   chaque borne, puis corriger le README (B#37).

## Chantier 50 : le moteur de XP

- **MFTDefrag** : il agit dès deux extents, cherche un trou de la taille de
  la MFT entière, hors de la zone MFT, et agit avant et après la passe
  (`xp-defrag-mft-condition`, `mft-zone-cible`).
- **Pas de rétention de 5 s** pour un défragmenteur. Les clusters quittés
  sont libres dans la bitmap qu'il relit. Un `MOVE_FILE` vers eux produit
  `DELETE_PENDING`, puis un vidage du journal, puis la réussite
  (`xp-defrag-point-de-controle`, `ntfs-alloc-15`). Cela vaut pour XP,
  JkDefrag et UltraDefrag, et touche `relocateMFTTail` et `heldClusters`.
- **Une transaction par bloc de 64 Kio** : commit dans `$LogFile`, USN,
  pages de bitmap et *mapping pairs*. Les métadonnées sont écrites par le
  lazy writer (`xp-defrag-validation`, `ntfs-alloc-14`).
- **La copie s'arrête à `ValidDataLength`** : au-delà, les clusters sont
  réalloués sans copie (lacune).
- **Consolidation** : elle rend « région parcourue sans abandon ». Le vidage
  de la zone MFT s'arrête au premier échec (`xp-defrag-abandon-dix`,
  `zone-mft-une-fois`). Les listes rognent aussi la zone de démarrage
  (`zone-mft-rognee`).
- **`ProcessBootOptimise` ouvre la passe** sur le volume système :
  `Layout.ini`, fichiers de 32 Mo au plus, zone déplacée quand moins de 90 %
  des fichiers y sont déjà, avec une croissance de 150 % du manque
  (`xp-defrag-mft-avant-apres`, `boot-10` à `12`). Elle est à rapprocher de
  `BootLayout` et du rangement intelligent.
- **Les 15 %** : en ligne de commande, sans `-f`, l'outil refuse
  (`xp-defrag-15pct`).
- Les commentaires et les tests sur l'ancien XP (B#22) suivent.

## Chantier 51 : démarrage, cache et pile d'E/S de XP

- **Préchargeur** : il lit dans l'ordre du premier accès, fichier après
  fichier. Le balayage entendu vient de la **file d'`atapi` triée par LBA**
  (C-LOOK), qui s'applique aussi à la lecture anticipée, au lazy writer et à
  toute rafale asynchrone (`boot-01`, `02`, `io-cache-09`). Les pages
  tracées sont lues, pas « les N premiers Ko » (`boot-05`). Il y a deux lots
  par phase : les données, puis les images (lacune). Historique de
  8 démarrages (`boot-03`).
- **Date d'accès** : elle est journalisée, et l'entrée `$FILE_NAME` de
  l'index du répertoire parent est réécrite (`boot-15`).
- **Lazy writer** : un réveil par seconde, qui vide un huitième des pages
  sales ; le premier passage attend 3 s ; il écrit aussi les données
  (`io-cache-01`, `boot-16`).
- **Lecture anticipée** dès la troisième lecture séquentielle, ou dès le
  premier défaut à l'offset 0 (`io-cache-05`).
- **Tailles de requête** : 64 Ko par le cache, 128 Ko par SRB côté
  `atapi`, et des fautes d'image par 32 Ko (code) ou 16 Ko (données)
  (`io-cache-02` à `04`, lacune).
- **Vidage du registre** : 5 s après une modification, jusqu'au `FLUSH
  CACHE` du disque (lacune).
- **FAT sous l'API de XP** : `FSCTL_MOVE_FILE` avance par tranches de
  256 Kio ; il écrit la FAT avant et après chaque tranche, puis vide le cache
  du disque. Cela vaut pour JkDefrag et UltraDefrag sur FAT (`fat-20`,
  `xp-defrag-fat-bloc`).

## Chantier 52 : les documents

- **`readme-tables.py`** : corriger d'abord les gabarits (B#20, B#38 à B#44 :
  « 91-91 % », « que un occupants », « 1 trous », les comparatifs retournés),
  puis régénérer.
- **README** : la table du rangement intelligent (B#39), l'arborescence
  (B#46) et « Ce qui ne l'est pas », qui perd tout ce que les chantiers 48
  à 51 ont sourcé.
- **Fiches d'outils** : durées « measured » (B#19, B#26).
- **Site** : l'ancien XP, les outils de 1993, de Vista et de 7 (B#18, B#27,
  B#49), et la page « how it works ».
- **Commentaires** : B#1 à B#4, B#11, B#14, B#28, B#48, et la liste
  « Commentaires faux » de `WINDOWS_CHECK.md` qui reste.
- **Traduction** : les pluriels de `summary.windowsXP` (B#23),
  l'avertissement d'anachronisme en français seul (B#13).
- **`CLAUDE.md`** : le nom de système « MS-DOS 6 » (B#29), et l'état de la
  soumission (B#47) une fois les chantiers livrés.
- `LEDGER.md:7459` : le renvoi au chantier 37 devient un renvoi au
  chantier 40 (B#50).

**Hors plan, plus tard** : B#31 à B#34 et B#45 (« sans achat intégré »,
Ko-fi, « no network access »), et B#36.
