# DiskNoise — spike

Simulation d'I/O **au niveau bloc** d'un disque dur à plateaux, convertie en son
via AVFAudio. Application iOS de démonstration, avec deux scénarios :

- **Démarrage** — « démarrage Windows puis lancement d'une suite bureautique »,
  une minute, sur un Seagate Barracuda ATA IV de 20 Go (2001) ;
- **Défragmentation** — passe complète du défragmenteur de Windows 95 sur un
  volume FAT16 vieilli, 3 min 24, sur un Quantum Fireball 1080AT (1996).

Spike : l'objectif est de valider la chaîne complète et le réglage du synthé,
pas de livrer une bibliothèque.

## Chaîne

```
scénario de phases                     volume FAT16 vieilli
        │ WorkloadGenerator                     │ DefragPlanner
        │ localité, débit, rafales              │ empaquetage, évacuations, FAT
        └───────────────┬───────────────────────┘
                        ▼
requêtes bloc                     (date, LBA, nb secteurs, R/W)
        │  DiskSimulator          LBA→CHS zoné, seek, latence rotationnelle, transfert
        ▼
chronologie mécanique             seek / commutation de tête / pas de piste / transfert
        │  AudioCueBuilder        regroupement des seeks rapprochés, filtrage des tics
        ▼
repères audio
        │  SeekSynth · SpindleVoice
        ▼
AVAudioEngine
```

## Ce qui est modélisé

**Géométrie** — deux disques qui ont existé, repris de leurs fiches.

Celui du démarrage est un **Seagate Barracuda ATA IV ST320011A** de 2001 :
20 Go, 63 800 pistes, 7 200 tr/min, 791 → 435 secteurs par piste, soit 48,6 Mo/s
au bord et 26,7 au moyeu. **Un seul plateau, une seule face utilisée** : pas une
commutation de tête de tout le démarrage. Son bras est léger et son
asservissement rapide — 0,95 ms piste-à-piste, 9,0 ms en seek moyen, 16 ms en
pleine course.

Celui de la défragmentation est un **Quantum Fireball 1080AT** de 1996 : 1,08 Go,
3 835 pistes, quatre faces, 5 400 tr/min, 166 → 111 secteurs par piste, soit
7,6 Mo/s au bord et 5,1 au moyeu. Bras plus lourd, asservissement plus lent —
3,0 ms piste-à-piste, 12,0 ms en seek moyen, 21,6 ms en pleine course, et un
settle deux fois plus long, qui s'entend : chaque arrêt « traîne ».

Le cylindre 0 est au bord : les fichiers système d'une installation fraîche
occupent donc les cylindres extérieurs, et le bruit de boot reste confiné à une
zone étroite. Conversion LBA→CHS par recherche dichotomique, le zonage
interdisant une formule fermée.

**Un disque quelconque se déduit de sa fiche commerciale — et de son année.**
C'est ce dont la galerie a besoin : elle décrit ses disques par une capacité, un
régime et une date, jamais par une géométrie. La capacité seule ne suffit pas à
décrire un disque, et c'est tout le problème : le même gigaoctet est un disque
entier de 3 835 pistes en 1996 et un coin de plateau lu cinq fois plus vite en
2003.

Le modèle interpole donc dans le temps entre sept disques **réellement vendus**,
de 1993 à 2008, dont les fiches sont recopiées dans `DriveCatalog` avec leur
source — plus une huitième, variante à un plateau de celle de 2001, qui ne sert
pas d'ancrage mais porte le scénario de démarrage. Ce qu'il interpole, ce ne sont pas des « densités » en général mais les
deux seules grandeurs que ces fiches publient sans ambiguïté :

- le nombre de **pistes par face**, qui fixe la course du bras, donc toute
  l'acoustique des seeks ;
- la **capacité d'une face**, qui, rapportée à la capacité demandée, fixe le
  nombre de plateaux.

