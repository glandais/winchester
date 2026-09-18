# DiskNoise — spike

Simulation d'I/O **au niveau bloc** d'un disque dur à plateaux, convertie en son
via AVFAudio. Application iOS de démonstration, avec deux démos prêtes à
écouter, qui tournent l'une et l'autre sur un disque de la galerie :

- **Démarrage** — Windows 98 SE puis Office 97 sur `secretaire-1999`, un FAT32
  de 4,2 Go vieilli par deux ans de bureautique : 51,0 s, dont 40 % d'attente du
  disque, et 6 % de plus que le même contenu jamais fragmenté ;
- **Défragmentation** — tassage à la frontière sur `dev-1993`, un FAT16 de
  210 Mo plein à 69 % : 5 min 46, 1 414 fichiers déplacés, et un volume qui sort
  sans un seul fichier déplaçable en morceaux.

Et une galerie de vingt disques d'époque, générés sur l'appareil, qu'on peut
**démarrer**, **installer**, **défragmenter** ou **revivre** à voix haute — les
deux démos n'étant que deux d'entre eux, sous un nom et un outil choisis.

Spike : l'objectif est de valider la chaîne complète et le réglage du synthé,
pas de livrer une bibliothèque.

## Chaîne

```
catalogue d'un volume généré                       volume à ranger
    │ BootPlanner · InstallSession · DaySession         │ DefragPlanner
    │ quels fichiers, dans quel ordre,                  │ empaquetage,
    │ calcul entre deux lectures                        │ évacuations, FAT
    └──────────────────────────┬────────────────────────┘
                               ▼
requêtes bloc, une à une         (date, LBA, nb secteurs, R/W) — OperationSink
        │  DiskMechanics          LBA→CHS zoné, seek, latence rotationnelle, transfert
        ▼
chronologie mécanique             seek / commutation de tête / pas de piste / transfert
        │  CueStream              regroupement des seeks rapprochés, filtrage des tics
        ▼
paquets datés                     repères, échantillons du plateau, mutations de la
        │  PassPipeline           carte, tranches d'activité — PassSession les tamponne
        ▼                         quelques secondes devant l'écoute
LivePass (l'instant présent)
        │  SeekSynth · SpindleVoice · DiskHaptics · SwiftUI
        ▼
AVAudioEngine
```

**Rien n'est calculé d'avance.** Le planificateur tourne sur son propre fil et
émet ses opérations au lieu de les empiler ; chacune traverse aussitôt le
simulateur, la construction des repères et la datation, et le résultat attend
l'écoute dans un tampon. Le fil s'endort dès qu'il a huit secondes d'avance.
L'écran, le son et l'haptique ne lisent que l'instant présent : il n'y a plus ni
durée connue à l'avance ni retour en arrière, et revenir au début, c'est relancer
la passe. Le calcul est **identique** à celui d'un bloc : même chronologie, mêmes
repères, même WAV à l'échantillon près sur les 48 scénarios de référence.

## Ce qui est modélisé

**Géométrie** — deux disques qui ont existé, repris de leurs fiches. Ils ne
portent plus de scénario — les démos tournent sur des disques de la galerie,
dont la géométrie est déduite de leur fiche et de leur année — mais ils restent
les points d'ancrage du modèle, et les tests les mesurent.

Le premier est un **Seagate Barracuda ATA IV ST320011A** de 2001 :
20 Go, 63 800 pistes, 7 200 tr/min, 791 → 435 secteurs par piste, soit 48,6 Mo/s
au bord et 26,7 au moyeu. **Un seul plateau, une seule face utilisée** : pas une
commutation de tête de tout le démarrage. Son bras est léger et son
asservissement rapide — 0,95 ms piste-à-piste, 9,0 ms en seek moyen, 16 ms en
pleine course.

Le second est un **Quantum Fireball 1080AT** de 1996 : 1,08 Go,
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
pas d'ancrage et portait le scénario de démarrage avant qu'il passe sur un
disque de la galerie. Ce qu'il interpole, ce ne sont pas des « densités » en général mais les
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
piste et commutation de tête en fin de cylindre. Une requête qui déborde du
dernier cylindre est tronquée, comme le ferait le disque. Le bras est parqué au
diamètre intérieur au repos : le premier accès après la mise en rotation est une
course quasi complète, d'où le « clac » franc du boot.

**Le disque au repos fait encore deux choses.** Une seconde après la dernière
requête, le bras **retourne se parquer** — la même course que le « clac »
d'ouverture, dans l'autre sens, et c'est elle qui referme une passe au lieu d'un
blanc. Et quand la chronologie coupe le moteur, le plateau **redescend par la
même loi du premier ordre** qu'il est monté : sans couple, il continue de tourner
encore `v·τ` tours. Les têtes sont toujours parquées avant la coupure, faute de
quoi il n'y aurait plus de coussin d'air pour les porter.

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
séquentielle, s'en retourne se parquer une fois le travail fini, et s'élance vers
l'accès suivant au dernier moment — pas plus tôt,
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

**Le volume** est celui de `dev-1993`, un disque de la galerie comme un autre :
210 Mo en FAT16, clusters de 4 Ko — ceux que `FORMAT` donnait sous 256 Mo —, sur
un IDE de 1993 à 3 600 tr/min. Il est vieilli par deux ans d'usage simulé :
installation de MS-DOS puis de Windows, création du fichier d'échange, et des
journées de compilations, de temporaires et d'archives. L'allocateur est celui
de MS-DOS — le premier cluster libre **depuis le début du volume**, à chaque
écriture. C'est tout ce qu'il faut pour que les fichiers éclatent ; aucun
mécanisme exotique n'intervient. Résultat : 4 016 fichiers, 8 % fragmentés en
1 024 morceaux, 60 trous dans l'espace libre, à 69 % de remplissage.

**La passe** — « défragmentation complète (fichiers et espace libre) » : chaque
fichier est rendu contigu et tassé contre le début du volume, dans l'ordre du
parcours de l'arborescence, seul ordre dont l'outil disposait. Trois
conséquences, et ce sont elles qu'on entend :

- la destination d'un fichier est presque toujours occupée par un autre, qu'il
  faut d'abord **évacuer** vers la fin du volume — et qui sera relu puis
  redéplacé quand viendra son tour. Sur ce volume-là, l'outil de 95 déplace
  3 984 fichiers et évacue 5 008 fois : c'est ce va-et-vient, pas le volume de
  données, qui fait durer une passe — 29 min 24, quand le tassage à la
  frontière, qui ne déloge presque personne, finit en 5 min 46 ;
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
un bloc affiché vaut plusieurs clusters — 43 ici, soit 172 Ko.

Les fichiers **d'un seul tenant** y sont d'un cinquième plus sombres que les
fichiers fragmentés de leur catégorie, comme les données optimisées du
défragmenteur de Windows 95 : on voit ce qui est rangé et ce qui reste à
recoller. Un bloc prend la nuance que porte la majorité des clusters de sa
catégorie dominante. Quand un déplacement **partiel** change l'état d'un
fichier — JkDefrag qui en coupe un autour d'un immobile, UltraDefrag qui en
recolle un — les morceaux restés en place changent de teinte avec la validation
du déplacement.

Elle s'ouvre **en plein écran**, et la grille se dérive alors de la surface
disponible plutôt que d'être figée : le repliement en lignes n'a aucune
signification physique — la carte est une suite linéaire de clusters — donc on
prend le découpage qui remplit l'écran, soit 16 808 blocs sur un iPhone 17 Pro
Max en paysage. À cette finesse un bloc vaut encore des milliers de clusters sur
un volume de 320 Go, et sa couleur ne peut plus être celle d'une catégorie
majoritaire : elle est **modulée par le taux de remplissage** du bloc, de sorte
qu'un bloc à moitié occupé n'ait pas l'air plein. Les accès y laissent une
rémanence de 0,34 s, fondue sur l'âge comme la traînée du plateau.

Rien de tout cela n'est tenu cluster par cluster : la carte est une suite de
plages, et un volume de 320 Go coûte 2,6 Mo au lieu de 78.

Une image ne recalcule que les blocs qu'une mutation a touchés depuis la
précédente, et rend le même tableau quand aucune n'est tombée : la vue ne refait
alors pas son image. L'écran recouvert par le plein écran cesse de suivre
l'horloge, et se remet à l'heure quand on en sort ; un onglet caché aussi.

