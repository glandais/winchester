# XP à la lettre : plan des chantiers 47 à 52

**État au 25 septembre 2026 : les six chantiers sont livrés sur la branche
`xp`** (47 à 52, `LEDGER.md`), ni poussés ni fusionnés. Avant la soumission
de la 1.0.0 restent : la fusion de `xp` dans `develop`, un nouveau build
(le build 4 ne porte ni la section « À propos » ni les pourboires, dont les
trois achats intégrés partent avec la version), et les corrections laissées
hors de ce plan — B#31 à B#34, B#36 et B#45 (« sans achat intégré », Ko-fi,
« no network access », le commentaire d'`AboutLink`).

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
  (`swift test -c release --filter CalibrationTests`). Trois tests y
  échouent (le « quatre » d'abord écrit ici comptait mal : recompté aux
  chantiers 48 et 49), sur huit anomalies relevées dont trois déjà connues :
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

**Fait** le 22 septembre 2026, branche `xp` (`LEDGER.md`, chantier 47). Tout
ce qui suit est livré. Écarts au plan : B#15 ne s'entend que sur 4 volumes
(ceux dont des fichiers ont leur enregistrement dans la queue de la MFT), et
la prédiction « seules les passes XP et les volumes 2012 bougent » tient au
bilan près (344 identiques, 56 changés, 12 absents ; 54 md5 sur 58).
Calibration en Release : inchangée, aux mêmes chiffres.

- [x] **B#15** : `mftRecordLBA` suit `DefragVolume.mftExtents` après
  `relocateMFTTail`, soit par une `partition` mutable, soit par les extents
  passés au `commit`.
- [x] **B#16** : l'avancement de la passe XP ne recule plus
  (`dfrgntfs.cpp:981-985` : borne sur la dernière valeur).
- [x] **B#25** : l'outil par défaut est daté par l'année du scénario, et non par
  celle du disque nommé.
- [x] **B#17** : `filesAlreadyInPlace` ne compte ni les fichiers qui seront
  déplacés ni les intouchables.
- [x] **B#21** : l'arrêt au premier fichier sans trou est limité à l'ordre par
  taille.
- [x] **`xp-defrag-tri`** : départager par `mftRecord`, non par `id`.
- [x] **B#35** : l'état de `TipJar` est remis à zéro à la fermeture de la
  feuille.
- [x] **B#51** : `wav-md5.py` part d'un environnement propre et sort en erreur
  quand un rendu échoue.
- [x] **Décision 3** : retirer les 12 passes XP sur FAT des mesures, et refaire
  le test de B#30.
- [x] **B#5 et B#12**, dans leur propre lot de rendus : `sizeMB: 500107` pour
  `dev-2012` et `gamer-2012`, et la doc de `DiskSpec(reference:)`.

Prédiction attendue : seules les passes XP et les volumes 2012 bougent.

## Chantier 48 : la disposition NTFS au formatage, `Formatting.xp` seul

**Fait** le 24 septembre 2026, branche `xp` (`LEDGER.md`, chantier 48). Tout
ce qui suit est livré. Écarts au plan : B#24 vaut pour tous les NTFS (l'analyse
est commune aux outils) ; l'index racine vient **après** `$UpCase`
(`format.cxx:1175`), pas avant `$Bitmap` ; le montage de XP lit aussi
`$UpCase` et `$Bitmap` entières (`fsctrl.c:2384-2412`, `bitmpsup.c:655`) ;
`dev-2007` est formaté Vista et ne bouge qu'à l'analyse, l'écoute est sur les
volumes de 2003. Prédiction : les comptes tiennent au bilan près (48a :
180/220 ; 48 : 73/327 ; 49 md5 sur 58), mais les plans de 48a bougent par la
grille de 5 s des points de contrôle (prouvé par binaires jetables), et les
passes des 40 Go ne s'allongent pas. Calibration en Release : mêmes échecs,
famille-2003 à 24,4 % au lieu de 23,5. `GalleryAllocationAudit` : propre sur
les vingt-quatre, une fois l'audit corrigé pour la queue de MFT que
`MFTDefrag` quitte (faux positif présent dès le chantier 47).

- [x] `$LogFile` finit deux clusters avant `$MFT`, avec le bitmap de la MFT
  juste devant elle (`ntfs-format-03`).
