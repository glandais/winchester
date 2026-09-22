# Audit des lots réalisme (`079b244..1cd42cc`)

Audit fait en lecture seule le 22 septembre 2026. Il porte sur la plage
`079b244..1cd42cc` : les lots « Réalisme » A à H, DEFRAG de 1993, les
pourboires par achat intégré (chantier 38), les liens (chantier 37) et le
retrait de Ko-fi. Le code a été lu tel qu'il était à `1cd42cc`. Aucune mesure
n'a été lancée : ni `swift test`, ni build, ni rendu.

Un workflow de douze agents l'a mené sur six zones. Dans chaque zone, un
auditeur a relevé les constats, puis un vérificateur a cherché à réfuter
chacun d'eux. Ce vérificateur rend un verdict (CONFIRMÉ ou PLAUSIBLE) et peut
revoir la gravité. Il y a 51 constats bruts, soit 43 après dédoublonnage entre
zones : 45 sont confirmés, 6 seulement plausibles, et aucun n'est réfuté.

La numérotation `B#1` à `B#51` suit l'ordre des constats, zone après zone.
C'est celle qu'emploie l'annexe de `WINDOWS_CHECK.md`, qui croise cet audit
avec le code de Windows XP SP1. Ce croisement corrige le sens de deux
corrections proposées ici (B#6 et B#10) et en précise une troisième (B#24) :
le lire avant de traiter l'un de ces constats.

Rien n'a été corrigé depuis : à `112a9a9`, tous les constats qui touchent au
code tiennent aux mêmes lignes. Seules les lignes du README se sont décalées,
de +1 à +13.

## Synthèse

### Défauts de comportement (à traiter en priorité)

1. **`dev-2012` et `gamer-2012` ont une capacité trop petite.** Leur `sizeMB` vaut toujours `476940`, calculé en Mio, alors que `ProfileSpec.sizeBytes` fait désormais `sizeMB * 1_000_000` (`ProfileSpec.swift:139`). Les deux volumes perdent donc environ 4,6 %, soit 476,9 Go au lieu de 500,1 Go. La plage n'a corrigé que les JSON de 1996 et de 2007, et la doc de `DiskSpec(reference:)` parle encore de « Mio entiers ».
2. **Le NTFS à deux plages éparpille les fichiers dans le front** (`NTFSAllocator.swift:418`). `place` va jusqu'à `scatter` sur les 3 premiers Gio avant d'essayer la plage arrière, qui a pourtant de l'espace vierge. Un fichier est donc éclaté alors qu'il aurait pu rester contigu. À la marge, le curseur système retombe à 3 Gio à chaque fichier (l. 450).
3. **Après le recollage de la queue de la MFT par XP, les lectures visent encore l'ancienne place.** `relocateMFTTail` (`DefragVolume.swift:399`) met à jour `volume.mftExtents` mais pas `partition.mftExtents`. `mftRecordLBA` place donc les enregistrements à leur ancienne adresse, ce qui fausse les accès et le son pendant la suite de la passe XP.
4. **L'avancement de la passe XP recule.** Les phases posent `sink.progress` sur des plages fixes (0 à 0,3, puis 0,3 à 0,7, puis 0,7 à 1) et sont rappelées en boucle (`WindowsXPStrategy.swift:420/546/579`). La barre repasse ainsi de près de 100 % à 0 %, alors que LEDGER.md annonce un avancement monotone.
5. **L'analyse NTFS lit trop** (`DefragStrategy.swift:145`). Elle lit tous les `systemExtents`, c'est-à-dire les 64 Mio de `$LogFile`, `$Bitmap` et `$MFTMirr`, et elle relit `$Boot`. Les commentaires disent qu'elle ne lit que la MFT.
6. **Plus mineur :**
   - Avec un disque nommé, l'outil par défaut suit l'année du disque et non celle du système (`Scenario.swift:724`).
   - Sur un ordre autre que la taille, XP s'arrête au premier fichier qui ne trouve pas de trou. Aucun appel hors des tests n'est concerné.
   - L'état de `TipJar` survit à la fermeture de la feuille : « Merci ! » réapparaît à chaque ouverture, et « en attente » reste affiché après un Ask to Buy refusé.

### Incohérences entre l'app, le site et la doc

- **Le site dit encore « Free, with no in-app purchase »** (`docs/index.html:260`), alors que l'app vend trois pourboires. Le README dit la même chose (« gratuit, sans achat intégré », l. 1892).
- **La fiche de l'outil XP annonce « de quelques secondes à 45 min »** (`DefragToolChoice.swift:106`), alors que le README donne jusqu'à 2 h 40. La fiche de Windows 95 annonce « 6 min à 1 h », le README « de 7 s à 1 h 01 ».
- **`docs/support/index.html:154` décrit encore l'ancien XP.** Le site ne cite pas non plus MS-DOS 6 DEFRAG, ni les défragmenteurs de Vista et de 7.
- **`summary.windowsXP` a quatre `%lld` sans variations de pluriel**, ce qui donne « 1 files ». Un test fige cette forme.
- **L'avertissement d'anachronisme** ajouté dans `ProfileIssues.swift:91` est en français seul et s'affiche par `Text(String)`. C'est le cas de tous les messages de ce fichier ; la plage en ajoute un.
- **`DiskWizard` propose encore « MS-DOS 6.22 et Windows 3.1 »** alors que le nom est devenu « MS-DOS 6 ». De plus, CLAUDE.md affirme que ce nom ne s'affiche nulle part dans l'app, ce qui est faux.
- **CLAUDE.md dit encore le build 4 prêt à être soumis**, alors que les achats intégrés exigent un build 5.

### Le README après le lot H (des phrases contredites par leurs propres tables)

- **famille-2003 est à 24 % dans le README**, alors que `CalibrationTests` exige moins de 16 % et un remplissage au-dessus de 90 %. Les bilans déjà présents dans `.build` donnent 23,5 % et 88 %. Ce test échoue donc probablement ; je ne l'ai pas lancé.
- **Des phrases générées par les gabarits de `readme-tables.py` sont inversées ou cassées :**
  - « 0,1 fois plus de requêtes » (l. 1082) ;
  - « deux volumes que XP nettoie entièrement », alors qu'aucun n'arrive à 0 ;
  - « 91-91 % » ;
  - « que un occupants » ;
  - « 1 trous ».
- **La prose se contredit sur plusieurs points :**
  - Le recollage économe laisserait « moins de morceaux que chacun » des autres outils : c'est faux, 9 232 contre 4 845 et 4 311 (l. 1335).
  - Pour gamer-1993, le texte dit que « la passe ne peut rien », alors que la table montre 838 morceaux ramenés à 0 (l. 1276).
  - L'argument de la frontière contre Windows 95 ne tient plus : 58 contre 58.
- **La table du rangement intelligent (l. 1383-1403) n'a pas bougé depuis `079b244`.** Le README ne signale pas qu'elle date d'avant les lots.
- **L'arborescence du README est périmée :** la description de `WindowsXPStrategy` date d'avant le lot G, et `SeekCharacter`, `TipJar`, `AboutLinks` et `TipSheet` n'y figurent pas.

### Commentaires périmés, sans effet à l'exécution

- `SeekCharacter`, `DriveCatalog` et le test décrivent la plage de niveaux comme allant « du U8 à 1,97 », alors que le 7200.10 SATA et le VelociRaptor dépassent le U8.
- `SeekModel.swift:329` parle encore du « tiers de course, sur la branche linéaire ».
- Le commentaire de `SpindleVoice.swift:131` reprend la prémisse de F1 que le chantier 39 a réfutée.
- `FrenchUnits.swift:25` est contredit par la capacité décimale.
- La doc de `formatting(for:)` et celle de `VolumeLayout` placent la MFT « près du début ».
- Plusieurs commentaires de doc ont été détachés de leur fonction et collés au code inséré juste après :
  - dans `AcousticsTests`, la doc de `windageFollowsSpeed` ;
  - dans `DriveCatalog`, celle de `writeSeek` ;
  - dans `DriveModelTests`, celle de `strokeGrowsWithTheYears`.
- **Les commentaires et les tests restent sur l'ancien XP :**
  - des commentaires d'`UltraDefragStrategy` (« 4 Mo », « n'évacue personne ») et de `DefragStrategy` ;
  - le test `DirectoryItemsTests:85` ne vérifie plus que les répertoires restent en place.
- `LEDGER.md:7459` renvoie au chantier 37 au lieu du 40.
- `wav-md5.py` hérite de l'environnement du shell (une variable comme `STRATEGY` peut fausser une comparaison) et sort toujours à 0, même en cas d'échec.

Le son (lots A, D et E) est cohérent : l'algèbre de la loi de seek, les bornes des biquads et le stéréo milieu/côté ont été revérifiés sans trouver de défaut.


---

## Détail

Pour chaque constat : la gravité donnée par l'auditeur, puis celle du
vérificateur quand elle diffère.


## Son (lots A, D, E)

La zone SON couvre les lots A, D et E et elle est cohérente. Lot A : Biquad.setBandpass garde l'état z1/z2 des résonateurs de la broche, qui ne sont donc plus remis à zéro à chaque recalage ; la plage de fréquences reste bornée par 0,35 + 0,65·v ≥ 0,35, ce qui écarte tout pôle dégénéré. L'élargissement stéréo devient milieu/côté (side 0,6, normalisé par √1,36) : il s'annule en mono, et la corrélation annoncée de 0,47 se vérifie. Lot E : le seek moyen devient l'espérance E[T] et la loi est calée en forme fermée sur trois durées. J'ai refait l'algèbre et recalculé : rapport de la forme de référence 1,855, pleine course de l'ATA IV 16,7 ms, du VelociRaptor 7,05 ms, et b > 0, s1 > 0 sur toutes les fiches. Les gardes contre la division par zéro tiennent (c ≥ 2, dénominateur borné), les disques à rampe se parquent au bord, et le bras arrive à arrivalTime, latence purgée. Lot D : SeekCharacter applique le gain à moitié en décibels (10^(ΔB/4)) ; le headGain s'applique aux seeks, trains et tics, mais pas au décollement ni à l'atterrissage. Le synthétiseur est reconstruit au load et ses caches vidés, sans risque de concurrence : les tâches détachées capturent le synthé local. SeekCharacter.swift est bien listé dans Tools/build-render.sh, et les deux appelants de StreamingMixer sont à jour. Aucun bug de logique ni de numérique trouvé ; il reste quatre incohérences de documentation mineures.


### B#1 — SeekCharacter (et son test) annonce une plage de niveaux « de 3,20 B (U8) à 1,97 » alors que deux fiches dépassent le U8

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : doc-incoherente
- Où : `Sources/Model/SeekCharacter.swift:10`

**Constat.** La doc dit que « le bras seul va de 3,20 B sur le U8 à 1,97 sur le 7200.14 — douze décibels », ce qui laisse lire le U8 comme le maximum. Or seekOnlyBels vaut 3,64 B pour le 7200.10 SATA (3,7/2,8) et 3,60 B pour le VelociRaptor (3,7/3,0) ; le README (table l.321 et l.325) et le test lui-même (sata10.gain > u8.gain) le confirment. L'écart réel entre fiches est de 16,7 dB aux manuels et de 8,4 dB à l'écoute, pas 12 et 6. La même phrase est recopiée dans Tests/DefragKitTests/AcousticsTests.swift:79-81 et dans la doc d'Acoustics (DriveCatalog.swift:148-150).

**Scénario.** En lisant la doc, on conclut que gain ≤ 1 pour tout disque et que le U8 est le plus fort. Or la machine de 2007 (7200.10 SATA) a un gain de 1,29 (+2,2 dB) et un 10 000 tr/min de 2012 un gain de 1,26 : un réglage de mixage qui suppose un gain toujours ≤ 1 peut saturer ces deux disques.

**Vérification.** À 1cd42cc, SeekCharacter.swift:9-12 dit « le bras seul va de 3,20 B sur le U8 à 1,97 sur le 7200.14 — douze décibels ». La même phrase figure dans DriveCatalog.swift:148-150 et dans AcousticsTests.swift:79-81. Les fiches donnent pourtant plus haut que le U8 : le 7200.10 SATA (3,7/2,8, DriveCatalog.swift:506) donne 3,64 B, et les deux fiches en 3,7/3,0 (l.636, l.667, dont le VelociRaptor) donnent 3,60 B. Le README (l.316-325, avec +2,2 et +2,0 dB) et le test lui-même (`sata10.gain > u8.gain`, l.94) le confirment. L'écart réel va de 1,97 à 3,64 B, soit 16,7 dB aux manuels et 8,4 dB à l'écoute. Le README, lui, ne se trompe pas : il écrit « douze décibels entre le U8 et le 7200.14 », ce qui compare deux disques et n'annonce pas une plage. Le défaut ne touche donc que ces commentaires. Le scénario de saturation est spéculatif : aucun code lu ne suppose gain ≤ 1 (`gain = pow(10, Δ/4)`, SeekCharacter.swift:54-56). Il n'y a aucun effet sur le comportement.


### B#2 — SeekModel décrit encore le seek moyen comme « un tiers de course » après le passage à l'espérance

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : doc-incoherente
- Où : `Sources/DiskCore/SeekModel.swift:329`

**Constat.** Le lot E redéfinit averageSeekMs comme E[T], réparti sur les deux branches (≈ 28 % des seeks aléatoires tombent dans la branche courte). Plusieurs commentaires n'ont pas suivi. L.329-331 : « Le seek moyen — un tiers de course, par convention de fiche — tombe toujours au-delà du cylindre de croisement, donc sur la branche linéaire : c'est elle que règle calibrated(averageSeekMs:cylinders:) » est désormais faux. L.201 : referenceShape « ~12 ms en seek moyen (un tiers de course) », alors que E[T] = 11,85 contre T(N/3) = 12,19. L.36-37 : « ~8,7 ms en seek moyen (1/3 de course), ~18 ms en pleine course » pour un disque de 2001, alors que le README donne 16,7 ms à l'ATA IV de 2001 ; la même phrase reste au README l.182, que le lot H n'a pas reprise.