Sur NTFS, `$Boot`, la MFT et `$MFTMirr` n'appartiennent à aucun fichier du
catalogue, mais occupent le volume : la carte les peint de la couleur des tables
FAT, celle de ce que le système de fichiers se réserve pour lui-même. Une zone
MFT qui cède ne laisse donc pas croire que la MFT est un trou.

## Les disques d'époque

L'onglet **Disques** de l'application : les deux démos, prêtes à écouter et
posées sur deux disques de la galerie qu'elles nomment, puis une galerie de
volumes vieillis, cinq époques et quatre profils
chacune, en cartes qu'on filtre par année et par profil. Un disque se génère
sur l'appareil quand on ouvre sa fiche, pas avant : la galerie ne connaît sa
fragmentation qu'une fois qu'il a été fabriqué. Les trois autres onglets sont la
**Passe** en cours, ses **Instruments** et les **Réglages** du son ; hors de
l'onglet Passe, un bandeau garde la passe sous la main.

Les **Instruments** lisent la passe à l'instant écouté : IOPS, débit et seeks de
la dernière minute ; depuis le début, la part du temps passée à déplacer le
bras, à attendre le secteur, à transférer, à calculer et à attendre la machine,
la distance des seeks rapportée à la course, les cylindres visités, et les
fichiers déplacés et évacuations tels que la stratégie les compte. Ces mesures
sont tenues à côté de la chronologie, jamais dedans : la mécanique cumule ses
temps, les tranches d'activité en gardent le détail, et chaque stratégie publie
ses compteurs sur le récepteur comme elle y publie son avancement. Rien de ce
qui s'entend n'en dépend.

Une passe entendue jusqu'au bout laisse un **bilan** : les cartes du volume
avant et après, les chiffres avant → après, et la phrase de l'outil. Depuis
lui, on relance **un autre outil** sur le même volume de départ, on **compare**
deux passes en colonnes, sans verdict, ou on **démarre le disque rangé**. Pour
ce dernier, le plan d'une passe garde où chaque fichier a fini
(`DefragPlan.arrangement`), et `GeneratedDisk.rearranged(extents:)` repose ces
extents dans le catalogue d'origine, refait la bitmap et les métriques : le
démarrage lit alors les fichiers là où l'outil les a mis, et se compare au
démarrage du même disque vieilli comme au témoin.

**Construire un disque usagé.** L'assistant de l'onglet Disques écrit un
`ProfileSpec` en six étapes — matériel, format, système et logiciels, période,
habitudes, graine — et le fabrique comme un scénario du bundle. On y règle une
histoire, jamais une fragmentation : elle ne se lit qu'une fois le disque
fabriqué, et « refaire avec les mêmes habitudes » sur un autre format montre ce
que le seul allocateur change. Un profil écrit à la main est relu avant d'être
fabriqué (`ProfileSpec.issues`) : ce qui arrêterait le générateur bloque, ce qui
est anachronique avertit. Les disques construits sont gardés dans « Mes
disques » — leur histoire seulement, en JSON : le volume se refait à l'identique
depuis la graine.

**Son, fond et accessibilité.** Le mixage se règle par préréglages — Casque,
Haut-parleur, Vibrations seules — et survit à l'app (`SoundMix`). Une passe
continue écran verrouillé, avec lecture et pause dans le centre de contrôle ; le
mode ambiance l'assombrit et l'arrête en fondu à l'heure dite. Un appel ou un
casque retiré met la passe en pause au lieu de laisser courir son horloge en
silence. La première ouverture présente ce qu'on entend et ce que montre la
carte ; les explications sont des fiches derrière un ⓘ à côté des chiffres. Les
polices suivent la taille de texte jusqu'à AX3, VoiceOver lit la carte en quatre
zones (`MapZone`), et « Réduire les animations » arrête le plateau et la
rémanence de la carte.

**La fragmentation n'est pas un paramètre, c'est un résidu.** On ne demande
jamais « un disque à 23 % de fragmentation ». On écrit une histoire — une
installation, des compilations, des enregistrements, des téléchargements, des
mises à jour, ce qu'on entasse et le moment où l'on fait enfin le ménage — et
on la rejoue à travers l'allocateur du système de fichiers visé. Ce qui sort
tombe tout seul, avec la bonne texture.

L'histoire est écrite **avant** toute allocation et ne connaît rien du format :
la même journée de développeur, rejouée sur les trois allocateurs, donne trois
volumes qui n'ont rien à voir, et toute la différence vient du placement.

**Un chemin ne désigne qu'un fichier présent.** L'histoire nomme les fichiers
d'après ce qu'ils sont — `MODULE.C`, `SAVE.DAT`, `M0.OBJ` — sans savoir ce qui
existe encore le jour où ils sont écrits. Une passe sur la chronologie triée
rejoue créations et suppressions, et donne à chaque nom déjà porté un alias à
la manière de Windows (`MODULE~1.C`), sans distinction de casse. Un nom libéré
par une suppression est repris tel quel. Aucun tirage n'est consommé : la
disposition sur le disque ne change pas, mais les tris et les départages par
chemin des défragmenteurs redeviennent un ordre unique.

|                | FAT16 32 Ko | FAT32 4 Ko | NTFS 4 Ko |
|---|---|---|---|
| fichiers fragmentés | 14,5 % | 3,1 % | 1,4 % |
| pire fichier | 7 extents | 98 extents | 339 extents |
| trous dans l'espace libre | 3 | 502 | 293 |
| slack | 13,8 % | 1,5 % | 1,4 % |

**Les trois stratégies.** MS-DOS sert le premier cluster libre à partir du
début du volume, à chaque écriture : les trous se rebouchent aussitôt, le début
du disque devient un gruyère dense et les fichiers récents sont hachés. VFAT
puis FAT32 reprennent au dernier cluster alloué : l'écriture est propre tant
que le curseur avance, puis il revient au début et repasse par-dessus des trous
laissés des mois plus tôt — la fragmentation arrive par vagues. NTFS choisit le
trou qui convient plutôt que le premier venu, et réserve 12,5 % du volume à sa
MFT. Il n'y touche que quand le reste du volume est plein, et alors il n'en rend
que la moitié libre, puis la moitié de ce qui reste la fois suivante : les
fichiers restent contigus bien plus longtemps, et la MFT garde de quoi grandir
jusqu'au bout.

**Ce qui se mesure.** Le slack de 1996 est là où on l'attend : sur une
population de documents Word, des clusters de 32 Ko perdent 31 % du volume
contre 2 % en FAT32 — un tiers de disque en plus pour le même contenu. Un
`gamer-2003` fraîchement installé n'a pas un seul fichier en deux morceaux. Un
poste DOS de 1993 après deux ans en a 70 %.

**Trois cibles ne sont pas atteintes**, et les tests le disent plutôt que de
l'arrondir : `dev-1996` donne 8 % de fichiers fragmentés au lieu des 35 à 50 %
visés, `secretaire-1999` 6 % au lieu de 15 à 25 %, et `famille-2003` 11 % au
lieu de 40 à 60 %. Le premier écart vient de la population : trois mille des cinq
mille fichiers du volume viennent d'une installation écrite d'affilée sur un
disque vierge, si bien que le taux global plafonne — alors que les fichiers de
sortie sont bel et bien en 423 morceaux. Le troisième vient de NTFS lui-même,
qui place encore bien à 95 % de remplissage. Le deuxième était atteint jusqu'à
ce que le hint système cesse de renvoyer les DLL au cluster 0 sur FAT32 : ce
mécanisme-là n'a jamais existé, et il fabriquait de la fragmentation. Ce qui
manque aux trois est le même — un fichier n'est ici fragmenté que si l'espace
libre l'était déjà, faute d'allocation incrémentale et d'entrelacement.

**Coût.** Le volume le plus lourd — un Vista de 250 Go, trois ans d'historique,
2,7 millions d'événements — se génère en 1,4 s en release, dont 0,4 s pour les noms uniques. Il passe de longues
périodes plein hors de sa zone MFT, où chaque écriture va chercher des trous
épars sur tout le volume : c'est un index à deux niveaux au-dessus de la bitmap
qui saute les régions pleines, sans rien changer à la place trouvée. La génération tourne
hors du fil principal, rapporte son avancement et s'annule si l'on change de
scénario en route.

### Démarrer un disque généré

