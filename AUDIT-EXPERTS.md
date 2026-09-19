# Audit du solde — huit lots relus de l'extérieur

Relecture de tout ce qui a été fait depuis `74da38b`, par quelqu'un qui n'a
écrit aucune de ces lignes et qui n'en a corrigé aucune. La question posée :
**le solde de `LEDGER-EXPERTS.md` est-il honnête ?** — l'état du code, les
journaux et le README disent-ils la même chose, et cette chose est-elle vraie ?

Périmètre : `74da38b^..d72aa81`. **La commande d'audit décrivait treize commits
et sept lots ; `HEAD` en porte un quatorzième, le lot 8 (`d72aa81`), qui réécrit
le solde.** C'est ce solde-là qui est relu — 120 fichiers, +14 416 / −1 252. Une
affirmation de la commande est périmée de ce fait : le `.pyc` suivi par git a
été retiré au lot 4 (`3a1a250`) et `.gitignore` couvre `__pycache__/`.

Tout ce qui suit a été **mesuré ou lu à `HEAD`** : binaire `bin-audit` construit
par `snapshot.sh`, les 340 bilans de `run.sh audit full`, `boots.py`,
`fit-think.py`, `extents.py`, `readme-tables.py`, les deux suites de tests, les
manuels de `disknoise.resources/manuels`. Les trois listes des revues, l'histoire
des tests, l'inventaire des constantes et la lecture du code ont été menés par
six relecteurs en lecture seule ; chaque trouvaille reprise ici a été revérifiée
à la main dans le fichier qu'elle cite. Rien n'est estimé ; ce qui n'a pas pu
être vérifié est au § 6.

---

## 1. Verdict

**Le solde est honnête sur ce qu'il compte, et faux sur ce qu'il croit avoir
compté.**

Ce qu'il affirme avoir fait est fait. Les quatre fautes, les huit erreurs de
fait, l'allocation incrémentale, les répertoires, le journal, le cache : tout
est dans le code, à la ligne, et les chiffres que les journaux donnent pour
`HEAD` se reproduisent **au dixième de seconde et au morceau près** — les 63
lignes de table du README sortent identiques de `readme-tables.py`, les cinq
sommes de démarrage du chantier 27 aussi (149,6 / 213,6 / 234,3 / 187,7 /
163,4 s), les 413 tests passent, les problèmes connus sont trois. Sur sept
agents qui se sont chacun auto-évalués, je n'ai trouvé **aucun chiffre de
journal inventé**.

Il cesse de l'être à trois endroits, et ce sont les conditions du verdict :

1. **« Ce qu'aucun lot n'a pris : plus rien » est faux.** Le lot 8 a soldé une
   liste qui était déjà incomplète. Une ligne entière du § 8 de la revue
   système de fichiers (n° 14) et une dizaine de points de prose n'ont été ni
   faits ni écartés par écrit ; six points que les chantiers eux-mêmes avaient
   laissés ouverts ne sont pas remontés dans « Ce qui reste » (§ 4).
2. **La conclusion sur `ThinkModel` ne tient plus à `HEAD`, et le chantier 27
   l'énonce avec le mauvais signe.** Le journal écrit qu'un recalage « monterait
   encore » le coût au mégaoctet de XP et de Vista. `fit-think.py`, à `HEAD`,
   le fait **descendre** : 0,20 → 0,192 et 0,16 → 0,148, c'est-à-dire
   exactement les valeurs d'avant le lot 7 (0,19 et 0,15). Le « plancher
   processeur plus lourd que le cache révèle » était un disque à qui il
   manquait les seeks de MFT que le lot 8 lui a rendus (§ 3, T1).
3. **Le README a des tables vraies et une prose périmée.** Dix-sept chiffres
   dans le texte contredisent la table qui se trouve vingt lignes plus bas
   (§ 3, T2). C'est le défaut que les trois revues signalaient, que le solde
   reconnaît pour elles, et qui vaut pour les huit chantiers.

À ces conditions-là — corriger la phrase, renverser la conclusion, repasser la
prose —, le solde devient vrai. Aucune des trois ne demande de toucher au
modèle.

---

## 2. Ce qui est juste et rare

