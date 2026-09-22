# Le réalisme au banc — dépouillement d'une évaluation en dix agents

Ce fichier n'est pas un chantier de correction : **aucune ligne du modèle n'a
bougé**. C'est le dépouillement d'une évaluation du réalisme commandée le
21 septembre 2026 sur `develop` (`bed102e`), rangé par ce qu'il faut en faire,
sur le modèle de `LEDGER-EXPERTS.md`.

| dimension | périmètre | note | révisée |
|---|---|---|---|
| mécanique et temps | seek, latence, géométrie, ZBR, tampon, bus, broche | 8,5 | **8,2** |
| catalogue | les onze fiches de `DriveCatalog` et les vingt-quatre scénarios | 7,5 | **7,5** |
| systèmes de fichiers et charges | allocateurs, métadonnées, population, démarrage, journée, caches | 7,5 | **7,5** |
| défragmenteurs | les huit stratégies face aux outils imités | 8 | **7,5** |
| son et rendu | `SeekSynth`, `SpindleVoice`, mixage, haptiques, plateau à l'écran | 7,5 | **7,5** |

**La méthode.** Cinq évaluateurs (opus), un par dimension, en lecture seule :
le code, le README, les manuels de `disknoise.resources/manuels`, les sources de
JkDefrag et d'UltraDefrag, et le web. Chacun rendait une note et huit à quinze
constats classés *fidèle*, *approximation assumée* (dite dans le README) ou
*écart non assumé*, avec `fichier:ligne` et source. Puis cinq **sceptiques**, un
par dimension, chargés de réfuter : relire le code cité, vérifier qu'aucun JSON
ne surcharge la valeur, recouper le fait d'époque, et chercher si le README
l'assume déjà. Soixante-douze constats, dont **trois réfutés** et **vingt-quatre
nuancés** (un est resté sans verdict), plus trente-six oublis relevés par les
sceptiques.

Contrairement aux trois revues de `experts`, **rien n'a été instrumenté** : ni
sonde, ni `swift test`, ni rendu. Les chiffres ci-dessous sont soit lus dans le
code et les manuels, soit recalculés à la main par un agent et revérifiés par un
autre. Une douzaine de points de code ont été recontrôlés par `grep` au moment
d'écrire ce fichier (marqués ✓) ; les faits externes (KB 942092,
`FreeSpaceErrorLevel`, FAST'07, `mkntfs.c`) n'ont été vérifiés que par les
agents.

---

## Le problème

Les trois revues de `experts` avaient relu la **forme** du modèle, et huit lots
l'ont corrigée. Celle-ci pose une autre question : ce qu'on entend et ce qu'on
voit ressemble-t-il à une machine de l'année ? Le verdict tient en une phrase,
la même aux cinq dimensions : **ce qui est transposé d'une source ouverte est
exact jusqu'aux défauts de l'original ; ce qui est reconstitué d'un outil fermé
est énoncé comme un fait.**

Le second membre de la phrase est le vrai résultat. JkDefrag et UltraDefrag sont
relus constante par constante contre leurs sources, et tiennent. Le
défragmenteur de XP — celui que l'app fait entendre sur douze volumes sur
vingt-quatre — « n'évacue personne », et le README le dit comme on cite une
fiche, alors que la documentation de l'outil lui réserve 15 % du volume comme
zone de tri. La même figure revient pour le refuge au fond du volume de
Windows 95, pour le tampon de 4 Mo de XP (emprunté à une courbe d'UltraDefrag de
2018), et pour la pleine course des Barracuda que le README donne en
millisecondes alors qu'aucun manuel Seagate du dépôt n'en publie. **Hypothèse
nommée dans le code, fait dans le README** : c'est le défaut que l'audit du lot 9
avait trouvé dans les chiffres, retrouvé ici dans les affirmations.

Le reste est une liste courte de fautes d'implémentation, sept erreurs de fait
vérifiables contre un manuel ou une date, et une poignée de choses que le modèle ne
fait pas et qui s'entendent.

---

## Ce qui a été trouvé, par gravité

### Fautes — le code ne fait pas ce que son commentaire annonce