La galerie mène à la passe par quatre boutons, qui lancent la lecture et
ouvrent l'onglet **Passe**. Le premier, **Démarrer cet OS**, confie le disque
affiché au simulateur, qui en joue le démarrage.

**Le démarrage livré décrit le disque en fractions ; celui-ci le décrit en
fichiers.** Le premier dit « les pilotes sont à 7,5 % du plateau, la base de
registre à 12,5 % » — des constantes réglées à l'oreille pour un disque de 2001,
qui ne veulent rien dire sur un 210 Mo de 1993. Le second ne nomme aucune
position : il dit « charge le noyau », « charge les pilotes », « lance
l'application », et va chercher dans le **catalogue du volume** les fichiers qui
répondent à cette description — avec exactement les extents que l'allocateur
leur a donnés. Où va la tête est alors un résidu de l'histoire du volume,
comme la fragmentation en est un.

Rien n'est refusé ici : lire des fichiers ne suppose aucune stratégie de
rangement, donc **les vingt profils démarrent** — et il n'a même pas fallu, pour
cela, écrire un chargeur par format. Là où la défragmentation a demandé deux
outils parce que le format datait l'outil, un démarrage n'en demande aucun : il
ouvre des fichiers.

**La durée n'est pas décrétée, elle est mesurée.** Un démarrage n'est pas une
suite de lectures collées : entre deux fichiers, la machine décompresse,
relocalise, initialise, et le disque attend. Ce temps de calcul est le
**plancher** d'un démarrage — deux constantes par époque, calées pour que le
total tombe sur les durées d'alors — et tout ce qui dépasse ce plancher est du
disque. Sur les vingt profils il pèse entre 30 et 65 % du total, et les vingt
démarrages tiennent entre 25,6 et 57,9 s.

| | système | fichiers | lu | durée | dont calcul | témoin |
|---|---|---|---|---|---|---|
| `gamer-1993` | MS-DOS 6.22 et Windows 3.1 | 96 | 7 Mo | 28,0 s | 30 % | +1 % |
| `dev-1993` | MS-DOS 6.22 et Windows 3.1 | 121 | 15 Mo | 39,2 s | 36 % | +0 % |
| `gamer-1996` | Windows 95 | 346 | 39 Mo | 43,0 s | 44 % | +5 % |
| `famille-1999` | Windows 98 SE | 618 | 122 Mo | 57,9 s | 55 % | +6 % |
| `secretaire-1999` | Windows 98 SE | 534 | 105 Mo | 51,0 s | 55 % | +6 % |
| `gamer-2003` | Windows XP | 912 | 228 Mo | 55,8 s | 65 % | −0 % |
| `dev-2003` | Windows XP | 386 | 174 Mo | 40,1 s | 62 % | −2 % |
| `famille-2007` | Windows Vista | 517 | 116 Mo | 31,5 s | 46 % | +6 % |

**Le témoin** est la colonne qui compte. C'est le même contenu posé comme au
premier jour — mêmes fichiers, mêmes tailles, chacun d'un seul tenant, tassé
contre le début du volume, derrière la zone que NTFS réserve à sa MFT. Seule la
place change. Sans lui une durée de démarrage ne dit rien : on ne saurait pas ce
qui, dedans, vient du disque.

Et ce qu'il dit est inattendu deux fois. **Sur les volumes FAT, la
fragmentation ne coûte presque rien à un démarrage** : de 0 à 7 %. La raison
tient en une phrase — un démarrage lit les fichiers qu'un installeur a écrits
d'affilée sur un disque encore vide, c'est-à-dire la population la **moins**
fragmentée du volume. Les fichiers en morceaux d'un `dev-1996`, ce sont ses
sorties de compilation, que personne ne lit au démarrage. Ce qui fait le bruit,
ce n'est pas que les fichiers soient hachés, c'est **l'ordre dans lequel on les
demande** et **l'étalement** de ce qu'il faut lire. Windows a fini par en tirer
la même conclusion : défragmenter n'accélérait pas le démarrage, et c'est un
rangement à part — `layout.ini` — qui s'en chargeait.

**Sur NTFS, le témoin ne gagne pas toujours.** Sur les huit volumes, l'écart va
de −2 % (`dev-2003`) à +6 % (`famille-2007`), et trois volumes
démarrent aussi vite ou plus vite que leur témoin. NTFS choisit le trou qui
convient plutôt que le premier venu, et sa disposition réelle peut battre un
rangement naïf qui empile tout dans l'ordre du répertoire. Le témoin garde donc
son sens de borne — il dit ce qu'un rangement bête donnerait — mais il n'est pas
un majorant.

**Le préchargeur est la seule différence d'époque qui ne tienne pas au
matériel.** Jusqu'à Windows 98, les fichiers partent dans l'ordre du registre et
le bras suit : sur un volume étalé, c'est du va-et-vient pur. Windows XP a
introduit le préchargeur de démarrage — il garde la trace des derniers
démarrages et **range la liste par position sur le disque**, métadonnées
comprises, pour tout relire d'une course ; Vista a poussé l'idée avec
SuperFetch. Le modèle fait les deux, et le gain est là où on l'attend : sur
`famille-2007`, le seek moyen passe de 105 289 à 34 974 cylindres et le nombre
de seeks de 1 142 à 682. La même étape crépite en 1995 et ronronne en 2003.

Ce qui rend ce préchargement décisif, c'est le format. Sur FAT, ouvrir un
fichier ne coûte presque rien : la table est lue une fois au montage et tient en
mémoire. Sur NTFS, chaque ouverture lit l'enregistrement de MFT qui décrit le
fichier — en tête du volume, quand les données sont ailleurs. Sans lecture
groupée, c'est deux courses quasi complètes du bras par fichier sur un volume de
320 Go, et un démarrage qui ne ressemble à rien : c'est exactement ce que donne
le modèle quand on la lui retire, et c'est pour cela qu'elle y est.

### Installer un disque généré

**Installer ce disque** rejoue le premier jour de son histoire : le système,
puis les applications, dans l'ordre du profil, sur un volume vierge dont la
carte se remplit. Les places sont celles que l'allocateur a données au
générateur (`DiskGenerator.install`), et le disque d'arrivée est exactement
celui que la galerie vieillit. Le bilan propose de le **démarrer tel quel**.

Ce qui fait une installation d'époque est autour des fichiers, et le modèle le
décrit par logiciel (`SetupStyle`) :

- **la source bride la copie** : 45 ko/s pour une disquette, avec une pause à
  chaque changement ; CD de 4x en 1995 à 48x en 2003 ; DVD 16x pour Vista. Plus
  la décompression, par époque ;
- **les archives** : Windows 95 et 98 extraient `WININST0.400` avant de copier ;
  une application sur CD extrait ses CAB dans `\WINDOWS\TEMP`, **les relit
  morceau par morceau** en posant ses fichiers, puis les efface. Ce
  va-et-vient crépite, et l'effacement laisse les premiers trous du volume. Les
  archives font partie du scénario : elles ont bel et bien occupé le disque ;
- **les tables** : sous MS-DOS, la FAT est réécrite à chaque fichier, et le bras
  revient au bord à chaque fois. Sous Windows, le cache les vide par salves
  triées. Sous NT, chaque vidage écrit aussi `$LogFile` ;
- **le registre** (`SYSTEM.DAT` et `USER.DAT`, les ruches de NT) est posé avec le
  système et réécrit en bloc après chaque logiciel ;
- **les redémarrages** — deux ou trois pour un système, un pour une application
  qui remplace des DLL partagées — sont de vrais démarrages, sur ce qui est
  posé jusque-là.

Les attentes humaines (détection du matériel, questions, clic sur
« Redémarrer ») sont raccourcies à quelques secondes. Les vingt installations
durent de 7 à 21 minutes : sur disquettes, la source fait plus des trois quarts
de l'attente ; sur CD et DVD, ce sont la décompression et les pauses.

| | source | posé | archives | redémarrages | durée |
|---|---|---|---:|---:|---:|
| `gamer-1993` | 21 disquettes | 373 fichiers, 39 Mo | 0 | 2 | 12 min 06 |
| `secretaire-1996` | CD-ROM 8x | 1 008 fichiers, 222 Mo | 46 | 3 | 7 min 04 |
| `famille-1999` | CD-ROM 32x | 2 412 fichiers, 574 Mo | 77 | 5 | 8 min 50 |
| `famille-2003` | CD-ROM 48x | 3 388 fichiers, 1,4 Go | 26 | 4 | 8 min 12 |
| `gamer-2007` | DVD 16x | 10 398 fichiers, 13,5 Go | 23 | 3 | 20 min 26 |