**Les journaux se reproduisent.** C'est la partie difficile, et je ne
l'attendais pas à ce degré. Les tables du README ne sont pas « à peu près »
celles de `HEAD` : elles le sont ligne pour ligne (63 sur 63 ; les quatre
journées ne diffèrent que par la colonne « activités », qui est du texte). Les
débits du § Géométrie sont ceux que le test imprime (−6,5 / +3,1 / +5,7 %). Les
trois cibles manquées sont à 8,1 / 5,5 / 7,6 %, comme écrit. `Tools/Measure`
est ce qui rend cela possible, et c'est le meilleur investissement de la
série : un relecteur extérieur refait tout le README en sept minutes.

**Les corrections sont faites comme les revues les demandaient, ou mieux, et le
disent quand c'est autrement.** Le skew est dérivé de la loi de seek, sans
littéral (`DriveGeometry.swift:148-190`), un `angleOf` unique sert la latence,
le transfert et la lecture anticipée. Le settle d'écriture ne reprend pas le
« +0,5 à 1 ms » de la revue : il est lu dans les colonnes « Write » des manuels,
fiche par fiche (`DriveCatalog.swift:267-402` — j'ai retrouvé 12,0/14,0 dans le
manuel du Fireball). Le facteur de format de 0,90 est **écarté sur mesure**, avec
la raison, plutôt qu'appliqué parce qu'un expert l'avait dit. La tranche de
JkDefrag est tranchée sur `fastfat`, pas au jugé.

**Un lot qui corrige la revue.** Le lot 8 mesure les constantes de
`NTFSAllocator` et trouve que la revue avait tort sur le sens (« elles poussent
toutes vers la contiguïté » : non) ; le lot 2 recompte « cinq fiches sur huit,
pas six » ; le lot 5 corrige « vingt échecs » en vingt et un. Des agents qui
contredisent leur donneur d'ordre sur pièces, c'est le comportement qu'on
voulait.

**Ce qui est déclaré ouvert l'est réellement.** L'entrelacement coupé, les
estimations du lot 6, les hypothèses du lot 7, le Conner qui emprunte au
Fireball : tout cela est dans le code *avec le mot « hypothèse »*. Le piste-à-
piste du Fireball, que le solde dit « tranché » sans que `LEDGER.md` en parle,
l'est bel et bien : `fireball-tm.txt:1569-1571`, « Track-to-track Typical
3.0 ms, Maximum 4.0 ms ».

**Aucun lot n'a défait un lot précédent** sur le fond. Sur 99 fonctions de test
ajoutées par les huit lots, une seule a été supprimée (voir T8), et
`AllocationInvariantTests`, `TrackSkewTests`, `WritingWhileItGrowsTests`,
`CheckpointTests`, `AcousticsTests`, `DriveCacheTests` n'ont jamais été
retouchés depuis leur ajout. Tout ce que les revues jugeaient juste est encore
là, à la ligne.

**Le code du cache est propre.** Horloge comptée une fois, événements dans
l'ordre, cas limites couverts (requête plus grande que le tampon, écriture sur
une lecture anticipée, lecture d'une écriture en attente, disque sans tampon au
bit près), pas un `Date()`, pas une itération de dictionnaire qui décide d'un
résultat, aucun TODO, aucune sonde de débogage, commentaires en français
partout.

---

## 3. Les trouvailles, par gravité

### Majeures — le journal ou le README affirme ce que la mesure dément

**T1. La conclusion sur `ThinkModel` est renversée à `HEAD`.**
`./Tools/Measure/fit-think.py audit` :

| époque | constante livrée | ajustée à `HEAD` | valeur d'avant le lot 7 |
|---|---:|---:|---:|
| 1993 | 0,65 | 0,661 | 0,80 |
| 1996 | 0,42 | 0,417 | 0,41 |
| 1999 | 0,24 | 0,241 | 0,25 |
| 2003 | **0,20** | **0,192** | 0,19 |
| 2007 | **0,16** | **0,148** | 0,15 |

Le raisonnement du chantier 26 était : le cache fait tomber le coût du
séquentiel, il faut monter `perMegabyte` de 0,19 à 0,20 et de 0,15 à 0,16 pour
tenir les cibles, rien ne justifie ce niveau, donc ce sont les cibles qu'il faut
rediscuter. Trois défauts, par ordre de poids :