Les secteurs par piste ne sont pas un troisième paramètre libre : ils tombent du
quotient des deux. Une capacité sans rapport avec son époque — un 6,4 Go en
1996 — n'étire pas la densité linéaire, qui est une propriété du canal de
lecture : elle ajoute des plateaux, puis de la surface, et le modèle le dit.

Trois contrôles tiennent l'ensemble, tous dans les tests : les huit disques du
catalogue sont retrouvés à partir de leur seule fiche, à 2 % sur la course ; le
**débit** de la piste externe retombe à 20 % près sur celui des manuels, alors
qu'il n'entre dans aucun calcul ; et une fiche n'entre au catalogue qu'après
vérification croisée par ce même débit — c'est ce contrôle qui a fait écarter la
géométrie « native » d'un Quantum Fireball ST 6.4AT, qui donnerait 6,5 Mo/s là
où son fabricant en annonce 16.

Ce que remplace ce modèle faisait tout porter à la densité linéaire, avec un seul
exposant calé sur les deux disques ci-dessus : il donnait 640 cylindres à un
disque de 1993 qui en avait 1 806, et 235 000 à un 320 Go de 2007 qui en a
160 000. Dans les deux cas la course était fausse d'un facteur trois, et le débit
avec.


**Seek** — loi à deux régimes de Ruemmler & Wilkes (IEEE Computer 27(3), 1994) :
`a + b·√d` pour les seeks courts, `c + e·d` au-delà du cylindre de croisement.
La forme fonctionnelle vient de l'article, **les constantes sont recalibrées**
pour un disque de 2001 (1,1 ms piste-à-piste, 8,7 ms en seek moyen, 18 ms pleine
course) : les coefficients publiés valent pour des disques HP des années 90.
Chaque seek est découpé en *speedup / coast / slowdown / settle* ; un seek court
n'a pas de phase de coast, ce qui fait varier la **forme** de l'enveloppe avec la
distance et pas seulement son amplitude.

**Latence rotationnelle et transfert** — simulés secteur par secteur, avec pas de
piste et commutation de tête en fin de cylindre. Le bras est parqué au diamètre
intérieur au repos : le premier accès après la mise en rotation est une course
quasi complète, d'où le « clac » franc du boot.

**Timbre de la tête** — banc de résonateurs à **fréquences fixes** (modes ~4,5 kHz
sway et ~5,5 kHz, plus cinq autres), excité par un profil de courant dérivé des
quatre phases. Les résonances structurelles de l'actionneur ne se transposent pas
avec la vitesse de seek : seule l'excitation change. L'amplitude et le dosage des
modes varient avec la distance parcourue — courbe réglée à l'oreille, aucune
source ne donne de loi exploitable.

**Trains de seeks** — deux seeks rapprochés ne relancent jamais deux one-shots.
Ils sont fusionnés en un rendu continu passé **une seule fois** dans le banc de
résonateurs, avec le transitoire terminal replacé en fin de train. Règle héritée
de l'émulation de lecteur de disquette de MAME, où relancer l'échantillon de pas
donnait un résultat « much too loud, and it sounds weird ».