### Revivre un disque généré

**Revivre ce disque** rejoue toute son histoire, de l'installation au dernier
jour. Deux vitesses s'y enchaînent, parce qu'une vie ne s'écoute pas d'un bout
à l'autre : l'histoire d'un profil écrit de 0,8 Go (`secretaire-1993`) à 585 Go
(`dev-2007`), et un seek dure ce qu'il dure.

- **Le défilement** ne joue rien. La carte avance d'un jour, d'une semaine ou
  d'un mois par seconde ; le volume se remplit, les fichiers partent en
  morceaux, et deux courbes le montrent. Une vie entière défile en 0,1 s pour un
  disque de 1996, 3,8 s pour les 2,7 millions d'événements de `dev-2007`.
- **Les journées à écouter** sont nommées au passage : l'installation, les caps
  de remplissage, le premier refus d'écriture, les grosses journées, les
  défragmentations de l'histoire, les pics de fragmentation. De 1 à 39 selon les
  profils.
- **Une journée s'écoute en temps réel**, sur le disque tel qu'il est ce
  matin-là. Le défilement reprend ensuite au lendemain.

**Une journée n'est pas une liste d'écritures.** L'histoire du profil ne décrit
que ce qui change sur le disque, daté au jour près ; le reste est remis autour :
la machine qu'on allume, une **séance** par activité — et une de plus à chaque
retour, parce que le cache du navigateur expire pendant qu'on compile —, puis
l'arrêt. Les lectures viennent de ce que l'activité suppose : le compilateur
relit ses sources, l'éditeur de liens relit ses objets avant d'écrire
l'exécutable, on ouvre un document avant de l'enregistrer, lancer un jeu charge
un niveau. Les sources lentes brident le reste — carte mémoire ou CD pour les
médias, la ligne pour les téléchargements, de 1,8 ko/s en 1993 à 1 Mo/s en 2007
— et les attentes sont plafonnées à huit secondes, sans quoi un téléchargement
de 1999 durerait la nuit.

| journée | activités | lu / écrit | durée |
|---|---|---|---:|
| `dev-1996`, jour 20 | navigation, compilation, archivage | 215 / 44 Mo | 5 min 38 |
| `dev-1996`, jour 300 | idem | 231 / 78 Mo | 7 min 02 |
| `famille-2003`, jour 400 | navigation, bureautique, téléchargement, médias | 201 / 16 Mo | 1 min 26 |
| `gamer-1999`, jour 365 | navigation, jeu | 541 / 6 Mo | 1 min 58 |

**L'usure s'entend.** Sur `dev-1996`, la même journée de travail passe d'un seek
moyen de 273 cylindres au jour 20 à 617 au jour 300 : le disque fait la même
chose, il le fait de plus en plus loin.

### Défragmenter un disque généré

L'autre bouton, **Défragmenter ce disque**, confie le volume affiché au
simulateur, qui en planifie la passe et la fait sonner.

Les fichiers gardent exactement les clusters que l'allocateur leur a donnés —
c'est ce volume-là qui est défragmenté, pas une approximation — et le matériel
est celui de la fiche du profil, et non un modèle choisi à côté : la
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

#### Six défragmenteurs, dont deux d'époque

Sur un volume FAT, c'est la passe livrée avec Windows 95 puis 98 : tasser tous
les fichiers contre le début du volume, dans l'ordre du parcours de
l'arborescence. Sur un volume NTFS, c'est le `dfrg.msc` de Windows XP, dérivé
de Diskeeper Lite — l'outil qu'un utilisateur de 2003 ou 2007 avait réellement
sous la main, et qui fait un autre métier : il ne range pas le volume, il
répare les fichiers cassés, en les recopiant dans un trou déjà libre par blocs
de 4 Mo. Il n'évacue personne, et la validation d'un déplacement n'est plus
trois écritures au bord du plateau mais un enregistrement de MFT, là où il
vit — donc plus de « clac … clac … clac ».

Les deux autres ne sont d'aucune époque, et ne se choisissent jamais tout seuls.
**UltraDefrag 7.1.1**, de 2018, répond à un échec des outils d'époque sur les
gros fichiers. **JkDefrag 3.36**, de 2008, est le seul qui range le volume sans
évacuer personne. On les demande explicitement (`STRATEGY=ultraDefrag`,
`STRATEGY=jkDefrag`) pour comparer des passes sur exactement le même volume.
JkDefrag s'obtient aussi dans ses autres modes, décrits plus bas.

Les deux derniers n'imitent aucun outil, et ont été écrits ici à partir de ce
que les quatre autres font mal : le **tassage à la frontière**
(`STRATEGY=frontierCompaction`) pour FAT, et le **recollage économe**
(`STRATEGY=fragmentMerge`) pour les gros volumes NTFS. Ils sont décrits en
dernier.

Dans l'app, tous se choisissent sur l'écran « Avec quel outil ? » qui suit
**Défragmenter ce disque**. L'outil d'époque y est présélectionné ; les deux
outils d'époque et les deux écrits ici ne sont proposés que sur leur format, et
les déplacements par blocs pleins s'y activent pour XP, UltraDefrag et JkDefrag.

L'écart n'est pas de degré. Passer la stratégie de 95 sur le 320 Go de
`famille-2007` tasse trois cents gigaoctets par tampons de 256 Ko : trente-cinq
millions de requêtes, cent vingt heures de passe simulée, pour ranger
560 fichiers sur 12 229. La passe de XP sur le même volume tient en **102 456
requêtes et 28 min 54**.

| scénario NTFS     | plein | requêtes | durée      | déplacés | fragmentés avant → après | morceaux avant → après |
|-------------------|------:|---------:|-----------:|---------:|--------------------------|------------------------|
| `gamer-2003`      |   8 % |       20 |        8 s |        0 | 0 → 0                    | 0 → 0                  |
| `secretaire-2003` |  94 % |    7 282 |   1 min 54 |      197 | 313 → 116                | 27 238 → 23 814        |
| `famille-2003`    |  95 % |   22 787 |   5 min 40 |      408 | 450 → 42                 | 55 614 → 44 745        |
| `dev-2003`        |  95 % |   23 528 |   5 min 54 |       33 | 40 → 7                   | 14 606 → 3 054         |
| `secretaire-2007` |  88 % |   28 373 |  10 min 42 |       47 | 47 → **0**               | 11 808 → **0**         |
| `famille-2007`    |  93 % |  102 456 |  28 min 54 |      410 | 560 → 150                | 188 566 → 142 347      |
| `gamer-2007`      |  90 % |   56 178 |  19 min 30 |      192 | 290 → 98                 | 63 921 → 40 045        |
| `dev-2007`        |  86 % |  294 502 |     1 h 16 |      271 | 271 → **0**              | 135 927 → **0**        |

La colonne qui compte est la dernière : cet outil-là ne déloge personne, donc
il échoue quand aucun trou n'est à la taille, et il le dit dans son rapport.
Et **le remplissage ne suffit pas à le prédire**. `dev-2003` et
`secretaire-2003` sont deux volumes de 40 Go remplis à 94-95 % : le premier
répare 33 fichiers sur 40, le second 197 sur 313. La taille de ce qu'il y a à
réparer ne l'explique pas non plus — 36 Mo par fichier déplacé chez le
développeur, 3 Mo chez la secrétaire. Ce qui sépare les deux volumes n'est pas établi : il
faudrait compter les échecs par taille, et regarder où tombent les trous.

#### Recoller au lieu de déplacer

UltraDefrag part du constat que ces gros fichiers n'ont **pas besoin d'être
déplacés** pour aller mieux. Un fichier de 213 Mo en quatre morceaux devient
rapide à lire dès qu'on recolle ses trois petits éclats ; le gros bloc, lui, ne
gagne rien à voyager. Sa passe traite les fichiers *les plus fragmentés
d'abord*, recopie entiers ceux qui font moins de 40 Mo, et sur les autres ne
fusionne que les fragments de moins de 20 Mo. C'est ce que la comparaison des
deux bases de code donne comme sans équivalent chez JKDefrag.

Le résultat ne se lit pas dans la colonne « fragmentés », et c'est tout le
sujet : un fichier ramené de quarante morceaux à deux y reste « fragmenté ».