- **Le lot 8 a annulé la prémisse.** La numérotation MFT rend au disque +3,3 %
  et +4,1 %, et l'ajustement retombe sur 0,19 / 0,15. Ce que le lot 7 lisait
  comme un plancher processeur était un manque du modèle de disque. Le
  chantier 27 (`LEDGER.md:5728-5731`) écrit l'inverse — « un recalage monterait
  encore le coût au mégaoctet » — alors que ses propres sommes sont **au-dessus**
  des cibles : il faut descendre. Le solde (`:461-464`, `:480-482`), le README
  (`:624-629`) et le docstring (`BootSession.swift:66-77`) portent tous la
  conclusion périmée.
- **La hausse était dans le bruit.** 0,19 → 0,199 et 0,15 → 0,157, arrondies
  au centième : +5 %, soit 2 à 4 s par époque, quand les résidus par profil
  sont de ±1,3 à ±1,8 s. « Le recalage final le montre » est trop fort pour
  ce que la table montre.
- **L'argument qui tient n'est pas celui-là.** Ce qui est injustifiable, c'est
  le *niveau* — 0,16 s/Mo pour un Vista, 20 % sous un XP — et il date du
  chantier 22 (0,09 → 0,15), pas du 26. Et la circularité est dite sans être
  tirée : les cibles sont « les durées que le modèle donnait avant la
  relecture », donc caler dessus revient à demander au modèle corrigé de
  reproduire le modèle fautif. Le README écrit pourtant encore, ligne 614,
  « calées pour que le total tombe sur **les durées d'alors** ».

Ce que le journal dit justement : avec quatre profils par époque, fichiers et
mégaoctets sont colinéaires, les résidus des deux ajustements sont les mêmes à
0,1 s (je les retrouve), et le choix de `perMegabyte` est physique, pas
statistique. Correction : aucune ligne de modèle. Soit recaler 2003 et 2007 à
0,19 / 0,15 (deux littéraux, et l'on constate que le lot 7 et le lot 8 se
compensent), soit laisser et réécrire la conclusion aux quatre endroits. Dans
les deux cas, retirer « il monte » du README. Détail : le docstring dit « calé
trois fois (chantiers 20, 22 et 26) » ; le chantier 20 écrit lui-même
« `ThinkModel` n'a **pas** été recalé » (`LEDGER.md:3332`), et le README dit
« deux fois ».

**T2. Dix-sept chiffres de prose du README sont faux à `HEAD`.** Les tables
sont régénérées ; le texte autour ne l'a pas été. Chaque ligne ci-dessous est
démentie par un bilan de `out-audit`, et pour la plupart par la table voisine :