**Scénario.** Quelqu'un modifie calibrated(averageSeekMs:cylinders:) en s'appuyant sur l.329, c'est-à-dire en croyant que seule la branche longue porte le seek moyen, et ne recale que celle-ci : l'espérance s'écarte de la fiche d'autant que pèse la branche courte, soit le quart des seeks aléatoires.

**Vérification.** Le lot E a redéfini `averageSeekMs` comme une espérance (SeekModel.swift:228-240, le commentaire dit « ce n'est pas le tiers de course »). `calibrated(averageSeekMs:cylinders:)` (l.314-320) applique maintenant `timeScaled` à toute la loi, les deux branches ensemble, d'après E[T]. Or le paragraphe des l.327-338 dit encore « Le seek moyen — un tiers de course, par convention de fiche — tombe toujours au-delà du cylindre de croisement, donc sur la branche linéaire : c'est elle que règle calibrated(averageSeekMs:cylinders:) ». C'est faux depuis ce lot. Le paragraphe date d'avant la plage (base l.292) : la plage ne l'a pas écrit, mais elle l'a laissé devenir faux. Il est aussi orphelin : collé sur la doc de `headSwitch` (l.339), il ne documente plus aucune fonction, ce qui limite le risque d'induire en erreur. `referenceShape` (l.201, « ~12 ms en seek moyen (un tiers de course) ») est inexact de la même façon. Les l.36-37 et le README l.182 (« 8,7 ms en seek moyen, 1/3 de course ») datent d'avant la plage et sont restés tels quels. Ce n'est que de la doc.


### B#3 — Le commentaire de SpindleVoice reprend l'effet de F1 que le chantier 39 a mesuré comme surestimé

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : doc-incoherente
- Où : `Sources/Audio/SpindleVoice.swift:131`

**Constat.** Le commentaire ajouté affirme que, sans setBandpass, « le grave, qui met un bloc à s'établir, ne monterait jamais ». LEDGER.md (chantier 39) et LEDGER-REALISME.md (Suites, lot A) consignent le contraire : niveau identique à 0,1 dB près par demi-seconde, y compris sous 250 Hz, et un écart de 20 à 25 dB sous un signal quasi muet. Le recalage n'a lieu à chaque bloc que sous 37 % du régime, et « le grave ne s'établit jamais » y est qualifié de « calcul juste sur une prémisse fausse ». Le commentaire du code garde la prémisse fausse.

**Scénario.** Lors d'une optimisation du rendu (par exemple recalculer les coefficients moins souvent ou réinitialiser les bancs), ce commentaire fait croire à un défaut audible majeur. On écarte alors une simplification sans conséquence, ou on justifie à tort la mesure F1 comme la cause d'un problème de grave.

**Vérification.** La plage (lot A) a ajouté ce commentaire en SpindleVoice.swift:129-131 : « l'état des résonateurs survit au bloc, sans quoi le grave, qui met un bloc à s'établir, ne monterait jamais ». LEDGER.md:7026-7036 consigne le contraire : un niveau identique à 0,1 dB près par demi-seconde, y compris sous 250 Hz, un recalage à chaque bloc seulement sous 37 % du régime, et « un calcul juste sur une prémisse fausse ». LEDGER-REALISME.md:417 dit de même « F1 était surestimée ». Le code (`setBandpass`) est correct ; seul le commentaire affirme un effet audible que la mesure consignée réfute. Ce n'est que de la doc, et le scénario d'échec reste hypothétique.


### B#4 — Doc comment de windageFollowsSpeed détaché sur le nouveau test seekLevelsFollowManuals

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : test-doc
- Où : `Tests/DefragKitTests/AcousticsTests.swift:77`

**Constat.** Le test seekLevelsFollowManuals a été inséré entre la doc « Le cœur du point 1 : à plein régime, deux disques de régime différent n'ont plus le même souffle » et la fonction qu'elle documentait (windageFollowsSpeed, l.110). Le test des niveaux de tête porte donc deux paragraphes, dont un sur le souffle de la broche, et windageFollowsSpeed n'a plus de doc. Le test annonce aussi l'emprunt « 1993 et 1996 au U8 », mais ne vérifie que 1993.

**Scénario.** En lisant la suite pour savoir quel test garde « le point 1 » (le souffle selon le régime), on tombe sur un test de niveau de seek. Une régression de l'emprunt pour 1996, par exemple une fiche avec acoustique ajoutée en 1997, passerait sans échec malgré ce que le commentaire promet.

**Vérification.** Le diff de la plage insère le nouveau test juste après les deux lignes « Le cœur du point 1 : à plein régime, deux disques de régime différent n'ont plus le même souffle » (AcousticsTests.swift:77-78). Ces lignes passent donc dans la doc de `seekLevelsFollowManuals` (l.79-83), et `windageFollowsSpeed` (l.110-111) n'a plus de doc. Le commentaire des l.97-99 annonce « 1993 et 1996 au U8 », mais seul le Conner en 1993 est vérifié (l.100-101) : aucune assertion ne porte sur 1996. Comme `DriveCatalog.acoustics(year:)` prend la fiche publiée la plus proche en année (DriveCatalog.swift:735-739), une fiche avec acoustique ajoutée vers 1997 changerait l'emprunt de 1996 sans qu'aucun test n'échoue. Ce ne sont que la doc et la couverture du test.


## Catalogue et volumes (lots B, F)

Les lots B et F touchent au catalogue des disques et aux volumes. Côté catalogue : le Conner passe à un plateau (2 têtes, 2 111 pistes), les capacités Seagate deviennent les secteurs garantis × 512, une fiche SATA du 7200.10 est ajoutée, `nearest` départage les égalités d'année, `fullStrokeMs` et `Acoustics` apparaissent, et `releaseDate` sur quatre manifestes déclenche un avertissement d'anachronisme. Côté volumes : `sizeMB` devient décimal (×10⁶), et `NTFSAllocator.Formatting` (nt/xp/vista/win7) remplace `MirrorPlacement` : $MFT à 3 Gio avec des données devant elle, soit deux plages de données, et une zone de 200 Mo renouvelable pour Vista et 7. La MFT est désormais adressée à ses extents (`mftRecordLBA`), la validation FAT/NTFS couvre tous les extents, et le forfait de lecture de la MFT sort de `scanAccesses`. Constats principaux, tous tirés de la lecture du code sans aucune mesure. (1) Les JSON dev-2012 et gamer-2012 gardent une taille en Mio (476940) alors que `sizeMB` est maintenant décimal. (2) Les deux plages font que l'allocateur remplit les trous des 3 premiers Gio, en fragmentant (`scatter`), avant d'utiliser l'espace vierge derrière la zone. Cela casse aussi le curseur système. (3) La zone renouvelable exclut toute la partie centrale du volume. (4) `PartitionGeometry.mftExtents` n'est pas mis à jour après `relocateMFTTail`. Le reste concerne des commentaires et docstrings périmés. Aucun fichier n'a été ajouté à Sources/Model sans être listé dans build-render.sh : `SeekCharacter.swift` y figure.


### B#5 — dev-2012 et gamer-2012 gardent une capacité en Mio alors que sizeMB est devenu décimal

- Verdict : **CONFIRMÉ** ; gravité : haute → moyenne ; catégorie : constante-mal-reportee
- Où : `Sources/DiskCore/Resources/scenarios/dev-2012.json:28`

**Constat.** Le lot F fait de sizeMB un mégaoctet décimal (ProfileSpec.swift:139, `sizeBytes = sizeMB * 1_000_000`), et `DiskSpec(reference:)` divise maintenant par 10⁶. Or dev-2012.json:28 et gamer-2012.json:25 portent `sizeMB: 476940`, c'est-à-dire 500_107_862_016 / 2²⁰, la valeur en Mio que l'ancien `DiskSpec(reference:)` produisait pour le WD5000HHTZ. LEDGER-REALISME E1 les citait comme « les seuls justes ». Le basculement en a fait les deux seuls faux : aucun des deux JSON n'a été modifié dans la plage.

**Scénario.** dev-2012 (model WD5000HHTZ, capacityBytes 500_107_862_016) : la partition fait 476 940 000 000 octets, soit 95,4 % du disque. Environ 23 Go de plateau ne sont jamais adressés, la course utile est raccourcie d'autant, et la galerie affiche environ 444 Gio au lieu des 466 d'un 500 Go formaté. Il faudrait 500107 (ce que donnerait `DiskSpec(reference:)`).

**Vérification.** À 1cd42cc, dev-2012.json:28 et gamer-2012.json:25 portent `sizeMB: 476940` (= 500_107_862_016 / 2²⁰), et ni l'un ni l'autre n'est modifié dans la plage (seuls famille-1996, gamer-1996 et gamer-2007 le sont). ProfileSpec.swift:139 fait maintenant `sizeBytes = sizeMB * 1_000_000`, et `DiskSpec(reference:)` (l. 122) divise par 10⁶, ce qui donnerait 500107. Le LEDGER du chantier 41 décide « les JSON ne bougent pas », et LEDGER-REALISME E1:87 citait justement ces deux fichiers comme « les seuls justes », puisqu'ils étaient en Mio : la décision les a oubliés. Conséquence : une partition de 476,94 Go sur un disque de 500,1 Go (95,4 %), dont le dernier ~4,6 % de la course n'est jamais adressé. Gravité ramenée à moyenne : deux disques de la galerie sur vingt-quatre, sans plantage, et les chiffres du README ont été mesurés dans cet état.


### B#6 — Deux plages NTFS : le front de 3 Gio est pris par scatter avant l'espace vierge de derrière

- Verdict : **CONFIRMÉ** ; gravité : haute ; catégorie : logique
- Où : `Sources/DiskCore/Allocators/NTFSAllocator.swift:418`

**Constat.** `allocate` essaie `place(count, in: frontRange)` au complet avant la plage arrière. Or `place` tente tour à tour contiguousRun, preferredRun (best-fit, vierge borné au front, puis 16 fenêtres de fallback en best-fit sans tolérance sur tout le front), puis `commit(scatter(count, in: range))`. Dès que le vierge du front est épuisé, un fichier plus grand que tous les trous du front est donc éclaté sur ces trous, dès lors que leur somme suffit, sans jamais regarder le vierge derrière la zone. Cela contredit la règle de l'en-tête (l. 70-75 : « un trou n'est repris que s'il convient vraiment au fichier, ou quand le vierge est épuisé ») et la promesse de `.reservedContiguous` (« d'un seul tenant tant que le volume a un bloc capable de les accueillir »). Avant le lot F, il n'y avait qu'une plage, et scatter n'intervenait qu'en l'absence de bloc contigu sur tout le volume.

**Scénario.** XP famille-2003 (40 Go) : l'installation remplit les 3 premiers Gio, des temporaires supprimés y laissent 60 Mo de trous épars, et on télécharge un fichier de 40 Mo. Aucun trou du front ne le tient d'un seul morceau, mais leur somme suffit : il est posé en plusieurs extents devant la MFT alors que plus de 30 Go vierges restent derrière la zone. Un pagefile ou un hiberfil créé à ce moment subit le même sort.

**Vérification.** NTFSAllocator.swift:418-421 : `allocate` appelle `place` sur chaque plage, et `place` va jusqu'à `commit(scatter(count, in: range))` (l. 460) avant de passer à la plage suivante. Sur frontRange, une fois highWater au-delà du front, `virginStart = max(highWater, lower)` dépasse `range.upperBound` et le vierge est vide (l. 496-503). Les fenêtres de repli (l. 511-533) ne trouvent aucun trou ≥ count, puis `scatter` (l. 540-555) réussit dès que la somme des trous du front suffit. Le fichier est alors éclaté dans les 3 Gio alors que la plage arrière a du vierge. `.reservedContiguous` (l. 429-434) tombe dans le même chemin. Cela contredit l'en-tête (l. 70-75 : un trou n'est repris que « quand le vierge est épuisé ») et le doc de `scatter` (« le volume n'a plus un seul bloc assez grand »). Le LEDGER (chantier 41, « Laissé ouvert ») ne le mentionne pas, et l'audit de galerie ne vérifie que l'invariant d'allocation, pas ce comportement. Concerne tout volume XP, Vista ou 7 de plus de 3 Gio.


### B#7 — Le curseur système est ramené à 3 Gio à chaque fichier .system une fois le front dépassé

- Verdict : **CONFIRMÉ** ; gravité : moyenne → basse ; catégorie : logique
- Où : `Sources/DiskCore/Allocators/NTFSAllocator.swift:450`

**Constat.** Dans `place(.system)` appelé sur frontRange avec `systemCursor` déjà dans la plage arrière, firstFitRun trouve un run au-delà du front, et `run.end <= range.upperBound` échoue. La ligne 450 fait alors `systemCursor = min(max(sc, lb) + horizon, range.upperBound)` = frontRange.upperBound : le curseur recule. Sur la plage arrière, `from = max(786432, back.lowerBound)` vaut donc le début de la zone de données arrière à chaque fois. Cela annule l'intention écrite l. 446-449 (« sinon chaque mise à jour rebalaie la même zone pleine depuis le début »).

**Scénario.** Un volume XP, Vista ou 7 dont le front est plein reçoit une mise à jour de 40 fichiers système. Chacun repart en first-fit depuis la fin de la zone MFT au lieu de suivre le précédent, si bien que les fichiers système comblent les premiers trous derrière la zone au lieu d'être écrits à la suite.

**Vérification.** NTFSAllocator.swift:440-451 : quand `systemCursor` est dans la plage arrière, l'appel sur frontRange donne `from = systemCursor` ; le run trouvé échoue au test `run.end <= range.upperBound`, et la l. 450 pose `systemCursor = min(max(sc, lb)+horizon, front.upperBound)` = front.upperBound, donc le curseur recule. Sur la plage arrière, `from = max(front.upper, back.lower)` = mftZone.upperBound à chaque fois. Le first-fit repart donc du début de la zone arrière pour chaque fichier système. Gravité basse : le cas ne se produit que quand le front ne peut même pas éparpiller le fichier (voir le constat précédent, qui capte la plupart des fichiers système), et il ne change que le placement, sans aucune erreur.