| # | quoi | où | effet |
|---|---|---|---|
| F1 | les résonateurs de la broche sont **remis à zéro à chaque bloc** pendant la rampe : `Biquad` est une `struct` qui porte `z1`/`z2`, et `updateCoefficients` réaffecte la structure entière. Le commentaire du dessus annonce « réécrits en place » ✓ | `SpindleVoice.swift:143-146`, `Biquad.swift:7-8` | le temps d'établissement à 185 Hz (Q = 7) vaut 12 ms, la longueur d'un bloc : le grave de la montée en régime ne s'établit jamais pendant la première moitié de la rampe |
| F2 | les enregistrements de MFT sont adressés à `mftLBA + n × mftRecordSectors`, comme si `$MFT` était d'un seul tenant, à partir de la disposition **du formatage** (32 enregistrements). Or la MFT se fragmente dans ce modèle (31 extents sur `famille-2003`, chantier 27), et `DiskGenerator` publie ses extents | `VolumeLayout.swift:190-199`, `:287-289` ; `BootSession.swift:891-893`, `:952-956` | au-delà du 32ᵉ enregistrement, l'adresse ne repose sur rien de ce que l'allocateur a alloué : validations, dates d'accès et lectures groupées visent un endroit où la MFT n'est pas |
| F3 | une validation FAT écrit **deux secteurs de table quelle que soit la taille du fichier**, calculés sur le seul premier cluster ✓ | `VolumeLayout.swift:262-276` | FAT32 à 4 Ko, fichier contigu de 50 Mo : 100 secteurs par copie, le modèle en écrit 2. Facteur 6 seulement en FAT16 à 32 Ko, et nul pour un fichier en miettes (un accès par extent) : c'est la passe de gros fichiers contigus qui est sous-facturée |
| F4 | la phase d'analyse d'une passe lit la MFT « d'une traite » selon son commentaire, puis plafonne à `min(mftSectors, 4_096)` — 2 Mo ✓ ; les répertoires sont lus à des clusters **tirés au hasard** (`rng.uniform(0...clusterCount-1)`) ✓ alors que `DefragVolume` connaît leurs extents ; et le minutage est en dur (`0.30 + 0.45·index`, répertoires étalés sur ~4,5 s) | `VolumeLayout.swift:422-433`, `DefragStrategy.swift:104-127` | un FAT16 de 180 Mo et un NTFS de 320 Go s'analysent dans la même poignée de secondes ; sur `famille-2007` l'analyse lit 0,16 % de la MFT. Une analyse de `dfrg.msc` se comptait en minutes |
| F5 | le bras à l'écran part **une latence rotationnelle après** le clic qu'on entend : le repère sonore est daté avant la latence, `HeadSample` après, et `Platter` reconstruit le départ à rebours | `DiskSimulator.swift:722`, `:780-783` ; `Platter.swift:298-299` | 4,2 ms en moyenne à 7 200 tr/min, 7,5 sur le Conner, au pire une demi-image. Mineur — mais porter la date du départ dans `HeadSample` rendrait visible l'attente du secteur, qui ne l'est pas |
| F6 | la journée met le disque sous tension **à froid en 1,2 s** ✓, quand le démarrage du même dépôt calcule 4,4 à 7,4 s (`post − 0,6`) et que les manuels donnent 10 s de *power-on to ready* | `Scenario.swift:592` contre `:367` | la journée est le seul endroit hors démarrage où l'on entend une montée en régime, et elle contredit l'autre. Les 0,9 s de l'installation et de la défragmentation ne sont pas concernés : pas de `coldStart`, c'est un fondu, et le code le dit |
| F7 | `DriveCatalog.dataBandInches` n'est **lu nulle part** ✓ ; son commentaire le dit « le seul paramètre du modèle qui ne vienne pas d'une fiche » et « c'est elle qui convertit une densité de pistes en nombre de cylindres » | `DriveCatalog.swift:272` | du code mort assorti d'une documentation fausse : il a trompé le premier évaluateur sur trois constats — deux réfutés, un nuancé. À supprimer ou à rebrancher |
| F8 | l'élargissement stéréo retarde le canal droit de 16 échantillons (0,333 ms) ✓ : replié en **mono**, il creuse un peigne à −18,9 dB à 1 500, 4 500 et 7 500 Hz — sur trois des sept modes du banc (1 450, 4 500, 7 200 Hz) | `SeekSynth.swift:322-332` | le mono, c'est le haut-parleur de l'iPhone et la lecture d'une vidéo de la fiche du store |

F2 et F3 sont de la famille des fautes de `LEDGER-EXPERTS.md` : l'état décrit
ne peut pas exister. F1 et F8 abîment le rendu sans rien changer au modèle, et
sont les deux corrections les moins chères de tout ce fichier.

### Erreurs de fait — vérifiables contre un manuel ou une date

| # | quoi | correction |
|---|---|---|
| E1 | `sizeBytes = sizeMB × 1 024 × 1 024` ✓, mais l'étiquette fait `sizeMB × 1e6` ✓ et les JSON portent la capacité **décimale** de la gamme : vingt-et-un volumes sur vingt-quatre sont 4,86 % plus gros que le disque affiché (`famille-2012` simule 1 048,6 Go pour le 1 To du ST1000DM003 ; un 250 Go, +7,4 %). Seuls `dev-2012` et `gamer-2012`, passés par `DiskSpec(reference:)`, sont justes | écrire les capacités en Mio (953 869, 476 940, 305 175, 238 418…) ou donner à `disk` une clé décimale. **Change tous les volumes**, donc tout ce qui s'y mesure. Effet sur le format quasi nul : les cinq FAT16 gardent leur taille de cluster, et le vrai U8 de 8,03 Gio aurait eu 8 Ko lui aussi |
| E2 | l'ancre de 1999 porte `capacityBytes: 8_420_000_000` ✓ ; le manuel qu'elle cite garantit 16 841 664 secteurs, soit **8 622 931 968 o** (`u8-pma.txt:127-129`, `:270`). Le débit interne du même manuel (285,5 Mbit/s) recoupe la valeur corrigée à 0,66, dans les « 0,65 à 0,68 » de l'en-tête du catalogue | `8_622_931_968`. Aucun nombre de têtes ne bouge sur les scénarios de 1999 ; les secteurs par piste glissent de 2,4 % |
| E3 | le ST320011A porte `20_010_332_160` ✓ — la moitié exacte du 40 Go — alors que la ligne d'à côté cite les bons 39 102 336 secteurs | `20_020_396_032`. Inaudible, gratuit |
| E4 | le 7200.10 porte `averageSeekMs: 11.0` ✓, du manuel PATA. Le manuel **SATA du même disque** (100402371, ST3320620AS : mêmes 625 142 448 secteurs, 4 têtes, 781 kBPI) publie < 8,5 / < 10,0 ms. Et le commentaire est faux deux fois : il attribue 8,5 ms aux 750 et 500 Go, que la table 1 donne aussi à < 11,0 ; et il date la fiche de 813 kBPI, qui sont ceux des tables 1 et 3, pas de la table 2 (781) | trancher entre les deux manuels **à voix haute**, comme le fait déjà la note de l'ATA IV. 8,5 rendrait `averageSeekMs(year:)` monotone — la bosse de 2005-2006 ne se voit que dans l'assistant, les vingt-quatre JSON écrivent leur seek |
| E5 | `nearest(year:)` compare en strictement inférieur ✓ : à égalité d'écart, 2007 reçoit le 7200.10 PATA déclaré avant le 7200.11, et la carte de `famille-2007` annonce « IDE » sous Vista | départager en faveur de l'année la plus récente, ou ajouter la variante AS |
| E6 | quatre logiciels installés avant leur sortie, tous posés au jour 0 : **MS-DOS 6.22** le 1ᵉʳ avril 1993 (sorti en juin 1994 ; 6.0 en mars 1993), **Quake** et **Netscape 3** le 1ᵉʳ mars 1996 (juin et août 1996), **Crysis** le 1ᵉʳ avril 2007 (novembre). `AppManifest` n'a pas d'année, `ProfileIssues` ne date que le format — le README promet « ce qui est anachronique avertit » | une année de sortie dans `AppManifest`, un `warn` dans `ProfileIssues`. Attention à 1993 : `MS-DOS 6.22 et Windows 3.1` est recopié tel quel par `readme-tables.py` (CLAUDE.md) |
| E7 | l'outil des quatre volumes de 1993 s'appelle « Windows 95 Defragmenter » : `strategy(for:)` ne regarde que le format. Celui de MS-DOS 6 est `DEFRAG.EXE`, le Speed Disk de Symantec sous licence | un libellé porté par l'année, sans toucher à l'algorithme — deux clés, pas une partagée |