- [x] `$MFTMirr` est à n/2, suivi de `$AttrDef`, de l'index de la racine, de
  `$Bitmap` et de `$UpCase` (`ntfs-format-04`, lacune « métafichiers »).
- [x] `$MFT` au tiers du volume sous 2 Gio, à 1 Gio de 2 à 6 Gio, à 3 Gio
  au-delà (`ntfs-format-02`). Une MFT neuve compte 16 enregistrements
  (`ntfs-format-12`).
- [x] La taille de `$LogFile` suit la rampe de XP (`ntfs-format-07`). Cela ne
  change rien pour la galerie, seulement pour les disques personnalisés.
- [x] Le montage ne lit plus le dernier secteur (`ntfs-format-17`). La copie du
  secteur d'amorçage n'est lue que si la lecture de `$Boot` échoue.
- [x] **B#24** : l'analyse lit les extents de `$MFT`, son `$BITMAP` et la bitmap
  du volume. Elle ne lit plus `$LogFile`, `$MFTMirr`, ni `$Boot` une
  seconde fois (`dfrgntfs.cpp:4588-4613, 5110-5160`,
  `freespace.cpp:1345`).
- [x] **B#10** : les commentaires de `VolumeLayout` et de `DiskGenerator` sont
  corrigés **dans le sens de XP**.

À écouter : `dev-2007`, dont chaque validation va maintenant vers une bitmap
à mi-volume, avec le journal tout proche. `GalleryAllocationAudit` doit être
lancé en Release.

## Chantier 49 : l'allocateur NTFS de XP