### B#8 — Zone renouvelable Vista/7 : après renouvellement, tout le milieu du volume sort des plages de données

- Verdict : **PLAUSIBLE** ; gravité : moyenne → basse ; catégorie : logique
- Où : `Sources/DiskCore/Allocators/NTFSAllocator.swift:677`

**Constat.** Le renouvellement pose `mftZone = taken.end..<run.end`, avec run cherché à partir de `max(highWater, mftZone.upperBound)`, donc au bord du vierge. `dataRanges` (l. 374) définit la plage arrière comme `mftZone.upperBound..<clusterCount`. Toute la région entre la fin de la zone d'origine (3 Gio + 200 Mo) et la nouvelle tranche, c'est-à-dire l'essentiel des données, n'appartient alors plus à aucune plage. Ses trous ne sont plus jamais repris, sauf par prolongation. Quand le vierge arrière est plein, `yieldMFTZone` vide la tranche puis renvoie false, et `allocate` renvoie [] alors qu'il reste de la place libre au milieu. Aucun test ne couvre le renouvellement (`mftZoneSize` ne vérifie que la taille initiale). Les MFT de la galerie (~20 Mo) ne remplissent pas 200 Mo, donc seuls les disques personnalisés sont concernés.

**Scénario.** Un disque personnalisé Vista de 250 Go avec plus de 205 000 enregistrements au pic : la MFT remplit ses 200 Mo, et une tranche est réservée vers 60 Go. À partir de là, les suppressions entre 3,2 et 60 Go ne sont plus réutilisables. En fin de vie, les écritures échouent (failedWrites) alors que la bitmap montre des Go libres au milieu.

**Vérification.** La partie structurelle est confirmée. l. 671-677 : la nouvelle tranche est prise à partir de `max(highWater, mftZone.upperBound)` et `mftZone = taken.end..<run.end`. dataRanges (l. 374) devient alors `[frontRange, mftZone.upperBound..<end]`, et la région entre l'ancienne zone et la nouvelle tranche en sort. Le scénario d'échec est en revanche RÉFUTÉ : quand la plage arrière est pleine, `yieldMFTZone` (l. 392-406) réduit la tranche de moitié jusqu'à la vider (`lower..<lower`, retour true). À ce moment `mftZone.isEmpty` donne `back = 0..<clusterCount` (l. 374), et le placement reprend le milieu. Il n'y a donc pas de failedWrites avec des Go libres. L'effet réel se limite à des trous du milieu non réutilisés tant que la tranche n'est pas vidée, et seulement sur des disques personnalisés à plus de ~200 000 enregistrements MFT.


### B#9 — PartitionGeometry.mftExtents n'est pas mis à jour quand XP recolle la queue de la MFT

- Verdict : **CONFIRMÉ** ; gravité : moyenne ; catégorie : logique
- Où : `Sources/Model/DefragVolume.swift:399`

**Constat.** `relocateMFTTail` met à jour `DefragVolume.mftExtents` et `systemExtents`, mais `partition` est un `let` (DefragVolume.swift:214) qui garde `partition.mftExtents` posé par GeneratedVolume.swift:125. Tout `commitAccesses` / `mftRecordLBA` (VolumeLayout.swift:210, 322) postérieur à `defragmentMFT` (WindowsXPStrategy.swift:399-401) calcule donc l'enregistrement d'un fichier dont le rang tombe dans l'ancienne queue à l'ancien emplacement. Ces clusters sont libérés au point de contrôle et peuvent être réoccupés par des fichiers déplacés.

**Scénario.** famille-2003 (MFT en 31 extents) sous la stratégie XP : la queue part vers un trou unique, et un fichier de rang 20 000 est ensuite déplacé. Sa validation réécrit l'enregistrement à l'ancien LBA, dans un extent abandonné, peut-être déjà repris par un fichier, et non dans la nouvelle MFT. Le bras va donc au mauvais endroit à chaque validation qui suit.

**Vérification.** DefragVolume.swift:214 `let partition` ; `relocateMFTTail` (l. 399-413, nouveau au lot G) ne met à jour que `self.mftExtents` et `systemExtents`. `partition.mftExtents` (VolumeLayout.swift:94, posé par GeneratedVolume.swift:125 au lot F) garde les anciens extents. `mftRecordLBA` (VolumeLayout.swift:210-225), appelé par `commitAccesses` (l. 322) via `DefragOperations.commit(... partition: partition ...)` (WindowsXPStrategy.swift:368-370), situe donc tout enregistrement au-delà du premier extent dans l'ancienne queue. Ces clusters sont retenus puis libérés au point de contrôle. Les deux pièces sont introduites dans la plage. Il n'y a ni plantage ni corruption : l'effet porte sur la position du bras, donc sur le son, pour toute passe XP dont la MFT a plus de 2 extents.


### B#10 — Doc de formatting(for:) périmée : dit que le miroir remonte avec Windows 2000

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : doc-code
- Où : `Sources/DiskCore/DiskGenerator.swift:339`

**Constat.** Le commentaire dit encore « $MFTMirr est au milieu jusqu'à NT 4, ramené près du début par NTFS 3.0 — c'est-à-dire par Windows 2000 », avec l'anecdote de l'année 2000. Le code l. 352 donne `.nt` (miroir au milieu, MFT en tête) à tout profil d'avant 2001, et `Formatting` place le miroir au milieu jusqu'à Vista. Même défaut dans VolumeLayout.swift:87-88 (« près du début depuis Windows 2000 ») et VolumeLayout.swift:314-315 (« La MFT est près du début du volume, derrière les 64 Mo du journal »), alors qu'elle est à 3 Gio.

**Scénario.** Un lecteur qui se fie au docstring pour un disque personnalisé daté de 2000 attend un miroir près du début. Le code pose un NT (miroir au milieu, MFT en tête).

**Vérification.** DiskGenerator.swift:339-344 dit que le miroir est « ramené près du début par NTFS 3.0 — c'est-à-dire par Windows 2000 ». Le code l. 352 renvoie `.nt` avant 2001, et `Formatting.mirrorInTheMiddle` (NTFSAllocator.swift:106) vaut true pour tout sauf `.win7`. VolumeLayout.swift:87-88 (« près du début depuis Windows 2000 ») et l. 314-315 (« La MFT est près du début du volume, derrière les 64 Mo du journal ») sont eux aussi contredits par `$MFT` à 3 Gio depuis XP. Documentation seulement.


### B#11 — La doc de writeSeek(year:) est maintenant rattachée à acoustics(year:)

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : doc-code
- Où : `Sources/DiskCore/DriveCatalog.swift:724`

