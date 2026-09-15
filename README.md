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
  des `Double` non synchronisés. Acceptable ici, à reprendre avant production.

## Lancer

```sh
xcodegen generate
open DiskNoise.xcodeproj
```

Ou directement :

```sh
xcodebuild -project DiskNoise.xcodeproj -scheme DiskNoise \
    -destination "platform=iOS Simulator,id=<UDID>" \
    -derivedDataPath .build/DerivedData build
```

## Rendu hors-ligne

Pour auditionner et régler le synthé sans passer par le simulateur — bien plus
rapide en boucle d'itération :

```sh
./Tools/build-render.sh
/tmp/rendertrace sortie.wav                         # scénario de démarrage
SCENARIO=defrag /tmp/rendertrace defrag.wav         # passe de défragmentation

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
Sources/Model/
    DriveGeometry.swift    géométrie zonée, LBA→CHS ; disques 2001 et 1996
    SeekModel.swift        loi de durée, découpage en quatre phases
    Workload.swift         phases du scénario, générateur de requêtes déterministe
    Volume.swift           partition FAT16, allocateur next-fit, vieillissement
    DefragJob.swift        planificateur de la passe de défragmentation
    DiskSimulator.swift    rejeu des requêtes → chronologie mécanique
    Scenario.swift         construction des deux scénarios, séries d'affichage
    SimulationModel.swift  assemblage + interrogation pour l'UI
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