**Retour haptique** — le Taptic Engine reçoit les mêmes repères que l'audio, donc
sans resynchronisation. Un seek isolé est rendu par ses quatre phases : choc à la
mise en mouvement, événement continu sourd pendant le coast (absent des seeks
courts, qui n'ont pas de palier), choc à la décélération, tic sec
d'asservissement en fin de course. La distance module l'intensité **et** la
netteté — une course d'une piste donne un tic léger et sec, une pleine course un
choc fort et sourd.

Les trains rapprochés ne sont pas envoyés en salve de transitoires : à 150 seeks
par seconde le moteur écrête et la main ne perçoit qu'une bouillie. Ils passent
en événement continu modulé par une courbe d'intensité échantillonnée sur la
densité du train, avec quelques transitoires espacés d'au moins 45 ms pour le
grain. Un grondement de rotation en boucle, dont l'intensité suit la vitesse du
plateau, est réglable séparément — il masquerait les transitoires au même niveau.

**Le plateau affiché sort de la même trace que le son.** Le bras est parqué au
moyeu tant que rien n'a été lu, descend piste après piste pendant une lecture
séquentielle, et s'élance vers l'accès suivant au dernier moment — pas plus tôt,
un disque ne déplace pas sa tête pour l'immobiliser ensuite le temps que le
secteur arrive. La seule licence est l'angle : un plateau qui tourne cent vingt
fois par seconde n'est pas affichable sur un écran à soixante images, il est donc
**ralenti d'un facteur cent**, le même pour tout — repères de rotation et accès
de la traînée tournent ensemble, parce que les données sont gravées sur le
plateau. Le rapport entre disques, lui, est conservé : un 3 600 tr/min de 1993
tourne deux fois moins vite à l'écran qu'un 7 200 de 2003. Un accès naît sous la
tête puis dérive avec le disque ; une lecture séquentielle y dessine une spirale.

## Le scénario de défragmentation

Inspiré de [defrag95](https://github.com/keithadler/defrag95), qui mesure ce
qu'aurait valu un défragmenteur ordonnant le volume par usage. Ici on ne mesure
rien : on **écoute** la passe que Windows 95 livrait réellement.

**Le volume** — partition FAT16 de 180 Mo en tête du Fireball de 1,08 Go,
clusters de 4 Ko, occupant les 14 % extérieurs du plateau — elle s'arrête au
cylindre 537 sur 3 835. Elle est vieillie par deux ans
d'usage simulé : installation de Windows puis des applications, création du
fichier d'échange, et 220 « journées » de créations de temporaires, de purges de
cache et de réenregistrements de documents. L'allocateur reproduit celui de
VFAT — **next-fit** : le premier cluster libre *à partir du dernier alloué*, avec
retour au début en fin de volume. C'est tout ce qu'il faut pour que les fichiers
éclatent ; aucun mécanisme exotique n'intervient. Résultat : 504 fichiers, 11 %
fragmentés, 102 trous dans l'espace libre.

**La passe** — « défragmentation complète (fichiers et espace libre) » : chaque
fichier est rendu contigu et tassé contre le début du volume, dans l'ordre du
parcours de l'arborescence, seul ordre dont l'outil disposait. Trois
conséquences, et ce sont elles qu'on entend :

- la destination d'un fichier est presque toujours occupée par un autre, qu'il
  faut d'abord **évacuer** vers la fin du volume — et qui sera relu puis
  redéplacé quand viendra son tour. 392 fichiers déplacés, mais 935 évacuations :
  c'est ce va-et-vient, pas le volume de données, qui fait durer une passe ;
- chaque déplacement validé réécrit les deux copies de la FAT et l'entrée de
  répertoire, toutes trois au tout début de la partition. Le bras revient donc
  au bord du plateau environ une fois par fichier ;
- le fichier d'échange est ouvert par Windows : il ne bouge pas, et tout est
  tassé autour de lui. C'est le bloc rouge immobile de la carte.

**La durée est fixée par la simulation, pas décrétée.** Le scénario est en
**boucle fermée** : toutes les opérations sont émises à l'instant zéro et c'est
le disque qui décide du rythme — seek, latence rotationnelle, transfert. Les
phases affichées sur la chronologie ne sont donc datées qu'*après* la simulation.

**La carte des clusters** est rejouée sur la même horloge que l'audio : un bloc
change de couleur exactement quand son écriture s'entend. Comme sur l'original,
un bloc affiché vaut plusieurs clusters — 35 ici, soit 140 Ko.

## Les disques d'époque

Second écran de l'application : une galerie de volumes vieillis, cinq époques
et quatre profils chacune, générés à la demande sur l'appareil.

**La fragmentation n'est pas un paramètre, c'est un résidu.** On ne demande
jamais « un disque à 23 % de fragmentation ». On écrit une histoire — une
installation, des compilations, des enregistrements, des téléchargements, des
mises à jour, ce qu'on entasse et le moment où l'on fait enfin le ménage — et
on la rejoue à travers l'allocateur du système de fichiers visé. Ce qui sort
tombe tout seul, avec la bonne texture.

L'histoire est écrite **avant** toute allocation et ne connaît rien du format :
la même journée de développeur, rejouée sur les trois allocateurs, donne trois
volumes qui n'ont rien à voir, et toute la différence vient du placement.

|                | FAT16 32 Ko | FAT32 4 Ko | NTFS 4 Ko |
|---|---|---|---|
| fichiers fragmentés | 14,5 % | 3,1 % | 1,4 % |
| pire fichier | 7 extents | 98 extents | 4 extents |
| trous dans l'espace libre | 3 | 502 | 107 |
| slack | 13,8 % | 1,5 % | 1,4 % |

**Les trois stratégies.** MS-DOS sert le premier cluster libre à partir du
début du volume, à chaque écriture : les trous se rebouchent aussitôt, le début
du disque devient un gruyère dense et les fichiers récents sont hachés. VFAT
puis FAT32 reprennent au dernier cluster alloué : l'écriture est propre tant
que le curseur avance, puis il revient au début et repasse par-dessus des trous
laissés des mois plus tôt — la fragmentation arrive par vagues. NTFS choisit le
trou qui convient plutôt que le premier venu, réserve 12,5 % du volume à sa MFT
et n'y touche qu'au-delà de 87 % de remplissage : les fichiers restent
contigus bien plus longtemps, et le jour où ça lâche, ça lâche d'un coup.

**Ce qui se mesure.** Le slack de 1996 est là où on l'attend : sur une
population de documents Word, des clusters de 32 Ko perdent 31 % du volume
contre 2 % en FAT32 — un tiers de disque en plus pour le même contenu. Un
`gamer-2003` fraîchement installé n'a pas un seul fichier en deux morceaux. Un
poste DOS de 1993 après deux ans en a 71 %.

**Deux cibles ne sont pas atteintes**, et les tests le disent plutôt que de
l'arrondir : `dev-1996` donne 11 % de fichiers fragmentés au lieu des 35 à 50 %
visés, et `famille-2003` 2 % au lieu de 40 à 60 %. Le premier écart vient de la
population : trois mille des cinq mille fichiers du volume viennent d'une
installation écrite d'affilée sur un disque vierge, si bien que le taux global
plafonne — alors que les fichiers de sortie sont bel et bien en 290 morceaux.
Le second vient de NTFS lui-même, qui place encore bien à 93 % de remplissage.

**Coût.** Le volume le plus lourd — un Vista de 250 Go, trois ans d'historique,
2,7 millions d'événements — se génère en 2,0 s en release. La génération tourne
hors du fil principal, rapporte son avancement et s'annule si l'on change de
scénario en route.

### Défragmenter un disque généré

Les deux écrans se rejoignent par un bouton : **Défragmenter ce disque** confie
le volume affiché au simulateur, qui en planifie la passe et la fait sonner.

Les fichiers gardent exactement les clusters que l'allocateur leur a donnés —
c'est ce volume-là qui est défragmenté, pas une approximation — et le matériel
est celui de la fiche du profil, pas le disque de 1996 du scénario livré : la
géométrie est celle des disques vendus l'année du scénario, et la loi de seek
passe par les **deux** durées que publie une fiche — le seek moyen et le
piste-à-piste. C'est leur rapport qui distingue une époque d'une autre : entre
1993 et 2003 le seek moyen n'a été divisé que par 1,5, le piste-à-piste par 3.
Un 210 Mo à 3 600 tr/min de 1993 ne sonne pas comme un 1 Go à 5 400 tr/min de
1996, et n'en est pas loin de sonner comme un 40 Go de 2003.

**Les vingt scénarios y ont droit.** Ni la taille ni le format ne limitent plus
rien : le planificateur travaille en extents, et un volume de 320 Go ne lui
coûte pas plus cher qu'un de 180 Mo. Ce qui change avec le format, c'est
l'**outil** — parce que c'est lui que le format datait.

#### Deux défragmenteurs, pas un

Sur un volume FAT, c'est la passe livrée avec Windows 95 puis 98 : tasser tous
les fichiers contre le début du volume, dans l'ordre du parcours de
l'arborescence. Sur un volume NTFS, c'est le `dfrg.msc` de Windows XP, dérivé
de Diskeeper Lite — l'outil qu'un utilisateur de 2003 ou 2007 avait réellement
sous la main, et qui fait un autre métier : il ne range pas le volume, il
répare les fichiers cassés, en les recopiant dans un trou déjà libre par blocs
de 4 Mo. Il n'évacue personne, et la validation d'un déplacement n'est plus
trois écritures au bord du plateau mais un enregistrement de MFT, là où il
vit — donc plus de « clac … clac … clac ».

L'écart n'est pas de degré. Passer la stratégie de 95 sur le 320 Go de
`famille-2007` tassait trois cents gigaoctets par tampons de 256 Ko : vingt-huit
millions de requêtes, quatre-vingt-quatorze heures de passe simulée, pour ranger
244 fichiers sur 12 220. La passe de XP sur le même volume tient en **78 797
requêtes et 23 min 38**.

| scénario NTFS     | plein | requêtes | durée      | déplacés | fragmentés avant → après |
|-------------------|------:|---------:|-----------:|---------:|--------------------------|
| `gamer-2003`      |   8 % |       17 |      7,8 s |        0 | 0 → 0                    |
| `secretaire-2003` |  94 % |    7 455 |   2 min 23 |       57 | 141 → 84                 |
| `famille-2003`    |  93 % |    9 190 |   2 min 32 |       39 | 80 → 41                  |
| `dev-2003`        |  94 % |   19 353 |   5 min 58 |      260 | 299 → 39                 |
| `secretaire-2007` |  88 % |   35 408 |  15 min 27 |      186 | 186 → **0**              |
| `famille-2007`    |  93 % |   78 797 |  23 min 38 |       89 | 244 → 155                |
| `gamer-2007`      |  90 % |   76 425 |  27 min 31 |      131 | 192 → 61                 |
| `dev-2007`        |  86 % |  280 595 | 1 h 12 min |      172 | 172 → **0**              |

La colonne qui compte est la dernière : cet outil-là ne déloge personne, donc
il échoue quand aucun trou n'est à la taille, et il le dit dans son rapport.
Mais **ce n'est pas le remplissage qui décide**. `dev-2003` et
`secretaire-2003` sont deux volumes de 40 Go remplis à 94 % : le premier répare
260 fichiers sur 299, le second 57 sur 141. Ce qui les sépare est la taille de
ce qu'il y a à réparer — 11 Mo par fichier déplacé chez le développeur, 21 Mo
chez la secrétaire, et 213 Mo sur le 320 Go de `famille-2007`, qui n'en répare
qu'un tiers. Un volume plein garde des trous ; il ne garde pas de *grands*
trous, et c'est un gros fichier fragmenté qui n'a nulle part où aller.

Les 15 % d'espace libre que demandait Microsoft vont dans ce sens, mais la
mesure ne suffit pas à l'établir : la taille moyenne citée ici est celle des
fichiers que la passe a **réussi** à déplacer, pas de ceux qui sont restés en
morceaux. Le vérifier demanderait de compter les échecs par taille.

Ces passes FAT-là sont longues : de 31 min (`dev-1993`) à 5 h 04 (`dev-1999`),
contre 3 min 24 pour le scénario livré, dont le volume est délibérément réduit.
C'est la vraie durée d'une passe d'époque sur un volume d'époque, et ce n'est
pas la taille du volume qui la fixe : `secretaire-1993`, le plus petit disque de
la galerie, y passe 66 minutes — 170 Mo dont 71 % des fichiers sont en morceaux,
lus à 1,8 Mo/s — quand `dev-1996`, six fois plus gros, en prend 36.

Ce qui la fixe, c'est le **remplissage**. Un volume plein n'a plus où évacuer :
à 76 % de remplissage la passe livrée déplace 231 Mo pour ranger un volume de
179 Mo, à 93 % `dev-1999` en déplace 44 938 pour 6 710 — sept fois son propre
contenu, en 23 284 évacuations. C'est ce va-et-vient que l'on entend, et c'est
pour cela que l'outil d'époque demandait de faire de la place avant de le
lancer.

Le rendu hors-ligne accepte les mêmes identifiants :

```sh
SCENARIO=dev-1993 /tmp/rendertrace dev1993.wav
```

## Ce qui ne l'est pas

- **La couche rotation est procédurale, et c'est le maillon faible.** La
  littérature et tous les projets qui fonctionnent bouclent un enregistrement ;
  synthétiser le ronronnement à partir du régime a été explicitement invalidé.
  Ici, l'essentiel de l'énergie est du bruit filtré par trois résonances, la
  composante tonale à tr·min⁻¹/60 restant discrète. **À remplacer par un sample
  CC0 bouclé.**
- Aucun échantillon n'est embarqué : tout est synthétisé. Pour la couche tête
  c'est défendable, c'est justement la couche où aucun asset isolé de seek sain
  n'est disponible en CC0.
- Pas de réordonnancement d'ascenseur, pas de cache disque, pas de NCQ. File
  FIFO : représentatif d'un contrôleur IDE de l'époque, et c'est ce qui rend le
  crépitement si dense.
- **Tout est calculé avant que le premier son ne sorte.** La passe entière —
  requêtes, chronologie mécanique, repères audio — est matérialisée en mémoire :
  1,1 million de requêtes et 780 Mo de pic pour `dev-1999`, un FAT32 de 6,4 Go
  rempli à 93 %. Tenable sur un Mac, à la limite sur un téléphone, et c'est ce
  qui plafonne la taille des volumes bien avant le planificateur, qui lui ne
  connaît que des extents. Une passe rendue **au fil de l'eau**, sur une fenêtre
  de quelques secondes d'avance, lèverait cette limite ; c'est le chantier
  suivant.
- **La passe de défragmentation est raccourcie par la taille du volume, pas par
  une accélération.** 180 Mo se défragmentent en 3 min 24 ; un
  volume de l'époque réellement dimensionné (500 Mo à 1 Go) en prend vingt-sept
  à soixante-deux, et la galerie le montre. Le modèle est le même, le volume est
  plus petit.
- Le défragmenteur modélisé ne fait pas de passe de vérification, ne relit pas
  ce qu'il vient d'écrire et ne reprend pas une passe interrompue. Les entrées
  de répertoire sont réduites à une écriture d'un secteur dans la racine.
- Le mixage des transitoires s'appuie sur `scheduleBuffer(at:)` et l'horloge du
  player node. Suffisant pour une démo ; une version robuste rendrait tout dans
  un unique `AVAudioSourceNode` piloté par une file d'événements.
- Les haptiques sont programmées sur l'horloge de `CHHapticEngine`, l'audio sur
  celle du player node. Les deux dérivent du même compte à rebours, mais rien ne
  garantit un alignement à la milliseconde entre les deux moteurs.
- `SpindleVoice` échange ses consignes entre thread principal et thread audio par
  des `Double` non synchronisés. Acceptable ici, à reprendre avant production —
  c'est la seule entorse restante au modèle de concurrence, et le compilateur ne
  la voit pas : la voix est confinée à l'acteur principal, seul le callback de
  rendu d'`AVAudioSourceNode` la lit depuis le thread audio.

## Concurrence

Tout le projet compile en **mode langage Swift 6**, vérification stricte des
données partagées comprise : le paquet `DiskCore` (`swiftLanguageMode(.v6)`),
la cible application (`SWIFT_VERSION = 6.0`, plus
`SWIFT_APPROACHABLE_CONCURRENCY`) et l'outil de rendu hors-ligne
(`swiftc -swift-version 6`).

Le découpage qui rend cela tenable :

- `DiskCore`, `Sources/Model` et la couche DSP de `Sources/Audio` n'ont aucune
  isolation : ce sont des calculs purs, appelables depuis n'importe quel fil.
  `SeekSynth` est `Sendable` — tout son état est immuable — d'où la possibilité
  de rendre un train de crépitements sur une tâche détachée.
- `DiskNoiseEngine`, `DiskHaptics`, `SimulationModel` et `DiskLibraryModel` sont
  `@MainActor` : ils pilotent des objets AVFoundation, Core Haptics et l'état
  publié de l'interface.
- Les allers-retours entre les deux se font par valeurs `Sendable` et retours
  explicites sur l'acteur principal, jamais par `@unchecked Sendable`.

## Lancer

```sh
xcodegen generate
open DiskNoise.xcodeproj
```

Le noyau se construit et se teste sans passer par Xcode :

```sh
swift build
swift test
```

`swift test` couvre le noyau `DiskCore` et la couche défragmentation —
plan de partition, volume en extents, planificateur, simulateur mécanique. Ces
fichiers-là appartiennent à l'application, qui les compile de son côté ; le
paquet les compile une seconde fois sous le nom `DefragKit`, pour pouvoir les
tester sans avoir à rendre publique la moitié de la couche. Ce qui reste hors
tests — construction des scénarios, modèles d'interface — se vérifie par le
rendu hors-ligne ci-dessous, qui compile et fait tourner la chaîne entière.

Ou directement :

```sh
xcodebuild -project DiskNoise.xcodeproj -scheme DiskNoise \
    -destination "platform=iOS Simulator,id=<UDID>" \
    -derivedDataPath .build/DerivedData build
```

Le schéma construit en **Debug** : le produit est dans
`.build/DerivedData/Build/Products/Debug-iphonesimulator/`. Un
`Release-iphonesimulator/` laissé par un archivage précédent y traîne
volontiers — installer celui-là donne l'impression que la compilation n'a rien
changé.

## Rendu hors-ligne

Pour auditionner et régler le synthé sans passer par le simulateur — bien plus
rapide en boucle d'itération :

```sh
./Tools/build-render.sh
/tmp/rendertrace sortie.wav                         # scénario de démarrage
SCENARIO=defrag /tmp/rendertrace defrag.wav         # passe de défragmentation
SCENARIO=dev-1993 /tmp/rendertrace dev1993.wav      # passe sur un disque généré

SPINDLE_GAIN=0 /tmp/rendertrace tete-seule.wav      # isoler une couche
TRANSIENT_GAIN=0 /tmp/rendertrace rotation-seule.wav

PLAN_ONLY=1 SCENARIO=dev-1999 /tmp/rendertrace x.wav  # bilan seul, sans rendu
```

`PLAN_ONLY` s'arrête au bilan de la passe — volume, déplacements, évacuations,
octets déplacés — sans rendre une note. C'est ce qu'il faut pour juger d'un
planificateur : une passe d'époque sur un volume d'époque dure des heures, et
son rendu pèse des gigaoctets.

L'outil imprime le RMS et la crête par phase, ce qui permet de vérifier que la
dynamique du scénario tient. Mesures actuelles sur l'étage tête seul : ~20 dB
entre la lecture séquentielle du noyau et le crépitement des pilotes, et **88 %
de l'énergie entre 1,5 et 8 kHz**, conforme aux mesures publiées sur des seeks
piste-à-piste répétés.

## Structure

```
Sources/DiskCore/          noyau, paquet SPM sans UI ni audio, mode langage Swift 6
    DriveGeometry.swift    géométrie zonée, LBA→CHS ; déduction d'un disque
                           quelconque à partir de sa fiche et de son année
    DriveCatalog.swift     huit disques réellement vendus, 1993 → 2008, avec
                           leurs sources ; densités interpolées dans le temps,
                           et les deux disques des scénarios livrés
    SeekModel.swift        loi de durée, découpage en quatre phases, calage
                           sur le seek moyen et le piste-à-piste d'une fiche
    SeededGenerator.swift  SplitMix64, tirages stables entre plateformes
    Extent.swift           suite de clusters contigus, huit octets
    ClusterBitmap.swift    occupation des clusters, recherche de place libre
    AccessCost.swift       temps de lecture d'une liste d'extents
    FileSystemProfile.swift  contraintes d'un format : cluster, résidence, slack
    Allocator.swift        protocole de placement, indices, entrée de fichier
    Allocators/            FAT (scan depuis le début ou next-free) et NTFS
    FileCatalog.swift      arborescence, extents, métadonnées
    WritePattern.swift     motifs d'écriture
    EventTimeline.swift    suite datée d'événements, indépendante du format
    Simulator.swift        rejeu de la timeline, progression, annulation
    AllocationMetrics.swift  mesures de sortie
    SizeModel.swift        distributions de tailles, par catégorie
    AppManifest.swift      manifestes d'installation, par règles
    ProfileSpec.swift      format déclaratif d'un scénario, calendrier
    ScenarioCompiler.swift  description d'un usage → suite d'événements
    ScenarioLibrary.swift  chargement des scénarios embarqués
    DiskGenerator.swift    point d'entrée : une description, un disque
    Resources/scenarios/   vingt scénarios : cinq époques, quatre profils
Sources/Model/
    Workload.swift         phases du scénario, générateur de requêtes déterministe
    VolumeLayout.swift     plan d'une partition FAT16, FAT32 ou NTFS : où sont
                           les métadonnées, et ce que coûte une validation
    Volume.swift           volume vieilli sur place, allocateur next-fit
    DefragVolume.swift     le volume vu par le défragmenteur : bitmap, fichiers
                           décrits par extents, index des occupants par blocs
    DefragJob.swift        types du plan, et choix de la stratégie sur le format
    DefragStrategy.swift   ce qu'est un défragmenteur : phases, plan, et les
                           fabriques d'opérations communes à tous
    Windows95Strategy.swift  tasser le volume contre son début (FAT16, FAT32)
    WindowsXPStrategy.swift  réparer les seuls fichiers cassés (NTFS)
    DiskSimulator.swift    rejeu des requêtes → chronologie mécanique
    Platter.swift          position du bras et rotation du plateau à l'image,
                           interpolées depuis la trace
    Scenario.swift         construction des scénarios, séries d'affichage
    SimulationModel.swift  assemblage + interrogation pour l'UI
    GeneratedVolume.swift  passerelle disque généré → volume et matériel
Sources/Audio/
    Biquad.swift           filtres RBJ, bruit xorshift
    SeekSynth.swift        banc de résonateurs, excitation, trains
    SpindleVoice.swift     couche continue procédurale
    AudioCue.swift         chronologie mécanique → repères audio
    DiskNoiseEngine.swift  graphe AVAudioEngine, transport, programmation
Sources/Haptics/
    DiskHaptics.swift      Core Haptics : motifs de seek, texture des trains
Sources/UI/                SwiftUI : plateau, carte des clusters, chronologie,
                           transport, mixage
Tools/RenderTrace/         rendu hors-ligne en WAV
```

## Journal de bord

[`LEDGER.md`](LEDGER.md) garde la trace de ce que chaque chantier a décidé, de
ce qu'il a mesuré et de ce qu'il laisse ouvert — y compris les fiches écartées
et les tentatives sans effet. Ce README décrit le modèle tel qu'il est ; le
journal dit pourquoi il est ainsi.

## Pistes

1. Remplacer la couche rotation par un sample CC0 bouclé (spin-up, boucle,
   spin-down) — le gain de réalisme le plus élevé pour l'effort le plus faible.
2. Enregistrer un vrai disque pour caler les fréquences et les Q du banc par
   analyse spectrale, plutôt qu'à l'oreille.
3. Brancher la simulation sur de vraies traces d'I/O plutôt que sur un scénario
   déclaratif.
4. Ajouter d'autres géométries (15 000 tr/min SCSI, disquette) : seules la table
   de zones et les constantes de seek changent.
5. Comparer à l'oreille deux politiques de rangement sur le même volume — l'ordre
   par répertoire de Windows 95 contre l'ordre par usage de defrag95. Le
   planificateur est déjà isolé du reste ; il n'y a qu'une seconde politique à
   écrire.