| scénario NTFS     | morceaux restants, XP | UltraDefrag |  requêtes XP → UD |    durée XP → UD |
|-------------------|----------------------:|------------:|------------------:|-----------------:|
| `secretaire-2003` |                23 814 |      12 656 |   7 282 → 31 376  | 1 min 54 → 7 min 52 |
| `famille-2003`    |                44 745 |      21 622 |  22 787 → 70 215  | 5 min 40 → 18 min 56 |
| `dev-2003`        |                 3 054 |     **209** |  23 528 → 29 456  | 5 min 54 → 7 min 34 |
| `secretaire-2007` |                     0 |           0 |  28 373 → 26 035  | 10 min 42 → 10 min 51 |
| `famille-2007`    |               142 347 |   **1 637** | 102 456 → 383 076 | 28 min 54 → 1 h 36 |
| `gamer-2007`      |                40 045 |     **570** |  56 178 → 130 604 | 19 min 30 → 39 min 36 |
| `dev-2007`        |                     0 |          54 | 294 502 → 280 514 | 1 h 16 → 1 h 26 |

Sur `famille-2007`, les 142 347 morceaux que XP laisse derrière lui tombent à
**1 637** — 99 % de moins — pendant que le nombre de fichiers fragmentés, lui,
monte de 150 à 153. Le prix est près de quatre fois plus de requêtes et un peu
plus de trois fois plus de temps.

Sur NTFS, la passe ne réutilise pas dans un tour l'espace qu'elle vient de
libérer : Windows tient ces clusters pour temporairement alloués jusqu'au
prochain point de contrôle, et UltraDefrag ne relit sa liste de trous qu'en tête
de tour. Ses destinations sont donc plus lointaines — le seek moyen de
`dev-2007` passe de 24 638 à 66 586 cylindres — et un morceau inversé compte
pour deux : la tête le lit dans l'ordre du fichier.

Cela ne fait pas d'UltraDefrag le meilleur outil partout. Les deux volumes que
XP nettoie entièrement, il les nettoie aussi, ni mieux ni plus vite. Et sur un
volume FAT de 1996, où presque aucun fichier n'atteint 40 Mo, la défragmentation
partielle n'a rien à mordre : sur `dev-1996`, la passe tient en 32 s contre
13 min 42 à l'outil de 95, parce qu'elle n'évacue personne. Elle laisse 1 961
morceaux — et l'outil de 95, sur ce volume-là, en laisse 2 496 : à 95 % de
remplissage, il ne trouve plus où évacuer non plus, et saute les places qu'il
ne peut pas libérer.

#### Ranger sans évacuer

JkDefrag joue son mode par défaut, le mode 2, qui enchaîne quatre passes :
recopier les fichiers cassés dans le premier trou à leur taille, ou par tranches
dans les plus grands ; renvoyer chaque fichier dans sa **zone** (les gros, les
archives, les installateurs au fond du volume, derrière les fichiers ordinaires
et une réserve de 1 %) ; combler chaque trou, de bas en haut, par des fichiers
pris plus haut, au cluster près si une combinaison existe, sinon par le plus
haut qui tient ; puis remettre en zone ce que l'optimisation a dérangé. Une
destination est toujours un trou déjà libre.

Sur FAT, il fait en quelques minutes ce que Windows 95 faisait en heures, et il
laisse plus de morceaux derrière lui dès que les trous manquent :

| scénario | plein | durée, 95 → JkDefrag | évacuations, 95 | morceaux restants, 95 → JkDefrag |
|---|---:|---:|---:|---:|
| `dev-1993` | 69 % | 29 min 24 → 5 min 15 | 5 008 | 0 → 0 |
| `dev-1996` | 95 % | 13 min 42 → 4 min 04 | 656 | 2 496 → 838 |
| `secretaire-1999` | 87 % | 4 h 37 → 9 min 07 | 9 145 | 4 → 1 229 |
| `famille-1999` | 96 % | 5 h 52 → 14 min 29 | 8 661 | 1 395 → 3 323 |
| `gamer-1996` | 99 % | 8 s → 8 s | 3 | 1 536 → 1 534 |

À 99 %, il ne fait presque rien : un outil qui n'évacue personne a besoin de
trous. **Et l'outil de 95 non plus** : sur `gamer-1996`, dont les quelques centaines de
clusters libres ne logent aucun de ses gros fichiers, il n'évacue que trois
occupants avant de se retrouver bloqué partout, et rend le volume intact. C'est la limite
réelle de l'algorithme de 1995, et c'est pourquoi l'outil demandait de faire de
la place avant de le lancer.

Sur NTFS, les morceaux restants restent du même ordre de grandeur qu'avec
UltraDefrag, mieux sur deux volumes, moins bien sur trois. Mais la passe range
tout le volume et déplace bien plus que les seuls fichiers cassés — 4,0 Go sur
`gamer-2003`, plein à 8 % et sans un fichier en morceaux :

| scénario | plein | morceaux restants, XP | UltraDefrag | JkDefrag | durée, XP → JkDefrag | Go déplacés, XP → JkDefrag |
|---|---:|---:|---:|---:|---:|---:|
| `secretaire-2003` | 94 % | 23 814 | 12 656 | 6 371 | 1 min 54 → 22 min 50 | 0,6 → 5,2 |
| `famille-2003` | 95 % | 44 745 | 21 622 | 2 176 | 5 min 40 → 30 min 04 | 1,3 → 10,3 |
| `dev-2003` | 95 % | 3 054 | 209 | 134 | 5 min 54 → 12 min 24 | 1,2 → 3,4 |
| `gamer-2003` | 8 % | 0 | 0 | 0 | 8 s → 5 min 56 | 0,0 → 3,9 |
| `famille-2007` | 93 % | 142 347 | 1 637 | 2 162 | 28 min 54 → 2 h 13 | 21,6 → 113,8 |
| `gamer-2007` | 90 % | 40 045 | 570 | 608 | 19 min 30 → 1 h 17 | 22,6 → 91,8 |

La zone MFT que voient ces passes est la zone **courante**, réduite de moitié
chaque fois que le reste du volume s'est rempli, et non la réserve d'origine :
une réserve publiée entière faisait passer à JkDefrag l'essentiel de son temps
à vider de l'espace que Windows avait déjà rendu. Le journal donne l'écart.

`FindBestItem`, la recherche de combinaison exacte, s'arrêtait chez l'original
au bout d'une demi-seconde de temps réel. Elle est bornée ici en visites, pour
que le plan ne dépende pas de la machine ; la borne ne mord sur aucun des vingt
volumes.

#### Tasser, trier

Les autres modes de la ligne de commande de JkDefrag sont là aussi, chacun sous
son identifiant. Ce ne sont pas des variantes du mode 2 mais **une seule
routine**, sans défragmentation devant :

- `jkDefragForcedFill` (`-a 5`) tasse le volume contre son début : chaque trou
  est rempli par la fin du fragment le plus haut. Quelques minutes, et il casse
  plus de fichiers qu'il n'en répare ;
- `jkDefragMoveUp` (`-a 6`) le tasse contre sa fin : chaque trou, du fond vers
  le début, reçoit les fichiers pris **dessous**, en commençant par le plus bas ;
- `jkDefragSortName`, `…Size`, `…Access`, `…Change` et `…Creation` (`-a 7` à
  `-a 11`) reposent chaque fichier à son rang, zone par zone, en **évacuant** ce
  qui occupe la place du suivant. C'est le seul mode de JkDefrag qui déloge.

Un tri est long, et il déplace plus que le volume : ce qu'on évacue redescend
quand vient son tour. Sur `famille-2007`, 430 Go déplacés pour 320, 180 010
évacuations, 7 h 37 de passe contre 2 h 13 pour le mode 2. Sur un volume plein,
ce qui ne trouve pas de place est posé en morceaux : `gamer-2007` en sort avec
29 776 morceaux contre 608. Sur `secretaire-1999`, il en laisse 23 contre
1 229.

Le catalogue ne date que les écritures, au jour près : le dernier accès y est la
dernière écriture, et à jour égal c'est le chemin qui départage — unique, puisque
le générateur ne fait jamais coexister deux fichiers au même chemin.