### Trois écarts de modèle

Ce sont les seuls points qui demandent une décision de conception.

**Le défragmenteur de XP, et ce qui lui succède.** `WindowsXPStrategy` prend le
premier trou qui tient et passe au suivant faute de trou (`:203-213`), avec
`evacuations: 0` en dur ✓ et le commentaire « c'est exactement ce que faisait
l'outil ». La documentation de Windows Server 2003 décrit
`HKLM\SOFTWARE\Microsoft\Dfrg\FreeSpaceErrorLevel`, défaut 15 : le pourcentage
du volume qui doit être libre « pour servir de zone de tri », en dessous duquel
l'outil ne fait qu'une passe partielle et le dit. La clé établit une réserve,
pas directement une éviction — mais c'est le modèle, et non la source, qui
affirme. Trois conséquences se lisent dans les tables du README :

- **l'espace libre n'est jamais consolidé** : 35 478 trous restent sur
  `famille-2007`, 38 034 sur `famille-2012`, 20 439 sur `gamer-2012`, quand le
  rapport de `dfrg.msc` affichait la fragmentation de l'espace libre sur sa
  propre ligne. C'est le plus visible des trois ;
- **les durées NTFS ne sont opposées à aucune mesure d'époque**, contrairement
  à FAT (« une heure pour les 6 Go de 1999 »). Elles vont de 2 min 10
  (`secretaire-2003`) à 44 min 12 (`dev-2007`) : « un ordre de grandeur trop
  court », disait l'évaluateur, et le sceptique a ramené le reproche à ce qu'il
  vaut — la direction est juste, l'amplitude n'est étayée par rien, et l'analyse
  tronquée (F4) y compte autant que l'absence d'évacuation ;
- **les volumes de 2007 et 2012 reçoivent l'algorithme de XP**, verrouillé par
  `DefragPlannerTests:606-608`. KB 942092 : sous Vista, l'outil ne touche pas
  aux fragments de 64 Mo et plus, et **sait recoller la MFT**, que
  `canTouch` (`:306-308`) interdit à tous les NTFS. Les volumes de 2012
  relèvent d'une tâche de maintenance hebdomadaire sans carte de clusters.
  UltraDefrag a déjà son seuil par taille (`:131`) ; un
  `fragmentCeiling` et un choix par année suffiraient.

À la même famille appartiennent deux réglages **actifs par défaut** que l'état
livré ignore : `BootOptimizeFunction` de XP (le préchargeur passe `layout.ini`
au défragmenteur tous les trois jours) et le réordonnancement des fichiers de
programme de **Windows 98** (`TASKMON`, `APPLOG` — 1999 seulement, pas 1996).
Le README connaît les deux, dans « Ranger pour démarrer », et ne dit nulle part
que l'état livré devrait en porter la trace : les 27,3 s que le rangement
intelligent gagne sur les huit NTFS (341,3 → 314,0 s) sont en partie un gain
que la machine s'était déjà offert. Et la phrase de `Windows95Strategy.swift:8-10`
— « le seul ordre dont l'outil disposait » — est fausse pour 1999.

Enfin la **défragmentation rejouée au fil de l'histoire** (`Simulator.swift:876-906`)
est une compaction parfaite depuis le cluster 0 : zéro fragment, zéro trou,
jusqu'à cinq fois sur `secretaire-2012`. Le commentaire assume le raccourci sur
les mouvements, pas sur le résultat — qu'aucun outil d'époque ne produisait. Les
stratégies d'époque existent ; le vieillissement ne les emprunte pas.

**La pleine course.** `calibrated(averageSeekMs:trackToTrackMs:cylinders:)` ne
recale que la branche courte ; la branche longue vient de `referenceShape`
étirée, si bien que **pleine course / seek moyen vaut 1,804 pour tous les
disques**. Recalculé par deux agents sur tout le catalogue : 23,44 ms (Conner),
21,65 (Fireball), 16,06 (U8), 16,24 (ATA IV), 15,33 (7200.7, 7200.14), 6,85
(VelociRaptor).

