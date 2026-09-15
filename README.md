# DiskNoise — spike

Simulation d'I/O **au niveau bloc** d'un disque dur à plateaux, convertie en son
via AVFAudio. Application iOS de démonstration, avec deux scénarios :

- **Démarrage** — « démarrage Windows puis lancement d'une suite bureautique »,
  une minute, sur un IDE de 2001 ;
- **Défragmentation** — passe complète du défragmenteur de Windows 95 sur un
  volume FAT16 vieilli, trois minutes, sur un disque de 1996.

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

**Géométrie** — deux disques. Celui de 2001 : 20 Go, 24 000 cylindres, 4 têtes,
7 200 tr/min, 12 zones ZBR (468 → 248 secteurs par piste). Celui de 1996, pour la
défragmentation : 876 Mo, 2 000 cylindres, 4 têtes, 4 500 tr/min, 8 zones
(256 → 172). Le cylindre 0 est au bord : les fichiers système d'une installation
fraîche occupent donc les cylindres extérieurs, et le bruit de boot reste confiné
à une zone étroite. Conversion LBA→CHS par recherche dichotomique, le zonage
interdisant une formule fermée.

Seules la table de zones et les constantes de seek distinguent les deux — le
disque de 1996 a un bras plus lourd et un asservissement plus lent : 3,0 ms
piste-à-piste, ~12 ms en seek moyen, 22 ms en pleine course, et un settle deux
fois plus long, qui s'entend (chaque arrêt « traîne »).

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

## Le scénario de défragmentation

Inspiré de [defrag95](https://github.com/keithadler/defrag95), qui mesure ce
qu'aurait valu un défragmenteur ordonnant le volume par usage. Ici on ne mesure
rien : on **écoute** la passe que Windows 95 livrait réellement.

**Le volume** — partition FAT16 de 180 Mo en tête d'un disque de 876 Mo, clusters
de 4 Ko, occupant les 21 % extérieurs du plateau. Elle est vieillie par deux ans
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
géométrie zonée s'interpole entre les deux disques modélisés à la main, et la
loi de seek garde sa forme en se recalibrant sur la course et le seek moyen
annoncés. Un 210 Mo à 3 600 tr/min de 1993 ne sonne pas comme un 1 Go à
5 400 tr/min de 1996.

**Huit scénarios sur vingt y ont droit** : ceux de 1993 et 1996. Au-delà, le
bouton reste visible mais éteint, avec la raison écrite dessous — le
défragmenteur simulé est celui de Windows 95, qui ne connaît que la FAT16, et
un volume NTFS de 320 Go n'a de toute façon pas vocation à y passer.

Ces passes-là sont longues : de 17 min (`gamer-1993`) à 51 min
(`famille-1996`), contre un peu plus de trois minutes pour le scénario livré,
dont le volume est délibérément réduit. C'est la vraie durée d'une passe
d'époque sur un volume d'époque. La planification et la simulation coûtent 70 à
190 ms en release, du même ordre que la passe livrée.

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
- **La passe de défragmentation est raccourcie par la taille du volume, pas par
  une accélération.** 180 Mo se défragmentent en trois minutes ; un volume de
  l'époque réellement dimensionné (500 Mo à 1 Go) en prenait vingt à
  quarante-cinq. Le modèle est le même, le volume est plus petit.
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

`swift test` ne couvre que `Sources/DiskCore`, le seul paquet SPM. La couche
`Sources/Model` — volume FAT16, planificateur de défragmentation, construction
des scénarios — se vérifie par le rendu hors-ligne ci-dessous, qui la compile
et la fait tourner en entier.

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
```

L'outil imprime le RMS et la crête par phase, ce qui permet de vérifier que la
dynamique du scénario tient. Mesures actuelles sur l'étage tête seul : ~20 dB
entre la lecture séquentielle du noyau et le crépitement des pilotes, et **88 %
de l'énergie entre 1,5 et 8 kHz**, conforme aux mesures publiées sur des seeks
piste-à-piste répétés.

## Structure

```
Sources/DiskCore/          noyau, paquet SPM sans UI ni audio, mode langage Swift 6
    DriveGeometry.swift    géométrie zonée, LBA→CHS ; disques 2001 et 1996,
                           et interpolation pour une capacité quelconque
    SeekModel.swift        loi de durée, découpage en quatre phases,
                           recalibrage sur une course et un seek moyen donnés
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
    Volume.swift           partition FAT16, allocateur next-fit, vieillissement
    DefragJob.swift        planificateur de la passe de défragmentation
    DiskSimulator.swift    rejeu des requêtes → chronologie mécanique
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