**Fait** le 24 septembre 2026, branche `xp` (`LEDGER.md`, chantier 49).
Tout ce qui suit est livré, pour `Formatting.xp` seul (NT 4, Vista et 7
gardent le modèle d'avant ; B#8 vaut pour tous). Écarts au plan : B#8 touche
la galerie (quatre volumes de Vista et 7, dont la zone est renouvelée après
une défragmentation d'histoire) ; le temps est traduit par un montage au
premier événement de chaque journée et un point de contrôle entre deux
événements ; l'écriture du programme est de 4 Ko (`stdio.h:265`) ; le
perçage de la MFT n'est pas modélisé, sa condition n'étant jamais remplie
sur la galerie. famille-2003 finit à 16,2 %, secretaire-2003 à 64,0 %.
Calibration en Release : verte, 4 known issues ; trois cibles retirées ou
remplacées, avec leur source.

- [x] 1. **B#8** : `dataRanges` exclut la zone MFT courante, et non tout ce qui la
   précède.
- [x] 2. **Best fit global hors zone** : le plus petit run au moins aussi long que
   la demande, dans le cache des runs libres, au plus petit LCN. Il n'y a
   pas de curseur pour un fichier neuf, et l'extension part de
   `PrecedingLcn + 1` (`ntfs-alloc-01`, `02`, `04`). Cela remplace B#6 et
   B#7, qu'il ne faut pas appliquer tels quels.
- [x] 3. **Découpage** du plus grand run au plus petit (`AllowShorter`), seulement
   si aucun run ne suffit (`ntfs-alloc-21`).
- [x] 4. **Pas de préférence pour l'espace vierge.** Les clusters libérés restent
   masqués jusqu'au point de contrôle, puis entrent dans le cache
   (`ntfs-alloc-03`).
- [x] 5. **Surallocation** à l'écriture : exacte d'abord, puis ×2, ×4, ×8 et ×16,
   bornée à `FreeClusters/1024 + demande`, et rendue à la fermeture
   (`ntfs-alloc-05`, `io-cache-06`). La doc de `FileSystemProfile` et le
   README cessent de l'attribuer au lazy writer.
   *Repris le 25 septembre 2026 (`LEDGER.md`, chantier 49, « Reprise de
   49c ») : l'écriture de 4 Ko n'est plus celle de tous. Word écrit par
   ole32, un fichier projeté étendu par `SetEndOfFile` exacts au multiple
   de 16 Ko (lien Word → ole32 déduit, pas de 16 Ko un minimum) ;
   `index.dat` par `wininet`, 16 Ko exacts (attesté) ; le `.pst` et les
   autres gardent 4 Ko et la surallocation, en hypothèse. secretaire-2003
   reste à 64,0 % — le cluster du stub d'ole32 va, comme la première
   écriture de 4 Ko, au plus petit trou —, ses documents en plus de
   morceaux ; `index.dat` en deux à trois fois moins.*
- [x] 6. **Zone MFT** recalculée au montage, regonflée au-dessus d'un seizième
   d'espace libre, reposée ailleurs quand la MFT ne peut plus s'étendre
   d'un seul tenant (`ntfs-format-10`, `ntfs-alloc-08`, `10`). Le registre
   `NtfsMftZoneReservation` n'est gardé que si un profil s'en sert.
   *Fait : aucun profil ne s'en sert ; `mftZoneShare` reste, et le
   multiplicateur de XP en est déduit.*
- [x] 7. **Croissance de la MFT** par 16 enregistrements, dans la zone comme
   ailleurs (`ntfs-alloc-09`). Les enregistrements libérés sont réutilisés
   par le bas (`ntfs-alloc-12`). La MFT est trouée quand les
   enregistrements libres dépassent un huitième de l'espace libre (lacune
   `NtfsCreateMftHole`). *Fait, sauf le perçage : sa condition est comptée à
   chaque point de contrôle, et n'est jamais remplie sur la galerie.*
- [x] 8. **Recaler `CalibrationTests`** selon la décision 1, avec la source de
   chaque borne, puis corriger le README (B#37).

## Chantier 50 : le moteur de XP

**Fait** le 25 septembre 2026, branche `xp` (`LEDGER.md`, chantier 50),
précédé d'une étape non prévue au plan : **50a**, la défragmentation de
l'histoire qui laisse la zone MFT vide (`freespace.cpp:305-318`) — c'est
elle qui envoyait la MFT de `dev-2003` dans une zone neuve à 94 % du
volume ; cinq volumes changent, leur MFT d'un seul tenant. Tout ce qui
suit est livré, dans l'ordre 50b (rétention) → 50c (MFTDefrag) → 50d
(transactions) → 50e (consolidation) → 50f (démarrage) → 50g (15 %,
B#22) : la rétention d'abord, parce qu'elle rendait les plans sensibles à
l'horloge. Écarts au plan : le code du pilote (rétention, transactions,
VDL) ne vaut que pour les volumes formatés par XP, Vista et 7 gardent le
modèle d'avant ; celui de l'outil vaut pour le moteur commun, sauf
l'optimisation du démarrage, XP seulement ; UltraDefrag garde sa propre
rétention (`move.c`). Prédictions fausses sur les durées à 50b (tris de
JkDefrag ×2 à ×7, qui vont maintenant au bout), 50c (aucun effet) et 50d
(XP +2 à +23 %, le poids du journal par bloc). Calibration en Release :
verte, les mêmes 4 known issues.

- [x] **MFTDefrag** : il agit dès deux extents, cherche un trou de la taille
  de la MFT entière, hors de la zone MFT, et agit avant et après la passe
  (`xp-defrag-mft-condition`, `mft-zone-cible`). *Fait (50c) : le seuil de
  seize enregistrements se réduit à un premier extent non vide sur des
  clusters de 4 Ko (`ClustersPerFRS` vaut 0) ; faute de trou, le dernier
  trou s'il touche la fin du volume, et `MOVE_FILE` pose ce qui tient.*
- [x] **Pas de rétention de 5 s** pour un défragmenteur. Les clusters quittés
  sont libres dans la bitmap qu'il relit. Un `MOVE_FILE` vers eux produit
  `DELETE_PENDING`, puis un vidage du journal, puis la réussite
  (`xp-defrag-point-de-controle`, `ntfs-alloc-15`). Cela vaut pour XP,
  JkDefrag et UltraDefrag, et touche `relocateMFTTail` et `heldClusters`.
  *Fait (50b), sous XP : les décisions ne dépendent plus de l'horloge
  (40 passes identiques sans point de contrôle).*
- [x] **Une transaction par bloc de 64 Kio** : commit dans `$LogFile`, USN,
  pages de bitmap et *mapping pairs*. Les métadonnées sont écrites par le
  lazy writer (`xp-defrag-validation`, `ntfs-alloc-14`). *Fait (50d) : le
  journal part avec le lazy writer (une seconde), le point de contrôle, un
  `DELETE_PENDING` ; LFS écrit paresseusement (`lfs/write.c:185-190`).*
- [x] **La copie s'arrête à `ValidDataLength`** : au-delà, les clusters sont
  réalloués sans copie (lacune). *Fait (50d) ; sans effet sur la galerie.*
- [x] **Consolidation** : elle rend « région parcourue sans abandon ». Le vidage
  de la zone MFT s'arrête au premier échec (`xp-defrag-abandon-dix`,
  `zone-mft-une-fois`). Les listes rognent aussi la zone de démarrage
  (`zone-mft-rognee`). *Fait (50e, et 50f pour la zone de démarrage).*
- [x] **`ProcessBootOptimise` ouvre la passe** sur le volume système :
  `Layout.ini`, fichiers de 32 Mo au plus, zone déplacée quand moins de 90 %
  des fichiers y sont déjà, avec une croissance de 150 % du manque
  (`xp-defrag-mft-avant-apres`, `boot-10` à `12`). Elle est à rapprocher de
  `BootLayout` et du rangement intelligent. *Fait (50f), XP seulement :
  `Layout.ini` est `BootLayout` ; la zone part du registre à 0 (première
  passe) ; le rangement intelligent n'est pas touché.*
- [x] **Les 15 %** : en ligne de commande, sans `-f`, l'outil refuse
  (`xp-defrag-15pct`). *Tranché (50g) : l'app imite la console, qui pose
  une question ; le modèle y répond oui.*
- [x] Les commentaires et les tests sur l'ancien XP (B#22) suivent. *Fait
  (50g).*

## Chantier 51 : démarrage, cache et pile d'E/S de XP

**Fait** le 25 septembre 2026, branche `xp` (`LEDGER.md`, chantier 51), en
neuf étapes : 51a (la file) → 51b (le préchargeur) → 51c (tailles) → 51d (le
*lazy writer*) → 51e (ses données) → 51f (date d'accès) → 51g (lecture
anticipée) → 51h (registre et `FLUSH CACHE`) → 51i (FAT). Tout ce qui suit est
livré, pour l'époque XP ; Vista et 7 gardent leur modèle. Écarts au plan : le
simulateur ne sert qu'une commande à la fois dans l'ordre du plan, la file
d'`atapi` est donc jouée par le planificateur sur ce qu'il émet ensemble ; le
« huitième » du *lazy writer* est un budget dépensé flux par flux, et un flux
de métadonnées part en entier ; le registre n'a pas de `.LOG` au catalogue ;
la borne validée du test « 2003 horodate » change avec le mécanisme.
Prédictions fausses sur l'ampleur à 51b (démarrages −0,7 à −5,8 %, seeks en
hausse), 51d (installations, journée) et 51i (passes FAT −18,6 à +277,9 %).
Calibration en Release : verte, les mêmes 4 known issues.