| disque | pleine course publiée | modélisée | écart |
|---|---|---|---|
| Fireball TM, un plateau (`fireball-tm.txt:1687`) | 21,0 ms pour 12,0 de moyen — 1,75 | 21,65 | **+3 %** |
| Seagate U8 (`u8-pma.txt:363`) | 23,0 ms pour 10,5 — 2,19 | 16,06 | **−30 %** |
| Conner Cougar CP30204 (`cougar-cp30204.txt:146-150`) | 30,0 ms pour 12,0 — 2,50 | — | un proxy : ce n'est pas le CFA170A du catalogue |

La loi n'est donc pas fausse partout — elle tombe juste sur le Fireball — mais
les longues courses d'une défragmentation sont trop rapides sur le U8. Trois
choses s'y rattachent : le catalogue retient pour le U8 **8,9 ms** (table de
tête) et non les 10,5 de la table de performance du même manuel, celle qui porte
la pleine course ; le **croisement est figé à 15 % de la course**
(`crossover = 300` sur 2 000), alors que les constantes de Ruemmler & Wilkes que
le code cite se croisent vers 400 ; et le « seek moyen » est calé sur T(N/3)
quand quatre manuels du dépôt le définissent comme « a true statistical random
average of at least 5,000 measurements » — E[T] et non T(E[d]) : le disque
simulé est 2,7 à 3,9 % plus rapide que sa fiche en accès aléatoire (ATA IV 8,65
pour 9,0 ; Fireball 11,68 pour 12,0 ; 7200.14 8,18 pour 8,5). Un `fullStrokeMs`
optionnel dans `DriveReference` et un calage sur l'espérance analytique règlent
les deux. Et le README donne « 16 ms en pleine course » et « 6,85 ms » comme des
faits : ce sont des sorties du modèle, aucun manuel Barracuda n'en publie.

**La place de `$MFT`.** C'était la dernière des quatre questions « à trancher sur
source » de `LEDGER-EXPERTS.md`, restée **ouverte**. Tous les NTFS de la galerie
tombent dans la branche `.nearStart` (année ≥ 2000) : `$MFT` démarre derrière
les 64 Mio de `$LogFile`, vers le cluster 16 400, et
`dataRange = mftZone.upperBound..<clusterCount` — **aucune donnée ordinaire
avant 12,5 % du volume** tant que la zone n'a pas cédé, c'est-à-dire pendant
toute l'installation. Sur `dev-2007`, ~31 Go interdits en tête : les fichiers de
démarrage ne sont jamais sur les pistes les plus rapides. Deux sources
contredisent cette branche, dont celle que le code invoque :

- depuis Windows XP, `$MFT` est au **LCN 786 432 (0xC0000)**, soit 3 Gio en
  clusters de 4 Ko quelle que soit la taille du volume, `$MFTMirr` juste
  derrière le secteur d'amorçage, et les données remplissent les trois premiers
  gigaoctets ;
- `mkntfs.c`, cité deux fois dans `NTFSAllocator.layout`, pose `g_mft_lcn` en
  tête (à 16 Kio, lignes 3515-3524), `g_mftmirr_lcn` **au milieu du volume**
  (3567) et `g_logfile_lcn` juste derrière (3593) — c'est la branche
  `.volumeMiddle` du modèle. La zone de 12,5 % comptée depuis la MFT et son
  halving (`g_mft_zone_end >>= 1`) sont, eux, exacts.

Poser `mftStart` à `min(0xC0000, un douzième du volume)` pour XP et la suite
change l'amplitude de l'aller-retour MFT ↔ données — la signature que le README
revendique pour un démarrage NTFS — et **tous les volumes NTFS**, donc les
durées de démarrage, donc `ThinkModel`. `MFTNumbering` (rang de création, quand
NTFS reprend le plus petit enregistrement libre) est de la même pièce, et F2
aussi : à faire ensemble.

### Ce que le modèle ne fait pas, et qui s'entend