Ces passes FAT-là sont longues : de 14 min (`dev-1996`) à 6 h 16 (`dev-1999`)
sur les dix volumes où l'outil de 95 a de quoi travailler. C'est la vraie durée
d'une passe d'époque sur un volume d'époque, et c'est pourquoi la démo de
défragmentation a pris un autre outil que celui de 95 — 5 min 46 sur `dev-1993`
au lieu de 29 min 24, pour le même résultat. Ce n'est pas la taille du volume
qui la fixe : `secretaire-1993`, le plus petit disque de la galerie, y passe
1 h 46 — 170 Mo dont 69 % des fichiers fragmentables sont en morceaux, lus à
1,8 Mo/s — quand `dev-1996`, six fois plus gros, en prend 14.

Ce qui la fixe, c'est le **remplissage**. Un volume plein n'a plus où évacuer :
à 69 % de remplissage la passe de `dev-1993` déplace 388 Mo pour ranger un
volume de 220 Mo, à 93 % `dev-1999` en déplace 63 609 pour 6 710 — neuf fois son propre
contenu, en 20 111 évacuations. C'est ce va-et-vient que l'on entend, et c'est
pour cela que l'outil d'époque demandait de faire de la place avant de le
lancer.

#### Tasser sans changer l'ordre

Sur FAT, les outils simulés se partagent deux défauts. Windows 95 range
parfaitement, mais dans un autre ordre que celui du volume : il déplace jusqu'à
neuf fois le contenu du disque. JkDefrag et UltraDefrag ne délogent personne, et
n'ont plus rien à faire quand les trous manquent — à 99 %, ils ne touchent pas
un des 399 fichiers cassés de `gamer-1996`, et l'outil de 95 non plus.

Le **tassage à la frontière** part d'une règle : l'ordre d'arrivée est l'ordre
actuel. Une frontière balaie le volume depuis son début, et tout ce qui est
sous elle est rangé. Un fichier d'un seul tenant qui y commence reste où il est
; un petit trou est comblé au cluster près par des fichiers qui devaient bouger
de toute façon ; sinon, le fichier qui suit le trou **glisse**, par tronçons de
la taille du trou, chacun écrit dans la place que le précédent vient de quitter.
Deux clusters libres suffisent à tasser un volume entier, et le trou grossit en
montant, de tous ceux qu'il absorbe.

Autour de ce geste : les fichiers en morceaux qui tiennent dans un trou y sont
recopiés d'un tenant avant le balayage ; un morceau qui barre la frontière est
poussé au fond du volume, où elle ne le recroisera qu'à la fin ; un gros fichier
qui ne trouvera plus de fenêtre à sa taille entre les morceaux du fichier
d'échange passe avant les autres ; et les tables ne sont écrites qu'une fois
par lot de déplacements, dont aucun n'écrit sur un cluster que le lot vient de
quitter. D'où une garantie qu'aucun outil d'époque n'offrait : **aucune écriture
ne tombe sur une donnée encore référencée**. Une coupure de courant pendant la
passe laisse un volume cohérent.

| scénario | plein | durée, 95 → JkDefrag → frontière | morceaux restants, 95 / JkDefrag / frontière | trous libres, 95 / JkDefrag / frontière |
|---|---:|---:|---:|---:|
| `dev-1993` | 69 % | 29 min 24 → 5 min 15 → **5 min 46** | 0 / 0 / **0** | 2 / 8 / **1** |
| `secretaire-1993` | 88 % | 1 h 46 → 9 min 03 → **15 min 24** | 0 / 0 / **0** | 2 / 149 / **2** |
| `poweruser-1993` | 86 % | 39 min 05 → 5 min 51 → **11 min 35** | 0 / 65 / **0** | 2 / 55 / **1** |
| `gamer-1993` | 99 % | 10 s → 10 s → **32 min 02** | 988 / 977 / **0** | 6 / 13 / **1** |
| `dev-1996` | 95 % | 13 min 42 → 4 min 04 → **14 min 50** | 2 496 / 838 / **339** | 166 / 218 / **62** |
| `famille-1996` | 89 % | 58 min 09 → 6 min 24 → **8 min 32** | 177 / 186 / **177** | 165 / 222 / **89** |
| `secretaire-1996` | 76 % | 42 min 19 → 6 min 30 → **5 min 58** | 2 / 36 / **2** | 3 / 143 / **1** |
| `gamer-1996` | 99 % | 8 s → 8 s → **51 min 54** | 1 536 / 1 534 / **4** | 2 / 2 / **1** |
| `dev-1999` | 93 % | 6 h 16 → 14 min 13 → **37 min 48** | 1 723 / 2 258 / **3** | 255 / 1 477 / **1** |
| `famille-1999` | 96 % | 5 h 52 → 14 min 29 → **38 min 38** | 1 395 / 3 323 / **53** | 511 / 2 247 / **9** |
| `secretaire-1999` | 87 % | 4 h 37 → 9 min 07 → **18 min 18** | 4 / 1 229 / **4** | 5 / 1 041 / **2** |
| `gamer-1999` | 97 % | 22 min 27 → 7 min 36 → **50 min 21** | 6 743 / 1 770 / **112** | 787 / 850 / **11** |

Les morceaux qui restent sont **tous ceux du fichier d'échange**, que personne
ne déplace : aucun fichier déplaçable ne sort de la passe en morceaux. Les trous
qui restent sont entre ces morceaux — sur `dev-1996`, 300 morceaux ne laissent
plus que 2 trous.

Sur les douze volumes, la passe dure 4 h 51 au total contre 21 h 59 pour
Windows 95, et elle déplace cinq fois moins de données (34,2 Go contre 189).
Elle reste trois fois plus longue que JkDefrag (1 h 23), qui ne fait pas le même
travail : sur les quatre volumes de 1999, il laisse entre 1 200 et 3 300 morceaux
et de 850 à 2 250 trous. Et c'est le seul des trois à ranger les deux volumes
pleins à 99 %, où l'algorithme de 1995 ne trouve plus où évacuer et rend le
volume tel quel : là, tout passe par une navette de deux clusters, et chaque
tronçon se paie d'une écriture des tables.

#### Recoller peu, sur les gros volumes

Sur les volumes NTFS de 2003 et 2007, la place ne manque plus — 2 à 33 Go
libres — mais la taille : le tassage à la frontière y déplace tout le contenu
du volume, jusqu'à 339 Go et dix heures de passe. Et la fragmentation y est faite
de miettes. Sur `famille-2007`, 560 fichiers cassés pèsent 249 Go en 188 000
morceaux, dont 187 000 font moins de 4 Mo et ne pèsent que 12 Go. Chacun coûte
pourtant une lecture : c'est leur nombre, pas leur poids, qui fait la durée.

Le **recollage économe** ne déplace donc que ce qui coûte peu. Une suite de
morceaux de moins de 4 Mo est recopiée d'un seul tenant, contre le gros morceau
voisin si le trou qui le borde l'accepte, sinon dans le trou le plus proche ; les
gros morceaux restent où ils sont. Un morceau de 16 Mo au plus rejoint son
voisin quand un trou s'ouvre à côté de lui. Et l'espace libre se consolide avec
de petits fichiers : celui qui sépare deux trous part ailleurs, et les deux trous
n'en font qu'un ; celui qui borde un trou part dans un trou exactement à sa
taille, ou dans un trou plus petit. Les tours se succèdent tant que chacun retire
au moins 1 % des trous.

Deux choses tiennent au format. Les clusters quittés ne resservent qu'au point de
contrôle, tous les seize déplacements, où les enregistrements de MFT et la
bitmap sont écrits d'une traite : aucune écriture ne tombe sur un cluster dont
la libération n'est pas écrite. Et un bloc de 4 à 16 Mo se lit morceau par
morceau puis s'écrit une fois, là où les autres outils font un aller-retour du
bras par morceau. La zone MFT n'est jamais une destination.