- [x] **Préchargeur** : il lit dans l'ordre du premier accès, fichier après
  fichier. Le balayage entendu vient de la **file d'`atapi` triée par LBA**
  (C-LOOK), qui s'applique aussi à la lecture anticipée, au lazy writer et à
  toute rafale asynchrone (`boot-01`, `02`, `io-cache-09`). Les pages
  tracées sont lues, pas « les N premiers Ko » (`boot-05`). Il y a deux lots
  par phase : les données, puis les images (lacune). Historique de
  8 démarrages (`boot-03`). *Fait (51a, 51b) : métadonnées une fois,
  répertoires énumérés, phase des pilotes et phase d'avant `SMSS` (en
  arrière-plan des pilotes), services et session sur pages préchargées,
  l'application à son lancement ; la trace n'existant pas, le budget de
  l'acte est lu d'un tenant (le comblement de 128 Ko le justifie, pas plus).*
- [x] **Date d'accès** : elle est journalisée, et l'entrée `$FILE_NAME` de
  l'index du répertoire parent est réécrite (`boot-15`). *Fait (51f).*
- [x] **Lazy writer** : un réveil par seconde, qui vide un huitième des pages
  sales ; le premier passage attend 3 s ; il écrit aussi les données
  (`io-cache-01`, `boot-16`). *Fait (51d, 51e) : le huitième est un budget
  dépensé flux par flux (`lazyrite.c:436-506`) ; trois fils dans la file.*