| README | écrit | mesuré à `HEAD` |
|---|---|---|
| `:840` XP sur `famille-2007` | 90 398 requêtes, 16 min 14 | 203 573, 20 min 52 |
| `:840`, `:1126` fichiers cassés de `famille-2007` | 870, en 173 194 morceaux | 2 576, en 147 376 |
| `:858` `dev-2003` | répare 109 sur 123 | 114 sur 126 |
| `:858` `secretaire-2003` | 887 sur 1 181 ; 0,6 Mo par fichier | 963 sur 1 276 ; 1,2 Mo |
| `:901-904` XP → UltraDefrag, `famille-2007` | 134 532 → 1 634 morceaux ; 157 fragmentés ; « près de quatre fois plus de requêtes, deux fois plus de temps » | 54 360 → 1 087 ; 146 ; ×1,5 et ×1,5 |
| `:915` seek moyen sur `dev-2007`, UD / XP | 21 199 / 20 090 cyl. | 28 641 / 25 763 |
| `:977` JkDefrag sur `famille-1999` | 2 918 → 1 970 morceaux | reste 1 824 |
| `:1050` Windows 95 sur `dev-1999` | 4 805 morceaux au lieu de 1 717 | 3 357 |
| `:1099` frontière sur `dev-1996` | 66 morceaux, 12 trous | 43, 1 |
| `:1125` frontière sur NTFS | jusqu'à 488 Go et six heures | 389 Go, 4 h 37 (`famille-2007`) |
| `:660` témoins NTFS | de −1 % (`dev-2003`) à +3 % | de −2 % à +4 % |
| `:674-675` préchargeur, `famille-2007` | 635 seeks, 18 757 cyl., 38,6 s | 865 seeks, 8 798 cyl., 39,9 s |
| `:682` dates d'accès de `gamer-2003` | 912 réécrites en **33** écritures | 912 en **387** |
| `:692` pages de FAT32 relues | de 68 à 99 | de 64 à 111 |
| `:521` traîne de `secretaire-2003` | 10,3 % | 10,9 % |
| `:577` génération de `dev-2007` | 1,6 s | 1,80 à 1,84 s, trois passes, machine au repos (l'en-tête de `NTFSAllocator` dit 1,7) |

La ligne `:682` n'est pas qu'un chiffre : le lot 8 a éparpillé les
enregistrements de MFT, le groupement du lot 3 (« le cache les écrit par
paquets ») est passé de 28 dates par écriture à 2,4, et le test qui le gardait a
été **élargi dans le même commit** (`BootSessionTests.swift:225`, `× 4` →
`× 2`). C'est le seul endroit où un lot a entamé le mécanisme d'un autre, et ni
le journal ni le README ne le disent. Correction : faire imprimer ces chiffres
par `readme-tables.py` (il en sort déjà une vingtaine sous « chiffres de
prose ») ; une trentaine de lignes de Python, puis une passe de relecture.

**T3. « Ce qu'aucun lot n'a pris : plus rien » est faux** — détail au § 4.

### Sérieuses — un test ou une constante qui ne tient pas ce qu'on lui prête

**T4. L'invariant du tour perdu n'est vérifié que sur un chemin que
l'application n'emprunte plus.** `TrackSkewTests` construit `DiskMechanics` sans
`drive:`, donc en `.direct` (`TrackSkewTests.swift:35-37`,
`DiskSimulator.swift:402`). Les cinq scénarios de production passent
`.era(year:)` (`Scenario.swift:377, 413, 501, 572, 679`). Depuis le lot 7,
« *N* requêtes contiguës = une requête de *N* fois la taille » n'est donc plus
énoncé nulle part pour le disque qu'on écoute — alors que c'est la lecture
anticipée, d'après le solde lui-même, qui tient désormais cet invariant.
`Scenario.swift` étant exclu du paquet, aucun test n'assemble cache +
mise sous tension + démarrage : la durée que `thinkTimeIsAFloor` borne n'est pas
celle de l'application. Correction : le même test avec `.era(year: 2001)`, à une
tolérance à mesurer ; ~25 lignes.

**T5. Une borne a suivi son sujet quatre fois, et ne contraint plus rien.**
`CalibrationTests.fileSystemDominatesTheOutcome`, rapport FAT32 / NTFS du taux
de fragmentés :

| commit | titre | facteur exigé | mesure citée |
|---|---|---:|---|
| base | « trois fois plus » | 2,5 | > 20 % |
| lot 1 | « deux fois plus » | 1,9 | 22 contre 11 % |
| lot 2 | « une fois et demie » | 1,5 | 17 contre 11 % |
| lot 4 | « un quart de plus » | 1,25 | 17 contre 13 % |
| lot 8 | « **au moins** un quart » | 1,25 | 19 contre 8 %, soit ×2,5 |

À `HEAD` le modèle est revenu à ×2,5 et la borne est restée à 1,25 : le test
laisse le rapport varier du simple au double sans broncher. Même famille :
`secretaire-1999` dont le plancher effectif est passé de 10 % à 3 % sous un
`withKnownIssue` ajouté au lot 2 sur une assertion qui passait ;
`famille-2003` dont seules les bornes `> 0,01` et `< 0,25` sont actives (elles
ont laissé passer 6, 11, 13 et 8 %) ; `MFTGrowthTests` où deux profils sont
passés de `== 1` extent à `< 80` au lot 4 ; `AllocatorComparisonTests:272` où
la métrique a été remplacée par sa variante « sans le pire fichier ». Et
**toute la suite `Calibration` est désactivée en debug** : un `swift test`
ordinaire n'exécute aucune de ces bornes. Les trois `withKnownIssue` sont bien
trois, leurs raisons sont vraies à `HEAD` (8,1 / 5,5 / 7,6 %), mais le fichier
dit encore « deux d'entre elles » (`:191`, `:335`). À l'inverse,
`DefragPlannerTests:421` (bornes bilatérales après le changement d'algorithme
du lot 5) et `DriveModelTests:81` (demi-intervalle) ont été **resserrées** :
le réflexe n'est pas général.

**T6. La commutation de tête à 0,6 × le piste-à-piste est contredite par un
manuel du dossier.** `SeekModel.swift:308-322` : « toujours plus rapide qu'un pas
de piste… ce qu'aucun disque n'a jamais fait », source : « l'ordre de grandeur
annoncé sur la période ». Manuel du Fireball TM, table 4-3
(`fireball-tm.txt:1677-1679`) : *Sequential Cylinder Switch Time* 3,0 ms,
*Sequential Head Switch Time* **3,0 ms** — égales. Le modèle donne 1,8 ms à ce
disque, et le skew de tête en hérite. Le solde range E6 parmi les erreurs
« corrigées contre une fiche » ; c'est une constante de catégorie « ordre de
grandeur », non déclarée.

**T7. « Read-on-arrival » n'est pas une lecture sans latence.** Le README
(`:169-171`) et `DriveCatalog.swift:266` donnent le manuel du Fireball pour
source de la lecture qui « commence au secteur qui se présente ». Dans ce
manuel, l'expression qualifie **un temps de seek** — « Seek times:
Read-on-arrival, Typical 12.0 ms », opposé à « Average write 14.0 ms »
(`:1565-1573`) — et revient dans la note des taux d'erreur : « Read on arrival
is disabled to meet this specification » (`:2020`). Rien n'y décrit un
réordonnancement dans le tampon. Le solde ne déclare en hypothèse que « la
lecture sans latence des Seagate » : elle l'est pour **toutes** les fiches.

**T8. L'assertion « la cible est libre, pour les huit stratégies » existe dans
une stratégie, et en debug.** Un seul `assert`, `Windows95Strategy.swift:205` ;
aucun garde dans `DefragOperations.move` ni `DefragVolume`. Il est éliminé en
release : ni l'application ni les 340 bilans ne le vérifient.
`AllocationInvariantTests` joue bien les treize plans, mais sur **un** volume
synthétique FAT16 de 16 000 clusters — ni NTFS, ni zone MFT, ni un seul des
douze FAT sur lesquels la revue avait trouvé la faute. Le solde écrit que
l'audit « rejoue la garantie sur les treize plans » : vrai, et moins que ce
qu'on y lit. Et le second cas de recouvrement que le chantier 20 a trouvé dans
`DefragOperations.move` (`LEDGER.md:3421-3426`) n'a eu aucune suite.
Correction : l'audit en mode de `rendertrace` (il tourne déjà sur les 260
passes), ou un test release sur la galerie ; ~40 lignes.