| scénario | plein | durée, XP / UltraDefrag / JkDefrag / recollage | morceaux restants | trous libres |
|---|---:|---:|---:|---:|
| `dev-2003` | 95 % | 5 min 54 / 7 min 34 / 12 min 24 / **3 min 19** | 3 054 / 209 / 134 / **149** | 3 462 / 1 000 / 432 / **131** |
| `famille-2003` | 95 % | 5 min 40 / 18 min 56 / 30 min 04 / **12 min 21** | 44 745 / 21 622 / 2 176 / **1 185** | 9 784 / 15 981 / 1 156 / **285** |
| `secretaire-2003` | 94 % | 1 min 54 / 7 min 52 / 22 min 50 / **12 min 16** | 23 814 / 12 656 / 6 371 / **2 913** | 3 633 / 7 811 / 3 395 / **727** |
| `gamer-2003` | 8 % | 8 s / 8 s / 5 min 56 / **8 s** | 0 / 0 / 0 / **0** | 8 / 8 / 16 / **7** |
| `dev-2007` | 86 % | 1 h 16 / 1 h 26 / 2 h 07 / **10 min 27** | 0 / 54 / 0 / **1 059** | 5 580 / 5 619 / 249 / **339** |
| `famille-2007` | 93 % | 28 min 54 / 1 h 36 / 2 h 13 / **22 min 39** | 142 347 / 1 637 / 2 162 / **1 935** | 39 170 / 7 064 / 1 536 / **592** |
| `gamer-2007` | 90 % | 19 min 30 / 39 min 36 / 1 h 17 / **17 min 30** | 40 045 / 570 / 608 / **1 575** | 16 424 / 7 083 / 908 / **646** |
| `secretaire-2007` | 88 % | 10 min 42 / 10 min 51 / 46 min 12 / **3 min 33** | 0 / 0 / 0 / **57** | 3 225 / 3 223 / 192 / **920** |

Sur les huit volumes, la passe dure 1 h 22, contre 2 h 29 pour XP, 4 h 28 pour
UltraDefrag et 7 h 35 pour JkDefrag, et laisse moins de morceaux (8 873) et
moins de trous (3 647) que chacun d'eux. L'écart de durée avec XP et UltraDefrag
tient surtout aux blocs pleins : donnés à ces outils (`FULL_BLOCKS=1`), ils les
ramènent à 1 h 15 et 1 h 31, sans rien changer à ce qu'ils laissent. Ce que la passe apporte en
propre, c'est la qualité à durée égale. Elle ne recopie jamais un fichier
entier : sur `dev-2007`, où un trou de 22 Go accueille tout, XP et JkDefrag
finissent sans un morceau, et elle en laisse 1 059.

Le rendu hors-ligne accepte les mêmes identifiants, préfixés de `boot:` pour le
démarrage :

```sh
SCENARIO=dev-1993 /tmp/rendertrace dev1993.wav        # la passe
SCENARIO=boot:dev-1993 /tmp/rendertrace boot1993.wav  # le démarrage
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
- **Un démarrage décrit en fichiers est moins dense qu'un scénario réglé à
  l'oreille** : 1 115 requêtes pour tout un démarrage de `dev-1996`, contre 90 à
  150 par seconde dans les phases écrites à la main du scénario que la démo a
  remplacé — lequel ne vit plus que dans les tests. Un vrai démarrage consulte le
  registre à chaque périphérique, relit des `.INI`, rouvre des répertoires —
  autant d'accès courts que ce modèle ne pose pas, parce qu'aucun d'eux ne
  correspond à un fichier du catalogue. Le crépitement est donc un peu plus
  clairsemé qu'il ne devrait.
- **On ne navigue plus dans une passe.** Ni tête de lecture à traîner, ni saut
  de cinq secondes, ni durée totale : la passe se calcule pendant qu'on
  l'écoute, et seul son présent est gardé. Le bilan — état d'arrivée, temps
  perdu au démarrage — ne s'affiche qu'une fois la passe entendue jusqu'au bout.
- **Abandonner une passe n'interrompt pas son planificateur**, qui n'a aucun
  point d'arrêt : il cesse de simuler et finit son calcul à vide, quelques
  secondes de processeur au pire.
- **La mémoire d'un gros disque est désormais celle de sa génération**, pas de
  sa passe : `dev-1999` tient à 220 Mo au rendu hors-ligne comme à son
  démarrage, et un NTFS de 2007 reste au-dessus de 700 Mo pour la même raison.
- **Une passe de défragmentation n'est jamais accélérée** : ce qui la raccourcit,
  c'est la taille du volume et l'outil. Les 220 Mo de `dev-1993` se tassent en
  5 min 46 à la frontière et en 29 min 24 sous l'outil de 95 ; un volume de
  l'époque réellement dimensionné (500 Mo à 1 Go) y passe des heures, et la
  galerie le montre. Le modèle est le même dans les trois cas.
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
  explicites sur l'acteur principal.
- **Une exception, bornée à `PassSession.swift`** : le fil producteur d'une
  passe est un `Thread` qui s'endort sur une `NSCondition`, et les trois
  classes qui partagent cet état — la session, sa sortie côté producteur et un
  petit verrou `Locked` — sont `@unchecked Sendable`, tout accès passant par le
  verrou. Les paquets qui traversent sont, eux, de vraies valeurs `Sendable`.
  Un fil plutôt qu'une tâche : le producteur *bloque* quand il a assez d'avance,
  ce qu'une tâche du pool coopératif ne doit pas faire.

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
SCENARIO=boot:dev-1993 /tmp/rendertrace boot.wav    # démarrage d'un disque généré
SCENARIO=install:dev-1993 /tmp/rendertrace inst.wav # installation d'un disque généré
SCENARIO=day:dev-1996:300 /tmp/rendertrace jour.wav # une journée d'usage
SCENARIO=life:dev-1996 /tmp/rendertrace /dev/null   # toute la vie, sans son

SPINDLE_GAIN=0 /tmp/rendertrace tete-seule.wav      # isoler une couche
TRANSIENT_GAIN=0 /tmp/rendertrace rotation-seule.wav

PLAN_ONLY=1 SCENARIO=dev-1999 /tmp/rendertrace x.wav  # bilan seul, sans rendu
STRATEGY=ultraDefrag SCENARIO=famille-2007 /tmp/rendertrace ud.wav  # un autre outil
```

`STRATEGY` force le défragmenteur simulé au lieu de laisser le format le dater :
`windows95`, `windowsXP`, `jkDefrag`, `ultraDefrag`, les autres modes de
JkDefrag : `jkDefragForcedFill`, `jkDefragMoveUp`, `jkDefragSortName`,
`jkDefragSortSize`, `jkDefragSortAccess`, `jkDefragSortChange`,
`jkDefragSortCreation`, `frontierCompaction` et `fragmentMerge`. C'est ainsi que se comparent
deux passes sur exactement le même volume. `FULL_BLOCKS=1` fait déplacer XP,
UltraDefrag et JkDefrag par blocs pleins, comme le recollage économe : c'est
ainsi qu'on compare les algorithmes à primitive égale.

Le rendu est **au fil de l'eau**, comme l'écoute : le son est mixé à mesure
que la passe se planifie, écrit dans un fichier brut dès qu'il est définitif,
puis converti en WAV. Seules quelques secondes restent en mémoire — la passe
livrée se rend en 38 Mo au lieu de 97, `dev-1996` en 154 au lieu d'un
gigaoctet — et le mixage garde l'ordre des additions du rendu d'un bloc, d'où
un WAV identique au bit près.

`PLAN_ONLY` s'arrête au bilan de la passe — volume, déplacements, évacuations,
octets déplacés, morceaux et trous libres restants — sans rendre une note. C'est ce qu'il faut pour juger d'un
planificateur : une passe d'époque sur un volume d'époque dure des heures, et
son rendu pèse des gigaoctets.

L'outil imprime le RMS et la crête par phase, ce qui permet de vérifier que la
dynamique du scénario tient. Mesures actuelles sur l'étage tête seul : ~20 dB
entre la lecture séquentielle du noyau et le crépitement des pilotes, et **88 %
de l'énergie entre 1,5 et 8 kHz**, conforme aux mesures publiées sur des seeks
piste-à-piste répétés.

## Vidéos

Les vidéos de démonstration se rendent **hors de l'application** : la même
passe, le même modèle et la même horloge que le son, dessinés image par image en
Core Graphics et encodés par `ffmpeg` (à installer : `brew install ffmpeg`).

```sh
./Tools/make-videos.sh                    # tout le lot de Tools/videos.txt
./Tools/make-videos.sh defrag-frontiere   # les lignes dont le nom commence ainsi

./Tools/build-render.sh                   # construit aussi /tmp/rendervideo
SCENARIO=windowsBoot /tmp/rendervideo demarrage.mp4
SCENARIO=defrag FIT_SECONDS=180 /tmp/rendervideo defrag-3min.mp4
SCENARIO=dev-1993 LAYOUT=short FIT_SECONDS=58 /tmp/rendervideo short.mp4
SCENARIO=install:secretaire-1996 /tmp/rendervideo installation.mp4
SCENARIO=day:dev-1996:120 /tmp/rendervideo jour120.mp4
MAX_SECONDS=10 SCENARIO=defrag /tmp/rendervideo essai.mp4
```