**Constat.** `acoustics(year:reference:)` a été inséré entre le commentaire de `writeSeek` (l. 724-731 : « Les seeks d'écriture… Le Conner de 1993 est le seul… une hypothèse ») et sa déclaration (l. 741). Le bloc /// fusionné documente donc `acoustics`, et `writeSeek` n'a plus de doc.

**Scénario.** Dans Xcode, l'aide rapide sur `DriveCatalog.acoustics` affiche d'abord le texte sur les seeks d'écriture et l'hypothèse du Fireball, qui ne la concerne pas.

**Vérification.** DriveCatalog.swift:724-734 : le bloc /// sur les seeks d'écriture (Conner, Fireball, hypothèse) est immédiatement suivi du doc d'`acoustics` (l. 732-734) sans ligne de code entre les deux, puis de `acoustics` (l. 735). `writeSeek` (l. 741) n'a plus de doc. Documentation seulement.


### B#12 — Doc de DiskSpec(reference:) : « capacité en Mio entiers » alors qu'elle divise par 10⁶

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : doc-code
- Où : `Sources/DiskCore/ProfileSpec.swift:119`

**Constat.** Le commentaire dit « la capacité en Mio entiers ». Le code l. 122 divise par 1_000_000 depuis le lot F.

**Scénario.** Quelqu'un qui écrit un JSON d'après ce commentaire y met des Mio : c'est exactement l'erreur restée dans dev-2012 et gamer-2012.

**Vérification.** ProfileSpec.swift:119-120 dit « la capacité en Mio entiers », alors que la l. 122 fait `reference.capacityBytes / 1_000_000`. Cette doc périmée est cohérente avec l'oubli de dev-2012 et gamer-2012 (premier constat).


### B#13 — Nouvel avertissement d'anachronisme en français seul, affiché par Text(String)

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : traduction
- Où : `Sources/DiskCore/ProfileIssues.swift:91`

**Constat.** Le message ajouté « « X » ne sort que le AAAA-MM-JJ : il est installé avant. » est une String française avec une date ISO. Il est affiché par `Text(issue.message)` (DiskWizard.swift:811), donc sans traduction, ce qui contredit la règle de CLAUDE.md. Les autres messages de ProfileIssues ont le même défaut, mais celui-ci a été ajouté dans la plage.

**Scénario.** Appareil en anglais, assistant de disque réglé en 1996 avec Quake : le panneau affiche « « Quake » ne sort que le 1996-06-22 : il est installé avant. » en français.

**Vérification.** Le diff de la plage ajoute à ProfileIssues.swift:87-93 `warn("« \(manifest.displayName) » ne sort que le \(released) : il est installé avant.")`. `ProfileIssue.message` est une `String`, affichée par `Text(issue.message)` (DiskWizard.swift:811), donc en verbatim, sans traduction. Gravité basse : tous les autres messages de ProfileIssues (DiskCore) sont déjà français et affichés de la même façon. Le défaut est hérité, et la plage l'étend à un message de plus. Le test ProfileIssuesTests.swift:63 affirme d'ailleurs le libellé français.


### B#14 — Commentaire de test contredit par son corps (ProfileIssuesTests)

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : test
- Où : `Tests/DiskCoreTests/ProfileIssuesTests.swift:49`

**Constat.** Le docstring dit que quatre logiciels de la galerie sont installés avant leur sortie et qu'« il le fait donc sur ces profils-là, jusqu'à ce que leurs dates bougent ». Le corps affirme l'inverse : aucun profil de la galerie n'avertit, puisque les dates ont bougé au lot F. De même, DriveModelTests.swift:173 dit « le 7200.10 SATA, daté 2007 » alors que la fiche est de 2006. Et les tests insérés l. 144-148 ont séparé de sa fonction la doc de `strokeGrowsWithTheYears` (l. 141).

**Scénario.** Un lecteur du test croit que la galerie doit avertir, alors que le test échouerait si c'était le cas.

**Vérification.** ProfileIssuesTests.swift:49-52 dit que la galerie avertit « sur ces profils-là, jusqu'à ce que leurs dates bougent », alors que les l. 55-59 affirment qu'aucun profil de la galerie n'avertit. DriveModelTests.swift:173 dit « le 7200.10 SATA, daté 2007 », alors que DriveCatalog.swift:501 donne `year: 2006` à ST3320620AS. DriveModelTests.swift:141-142 (« Et à capacité d'époque, c'est la course qui explose… ») est collé au doc du test Seagate inséré l. 143-148 et n'est plus attaché à `strokeGrowsWithTheYears` (l. 182). Les assertions restent justes : seuls les commentaires sont faux.


## Défragmenteur de XP (lot G)

Le lot G (5eedbf9) réécrit WindowsXPStrategy d'après DefragNtfs de XP SP1. La MFT est recollée avant et après la passe (DefragVolume gagne mftExtents et relocateMFTTail). Les fichiers cassés sont réparés par taille croissante, en best fit, avec arrêt au premier fichier sans trou (MinimumLength). Viennent ensuite la consolidation d'une région occupée à moins de 75 %, abandonnée au-delà de dix échecs, le vidage de la zone MFT, le tassement vers l'avant, des blocs de 64 Kio, et un seuil de 64 Mo daté pour Vista et 7. Les boucles sont bornées à 32 tours, ce qui garantit la terminaison. Les tris de fichiers sont totaux. Je n'ai trouvé ni cluster perdu ou dupliqué, ni index hors bornes dans les listes de trous (takeBestFit, byStart). Les défauts réels : la MFT déplacée n'est pas reportée dans la géométrie qui adresse ses enregistrements ; l'avancement affiché recule ; filesAlreadyInPlace compte aussi des fichiers qui bougent. Côté documentation, la page support du site, la fourchette de durée de la carte, deux phrases du README produites par readme-tables.py et plusieurs commentaires ou tests décrivent encore l'ancien XP qui « n'évacue personne ». Tout a été lu à 1cd42cc, sans rien modifier ni mesurer.


### B#15 — MFTDefrag déplace la queue de la MFT, mais les validations visent encore son ancienne place

- Verdict : **CONFIRMÉ** ; gravité : haute → moyenne ; catégorie : correctness
- Où : `Sources/Model/DefragVolume.swift:399`

**Constat.** relocateMFTTail met à jour volume.mftExtents et systemExtents, mais pas volume.partition.mftExtents. DefragVolume.partition est un `let` (DefragVolume.swift:214), rempli depuis disk.mftFileExtents par GeneratedVolume.swift:124-125. Or DefragOperations.commit → partition.commitAccesses → mftRecordLBA (VolumeLayout.swift:210, 322, 359) calcule le secteur d'un enregistrement de MFT à partir de ces anciens extents. Après pass.defragmentMFT() (WindowsXPStrategy.swift:181, 401), chaque validation d'un enregistrement au-delà du premier extent écrit donc à l'ancienne place de la queue. Ces clusters ont été rendus au point de contrôle et peuvent être devenus la destination d'autres fichiers. Aucun test ne couvre defragmentMFT ni relocateMFTTail : grep sur Tests ne trouve rien, et swapAndMetadataAreLeftAlone modélise la MFT comme un fichier `.reserved`.

**Scénario.** famille-2003, dont la MFT a 31 extents, avec l'outil de XP. defragmentMFT déplace la queue d'un bloc vers le premier trou. Ensuite, chaque déplacement d'un fichier dont l'enregistrement n'est pas dans le premier extent émet son écriture de MFT vers l'ancien extent de queue. Le bras va là où la MFT n'est plus, parfois sur des clusters qu'un fichier réparé vient d'occuper, au lieu de l'extent neuf.

**Vérification.** À 1cd42cc : DefragVolume.swift:214 `let partition: PartitionGeometry`. relocateMFTTail (l.399-413) ne met à jour que volume.mftExtents et systemExtents. partition.mftExtents est rempli une fois par GeneratedVolume.swift:124-125 (disk.mftFileExtents), et volume.mftExtents par la l.200 depuis la même source. Ensuite, WindowsXPStrategy.move (commit, fileIndex: volume.mftRecord(of:), soit 16+position) → DefragStrategy.swift:511 partition.commitAccesses → VolumeLayout.swift:322 mftRecordLBA (l.210-224), qui parcourt les anciens extents. defragmentMFT est appelée aux l.181 et 215, avec la garde extents.count > 2. Sur un NTFS dont la MFT a plus de deux extents (famille-2003 : 31), chaque validation d'un enregistrement situé au-delà du premier extent écrit donc à l'ancienne place de la queue. Aucun test n'appelle defragmentMFT ni relocateMFTTail (git grep sur Tests). L'effet est une position de bras fausse, donc un son faux, sans plantage : gravité ramenée à moyenne.


### B#16 — L'avancement de la passe XP recule de près de 100 % à 0 % à chaque tour

- Verdict : **CONFIRMÉ** ; gravité : moyenne ; catégorie : correctness
- Où : `Sources/Model/WindowsXPStrategy.swift:420`

**Constat.** Chaque phase remet sink.progress sur une plage fixe : defragmentFiles de 0 à 0,3 (l.420), empty de 0,3 à 0,7 (l.546), moveFilesForward de 0,7 à 1 (l.579). Ces phases sont rappelées dans les boucles intérieure et extérieure (l.192-214). PassPipeline enregistre toute variation d'au moins 0,001, y compris vers le bas (PassPipeline.swift:423), et LivePass.progress rend la dernière marque. PassScreen.swift:193 et 209 affichent ce pourcentage et cette barre. L'ancienne passe n'avait qu'une boucle, dont l'avancement était monotone.

**Scénario.** Un volume où la première défragmentation laisse des fichiers cassés. Le tour 1 va de 0 à 0,7, puis la seconde defragmentFiles du même tour ramène la barre à 0 %. Après le tassement (0,7 à 1), le tour suivant la ramène encore à 0 %. Sur dev-2007 (2 h 40), l'écran annonce plusieurs fois près de 100 % puis repart de zéro.

**Vérification.** WindowsXPStrategy.swift:420 (0..0,3), 546 (0,3..0,7) et 579 (0,7..1) posent sink.progress sur des plages fixes, et ces phases sont rappelées dans les boucles des l.192-213. OperationSink.progress (OperationSink.swift:47) est un simple var, sans clamp. PassPipeline.swift:423 enregistre |Δ| ≥ 0,001 dans les deux sens, LivePass.swift:283 rend la dernière marque, et SimulationModel.defragProgress puis PassScreen.swift:193/209 l'affichent. À 079b244, l'unique `sink.progress = rank/count` (l.189) était monotone. LEDGER.md:2814 revendique un « avancement monotone ».


### B#17 — filesAlreadyInPlace compte des fichiers qui seront déplacés, et des intouchables

- Verdict : **PLAUSIBLE** ; gravité : moyenne → basse ; catégorie : correctness
- Où : `Sources/Model/WindowsXPStrategy.swift:293`

**Constat.** alreadyInPlace est figé à l'init : tous les fichiers contigus de taille non nulle, y compris le fichier d'échange et les `.reserved` que canTouch exclut. Il inclut aussi ceux que la consolidation et le tassement déplacent ensuite. Les autres stratégies comptent « déplaçables moins touchés » (FrontierCompaction:142, JK:313, Smart:110), et l'ancien XP ne comptait que les fichiers canTouch non déplacés. Le bilan (Tools/Shared/Report.swift:45, « N déjà en place ») additionne donc des fichiers comptés deux fois. Les tests affirment ce double compte : brokenFilesFirstThenPacking (DefragPlannerTests.swift:690, 694) veut filesAlreadyInPlace == 2 alors que l'application a été ramenée vers le début, et hugeVolumeStaysTractable (l.923) veut 12 000 alors que le tassement déplace ces mêmes fichiers.

**Scénario.** hugeVolumeStaysTractable : 12 000 documents contigus, tassés vers l'avant par moveFilesForward. Le plan annonce filesMoved ≥ 250 + milliers et filesAlreadyInPlace = 12 000, soit plus de fichiers traités qu'il n'y en a sur le volume.

**Vérification.** WindowsXPStrategy.swift:293 : `alreadyInPlace = volume.files.filter { $0.isContiguous && $0.clusterCount > 0 }.count`, figé à l'init, sans canTouch, donc fichier d'échange et `.reserved` compris. Il n'est pas réduit quand moveFilesForward ou empty déplacent ces fichiers. L'ancien XP (079b244 l.187-196) ne comptait que les candidats contigus qu'il sautait. Les tests DefragPlannerTests.swift:690 et 923 figent bien le chiffre alors que les fichiers sont tassés. Le compte « contigus au départ » peut toutefois se défendre comme une définition (UltraDefragStrategy.swift:172 fait de même, avant de déplacer), et rien ne l'affiche dans l'app hors du bilan de Tools/Shared/Report.swift:45. Il y a donc une incohérence de sens, plutôt qu'un calcul faux.


### B#18 — Le site décrit toujours l'ancien XP qui ne répare qu'en place

- Verdict : **CONFIRMÉ** ; gravité : moyenne ; catégorie : doc-incoherence
- Où : `docs/support/index.html:154`

**Constat.** Le lot G a réécrit tool.windowsXP.principle et tool.windowsXP.sound, et docs/index.html:174 a suivi. La page support dit encore : « only repairs files in pieces, by copying them into a hole that is already free. Short and calm; it gives up when no hole is the right size. » Le CLAUDE.md exige que chaque libellé cité sur le site soit l'unité `en` du catalogue.

**Scénario.** Un visiteur de glandais.github.io/winchester/support lit que XP ne déloge personne et reste court. L'app affiche au contraire « empties a region when none does; then packs everything » et des passes XP de plus de deux heures.

**Vérification.** docs/support/index.html:154 à 1cd42cc : « only repairs files in pieces, by copying them into a hole that is already free. Short and calm; it gives up when no hole is the right size. » Le catalogue tool.windowsXP.principle (en) dit pourtant « Repairs files in pieces, smallest first, into the smallest hole that fits; empties a region when none does; then packs everything towards the start. », et docs/index.html:174 a été mis à jour. docs/support a été touché dans la plage (9 lignes ajoutées), sans cette ligne. Cela contredit la règle du CLAUDE.md : chaque libellé cité sur le site est l'unité `en` du catalogue.


### B#19 — La carte de l'outil XP annonce « a few seconds to 45 min », alors que les passes durent jusqu'à 2 h 40

- Verdict : **CONFIRMÉ** ; gravité : moyenne ; catégorie : doc-incoherence
- Où : `Sources/UI/DefragToolChoice.swift:106`

**Constat.** tool.windowsXP.ntfs.measured porte le commentaire « Fourchette mesurée sur les vingt disques de la galerie ». Elle n'a pas été reprise après le lot G. La table du README (l.1012-1023) donne 2 h 18 (gamer-2007), 2 h 40 (dev-2007), 2 h 11 et 2 h 12 (2012). Le LEDGER, chantier 45, note que les durées XP montent de 2 à 3 fois.

**Scénario.** Sur la carte « Avec quel outil ? » de dev-2007, le défragmenteur de Vista est présenté comme durant au plus 45 min. La passe lancée en dure 2 h 40.

**Vérification.** DefragToolChoice.swift:106 : measured [.ntfs] = « a few seconds to 45 min » (fr « de quelques secondes à 45 min »), avec le commentaire « Fourchette mesurée sur les vingt disques ». La table du README à 1cd42cc (l.~1012-1023) donne 55 min 23 (secretaire-2007), 2 h 18 (gamer-2007), 2 h 40 (dev-2007), 2 h 11 et 2 h 12 (famille et gamer-2012), 1 h 10 (dev-2012). La fourchette n'a pas été reprise après le lot G. L'écran de choix sous-estime la durée d'un facteur 3 ou plus.


### B#20 — Deux phrases du README produites par readme-tables.py se retournent avec le nouvel XP

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : doc-incoherence
- Où : `README.md:1082`

**Constat.** readme-tables.py:396 écrit « Le prix est {u/x} fois plus de requêtes et {u/x} fois plus de temps ». UltraDefrag coûte désormais moins que XP, d'où « 0,1 fois plus de requêtes et 0,7 fois plus de temps » : la comparaison est inversée, et `--check` ne vérifie que le nombre. À la l.1096, « Des deux volumes que XP nettoie entièrement, il nettoie l'un aussi » n'est plus vrai. La table (l.1072-1076) montre que XP laisse 4, 2, 4 et 2 morceaux sur secretaire-2007, dev-2007, secretaire-2012 et dev-2012 ; seul gamer-2003 finit à 0. Le « 93 » de la phrase désigne dev-2007, où XP laisse 2 morceaux.

**Scénario.** Le lecteur du README apprend qu'UltraDefrag coûte « 0,1 fois plus » de requêtes que XP sur famille-2007. En réalité il en fait 8 fois moins (151 444 contre 1 196 949). Il lit aussi que XP nettoie entièrement deux volumes, alors que la table juste au-dessus dit le contraire.

**Vérification.** README.md:1082 : « Le prix est 0,1 fois plus de requêtes et 0,7 fois plus de temps ». Le gabarit est fixe (readme-tables.py, prose « Le prix est {rq} fois plus… » avec u/x), alors que la table donne 1 196 949 → 151 444 requêtes : UD en fait 8 fois moins, la phrase est inversée. README.md:1095-1096 : « Des deux volumes que XP nettoie entièrement, il nettoie l'un aussi, et laisse 93 morceaux sur l'autre ». La table de la même section donne pour XP 4 (secretaire-2007), 2 (dev-2007), 4 (secretaire-2012) et 2 (dev-2012) morceaux restants, et seul gamer-2003 finit à 0. Le 93 est celui d'UD sur dev-2007, où XP laisse 2 morceaux. --check ne vérifie que les nombres.


### B#21 — Les ordres autres que la taille arrêtent la réparation au premier fichier sans trou

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : correctness
- Où : `Sources/Model/WindowsXPStrategy.swift:425`

**Constat.** Le `break` sur l'échec de takeBestFit, et le compte `remaining += candidates.count - rank`, reposent sur « les suivants sont plus gros ». Cette hypothèse n'est vraie que pour `.sizeThenRecord`. Or la doc de `order` (l.132-138) présente les autres ordres comme rejoués « avec le même placement » pour mesurer le coût d'un ordre de passage seul. Avec mostFragmented, mftRecord, diskPosition ou directoryWalk, un gros fichier sans trou fait sauter tous les petits qui suivent, ce qui change aussi le nombre de fichiers réparés.

**Scénario.** order = .mostFragmented. Le premier candidat est un fichier de 500 clusters en 40 morceaux, sans trou à sa taille. La phase s'arrête et vingt fichiers de 2 clusters, qui tenaient dans des trous libres, ne sont pas tentés dans ce tour. La comparaison attribue à l'ordre un effet qui vient de l'arrêt anticipé.

**Vérification.** WindowsXPStrategy.swift:425-431 : sur un échec de takeBestFit, `remaining += candidates.count - rank; break`, justifié par « les suivants sont plus gros ». Ce n'est vrai que pour .sizeThenRecord, alors que la doc de `order` (l.132-138) promet les autres ordres « avec le même placement ». Avec .mostFragmented, un gros fichier sans trou fait sauter tous les petits qui suivent. Portée limitée : aucun appel hors Tests ne change `order` (git grep, seul DefragPlannerTests.swift:1074). Aucun effet sur l'app ni sur les mesures consignées. Le seul test concerné (theWorstFileGoesFirst) n'affirme que le premier fichier servi, il n'est donc pas affecté.


### B#22 — Commentaires et tests qui affirment encore l'ancien comportement de XP

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : doc-incoherence
- Où : `Sources/Model/UltraDefragStrategy.swift:38`

**Constat.** UltraDefragStrategy.swift:38 dit « Comme la passe de XP, elle n'évacue personne ». Sa l.121 dit « WindowsXPStrategy retient 4 Mo », alors que c'est maintenant 64 Kio. DefragStrategy.swift:62 dit que « 0 évacuation » est le principe d'un outil qui ne déloge personne, sur une passe XP. Dans DefragPlannerTests.swift : le test de la l.571 s'intitule « n'est pas défragmenté » alors qu'il vérifie un fichier déplacé et recollé (l.584) ; la l.591 dit que la zone MFT est « une hypothèse » alors que avoidsMFTZone dit « un fait de la source » ; les l.829-831 disent que la MFT « ne se réorganise pas à chaud », ce que contredit MFTDefrag ; la l.1030 dit que XP suit les numéros d'enregistrement de la MFT, alors qu'il trie par taille.

**Scénario.** Un lecteur qui se fie à ces commentaires croit XP sans évacuation, à 4 Mo et sans MFTDefrag. Il peut alors « corriger » le code dans le mauvais sens, ou juger couvert le recollage de la MFT, qu'aucun test n'exerce.

**Vérification.** À 1cd42cc : UltraDefragStrategy.swift:38 « Comme la passe de XP, elle n'évacue personne ». UltraDefragStrategy.swift:121 « WindowsXPStrategy retient 4 Mo », alors que bufferBytes vaut 64*1024 (WindowsXPStrategy.swift:~89). DefragStrategy.swift:60-63 (« 0 évacuation… principe d'un outil qui ne déloge personne… sur une passe XP »). DefragPlannerTests.swift:590-591 « c'est une hypothèse », contredit par avoidsMFTZone : « c'est un fait de la source ». DefragPlannerTests.swift:829-831 « la MFT ne se réorganise pas à chaud », contredit par MFTDefrag. DefragPlannerTests.swift:1030 « XP suit les numéros d'enregistrement », alors que l'ordre par défaut est .sizeThenRecord. S'y ajoute DefragPlannerTests.swift:652, dont le message dit « une passe qui n'évacue rien ». Ce sont des commentaires sans effet sur le code.


