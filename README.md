# Winchester — spike

[App Store](https://apps.apple.com/app/id6814382619) ·
[Site](https://glandais.github.io/winchester/) ·
[Assistance](https://glandais.github.io/winchester/support/) ·
[Confidentialité](https://glandais.github.io/winchester/privacy/) ·
[Code source](https://github.com/glandais/winchester) ·
[Autres apps du développeur](https://apps.apple.com/developer/id1891310404) ·
[Ko-fi](https://ko-fi.com/gabylandais)

Le nom vient de l'IBM 3340 « 30/30 », baptisé *Winchester* en 1973 — le
premier disque à plateaux scellé avec ses têtes, l'ancêtre direct de ceux
que cette application fait entendre.

Simulation d'I/O **au niveau bloc** d'un disque dur à plateaux, convertie en son
via AVFAudio. Application iOS de démonstration, avec deux démos prêtes à
écouter, qui tournent l'une et l'autre sur un disque de la galerie :

- **Démarrage** — Windows 98 SE puis Office 97 sur `secretaire-1999`, un FAT32
  de 4,2 Go vieilli par deux ans de bureautique : 57,5 s, dont 44 % d'attente du
  disque, et 9 % de plus que le même contenu jamais fragmenté ;
- **Défragmentation** — tassage à la frontière sur `dev-1993`, un FAT16 de
  210 Mo plein à 72 % : 5 min 31, 1 484 fichiers déplacés, et un volume qui sort
  sans un seul fichier déplaçable en morceaux.

Et une galerie de vingt-quatre disques d'époque, générés sur l'appareil, qu'on peut
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
        │  DiskMechanics          tampon et bus, LBA→CHS zoné, seek, latence, transfert
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
l'écoute dans un tampon. Le fil s'endort dès qu'il a huit secondes d'avance —
huit secondes d'écoute : à ×8, soixante-quatre secondes de passe.
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
asservissement rapide — 0,95 ms piste-à-piste, 9,0 ms en seek moyen, et
16,7 ms en pleine course : celle-ci est une sortie du modèle, aucun manuel
Barracuda n'en publie.

Le second est un **Quantum Fireball 1080AT** de 1996 : 1,08 Go,
3 835 pistes, quatre faces, 5 400 tr/min, 166 → 111 secteurs par piste, soit
7,6 Mo/s au bord et 5,1 au moyeu. Bras plus lourd, asservissement plus lent —
3,0 ms piste-à-piste, 12,0 ms en seek moyen, 21,0 ms en pleine course (les
trois durées de son manuel), et un
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

Le modèle interpole donc dans le temps entre huit disques **réellement vendus**,
de 1993 à 2012, dont les fiches sont recopiées dans `DriveCatalog` avec leur
source — plus une neuvième, variante à un plateau de celle de 2001, qui ne sert
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

Trois contrôles tiennent l'ensemble, tous dans les tests : les neuf disques du
catalogue sont retrouvés à partir de leur seule fiche, à 2 % sur la course ; la
**lecture séquentielle** simulée au bord du plateau retombe à 10 % près sur le
débit soutenu des quatre manuels qui le publient — −6,5 % sur le 7200.7, +3,1 %
sur le 7200.10, +5,7 % sur le 7200.11, −9,3 % sur le 7200.14 —, alors que le
débit n'entre dans aucun calcul ; et une fiche n'entre au catalogue qu'après
vérification croisée par ce même débit — c'est ce contrôle qui a fait écarter la
géométrie « native » d'un Quantum Fireball ST 6.4AT, qui donnerait 6,5 Mo/s là
où son fabricant en annonce 16.

**Le disque de 2012** est le **Barracuda 7200.14 ST1000DM003** : un plateau de
1 To, deux têtes, 352 000 pistes par pouce, 64 Mo de tampon en SATA 6 Gb/s, et
des têtes garées sur une rampe — son manuel compte des « Load/Unload cycles » là
où celui du 7200.10 comptait des « Contact start-stop cycles ». C'est le seul
manuel du catalogue à publier un **débit moyen** à côté du débit au bord : 156 et
210 Mo/s. Sur une bande où les secteurs par piste décroissent linéairement, la
moyenne vaut bord × (1 + rapport) / 2, d'où un rapport interne de 0,486, le seul
point de `innerRatioByYear` qui vienne d'une fiche. Le modèle en tire 208,7 →
101,4 Mo/s bruts, 1 % sous les 210 publiés : deux chiffres arrondis.

**Un 10 000 tr/min n'est pas un 7 200 qui tourne plus vite.** Le **WD
VelociRaptor** (`DriveCatalog.named`, chantiers 33 et 34) met des plateaux de 2,5 pouces
dans un radiateur de 3,5, pour que l'air au bord n'aille pas plus vite que sur un
7 200 tr/min. Ses deux fiches, le WD1000DHTZ (1 To, trois plateaux, six têtes) et
le WD5000HHTZ (500 Go, deux plateaux, trois têtes), décrivent le disque entier ;
un profil les nomme par `"model"` dans sa section `disk`. Un disque **déduit** à
10 000 tr/min à partir de 2008 prend la même mécanique (`DriveCatalog.mechanics`) :
des faces qui portent, par rapport à celles du disque de bureau de son année, ce
que le WD1000DHTZ portait par rapport au 7200.14 — 44 % des pistes et un tiers
des octets —, ses plateaux de 2,5 pouces, son piste-à-piste et sa rampe. En 2012
il retrouve exactement la fiche ; en 2009, la même mécanique à la densité de 2009.
Avant 2008, un 10 000 tr/min est un Raptor et reste sur la courbe des 3,5 pouces,
faute d'une fiche qui dise la taille de ses plateaux.

| | fiche et mesures | le modèle, de la fiche | un 10 000 tr/min prolongé de la courbe des 3,5 pouces |
|---|---|---|---|
| têtes | 6 (3 plateaux de 334 Go) | 6 | 2 |
| pistes par face | — | 171 600 | 387 200 |
| débit bord → moyeu | 209,1 → 114,7 Mo/s (Tom's Hardware) | 208,9 → 114,9 Mo/s | 290 → 141 Mo/s |
| seek moyen / piste-à-piste | ≈ 3,8 ms / 0,7 ms | 3,80 / 0,70 ms, pleine course 7,05 ms (le modèle : WD n'en publie pas) | celui qu'on lui donne / 1,0 ms |
| tampon | 64 Mo, SATA 6 Gb/s | 64 Mo | 64 Mo (celui du 7200.14) |
| repos | 30 dBA = 3,0 B | 2,67 B | 3,5 B sur trois plateaux, au régime seul |
| parcage | rampe NoTouch | rampe : ni décollage ni atterrissage | rampe (celle du 7200.14) |

Le manuel WD ne publie ni seek ni densité. Le seek moyen vient de l'accès en
lecture mesuré par Tom's Hardware, 6,78 ms, moins 3,0 ms de latence. Le
piste-à-piste vient de la fiche de 2008 du WD3000HLFS, la seule VelociRaptor qui
le donne. Les pistes par face viennent du débit mesuré au bord et de la capacité.
Le WD5000HHTZ prend la mécanique du WD1000DHTZ, que la fiche de 2012 décrit dans
la même table.

Un disque nommé garde son année, qui décide de sa voix ; celle du scénario décide
du reste, y compris l'outil de défragmentation qu'on prend sans en nommer
(chantier 47 : il suivait l'année du disque). Posé dans une machine plus ancienne (`DRIVE=VelociRaptor`), il se
branche sur le contrôleur SATA de celle-ci.

Ce que remplace ce modèle faisait tout porter à la densité linéaire, avec un seul
exposant calé sur les deux disques ci-dessus : il donnait 640 cylindres à un
disque de 1993 qui en avait 2 111, et 235 000 à un 320 Go de 2007 qui en a
160 000. Dans les deux cas la course était fausse d'un facteur trois, et le débit
avec.


**Seek** — loi à deux régimes de Ruemmler & Wilkes (IEEE Computer 27(3), 1994) :
`a + b·√d` pour les seeks courts, `c + e·d` au-delà du cylindre de croisement.
La forme fonctionnelle vient de l'article, **les constantes sont recalibrées**
pour chaque disque sur les trois durées de sa fiche — piste-à-piste, seek moyen
pris comme l'espérance d'un seek aléatoire (et non comme le seek d'un tiers de
course), pleine course quand elle est publiée : le Barracuda ATA IV de 2001, à
0,95 et 9,0 ms, en reçoit 16,7 en pleine course. Les coefficients publiés
valent pour des disques HP des années 90.
Chaque seek est découpé en *speedup / coast / slowdown / settle* ; un seek court
n'a pas de phase de coast, ce qui fait varier la **forme** de l'enveloppe avec la
distance et pas seulement son amplitude.

**Un seek qui précède une écriture dure plus** : la tête doit être mieux posée
avant d'écrire, sous peine d'écraser la piste voisine, et l'asservissement
attend plus longtemps. Les manuels le publient par une colonne « Write » —
14,0 ms contre 12,0 sur le Fireball, 9,5 contre 8,5 sur les Barracuda de 2003
et 2008, 1,2 contre 1,0 en piste-à-piste. Le modèle cale une seconde loi sur
ces deux durées, et son excédent sur la loi de lecture allonge le settle ; le
bras, lui, ne va pas plus vite. Un disque de la galerie reçoit le rapport de la
fiche la plus proche de son année qui le publie ; le Conner de 1993 n'en a pas,
et prend celui du Fireball — une hypothèse.

**Latence rotationnelle et transfert** — simulés secteur par secteur, avec pas de
piste et commutation de tête en fin de cylindre. Une requête qui déborde du
dernier cylindre est tronquée, comme le ferait le disque. La commutation de
tête vaut six dixièmes du pas de piste : **un ordre de grandeur**. Le seul
manuel du catalogue qui publie les deux temps, celui du Fireball, les donne
égaux — 3,0 ms chacun — ; les égaler allongerait les démarrages de 0,8 s au plus.

**Le tampon du disque** (`DriveBuffer`, `DriveInterface`). Chaque
fiche du catalogue porte son tampon et la politique que son constructeur y
appliquait à la mise sous tension, relevés dans les manuels ; un disque de la
galerie prend celui de la fiche de son année, et le bus de la machine de son
année :

| disque | tampon | lecture anticipée | cache d'écriture | interface | bus de la machine |
|---|---:|---|---|---|---|
| Conner CFA170A, 1993 | 64 Ko | oui | non | 7,0 Mo/s | ISA, PIO : 5,0 Mo/s |
| Fireball 1080AT, 1996 | 128 Ko, dont 76 de cache | oui | oui | PIO 4 : 16,7 Mo/s | PIO 4 : 16,6 Mo/s |
| Seagate U8, 1999 | 512 Ko | oui | oui | UDMA 4 : 66,6 Mo/s | UDMA/33 : 32,6 / 21,9 Mo/s |
| Barracuda ATA IV, 2001 | 2 Mo | oui | oui | UDMA 5 : 100 Mo/s | — |
| Barracuda 7200.7, 2003 | 2 Mo | oui | oui | UDMA 5 : 100 Mo/s | UDMA/100 |
| Barracuda 7200.10, 2006 | 16 Mo | oui | oui | UDMA 5 : 100 Mo/s | UDMA/100 |
| Barracuda 7200.11, 2008 | 32 Mo | oui | oui | SATA : 300 Mo/s | — |
| Barracuda 7200.14, 2012 | 64 Mo | oui ¹ | oui ¹ | SATA : 600 Mo/s | SATA 6 Gb/s : 600 Mo/s |
| VelociRaptor WD1000DHTZ et WD5000HHTZ, 2012 ² | 64 Mo | oui | oui | SATA : 600 Mo/s | SATA de l'époque du scénario : 150 Mo/s avant 2006, 300 avant 2011, 600 ensuite |

¹ Le manuel du 7200.14 ne dit rien de l'état du cache à la mise sous tension : c'est
celui des manuels Seagate précédents.
² Disques nommés : ils ne servent que les profils qui les nomment. Un disque SATA
impose un contrôleur SATA, quelle que soit la machine. Aucun bus de 2012 n'est
mesuré : ce sont les débits de la norme.

- **la lecture anticipée** : après une lecture, la tête continue de lire, une
  piste d'avance — ce que tient le cache du Fireball. Une requête qui tombe
  dedans est servie au rythme du bus, sans seek, sans latence ni pas de piste ;
  une requête ailleurs l'arrête au secteur près, et ce qu'elle a lu reste. Le
  disque lit donc **aussi quand l'hôte calcule** : ses pas de piste ne suivent
  plus seulement les requêtes ;
- **le tampon est segmenté** comme le décrit le manuel du Fireball — autant
  d'entrées que la taille en loge, la plus ancienne cède la place. C'est une
  file : une entrée relue n'est pas rajeunie, là où le Conner annonce une
  gestion « au plus anciennement utilisé ». Aucun nombre de segments n'est
  posé : il tombe de la taille du tampon devant celle d'une piste, une entrée
  sur le Fireball, une trentaine sur le 7200.10 ;
- **la lecture sans latence** : une requête qui tient sur une piste commence au
  secteur qui se présente, et un tour suffit. **Aucun manuel ne la décrit** :
  le « Read-on-arrival » du Fireball, qui en a longtemps tenu lieu de source,
  qualifie un temps de seek — la lecture commence dès que la tête arrive,
  avant la fin de l'asservissement. Le mécanisme est plausible pour un tampon
  segmenté, et toutes les fiches sauf le Conner le reçoivent par hypothèse ;
- **le cache d'écriture** acquitte une écriture dès qu'il la tient, et la pose
  plus tard, dans l'ordre de l'ascenseur, en fusionnant ce qui se touche : dès
  que l'hôte n'a rien à demander, ou quand il faut de la place. Les écritures
  qui arrivent plus vite que le disque ne les pose partent **en salves** —
  93,3 écritures par vidage en moyenne pour l'outil de XP sur `dev-2007` ;
  celles qu'un installeur espace de calcul sont posées une à une, pendant
  qu'il calcule ;
- **le bus borne ce que le tampon sert**, et **chaque commande coûte** 0,2 ms —
  la mise en place DMA mesurée par Microsoft Research sur un Pentium II en
  1999 —, 0,5 ms sur le Conner, dont le constructeur donne ce chiffre. Mesurée
  sur un Pentium II, elle est prêtée aux dix ans de la galerie : c'est une
  mesure d'un point. Sans lecture anticipée, ce coût ferait manquer le secteur
  suivant à chaque requête contiguë : les vingt démarrages dureraient 1,7 à 11,4 s
  de plus. C'est le mécanisme qui masquait, sur un vrai disque, le tour de
  plateau qu'une mécanique sans coût de commande ne perd pas.

**La mise sous tension est en trois temps** (`IdleBehavior.coldStart`, pour un
démarrage et une journée). Le moteur démarre ; dans les 50 ms, les têtes
collées au plateau s'en **décollent** — la *stiction*, un claquement sec ; puis,
une fois le coussin d'air établi, le disque **cherche sa piste 0 et charge son
asservissement** : une course complète depuis la zone de parcage du moyeu, et
quatre pas courts au bord, calés pour finir quand le disque est prêt. Le « clac »
franc d'ouverture est donc celui-là, et non la première lecture — d'autant que
le secteur d'amorçage est au cylindre 0, où la salve laisse le bras : un
démarrage n'a pas de premier seek vers le cylindre 0. Une défragmentation ou une
installation, elles, partent d'un plateau qui tourne déjà : leur rampe n'est
qu'un fondu, et le bras attend au moyeu — une convention, puisque aucun disque de
bureau n'y parquait : là où le dernier accès l'a laissé, le modèle ne le sait
pas. Un disque à rampe, lui, se parque **au bord** : sur un 3,5 pouces à
*load/unload* la rampe est au diamètre extérieur, et le 7200.14 comme le
VelociRaptor ne commencent ni ne finissent par une pleine course.

**Au repos, un disque de bureau laisse son bras où il est.** Aucun disque à
plateaux de cette période ne parquait ses têtes une seconde après la dernière
requête — c'est une pratique des disques à rampe des portables des années
2000. Le mécanisme existe (`IdleBehavior.parkAfter`), aucun scénario ne s'en sert : une
défragmentation, un démarrage, une installation se referment sur le disque qui
tourne. Le dernier mouvement appartient à ce qui le produisait vraiment, **la
coupure** : une journée s'achève une seconde après sa dernière écriture, le bras
se retire au moyeu, le moteur est coupé, le plateau **redescend par la même loi
du premier ordre** qu'il est monté, et quand il est tombé à 40 % de son régime
les têtes **se posent** sur la zone d'atterrissage — le petit *crac* granuleux
qui termine un arrêt. La seconde avant la coupure et les 3,5 s de la
redescente sont des choix de rendu : le manuel du Fireball donne dix secondes
d'arrêt complet.

**Les disques d'avant 1997 se recalibrent** (`ThermalRecalibration`). Deux
minutes après être prêt, puis toutes les quatre minutes, un disque de 1993 ou
de 1996 finit sa commande en cours et va relire ses repères de position au
bord, au moyeu et au milieu : une seconde de crépitement, l'événement sonore
signature de cette génération — au point que les constructeurs ont dû sortir des
modèles « AV » sans recalibration pour le montage vidéo. Aucun démarrage n'en
contient (le plus long dure 66 s) ; une passe de vingt minutes en compte cinq,
et dure d'autant plus : +0,1 à +0,7 % sur les passes de 1993 et 1996, rien
ailleurs. Le délai compté est dans `TraceStats.recalibrationSeconds`, à part des
seeks demandés.

**Timbre de la tête** — banc de résonateurs à **fréquences fixes** (modes ~4,5 kHz
sway et ~5,5 kHz, plus cinq autres), excité par un profil de courant dérivé des
quatre phases. Les résonances structurelles de l'actionneur ne se transposent pas
avec la vitesse de seek : seule l'excitation change. L'amplitude et le dosage des
modes varient avec la distance parcourue — courbe réglée à l'oreille, aucune
source ne donne de loi exploitable.

**Niveau de la tête** — `SeekCharacter`. Le timbre est commun aux vingt-quatre
disques ; le niveau, lui, vient des manuels, qui publient la puissance
acoustique **en seek**. Le repos retranché (les puissances s'ajoutent), il
reste ce que fait le bras seul, et il va du simple au triple :

| disque | repos | seek | bras seul | à l'écoute |
|---|---|---|---|---|
| Seagate U8, 1999 | 3,2 B | 3,5 B | 3,20 B | 0 dB (référence) |
| Barracuda ATA IV, 2001 | 2,1 B | 3,0 B (*performance*) | 2,94 B | −1,3 dB |
| Barracuda 7200.7, 2003 | 2,2 B | 3,1 B (*performance*) | 3,04 B | −0,8 dB |
| Barracuda 7200.10 SATA, 2006 | 2,8 B | 3,7 B (*performance*) | 3,64 B | +2,2 dB |
| Barracuda 7200.10 PATA, 2006 | 2,7 B | 3,0 B (*quiet*) | 2,70 B | −2,5 dB |
| Barracuda 7200.11, 2008 | 2,9 B | 3,2 B (*performance*) | 2,90 B | −1,5 dB |
| Barracuda 7200.14, 2012 | 2,2 B | 2,4 B | 1,97 B | −6,2 dB |
| VelociRaptor, 2012 | 30 dBA | 37 dBA (*performance*) | 3,60 B | +2,0 dB |

Douze décibels aux manuels entre le U8 et le 7200.14 ; **six à l'écoute** — le
même parti qu'au plateau, à moitié en décibels, sans quoi un disque de 2012
disparaît sous sa broche. Le Conner et le Fireball ne publient rien en seek :
les disques de 1993 et 1996 empruntent au U8, et sonnent comme avant. Ce qui
reste commun est **dit** : aucune fiche ne publie un spectre, et l'attaque en
bang-bang est la même de 1993 à 2012 quand un ATA IV perd 6 dB en *quiet seek*
— la gestion acoustique n'est pas modélisée.

**Trains de seeks** — deux seeks rapprochés ne relancent jamais deux one-shots.
Ils sont fusionnés en un rendu continu passé **une seule fois** dans le banc de
résonateurs, avec le transitoire terminal replacé en fin de train. Règle héritée
de l'émulation de lecteur de disquette de MAME, où relancer l'échantillon de pas
donnait un résultat « much too loud, and it sounds weird ».

**Trains de micro-transitoires** — la même règle vaut pour les commutations de
tête et les pas de piste : à moins de 30 ms l'un de l'autre, ils partent en un
train rendu d'un seul passage, l'excitation de chacun coupée au suivant. Aucun
n'est supprimé. Une lecture séquentielle sur le Barracuda à une tête franchit
une piste à chaque tour : sa cadence est de **108 Hz** (un tour de 8,33 ms et le
pas), une hauteur plutôt qu'une suite de tics. Sur le Fireball à quatre têtes,
**deux périodicités emboîtées** : la commutation à 75,7 Hz, le pas de piste tous
les quatre tours à 18,9 Hz. Un filtre de 18 ms en supprimerait un sur deux, et
l'enveloppe tomberait à 53,6 et 37,9 Hz — un cliquetis, pas le sifflement d'une
grosse lecture.

**Décollement et atterrissage** — deux one-shots, du même banc de résonateurs :
le décollement est un claquement unique, plus grave qu'un seek (tout
l'équipage bouge, sans profil de courant pour l'adoucir), suivi d'un bref
frottement ; l'atterrissage, quatre contacts de plus en plus faibles et
rapprochés — un rebond qui s'amortit — puis un frottement qui s'éteint. Un
disque à rampe — le 7200.14, le VelociRaptor, tout disque de 2012 — n'a ni l'un
ni l'autre : ses têtes ne touchent jamais le plateau. Le clic du chargement sur la rampe n'a pas de voix, faute de
source.

**Plateau** — `SpindleCharacter` et `SpindleVoice`. Du bruit filtré, et trois
grandeurs pour le former, prises aux manuels :

| disque | tr/min | plateaux | palier | repos (manuel) | modèle |
|---|---|---|---|---|---|
| Conner CFA170A, 1993 | 4 011 | 1 | billes | 42 dBA ≈ 4,6 B | 4,6 B |
| Quantum Fireball, 1996 | 5 400 | 2 | billes | 3,6 B | 3,6 B |
| Seagate U8, 1999 | 5 400 | 1 | billes | 3,2 B | 3,2 B |
| Barracuda ATA IV, 2001 | 7 200 | 1 | fluide | 2,1 B | 2,15 B |
| Barracuda 7200.7, 2003 | 7 200 | 1 | fluide | < 2,2 B | 2,15 B |
| Barracuda 7200.10, 2006 | 7 200 | 2 | fluide | 2,8 B | 2,55 B |
| Barracuda 7200.11, 2008 | 7 200 | 4 | fluide | 2,9 B | 2,95 B |
| Barracuda 7200.14, 2012 | 7 200 | 1 | fluide | 2,2 B | 2,15 B |
| VelociRaptor WD1000DHTZ, 2012 | 10 000, plateaux de 2,5" | 3 | fluide | 30 dBA = 3,0 B | 2,67 B |
| VelociRaptor WD5000HHTZ, 2012 | 10 000, plateaux de 2,5" | 2 | fluide | — | 2,43 B |

- le **souffle** d'air autour des plateaux est un bruit de sillage : ses trois
  bandes (185, 520, 1 450 Hz à 7 200 tr/min) glissent avec le régime, l'aigu y
  pèse d'autant plus que le disque tourne vite, et sa puissance croît en
  puissance cinq de la vitesse **au bord du plateau**, pas du régime : le
  VelociRaptor, à 10 000 tr/min sur un rayon de 1,25 pouce contre 1,83, brasse
  l'air à 0,95 fois la vitesse d'un 7 200 tr/min de 3,5 pouces. Au régime seul,
  il aurait fait 3,5 B, plus que le 7200.11 ; la fiche dit 3,0 ; +0,4 B par doublement du nombre de plateaux —
  l'écart que le manuel de l'ATA IV mesure entre un et deux plateaux ;
- le **roulement à billes**, jusqu'en 2000, fait l'essentiel du bruit d'un
  disque : un sifflement large vers 2,9 kHz et un roulage grave qui suit le
  régime, modulés à 35 % **à chaque tour** — le battement d'un vieux disque au
  repos. Seagate passe au palier fluide avec l'ATA IV, en 2001 ;
- une raie de **commutation du moteur** à 24 fois la fréquence de rotation (un
  triphasé à huit pôles : estimation, aucune fiche ne donne les pôles), un
  vingtième du bruit.

Régime, plateaux et palier viennent des manuels ; ce qui les met en son — les
fréquences des bandes, le battement de 35 %, le vingtième de la raie — est
estimé : aucun manuel ne publie de spectre.

Le niveau suit les manuels **à moitié en décibels** autour du U8, **au quart**
au-delà de 3,0 B : 25 dB entre le Conner et un 7 200 tr/min à un plateau, c'est
un 1993 qui couvre ses seeks ou un 2003 qu'on n'entend plus sur un haut-parleur
de téléphone. Le coude vient de l'écoute sur le téléphone, qui a trouvé les
vieux disques trop forts à moitié partout et les récents justes. C'est une
licence de mixage ; l'autre est le niveau de la rotation dans le préréglage
« Casque », ramené de 32 à 20 % à l'écoute. Mesuré sur la voix seule, à plein régime :

| | RMS | centroïde | > 1,5 kHz | battement au tour |
|---|---|---|---|---|
| avant, tous les disques | −32,3 dB | 611–656 Hz | 14 % | 1 % |
| Conner 1993 | −29,3 dB | 1 119 Hz | 25 % | 34 % |
| Fireball 1996 | −31,7 dB | 1 226 Hz | 26 % | 34 % |
| U8 1999 | −32,7 dB | 1 226 Hz | 26 % | 34 % |
| ATA IV ×2, 7200.7 | −37,5 dB | 660 Hz | 14 % | 1 % |
| 7200.10 | −35,5 dB | 660 Hz | 14 % | 1 % |
| 7200.11 | −33,5 dB | 660 Hz | 14 % | 1 % |

Sans ces trois grandeurs, les huit fiches auraient **exactement** le même
spectre à plein régime (0,0 dB d'écart par tiers d'octave) et ne différeraient
que par une raie discrète à tr/min/60. Trois familles se distinguent par le
timbre — le roulement de 1993, plus fort et plus grave dans son roulage ; celui
de 1996-1999, qui bat à 90 Hz ; le souffle lisse du palier fluide — mais **pas
les huit fiches**. À l'intérieur d'une famille, seul le niveau sépare les
plateaux, de 1 à 2 dB : Fireball et U8, 7200.10 et 7200.11 ne se distinguent qu'en
comparaison directe. Et trois fiches restent identiques, parce qu'elles le
sont : les deux ATA IV et le 7200.7 ont un plateau, un palier fluide,
7 200 tr/min, et 2,1 à 2,2 B au repos selon Seagate.

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
moyeu tant que rien n'a été lu — au bord, sur un disque qu'on vient d'allumer et
qui a cherché sa piste 0 —, descend piste après piste pendant une lecture
séquentielle, se retire au moyeu à la coupure, et s'élance vers
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
mécanisme exotique n'intervient. Résultat : 4 016 fichiers et 11 répertoires,
8 % fragmentés en 1 046 morceaux, 38 trous dans l'espace libre, à 72 % de
remplissage.

**La passe** — « défragmentation complète (fichiers et espace libre) » : chaque
fichier est rendu contigu et tassé contre le début du volume, dans l'ordre du
parcours de l'arborescence, seul ordre dont l'outil disposait. Trois
conséquences, et ce sont elles qu'on entend :

- la destination d'un fichier est presque toujours occupée par un autre, qu'il
  faut d'abord **évacuer** vers la fin du volume — et qui sera relu puis
  redéplacé quand viendra son tour. Sur ce volume-là, l'outil de 95 déplace
  3 997 éléments et évacue 3 090 fois : c'est ce va-et-vient, pas le volume de
  données, qui fait durer une passe — 24 min 42, quand le tassage à la
  frontière, qui ne déloge presque personne, finit en 5 min 31 ;
- chaque déplacement validé réécrit les deux copies de la FAT, au tout début de
  la partition, puis l'entrée du fichier **là où vit son répertoire** — dans la
  racine pour un fichier de la racine, ailleurs pour tous les autres. Le bras
  revient donc au bord du plateau environ une fois par fichier. Sur NTFS, pas
  de bord : un enregistrement de MFT, un secteur de `$Bitmap` et, une
  validation sur huit, une page de journal. Sous XP, `$Bitmap` est au milieu du
  volume et le journal juste devant la MFT : le bras paie une demi-course vers
  la bitmap à chaque validation, et le journal n'est qu'un seek court ;
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

Les **répertoires** ont leur couleur, le jaune des dossiers de l'Explorateur :
sur FAT ce sont des fichiers comme les autres, que la passe déplace aussi ; sur
NTFS, l'index des noms d'un répertoire qui a débordé de son enregistrement de
MFT.

Rien de tout cela n'est tenu cluster par cluster : la carte est une suite de
plages, et un volume de 320 Go coûte 2,6 Mo au lieu de 78.

Une image ne recalcule que les blocs qu'une mutation a touchés depuis la
précédente, et rend le même tableau quand aucune n'est tombée : la vue ne refait
alors pas son image. L'écran recouvert par le plein écran cesse de suivre
l'horloge, et se remet à l'heure quand on en sort ; un onglet caché aussi.

Sur NTFS, `$Boot`, la MFT, `$MFTMirr`, `$LogFile` et `$Bitmap` — et, sous XP,
la bitmap de la MFT, `$AttrDef` et `$UpCase` — n'appartiennent à aucun
fichier du catalogue, mais occupent le volume : la carte les peint de la couleur des tables
FAT, celle de ce que le système de fichiers se réserve pour lui-même. Une zone
MFT qui cède ne laisse donc pas croire que la MFT est un trou.

## Les disques d'époque

L'onglet **Disques** de l'application : les deux démos, prêtes à écouter et
posées sur deux disques de la galerie qu'elles nomment, puis une galerie de
volumes vieillis, six époques et quatre profils
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

Le matériel va de 1990 à 2012, de 20 Mo à 2 To, de 3 600 à 10 000 tr/min, et le
seek descend à 3 ms. Choisir 10 000 tr/min pose le seek du VelociRaptor, et à
partir de 2008 ses plateaux de 2,5 pouces ; on peut aussi **partir d'une fiche**
— les deux VelociRaptor —, que le premier réglage touché quitte : le disque
redevient alors déduit, et à 10 000 tr/min en 2012 il retombe sur la même
mécanique.

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

**Une exception, dite et mesurée, hors XP.** Sous NT 4, Vista et 7, l'allocateur
NTFS borne sa recherche de trous par quatre constantes introduites pour le coût
de calcul — la tolérance d'un trou trop grand, la fenêtre de trous examinés,
l'horizon parcouru dans la bitmap, les fenêtres du dernier recours. **Aucune ne
vient d'une source**, et elles règlent la fragmentation : sur `famille-2007`,
l'horizon seul la fait aller de 22,3 à 35,0 % des fichiers fragmentables.
L'allocateur de XP n'en a aucune : il suit le code du pilote, et son *best fit*
est celui de son cache de runs libres. L'en-tête de `NTFSAllocator` porte la
table, et `CalibrationTests` la régénère.

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
| trous dans l'espace libre | 3 | 502 | 78 |
| slack | 13,8 % | 1,5 % | 1,4 % |

**Écrire sans connaître la taille.** Un programme qui copie un fichier, ou
l'installe depuis un CD, en connaît la taille et obtient sa place d'un coup. Un
compilateur qui produit son `.obj`, un navigateur qui reçoit une page, Word qui
sérialise son document, un logiciel de téléchargement ou de compression ne la
connaissent pas : leur fichier grandit **à l'écriture**. Sur FAT, le pilote
prolonge la chaîne d'un cluster à chaque écriture qui en franchit la fin. Sous
XP, cela dépend du programme (`StreamedGrowth`). Deux tiennent leur fichier
**projeté en mémoire** et l'étendent par `SetEndOfFile`, que NTFS alloue
exactement, sans surplus : `wininet` fait grandir `index.dat` de 16 Ko en
16 Ko (le code de XP le dit), et Word écrit son document par ole32 — déduit, pas
attesté —, qui le crée à 512 octets puis l'engage par blocs de 16 Ko, un
minimum : rien ne dit la taille des écritures de Word. Les autres —
compilateur, navigateur qui écrit son cache, encodeur, jeu, `.pst` d'Outlook —
sont supposés écrire par 4 Ko, le tampon de la bibliothèque C : c'est alors
`NtfsCommonWrite` qui étend le fichier — pas le gestionnaire de cache, que le
code exclut —, à chaque écriture qui dépasse l'allocation, exactement d'abord,
puis deux, quatre, huit et seize fois l'écriture, alignées, prises tant que le
cache des runs libres répond, et **le surplus est rendu à la fermeture**. Vista
et 7 gardent des paquets de 64 Ko, une taille estimée, pour tous. La question
est posée programme par programme (`FileSpec.sizeKnownInAdvance`), jamais par
taux. Sur FAT elle ne change rien tant qu'un programme écrit seul — cluster par
cluster au curseur, il prend ce qu'il aurait pris d'un coup —, et c'est sur
NTFS qu'elle se voit : la première place d'un fichier — un cluster pour les
512 octets d'ole32 — va dans le plus petit trou qui lui suffit, et la traîne
des fichiers en 2 à 16 morceaux atteint
62,5 % des fichiers fragmentables sur `secretaire-2003`. Plusieurs programmes
qui écrivent **en même temps** se disputeraient le curseur et
s'entrelaceraient ; le simulateur sait le faire, mais ne le fait pas : il
faudrait savoir à quel débit et à quelle heure chacun écrit, ce que la
chronologie ignore.

**Les répertoires existent.** Sur FAT un répertoire est un fichier qui porte
les entrées de 32 octets de ses enfants — plus une par tranche de treize
caractères d'un nom long sous VFAT — et grandit d'un cluster quand elles
débordent, au curseur, donc loin de ses premiers clusters ; il ne raccourcit
jamais. Sur NTFS, son index tient dans son enregistrement de MFT tant qu'il est
petit, puis prend des tampons de 4 Ko. Un répertoire naît au premier fichier
qu'on y écrit. Démarrer un disque, c'est lire le chemin de chaque fichier
ouvert, répertoire par répertoire depuis la racine, là où ils sont.

**Les trois stratégies.** MS-DOS sert le premier cluster libre à partir du
début du volume, à chaque écriture : les trous se rebouchent aussitôt, le début
du disque devient un gruyère dense et les fichiers récents sont hachés. VFAT
puis FAT32 reprennent au dernier cluster alloué : l'écriture est propre tant
que le curseur avance, puis il revient au début et repasse par-dessus des trous
laissés des mois plus tôt — la fragmentation arrive par vagues. NTFS choisit le
trou qui convient plutôt que le premier venu. **Sous XP, le code du pilote fait
foi** (`bitmpsup.c`, XP SP1) : un fichier prend le plus petit run au moins aussi
long que lui dans un **cache des runs libres** de 9 000 entrées au plus —
rebâti à chaque montage des 64 plus longs runs de chaque page de la bitmap —,
le plus à gauche à longueur égale, sans curseur et sans préférence pour
l'espace jamais servi ; faute de run assez long, il se découpe du plus grand
morceau au plus petit. Les clusters libérés sont masqués jusqu'au point de
contrôle suivant — un entre deux événements de l'histoire, dans le modèle —,
puis offerts comme les autres. Un fichier qu'on agrandit prend le run qui le
suit s'il est en cache, sinon le trou le plus juste, où qu'il soit.
`FORMAT` pose sa MFT selon le
système : en tête sous NT, loin du début depuis XP, et lui réserve derrière
elle une zone — 12,5 % du volume jusqu'à XP, 200 Mo depuis Vista, renouvelés
par tranches quand elle les a remplis (KB 961095). Sous XP, **le code de
`FORMAT` fait foi** (`untfs`, XP SP1) : `$MFT` à 3 Gio du début — à 1 Gio
de 2 à 6 Gio de volume, au tiers en dessous —, seize enregistrements, sa
bitmap juste devant elle, et **`$LogFile` collé devant**, à deux clusters
près ; au milieu du volume, `$MFTMirr`, puis `$AttrDef`, **`$Bitmap`**,
`$UpCase` et le premier tampon de l'index racine, posés à la suite. Vista
et 7 gardent la disposition d'avant, que leur code absent ne permet pas de
vérifier : le journal derrière le miroir, comme `mkntfs`, la bitmap
derrière la zone. Les données se posent d'abord devant la MFT, dans les
trois premiers gigaoctets — le pilote de XP ne réserve que la zone —, puis
derrière la zone. À celle-ci il ne touche que quand le reste du volume est
plein, et alors il n'en rend que la moitié libre, puis la moitié de ce qui
reste la fois suivante. Sous XP, la zone est **recalculée à chaque montage**
sur le run libre qui suit la MFT — ou, s'il est pris, sur le plus petit run qui
atteint un huitième du volume —, regonflée dès que l'espace libre repasse
au-dessus d'un seizième, et reposée ailleurs quand la MFT ne peut plus grandir
sur place ; la MFT, qui grandit par seize enregistrements, y continue d'un
seul tenant, et ses enregistrements libérés sont repris par le bas.
`NTFSAllocator` dit ce qui vient d'une source et ce que le modèle pose. Sous
Vista et 7, un fichier qu'on agrandit est d'abord prolongé en place, et son
complément est cherché **près de lui** — c'est ce que fait le pilote NTFS de
Linux —, pas là où l'allocateur a écrit en dernier : c'est ce qui donne aux
fichiers la traîne de deux à seize morceaux qu'un NTFS plein de trois ans porte
(de 0,5 à 6,7 % des fichiers fragmentables sur `dev-2007`). Le simulateur lit et écrit `$Bitmap`
et le journal là où le générateur les a posés. Monter un NTFS de XP, c'est
lire le secteur d'amorçage — pas sa copie au dernier secteur, que le pilote
ne consulte qu'en cas d'erreur —, les premiers enregistrements de la MFT et
leur miroir, la zone de redémarrage du journal, puis `$UpCase` et `$Bitmap`
entières. L'analyse d'un défragmenteur ne lit que la bitmap de la MFT, celle
du volume, et la MFT : ni le journal, ni le miroir.

**2012, la sixième époque.** Windows 7 SP1 en 64 bits — les applications 32 bits
dans `\Program Files (x86)`, le magasin de pilotes, 128 traces de préchargement
au plus, `pagefile.sys` et `hiberfil.sys` taillés sur 4 Go de mémoire —, Office
2010 et sa source gardée dans `\MSOCache`, Visual Studio 2010, Battlefield 3 et
ses `cas` d'un gigaoctet, Skyrim et ses `bsa`, iTunes 10 ; une carte SD à
25 Mo/s et l'ADSL2+ à 2 Mo/s. Le joueur et le développeur ont un **VelociRaptor
WD5000HHTZ** de 500 Go à 10 000 tr/min, la famille un 7200.14 de 1 To, la
secrétaire un 500 Go de la même année. Un jeu installé pèse cinq à quinze
gigaoctets au lieu d'un, et ce qu'on entasse est un film de 700 Mo.

**Ce qui se mesure.** Le slack de 1996 est là où on l'attend : sur une
population de documents Word, des clusters de 32 Ko perdent 31 % du volume
contre 2 % en FAT32 — un tiers de disque en plus pour le même contenu.
L'installation d'un `gamer-2003` n'a pas un seul fichier en deux morceaux ; ses
sauvegardes de jeu, écrites par 4 Ko dans les trous des précédentes, si. Un
poste DOS de 1993 après deux ans en a 71 %.

**Deux cibles ne sont pas atteintes**, et les tests le disent plutôt que de
l'arrondir : `dev-1996` donne 8 % de fichiers fragmentés au lieu des 35 à 50 %
visés, et `secretaire-1999` 5 % au lieu de 15 à 25 %. Celle de `famille-2003`,
40 à 60 %, est **retirée** : elle venait du cahier des charges, et l'allocateur
de XP, suivi à la lettre, en produit 16 % — le rapport de deux avec le FAT32 de
1999 tombe avec elle (`CalibrationTests`). Son remplissage final, 88,7 %, reste
sous les 90 % visés : c'est la fin du cycle de rangement du profil, pas
l'allocateur. Le premier écart vient de la population : trois mille des cinq
mille fichiers du volume viennent d'une installation écrite d'affilée sur un
disque vierge, si bien que le taux global plafonne — alors que les fichiers de
sortie sont bel et bien en 275 morceaux. Le deuxième était atteint jusqu'à
ce que le hint système cesse de renvoyer les DLL au cluster 0 sur FAT32 : ce
mécanisme-là n'a jamais existé, et il fabriquait de la fragmentation.
L'écriture par paquets ne les a pas refermées : elle ne change rien sur FAT, et
peu sur NTFS. L'entrelacement de plusieurs programmes, essayé, portait
`secretaire-1999` à 32 % — au-dessus de sa fourchette — et mettait `dev-1999` en
437 802 morceaux ; il supposait tous les programmes d'une journée actifs
ensemble et au même débit, et n'est pas retenu.

**Coût.** Le plus lourd des volumes de 2007 — un Vista de 250 Go, trois ans
d'historique, 2,7 millions d'événements — se génère en 1,7 s en release, dont
0,4 s pour les noms uniques ; les plus lourds de 2012, un Windows 7 de 500 Go et
un de 1 To, en 2,6 et 2,2 s. Les deux disques des démos, fabriqués au lancement, prennent 50
et 32 ms. L'écriture sans taille connue coûte surtout sur les gros fichiers de
XP, étendus par 64 Ko en régime établi : `famille-2003` en prend 1,6 s, parce
que les extensions que le run suivant sert en entier sont prises d'un coup —
mêmes clusters, sept fois moins de temps. Il passe de longues
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
rangement, donc **les vingt-quatre profils démarrent** — et il n'a même pas fallu, pour
cela, écrire un chargeur par format. Là où la défragmentation a demandé deux
outils parce que le format datait l'outil, un démarrage n'en demande aucun : il
ouvre des fichiers.

**La durée n'est pas décrétée, elle est mesurée.** Un démarrage n'est pas une
suite de lectures collées : entre deux fichiers, la machine décompresse,
relocalise, initialise, et le disque attend. Ce temps de calcul est le
**plancher** d'un démarrage — deux constantes par époque, calées sur des cibles
qui **ne sont pas des mesures d'époque** : les durées que le modèle donnait
avant la relecture de ses experts — et tout ce qui dépasse ce plancher est du
disque. Sur les vingt-quatre profils il pèse entre 37 et 72 % du total, et les vingt-quatre
démarrages tiennent entre 29,0 et 66,0 s.

Ces constantes vivent dans une seule table (`ThinkModel.boot`), et seul le coût
de calcul **par mégaoctet** y bouge d'un calage à l'autre : ce que les
corrections du disque ont déplacé — un tour de plateau perdu à chaque requête
contiguë, une table FAT lue deux fois, les trois caches, les enregistrements de
MFT épars — est un coût de lecture, au mégaoctet. Avec quatre profils par
époque, les écarts ne départagent plus les deux constantes ; c'est la
physique qui choisit. Pour 2003 et 2007, l'ajustement retombe sur 0,19 et
0,15 s par mégaoctet : un disque qui va chercher chaque enregistrement de MFT
là où il est coûte ce que le plancher processeur ne coûtait pas. La constante
de XP, elle, n'a pas bougé depuis : 0,185. Le chantier 51 a refait le
démarrage de XP d'après son code, et une cible qui n'est pas une mesure
d'époque ne se recale pas sur le modèle qu'on vient de corriger. Le niveau
reste injustifié — un Vista à peine plus rapide qu'un XP sur des processeurs
trois ou quatre fois plus rapides — et c'est aux cibles de le dire : seules des
mesures d'époque le trancheraient.

**Windows 7 n'a pas de cible.** Le modèle d'avant la relecture ne connaissait
pas 2012 : ses deux constantes sont celles de Vista divisées par 1,5 — un
processeur de 2012 exécute un fil à peu près deux fois plus vite qu'un Core 2 de
2007, et Windows 7 en fait un peu plus au démarrage. **Une hypothèse**, que rien
ne recoupe ; `fit-think.py` n'a rien à y ajuster. Pour le reste, Windows 7 est
un Vista : dates d'accès éteintes, préchargement par position (ReadyBoot), un
peu plus de pilotes et de services.

| | système | fichiers | lu | durée | dont calcul | témoin |
|---|---|---|---|---|---|---|
| `gamer-1993` | MS-DOS 6 et Windows 3.1 | 95 | 9 Mo | 29,7 s | 37 % | +1 % |
| `dev-1993` | MS-DOS 6 et Windows 3.1 | 121 | 17 Mo | 42,2 s | 45 % | +1 % |
| `gamer-1996` | Windows 95 | 346 | 35 Mo | 44,4 s | 48 % | +3 % |
| `famille-1999` | Windows 98 SE | 620 | 110 Mo | 64,3 s | 53 % | +10 % |
| `secretaire-1999` | Windows 98 SE | 533 | 98 Mo | 57,5 s | 53 % | +9 % |
| `gamer-2003` | Windows XP | 912 | 231 Mo | 66,0 s | 72 % | −0 % |
| `dev-2003` | Windows XP | 414 | 183 Mo | 49,8 s | 70 % | −0 % |
| `famille-2007` | Windows Vista | 683 | 136 Mo | 43,2 s | 58 % | +3 % |
| `gamer-2012` | Windows 7 | 600 | 275 Mo | 43,6 s | 68 % | +2 % |

**Le témoin** est la colonne qui compte. C'est le même contenu posé comme au
premier jour — mêmes fichiers, mêmes tailles, chacun d'un seul tenant, tassé
contre le début du volume — devant `$MFT`, sur NTFS. Seule la
place change. Sans lui une durée de démarrage ne dit rien : on ne saurait pas ce
qui, dedans, vient du disque.

Et ce qu'il dit est inattendu deux fois. **Sur les volumes FAT, la
fragmentation ne coûte presque rien à un démarrage** : de 1 à 11 %. La raison
tient en une phrase — un démarrage lit les fichiers qu'un installeur a écrits
d'affilée sur un disque encore vide, c'est-à-dire la population la **moins**
fragmentée du volume. Les fichiers en morceaux d'un `dev-1996`, ce sont ses
sorties de compilation, que personne ne lit au démarrage. Ce qui fait le bruit,
ce n'est pas que les fichiers soient hachés, c'est **l'ordre dans lequel on les
demande** et **l'étalement** de ce qu'il faut lire. Windows a fini par en tirer
la même conclusion : défragmenter n'accélérait pas le démarrage, et c'est un
rangement à part — `layout.ini` — qui s'en chargeait.

**Sur NTFS, le témoin ne gagne pas toujours.** Sur les douze volumes, l'écart va
de −1 % (`famille-2003`) à +6 %, et cinq volumes démarrent aussi vite ou plus vite
que leur témoin. NTFS choisit le trou qui
convient plutôt que le premier venu, et sa disposition réelle peut battre un
rangement naïf qui empile tout dans l'ordre du répertoire. Le témoin garde donc
son sens de borne — il dit ce qu'un rangement bête donnerait — mais il n'est pas
un majorant.

**Le préchargeur est la première différence d'époque qui ne tienne pas au
matériel.** Jusqu'à Windows 98, les fichiers partent dans l'ordre du registre et
le bras suit : sur un volume étalé, c'est du va-et-vient pur. Windows XP a
introduit le préchargeur de démarrage, et il **ne trie rien** : il relit ce
que les huit derniers démarrages ont lu — une page vue au moins deux fois —,
dans l'ordre du **premier accès**, par lots qu'il émet d'un bloc. D'abord les
enregistrements de MFT de toute la trace et le contenu de ses répertoires, une
fois ; puis, pour les pilotes, les pages de données (avec l'en-tête de chaque
image), puis les pages d'images ; puis, pendant que les pilotes
s'initialisent, le même couple pour tout ce qui précède `SMSS`. Le balayage
qu'on entend vient du **pilote de port** : `atapi` sert les requêtes en
attente par LBA croissante, un ascenseur à sens unique. Les services et
l'ouverture de session se font ensuite sur des pages en mémoire — du calcul et
des écritures —, et l'application a son propre scénario, préchargé à son
lancement. Vista a poussé l'idée avec SuperFetch ; le modèle y range la liste
par position, **sans source**. Le gain est là où on l'attend : sur
`famille-2007`, le seek moyen passe de 15 240 à 1 900 cylindres, le nombre
de seeks de 1 448 à 1 148, et le démarrage de 45,2 à 43,2 s. La même étape crépite
en 1995 et ronronne en 2003.

**La seconde est la date de dernier accès.** Jusqu'à XP, toute lecture la
réécrit — dans l'enregistrement de MFT sur NTFS, dans l'entrée de répertoire
sous VFAT —, et Vista l'a désactivée par défaut. Au premier démarrage de la
journée, chaque fichier lu salit donc ses métadonnées **ailleurs** que là où on
vient de lire. Sous XP, à la fermeture du fichier, deux choses : la page de MFT
qui porte son enregistrement, et l'entrée de son nom dans l'index de son
répertoire — deux changements **journalisés**. Le *lazy writer* pose le journal
d'abord, puis les pages, par passages d'une seconde : sur `gamer-2003`, 912
dates réécrites en 885 écritures, et 9 du journal — les enregistrements des fichiers d'un
démarrage sont épars dans la MFT, et une page en porte rarement plus de deux ou
trois ; sur `famille-2007`, aucune. MS-DOS n'avait pas ce champ.

Ce qui rend ce préchargement décisif, c'est le format. Sur FAT16, ouvrir un
fichier ne coûte presque rien : la première table est lue entière au montage et
tient en mémoire. Sur FAT32 elle fait des mégaoctets : le pilote en lit les
pages à la demande, au fil des chaînes qu'il suit, et un fichier fragmenté
renvoie le bras vers la table en tête du volume — de 227 à 353 pages sur un
démarrage de Windows 98. Et ces pages ne restent pas : elles vivent dans VCACHE
avec les données des fichiers, qui les poussent dehors, et de 69 à 105 d'entre
elles sont **relues** plus tard, quand une chaîne y repasse — le va-et-vient
d'un Windows 98 fatigué. La taille de VCACHE, 16 Mo pour une machine de 64 Mo,
est la règle de réglage de l'époque ; son vrai défaut était dynamique. Sous
MS-DOS, `SMARTDRV` lit par éléments de 8 Ko, 16 Ko d'avance, et sert une partie
de ce que le démarrage redemande ; sur un disque à 1,5 Mo/s, lire par éléments
et d'avance coûte plus que ce que le cache rend : de 1,2 à 1,8 s par démarrage.
Sur NTFS, chaque ouverture lit l'enregistrement de MFT qui décrit le
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
  triées. Sous NT, chaque vidage écrit aussi une page de `$LogFile`, le
  journal de 64 Mo que `FORMAT` pose juste devant la MFT sous XP, et
  derrière le miroir au milieu du volume sous Vista et 7. Sous XP, c'est le
  *lazy writer* tel que son code le joue : trois secondes après la première
  page salie, puis chaque seconde, un huitième des pages sales, flux par
  flux, le journal d'abord, sur trois fils que la file d'`atapi` croise — et
  il écrit aussi **les données** : la copie ne fait que salir des pages, qui
  partent par pulsations pendant que le CD se lit ;
- **le registre** (`SYSTEM.DAT` et `USER.DAT`, les ruches de NT) est posé avec le
  système et réécrit en bloc après chaque logiciel ; sous XP, cinq secondes
  après la dernière modification, avec trois `FLUSH CACHE` par ruche — ceux de
  son `.LOG` —, et avant chaque redémarrage ;
- **les redémarrages** — deux ou trois pour un système, un pour une application
  qui remplace des DLL partagées — sont de vrais démarrages, sur ce qui est
  posé jusque-là.

Les attentes humaines (détection du matériel, questions, clic sur
« Redémarrer ») sont raccourcies à quelques secondes. Les vingt-quatre installations
durent de 7 à 25 minutes : sur disquettes, la source fait plus des trois quarts
de l'attente ; sur CD et DVD, ce sont la décompression et les pauses.

| | source | posé | archives | redémarrages | durée |
|---|---|---|---:|---:|---:|
| `gamer-1993` | 21 disquettes | 373 fichiers, 39 Mo | 0 | 2 | 11 min 59 |
| `secretaire-1996` | CD-ROM 8x | 1 008 fichiers, 222 Mo | 46 | 3 | 7 min 16 |
| `famille-1999` | CD-ROM 32x | 2 412 fichiers, 574 Mo | 77 | 5 | 8 min 08 |
| `famille-2003` | CD-ROM 48x | 3 388 fichiers, 1,4 Go | 26 | 4 | 7 min 20 |
| `gamer-2007` | DVD 16x | 10 398 fichiers, 13,5 Go | 23 | 3 | 17 min 16 |
| `gamer-2012` | DVD 16x | 16 092 fichiers, 29,1 Go | 46 | 2 | 25 min 11 |

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
| `dev-1996`, jour 20 | navigation, compilation, archivage | 142 / 36 Mo | 5 min 24 |
| `dev-1996`, jour 300 | idem | 156 / 65 Mo | 6 min 52 |
| `famille-2003`, jour 400 | navigation, bureautique, téléchargement, médias | 211 / 24 Mo | 1 min 20 |
| `gamer-1999`, jour 365 | navigation, jeu | 532 / 6 Mo | 2 min 00 |

**L'usure s'entend.** Sur `dev-1996`, la même journée de travail passe d'un seek
moyen de 314 cylindres au jour 20 à 536 au jour 300 : le disque fait la même
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

**Les vingt-quatre scénarios y ont droit.** Ni la taille ni le format ne limitent plus
rien : le planificateur travaille en extents, et un volume de 320 Go ne lui
coûte pas plus cher qu'un de 180 Mo. Ce qui change avec le format, c'est
l'**outil** — parce que c'est lui que le format datait.

#### Sept défragmenteurs, dont deux d'époque

Sur un volume FAT, c'est la passe livrée avec Windows 95 puis 98 : tasser tous
les fichiers contre le début du volume, dans l'ordre du parcours de
l'arborescence. Sur les disques de 1993, l'app la nomme « MS-DOS 6 DEFRAG » —
le `DEFRAG.EXE` de Symantec sous licence, qui faisait la même chose dans le
même ordre : le modèle leur donne le même moteur. Sur un volume NTFS, c'est
le `dfrg.msc` de Windows XP, dérivé de Diskeeper Lite — l'outil qu'un
utilisateur de 2003 avait réellement sous la main —, nommé « Windows Vista
Defragmenter » en 2007 et « Windows 7 Defragmenter » en 2012, où il ne
recolle plus les fragments de 64 Mo et plus : le même moteur, par hypothèse.
Le modèle l'a longtemps décrit comme un outil qui « n'évacue personne » : c'était
faux, et **la source est le code de XP SP1** lui-même, tel qu'il a
circulé en 2020 (`dfrgntfs.cpp`, `mftdefrag.cpp`, `deviosup.c` — pas une source
ouverte, et le journal le dit, chantier 45). Sous XP, une passe commence
par **ranger le démarrage** : les fichiers que le préchargeur a notés dans
`Layout.ini` — ici la trace d'un démarrage planifié, répertoires puis fichiers
dans l'ordre du premier accès, comme `pfsvc` l'écrit —, 32 Mo au plus
chacun, partent dans cet ordre au début du plus grand trou du volume, s'il en
a un assez grand (sinon au début du volume, dont les intrus en morceaux sont
chassés), et cette zone, aucune phase ne la touche ensuite. Elle recolle alors
la MFT dès qu'elle a deux morceaux, vers le premier trou qui la tiendrait
entière hors de sa zone, puis répare les fichiers cassés du plus petit au plus
gros, chacun recopié entier dans **le plus petit trou qui le tient**, par blocs
de **64 Kio** ; quand aucun trou ne convient, elle **vide une région** — la
plus longue suite de trous et de fichiers contigus, occupée à moins de 75 % —
pour en ouvrir un, puis la zone MFT, jusqu'au premier fichier qui n'y trouve
pas de place ; et elle finit par **tasser vers l'avant** tout fichier contigu
qui a un trou devant lui. Chaque bloc de 64 Kio est une transaction : ses
enregistrements de journal attendent en mémoire, l'enregistrement de MFT et
les pages de bitmap qu'il salit partent avec le *lazy writer* — trois secondes
après la première page salie, puis à chaque passage d'une seconde, un huitième
des pages sales, flux par flux, le journal d'abord — donc pas de « clac … clac
… clac » après chaque fichier, mais un aller-retour vers le journal et les
tables chaque seconde, et un long balayage à la fin. Vista et 7 gardent le modèle d'avant : pas de rangement du
démarrage, une validation par fichier, là où il vit.

Les deux autres ne sont d'aucune époque, et ne se choisissent jamais tout seuls.
**UltraDefrag 7.1.1**, de 2018, répond à un échec des outils d'époque sur les
gros fichiers. **JkDefrag 3.36**, de 2008, est le seul qui range le volume sans
évacuer personne. On les demande explicitement (`STRATEGY=ultraDefrag`,
`STRATEGY=jkDefrag`) pour comparer des passes sur exactement le même volume.
JkDefrag s'obtient aussi dans ses autres modes, décrits plus bas.

Les deux derniers n'imitent aucun outil, et ont été écrits ici à partir de ce
que les quatre autres font mal : le **tassage à la frontière**
(`STRATEGY=frontierCompaction`) pour FAT, et le **recollage économe**
(`STRATEGY=fragmentMerge`) pour les gros volumes NTFS. Le **rangement
intelligent** (`STRATEGY=smart`), pour les deux formats, vise ce qu'on
mesure *après* la passe : le démarrage, les morceaux, les trous. Ils sont
décrits en dernier.

Dans l'app, tous se choisissent sur l'écran « Avec quel outil ? » qui suit
**Défragmenter ce disque**. L'outil d'époque y est présélectionné ; les deux
outils d'époque et les deux écrits ici ne sont proposés que sur leur format, et
les déplacements par blocs pleins s'y activent pour XP, UltraDefrag et JkDefrag.

L'écart n'est pas de degré. Passer la stratégie de 95 sur le 320 Go de
`famille-2007` tasse des centaines de gigaoctets par tampons de 256 Ko : 4 786 660
requêtes et 5 h 47 de passe simulée pour ranger 2 752 fichiers sur 12 244. La
passe de XP sur le même volume tient en **1 159 153 requêtes et 29 min 21**.

| scénario NTFS     | plein | requêtes | durée      | déplacés | fragmentés avant → après | morceaux avant → après |
|-------------------|------:|---------:|-----------:|---------:|--------------------------|------------------------|
| `gamer-2003`      |   9 % |   27 139 |   1 min 40 |     1829 | 14 → **0**               | 109 → **0**            |
| `secretaire-2003` |  91 % |  495 879 |  30 min 32 |    10305 | 5 912 → 286              | 36 327 → 4 166         |
| `famille-2003`    |  88 % |   95 955 |   6 min 31 |     2800 | 689 → 35                 | 10 665 → 4 348         |
| `dev-2003`        |  91 % |  703 838 |  39 min 56 |     9348 | 690 → **0**              | 3 472 → **0**          |
| `secretaire-2007` |  88 % | 2 146 170 |  51 min 03 |     5219 | 839 → 1                  | 15 720 → 2             |
| `famille-2007`    |  97 % | 1 159 153 |  29 min 21 |    10130 | 2 752 → 169              | 71 575 → 29 960        |
| `gamer-2007`      |  87 % | 6 973 481 |     2 h 19 |    12640 | 3 386 → 30               | 61 230 → 68            |
| `dev-2007`        |  93 % | 5 645 775 |     2 h 22 |    13495 | 1 408 → 1                | 105 462 → 2            |
| `secretaire-2012` |  89 % | 4 905 121 |     1 h 01 |     6739 | 1 054 → **0**            | 19 411 → **0**         |
| `famille-2012`    |  92 % | 14 250 117 |     3 h 03 |    22156 | 3 904 → 228              | 82 824 → 10 263        |
| `gamer-2012`      |  92 % | 20 604 946 |     3 h 57 |    19038 | 4 319 → 13               | 81 041 → 202           |
| `dev-2012`        |  85 % | 5 331 272 |  55 min 48 |    16639 | 1 386 → 1                | 63 867 → 2             |

Ce qu'il laisse en morceaux, il le dit dans son rapport : un fichier que ni
un trou ni une région vidée ne peuvent recevoir y reste.
Et **le remplissage ne suffit pas à le prédire**. `dev-2003` et
`secretaire-2003` sont deux volumes de 40 Go remplis tous deux à 91 % : le premier
répare 690 fichiers sur 690, le second 5 626 sur 5 912. La taille de ce qu'il y a à
réparer ne l'explique pas non plus — 2 Mo par fichier déplacé chez le
développeur, 1,2 Mo chez la secrétaire. Ce qui sépare les deux volumes n'est pas établi : il
faudrait compter les échecs par taille, et regarder où tombent les trous.

**Tous ces outils sont soumis à la même règle du volume, et elle dépend du
système.** Sous XP, le code du pilote la donne : ce qu'un déplacement quitte
est libre tout de suite dans la bitmap que relit un outil, et un déplacement
qui s'y pose lève `STATUS_DELETE_PENDING` — le pilote vide alors le journal,
oublie tout ce qu'il suivait et recommence (`bitmpsup.c`, `deviosup.c`). XP et
JkDefrag s'y posent donc aussitôt, au prix d'une écriture de `$LogFile` ;
UltraDefrag garde sa propre règle, un tour de routine. Leurs décisions ne
dépendent plus de l'horloge : sans aucun point de contrôle, les passes des
quatre volumes de 2003 prennent les mêmes, seuls les vidages changent. Les
tris de JkDefrag, qui évacuent une place pour s'y poser, vont maintenant au
bout. Pour NT 4 — et, faute de source, pour Vista et 7 —, le modèle garde la
règle que décrit Russinovich : les clusters qu'un déplacement quitte ne
redeviennent libres qu'au point de contrôle suivant, que Windows fait toutes
les cinq secondes ; d'ici là, le bitmap les montre occupés et un déplacement
vers eux échoue. La règle est portée par le volume — `DefragVolume` y refuse
tout déplacement qui rendrait aussitôt ce qu'il quitte —, et chaque outil n'y
choisit que sa cadence : celle de Windows pour XP et JkDefrag, qui relisent le
bitmap à chaque trou, un tour de routine pour UltraDefrag, qui tient sa propre
liste. Pour l'outil de Vista, la règle ne change presque rien : un gros
fichier cassé se déplace en plus de cinq secondes, et un point de contrôle est
passé quand vient le suivant. Le chiffre de cinq
secondes, le seul choisi dans ce réglage, ne décide pas non plus du résultat :
à une seconde ou à trente, XP et JkDefrag laissent au plus 17 fichiers cassés de
plus ou de moins. Ces secondes sont comptées sur une horloge que le
planificateur estime d'après les disques de 2003 à 2006 du catalogue, seek
moyen et débit compris. Seule l'hypothèse d'un point de contrôle unique en fin
de passe change le résultat — sur `dev-2007`, XP laisserait alors 769 fichiers en
morceaux au lieu de 1.

#### Recoller au lieu de déplacer

UltraDefrag part du constat que ces gros fichiers n'ont **pas besoin d'être
déplacés** pour aller mieux. Un fichier de deux cents mégaoctets en quatre morceaux devient
rapide à lire dès qu'on recolle ses trois petits éclats ; le gros bloc, lui, ne
gagne rien à voyager. Sa passe traite les fichiers *les plus fragmentés
d'abord*, recopie entiers ceux qui font moins de 40 Mo, et sur les autres ne
fusionne que les fragments de moins de 20 Mo. C'est ce que la comparaison des
deux bases de code donne comme sans équivalent chez JKDefrag.

Le résultat ne se lit pas dans la colonne « fragmentés », et c'est tout le
sujet : un fichier ramené de quarante morceaux à deux y reste « fragmenté ».

| scénario NTFS     | morceaux restants, XP | UltraDefrag |  requêtes XP → UD |    durée XP → UD |
|-------------------|----------------------:|------------:|------------------:|-----------------:|
| `secretaire-2003` |                 4 166 |         435 | 495 879 → 106 685 | 30 min 32 → 24 min 24 |
| `famille-2003`    |                 4 348 |         627 |   95 955 → 31 262 | 6 min 31 → 7 min 48 |
| `dev-2003`        |                     0 |           6 |  703 838 → 14 712 | 39 min 56 → 8 min 10 |
| `secretaire-2007` |                     2 |           0 | 2 146 170 → 42 770 | 51 min 03 → 28 min 21 |
| `famille-2007`    |                29 960 |       1 139 | 1 159 153 → 151 439 | 29 min 21 → 20 min 19 |
| `gamer-2007`      |                    68 |         161 | 6 973 481 → 139 038 | 2 h 19 → 46 min 17 |
| `dev-2007`        |                     2 |          77 | 5 645 775 → 226 980 | 2 h 22 → 45 min 25 |
| `secretaire-2012` |                     0 |           2 | 4 905 121 → 50 624 | 1 h 01 → 23 min 10 |
| `famille-2012`    |                10 263 |       1 313 | 14 250 117 → 188 575 | 3 h 03 → 40 min 05 |
| `gamer-2012`      |                   202 |         562 | 20 604 946 → 182 891 | 3 h 57 → 27 min 49 |
| `dev-2012`        |                     2 |           0 | 5 331 272 → 142 218 | 55 min 48 → 25 min 25 |

Sur `famille-2007`, les 29 960 morceaux que XP laisse derrière lui tombent à
**1 139** — 96 % de moins — pendant que le nombre de fichiers fragmentés, lui,
reste à 176. Il lui faut 7,7 fois moins de requêtes et 1,4 fois moins de temps.

UltraDefrag ne réutilise pas dans un tour l'espace qu'il vient de libérer : il
ne relit sa liste de trous qu'en tête de tour, même quand le point de contrôle
de Windows est passé entre-temps. Et il range des fichiers **dans la zone
réservée à la MFT** : son source ne la retire des régions libres que sous
Windows 2000 et avant, parce qu'il a sa propre routine d'optimisation de la MFT.
Sur `gamer-2007`, c'est le plus grand trou du volume. Ses destinations sont donc
plus grandes, pas forcément plus lointaines — sur `dev-2007`, son seek moyen est
plus court que chez XP : 18 483 cylindres contre 27 628, le cache d'écriture
posant les écritures des deux dans l'ordre de l'ascenseur — et un morceau
inversé compte pour deux : la tête le lit dans l'ordre du fichier. L'outil de XP, lui, respecte la zone :
ses listes de trous en sont rognées (`BuildFreeSpaceList`), et il la vide une fois par passe.

Cela ne fait pas d'UltraDefrag le meilleur outil partout. XP fait mieux sur
cinq des onze volumes : il nettoie entièrement `dev-2003` et `secretaire-2012`,
où UltraDefrag laisse 6 et 2 morceaux. Et sur un volume FAT de 1996, où presque
aucun fichier n'atteint 40 Mo,
la défragmentation partielle n'a rien à mordre : sur `dev-1996`, la passe tient
en 1 min 24 contre 21 min 31 à l'outil de 95, parce qu'elle n'évacue personne. Elle
laisse 1 085 morceaux — et l'outil de 95, sur ce volume-là, en laisse 602 : à
87 % de remplissage, il ne trouve plus où évacuer non plus, et saute les places
qu'il ne peut pas libérer. Elle ne touche pas aux répertoires FAT, que Windows
ne sait pas déplacer entiers.

#### Ranger sans évacuer

JkDefrag joue son mode par défaut, le mode 2, qui enchaîne quatre passes :
recopier les fichiers cassés dans le premier trou à leur taille, ou par tranches
dans les plus grands ; renvoyer chaque fichier dans sa **zone** (les gros, les
archives, les installateurs au fond du volume, derrière les fichiers ordinaires
et une réserve de 1 %) ; combler chaque trou, de bas en haut, par des fichiers
pris plus haut, au cluster près si une combinaison existe, sinon par le plus
haut qui tient ; puis remettre en zone ce que l'optimisation a dérangé. Une
destination est toujours un trou déjà libre.

Sur FAT, il fait en quelques minutes ce que Windows 95 fait en 21 min 31 à
59 min 57, et il laisse plus de morceaux derrière lui dès que les trous
manquent :

| scénario | plein | durée, 95 → JkDefrag | évacuations, 95 | morceaux restants, 95 → JkDefrag |
|---|---:|---:|---:|---:|
| `dev-1993` | 72 % | 24 min 42 → 5 min 54 | 3 090 | 0 → 15 |
| `dev-1996` | 87 % | 21 min 31 → 9 min 15 | 4 060 | 602 → 393 |
| `secretaire-1999` | 87 % | 28 min 05 → 16 min 22 | 1 640 | 58 → 1 277 |
| `famille-1999` | 96 % | 59 min 57 → 15 min 24 | 2 542 | 19 → 2 140 |
| `gamer-1996` | 99 % | 5 s → 5 s | 1 | 1 417 → 1 417 |

À 99 %, il ne fait presque rien : un outil qui n'évacue personne a besoin de
trous. **Et l'outil de 95 non plus** : sur `gamer-1996`, dont les quelques centaines de
clusters libres ne logent aucun de ses gros fichiers, il n'évacue qu'un
occupant avant de se retrouver bloqué partout, et rend le volume intact. C'est la limite
réelle de l'algorithme de 1995, et c'est pourquoi l'outil demandait de faire de
la place avant de le lancer.

Sur FAT, il commence aussi par échouer. Windows ne sait pas déplacer le premier
cluster d'un répertoire FAT — ses sous-répertoires portent ce numéro dans leur
entrée `..`, et le pilote refuse de les réécrire tous à la fois —, et JkDefrag
le sait : « JkDefrag will still try », mais au-delà de vingt échecs d'affilée il
ne tente plus aucun répertoire, et les compte tous pour immobiles dans ses
zones. Chaque échec recalcule les zones. Sur six des huit volumes FAT de 1996
et 1999, la passe commence donc par vingt et un échecs, puis abandonne la classe
entière : sur `famille-1999`, 730 répertoires ne sont même plus essayés. Sur les
autres, et sur ceux de 1993, elle s'arrête avant — de 5 à 11 répertoires à
tenter. La zone 0 reste où elle était.

Une tranche de `Defragment` peut déborder de la fin du fichier : l'original
calcule sa taille avant de sauter les morceaux déjà bien placés, et ne la
recalcule pas. Windows la **borne** à la fin du fichier plutôt que de la
refuser — le pilote FAT le fait explicitement, et Microsoft documente qu'un
déplacement au-delà de la taille allouée est permis sur NTFS. Les tranches qui
débordent sont donc recopiées. Sur `famille-1996`, le volume FAT où JkDefrag
fait son plus mauvais score, il laisse 4 605 morceaux.

Sur NTFS, les morceaux restants restent du même ordre de grandeur qu'avec
UltraDefrag, mieux sur trois volumes, un peu moins bien sur deux. Mais la passe range
tout le volume et déplace bien plus que les seuls fichiers cassés — 4,1 Go sur
`gamer-2003`, plein à 9 % et sans un fichier en morceaux :

| scénario | plein | morceaux restants, XP | UltraDefrag | JkDefrag | durée, XP → JkDefrag | Go déplacés, XP → JkDefrag |
|---|---:|---:|---:|---:|---:|---:|
| `secretaire-2003` | 91 % | 4 166 | 435 | 769 | 30 min 32 → 28 min 47 | 12,4 → 22,1 |
| `famille-2003` | 88 % | 4 348 | 627 | 502 | 6 min 31 → 21 min 10 | 2,3 → 18,4 |
| `dev-2003` | 91 % | 0 | 6 | 104 | 39 min 56 → 9 min 57 | 20,2 → 9,4 |
| `gamer-2003` | 9 % | 0 | 0 | 0 | 1 min 40 → 3 min 54 | 0,7 → 4,1 |
| `famille-2007` | 97 % | 29 960 | 1 139 | 1 067 | 29 min 21 → 36 min 42 | 34,3 → 56,1 |
| `gamer-2007` | 87 % | 68 | 161 | 30 | 2 h 19 → 1 h 54 | 219,3 → 195,1 |

La zone MFT que voient ces passes est la zone **courante** — sous XP, celle que
recalcule le montage qui précède la passe ; sous Vista et 7, réduite de moitié
chaque fois que le reste du volume s'est rempli —, et non la réserve d'origine :
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

Un tri évacue une place, puis s'y pose. Sur FAT, la place est libre dès
l'évacuation validée, et le tri range : sur `secretaire-1999`, il laisse 293
morceaux contre 1 277 au mode 2. Sur un NTFS de Vista ou de 7, elle ne l'est
qu'au point de contrôle suivant, et `FindGap`, qui relit le bitmap juste après
l'évacuation, la trouve encore prise : le fichier part dans le trou suivant, en
morceaux s'il le faut. L'auteur de JkDefrag décrit ce cas dans son code. Sur
`famille-2007`, le tri par nom déplace 33 Go en 44 435 évacuations et 25 min 53,
et laisse 37 978 morceaux sur les 71 575 du départ ; `gamer-2007` en sort avec
20 164 morceaux, contre 30 au mode 2. Sous XP, la place est libre tout de suite
— s'y poser fait vider le journal (`STATUS_DELETE_PENDING`) — et le tri va au
bout, sans ranger mieux pour autant : sur `secretaire-2003`, il laisse 15 875
morceaux contre 769 au mode 2. Sur un volume NTFS plein, un tri de JkDefrag
range à peine.

Le catalogue ne date que les écritures, au jour près : le dernier accès y est la
dernière écriture, et à jour égal c'est le chemin qui départage — unique, puisque
le générateur ne fait jamais coexister deux fichiers au même chemin.

Les passes FAT de Windows 95 vont de 7 s (`gamer-1993`) à 1 h 01
(`gamer-1999`) sur les onze volumes où l'outil a de quoi travailler — une heure
pour les 6 Go de 1999, l'ordre de grandeur qu'on attendait d'un Windows 98.
La démo de défragmentation a pris un autre outil que celui de 95 : 5 min 31 sur
`dev-1993` au lieu de 24 min 42, pour le même résultat. Ce n'est pas la taille
du volume qui fixe la durée : `secretaire-1993`, le plus petit disque de la
galerie, y passe 20 min 29 — 170 Mo dont 71 % des fichiers fragmentables sont en
morceaux, lus à 1,8 Mo/s — quand `dev-1996`, six fois plus gros, en prend 22.

Ce qui la fixe, c'est le va-et-vient. L'outil évacue au **fond du volume**, sa
zone de manœuvre, où la frontière ne repasse qu'à la fin — un choix du modèle,
calé sur les durées d'époque (chantier 24), qu'aucune source sur `DEFRAG` ne
décrit : `dev-1999` déplace
8 904 Mo pour un contenu de 6 Go, en 4 136 évacuations. Reposer les évacués
juste au-dessus de la frontière, qui les rattraperait quelques fichiers plus
loin, ferait déplacer à la passe jusqu'à seize fois son contenu. Le prix est sur
les volumes pleins : quand la frontière arrive au fond, elle y trouve ses
propres réfugiés et plus de place au-dessus, et `famille-1996`, plein à 99 %, en
sort avec 5 108 morceaux. C'est pour cela que l'outil d'époque demandait de faire de la place
avant de le lancer.

#### Tasser sans changer l'ordre

Sur FAT, les outils simulés se partagent deux défauts. Windows 95 range, mais
dans un autre ordre que celui du volume, et quand le fond est plein il ne sait
plus où évacuer : il laisse alors des milliers de morceaux (`dev-1999`,
`gamer-1999`). JkDefrag et UltraDefrag ne délogent personne, et n'ont plus rien
à faire quand les trous manquent — à 99 %, ils ne réparent pas un des 407
fichiers cassés de `gamer-1996`, et l'outil de 95 non plus.

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
| `dev-1993` | 72 % | 24 min 42 → 5 min 54 → **5 min 31** | 0 / 15 / **0** | 2 / 11 / **1** |
| `secretaire-1993` | 92 % | 20 min 29 → 8 min 53 → **19 min 21** | 0 / 15 / **0** | 2 / 155 / **1** |
| `poweruser-1993` | 84 % | 17 min 00 → 6 min 20 → **7 min 41** | 0 / 44 / **0** | 1 / 29 / **1** |
| `gamer-1993` | 99 % | 7 s → 6 s → **32 min 30** | 838 / 836 / **0** | 5 / 7 / **1** |
| `dev-1996` | 87 % | 21 min 31 → 9 min 15 → **9 min 12** | 602 / 393 / **334** | 212 / 282 / **115** |
| `famille-1996` | 99 % | 48 s → 1 min 08 → **14 min 03** | 5 108 / 4 605 / **5** | 32 / 388 / **1** |
| `secretaire-1996` | 74 % | 10 min 52 → 11 min 24 → **5 min 53** | 3 / 9 / **3** | 2 / 120 / **1** |
| `gamer-1996` | 99 % | 5 s → 5 s → **59 min 45** | 1 417 / 1 417 / **46** | 1 / 1 / **1** |
| `dev-1999` | 85 % | 46 min 38 → 29 min 12 → **42 min 34** | 3 / 350 / **3** | 4 / 285 / **2** |
| `famille-1999` | 96 % | 59 min 57 → 15 min 24 → **27 min 48** | 19 / 2 140 / **19** | 20 / 989 / **1** |
| `secretaire-1999` | 87 % | 28 min 05 → 16 min 22 → **15 min 52** | 58 / 1 277 / **58** | 59 / 1 046 / **1** |
| `gamer-1999` | 89 % | 1 h 01 → 26 min 40 → **31 min 56** | 5 / 536 / **5** | 6 / 557 / **1** |

Les morceaux qui restent sont presque tous **ceux du fichier d'échange**, que
personne ne déplace : aucun fichier déplaçable ne sort de la passe en morceaux,
sauf sur `gamer-1996` (4 de plus). Les trous qui restent sont entre ces
morceaux — sur `dev-1996`, 334 morceaux ne laissent plus que 115 trous.
Même `gamer-1993`, plein à 99 %, en sort sans un morceau (838 au départ) : deux
clusters libres suffisent à la navette.

Sur les douze volumes, la passe dure 4 h 32 au total contre 4 h 51 pour
Windows 95, et elle déplace 1,4 fois moins de données (29,8 Go contre 40,5).
Ce n'est pas la durée qui les sépare — 19 min d'écart sur les douze volumes,
et la moindre correction du modèle fait passer l'avantage de l'un à l'autre —,
c'est ce qu'ils laissent : sur les volumes de 1999, Windows 95 laisse jusqu'à
58 morceaux et 59 trous, la frontière 58 morceaux et 2 trous au plus — les
mêmes morceaux, ceux du fichier d'échange, mais l'espace libre d'un seul
tenant. Elle est 2,1 fois plus longue que JkDefrag (2 h 11), qui ne fait pas
le même travail : sur les quatre
volumes de 1999, il laisse entre 350 et 2 140 morceaux et de 285 à 1 046
trous. Et c'est le seul des trois à ranger `gamer-1996`, plein à 99 %, où
l'algorithme de 1995 ne trouve plus où évacuer et rend le volume tel quel : là,
tout passe par une navette de deux clusters, et chaque tronçon se paie d'une
écriture des tables. Le groupement des validations en souffre : sur ce volume,
un lot n'en valide que 1,4 en moyenne, contre 1,7 à 12 sous 90 % de
remplissage.

#### Recoller peu, sur les gros volumes

Sur les volumes NTFS de 2003 à 2012, la place ne manque plus — 2 à 88 Go
libres — mais la taille : le tassage à la frontière y déplace tout le contenu
du volume, jusqu'à 972 Go et 4 h 30 de passe. Et la fragmentation y est
faite de miettes : sur `famille-2007`, 2 752 fichiers cassés en 71 575 morceaux.
Chacun coûte une lecture : c'est leur nombre, pas leur poids, qui fait la durée.

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
| `dev-2003` | 91 % | 39 min 56 / 8 min 10 / 9 min 57 / **1 min 55** | 0 / 6 / 104 / **272** | 207 / 943 / 224 / **31** |
| `famille-2003` | 88 % | 6 min 31 / 7 min 48 / 21 min 10 / **7 min 30** | 4 348 / 627 / 502 / **612** | 3 739 / 3 389 / 667 / **147** |
| `secretaire-2003` | 91 % | 30 min 32 / 24 min 24 / 28 min 47 / **11 min 26** | 4 166 / 435 / 769 / **618** | 3 895 / 2 412 / 1 417 / **197** |
| `gamer-2003` | 9 % | 1 min 40 / 6 s / 3 min 54 / **7 s** | 0 / 0 / 0 / **0** | 228 / 93 / 20 / **76** |
| `dev-2007` | 93 % | 2 h 22 / 45 min 25 / 1 h 21 / **12 min 37** | 2 / 77 / 63 / **868** | 1 847 / 7 845 / 798 / **79** |
| `famille-2007` | 97 % | 29 min 21 / 20 min 19 / 36 min 42 / **12 min 24** | 29 960 / 1 139 / 1 067 / **1 525** | 12 272 / 8 499 / 1 177 / **234** |
| `gamer-2007` | 87 % | 2 h 19 / 46 min 17 / 1 h 54 / **12 min 26** | 68 / 161 / 30 / **877** | 2 064 / 7 401 / 942 / **184** |
| `secretaire-2007` | 88 % | 51 min 03 / 28 min 21 / 40 min 24 / **4 min 08** | 2 / 0 / 0 / **206** | 1 622 / 3 530 / 639 / **82** |
| `dev-2012` | 85 % | 55 min 48 / 25 min 25 / 48 min 30 / **6 min 02** | 2 / 0 / 0 / **231** | 3 293 / 9 475 / 254 / **223** |
| `famille-2012` | 92 % | 3 h 03 / 40 min 05 / 1 h 10 / **11 min 09** | 10 263 / 1 313 / 1 086 / **2 181** | 8 076 / 10 499 / 905 / **219** |
| `gamer-2012` | 92 % | 3 h 57 / 27 min 49 / 1 h 11 / **9 min 44** | 202 / 562 / 467 / **892** | 5 378 / 10 291 / 906 / **294** |
| `secretaire-2012` | 89 % | 1 h 01 / 23 min 10 / 36 min 43 / **3 min 31** | 0 / 2 / 0 / **144** | 2 051 / 4 743 / 206 / **89** |

Sur les douze volumes, la passe dure 1 h 33, contre 16 h 19 pour XP, 4 h 57 pour
UltraDefrag et 9 h 24 pour JkDefrag. Elle laisse 8 426 morceaux et 1 855
trous : moins de morceaux que XP mais plus qu'UltraDefrag et JkDefrag, et
moins de trous que chacun d'eux. Sa durée tient à deux choses qui jouent en sens
contraires. Le cache d'écriture du disque pose les destinations de XP,
contiguës, par salves de 4,4 à 93,3 écritures selon le volume, quand celles du
recollage sont éparses, 1,2 par vidage : cela avantage XP. Mais XP recopie en
entier chaque fichier cassé, vide des régions et tasse tout le volume vers
l'avant, quand le recollage ne déplace que les morceaux : c'est ce qui
l'emporte, de loin. Les blocs pleins ne comptent presque plus : donnés à
XP et à UltraDefrag (`FULL_BLOCKS=1`), ils les mènent à 14 h 30 et 4 h 54, sans
changer ce qu'ils laissent — à un fichier près, les points de contrôle ne
tombant plus aux mêmes déplacements. Ce que la passe apporte en propre, c'est
la durée et l'espace libre, pas le dernier morceau. Elle ne recopie jamais un
fichier entier : sur `dev-2007`, où un grand trou accueille tout, XP en laisse
2, JkDefrag 63, et elle 868.

#### Ranger pour démarrer

Les six outils précédents se jugent à ce qu'ils laissent — morceaux, trous — et
à ce qu'ils coûtent. Le **rangement intelligent** (`smart`) se
juge à trois mesures prises *après* la passe : les morceaux, les trous, et la
durée du **démarrage** du disque rangé. La durée de la passe n'en fait pas
partie.

Le démarrage est le seul des trois qu'aucun outil ne visait, et c'est lui qui
décide de la méthode. Ce qu'il lit — noyau, pilotes, services, polices,
application — tient en quelques centaines de mégaoctets, et le système sait
dans quel ordre : le préchargeur de Windows XP l'écrit dans `Layout.ini` pour
que le défragmenteur les range à la suite, et « Réorganiser les fichiers
programme » de Windows 98 se servait des journaux du moniteur de tâches. La
passe reçoit donc cette liste (`BootLayout`), tirée du démarrage planifié, et
pose chaque élément en tête du volume — devant `$MFT` sur NTFS —, dans
l'ordre de sa première lecture, répertoires compris. Ce qui occupe la place en
est chassé, entier quand il y est surtout, sinon le seul morceau qui gêne.

Le reste est tassé derrière par le moteur du tassage à la frontière, avec deux
retouches. Les fenêtres qui suivent la dernière assez grande pour recevoir tout
l'espace libre sont remplies **d'abord** : sans cela l'espace libre finit semé
entre les morceaux du fichier d'échange ou de petits métafichiers NTFS — sur
`dev-1996`, 115 trous au tassage à la frontière, 2 au rangement. Et sur NTFS,
les fichiers qui pèsent plus du quart
de l'espace libre suivent le bloc de démarrage, parce que les fenêtres de la fin
du volume ne leur garderaient pas de place ; une zone MFT que les fichiers
occupent déjà à plus de moitié n'est plus respectée, parce qu'elle ne réserve
plus rien.

La table porte sur les vingt-quatre disques, mesurés au chantier 52 sur le
modèle du chantier 51 (`smart.sh`, `passes.py <étape>:smart`) : elle datait
d'avant les lots réalisme et les chantiers 47 à 51, et ne comptait pas 2012.

| scénario | plein | démarrage : livré / meilleur outil / **intelligent** | morceaux restants : meilleur outil / **intelligent** | trous libres : meilleur outil / **intelligent** | passe |
|---|---:|---:|---:|---:|---:|
| `dev-1993` | 72 % | 42,2 / 41,8 / **38,3** | 0 / **0** | 1 / **1** | 7 min 19 |
| `gamer-1993` | 99 % | 29,7 / 29,7 / **27,0** | 0 / **0** | 1 / **1** | 35 min 02 |
| `secretaire-1993` | 92 % | 35,5 / 34,9 / **32,0** | 0 / **0** | 1 / **1** | 19 min 46 |
| `poweruser-1993` | 84 % | 41,9 / 41,5 / **38,7** | 0 / **0** | 1 / **1** | 10 min 57 |
| `dev-1996` | 87 % | 58,8 / 56,6 / **52,3** | 334 / **334** | 115 / **2** | 15 min 28 |
| `famille-1996` | 99 % | 55,2 / 54,1 / **48,9** | 5 / **5** | 1 / **1** | 18 min 12 |
| `gamer-1996` | 99 % | 44,4 / 44,4 / **39,5** | 46 / **39** | 1 / **1** | 1 h 07 |
| `secretaire-1996` | 74 % | 54,7 / 54,1 / **50,1** | 3 / **3** | 1 / **1** | 7 min 54 |
| `dev-1999` | 85 % | 57,7 / 50,6 / **44,7** | 3 / **3** | 2 / **1** | 35 min 55 |
| `famille-1999` | 96 % | 64,3 / 57,8 / **51,8** | 19 / **19** | 1 / **2** | 30 min 03 |
| `gamer-1999` | 89 % | 54,8 / 51,1 / **46,1** | 5 / **5** | 1 / **1** | 36 min 16 |
| `secretaire-1999` | 87 % | 57,5 / 52,4 / **46,9** | 58 / **58** | 1 / **1** | 18 min 48 |
| `dev-2003` | 91 % | 49,8 / 49,1 / **48,4** | 0 / **0** | 31 / **4** | 38 min 18 |
| `famille-2003` | 88 % | 32,4 / 30,5 / **29,5** | 502 / **0** | 147 / **3** | 58 min 47 |
| `gamer-2003` | 9 % | 66,0 / 63,8 / **62,8** | 0 / **0** | 20 / **6** | 5 min 20 |
| `secretaire-2003` | 91 % | 34,3 / 31,5 / **31,5** | 435 / **0** | 197 / **3** | 53 min 00 |
| `dev-2007` | 93 % | 42,4 / 41,9 / **39,3** | 2 / **0** | 79 / **2** | 3 h 06 |
| `famille-2007` | 97 % | 43,2 / 41,9 / **38,2** | 1067 / **0** | 234 / **10** | 4 h 17 |
| `gamer-2007` | 87 % | 30,7 / 29,1 / **26,6** | 30 / **0** | 184 / **3** | 2 h 53 |
| `secretaire-2007` | 88 % | 41,1 / 40,9 / **37,7** | 0 / **0** | 82 / **2** | 2 h 48 |
| `dev-2012` | 85 % | 39,1 / 38,9 / **37,2** | 0 / **0** | 223 / **2** | 2 h 09 |
| `famille-2012` | 92 % | 29,0 / 27,4 / **24,4** | 1086 / **0** | 219 / **2** | 4 h 14 |
| `gamer-2012` | 92 % | 43,6 / 42,8 / **40,9** | 202 / **0** | 294 / **2** | 2 h 25 |
| `secretaire-2012` | 89 % | 33,9 / 33,8 / **30,1** | 0 / **0** | 89 / **3** | 2 h 12 |

« Meilleur outil » est, pour chaque colonne et chaque volume, le meilleur des
quatre autres outils de son format — Windows 95, JkDefrag, UltraDefrag et le
tassage à la frontière sur FAT ; XP, JkDefrag, UltraDefrag et le recollage
économe sur NTFS —, démarré de la même façon (`SCENARIO=boot:<profil>` avec une
`STRATEGY`). Sur les douze FAT, les démarrages passent de 596,7 s livrés et
569,0 s au mieux à **516,3 s** ; sur les douze NTFS, de 485,5 et 471,6 s à
**446,6 s**. Le bloc de démarrage atteint la borne d'un rangement idéal posé à
la main, que le journal mesure (`LEDGER.md`, chantier 28). Les morceaux qui
restent sur FAT sont presque tous ceux du fichier d'échange, que personne ne
déplace — `gamer-1996` garde un fichier de plus en morceaux —, et `gamer-1993`,
plein à 99 %, est rangé comme les autres. Les trous tombent de 127 à 14 sur
FAT et de 1 799 à 42 sur NTFS ; un volume fait exception, `famille-1999`, où la
frontière seule en laisse 1 et le rangement 2.

Le prix est la passe. Sur FAT, elle dure 5 h 03 pour les douze volumes, contre
4 h 32 au tassage à la frontière et 4 h 51 à Windows 95. Sur NTFS, c'est un
tassage complet : 3,7 To déplacés et 26 h 45 pour les douze volumes, jusqu'à
4 h 17 sur `famille-2007`, quand le recollage économe s'en tient à 1 h 33.

Le rendu hors-ligne accepte les mêmes identifiants, préfixés de `boot:` pour le
démarrage :

```sh
SCENARIO=dev-1993 /tmp/rendertrace dev1993.wav        # la passe
SCENARIO=boot:dev-1993 /tmp/rendertrace boot1993.wav  # le démarrage
```

## Ce qui ne l'est pas

- **La couche rotation est procédurale, et c'est toujours le maillon faible.**
  La littérature et tous les projets qui fonctionnent bouclent un
  enregistrement ; synthétiser le ronronnement comme une série harmonique du
  régime a été explicitement invalidé. Le régime, le
  nombre de plateaux et le palier forment le spectre et le niveau, pris aux
  manuels — mais la forme des bandes reste un choix, et un enregistrement par
  époque vaudrait mieux. **À remplacer par des samples CC0 bouclés.**
- Aucun échantillon n'est embarqué : tout est synthétisé. Pour la couche tête
  c'est défendable, c'est justement la couche où aucun asset isolé de seek sain
  n'est disponible en CC0.
- **Des constantes sont des ordres de grandeur, et le disent dans leur code.**
  Aucune source ne donne la commutation de tête (six dixièmes du pas de piste,
  que le manuel du Fireball contredit), la lecture sans latence, le coût de
  commande hors de la machine de 1999 qui l'a mesuré, le paquet d'écriture de
  64 Ko et le bloc de huit clusters de la MFT de Vista et 7, l'écriture de 4 Ko
  des programmes dont le code n'est pas lu sous XP (le `.pst` d'Outlook
  compris) et le pas de 16 Ko de Word, un minimum, huit validations — huit
  blocs de 64 Kio sous XP, huit dates d'accès — par page de journal, la
  mémoire d'une machine de XP (plus de 220 Mo : le seuil de rattrapage du
  *lazy writer*), les 64 Ko d'une lecture de programme par le cache, les
  quatre bornes de recherche de `NTFSAllocator` hors XP,
  le point de contrôle NTFS placé entre deux événements de l'histoire et le
  montage au premier de chaque journée, les bandes et le
  battement du roulement, la seconde avant la coupure et la redescente du
  plateau — ni les cibles de démarrage sur lesquelles `ThinkModel` est calé.
  `LEDGER-EXPERTS.md` en tient la liste.
- **Les défragmenteurs écrivent par requêtes de 64 Kio** (XP, le bloc du noyau),
  de 4 Mo (JkDefrag et UltraDefrag sur NTFS) et de 256 Ko (Windows 95, et
  `fastfat` quand JkDefrag ou UltraDefrag tournent sur FAT, découpés en
  paquets de 124 Ko), que personne d'autre ne découpe. Sous XP, `classpnp`
  coupe à 124 Ko ce qui ne passe pas par le cache — les lots du préchargeur —
  et le cache s'en tient à 64 Ko ; les installations et les journées d'avant ne
  dépassent pas 256 secteurs, la limite d'une commande ATA sans LBA48, et Vista
  et 7 gardent ce plafond faute de code. Sous XP, le pilote NTFS
  (`NtfsDefragFile`) coupe pourtant **tout** `FSCTL_MOVE_FILE` en blocs de
  64 Kio, une transaction chacun, quel que soit l'outil : le modèle ne l'applique
  qu'à l'outil de XP, et JkDefrag et UltraDefrag y gardent leurs requêtes de
  4 Mo, une transaction par requête.
- **Le démarrage de XP suit son préchargeur, avec des trous.** Pas de trace :
  ce qu'on lit d'un fichier reste le budget de l'acte, lu d'un tenant depuis
  le début — ce que ferait `MmPrefetchPages` de pages tracées qu'aucun écart de
  plus de 128 Ko ne sépare. La machine est supposée avoir assez de mémoire pour
  un seul passage avant `SMSS` (la troncature par la mémoire disponible n'est
  pas jouée), sans phase parallèle à l'initialisation vidéo, et l'application
  lancée a son propre scénario, sans être dans la trace du démarrage. Le
  dernier acte reste hors trace. Ce que le *lazy writer* n'a pas posé à la fin
  du silence final est écrit après la fenêtre du démarrage. Seuls les
  démarrages horodatent : une journée ne réécrit pas les dates de ce qu'elle
  lit, ni l'index d'un répertoire où naît un fichier.
- **Le registre n'a pas de `.LOG`** dans le catalogue : de son vidage, seuls les
  trois `FLUSH CACHE` par ruche sont joués, et la ruche est réécrite en entier,
  parce que rien ne dit ce qu'une installation en salit. Seules les
  installations le vident : rien ne dit quelles réécritures d'un démarrage ou
  d'une journée touchent le registre.
- **La géométrie radiale est une convention.** Le rapport du rayon intérieur
  au rayon extérieur est figé à 0,42 (`normalizedRadius`), y compris pour les
  plateaux de 2,5 pouces du VelociRaptor, et c'est lui qui porte la course
  du bras à l'écran et le souffle ; les seize zones de l'enregistrement
  zoné décroissent linéairement en secteurs par piste, quand un vrai disque
  a des zones de tailles inégales ; le décalage de piste (*skew*) est exact
  par construction, si bien qu'aucun franchissement ne rate jamais son
  créneau — un vrai disque le quantifie en secteurs et le cale sur le pire
  cas, ce qui explique peut-être les 6 % de débit en trop du 7200.11 ; et
  aucun défaut n'est géré : ni secteur réalloué, ni piste de rechange. Le
  LBA remplit tout un cylindre avant de changer de piste, ce qui est juste
  jusqu'au début des années 2000 ; ensuite une même tête écrit un paquet de
  pistes avant de commuter (*serpentine*), et le 7200.10 comme le VelociRaptor
  n'en font rien. Le 7200.14, enfin, est simulé en secteurs de 512 octets
  quand son manuel en donne 4 096 physiques : chaque réécriture d'un
  enregistrement de MFT — deux secteurs — lui coûterait une lecture du bloc
  et un tour.
- **La montée en régime est du premier ordre**, quand un moteur limité en
  courant monte en tangente hyperbolique — la vérité est entre les deux, et
  c'est mineur ; son enveloppe sonore suit v^1,6 quand la loi du souffle
  (`windageBels`) pose v^2,5, et ses bandes glissent en 0,35 + 0,65·v. La voix
  de la tête n'a rien sous 760 Hz : la cible spectrale (88 % entre 1,5 et 8 kHz)
  est sourcée, et le grave passe par les haptiques, qui reçoivent les mêmes
  repères.
- **La passe de XP est la première de sa machine.** `ProcessBootOptimise`
  lit la zone de démarrage au registre, à 0 tant qu'aucune passe ne l'a posée
  (`dfrg.inx`) : le modèle ne rejoue pas les passes `-b` que le préchargeur
  lance à l'inactivité tous les trois jours, et `Layout.ini` y est la trace
  d'un démarrage planifié et de son application, sans les autres scénarios de
  lancement que `pfsvc` y ajouterait. Sous
  les 15 % d'espace libre, la console pose une question en pausant le moteur
  (`WarnFutility`) : le modèle y répond oui sans attendre ; en ligne de
  commande, sans `-f`, l'outil refuserait, et ce n'est pas ce que l'app
  imite. Vista et 7 gardent la rétention de cinq secondes et la validation
  par fichier : le code de XP ne dit rien de leurs pilotes.
- **Le moteur de XP, à quelques nuances près.** L'analyse lit encore chaque
  répertoire sur NTFS, quand `dfrgntfs` semble ne lire que la MFT ; deux
  nuances de `FindRegionToConsolidate` ne sont pas reprises (une région
  commence toujours par un trou, et la coupure sur un fichier trop gros recule
  d'un cluster), et la zone de démarrage y coupe une région comme la zone MFT ;
  `NtfsAcquireAllFiles` à chaque bloc de la MFT et la dernière retentative d'un
  `STATUS_DELETE_PENDING` ne sont pas joués. Côté pilote, la MFT n'est jamais
  trouée (`NtfsCreateMftHole` : sa condition, comptée, n'est remplie sur aucun
  volume de la galerie), sa bitmap ne grandit pas, et `FORMAT` ne pose ni
  `$Secure` ni `$Extend`, que le pilote crée au premier montage.
- **Un document Word grossit comme sous l'enregistrement rapide.** Le modèle
  fait passer chaque enregistrement par `~wrdxxxx.tmp` — l'enregistrement
  complet, celui de Word par défaut depuis Word 97 SR-1 (KB Q192480) — mais
  garde au document le gonflement d'un enregistrement rapide, qui, lui,
  fusionnerait en place. Le lien de Word à ole32 est déduit, pas attesté, et
  le pas de ses écritures n'est dit nulle part.
- **Le refuge de Windows 95 au fond du volume est un choix du modèle**, calé
  sur les durées d'époque, pas lu dans une source ; et l'outil de 9x ne
  **redémarre jamais sa passe** (« the disk's contents have changed.
  Restarting… »), l'un de ses traits les plus mémorables, parce que rien
  n'écrit sur le volume pendant qu'il tourne.
- **Rien ne survit d'une séance à l'autre** sous NT : l'éditeur de liens relit
  ses trois cents `.OBJ` depuis le plateau à chaque compilation d'une journée
  de 2003, sur une machine qui les avait tous en mémoire. Un démarrage, lui,
  ne relit jamais deux fois le même fichier.
- **Les répertoires et les tailles de fichiers de la galerie sont des ordres
  de grandeur d'époque**, comparés au terrain après coup : l'étude de cinq
  ans de Microsoft (FAST'07, Agrawal et al.) donne environ 52 000 fichiers
  et 4 000 répertoires par volume en médiane en 2004, et 42 % de
  remplissage médian, sur des postes Microsoft.
- **Il n'y a pas de FAT12** : la galerie commence en 1993 avec des FAT16, et
  aucune disquette n'est simulée.
- **NTFS sans compression, sans fichiers creux, sans flux additionnels**, et
  sans `$UsnJrnl` ni `$Secure` : les répertoires compressés de 2003, alloués par
  unités de seize clusters, fragmenteraient à coup sûr ; le journal des
  modifications de Vista est réécrit en continu. Un fichier aux extents trop
  nombreux pour un enregistrement de MFT n'y prend pas les enregistrements
  supplémentaires d'un `$ATTRIBUTE_LIST`, et les liens physiques de WinSxS sont
  comptés comme des copies.
- **Pas de NCQ, pas de file dans le disque** : une commande à la fois. Sous XP,
  la file logicielle d'`atapi` sert ce qui attend par LBA croissante depuis sa
  clé courante (C-LOOK) ; le simulateur sert les requêtes dans l'ordre du plan,
  si bien que cette file est jouée par le planificateur, sur ce qu'il sait émis
  ensemble — un lot du préchargeur, les fils du *lazy writer*, la lecture
  anticipée —, et qu'une requête du premier plan arrivée pendant qu'un lot
  attend passe après lui au lieu d'être triée avec lui. Avant XP, et sous Vista
  et 7 faute de code, la file suit l'ordre des demandes ; seul le cache
  d'écriture du disque pose ce qu'il a acquitté dans l'ordre de l'ascenseur.
- **Le cache d'écriture n'est vidé que par ce que XP vide.** Ni les points de
  contrôle de NTFS ni la validation d'un déplacement n'envoient de `FLUSH
  CACHE` : le disque pose quand il est libre ou quand il manque de place. Mais
  le vidage du registre en envoie (les installations de XP), et `fastfat` à
  chaque tranche d'un `FSCTL_MOVE_FILE` sur FAT.
- **Un démarrage décrit en fichiers est moins dense qu'un scénario réglé à
  l'oreille** : 1 231 requêtes pour tout un démarrage de `dev-1996`, contre 90 à
  150 par seconde dans les phases écrites à la main du scénario que la démo a
  remplacé — lequel ne vit plus que dans les tests. Un vrai démarrage consulte le
  registre à chaque périphérique, relit des `.INI` — autant d'accès courts que
  ce modèle ne pose pas, parce qu'aucun d'eux ne correspond à un fichier du
  catalogue. Les répertoires, eux, sont lus : le chemin de chaque fichier
  ouvert, là où ses répertoires sont posés. Le crépitement est donc un peu plus
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
- **Le modèle n'accélère jamais une passe de défragmentation** : ce qui la
  raccourcit, c'est la taille du volume et l'outil. Les 220 Mo de `dev-1993` se
  tassent en 5 min 31 à la frontière et en 24 min 42 sous l'outil de 95 ; un
  volume de l'époque plus grand ou plus plein y passe jusqu'à plus d'une heure,
  et la galerie le montre. Le modèle est le même dans les trois cas.
- **L'écoute, elle, a une allure** : ×0,5, ×1, ×2, ×4 ou ×8, au transport, et
  chaque passe repart à ×1. C'est l'horloge qui lit la passe qui va plus vite,
  pas le disque : les transitoires gardent leur timbre et seules leurs dates se
  resserrent, la rotation — procédurale, réglée par une consigne et non par
  une date — garde sa hauteur, et le rendu hors-ligne n'en sait rien. À
  l'écran, ce qui est réglé pour l'œil reste en temps réel : le plateau ne
  tourne pas plus vite, les rémanences durent autant. **Au-delà de ×2 les
  transitoires se chevauchent** : le regroupement des seeks en trains se fait
  en temps de passe, et deux trains distants de 200 ms tombent à 25 ms l'un de
  l'autre à ×8. C'est un crépitement dense, pas ce que le disque faisait
  entendre ; ×1 reste l'écoute fidèle.
- Le défragmenteur modélisé ne fait pas de passe de vérification, ne relit pas
  ce qu'il vient d'écrire et ne reprend pas une passe interrompue. Sur FAT,
  les outils qui passent par l'API de Windows — JkDefrag, UltraDefrag ; celui
  de XP, qui y lançait un autre moteur (`dfrgfat`), n'y est pas proposé —
  échouent à déplacer un répertoire, comme Windows ; les autres le déplacent
  comme un fichier, sans réécrire l'entrée `..` de ses sous-répertoires, que
  `DEFRAG.EXE` devait bien réécrire.
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
- `WinchesterEngine`, `DiskHaptics`, `SimulationModel` et `DiskLibraryModel` sont
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
./scripts/xcb.sh build      # construit le schéma Winchester (Debug)
./scripts/xcb.sh run        # construit, installe et lance sur le simulateur
./scripts/xcb.sh gen        # (re)génère le .xcodeproj, puis `open Winchester.xcodeproj`
```

`scripts/xcb.sh` est la seule façon de lancer `xcodebuild` sur un simulateur
ici : il épingle la destination à l'appareil unique de `scripts/sim-config.sh`
et le `-derivedDataPath` au dépôt. Voir `CLAUDE.md`.

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

Pour un argument que `xcb.sh` ne connaît pas, `./scripts/xcb.sh -- <args…>`
passe la main à `xcodebuild`, destination toujours épinglée.

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
DRIVE=VelociRaptor SCENARIO=gamer-2007 /tmp/rendertrace vr.wav       # un autre disque
```

`DRIVE` pose le même volume en tête d'un disque nommé de `DriveCatalog.named` :
la partition garde la taille du profil, et seul le disque change.

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

### Mesurer un changement

`Tools/Measure/` range les gestes qui servent à mesurer un chantier — un binaire
par étape, le jeu complet des bilans, les comparaisons — sous
`.build/measure/` :

```sh
./Tools/Measure/snapshot.sh base              # avant de toucher au code
./Tools/Measure/run.sh base full              # 400 bilans, ~7 à 9 min
# … une correction …
./Tools/Measure/snapshot.sh m1 && ./Tools/Measure/run.sh m1 boots   # 3 s
./Tools/Measure/boots.py base m1              # les démarrages et leur cible
./Tools/Measure/boots.py --steps base m1 m2   # l'effet de chaque étape
./Tools/Measure/compare.py base m1 defrag- --identical   # ce qui n'a pas bougé
./Tools/Measure/wav-md5.py m1                 # 58 rendus sonores hachés : ce que les bilans ne voient pas
./Tools/Measure/fit-think.py m1               # quelle constante de ThinkModel
./Tools/Measure/readme-tables.py m1 --check   # le README contre les bilans
./Tools/Measure/readme-tables.py m1 --write   # tables et prose, réécrites
./Tools/Measure/run.sh m1 disks               # les vingt-quatre volumes, un à la fois
./Tools/Measure/extents.py base m1            # morceaux par fichier, répertoires, coût
./Tools/Measure/smart.sh m1 "- windows95 jkDefrag ultraDefrag frontierCompaction smart" \
    "- windowsXP ultraDefrag jkDefrag fragmentMerge smart"   # chaque disque démarré après chaque outil
./Tools/Measure/smart.py base m1              # démarrage rangé, morceaux, trous
./Tools/Measure/passes.py m1:smart         # durée et volume des passes
./Tools/Measure/smart-table.py base m1        # la table du rangement intelligent
```

Le bilan d'un volume (`SCENARIO=disk:<profil>`) donne l'histogramme du nombre
d'extents par fichier, les répertoires, les écritures refusées, le coût de
génération — la meilleure de trois — et une **empreinte** de toutes les
extents : deux binaires qui la partagent ont posé les mêmes clusters aux mêmes
fichiers.

Chaque étape est construite dans son propre dossier, avec son paquet de
ressources : deux worktrees qui mesurent en même temps ne se volent pas le
binaire. `run.sh` signale un bilan tronqué, et `compare.py --identical` sort en
erreur sur un bilan qui diffère, qui manque, ou sur une étape vide.

`readme-tables.py` tient **tous** les chiffres que le README tire d'un bilan :
les tables, reconnues à leur en-tête, et la prose, écrite dans le script comme
elle l'est dans le README, chaque chiffre y étant un champ. `--check` dit
lequel ment. Quelques phrases comparent la galerie à un modèle privé d'un
mécanisme ; elles demandent les bilans d'un binaire jetable, nommé en argument
(`nora=…`, `nopf=…`, `nosd=…`, `cp1=…`, `cp30=…`, `cpend=…`), et sont dites non
vérifiées sans lui. Il se valide d'abord en reproduisant le README du commit
précédent à partir des bilans de ce commit-là ; la table des trois allocateurs
n'en sort pas, et celle du rangement intelligent seulement quand `smart.sh`
(avec `smart` dans les deux listes, entre guillemets) et `passes.py <étape>:smart`
ont tourné sur la même étape (voir son en-tête).

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
    DriveCatalog.swift     douze fiches de disques réellement vendus, 1993 →
                           2012, avec leurs sources ; densités interpolées dans
                           le temps ; le tampon de chacun et sa politique par
                           défaut ; leurs niveaux acoustiques ; les deux
                           VelociRaptor, et la mécanique qu'ils donnent à un
                           10 000 tr/min d'après 2008
    SeekModel.swift        loi de durée, découpage en quatre phases, calage
                           sur les trois durées d'une fiche (piste-à-piste,
                           seek moyen en espérance, pleine course) ; le settle
                           plus long d'une écriture
    SeededGenerator.swift  SplitMix64, tirages stables entre plateformes
    Extent.swift           suite de clusters contigus, huit octets
    ClusterBitmap.swift    occupation des clusters, recherche de place libre
                           accélérée par un index des mots qui ont un trou
    AccessCost.swift       temps de lecture d'une liste d'extents
    FileSystemProfile.swift  contraintes d'un format : cluster, résidence, slack
    FormatOverhead.swift   ce que le format pose devant les clusters, commun
                           au générateur et à la partition simulée
    Allocator.swift        protocole de placement, indices, entrée de fichier
    Allocators/            FAT (scan depuis le début ou next-free) et NTFS ;
                           `NTFSAllocator+XP` et `NTFSFreeRunCache` : le pilote
                           de XP à la lettre (best fit dans le cache des runs
                           libres, surallocation, zone MFT recalculée au
                           montage), pour les volumes formatés par XP
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
    RearrangedDisk.swift   le même disque, ses fichiers posés ailleurs : ce
                           qu'une passe laisse, pour le démarrer ensuite
    ProfileIssues.swift    ce qui ne va pas dans un profil écrit à la main,
                           bloquant ou non (la phrase est dite par l'app)
    CellPartition.swift    le partage des clusters entre les blocs d'une carte
    CellContents.swift     ce que contient un bloc de la carte
    FrenchUnits.swift      nombres et octets en français, pour les bilans et
                           les tables de ce README
    Resources/scenarios/   vingt-quatre scénarios : six époques, quatre profils
Sources/Model/
    Workload.swift         requête bloc, et datation des phases après coup
    AtapiQueue.swift       la file du pilote IDE de XP : C-LOOK par LBA,
                           jouée par le planificateur sur ce qu'il émet ensemble
    LazyWriter.swift       le *lazy writer* du cache de XP : un réveil par
                           seconde, 3 s au premier, un huitième des pages sales
                           dépensé flux par flux
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
                           les métadonnées, ce que lit le montage, et ce que
                           coûte une validation, journal de NTFS compris
    Volume.swift           volume en clusters, allocateur next-fit
    DefragVolume.swift     le volume vu par le défragmenteur : bitmap, fichiers
                           décrits par extents, index des occupants par blocs
    DefragJob.swift        types du plan, et choix de la stratégie sur le format
    DefragStrategy.swift   ce qu'est un défragmenteur : phases, plan, les
                           fabriques d'opérations communes à tous, et la
                           recherche de trou
    Windows95Strategy.swift  tasser le volume contre son début (FAT16, FAT32)
    WindowsXPStrategy.swift  `dfrgntfs` de XP SP1 (NTFS) : ranger le démarrage
                           (`Layout.ini`), recoller la MFT, réparer du plus petit
                           au plus gros dans le plus petit trou qui le tient,
                           vider une région puis la zone MFT, tasser vers
                           l'avant ; blocs de 64 Kio, une transaction chacun ;
                           nommé d'après Vista ou 7 sur leurs disques, avec le
                           seuil de 64 Mo
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
    SmartDefragStrategy.swift  ranger pour le démarrage : ce qu'il lit en
                           tête, dans l'ordre de Layout.ini, la queue du volume
                           remplie, le reste tassé ; tous formats, sur demande
    BootLayout.swift       Layout.ini : ce qu'un démarrage lit, dans l'ordre,
                           confié au défragmenteur qui sait le lire
    DiskSimulator.swift    mécanique du disque, une requête après l'autre :
                           seek, latence, transfert, tampon et vidages
    DriveCache.swift       le disque dans sa machine : bus, coût de commande,
                           contenu du tampon
    SoftwareCache.swift    les caches du système au démarrage : SMARTDRV,
                           VCACHE
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
    MapZones.swift         la carte racontée par zones, pour VoiceOver
    SpindleCharacter.swift ce que le plateau fait entendre au repos : régime,
                           plateaux, palier, pris aux manuels
    SeekCharacter.swift    le niveau de la tête, pris aux manuels (le repos
                           retranché, à moitié en décibels)
    SoundMix.swift         le mixage et l'haptique en une valeur
    PassRecord.swift       le bilan d'une passe entendue jusqu'au bout
    PassDigest.swift       ce qu'il en reste une fois l'app fermée
    PassHistory.swift      ce que les disques gardent d'un lancement à l'autre
    CustomDiskStore.swift  les disques construits dans l'app : leur histoire,
                           pas le volume
    DiskLibraryModel.swift la galerie : générer hors du fil principal, publier
                           l'avancement
    DisplayFormat.swift    nombres, tailles, noms et résumés des disques
                           d'époque, remarques de l'assistant, dans la langue de
                           l'appareil
    Scenario.swift         description des scénarios : disque, chronologie,
                           source des requêtes
    PlaybackClock.swift    allure de l'écoute : horloge du player ↔ temps de passe
    SimulationModel.swift  assemblage + interrogation pour l'UI
    GeneratedVolume.swift  passerelle disque généré → volume et matériel
Sources/Audio/
    Biquad.swift           filtres RBJ, bruit xorshift
    SeekSynth.swift        banc de résonateurs, excitation, trains
    SpindleVoice.swift     couche continue procédurale
    NowPlaying.swift       la passe sur l'écran verrouillé et le centre de
                           contrôle
    WinchesterEngine.swift  graphe AVAudioEngine, transport, programmation des
                           repères tirés de la passe, attente du producteur
Sources/Haptics/
    DiskHaptics.swift      Core Haptics : motifs de seek, texture des trains
Sources/UI/                SwiftUI : plateau, carte des clusters, chronologie,
                           transport, mixage ; `AboutLinks` (les adresses que
                           l'app cite) et `TipSheet` (la feuille des pourboires)
Sources/Tips/TipJar.swift  les pourboires : trois achats consommables, par
                           StoreKit 2
Sources/Screenshots/       mode capture de l'App Store, compilé seulement dans
                           la configuration Screenshots
Tests/DiskCoreTests/       le noyau : allocateurs (dont `NTFSXPAllocationTests`,
                           le pilote de XP), catalogue, calibration (en Release)
Tests/DefragKitTests/      la couche Model : stratégies, démarrages, sessions ;
                           `WindowsXPLetterTests`, `AtapiQueueTests`,
                           `LazyWriterTests`, `FatMoveFileTests` pour XP à la
                           lettre (chantiers 47 à 51)
Tools/RenderTrace/         rendu hors-ligne en WAV
Tools/RenderVideo/         rendu hors-ligne en vidéo : carte, plateau, bilan
Tools/Shared/              scénario demandé, mixage en flux et bilan, communs
                           aux deux outils
Tools/make-videos.sh       le lot de vidéos décrit dans Tools/videos.txt
Tools/Measure/             mesurer un chantier : un binaire par étape, les
                           bilans en parallèle, comparaisons, tables du README
scripts/screenshots.sh     captures de l'App Store, iPhone et iPad
screenshots/               cadrage Koubou, assemblage, et les cartes envoyées
                           (voir screenshots/README.md)
```

## Soutenir

Winchester est gratuit, sans achat intégré. Pour laisser un pourboire :
[ko-fi.com/gabylandais](https://ko-fi.com/gabylandais).

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