Chaque vidéo reprend ce que montre la passe dans l'application : la carte des
clusters rejouée — d'une défragmentation, d'une installation qui part d'un
volume vierge, d'une journée d'usage —, le plateau et son bras, la phase,
l'avancement, les déplacements et le débit. Elle se termine sur un bilan de
quelques secondes, avec les chiffres de `PLAN_ONLY`. Deux formats : 1920 × 1080
(`LAYOUT=landscape`) et 1080 × 1920 pour les Shorts (`LAYOUT=short`).

La version **intégrale** a exactement le son de `RenderTrace`, au bit près avant
l'encodage AAC. Une version **accélérée** (`SPEED`, ou `FIT_SECONDS` qui déduit
la vitesse d'une planification à blanc) garde le son tel qu'il est, par
extraits de quatre secondes pris au milieu de ce que l'image montre et enchaînés
en fondu : accélérer le son lui-même en ferait un autre bruit. Tout est en flux,
et une passe de plusieurs heures se rend sans tenir en mémoire, à une centaine
d'images par seconde.

Les vidéos vont dans `.build/videos/`, avec le journal de chaque rendu. Une
vidéo déjà présente n'est pas refaite.

## Structure

```
Sources/DiskCore/          noyau, paquet SPM sans UI ni audio, mode langage Swift 6
    DriveGeometry.swift    géométrie zonée, LBA→CHS ; déduction d'un disque
                           quelconque à partir de sa fiche et de son année
    DriveCatalog.swift     huit disques réellement vendus, 1993 → 2008, avec
                           leurs sources ; densités interpolées dans le temps
    SeekModel.swift        loi de durée, découpage en quatre phases, calage
                           sur le seek moyen et le piste-à-piste d'une fiche
    SeededGenerator.swift  SplitMix64, tirages stables entre plateformes
    Extent.swift           suite de clusters contigus, huit octets
    ClusterBitmap.swift    occupation des clusters, recherche de place libre
                           accélérée par un index des mots qui ont un trou
    AccessCost.swift       temps de lecture d'une liste d'extents
    FileSystemProfile.swift  contraintes d'un format : cluster, résidence, slack
    Allocator.swift        protocole de placement, indices, entrée de fichier
    Allocators/            FAT (scan depuis le début ou next-free) et NTFS
    FileCatalog.swift      arborescence, extents, métadonnées
    WritePattern.swift     motifs d'écriture
    EventTimeline.swift    suite datée d'événements, indépendante du format ;
                           un chemin, un fichier présent
    Simulator.swift        rejeu de la timeline, progression, annulation
    AllocationMetrics.swift  mesures de sortie
    SizeModel.swift        distributions de tailles, par catégorie
    AppManifest.swift      manifestes d'installation, par règles
    HistoryReplay.swift    l'histoire rejouée jour par jour, sur l'allocateur
                           du format : une journée racontée, les autres sautées
    InstallSetup.swift     mise en place d'époque : source, archives, ruches,
                           redémarrages ; étapes et journal d'une installation
    ProfileSpec.swift      format déclaratif d'un scénario, calendrier
    ScenarioCompiler.swift  description d'un usage → suite d'événements
    ScenarioLibrary.swift  chargement des scénarios embarqués
    DiskGenerator.swift    point d'entrée : une description, un disque ; ou
                           son premier jour, rejoué pas à pas
    Resources/scenarios/   vingt scénarios : cinq époques, quatre profils
Sources/Model/
    Workload.swift         requête bloc, et datation des phases après coup
    BootSession.swift      démarrage décrit en fichiers : ce que chaque époque
                           va chercher dans le catalogue, dans quel ordre, et ce
                           que la machine calcule entre deux lectures ; plus le
                           témoin « jamais fragmenté »
    MachineWriter.swift    ce qu'une machine fait subir au disque en écrivant :
                           tampons, tables sales, temps hors disque, carte
    DaySession.swift       une journée d'usage : démarrage, séances, lectures de
                           chaque activité, sources lentes, arrêt
    DiskLife.swift         la vie du disque en accéléré : un relevé par journée,
                           et les journées qui valent d'être écoutées
    InstallSession.swift   installation rejouée : source, décompression,
                           archives relues, tables vidées par salves, registre,
                           redémarrages ; la carte part d'un volume vierge
    VolumeLayout.swift     plan d'une partition FAT16, FAT32 ou NTFS : où sont
                           les métadonnées, et ce que coûte une validation
    Volume.swift           volume en clusters, allocateur next-fit
    DefragVolume.swift     le volume vu par le défragmenteur : bitmap, fichiers
                           décrits par extents, index des occupants par blocs
    DefragJob.swift        types du plan, et choix de la stratégie sur le format
    DefragStrategy.swift   ce qu'est un défragmenteur : phases, plan, les
                           fabriques d'opérations communes à tous, et la
                           recherche de trou
    Windows95Strategy.swift  tasser le volume contre son début (FAT16, FAT32)
    WindowsXPStrategy.swift  réparer les seuls fichiers cassés (NTFS), dans
                           l'ordre de la MFT ou d'un autre outil
    JKDefragStrategy.swift  ranger en trois zones et combler les trous par le
                           haut, sans évacuer personne ; sur demande
    JKDefragFullOptimize.swift  ses autres modes : tasser contre le début ou
                           la fin, trier en évacuant ; sur demande
    UltraDefragStrategy.swift  recoller les petits morceaux des gros fichiers,
                           sur demande et quel que soit le format
    FrontierCompactionStrategy.swift  tasser un volume FAT dans l'ordre où
                           il est, par glissement, sans écrire sur une donnée
                           encore référencée ; sur demande
    FragmentMergeStrategy.swift  recoller les petits morceaux et consolider
                           l'espace libre d'un gros volume NTFS, par blocs
                           pleins et points de contrôle ; sur demande
    DiskSimulator.swift    mécanique du disque, une requête après l'autre
    AudioCue.swift         chronologie mécanique → repères audio, au fil des
                           événements
    OperationSink.swift    là où une stratégie émet ses opérations
    PassPipeline.swift     planificateur → simulateur → repères → paquets datés
    PassSession.swift      le fil producteur, tenu à quelques secondes d'avance
    LivePass.swift         l'instant écouté : fenêtres du plateau, de la carte
                           et de l'activité, file des repères
    Platter.swift          position du bras et rotation du plateau à l'image,
                           interpolées depuis la trace
    ClusterMap.swift       carte du volume par plages, rejeu vers l'avant, grille
                           d'affichage dérivée de la surface, rémanence
    ClusterPalette.swift   couleurs des catégories et teinte proportionnelle
    Scenario.swift         description des scénarios : disque, chronologie,
                           source des requêtes
    SimulationModel.swift  assemblage + interrogation pour l'UI
    GeneratedVolume.swift  passerelle disque généré → volume et matériel
Sources/Audio/
    Biquad.swift           filtres RBJ, bruit xorshift
    SeekSynth.swift        banc de résonateurs, excitation, trains
    SpindleVoice.swift     couche continue procédurale
    DiskNoiseEngine.swift  graphe AVAudioEngine, transport, programmation des
                           repères tirés de la passe, attente du producteur
Sources/Haptics/
    DiskHaptics.swift      Core Haptics : motifs de seek, texture des trains
Sources/UI/                SwiftUI : plateau, carte des clusters, chronologie,
                           transport, mixage
Tools/RenderTrace/         rendu hors-ligne en WAV
Tools/RenderVideo/         rendu hors-ligne en vidéo : carte, plateau, bilan
Tools/Shared/              scénario demandé, mixage en flux et bilan, communs
                           aux deux outils
Tools/make-videos.sh       le lot de vidéos décrit dans Tools/videos.txt
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
5. Écouter les six stratégies sur le même volume. `STRATEGY` les rend déjà
   comparables au rendu hors-ligne, et tout ce qui les sépare est mesuré ; rien
   de tout cela n'a encore été confronté à l'oreille, et l'écran de
   l'application ne propose toujours que l'outil d'époque.