| quoi | effet attendu |
|---|---|
| **la voix de la tête est la même pour les vingt-quatre disques** : `modes` est un `let`, `SeekSynth(sampleRate:)` ne reçoit rien du disque, `load` n'écrit que `spindle.character`. Les manuels du dépôt publient pourtant la puissance acoustique **en seek** : U8 3,5 B, ATA IV 3,0 (2,4 en *quiet*), 7200.7 3,1, 7200.11 3,2, 7200.14 2,6. Le repos retranché, le seek seul vaut 3,20 B sur le U8 et 2,17 sur le 7200.14 : **10,3 dB** | un `SeekCharacter` à côté de `SpindleCharacter`. C'est le chantier d'écoute que `LEDGER-EXPERTS.md` laissait ouvert (« le sourcer changerait le son ») ; il desserrerait le coude de `gain`, qui compense aujourd'hui côté broche ce qui ne varie pas côté tête |
| **aucune gestion acoustique** : attaque en bang-bang identique de 1993 à 2012, quand un même ATA IV perd 6 dB en *quiet seek* et que les trajectoires sinusoïdales (US 6 801 384) datent de cette époque | cohérent avec la mécanique — les durées de fiche sont des *performance seeks* — donc une fonctionnalité absente, pas une erreur. À dire |
| **les disques à rampe parqués au moyeu** : `parkCylinder = cylinders − 1` ✓ pour tous. La convention est assumée (README, lot 9), mais le commentaire écrit « ou une rampe juste au-delà », ce qui est faux : sur un 3,5 pouces à *load/unload* la rampe est au **diamètre extérieur** | trois fiches `rampLoad: true` commencent et finissent leur vie par une pleine course qu'elles ne faisaient pas. `rampLoad ? 0 : cylinders − 1` |
| **secteurs de 512 octets sur le 7200.14**, que son manuel donne à 4 096 physiques (512e). Le modèle émet de lui-même des écritures plus petites — l'enregistrement de MFT fait 2 secteurs, unité de quatre points de code | chaque réécriture d'un enregistrement coûtait une lecture du bloc et **un tour** (8,33 ms) |
| **pas de serpentin** : le LBA remplit tout un cylindre avant d'en changer. Juste jusqu'au début des années 2000 ; ensuite une même tête écrit un paquet de pistes avant qu'on commute | ne mord que sur le 7200.10 (4 têtes) et le VelociRaptor (6) |
| **rien sous 760 Hz** dans la voix de la tête. Nuancé : la cible spectrale du README (88 % entre 1,5 et 8 kHz) est sourcée, et le grave passe par les haptiques, qui reçoivent les mêmes `AudioCue` | à dire plutôt qu'à faire ; c'est le préréglage « Haut-parleur » qui y gagnerait |
| **le redémarrage de la passe sous Windows 9x** (« the disk's contents have changed. Restarting… »), l'un des traits les plus mémorables de l'outil | ni modélisé ni dit |
| **rien ne survit d'une séance à l'autre** sous NT : l'éditeur de liens relit 300 `.OBJ` depuis le plateau à chaque compilation (`DaySession.swift:355-360`), sur une machine de 2003 qui les avait tous en mémoire | à dire ; un démarrage, lui, ne relit jamais deux fois le même fichier |
| **les plateaux fantômes de 1993** : `bestHeadCount` minimise sans plafond de vraisemblance, et l'ancre de 1993 est le bas de sa propre gamme. `dev-1993` et `gamer-1993` (210 Mo) reçoivent 5 têtes, `poweruser-1993` (340 Mo) 8 — le vrai CFA-340A en a 4 sur 2 plateaux. `SpindleCharacter` en tire 3 et 4 plateaux : **+0,4 B de souffle** sur `poweruser-1993` | la prémisse — « à une année donnée, tous les disques écrivent à peu près le même nombre de bits par pouce » — est fausse en 1993 : facteur 1,72 par piste entre le CFA-170A et le CFA-340A, pour un `densityHeadroom` de 1,20. Juste à partir de 2003 : le 250 Go de 2007 retombe sur les 3 têtes du manuel |

### À dire dans le README, sans rien changer

Des choix défendables, tous dits dans le code et aucun dans « Ce qui ne l'est
pas » : le rapport des rayons **figé à 0,42** (`normalizedRadius`), le même pour
les plateaux de 2,5 pouces du VelociRaptor, qui porte toute la géométrie radiale
et le souffle ; les **seize zones** ZBR à décroissance linéaire ; le skew
**exact par construction**, si bien qu'aucun franchissement ne rate jamais son
créneau (un vrai disque le quantifie en secteurs et le cale sur le pire cas — ce
qui explique peut-être le +5,7 % de débit du 7200.11) ; l'absence de **gestion
des défauts** ; la montée en régime **du premier ordre** (un moteur limité en
courant monte en tanh — la vérité est entre les deux, et c'est mineur) avec son
enveloppe en v^1,6 quand `windageBels` pose v^2,5, et ses bandes qui glissent en
`0,35 + 0,65·v` ; les répertoires et la taille moyenne comparés au terrain
(FAST'07 : 52 000 fichiers et 4 000 répertoires en médiane en 2004, 42 % de
remplissage médian) ; le tampon de 4 Mo de XP ; le refuge au fond du volume de
Windows 95, calé sur une durée et non lu dans une source ; l'absence de FAT12.

---

## Ce que les cinq voient du même endroit

1. **L'hypothèse devient un fait en passant du code au README.** XP qui
   n'évacue personne, Windows 95 qui évacue au fond, les blocs de 4 Mo, la
   pleine course des Barracuda, la zone MFT « derrière laquelle » tout se pose :
   cinq endroits où le docstring dit « hypothèse » ou « calé sur » et où le
   README conjugue au présent de vérité générale. `readme-tables.py --check`
   garde les chiffres ; rien ne garde les verbes.
2. **Les fiches sont vérifiables, et c'est pourquoi on y trouve des erreurs.**
   E2, E3 et E4 sont trois valeurs qui contredisent la source citée sur la
   ligne d'à côté. Le 7200.14, lui, est reproduit au secteur près et se recoupe
   seul à 0,7 % sur ses 210 Mo/s. Le contrôle croisé par le débit n'est armé que
   pour six fiches sur onze ; les débits internes du U8 et de l'ATA IV existent
   dans leurs manuels et recoupent à mieux que 2 % une fois E2 corrigée.
3. **Une déduction jugée deux fois.** La déduction des têtes par la densité de
   l'année est un point de fidélité remarquable en 2007 et un écart en 1993 :
   c'est le même mécanisme, et il vaut ce que vaut la dispersion des gammes de
   l'année.
4. **Le même forfait de deux secteurs vu de deux côtés** (F3) : par la revue des
   systèmes de fichiers, dans `MachineWriter` et `InstallSession` ; par celle
   des défragmenteurs, dans la validation d'un déplacement. Une seule fonction.
5. **Tout ce qui touche à un volume rouvre le calage.** E1, la place de `$MFT`,
   F2 et la population changent les vingt-quatre disques, donc les durées de
   démarrage, donc `ThinkModel` — la leçon du premier recoupement de
   `LEDGER-EXPERTS.md`, inchangée : grouper, et ne recaler qu'une fois.

---

## L'ordre des travaux

**Lot A — le son, qui ne dépend de rien.** F1 (un `setBandpass` mutant, trois
lignes), F8 (raccourcir ou décorréler le retard pour que le mono ne tombe pas
sur un mode), F6 (la rampe de la journée alignée sur celle du démarrage), puis
l'exposant de l'enveloppe. Se valide à l'oreille et au rendu hors-ligne — dont
les `md5` **doivent** changer, et seulement pour les scénarios à rampe.

**Lot B — les faits du catalogue, d'un bloc.** E2 à E7, F7. E4 demande de
ranger le manuel SATA du 7200.10 dans `disknoise.resources/manuels` avant de
trancher. E6 et E7 passent par `i18n/translations.json`.

**Lot C — les fautes de métadonnées.** F3 (la plage de secteurs de table tirée
du premier et du dernier cluster), F4 (les répertoires lus là où ils sont, la
MFT lue entière, une durée d'analyse qui dépend du volume), F5. F3 et F4
allongent les passes : refaire les tables du README après, une fois.

**Lot D — la voix de la tête par disque.** `SeekCharacter`, niveaux tirés des
`seekBels` des manuels, puis le parcage des disques à rampe. Un chantier
d'écoute, le quatrième journal d'affilée à en réclamer une.

**Lot E — la pleine course.** `fullStrokeMs` optionnel, le calage sur E[T], et
la question du U8 (8,9 ou 10,5). Déplace toutes les durées, faiblement.

**Lot F — ce qui change les volumes**, à faire ensemble et en dernier : E1,
la place de `$MFT`, F2 et `MFTNumbering`, éventuellement le plafond des têtes de
1993. Régénère les vingt-quatre disques, les 340 bilans, et rouvre `ThinkModel`.

**Lot G — les défragmenteurs d'époque.** Décider d'abord, avec Gabriel, de ce
que XP fait de sa zone de tri — une variante qui évacue, mesurée contre l'état
actuel, ou l'écart assumé par écrit. Ensuite seulement : le seuil de 64 Mo et la
MFT pour 2007 et 2012, l'état livré optimisé pour le démarrage, l'histoire
rejouée par la stratégie d'époque. À faire après le lot F, sur des volumes
justes.

**Lot H — la prose.** « Ce qui ne l'est pas » reçoit la liste plus haut, et les
cinq affirmations du premier recoupement repassent au conditionnel de leur
docstring. Peut se faire tout de suite ; se refera de toute façon après G.

---

## Ce qui est jugé juste, et qu'aucune correction ne doit casser

- **la latence rotationnelle angulaire et le skew**, déduits de la loi de seek
  du disque et partagés par `DiskMechanics` et `AccessCost`, gardés par
  `TrackSkewTests` — un point rare, et que le README ne mentionne pas ;
- **le seek d'écriture gardé en rapport** et non en millisecondes, versé au
  settle et pas à la course, avec l'hypothèse de 1993 dite ;
- **la continuité de la loi de seek au croisement**, exacte par construction
  après calibrage (`T(1) = t2t`, `T(cross) = c + e·cross`) ;
- **le 7200.14 au chiffre près**, et `referenceSPT` de 1993 qui retombe sur les
  46 secteurs par piste de TULARC (45,96) sans y avoir été poussé ;
- **les tailles de cluster comme conséquence du format** : 65 524 entrées en
  FAT16, table de `FORMAT` en FAT32 aux seuils en gibioctets, aucun `clusterKB`
  dans les vingt-quatre JSON ; et **Windows 95 OSR1 sur VFAT** en mars 1996,
  quand FAT32 n'arrive qu'en août ;
- **la zone MFT et son halving**, exacts contre `mkntfs.c` ; les répertoires
  comme de vrais fichiers au bon prix par entrée ; la date de dernier accès qui
  salit la **page de 4 Ko** et distingue 2003 de 2007 ;
- **UltraDefrag constante par constante** (`PART_DEFRAG_MAGIC_CONSTANT`, le
  `move_entirely` sous deux fois le seuil, la courbe
  `adjust_move_at_once_parameter`) et **JkDefrag avec ses défauts**
  (`GapEnd = GapBegin`, le premier qui tient et non le plus gros) ;
- **la règle du point de contrôle NTFS**, confirmée mot pour mot chez
  Russinovich, portée par le volume, publiée en sensibilité ;
- **les modes à fréquences fixes**, les trains de tics qui font une hauteur
  (108 Hz sur le Barracuda à une tête), la recalibration thermique bornée à
  1996, ni décollement ni atterrissage sur les disques à rampe ;
- **les haptiques qui reçoivent les mêmes `AudioCue`** que le moteur : elles ne
  peuvent pas dériver du son.

---

## Ce que la contre-vérification a écarté

- **`dataBandInches` comme paramètre libre du modèle**, et avec lui **les 44 g et
  1,3 m/s de l'actionneur** donnés comme point de fidélité : la constante n'est
  lue nulle part (F7), le modèle ne calcule aucune grandeur physique, et la
  reconstruction ne tient pas — 255 à 435 g sur le VelociRaptor. Ce qui reste
  du troisième constat lié : l'enveloppe à quatre phases découpe du temps et pas
  de la distance, si bien que sa « vitesse de croisière » dépend de la longueur
  du seek. Elle ne sert qu'au son.
- **Le hint `.system` de NTFS qui ramènerait les mises à jour en tête de
  volume** : `systemCursor` est monotone croissant, il ne revient jamais. Le
  défaut réel est l'inverse — les fichiers système ne réutilisent pas les trous
  derrière leur curseur — et deux commentaires du même fichier se contredisent
  (`:185-190` contre `:398-400`).
- **La population « non assumée »** : le README la dit deux fois (`:663-667`),
  `CalibrationTests` la développe. Le facteur est de 3 à 5 sur les gros volumes,
  pas de 10, et les profils `famille-*` ont des centaines de répertoires (un par
  jour d'import). Seule la comparaison au terrain est neuve.
- **Le NCQ** : la profondeur de file du modèle est 1 par construction ; à cette
  profondeur il est inerte. Le vrai réordonnancement de l'époque — l'ascenseur
  du cache d'écriture — est modélisé.
- **Le cache de seeks en quarante classes** ne sert que les seeks **isolés** ;
  les trains d'une défragmentation passent par `.chatter`, rendu sans cache. Il
  lui manque seulement `isWrite` dans la clé.
- **La racine FAT16 à 512 entrées** et **la commutation de tête à six dixièmes**
  sont assumées sur place, et déjà « en attente » dans `LEDGER-EXPERTS.md`.
- **Une citation inventée** : la phrase prêtée à Russinovich sur la zone MFT
  n'est pas dans son article, qui dit la même chose autrement
  (`STATUS_INVALID_PARAMETER`, « NTFS reserves ranges of clusters for the
  expansion of its own metadata files »). Et **tous les numéros de ligne du
  README** cités par l'évaluateur des défragmenteurs étaient faux, le contenu
  exact.

---

## Ce qui reste à trancher sur source

| question | qui en dépend |
|---|---|
| que faisait `dfrg.msc` de sa zone de tri de 15 % — évacuait-il, et consolidait-il l'espace libre ? | tout le lot G, et les douze colonnes « XP » du README |
| le LCN 0xC0000 de `$MFT` vaut-il pour tous les volumes formatés par XP, Vista et 7, ou dépend-il de la taille ? | le lot F. La question était « ouverte » ; elle a maintenant une valeur candidate, vérifiée par les agents seulement |
| 8,5 ou 11,0 ms pour le 7200.10 — deux manuels d'un même disque | E4, et l'interpolation de l'assistant |
| 8,9 ou 10,5 ms pour le U8 — deux tables d'un même manuel | la pleine course, qui n'est publiée qu'avec 10,5 |
| la pleine course du Conner CFA170A : le Cougar est un proxy | l'ancre de 1993 |
| une durée d'époque pour une passe de `dfrg.msc` sur 40 à 320 Go | la seule mesure qui départagerait F4 de l'absence d'évacuation |

---

## Laissé ouvert

- **Rien n'a été corrigé**, et rien n'a été mesuré : aucun constat n'a de test
  qui échoue. Le premier geste de chaque lot est de l'écrire.
- **Les faits externes n'ont été vérifiés que par des agents**, l'un contre
  l'autre. Le second a attrapé chez le premier une citation inventée, un compte
  faux (six fiches, pas cinq), une arithmétique fausse (cinq scénarios NTFS, pas
  six) et trois constats bâtis sur une constante morte : il n'y a pas de raison
  de croire le second infaillible. KB 942092, `FreeSpaceErrorLevel`,
  `BootOptimizeFunction`, FAST'07 et les lignes de `mkntfs.c` sont à relire
  avant d'en faire une décision.
- **Les notes ne mesurent rien.** Cinq moyennes de jugements, utiles pour
  ordonner, pas pour conclure.
- **L'interface n'a été relue que par son plateau.** Un point trouvé en passant,
  non vérifié : avec `pivotDistance = 1,35` et `armLength = 0,95`, le rayon
  minimal atteignable (0,400 R) dépasse le bord intérieur de la bande (0,399 R),
  `cosPhi` est écrêté, et le dixième intérieur de la course prend la moitié du
  balayage angulaire du bras. Et le plateau tourne dans le sens horaire, quand
  l'observation courante est antihoraire vu de dessus.
- **L'écoute**, toujours : le lot A change le son de la montée en régime, le
  lot D celui de tous les seeks, et Gabriel n'a encore rien entendu des lots 6
  et 7 de `LEDGER-EXPERTS.md`.
- **Le détail des soixante-douze constats** — pistes, sources, contre-vérifications
  in extenso — n'est pas versionné : il est rangé hors du dépôt, dans
  `../disknoise.resources/evaluations/realisme-2026-09-21/` (`resultats.json`,
  sa mise à plat `constats-et-verifications.txt`, le script du workflow et son
  journal). Ce fichier en garde ce qui se décide.

---

## Suites

### Lot A — fait (chantier 39 de `LEDGER.md`)

F1, F8 et F6 sont corrigés sur la branche `realisme`. Deux choses à retenir
ici, parce qu'elles corrigent ce fichier :

- **F1 était surestimée.** La faute est réelle, l'effet mesuré est de 20 à
  25 dB sous un signal déjà presque muet : le recalage n'a lieu à chaque bloc
  que sous 37 % du régime. Elle ne faisait pas partie des « deux corrections
  qui abîment le rendu ».
- **F6 cachait une seconde faute** : la journée comptait le POST en temps de
  calcul *après* le disque prêt. Les quatre journées du README perdent 1,8 s.

Le protocole qui a servi — état de référence, prédiction écrite, 412 bilans et
58 `md5` sonores — est décrit au chantier 39, et vaut pour les lots suivants.

### Les questions « à trancher sur source » — relues le 21 septembre 2026

Sept questions, un chercheur (opus) puis un sceptique par question ; les sept
verdicts sont **« nuancé »** : aucune citation inventée cette fois, mais des
repères faux, des conclusions trop fortes et deux erreurs de fond, toutes
attrapées. Le détail est hors du dépôt, dans
`../disknoise.resources/evaluations/realisme-sources-2026-09-21/`
(`verdicts.txt`), les sources rangées dans `../disknoise.resources/manuels` et
`sources-realisme/`.

| question | ce que les sources disent | ce qui reste une hypothèse |
|---|---|---|
| la zone de tri de XP | `FreeSpaceErrorLevel` = 15, « sorting area », attestée pour XP par son aide produit et son Resource Kit (ch. 28). La consolidation de l'espace libre est une fonction annoncée de l'outil ; le rapport la chiffrait, et le pourcentage global en était pour moitié | **aucune source ne dit qu'il déplaçait des fichiers non fragmentés** : « il n'évacue personne » et « il évacue » sont deux hypothèses à nommer |
| la MFT et le défragmenteur | **ce fichier se trompait** : le recollage de `$MFT` n'arrive pas avec Vista (KB 942092) mais dès XP — Resource Kit, ch. 13 et 28 : le premier fragment ne bouge pas ; à trois fragments ou plus, le reste est déplacé d'un bloc s'il existe un trou. `canTouch` est faux pour les douze NTFS. Et `avoidsMFTZone` devient un fait sourcé (« Neither Disk Defragmenter nor the defrag command moves files into this area ») | — |
| Vista et Windows 7 | KB 942092 (**Vista**, pas « SP1 / Server 2008 ») : fragments de 64 Mo et plus laissés en place, MFT recollée. Windows 7 garde le seuil et rend d'autres métadonnées déplaçables (billet e7) | l'absence de carte de clusters sous 7 : des commentaires de lecteurs seulement |
| `BootOptimizeFunction`, Windows 98 | `layout.ini` est nommé par Russinovich et Solomon (MSDN Magazine, décembre 2001) ; « tous les trois jours environ, au plus, à l'inactivité ». Le réordonnancement de Windows 98 (`TASKMON`, `APPLOG`) est confirmé par son Resource Kit : « 1999 seulement, pas 1996 » tient | le défaut `Enable=Y` sous XP ne vient que d'une copie tierce de `dfrg.inf` |
| la place de `$MFT` | `.nearStart` tel qu'il est codé ne correspond à **aucune** disposition attestée. `$MFT` à 3 Gio ; `$MFTMirr` au milieu sous XP et Vista, au LCN 2 sous Windows 7 ; zone MFT de 12,5 % sous XP, **200 Mo renouvelables sous Vista et 7** (KB 961095, primaire : le point le plus solide). À choisir par le champ `os` des JSON, pas par l'année | XP et Vista reposent sur une seule page (Sedory) ; la place de `$LogFile` est inconnue ; que les données occupent les 3 premiers Gio sous XP est une inférence, que la KB 961095 contredit à la lettre |
| 7200.10 : 8,5 ou 11,0 ms | les deux sont publiés pour les mêmes 625 142 448 secteurs : PATA « measured in quiet mode », SATA (100402371, rév. F et K, rangées) « in performance mode ». Le commentaire de la fiche est à corriger (781 kBPI, 78 Mo/s pour le seul 750 Go) | le mode n'explique pas tout : le ST3250410AS est à < 11,0 en mode performance. Le choix reste à Gabriel — et la galerie de 2007 tourne déjà à 8,5 par ses JSON |
| U8 : 8,9 ou 10,5 ms | **10,5** : la seule des deux valeurs qui soit définie, appariée à l'écriture et à la pleine course. Aucun scénario ne lit le `seekModel` du U8 — les quatre JSON de 1999 écrivent 9,0 : les `md5` ne bougent pas | que 10,5 vaille pour le ST38410A en particulier |
| le Conner CFA170A | **deux têtes et un plateau, 2 111 pistes** (fiche BBS Conner, TULARC), pas « 1 806 cylindres, 4 têtes » ; pleine course **25 ms** (26 sur le manuel préliminaire du CP30174, son nom d'usine). `poweruser-1993` retombe alors seul sur les 4 têtes du vrai CFA340A : **les « plateaux fantômes » sont une erreur de fiche**, pas un défaut de `bestHeadCount`, et le « facteur 1,72 » est à retirer | aucun PDF constructeur : des transcriptions recoupées |
| une durée d'époque pour `dfrg.msc` | rien entre 40 et 320 Go. Deux chronométrages seulement : Computerworld 2005 (5 Go, 3 min 56, passe inachevée) et Hofmann 2011 (50 Go à 24 %, 13 min 47) | les durées XP du README ne sont calées sur rien, et doivent le dire. Mesurer la phase d'analyse sur `famille-2007` avant de réécrire F4 : elle croît peut-être déjà avec le nombre de répertoires |
| FAST'07 | « environ 52 000 fichiers, environ 4 000 répertoires, 42 % » : §3.1 p. 33, §4.1 p. 37, §5.1 p. 41 — postes Microsoft, par volume | — |

**Ce que cela déplace dans l'ordre des travaux.** Le lot B reçoit la fiche du
Conner (têtes, pistes) — qui change les quatre volumes de 1993 par leur
géométrie, donc ne va pas dans la partie « neutre ». Le lot E reçoit deux
pleines courses publiées de plus (Conner 25 ms, U8 23 ms pour 10,5). Le lot G
commence par la MFT recollée dès XP, qui est sourcée, avant la question de
l'évacuation, qui ne l'est pas. Le lot F choisit la disposition NTFS par `os`.