### B#23 — summary.windowsXP porte quatre %lld sans variations de pluriel, et le test fige « 1 files »

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : i18n
- Où : `Sources/Model/WindowsXPStrategy.swift:243`

**Constat.** La clé a été réécrite dans le lot G avec quatre arguments entiers (%1$lld à %4$lld). Le catalogue ne donne qu'une stringUnit simple, en `en` comme en `fr`, sans variations de pluriel, ce que le CLAUDE.md impose pourtant pour toute clé à %lld. Le test eachStrategyNarratesItsOwnCounters (DefragPlannerTests.swift:651) affirme même la chaîne agrammaticale « repairs 1 files out of 1 ». La règle n'est pas non plus appliquée à 42 autres clés du catalogue, antérieures à la plage.

**Scénario.** Une passe XP qui ne déloge qu'un fichier affiche « evicts 1 files … — 1 files moved in all ». En français : « en déloge 1 … 1 fichiers déplacés en tout ».

**Vérification.** Dans Localizable.xcstrings à 1cd42cc, summary.windowsXP n'a qu'un stringUnit simple en en et en fr pour %1$lld à %4$lld, sans `variations.plural`. Le CLAUDE.md l'exige pour toute clé à %lld. DefragPlannerTests.swift:651 affirme « repairs 1 files out of 1 ». Le défaut est antérieur (079b244 : la clé avait déjà deux %lld sans pluriel), mais la plage a réécrit la clé et y a ajouté deux entiers sans corriger. Il est visible sur une petite passe : « 1 files moved in all », « 1 fichiers déplacés ».


## Métadonnées et sessions (lot C, DEFRAG 1993)

Cette zone couvre le lot C (fautes de métadonnées), le renommage DEFRAG de 1993 et les retouches de session des lots A, B, D, E et F. Côté FAT, `commitAccesses(for:)` réécrit maintenant la chaîne entière. Le NTFS lit la bitmap sur toute la longueur de chaque extent, et l'enregistrement de MFT est lu à ses extents par `mftRecordLBA`. L'analyse ne passe plus par un forfait et lit ce que le volume porte. `HeadSample.latency` fait arriver le bras avant le secteur. Le démarrage et la journée prennent désormais la même montée en régime (`Era.spinUpDuration`), et `DayPlanner` ne compte plus le POST une seconde fois. `Windows95Strategy`, `WindowsXPStrategy` et la fiche d'outil prennent l'année du disque. Le rapport de cache (« dont N relues après éviction ») est intact, et « MS-DOS 6 et Windows 3.1 » est cohérent entre le code, le README et CLAUDE.md. Il reste pourtant un vrai défaut de modèle : l'analyse NTFS lit tous les `systemExtents`, dont les 64 Mio de `$LogFile`, si bien que les chiffres du LEDGER annoncés « de MFT » incluent le journal. S'y ajoutent une année d'outil prise sur le disque et non sur le système dans le chemin par défaut, et plusieurs textes restés en retard après les lots C, F et G (fiches d'outil, page support, commentaires, CLAUDE.md).


### B#24 — L'analyse NTFS lit tout $LogFile (64 Mio), $Bitmap, $MFTMirr et relit $Boot, pas seulement la MFT

- Verdict : **CONFIRMÉ** ; gravité : haute → moyenne ; catégorie : correctness
- Où : `Sources/Model/DefragStrategy.swift:145`

**Constat.** `analysis(volume:)` parcourt `volume.systemExtents`, qui vaut `[bootExtent] + mft.extents + [mftMirror, logFile, volumeBitmap]` (NTFSAllocator.swift:361-363, transmis tel quel par DiskGenerator.swift:380 puis GeneratedVolume.swift:199). Le commentaire (l.136-139) annonce pourtant « La MFT, sa copie et le secteur d'amorçage », et le LEDGER « la MFT se lit là où le volume la porte ». Le journal de 64 Mio (tout NTFS de plus de 12 Gio) se lit donc à chaque passe. `$Boot` se lit deux fois : `scanAccesses` le lit déjà (startLBA, 16 secteurs). Le champ `DefragVolume.mftExtents` (les extents de $MFT seule) existe et n'est pas utilisé ici. Les chiffres consignés en portent la trace : « secretaire-2003 3,3 s pour 80 Mo de MFT », « famille-2012 … 134 Mo » (LEDGER.md:7239-7240), environ 64 Mo de journal compris. Le test `analysisReadsWhatIsThere` ne le voit pas, parce qu'il fabrique des `systemExtents` qui ne contiennent que de la MFT. Le commentaire de `DefragVolume.systemExtents` (DefragVolume.swift:232, « la MFT, sa copie, le secteur d'amorçage ») est lui aussi inexact.

**Scénario.** Passe XP sur secretaire-2003 (40 Go, $LogFile de 64 Mio derrière le miroir) : la phase 0 émet une lecture de 131 072 secteurs sur le journal, que dfrg.msc ne lit pas. L'analyse dure environ 3,3 s au lieu d'environ 0,5 s pour la seule MFT d'environ 16 Mo, et le bilan attribue à la MFT des mégaoctets qui sont du journal.

**Vérification.** Sources/Model/DefragStrategy.swift:145-149 (à 1cd42cc) lit chaque extent de `volume.systemExtents`. Cette liste vaut `[bootExtent] + mft.extents + [mftMirror, logFile, volumeBitmap]` (Sources/DiskCore/Allocators/NTFSAllocator.swift:361-363). DiskGenerator.swift:380/414 la transmet telle quelle, puis GeneratedVolume.swift:199. $LogFile fait 64 Mio dès 12 Gio de volume (NTFSAllocator.swift:327). $Boot est déjà lu par `scanAccesses` (VolumeLayout.swift:470, startLBA sur 16 secteurs), puis relu par l'extent `bootExtent` : il est donc lu deux fois. Deux commentaires sont faux. DefragStrategy.swift:136 annonce « La MFT, sa copie et le secteur d'amorçage ». DefragVolume.swift:231-232 dit la même chose. `mftExtents` (DefragVolume.swift:241-246), la liste des extents de la seule $MFT, existe mais n'est pas utilisé ici. Le test analysisReadsWhatIsThere (DefragPlannerTests.swift:141-144) ne passe que des extents « MFT » synthétiques et ne voit pas le défaut. Les chiffres de LEDGER.md (« secretaire-2003 3,3 s pour 80 Mo de MFT ») collent avec 64 Mio de journal plus environ 16 Mo de MFT, miroir et bitmap. Gravité ramenée à moyenne : pas de plantage, le défaut allonge la phase 0 et l'attribue à tort à la MFT. Le chiffre de « 0,5 s » avancé dans le scénario est une estimation, il n'a pas été vérifié.


### B#25 — Chemin par défaut : l'outil et le seuil de 64 Mo suivent l'année du disque nommé, pas celle du système

- Verdict : **CONFIRMÉ** ; gravité : moyenne → basse ; catégorie : correctness
- Où : `Sources/Model/Scenario.swift:724`

**Constat.** `assembleDefrag` choisit `DefragPlanner.strategy(for: partition.format, year: hardware.year)`. Pour un disque nommé, `DriveHardware.year` vaut `reference.year`, l'année de la fiche, et le commentaire de DriveHardware (GeneratedVolume.swift:302-306) dit justement que ce n'est pas l'âge du logiciel. Or `prepared()` (Scenario.swift:693-707) et l'écran de choix (DefragToolChoice.swift:199 et 207) datent l'outil par `disk.spec.timeline.start.year`. Les deux chemins peuvent donc donner deux outils différents pour le même disque : nom (DEFRAG, 95, XP, Vista, 7) et `fragmentCeilingBytes`. Ce chemin sert à `rendertrace` et aux mesures sans STRATEGY (ScenarioRequest.swift:122, `strategy()` nil), à `DRIVE=` que le README documente (l.169, l.1640), et à `SimulationModel.load(... using: nil)`.

**Scénario.** `DRIVE=VelociRaptor SCENARIO=dev-2003 /tmp/rendertrace out.wav` : le VelociRaptor est de 2008, donc hardware.year = 2008 ≥ 2007. La passe devient « Windows Vista Defragmenter » avec le seuil de 64 Mo sur un disque XP de 2003, alors que ScenarioRequest dit « pour que seul le disque change ». À l'inverse, une fiche de 1993 posée dans un profil de 1996 via l'assistant afficherait « MS-DOS 6 DEFRAG » sous Windows 95.

**Vérification.** Scenario.swift:724 : `chosen ?? DefragPlanner.strategy(for: partition.format, year: hardware.year)`. Le paramètre `year:` a été ajouté dans la plage. Pour un disque nommé, GeneratedVolume.swift:256 renvoie `year: reference.year`. `prepared()` (Scenario.swift:693-707) date au contraire l'outil par `disk.spec.timeline.start.year`. Le scénario du relecteur contient une erreur : le VelociRaptor est de 2012 dans le catalogue (DriveCatalog.swift:628/659), pas de 2008. Le défaut se reproduit quand même par la commande que documente README.md:1640, `DRIVE=VelociRaptor SCENARIO=gamer-2007`. La timeline est de 2007, hardware.year vaut 2012, la passe s'intitule donc « Windows 7 Defragmenter » au lieu de Vista. Le seuil ne change pas, puisque les deux années sont ≥ 2007. `DRIVE="Barracuda 7200.11"` (2008) sur dev-2003 donnerait Vista et le plafond de 64 Mo sur un disque XP. Dans la galerie, les seuls disques nommés sont dev-2012 et gamer-2012 (VelociRaptor de 2012, timeline 2012) : aucun écart. L'app passe l'outil par l'écran de choix. Le défaut ne touche donc que les outils avec DRIVE= ou sans STRATEGY sur un disque nommé d'une autre année, d'où la gravité basse.


### B#26 — Fiches d'outil : durées « measured » périmées après les lots E-G

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : doc-incoherence
- Où : `Sources/UI/DefragToolChoice.swift:106`

**Constat.** `tool.windowsXP.ntfs.measured` affiche toujours « a few seconds to 45 min » / « de quelques secondes à 45 min ». La table NTFS du README à 1cd42cc donne pourtant 12 s à 2 h 40 (dev-2007), et 2 h 18 et 2 h 11-2 h 12 sur plusieurs volumes. De même, `tool.windows95.fat.measured` (l.91) reste « 6 min to 1 h », alors que le README (l.1209) dit désormais « de 7 s (gamer-1993) à 1 h 01 ». Le lot G a réécrit `principle` et `sound` de la fiche XP sans toucher à `measured`.

**Scénario.** Sur famille-2012, l'écran « Avec quel outil ? » annonce au plus 45 min pour l'outil d'époque, et la passe en dure 2 h 11 d'après le README.

**Vérification.** DefragToolChoice.swift:106 affiche encore `tool.windowsXP.ntfs.measured` = « a few seconds to 45 min ». i18n/translations.json porte les mêmes valeurs. Or la table NTFS du README à 1cd42cc (l.1011-1024) donne 12 s pour gamer-2003 et va jusqu'à 2 h 40 pour dev-2007, avec 2 h 18 (gamer-2007), 2 h 11 (famille-2012) et 2 h 12 (gamer-2012). De même, DefragToolChoice.swift:91 affiche `tool.windows95.fat.measured` = « 6 min to 1 h », alors que README.md:1209 dit « de 7 s (gamer-1993) à 1 h 01 ». Le lot G a réécrit `principle` et `sound` de XP sans toucher à `measured`.


### B#27 — Page support : libellés et outil par défaut non mis à jour (XP ancien texte, DEFRAG et Vista/7 absents)

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : doc-incoherence
- Où : `docs/support/index.html:154`

**Constat.** CLAUDE.md exige que chaque libellé cité sur le site soit celui de l'unité `en` du catalogue. La page support cite encore l'ancien `tool.windowsXP.principle`/`sound` (« only repairs files in pieces, by copying them into a hole that is already free. Short and calm; it gives up… »). Le catalogue et docs/index.html:174 disent maintenant « Repairs files in pieces, smallest first… » et « Bursts of small 64 KB copies… ». Les lignes 147-149 affirment aussi qu'un FAT des années 90 reçoit « the Windows 95/98 Defragmenter by default » et un NTFS des années 2000 « the Windows XP one ». Depuis adb0d06 et le lot G, un disque de 1993 présélectionne « MS-DOS 6 DEFRAG », et 2007 et 2012 les défragmenteurs de Vista et de Windows 7.

**Scénario.** Un utilisateur lit sur le site que l'outil XP « gives up when no hole is the right size ». L'app, elle, décrit un outil qui vide une région puis tasse tout, et lui présélectionne « MS-DOS 6 DEFRAG » sur un disque de 1993.

**Vérification.** docs/support/index.html:153 (à 1cd42cc) garde l'ancien texte XP : « only repairs files in pieces, by copying them into a hole that is already free. Short and calm; it gives up when no hole is the right size ». Le catalogue (DefragToolChoice.swift:103-104) et docs/index.html:174, retouché par le lot G (5eedbf9), disent « Repairs files in pieces, smallest first… then packs everything towards the start ». Les lignes 146-149 annoncent encore Windows 95/98 et XP comme outils par défaut, alors que l'app nomme maintenant « MS-DOS 6 DEFRAG » avant 1995, puis Vista et 7. Cela contredit la règle de CLAUDE.md : le site doit citer l'unité `en` du catalogue.


### B#28 — Commentaire contradictoire : « DayPlanner attend déjà le POST » alors que le même commit l'a retiré

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : doc-incoherence
- Où : `Sources/Model/Scenario.swift:595`