Dans la même veine, le seul test d'un lot supprimé par un autre :
`bootFilesStayAtTheStart` (lot 2) retiré au lot 8 avec `AllocationHint.boot`.
Le retrait est argumenté ; mais plus rien ne vérifie qu'`IO.SYS` est en tête de
volume.

### Moyennes — la règle n'est pas appliquée partout

**T9. La règle des docstrings du lot 5 s'arrête aux fichiers que le lot 5 a
ouverts.** `LEDGER.md:4543` la dit « appliquée à tous les docstrings de
défragmentation ». Restés, et faux à `HEAD` :
`FragmentMergeStrategy.swift:8-13` (« 335 Go et dix heures », « 268 fichiers
cassés… 163 000 morceaux » — le README dit 488 Go, 870, 173 194, et la mesure
389 Go, 2 576, 147 376 : trois générations de chiffres) ;
`OperationSink.swift:14-17` (« une passe qu'on écoutait pendant cinq heures » —
1 h 00) ; `JKDefragStrategy.swift:229-231` (« la zone des répertoires est vide
dans la galerie » — elle ne l'est plus depuis le lot 4) ;
`DriveCatalog.swift:227-229` (« à 5 % près », quand le test voisin écrit +5,
+10 et +14 %) ; `FormatOverhead.swift:10-12` (17 Mo de tables sur
`gamer-1999` : 8,4 depuis les clusters de 8 Ko, périmé à sa création) ;
`VolumeLayout.swift:281` (« la MFT est en tête du volume » — derrière 64 Mio de
journal) ; `DriveGeometry.swift:128-131` ; `Simulator.swift:97-102` (« Vrai sous
Windows 95 et après… pas un réglage », contredit par `DiskGenerator:273-289`).
Une douzaine d'autres faits de galerie non datés, sans contradiction constatée.

**T10. `OperationSink.plannedPositioning` n'a pas suivi la correction du
7200.10.** 12,7 ms et 50 Mo/s sont dérivés, dans leur commentaire, d'un seek de
8,5 ms et de « 58 et 78 Mo/s » (`OperationSink.swift:75-80`). Le lot 8 a corrigé
la fiche à 11,0 ms et 72 Mo/s. Ces deux constantes fixent l'horloge des points
de contrôle de XP et de JkDefrag. Le README assure que la cadence « ne décide
pas du résultat » ; c'est plausible et je ne l'ai pas remesuré.

**T11. Des constantes « justifiées par la cible seule » hors de la liste
déclarée.** L'inventaire compte dix-huit constantes des lots qui sont des ordres
de grandeur ou des réglages et que « Ce qui reste » ne nomme pas. Celles qui
pèsent : le paquet d'écriture de **64 Ko sur NTFS** (`FileSystemProfile.swift:196`),
qui décide de la traîne de fragmentation et est affirmé comme un fait ; le
bloc de **huit clusters** de la MFT ; **une validation de journal sur huit**
(le code dit « ordre de grandeur » ; le journal non) ; la borne de **16
fenêtres** de `NTFSAllocator.swift:456`, quatrième constante de recherche
quand l'en-tête et le README en annoncent trois ; `powerOffDelay` 1,0 s et
`spinDownDuration` 3,5 s, quand le manuel du Fireball donne « Drive Ready to
Power Down 10.0 seconds » ; les bandes du roulement (2 900 et 640 Hz), le
battement à 0,35, la raie à 0,05, sous un en-tête qui affirme « aucune n'est un
réglage d'oreille » ; `spindleLevel` 0,32 → 0,20, seconde retouche de mixage
quand le journal parle de « la seule » ; le coût de commande de 0,2 ms,
mesuré sur un Pentium II de 1999, appliqué au Fireball de 1996 ; `perMegabyte`
de 1993, 1996 et 1999, calés exactement comme ceux que le solde met en cause.
À l'inverse, **le niveau des seeks, « calé sur rien », est sourçable** avec ce
qui est déjà sur le disque : U8 3,5 B en seek contre 3,2 au repos, ATA IV 2,8 /
3,3, 7200.7 3,4, 7200.10 3,2, 7200.11 3,2.

**T12. Les constantes de `NTFSAllocator` sont dites, mesurées, et non
régénérables.** La revue demandait « un test qui génère et imprime les trois
taux ». La table de l'en-tête vient de binaires jetables qui lisaient
l'environnement ; à `HEAD` les trois constantes sont des `private let` sans
injection, et la table ne se refait pas sans éditer la source. C'est le défaut
que le dernier paragraphe du solde dénonce. La ligne « tel quel » se vérifie
(7,6 / 13,6 / 9,1 %) ; les six autres non. Le retrait de
`growthMarginClusters`, lui, est bien inerte à la lecture : les deux
`firstFitRun` partaient du même point au-delà de `highWater`, où il n'y a qu'un
trou, et seule une longueur jetée changeait.

### Le code, comme code

**T13. L'entrelacement coupé est allumé par défaut dans les tests.**
`runsProgramsConcurrently` rend `false` en dur ; `Simulator.init` garde
`concurrent: Bool = true` (`Simulator.swift:143`). Vingt constructions de
`Simulator` dans les tests prennent donc le chemin que la production n'emprunte
jamais. ~305 lignes mortes en production, qui dupliquent `create`, `append` et
`replaceViaTemporary` : un lot futur corrigera l'un sans l'autre. Correction :
retirer la valeur par défaut ; 1 ligne, plus 4 tests à rendre explicites.

**T14. « Le README dit le modèle tel qu'il est, le journal dit pourquoi » n'est
pas tenu.** Mentions « lot *N* » ou « chantier *N* » : de 1 à 27 dans
`Sources/`, de 0 à 13 dans le README (« Elle est redevenue la plus rapide au
chantier 27 », « Jusqu'au chantier 25… »). Le pire : 45 lignes de journal, table
comprise, dans l'en-tête de `NTFSAllocator` ; 14 lignes dans `Allocator.swift`
pour décrire deux cas d'enum retirés ; `// 0,80 avant le chantier 26, 0,60
avant le 22` sur la table de `ThinkModel`.

**T15. Détails vérifiés.** Le tampon du disque est une FIFO — un succès ne
remonte pas le segment (`DiskSimulator.swift:589-596`) — quand son commentaire
(`:390`) et le README (`:166`) disent « la moins récemment servie ».
`SpindleVoice.updateCoefficients` alloue ~9 tableaux dans le fil audio à chaque
bloc d'une rampe, contre 2 avant le lot 6 (~20 lignes pour les sortir).
`snapshot.sh` construit dans `/tmp/rendertrace` en dur : deux worktrees se
volent le binaire, dans un projet qui travaille à un worktree par chantier
(4 lignes). `compare.py --identical` sort « 0 différents » et code 0 sur une
étape vide. `SmartDrive.read` plante sur `sectors == 0` (aucun appelant).
`run.sh` annonce 340 bilans : le compte est juste ; « ~2 min 30 » en a pris
6 min 36 ici, six relecteurs tournant à côté.

**Coûts.** Le tassage à la frontière est toujours quadratique (`physical()`,
`vcn()` intouchés, `LEDGER.md:4747` : « rien n'y a été fait »), et ce point
n'est pas dans le solde. La génération de `famille-2003` : 2,16 à 2,24 s
mesurés, contre 0,6 s avant l'écriture par paquets — le lot 8 en a rendu un
tiers, pas le facteur. Le chemin chaud de `serve` n'a ni dictionnaire ni
allocation par requête hors `forget` et `destage` ; rien d'alarmant.

---

## 4. Ce qui reste, contre ce que le solde déclare rester

Le solde déclare : trois questions sur source, trois cibles de fragmentation,
l'entrelacement, les estimations du lot 6, les hypothèses du lot 7, les cibles
de démarrage, et deux trouvailles du lot 8. **L'écart :**

**Demandes des revues ni faites ni écartées par écrit** — toutes de la revue
système de fichiers, toutes absentes des deux journaux (grep vide) :

| § revue | demande | état à `HEAD` |
|---|---|---|
| § 8 n° 14, § 6.8 | un résident compte 1 Ko de MFT ; `SizeModel` sous 700 octets | `FileSystemProfile.swift:65-67` inchangé ; `SizeModel.swift` sans un commit ; **`secretaire-2007` : 17 011 fichiers, 0 résident** (mesuré) |
| § 6.6 | `yieldMFTZone` quand la MFT a débordé | code identique à l'octet. À la lecture, la revue surestime l'effet (la zone cède une moitié, pas tout) : une ligne d'écartement aurait suffi, elle n'existe pas |
| § 5.6 | le commentaire de `fromVolumeStart` ; le hint remis à zéro chaque journée | `FATAllocator.swift:10-13` inchangé |
| § 4.2 | `$UsnJrnl` (réécrit en continu sous Vista), `$Secure` | aucune occurrence |
| § 4.4 | `$ATTRIBUTE_LIST` ; liens physiques de WinSxS comptés comme des copies | aucune occurrence ; `AppManifest.swift:309` |
| § 4.4 | compression, fichiers creux, flux : « défendable, **à dire** » | absent de « Ce qui ne l'est pas » |
| § 7 | numéro de MFT ≠ rang d'écriture | fait pour le démarrage et les défragmenteurs ; `MachineWriter` et `InstallSession` numérotent encore par rang |

**Laissés ouverts par un chantier, absents de « Ce qui reste »** : le second
recouvrement de `DefragOperations.move` (ch. 20) ; `DEFRAG.EXE` qui déplaçait
par tronçons (ch. 20) ; la racine FAT16 à 512 entrées et les trente
répertoires d'un XP qui en compte des milliers (ch. 23) ; le planificateur
quadratique (ch. 23, 24) ; `MoveItem4`, l'entrée `..`, l'attente du point de
contrôle non jouée (ch. 24) ; le piste-à-piste du Conner (ch. 21) ; la position
de départ du bras sur un plateau déjà lancé, qui part du moyeu alors que le
lot 6 établit qu'aucun disque de bureau ne s'y parque.

**Constantes non déclarées** : T6, T7, T11.

**Ce que le solde déclare et qui n'est plus vrai** : la conclusion sur les
cibles de 2003 et 2007 (T1).

Rien de cette liste n'est grave isolément. Ce qui l'est, c'est la phrase « plus
rien » : elle ferme un inventaire que personne n'a refait depuis les revues, et
le lot 8, qui devait ramasser ce que les sept premiers s'étaient passé, a
ramassé ce que **le lot 7 avait listé**.

---

## 5. Ce que chaque passe a coûté et rendu

| passe | coût | rendu |
|---|---|---|
| 1 — les trois listes | trois relecteurs, ~6 min chacun ; ~25 points revérifiés à la main | 29 + 33 + 23 demandes pointées ; la liste du § 4 ; T8 |
| 2 — les chiffres | 1 min 44 de construction, 6 min 36 pour 340 bilans, une heure de confrontation | T1 et T2 : les deux trouvailles majeures. La plus rentable, de loin |
| 3 — les tests | un relecteur sur `git log -p`, 5 min ; `swift test` 2 min 48, calibration 2 min 23 | T4, T5 ; la confirmation qu'aucun lot n'a défait un autre |
| 4 — les constantes | un relecteur, 7 min, 358 littéraux ; trois vérifications dans les manuels | T6, T7, T10, T11 — deux constantes contredites par un manuel du dossier |
| 5 — le code | un relecteur, 9 min | T13 à T15 ; rien de bloquant |

---

## 6. Ce que je n'ai pas pu vérifier

- **Les binaires jetables des journaux** (`nomft`, `knobs`, `nora`, `soft`) :
  la table des constantes NTFS hors « tel quel », l'attribution de la dérive
  des démarrages à la seule numérotation MFT, les chiffres « sans préchargeur »
  et « point de contrôle unique » du README. Je n'ai mesuré que `HEAD`.
- **L'ajustement du chantier 26** (0,199 / 0,157) : il faudrait le binaire du
  lot 7. La cohérence de ses sommes avec celles du chantier 27, que je
  reproduis, plaide pour lui.
- **Les sources hors dossier** : TULARC, le brevet du bus ISA, `HELP SMARTDRV`,
  `mkntfs`, `JkDefragLib.cpp`, `fastfat`, les supports de *Windows Internals*
  pour les cinq secondes.
- **L'invariant de T4 avec le cache** : il aurait fallu écrire un test.
- **Rien n'a été écouté**, et le simulateur n'a pas été touché. Le chantier 26
  écrit lui-même que Gabriel n'a encore rien entendu du lot 7 ; c'est toujours
  la seule validation qui manque à tout le lot 6 et au lot 7.
- `Sources/Audio`, `Haptics`, `UI` (+256 lignes) ne sont dans aucune cible de
  test ; lus, pas exécutés.

---

## 7. Si un lot 9

Par rendement, sans toucher au modèle avant la quatrième ligne :

1. **Réécrire trois paragraphes** : « plus rien » → la liste du § 4 ; la
   conclusion sur les cibles de 2003 et 2007, aux quatre endroits ; le signe
   dans le chantier 27. Une heure.
2. **Faire sortir la prose du README de `readme-tables.py`** — les dix-sept
   chiffres de T2. ~30 lignes de Python ; c'est ce qui empêche la récidive.
3. **Armer les tests** : T4 avec `.era`, la borne de T5 remise à 2 (ou bilatérale),
   l'audit d'allocation sur la galerie en release (T8), `concurrent` sans
   défaut (T13). ~100 lignes de tests.
4. **Décider pour `ThinkModel`** : revenir à 0,19 / 0,15, ou remplacer les
   cibles. La décision est à Gabriel ; la mesure est au § 3.
5. **Sourcer ou déclarer** : la commutation de tête sur la table 4-3 du
   Fireball, le niveau des seeks sur les cinq manuels, « Read-on-arrival » à
   retirer comme source ; `plannedPositioning` à rederiver.
6. **Sortir le journal du code** (T14), et appliquer la règle des docstrings
   aux huit fichiers de T9.