- [x] **Lecture anticipée** dès la troisième lecture séquentielle, ou dès le
  premier défaut à l'offset 0 (`io-cache-05`). *Fait (51g).*
- [x] **Tailles de requête** : 64 Ko par le cache, 128 Ko par SRB côté
  `atapi`, et des fautes d'image par 32 Ko (code) ou 16 Ko (données)
  (`io-cache-02` à `04`, lacune). *Fait (51c) : `classpnp` coupe à 124 Ko
  (31 pages) ; les fautes d'image n'ont pas d'occasion dans la galerie.*
- [x] **Vidage du registre** : 5 s après une modification, jusqu'au `FLUSH
  CACHE` du disque (lacune). *Fait (51h), pour les installations ; sans
  `.LOG` au catalogue, ses trois `FLUSH CACHE` seuls.*
- [x] **FAT sous l'API de XP** : `FSCTL_MOVE_FILE` avance par tranches de
  256 Kio ; il écrit la FAT avant et après chaque tranche, puis vide le cache
  du disque. Cela vaut pour JkDefrag et UltraDefrag sur FAT (`fat-20`,
  `xp-defrag-fat-bloc`). *Fait (51i).*

## Chantier 52 : les documents

**Fait** le 25 septembre 2026, branche `xp` (`LEDGER.md`, chantier 52). Aucune
ligne du modèle n'a bougé : 400 bilans et 58 md5 identiques à `51i`. Écarts
au plan : la table du rangement intelligent est **remesurée** (sur le modèle
de `51i`, 2012 compris), pas seulement signalée ; les remarques de l'assistant
passent toutes par le catalogue (treize clés), pas seulement l'anachronisme ;
la liste « Commentaires faux » de `WINDOWS_CHECK.md` était déjà soldée par les
chantiers 48 à 51. B#29 n'est fait qu'à moitié : l'assistant et `CLAUDE.md`
disent le même nom, mais ce nom s'affiche encore en français dans l'app
anglaise.

- [x] **`readme-tables.py`** : corriger d'abord les gabarits (B#20, B#38 à B#44 :
  « 91-91 % », « que un occupants », « 1 trous », les comparatifs retournés),
  puis régénérer. *Fait : verbes et comparatifs calculés (`times`, `versus`,
  élision) ; `--check` : un seul écart, la durée de génération de `dev-2007`.*
- [x] **README** : la table du rangement intelligent (B#39), l'arborescence
  (B#46) et « Ce qui ne l'est pas », qui perd tout ce que les chantiers 48
  à 51 ont sourcé. *Fait ; « Ce qui ne l'est pas » gagne ce qui manquait
  (le découpage de 64 Kio que JkDefrag et UltraDefrag ne suivent pas sous
  XP, les nuances du moteur, le pas de Word).*
- [x] **Fiches d'outils** : durées « measured » (B#19, B#26). *Fait, les
  vingt-quatre, d'après `51i`.*
- [x] **Site** : l'ancien XP, les outils de 1993, de Vista et de 7 (B#18, B#27,
  B#49), et la page « how it works ». *Fait ; section « The system » neuve.*
- [x] **Commentaires** : B#1 à B#4, B#11, B#14, B#28, B#48, et la liste
  « Commentaires faux » de `WINDOWS_CHECK.md` qui reste. *Fait ; la liste
  était vide.*
- [x] **Traduction** : les pluriels de `summary.windowsXP` (B#23),
  l'avertissement d'anachronisme en français seul (B#13). *Fait : quatre
  substitutions plurielles, vérifiées sur le catalogue compilé.*
- [x] **`CLAUDE.md`** : le nom de système « MS-DOS 6 » (B#29), et l'état de la
  soumission (B#47) une fois les chantiers livrés. *Fait, et les suites
  `Calibration` et `GalleryAllocationAudit`.*
- [x] `LEDGER.md:7459` : le renvoi au chantier 37 devient un renvoi au
  chantier 40 (B#50).

**Hors plan, plus tard** : B#31 à B#34 et B#45 (« sans achat intégré »,
Ko-fi, « no network access »), et B#36.