**Constat.** Le lot A (b59ef90) supprime `writer.think(boot.post)` de DayPlanner (DaySession.swift:192-196 : « Le POST n'est pas un temps de calcul à compter ici … Le compter en plus le faisait durer deux fois »). Dans le même commit, Scenario.swift:593-595 justifie la montée en régime de la journée par « `DayPlanner` attend déjà le POST ». C'est l'inverse de ce que fait le code, et cela invite à remettre le double compte.

**Scénario.** En relisant Scenario.build(day:), on croit que le POST est compté dans DayPlanner, et on réduit spinUpDuration pour l'éviter. La journée perdrait alors le silence du POST, que plus rien ne compte.

**Vérification.** Le commit b59ef90 (lot A) supprime `writer.think(boot.post)` de DaySession.swift. À 1cd42cc, les lignes 192-195 de ce fichier disent : « Le POST n'est pas un temps de calcul à compter ici … Le compter en plus le faisait durer deux fois ». Le même commit ajoute pourtant en Scenario.swift:593-595 « la journée commence par lui, et `DayPlanner` attend déjà le POST ». C'est l'inverse du code : le POST n'est plus porté que par spinUpDuration.


### B#29 — CLAUDE.md : le nom de système « MS-DOS 6 et Windows 3.1 » est affiché dans l'app, contrairement à ce qu'affirme le paragraphe retouché

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : doc-incoherence
- Où : `CLAUDE.md:127`

**Constat.** Le paragraphe modifié dans la plage (6.22 → 6) dit que les deux textes français « ne vont nulle part dans l'app ». Or `Era.osName` s'affiche en verbatim : carte de la galerie (DiskGallery.swift:86 et 210), titre de passe (PassScreen.swift:302-303), résumé « Booting \(plan.osName) » (Scenario.swift:417), NowPlaying. Côté assistant, le renommage n'a pas suivi : `SystemOption` affiche toujours « MS-DOS 6.22 et Windows 3.1 · 1994 » (DiskWizard.swift:18), pour le même identifiant `msdos-6.22+win31`.

**Scénario.** L'app en anglais : la carte de gamer-1993 affiche « … · MS-DOS 6 et Windows 3.1 », et l'assistant propose « MS-DOS 6.22 et Windows 3.1 » pour le même système.

**Vérification.** CLAUDE.md:127-131 dit que ce nom « ne va nulle part dans l'app ». Or `Era.osName` (BootSession.swift:307) s'affiche en verbatim à plusieurs endroits : DiskGallery.swift:86 et 210, DiskLibraryView.swift:122, PassScreen.swift:302-303 et 691-693, et le résumé de Scenario.swift:417. Le « et » français sort donc aussi dans l'app en anglais. Cette affirmation date d'avant la plage. En revanche, le renommage 6.22 → 6 fait dans la plage n'a pas été reporté dans l'assistant : DiskWizard.swift:18 propose toujours « MS-DOS 6.22 et Windows 3.1 » pour le même identifiant `msdos-6.22+win31`. Un même système porte ainsi deux noms dans l'app.


### B#30 — Test « UltraDefrag et XP laissent les répertoires FAT en place » n'affirme plus qu'ils restent en place

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : test-coverage
- Où : `Tests/DefragKitTests/DirectoryItemsTests.swift:85`

**Constat.** L'assertion `plan.filesMoved == 1` est devenue `plan.arrangement.filter { $0.extents.count > 1 }.count == 30`. Le test vérifie maintenant que 30 fichiers restent en plusieurs morceaux, pas que les répertoires n'ont pas bougé : une stratégie qui déplacerait les fragments d'un répertoire sans les recoller le passerait. Il faudrait comparer les extents des répertoires avant et après.

**Scénario.** Une régression fait déplacer par XP un répertoire FAT fragmenté vers un autre emplacement, toujours en deux morceaux : le test reste vert, alors que son titre promet l'inverse.

**Vérification.** Dans DirectoryItemsTests.swift:85, le diff remplace `plan.filesMoved == 1` par `plan.arrangement.filter { $0.extents.count > 1 }.count == 30`. Cette assertion redit à peu près celle de la ligne 84 (`fragmentedFiles == 30`). Plus rien ne borne les déplacements, et rien ne compare les extents des répertoires, contrairement au test JkDefrag voisin (l.61-63), qui compare `extents == file.extents`. Une stratégie qui déplacerait un répertoire FAT en gardant ses deux morceaux passerait le test, alors que son titre promet que les répertoires restent en place.


## Pourboires, liens, traduction (chantiers 35 à 38)

Chantiers 35 à 38 sur les liens et les pourboires. Le lien Ko-fi, ajouté puis retiré de l'app (directive 3.1.1), est remplacé par une section « À propos » de six liens sortants (AboutLinks.swift). Trois pourboires consommables par StoreKit 2 s'y ajoutent : TipJar, qui écoute Transaction.updates dès le lancement, TipSheet et Tips.storekit, branché sur les deux schémas. Le site reçoit le bouton et la bannière App Store et une ligne vers les autres apps ; les notes de revue et la page confidentialité ajoutent un paragraphe « Tips ». Le code StoreKit est sain : transactions vérifiées puis finies, annulation, attente et erreurs traitées, @MainActor correct pour Swift 6. Les identifiants de produit concordent entre le code, Tips.storekit, le LEDGER et les notes de revue. Le catalogue et i18n/translations.json concordent clé par clé, et les 16 clés neuves sont des noms pointés sans %lld, avec en et fr. Les défauts sont surtout de la prose restée d'avant l'achat intégré (« no in-app purchase » sur le site et dans le README, « no network access at all »), le site lié depuis l'app qui appelle encore à donner sur Ko-fi alors que les notes de revue disent le contraire, et un état de TipJar qui n'est jamais remis à zéro.


### B#31 — Le site affirme encore « Free, with no in-app purchase » alors que l'app vend trois pourboires

- Verdict : **CONFIRMÉ** ; gravité : moyenne ; catégorie : incohérence code/doc
- Où : `docs/index.html:260`

**Constat.** Le chantier 38 (5ac5ec2) ajoute trois consommables (io.github.glandais.winchester.tip.small/.medium/.large, TipJar.swift:27-30, Tips.storekit). Il met à jour la page confidentialité et les notes de revue, mais laisse la liste « What it needs » de l'accueil telle quelle : « iPhone and iPad, iOS 17 or later. Free, with no in-app purchase. ». CLAUDE.md demande que le site reste vrai. De son côté, la fiche du store affichera « Achats intégrés » dès que les produits seront joints à la 1.0.0.

**Scénario.** Un visiteur lit « no in-app purchase » sur glandais.github.io/winchester/, installe l'app et y trouve « Soutenir Winchester » avec trois achats à 0,99 €, 2,99 € et 4,99 €. L'App Store affiche aussi la mention « Achats intégrés », ce qui contredit la page que l'app ouvre elle-même par Réglages → À propos → Site web.

**Vérification.** À 1cd42cc, docs/index.html:260 dit toujours « Free, with no in-app purchase. » (la phrase existait avant la plage, à la ligne 255). Le chantier 38 (5ac5ec2) ajoute les consommables et ne touche que docs/privacy/index.html sur le site, d'après son --stat. Le LEDGER du chantier 38 (Décisions et Laissé ouvert) ne dit rien de l'accueil. Or CLAUDE.md exige que le site reste vrai, et l'app l'ouvre par AboutLink.website (AboutLinks.swift:25). La contradiction vient donc de la plage.


### B#32 — README : « gratuit, sans achat intégré » et Ko-fi présenté comme seule voie de pourboire

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : incohérence code/doc
- Où : `README.md:1892`

**Constat.** La section « Soutenir » dit encore « Winchester est gratuit, sans achat intégré. Pour laisser un pourboire : ko-fi.com/gabylandais ». Le chantier 38 a pourtant ajouté l'achat intégré de pourboires. Le README est la référence du projet selon CLAUDE.md, et cette phrase n'a été relue ni par le chantier 38 ni par le lot H (la prose).

**Scénario.** Un lecteur du dépôt conclut que l'app n'a aucun achat intégré. Un agent qui s'appuie sur le README pour la fiche du store ou le site recopie la même affirmation fausse.

**Vérification.** À 1cd42cc, README.md:1892-1893 dit « Winchester est gratuit, sans achat intégré. Pour laisser un pourboire : ko-fi.com/gabylandais ». Cette section vient de c759804, qui est dans la plage. Le chantier 38 ne modifie pas README.md (absent de son --stat), et le lot H non plus. Que Ko-fi reste cité dans le README est voulu (chantiers 36 et 37). « Sans achat intégré », en revanche, est devenu faux.


### B#33 — Le site lié depuis l'app appelle à donner sur Ko-fi, alors que les notes de revue affirment qu'il n'y a aucun lien de don

- Verdict : **PLAUSIBLE** ; gravité : moyenne → basse ; catégorie : conformité 3.1.1 / notes de revue
- Où : `docs/index.html:270`

**Constat.** AboutLink.website (AboutLinks.swift:25) ouvre la page d'accueil du site. On y lit « Winchester is free and stays free. If it made you smile, you can leave a tip on Ko-fi » (l.270-272), et « Support on Ko-fi » figure au pied des quatre pages (index.html:304, support:245, privacy:210, how-it-works:270). Les pages support et privacy sont elles aussi ouvertes depuis l'app. Or metadata/review-notes.md:15 affirme « There is no external tip or donation link ». Le LEDGER (chantier 36) a jugé le site hors de l'app, mais depuis le chantier 37 l'app y mène en un tap. Le « free and stays free » contredit en outre le pourboire intégré.

**Scénario.** Le relecteur d'Apple lit dans les notes qu'il n'y a pas de lien de don externe, puis ouvre Réglages → À propos → Site web ou Confidentialité : Safari affiche un appel à donner sur Ko-fi, en concurrence avec l'achat intégré des pourboires. Cela expose à un refus au titre de 3.1.1/3.1.3, et la note de revue devient fausse.

**Vérification.** Le fait est exact : docs/index.html:270-272 et 304 portent Ko-fi, et AboutLinks.swift:25-27 ouvre l'accueil, le support et la confidentialité. review-notes.md:15 dit « There is no external tip or donation link ». Mais garder Ko-fi sur le site est une décision documentée (LEDGER, chantier 36 : « Le site garde Ko-fi… hors de l'app » ; chantier 37 : « Ko-fi reste sur le site »), et la note parle de l'app. Le refus au titre de 3.1.1(a) par le lien du site n'est qu'un risque possible, pas un défaut démontré. Seul « free and stays free » (l.271) reste défendable : les pourboires ne débloquent rien. Gravité ramenée à basse.


### B#34 — « No network access at all » / « never goes online » alors que la feuille de pourboires interroge l'App Store

- Verdict : **PLAUSIBLE** ; gravité : basse ; catégorie : incohérence code/doc (confidentialité)
- Où : `docs/privacy/index.html:57`

**Constat.** Depuis le chantier 38, TipSheet charge les produits dès son ouverture (TipSheet.swift:42 → TipJar.load, Product.products(for:)) et achète par StoreKit. Cela passe par le réseau, via le service StoreKit. Le commentaire de TipJar.swift:35 le reconnaît lui-même (« hors ligne »), et tip.unavailable s'affiche hors connexion. Pourtant, la page confidentialité (l.57 « It has no network access at all », et sa meta description l.8), l'accueil du site (index.html:261), la note sous « À propos » (settings.about.note, AboutLinks.swift:89 : « The app itself never goes online ») et metadata/review-notes.md:15 (« no network access at all ») n'ont pas été nuancés. Le paragraphe « Tips » ajouté à la page confidentialité n'en dit rien. CLAUDE.md demande que la page change dès qu'un accès réseau apparaît.

**Scénario.** En mode avion, l'utilisateur ouvre « Soutenir Winchester » : la feuille affiche « Tips are unavailable right now. » juste après qu'il a lu dans l'app « The app itself never goes online ». Un relecteur qui observe le trafic StoreKit trouve la politique « no network access at all » inexacte.

**Vérification.** TipSheet.swift:42 appelle tipJar.load(), qui appelle Product.products(for:) (TipJar.swift:62). Le commentaire de TipJar.swift:35 cite le cas « hors ligne ». Pourtant, docs/privacy/index.html:57 et 133-134 (« The app makes no network request of any kind »), docs/index.html:261, settings.about.note (« The app itself never goes online ») et review-notes.md:15 restent absolus. Deux atténuations : la requête passe par le démon StoreKit du système, pas par une connexion de l'app, et le paragraphe « Tips » (privacy l.126-130) dit que le paiement est traité par Apple. L'imprécision est réelle, mais elle relève de la formulation, pas d'une collecte de données.


### B#35 — L'état de TipJar survit à la feuille : « Merci ! » ou « L'achat n'a pas abouti » réapparaissent à chaque ouverture

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : logique UI / StoreKit
- Où : `Sources/Tips/TipJar.swift:52`

**Constat.** TipJar est un objet unique, créé dans WinchesterApp.swift:11. Son `state` n'est jamais remis à .idle, ni à l'ouverture ni à la fermeture de TipSheet (TipSheet.swift:42 appelle seulement load()). Le listener de Transaction.updates (l.47-53) pose .thanked même quand la feuille est fermée, par exemple pour un Ask to Buy approuvé plus tard ou une transaction interrompue finie au lancement. De même, .failed et .pending restent affichés tant que l'app n'est pas relancée. Un Ask to Buy refusé ne produit aucune transaction, donc « En attente d'approbation » ne disparaît jamais.

**Scénario.** L'utilisateur achète un petit pourboire et voit « Thank you! ». Il ferme la feuille puis la rouvre le lendemain sans relancer l'app : « Thank you! » est toujours affiché sous les produits, sans nouvel achat. Autre cas : un enfant demande un pourboire (Ask to Buy), le parent refuse, et la feuille affiche « Waiting for approval » jusqu'au prochain lancement à froid.

