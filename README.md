# DiskNoise — spike

Simulation d'I/O **au niveau bloc** d'un disque dur à plateaux, convertie en son
via AVFAudio. Application iOS de démonstration, avec deux scénarios livrés :

- **Démarrage** — « démarrage Windows puis lancement d'une suite bureautique »,
  une minute, sur un Seagate Barracuda ATA IV de 20 Go (2001) ;
- **Défragmentation** — passe complète du défragmenteur de Windows 95 sur un
  volume FAT16 vieilli, 3 min 24, sur un Quantum Fireball 1080AT (1996).

Et une galerie de vingt disques d'époque, générés sur l'appareil, qu'on peut
**démarrer** ou **défragmenter** à voix haute.

Spike : l'objectif est de valider la chaîne complète et le réglage du synthé,
pas de livrer une bibliothèque.

## Chaîne

```
scénario de phases      catalogue d'un volume généré      volume à ranger
    │ WorkloadGenerator      │ BootPlanner                      │ DefragPlanner
    │ localité, débit,       │ quels fichiers, dans quel ordre, │ empaquetage,
    │ rafales                │ calcul entre deux lectures       │ évacuations, FAT
    └────────────────────────┴────────────┬─────────────────────┘
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

L'onglet **Disques** de l'application : les deux scénarios livrés, prêts à
écouter, puis une galerie de volumes vieillis, cinq époques et quatre profils
chacune, en cartes qu'on filtre par année et par profil. Un disque se génère
sur l'appareil quand on ouvre sa fiche, pas avant : la galerie ne connaît sa
fragmentation qu'une fois qu'il a été fabriqué. Les trois autres onglets sont la
**Passe** en cours, ses **Instruments** et les **Réglages** du son ; hors de
l'onglet Passe, un bandeau garde la passe sous la main.

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
| pire fichier | 7 extents | 98 extents | 4 extents |
| trous dans l'espace libre | 3 | 502 | 107 |
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
poste DOS de 1993 après deux ans en a 71 %.

**Deux cibles ne sont pas atteintes**, et les tests le disent plutôt que de
l'arrondir : `dev-1996` donne 11 % de fichiers fragmentés au lieu des 35 à 50 %
visés, et `famille-2003` 2 % au lieu de 40 à 60 %. Le premier écart vient de la
population : trois mille des cinq mille fichiers du volume viennent d'une
installation écrite d'affilée sur un disque vierge, si bien que le taux global
plafonne — alors que les fichiers de sortie sont bel et bien en 290 morceaux.
Le second vient de NTFS lui-même, qui place encore bien à 93 % de remplissage.

**Coût.** Le volume le plus lourd — un Vista de 250 Go, trois ans d'historique,
2,7 millions d'événements — se génère en 1,3 s en release, dont 0,4 s pour les noms uniques. Il passe de longues
périodes plein hors de sa zone MFT, où chaque écriture va chercher des trous
épars sur tout le volume : c'est un index à deux niveaux au-dessus de la bitmap
qui saute les régions pleines, sans rien changer à la place trouvée. La génération tourne
hors du fil principal, rapporte son avancement et s'annule si l'on change de
scénario en route.

### Démarrer un disque généré

La galerie mène à la passe par deux boutons, qui lancent la lecture et
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
disque. Sur les vingt profils il pèse entre 29 et 52 % du total, et les vingt
démarrages tiennent entre 29,5 et 68,9 s.

| | système | fichiers | lu | durée | dont calcul | témoin |
|---|---|---|---|---|---|---|
| `gamer-1993` | MS-DOS 6.22 et Windows 3.1 | 95 | 8 Mo | 29,5 s | 29 % | +1 % |
| `dev-1993` | MS-DOS 6.22 et Windows 3.1 | 121 | 15 Mo | 41,8 s | 34 % | +0 % |
| `gamer-1996` | Windows 95 | 346 | 38 Mo | 43,3 s | 43 % | +0 % |
| `famille-1999` | Windows 98 SE | 620 | 122 Mo | 66,7 s | 48 % | +3 % |
| `secretaire-1999` | Windows 98 SE | 504 | 101 Mo | 54,5 s | 49 % | +4 % |
| `gamer-2003` | Windows XP | 912 | 225 Mo | 68,9 s | 52 % | −1 % |
| `dev-2003` | Windows XP | 427 | 178 Mo | 51,0 s | 50 % | −9 % |
| `famille-2007` | Windows Vista | 557 | 124 Mo | 39,3 s | 39 % | +1 % |

**Le témoin** est la colonne qui compte. C'est le même contenu posé comme au
premier jour — mêmes fichiers, mêmes tailles, chacun d'un seul tenant, tassé
contre le début du volume, derrière la zone que NTFS réserve à sa MFT. Seule la
place change. Sans lui une durée de démarrage ne dit rien : on ne saurait pas ce
qui, dedans, vient du disque.

Et ce qu'il dit est inattendu deux fois. **Sur les volumes FAT, la
fragmentation ne coûte presque rien à un démarrage** : de 0 à 4 %. La raison
tient en une phrase — un démarrage lit les fichiers qu'un installeur a écrits
d'affilée sur un disque encore vide, c'est-à-dire la population la **moins**
fragmentée du volume. Les fichiers en morceaux d'un `dev-1996`, ce sont ses
sorties de compilation, que personne ne lit au démarrage. Ce qui fait le bruit,
ce n'est pas que les fichiers soient hachés, c'est **l'ordre dans lequel on les
demande** et **l'étalement** de ce qu'il faut lire. Windows a fini par en tirer
la même conclusion : défragmenter n'accélérait pas le démarrage, et c'est un
rangement à part — `layout.ini` — qui s'en chargeait.

**Sur NTFS, le témoin ne gagne pas toujours.** Sur les huit volumes, l'écart va
de −9 % (`dev-2003`) à +10 % (`famille-2003`), et deux volumes démarrent plus
vite que leur témoin. NTFS choisit le trou qui convient plutôt que le premier
venu, et sa disposition réelle peut battre un rangement naïf qui empile tout
dans l'ordre du répertoire. Le témoin garde donc son sens de borne — il dit ce
qu'un rangement bête donnerait — mais il n'est pas un majorant.

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

### Défragmenter un disque généré

L'autre bouton, **Défragmenter ce disque**, confie le volume affiché au
simulateur, qui en planifie la passe et la fait sonner.

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
évacuer personne. On les demande explicitement pour comparer des passes sur
exactement le même volume : dans l'app, sur l'écran « Avec quel outil ? » qui
suit **Défragmenter ce disque**, où l'outil d'époque est présélectionné ; au
rendu hors-ligne, par `STRATEGY=ultraDefrag` ou `STRATEGY=jkDefrag`. JkDefrag
s'obtient aussi dans ses autres modes, décrits plus bas.

Les deux derniers n'imitent aucun outil, et ont été écrits ici à partir de ce
que les quatre autres font mal : le **tassage à la frontière**
(`STRATEGY=frontierCompaction`) pour FAT, et le **recollage économe**
(`STRATEGY=fragmentMerge`) pour les gros volumes NTFS. Ils sont décrits en
dernier.

L'écart n'est pas de degré. Passer la stratégie de 95 sur le 320 Go de
`famille-2007` tassait trois cents gigaoctets par tampons de 256 Ko : vingt-huit
millions de requêtes, quatre-vingt-quatorze heures de passe simulée, pour ranger
244 fichiers sur 12 220. La passe de XP sur le même volume tient en **69 967
requêtes et 23 min 14**.

| scénario NTFS     | plein | requêtes | durée      | déplacés | fragmentés avant → après | morceaux avant → après |
|-------------------|------:|---------:|-----------:|---------:|--------------------------|------------------------|
| `gamer-2003`      |   8 % |       17 |      7,8 s |        0 | 0 → 0                    | 0 → 0                  |
| `secretaire-2003` |  94 % |    4 819 |   1 min 18 |       68 | 178 → 110                | 26 101 → 23 778        |
| `famille-2003`    |  93 % |    9 144 |   2 min 34 |       27 | 68 → 41                  | 47 063 → 42 617        |
| `dev-2003`        |  94 % |   17 309 |   4 min 50 |       32 | 36 → 4                   | 12 253 → 3 771         |
| `secretaire-2007` |  88 % |   23 962 |   9 min 49 |       49 | 49 → **0**               | 9 662 → **0**          |
| `famille-2007`    |  93 % |   69 967 |  23 min 14 |      118 | 268 → 150                | 163 249 → 132 920      |
| `gamer-2007`      |  90 % |   50 991 |  18 min 42 |       85 | 175 → 90                 | 60 516 → 38 419        |
| `dev-2007`        |  86 % |  258 179 | 1 h 07 min |      176 | 176 → **0**              | 120 211 → **0**        |

La colonne qui compte est la dernière : cet outil-là ne déloge personne, donc
il échoue quand aucun trou n'est à la taille, et il le dit dans son rapport.
Et **le remplissage ne suffit pas à le prédire**. `dev-2003` et
`secretaire-2003` sont deux volumes de 40 Go remplis à 94 % : le premier répare
32 fichiers sur 36, le second 68 sur 178. La taille de ce qu'il y a à réparer
ne l'explique pas non plus — 34 Mo par fichier déplacé chez le développeur,
6 Mo chez la secrétaire. Ce qui sépare les deux volumes n'est pas établi : il
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
| `secretaire-2003` |                23 778 |      14 334 |   4 819 → 25 153  | 1 min 18 → 6 min 24 |
| `famille-2003`    |                42 617 |      14 949 |   9 144 → 66 598  | 2 min 34 → 18 min 04 |
| `dev-2003`        |                 3 771 |      **11** |  17 309 → 24 987  | 4 min 50 → 6 min 48 |
| `secretaire-2007` |                     0 |           0 |  23 962 → 21 684  | 9 min 49 → 9 min 53 |
| `famille-2007`    |               132 920 |   **1 503** | 69 967 → 331 349  | 23 min 14 → 1 h 27 |
| `gamer-2007`      |                38 419 |     **561** | 50 991 → 123 361  | 18 min 42 → 38 min 20 |
| `dev-2007`        |                     0 |          19 | 258 179 → 247 803 | 1 h 07 → 1 h 16 |

Sur `famille-2007`, les 132 920 morceaux que XP laisse derrière lui tombent à
**1 503** — 99 % de moins — pendant que le nombre de fichiers fragmentés, lui,
monte de 150 à 157. Le prix est près de cinq fois plus de requêtes et près de
quatre fois plus de temps.

Sur NTFS, la passe ne réutilise pas dans un tour l'espace qu'elle vient de
libérer : Windows tient ces clusters pour temporairement alloués jusqu'au
prochain point de contrôle, et UltraDefrag ne relit sa liste de trous qu'en tête
de tour. Ses destinations sont donc plus lointaines — le seek moyen de
`dev-2007` passe de 47 430 à 64 868 cylindres — et un morceau inversé compte
pour deux : la tête le lit dans l'ordre du fichier.

Cela ne fait pas d'UltraDefrag le meilleur outil partout. Les deux volumes que
XP nettoie entièrement, il les nettoie aussi, ni mieux ni plus vite. Et sur un
volume FAT de 1996, où presque aucun fichier n'atteint 40 Mo, la défragmentation
partielle n'a rien à mordre : la passe est quarante fois plus courte que celle
de Windows 95 (79 s contre 36 min sur `dev-1996`) parce qu'elle n'évacue
personne, et elle laisse trois fois plus de morceaux derrière elle pour
exactement la même raison.

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
| `dev-1993` | 74 % | 30 min 35 → 4 min 30 | 4 561 | 0 → 0 |
| `dev-1996` | 87 % | 36 min 21 → 5 min 03 | 3 811 | 290 → 334 |
| `secretaire-1999` | 87 % | 3 h 07 → 10 min 19 | 19 595 | 3 → 1 057 |
| `famille-1999` | 97 % | 4 h 29 → 12 min 09 | 11 989 | 8 → 2 739 |
| `gamer-1996` | 99 % | 59 min 18 → 7,9 s | 4 438 | 14 → 1 622 |

À 99 %, il ne fait presque rien : un outil qui n'évacue personne a besoin de
trous.

Sur NTFS, les morceaux restants restent du même ordre de grandeur qu'avec
UltraDefrag, mieux sur deux volumes, moins bien sur trois. Mais la passe range
tout le volume et déplace bien plus que les seuls fichiers cassés — 4,1 Go sur
`gamer-2003`, plein à 8 % et sans un fichier en morceaux :

| scénario | plein | morceaux restants, XP | UltraDefrag | JkDefrag | durée, XP → JkDefrag | Go déplacés, XP → JkDefrag |
|---|---:|---:|---:|---:|---:|---:|
| `secretaire-2003` | 94 % | 23 778 | 14 334 | 5 307 | 1 min 18 → 21 min 25 | 0,4 → 5,6 |
| `famille-2003` | 93 % | 42 617 | 14 949 | 2 128 | 2 min 34 → 28 min 24 | 0,7 → 11,6 |
| `dev-2003` | 94 % | 3 771 | 11 | 25 | 4 min 50 → 11 min 38 | 1,1 → 3,6 |
| `gamer-2003` | 8 % | 0 | 0 | 0 | 7,8 s → 6 min 11 | 0,0 → 4,1 |
| `famille-2007` | 93 % | 132 920 | 1 503 | 2 191 | 23 min 14 → 2 h 02 | 22,9 → 103,1 |
| `gamer-2007` | 90 % | 38 419 | 561 | 1 439 | 18 min 42 → 1 h 15 | 20,6 → 86,9 |

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
quand vient son tour. Sur `famille-2007`, 447 Go déplacés pour 320, 160 570
évacuations, 7 h 24 de passe contre 2 h 02 pour le mode 2. Sur un volume plein,
ce qui ne trouve pas de place est posé en morceaux : `gamer-2007` en sort avec
30 383 morceaux contre 1 439. Sur `secretaire-1999`, il en laisse 14 contre
1 057.

Le catalogue ne date que les écritures, au jour près : le dernier accès y est la
dernière écriture, et à jour égal c'est le chemin qui départage — unique, puisque
le générateur ne fait jamais coexister deux fichiers au même chemin.

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

#### Tasser sans changer l'ordre

Sur FAT, les outils simulés se partagent deux défauts. Windows 95 range
parfaitement, mais dans un autre ordre que celui du volume : il déplace jusqu'à
sept fois le contenu du disque. JkDefrag et UltraDefrag ne délogent personne, et
n'ont plus rien à faire quand les trous manquent — à 99 %, ils ne touchent pas
un des 440 fichiers cassés de `gamer-1996`.

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
| `dev-1993` | 74 % | 30 min 35 → 4 min 30 → **5 min 22** | 0 / 0 / **0** | 2 / 8 / **1** |
| `secretaire-1993` | 90 % | 1 h 05 → 8 min 15 → **14 min 25** | 0 / 0 / **0** | 2 / 104 / **1** |
| `poweruser-1993` | 86 % | 40 min 51 → 6 min 07 → **12 min 04** | 0 / 65 / **0** | 2 / 55 / **1** |
| `gamer-1993` | 99 % | 32 min 36 → 9 s → **26 min 30** | 0 / 941 / **0** | 241 / 7 / **1** |
| `dev-1996` | 87 % | 36 min 21 → 5 min 03 → **9 min 06** | 290 / 334 / **290** | 239 / 285 / **157** |
| `famille-1996` | 89 % | 1 h 01 → 6 min 54 → **10 min 01** | 176 / 193 / **176** | 176 / 312 / **60** |
| `secretaire-1996` | 75 % | 46 min 12 → 7 min 21 → **5 min 46** | 2 / 2 / **2** | 2 / 113 / **1** |
| `gamer-1996` | 99 % | 59 min 18 → 8 s → **53 min 45** | 14 / 1 622 / **5** | 286 / 2 / **1** |
| `dev-1999` | 93 % | 5 h 04 → 17 min 40 → **49 min 45** | 3 / 707 / **3** | 248 / 612 / **1** |
| `famille-1999` | 97 % | 4 h 28 → 12 min 09 → **35 min 29** | 8 / 2 739 / **8** | 312 / 1 563 / **7** |
| `secretaire-1999` | 87 % | 3 h 07 → 10 min 19 → **19 min 00** | 3 / 1 057 / **3** | 4 / 1 067 / **1** |
| `gamer-1999` | 97 % | 4 h 14 → 8 min 55 → **46 min 45** | 89 / 1 394 / **46** | 884 / 915 / **41** |

Les morceaux qui restent sont **tous ceux du fichier d'échange**, que personne
ne déplace : aucun fichier déplaçable ne sort de la passe en morceaux. Les trous
qui restent sont entre ces morceaux — sur `dev-1996`, 290 morceaux laissent 157
trous que la passe n'a pas su combler.

Sur les douze volumes, la passe dure 4 h 47 au total contre 23 h 07 pour
Windows 95, et elle déplace de deux à sept fois moins de données. Elle reste
trois fois plus longue que JkDefrag (1 h 27), qui ne fait pas le même travail :
sur les quatre volumes de 1999, il laisse entre 700 et 2 700 morceaux et plus de
600 trous. Sur les deux volumes pleins à 99 %, l'écart avec Windows 95 se
resserre à 10–20 % : tout passe par une navette de deux clusters, et chaque
tronçon se paie d'une écriture des tables.

#### Recoller peu, sur les gros volumes

Sur les volumes NTFS de 2003 et 2007, la place ne manque plus — 2 à 33 Go
libres — mais la taille : le tassage à la frontière y déplace tout le contenu
du volume, jusqu'à 335 Go et dix heures de passe. Et la fragmentation y est faite
de miettes. Sur `famille-2007`, 268 fichiers cassés pèsent 239 Go en 163 000
morceaux, dont 161 000 font moins de 4 Mo et ne pèsent que 11 Go. Chacun coûte
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
| `dev-2003` | 94 % | 4 min 49 / 6 min 47 / 11 min 38 / **3 min 17** | 3 771 / 11 / 25 / **101** | 3 029 / 1 130 / 620 / **138** |
| `famille-2003` | 93 % | 2 min 34 / 18 min 03 / 28 min 23 / **11 min 58** | 42 617 / 14 949 / 2 128 / **1 073** | 5 711 / 10 905 / 1 062 / **256** |
| `secretaire-2003` | 94 % | 1 min 17 / 6 min 23 / 21 min 25 / **11 min 34** | 23 778 / 14 334 / 5 307 / **3 410** | 2 795 / 7 683 / 2 903 / **879** |
| `gamer-2003` | 8 % | 7 s / 7 s / 6 min 11 / **8 s** | 0 / 0 / 0 / **0** | 6 / 6 / 15 / **3** |
| `dev-2007` | 86 % | 1 h 07 / 1 h 16 / 1 h 55 / **12 min 30** | 0 / 19 / 0 / **844** | 5 323 / 5 346 / 253 / **207** |
| `famille-2007` | 93 % | 23 min 13 / 1 h 27 / 2 h 02 / **23 min 37** | 132 920 / 1 503 / 2 191 / **1 822** | 29 449 / 6 586 / 1 544 / **539** |
| `gamer-2007` | 90 % | 18 min 42 / 38 min 19 / 1 h 15 / **18 min 06** | 38 419 / 561 / 1 439 / **1 560** | 13 470 / 6 950 / 1 696 / **720** |
| `secretaire-2007` | 88 % | 9 min 49 / 9 min 53 / 49 min 40 / **3 min 55** | 0 / 0 / 0 / **54** | 3 347 / 3 370 / 297 / **938** |

Sur les huit volumes, la passe dure 1 h 25, contre 2 h 08 pour XP, 4 h 03 pour
UltraDefrag et 7 h 09 pour JkDefrag, et laisse moins de morceaux (8 864) et
moins de trous (3 680) que chacun d'eux. L'écart de durée avec XP et UltraDefrag
tient surtout aux blocs pleins : donnés à ces outils (`FULL_BLOCKS=1`), ils les
ramènent à 1 h 08 et 1 h 28, sans rien changer à ce qu'ils laissent. Ce que la passe apporte en
propre, c'est la qualité à durée égale. Elle ne recopie jamais un fichier
entier : sur `dev-2007`, où un trou de 22 Go accueille tout, XP et JkDefrag
finissent sans un morceau, et elle en laisse 844.

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
- **Le démarrage d'un disque généré est moins dense que le scénario livré** :
  1 056 requêtes pour tout un démarrage de `dev-1996`, contre 90 à 150
  par seconde dans le scénario réglé à l'oreille. Un vrai démarrage consulte le
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
    ProfileSpec.swift      format déclaratif d'un scénario, calendrier
    ScenarioCompiler.swift  description d'un usage → suite d'événements
    ScenarioLibrary.swift  chargement des scénarios embarqués
    DiskGenerator.swift    point d'entrée : une description, un disque
    Resources/scenarios/   vingt scénarios : cinq époques, quatre profils
Sources/Model/
    Workload.swift         phases du scénario, générateur de requêtes déterministe
    BootSession.swift      démarrage décrit en fichiers : ce que chaque époque
                           va chercher dans le catalogue, dans quel ordre, et ce
                           que la machine calcule entre deux lectures ; plus le
                           témoin « jamais fragmenté »
    VolumeLayout.swift     plan d'une partition FAT16, FAT32 ou NTFS : où sont
                           les métadonnées, et ce que coûte une validation
    Volume.swift           volume vieilli sur place, allocateur next-fit
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