**Vérification.** TipJar est créé une seule fois dans WinchesterApp.swift:11-13 (un @State de l'App), puis injecté par .environment. `state` (TipJar.swift:37) ne revient à .idle que sur .userCancelled ou @unknown (l.85, l.87). TipSheet.swift:42 appelle seulement load(), et la feuille ne le remet à zéro ni à l'ouverture ni à la fermeture (SettingsScreen.swift:43-44). Après « Thank you! », fermer puis rouvrir la feuille réaffiche donc le remerciement (TipSheet.swift:109-111). Un Ask to Buy refusé ne produit aucune transaction, si bien que .pending reste affiché jusqu'au prochain lancement à froid. Le LEDGER du chantier 38 note d'ailleurs « Pas vu : l'attente d'approbation (Ask to Buy), l'échec simulé ».


### B#36 — Commentaire d'AboutLink périmé : le pourboire « passerait » par l'achat intégré (chantier 36)

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : incohérence code/doc
- Où : `Sources/UI/AboutLinks.swift:7`

**Constat.** Le commentaire de tête dit « Aucun lien de don ici : un pourboire, dans l'app, passerait par l'achat intégré (directive 3.1.1, chantier 36) ». Il a été écrit au chantier 37, avant les pourboires. Depuis le chantier 38, ce pourboire existe : TipJar et TipSheet, ouvert par SettingsScreen.support. Le conditionnel et le renvoi au chantier 36 induisent en erreur sur l'endroit où vit le pourboire.

**Scénario.** Un développeur lit AboutLinks.swift, conclut qu'aucun pourboire n'existe encore et en ajoute un second, ou cherche l'achat dans le chantier 36 au lieu de Sources/Tips/TipJar.swift.

**Vérification.** AboutLinks.swift:7-9 dit « Aucun lien de don ici : un pourboire, dans l'app, passerait par l'achat intégré (directive 3.1.1, chantier 36) ». Ce commentaire vient du chantier 37 (5949dc4). Le chantier 38 (5ac5ec2), dans la plage, a ensuite ajouté TipJar et TipSheet sans y toucher. La première moitié (« aucun lien de don ici ») reste juste. Seuls le conditionnel et le renvoi au chantier 36 sont périmés, et c'est sans effet à l'exécution.


## Documentation et registres (lot H)

J'ai relu la zone documentation et registres à 1cd42cc, en lecture seule : aucune mesure lancée, aucun fichier modifié. Dans cette plage, le README reçoit ses nouveaux chiffres (lots A à G, réécrits par readme-tables.py), les nouvelles sections (niveau de la tête, place de $MFT, XP d'après le code de SP1, « Ce qui ne l'est pas » étendu), une ligne de liens et une section « Soutenir ». LEDGER.md ajoute les chantiers 35 à 45, LEDGER-REALISME.md le dépouillement et ses suites, CLAUDE.md corrige la phrase sur le 2²⁰ et le nom « MS-DOS 6 », et wav-md5.py arrive (58 rendus hachés ; le compte et les identifiants de scénario sont justes). Le défaut dominant vient de readme-tables.py : ses gabarits remplacent les nombres mais gardent les phrases autour. Le lot H n'a pas relu ces phrases, si bien qu'une quinzaine d'argumentaires disent maintenant le contraire de leurs propres tables, parfois avec des tournures cassées (« 91-91 % », « 0,1 fois plus », « un occupants », « 1 trous »). Plusieurs points restent à côté : la table du rangement intelligent est entièrement d'avant le réalisme sans avertissement, la section « Soutenir » contredit l'achat intégré du chantier 38, et le 24 % de famille-2003 est incompatible avec les bornes non modifiées de CalibrationTests.


### B#37 — famille-2003 à 24 % dans le README, alors que CalibrationTests exige moins de 16 % et un remplissage supérieur à 90 %

- Verdict : **CONFIRMÉ** ; gravité : haute ; catégorie : incohérence code/doc
- Où : `README.md:703`

**Constat.** README.md:703-710 annonce (depuis le lot F, c7cda33) « `famille-2003` 24 % au lieu de 40 à 60 % », puis « NTFS lui-même, qui place encore bien à 95 % de remplissage ». Or Tests/DiskCoreTests/CalibrationTests.swift:249-265, que la plage n'a pas touché, affirme `fill > 0.90` et `fragmentedRatioAmongFragmentable < 0.16`, avec un withKnownIssue libellé « le modèle produit 8 % ». Le chiffre du README vient de `disk-famille-2003` (Report.swift:273, même métrique `fragmentedRatioAmongFragmentable`, même `DiskGenerator.generate`). De plus, les tables XP donnent famille-2003 à 88 % de remplissage (README:1323), sous les 0,90 du test. Enfin, fileSystemDominatesTheOutcome exige que famille-1999 dépasse 2 × 24 % = 48 %. LEDGER.md (chantier 44) affirme « swift test : 306 tests » verts.

**Scénario.** Quelqu'un lance `swift test` à 1cd42cc. Soit family2003 échoue sur `< 0.16` (et peut-être sur `fill > 0.90`), alors que le journal le dit vert. Soit le test passe, et c'est le 24 % publié par le README (et la phrase « à 95 % ») qui est faux. Dans les deux cas, le registre et le code se contredisent.

**Vérification.** README.md:705 à 1cd42cc dit « famille-2003 24 % ». c7cda33 l'a fait passer de 8 à 24 % par readme-tables.py:292-295 (disks[...]["ratio"], qui est fragmentedRatioAmongFragmentable). Tests/DiskCoreTests/CalibrationTests.swift n'a pas bougé dans la plage : family2003 exige fill > 0.90 et un taux < 0.16 ; fileSystemDominatesTheOutcome exige ntfs.fill > 0.90 et famille-1999 > 2 × famille-2003. Les bilans que le lot G a déjà écrits sur le disque (.build/measure-realisme/out-g/, lus sans rien remesurer) donnent disk-famille-2003 : « 88 % plein », « 976 sur 4156, 23.5 % », et disk-famille-1999 : 16,4 %. Au lot E (out-e), c'était encore 95 % et 7,6 %. Quatre #expect stricts tombent donc : 0,88 < 0,90 (deux fois), 23,5 > 16, et 16,4 < 47. LEDGER.md:7473 annonce pourtant « swift test : 306 tests ». La phrase « NTFS … place encore bien à 95 % de remplissage » (README:710) est périmée, comme le libellé withKnownIssue « le modèle produit 8 % ».


### B#38 — Recollage économe : « moins de morceaux que chacun d'eux », contredit par sa propre table

- Verdict : **CONFIRMÉ** ; gravité : moyenne ; catégorie : prose contredite par les chiffres
- Où : `README.md:1335`

**Constat.** README.md:1335-1337 : « laisse moins de morceaux (9 232) et moins de trous (1 937) que chacun d'eux ». La somme des colonnes de la table (README:1321-1332) donne 4 845 morceaux pour UltraDefrag et 4 311 pour JkDefrag, tous deux sous 9 232. Le gabarit (readme-tables.py:486-492) ne calcule que la somme du recollage et écrit « moins » en dur. Dans le même paragraphe, « qui se compensent » et « la qualité à durée voisine » (l.1347) ne tiennent plus face à 1 h 38 contre 13 h 43 ou 4 h 38. Et « sur `dev-2007` […] XP et JkDefrag finissent sans un morceau » (l.1348-1349) contredit la ligne dev-2007 (README:1326), qui donne 2 et 90 morceaux.

**Scénario.** Un lecteur compare la conclusion à la table juste au-dessus : le recollage laisse deux fois plus de morceaux qu'UltraDefrag ou JkDefrag, et XP comme JkDefrag laissent des morceaux sur dev-2007. `readme-tables.py --check` ne voit rien, parce que le verbe n'est pas un chiffre.

**Vérification.** Sommes de la table README.md:1321-1332 : 9 232 morceaux pour le recollage, 4 845 pour UltraDefrag, 4 311 pour JkDefrag. « moins de morceaux (9 232) … que chacun d'eux » (l.1335) est donc faux. À 079b244 la phrase tenait : 13 163, contre environ 38 000 et 17 500. Sur dev-2007, XP laisse 2 morceaux et JkDefrag 90, alors que le texte dit « sans un morceau » (l.1348-1349). La passe dure 1 h 38 contre 4 h 38 et 13 h 43, alors que le texte parle de « qualité à durée voisine » (l.1347). Le défaut est entré dans la plage.


### B#39 — Table du rangement intelligent entièrement d'avant les lots, présentée comme à jour sauf pour 2012

- Verdict : **CONFIRMÉ** ; gravité : moyenne ; catégorie : registre périmé
- Où : `README.md:1380`

**Constat.** README.md:1380-1381 ne signale que l'absence de 2012 (« la mesure reste à faire »). Or toute la table (l.1383-1403) date d'avant les lots : dev-1993 69 %, 41,6 s livrés ; gamer-1993 100 % ; dev-2003 95 %, 64 morceaux ; famille-2003 95 %. Les tables voisines disent dev-1993 72 % et 42,2 s, gamer-2003 66,2 s, famille-2003 88 %. La prose qui en dépend est périmée aussi : l.1414-1421, « `gamer-1993`, plein à 100 %, reste tel quel », « `gamer-1999`, où la frontière seule en laisse 18 » (la table de la frontière, README:1266, en donne 1), « 4 h 42 », « 1,3 To et 15 h 43 ». LEDGER.md (chantier 45, Laissé ouvert) et LEDGER-REALISME.md:526 savent que `smart` est « à remesurer », mais le lot H n'a pas reporté cet avertissement dans le README.

**Scénario.** Un lecteur croise la table du rangement avec celles des démarrages et des passes : le même disque y est à 69 % et à 72 %, démarre en 41,6 s et en 42,2 s, et gamer-1999 garde 18 trous puis 1. Rien dans le README ne dit laquelle est la vieille.

**Vérification.** La table README.md:1383-1403 est identique à celle de 079b244 (famille-2003 95 %, 1137/0, 168/14 ; dev-1993 69 % ; gamer-1993 100 %). Les tables voisines ont été régénérées : dev-1993 72 %, gamer-1993 99 %, famille-2003 88 %. La seule réserve est celle de l.1380-1381, sur 2012. LEDGER.md (chantier 45, Laissé ouvert, l.7605) et LEDGER-REALISME.md (« le rangement intelligent à remesurer ») savent que la table est périmée, mais le README ne le dit pas. La prose qui en dépend l'est aussi : l.1414 dit « gamer-1993, plein à 100 % », l.1416 dit « la frontière seule en laisse 18 » alors que la table de la frontière donne 1 pour gamer-1999 (l.1266).


### B#40 — « Une exception : gamer-1993 […] la passe ne peut rien » contredit la ligne gamer-1993 de la même table

- Verdict : **CONFIRMÉ** ; gravité : moyenne ; catégorie : prose contredite par les chiffres
- Où : `README.md:1276`

**Constat.** README.md:1276-1279 : « `gamer-1993`, plein à 100 % […] la passe ne peut rien, et elle le rend tel quel ». La ligne README:1263 dit maintenant 99 %, un tassage à la frontière de 32 min 30 et 838 morceaux ramenés à 0 (trous 5 → 1). Juste avant, « les morceaux qui restent sont tous ceux du fichier d'échange » voisine avec « 334 morceaux ne laissent plus que 115 trous », qui ne décrit plus un volume tassé.

**Scénario.** Un lecteur lit la phrase juste sous la table, qui montre que la frontière est le seul outil à ranger gamer-1993. Le texte affirme exactement l'inverse.

**Vérification.** README.md:1263 : gamer-1993 à 99 %, frontière en 32 min 30, 838 morceaux ramenés à 0, trous de 5 à 1. Or l.1276-1279 disent « plein à 100 % … la passe ne peut rien, et elle le rend tel quel ». La table dit l'inverse de la prose placée juste dessous.


### B#41 — Frontière contre Windows 95 : l'argument « c'est ce qu'ils laissent » ne tient plus

- Verdict : **CONFIRMÉ** ; gravité : moyenne → basse ; catégorie : prose contredite par les chiffres
- Où : `README.md:1280`

**Constat.** README.md:1280-1286 : « elle déplace à peu près autant de données (29,8 Go contre 40,5) », « elles sont à quelques minutes l'une de l'autre » (4 h 32 contre 4 h 51, soit 19 min), puis « Windows 95 laisse jusqu'à 58 morceaux, la frontière 58 au plus ». La conclusion (« c'est ce qu'ils laissent » qui les sépare) est vidée de son objet : sur 1999, les deux laissent la même chose. Les gabarits readme-tables.py:465-472 ont remplacé les nombres sans que la phrase soit relue.

**Scénario.** Le lecteur lit « à peu près autant » devant un écart de 36 %, puis « Windows 95 laisse jusqu'à 58, la frontière 58 au plus » comme preuve d'une différence.

**Vérification.** README.md:1285 : « Windows 95 laisse jusqu'à 58 morceaux, la frontière 58 au plus ». La table (secretaire-1999 58/58) donne la même valeur aux deux outils, si bien que la différence invoquée n'existe plus. À 079b244, c'était 6 678 contre 147. « À peu près autant » (29,8 contre 40,5 Go) et « quelques minutes » (19 min) sont discutables, mais le cœur du constat tient. Gravité ramenée à basse : c'est de la prose.


### B#42 — UltraDefrag contre XP : « 0,1 fois plus de requêtes », des destinations « plus lointaines » avec un seek plus court, et « deux volumes que XP nettoie entièrement »

- Verdict : **CONFIRMÉ** ; gravité : moyenne ; catégorie : prose contredite par les chiffres
- Où : `README.md:1082`

**Constat.** README.md:1082 : « Le prix est 0,1 fois plus de requêtes et 0,7 fois plus de temps ». UltraDefrag coûte maintenant beaucoup moins que XP (151 444 contre 1 196 949 requêtes) ; la phrase parle d'un « prix » qui n'existe plus, et « 0,1 fois plus » n'a pas de sens (gabarit readme-tables.py:396). README:1088-1091 : ses destinations seraient « plus lointaines », avec pour preuve « 17 820 cylindres contre 30 270 chez XP », soit un seek plus court. README:1096-1097 : « Des deux volumes que XP nettoie entièrement, il nettoie l'un aussi, et laisse 93 morceaux sur l'autre ». Aucun volume n'est plus nettoyé entièrement par XP (secretaire-2007 : 4, dev-2007 : 2 morceaux).

**Scénario.** Le lecteur de la section « Recoller au lieu de déplacer » tombe sur trois affirmations dont les nombres cités prouvent le contraire.

**Vérification.** README.md:1082 : « Le prix est 0,1 fois plus de requêtes et 0,7 fois plus de temps » ; sur famille-2007, 151 444 contre 1 196 949 requêtes et 20 min 20 contre 30 min 20, donc UltraDefrag coûte moins. À 079b244, c'était « 1,5 fois ». l.1090-1091 : « plus lointaines », avec pour preuve 17 820 cylindres contre 30 270 chez XP, soit un seek plus court. l.1096-1097 : « Des deux volumes que XP nettoie entièrement » ; la table l.1069-1080 ne donne aucun 0 à XP (au mieux 2 ou 4 morceaux).


### B#43 — Argumentaires FAT de Windows 95 renversés par les nouveaux chiffres

- Verdict : **PLAUSIBLE** ; gravité : basse ; catégorie : prose contredite par les chiffres
- Où : `README.md:1209`

**Constat.** README.md:1209-1210 : « de 7 s (`gamer-1993`) […] sur les onze volumes où l'outil a de quoi travailler ». Le commentaire du gabarit (readme-tables.py:437-438) exclut justement gamer-1993, et 7 s, c'est une passe qui ne fait rien. l.1213-1216 : « Ce n'est pas la taille du volume qui fixe la durée : secretaire-1993 […] 20 min 29 […] quand dev-1996, six fois plus gros, en prend 22 » ; le contraste (autrefois 19 contre 6 min) s'annule. l.1224-1228 : « Le prix est sur les volumes pleins […] `dev-1999` en sort avec 3 morceaux », à l'appui d'une limite de l'outil qui ne se voit plus. l.1099-1103 : UltraDefrag sur dev-1996 laisse 1 085 morceaux « et l'outil de 95 […] en laisse 602 : […] il ne trouve plus où évacuer non plus » ; l'outil de 95 fait mieux, et la phrase ne l'illustre plus.

**Scénario.** Chaque phrase cite des nombres qui ne soutiennent plus sa thèse : le lecteur conclut l'inverse de ce que le texte affirme.

**Vérification.** Le constat est en partie réfuté. « six fois plus gros, en prend 22 » contre 20 min 29 (README:1213-1216) soutient toujours la thèse que la taille ne fixe pas la durée : six fois plus gros pour une durée voisine. « 7 s (gamer-1993) » vient du filtre movedMB > 0 (readme-tables.py:437-440), si bien que gamer-1993 déplace bien quelque chose ; seul le commentaire du gabarit, qui l'exclut, est faux. dev-1996 (602 morceaux pour 95 contre 1 085) illustre encore que 95 ne finit pas. Reste que « Le prix est sur les volumes pleins … dev-1999 en sort avec 3 morceaux » (l.1224-1228) n'illustre plus grand-chose.


### B#44 — Gabarits qui produisent du texte cassé : « 91-91 % », « que un occupants », « 1 trous »

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : prose générée
- Où : `README.md:1029`

**Constat.** README.md:1028-1033 : « remplis à 91-91 % », et « le remplissage ne suffit pas à le prédire » n'a plus d'appui (185/192 et 2 747/2 934, soit 96 % et 94 %). README:1131 : « il n'évacue que un occupants avant de se retrouver bloqué partout, et rend le volume intact » (word(1) dans readme-tables.py:419). README:1373-1374 : « — 1 trous sur `famille-1996` », à l'appui d'une retouche censée éviter un espace libre « semé ». Le lot H devait relire la prose et ne l'a pas fait.

**Scénario.** Un visiteur du dépôt lit des phrases fautives et des justifications qui ne justifient plus rien (un seul trou pour prouver un espace « semé »).

**Vérification.** README.md:1029 : « remplis à 91-91 % », et « le remplissage ne suffit pas à le prédire » ne s'appuie plus sur rien (185/192 contre 2 747/2 934, soit 96 et 94 %). README:1131-1132 : « il n'évacue que un occupants », produit par word(1) au gabarit readme-tables.py:414-415. README:1373-1374 : « — 1 trous sur `famille-1996` », à l'appui d'un espace libre « semé ».


### B#45 — Section « Soutenir » : « sans achat intégré », alors que le chantier 38 ajoute trois pourboires par achat intégré

- Verdict : **CONFIRMÉ** ; gravité : moyenne ; catégorie : incohérence code/doc
- Où : `README.md:1892`

**Constat.** README.md:1890-1893 : « Winchester est gratuit, sans achat intégré. Pour laisser un pourboire : ko-fi ». La plage ajoute Sources/Tips/TipJar.swift, Sources/UI/TipSheet.swift, Support/Tips.storekit et trois consommables (LEDGER.md, chantier 38), et docs/privacy/index.html décrit ces « Tips » comme des achats intégrés. Le commit 79939b4 retire Ko-fi de l'app au nom de la directive 3.1.1. Le README, public et lié depuis l'app (« Code source »), dit le contraire de ce que l'app propose.

**Scénario.** Un utilisateur arrive sur GitHub depuis Réglages > À propos et lit « sans achat intégré », puis voit trois achats intégrés dans l'app ; un relecteur App Store qui suit le lien voit la même contradiction.

**Vérification.** À 1cd42cc, README.md:1892-1893 dit « Winchester est gratuit, sans achat intégré. Pour laisser un pourboire : ko-fi.com/gabylandais », et Ko-fi figure aussi en l.9. Pourtant la plage ajoute Sources/Tips/TipJar.swift, Sources/UI/TipSheet.swift et Support/Tips.storekit (5ac5ec2), et docs/privacy/index.html:126-128 décrit les « tips as in-app purchases ». 79939b4 a retiré Ko-fi de l'app au nom de la directive 3.1.1, mais le README n'a pas suivi.


### B#46 — Arborescence du README périmée : description de WindowsXPStrategy, fichiers neufs absents

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : doc périmée
- Où : `README.md:1825`

**Constat.** README.md:1825-1826 décrit encore WindowsXPStrategy.swift comme « réparer les seuls fichiers cassés (NTFS), dans l'ordre de la MFT ou d'un autre outil ». Depuis le lot G, l'outil recolle la MFT, place en best fit, vide une région et la zone MFT, puis tasse vers l'avant. L'arborescence ne cite pas non plus Sources/Model/SeekCharacter.swift (lot D), Sources/Tips/ ni TipSheet/AboutLinks, tous ajoutés dans la plage.

**Scénario.** Un contributeur qui s'oriente par l'arborescence croit que l'outil de XP ne déplace que les fichiers fragmentés, et ne trouve pas où vit le niveau de la tête.

**Vérification.** README.md:1825-1826 : « WindowsXPStrategy.swift réparer les seuls fichiers cassés (NTFS), dans l'ordre de la MFT ou d'un autre outil ». Le lot G (et docs/index.html:174) décrit pourtant un best fit, le vidage d'une région, puis un tassage. La plage ajoute Sources/Model/SeekCharacter.swift, Sources/Tips/TipJar.swift, Sources/UI/AboutLinks.swift et Sources/UI/TipSheet.swift, dont aucun n'apparaît dans l'arborescence : SeekCharacter n'est cité qu'en l.311.


### B#47 — CLAUDE.md : « la version 1.0.0, build 4, est prête à être soumise », rendu faux par les chantiers 37 et 38

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : registre périmé
- Où : `CLAUDE.md:350`

**Constat.** CLAUDE.md:348-351 et 294 présentent le build 4 comme rattaché et prêt à soumettre. LEDGER.md (chantier 37) dit « le build 4 ne porte pas la section », et le chantier 38 dit « Joindre les trois [achats intégrés] à la 1.0.0, avec un build 5 ». CLAUDE.md ne mentionne ni les consommables, ni l'accord Paid Applications, ni Tips.storekit.

**Scénario.** Un agent qui suit CLAUDE.md soumet la 1.0.0 avec le build 4, sans la section À propos ni les pourboires, et sans joindre les achats intégrés, qui ne partent qu'avec une version.

**Vérification.** CLAUDE.md:294 et 350 à 1cd42cc disent que le build 4 est rattaché et prêt. LEDGER.md:6942 dit « le build 4 ne porte pas la section : il faut un nouveau build », et l.6996 « Joindre les trois à la 1.0.0, avec un build 5 ». CLAUDE.md ne mentionne ni les achats intégrés, ni Tips.storekit, ni Paid Applications.


### B#48 — Commentaire de FrenchUnits.bytesPerMegabyte contredit par le lot F

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : commentaire faux
- Où : `Sources/DiskCore/FrenchUnits.swift:25`

**Constat.** FrenchUnits.swift:23-30 affirme que `ProfileSpec.sizeBytes` vaut `sizeMB × 1 024 × 1 024` et que ce 2²⁰ « rend au disque étiqueté « 210 Mo » ses 210 Mo à l'écran ». Or ProfileSpec.swift:139 vaut désormais `sizeMB * 1_000_000`, et CLAUDE.md (corrigé dans la plage) dit l'inverse : le disque « en montre 200 une fois formaté, comme CHKDSK ». LEDGER.md (chantier 44) signalait la phrase de CLAUDE.md « à relire », mais pas ce commentaire.

**Scénario.** Un développeur lit le commentaire, conclut que le catalogue est en mébioctets et « corrige » l'affichage de 200 vers 210, ou recalcule une capacité avec le mauvais facteur.

**Vérification.** Sources/DiskCore/FrenchUnits.swift:23-30 (inchangé dans la plage) : « ProfileSpec.sizeBytes vaut sizeMB × 1 024 × 1 024 … rende au disque étiqueté « 210 Mo » ses 210 Mo ». Or ProfileSpec.swift:139 vaut désormais `sizeMB * 1_000_000`, et son commentaire dit qu'« un 210 Mo de 1993 en affiche 200 ». Le constat ne porte que sur un commentaire : la constante 2²⁰ reste juste pour l'affichage.


### B#49 — Site : outil de 1993 et outils de Vista et 7 absents de la table des défragmenteurs

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : incohérence site/app
- Où : `docs/index.html:173`

**Constat.** docs/index.html:173-174 ne nomme que « Windows 95/98 Defragmenter » (1995, FAT) et « Windows XP Defragmenter ». Depuis adb0d06 et le lot G, l'app affiche « MS-DOS 6 DEFRAG » (tool.msdos6.name) sur les quatre disques de 1993, et « Windows Vista Defragmenter » / « Windows 7 Defragmenter » (tool.vista.*, tool.win7.*) sur 2007 et 2012. CLAUDE.md exige que chaque libellé cité sur le site soit celui de l'unité `en`.

**Scénario.** Un utilisateur ouvre un disque de 1993 : l'app propose « MS-DOS 6 DEFRAG », que le site ne cite nulle part ; même chose pour 2007 et 2012.

**Vérification.** Les clés tool.msdos6.name, tool.vista.name et tool.win7.name sont absentes à 079b244 et présentes à 1cd42cc (DefragToolChoice.swift:83-96 : « MS-DOS 6 DEFRAG », « Windows Vista Defragmenter », « Windows 7 Defragmenter »). La table « The tools, as the app describes them » de docs/index.html:173-179 ne cite que « Windows 95/98 Defragmenter » et « Windows XP Defragmenter ». Aucun libellé cité n'est faux, mais ceux qu'affiche l'app sur 1993, 2007 et 2012 manquent.


### B#50 — LEDGER.md renvoie la fiche du Conner au chantier 37 au lieu du 40

- Verdict : **CONFIRMÉ** ; gravité : basse ; catégorie : référence fausse
- Où : `LEDGER.md:7459`

**Constat.** LEDGER.md:7459-7460 (chantier 44) : « la fiche du Conner (chantier 37) a rendu au disque ses 79 secteurs par piste ». La fiche du Conner est le chantier 40 (lot B) ; le chantier 37 concerne les liens croisés app, site et App Store.

**Scénario.** Un lecteur qui remonte l'origine du recalage à 0,93 de 1993 ouvre le chantier 37 et n'y trouve que des liens web.

**Vérification.** LEDGER.md à 1cd42cc : le chantier 37 (l.6895) porte sur les liens croisés, et la fiche du Conner est au chantier 40 (lot B, l.7089-7116). L.7459-7460 dit pourtant « la fiche du Conner (chantier 37) ». Pour mémoire, le message du commit c7cda33 dit aussi « Chantier 41 de LEDGER.md » pour ce qui est le chantier 44.


### B#51 — wav-md5.py : environnement hérité et sortie à 0 même en cas d'échec

- Verdict : **PLAUSIBLE** ; gravité : basse ; catégorie : outil de mesure
- Où : `Tools/Measure/wav-md5.py:40`

**Constat.** wav-md5.py:40 passe `dict(os.environ, SCENARIO=…)` : un STRATEGY, FULL_BLOCKS, TRANSIENT_GAIN ou SPINDLE_GAIN resté exporté dans le shell (LEDGER.md chantier 39 en utilise justement, `TRANSIENT_GAIN=0`) change les rendus sans que md5.txt le dise. Par ailleurs, un échec de rendertrace ne donne qu'une ligne « ECHEC » (le stderr capturé est jeté), et le script sort toujours avec le code 0 (l.57-60).

**Scénario.** Après une écoute avec `export TRANSIENT_GAIN=0`, on lance `wav-md5.py g` puis on compare à `wav-f/md5.txt` : les 58 md5 diffèrent et on attribue l'écart au lot. Ou bien un binaire cassé donne 58 ECHEC, le script sort à 0, et une chaîne de commandes continue.

**Vérification.** Tools/Measure/wav-md5.py (ajouté par b59ef90, donc dans la plage). l.40 : `dict(os.environ, SCENARIO=…)` hérite de STRATEGY, TRANSIENT_GAIN, etc. l.42 capture le stderr puis le jette, et le script n'appelle jamais sys.exit(≠0). Le constat est atténué : l.60 imprime le nombre d'échecs, et md5.txt porte « ECHEC » en clair. Le risque réel se limite à une variable exportée qui fausse une comparaison sans que rien ne le signale. C'est un outil de développement, non livré.

