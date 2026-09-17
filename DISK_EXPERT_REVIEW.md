# Revue critique de la simulation de disque dur

Relecture du code par quelqu'un qui a vécu, ouvert et mesuré ces disques.
Périmètre : la **mécanique du disque**, la **géométrie**, le **placement
système de fichiers** et l'**acoustique**. Les stratégies de défragmentation
sont explicitement hors scope ; elles ne sont évoquées que là où elles
partagent la mécanique (`VolumeLayout`, `MachineWriter`).

Les mesures citées ont été obtenues en instrumentant le code tel quel
(`swift test`, cible macOS), pas estimées.

---

## 1. Verdict

Le modèle est **nettement au-dessus de ce qu'on trouve habituellement** dans ce
genre de projet. Trois choix sont justes et rares :

- la géométrie est **zonée et physique**, avec conversion LBA→CHS par
  dichotomie, et le débit en tombe au lieu d'être postulé
  (`DriveGeometry.swift`). C'est la bonne façon de faire, et c'est ce qui donne
  gratuitement l'effet « le début du volume est deux fois plus rapide que la
  fin » ;
- la **latence rotationnelle est angulaire et continue**, calculée contre une
  horloge absolue et non tirée au sort à un demi-tour
  (`DiskSimulator.swift:276`). C'est ce qui fait qu'un fichier éclaté coûte
  vraiment plus cher, et pas seulement statistiquement ;
- l'ordre LBA remplit **tout un cylindre (toutes les têtes) avant de changer de
  cylindre**, ce qui est bien la disposition réelle de ces disques, et la
  distinction commutation de tête / pas de piste est correctement faite.

Le reste de cette revue porte donc sur ce qui reste, et il y a une vraie
**erreur de modèle** — pas un réglage — qui coûte aujourd'hui un facteur 2 à 4
sur tout débit séquentiel.

---

## 2. Défaut majeur : l'oubli du *track skew* — et un tour perdu par arrondi

### Ce que fait le code

Dans `DiskMechanics.serve` (`Sources/Model/DiskSimulator.swift:270-285`), chaque
requête recalcule sa latence rotationnelle en supposant que **le secteur 0 de
toutes les pistes est à l'angle 0** :

```swift
let currentAngle = (t / revolution).truncatingRemainder(dividingBy: 1.0)
let targetAngle  = Double(target.sector) / Double(spt)
var delta = targetAngle - currentAngle
if delta < 0 { delta += 1 }        // ← un tour entier
```

Or **à l'intérieur** d'une requête, le franchissement de piste
(`DiskSimulator.swift:311-325`) fait l'hypothèse inverse : on paie le pas de
piste, puis on reprend au secteur 0 **sans aucune attente rotationnelle**,
c'est-à-dire en supposant un décalage angulaire parfait entre pistes
(*cylinder skew* / *head skew*). Les deux hypothèses coexistent et se
contredisent.

### Conséquence, mesurée

Le décalage accumulé par un pas de piste (0,95 ms sur le disque de 2001, soit
0,114 tour) n'est jamais rendu : à la requête suivante, `delta` devient négatif
et le disque attend **0,886 tour**, soit 7,4 ms de trop. Pire, même **sans**
franchissement de piste, l'arrondi flottant sur la somme des `dt` fait passer
`delta` sous zéro environ une fois sur trois, et fait perdre **un tour complet**
au milieu d'une lecture strictement contiguë :

```
Barracuda ATA IV, requêtes de 32 Ko contiguës dans une même piste
1 req → 0,368 tour de latence cumulée
2 req → 0,368
3 req → 1,368      ← +1 tour, aucune raison physique
6 req → 2,368
8 req → 3,368
```

Sur une lecture contiguë de 4 Mo — exactement ce que fait le démarrage, qui
découpe en requêtes de 64 Ko (`BootSession.swift:448`) :

| disque | découpé en 64 Ko | d'un seul bloc | piste externe (théorique) |
|---|---|---|---|
| Barracuda ATA IV (2001) | **12,2 Mo/s** | 34,3 Mo/s | 48,6 Mo/s |
| Fireball 1080AT (1996) | **3,5 Mo/s** | 6,2 Mo/s | 7,6 Mo/s |

Un Barracuda ATA IV qui lit un fichier **contigu** à 12 Mo/s, c'est quatre fois
moins que la réalité, et c'est en dessous de ce que faisait un disque de 1998.
Ce n'est pas un détail d'équilibrage : c'est la moitié du temps de démarrage.

Et comme les constantes de *think time* ont été calées « pour que le total
tombe sur les durées d'alors » (README), **cet artefact est aujourd'hui absorbé
dans la calibration** : corriger le skew fera tomber les vingt démarrages sous
leur cible, et il faudra recaler `ThinkModel`. Autant le savoir avant.

### Correctif

Introduire explicitement un skew, ce qui supprime les deux symptômes d'un coup :

1. donner à la géométrie un décalage angulaire par piste et par tête —
   `trackSkew = seek(1)/revolution`, `headSkew = headSwitch/revolution`, ce qui
   est exactement la façon dont ces disques étaient formatés ;
2. `angleOf(position)` devient
   `(sector/spt + cylinder*trackSkew + head*headSkew) mod 1`, utilisé **et** dans
   la latence rotationnelle **et** dans le transfert ;
3. tolérance sur l'arrondi : `if delta < -1e-9 { delta += 1 } else { delta = max(delta, 0) }`.

Un test de non-régression évident : *N* requêtes contiguës doivent coûter
exactement la même chose qu'une seule requête de *N* fois la taille, à la
latence initiale près. Il échoue aujourd'hui d'un facteur 3.

---

## 3. Constantes à revoir

### 3.1 La commutation de tête est plus lente que le seek d'une piste

`SeekModel.referenceShape` fixe `headSwitchDuration` à 2,0 ms
(`SeekModel.swift:140`), et cette valeur n'est mise à l'échelle que par le
facteur du **seek moyen** — jamais par la calibration piste-à-piste, qui est
appliquée après (`calibrated(averageSeekMs:trackToTrackMs:)`). Résultat mesuré :

| disque | piste-à-piste | commutation de tête |
|---|---|---|
| Fireball (1996) | 3,00 ms | 1,97 ms |
| Barracuda ATA IV (2001) | **0,95 ms** | **1,48 ms** |
| Barracuda 7200.10 (2006) | **1,00 ms** | **1,40 ms** |

Sur tous les disques à partir de 1999, **changer de tête coûte plus cher que
déplacer le bras d'une piste**. C'est physiquement faux : une commutation de
tête est un basculement électronique du préampli suivi d'une micro-correction
d'asservissement ; elle est toujours plus rapide qu'un déplacement mécanique,
typiquement 0,5 à 1,0 ms sur ces générations, et elle *décroît* comme le
piste-à-piste, pas comme le seek moyen.

Correctif : dériver `headSwitchDuration` du piste-à-piste (par exemple
`0,6 × trackToTrack`, borné vers le bas), dans
`calibrated(averageSeekMs:trackToTrackMs:)` où le piste-à-piste est connu.
Sur le Fireball à 4 têtes, cela change la texture de toute lecture
séquentielle : trois commutations pour un pas de piste, à chaque cylindre.

### 3.2 Le piste-à-piste de 1993 et de 1996 est le même — et il est suspect

`DriveCatalog` donne 3,0 ms pour le Conner CFA170A **et** pour le Quantum
Fireball 1080AT. Deux fiches indépendantes qui tombent sur la même valeur
ronde, c'est le signe d'un chiffre par défaut plutôt que d'une lecture. Le
Fireball était une gamme à bras léger, et Quantum annonçait un piste-à-piste
nettement sous 3 ms sur cette famille — **à revérifier sur la fiche**, parce que
cette constante pilote deux choses très audibles :

- le coût du pas de piste, donc la part de la lecture séquentielle perdue en
  franchissements : **16,3 % du temps** sur le Fireball aujourd'hui, contre 5 à
  8 % attendus sur un disque réel ;
- via `calibrated`, toute la branche courte de la loi de seek, c'est-à-dire le
  **grain du crépitement** — ce qui distingue justement un disque de 1996 d'un
  disque de 2001.

### 3.3 Le débit ignore les *servo wedges* et le format de piste

`sustainedMBs` (`DriveGeometry.swift`, fin) fait
`spt × 512 × rpm / 60` : autrement dit **tout le tour du plateau est de la
donnée**. Sur un disque à asservissement embarqué — tous ceux du catalogue — 5 à
12 % du tour est occupé par les rafales servo, plus les en-têtes, les gaps et
l'ECC entre secteurs. Le débit soutenu réel est donc systématiquement en dessous
du produit ci-dessus.

La vérification croisée du catalogue le montre déjà, mais la tolérance de 20 %
l'absorbe :

| disque | modèle | fiche | écart |
|---|---|---|---|
| 7200.7 (2003) | 60,8 Mo/s | 58 | +5 % |
| 7200.10 (2006) | 79,3 Mo/s | 78 | +2 % |
| 7200.11 (2008) | **119,7 Mo/s** | 105 | **+14 %** |

L'écart est toujours du même côté, ce qui est la signature d'un biais et non
d'un bruit. Un facteur de format unique (`formatEfficiency ≈ 0,90`) appliqué
dans `sustainedMBs` **et** dans le temps de transfert remettrait les trois dans
les 5 %, et la tolérance du test pourrait descendre à 10 % — ce qui en ferait un
vrai garde-fou.

### 3.4 Des requêtes d'un mégaoctet

`InstallEra.writeRequestSectors` monte à 1 024 puis 2 048 secteurs
(`InstallSession.swift:88,93`), soit 512 Ko et 1 Mo par requête. Aucune pile de
l'époque n'émettait cela : ATA sans LBA48 plafonne à 256 secteurs (128 Ko) par
commande, et le pilote de port de Windows XP découpait à 64 Ko dans la quasi-
totalité des cas. Le rendre réaliste (plafond à 128, voire 256 secteurs) est
facile — mais **à ne faire qu'après le correctif du §2**, sinon le nombre de
frontières de requêtes explose et la durée avec.

---

## 4. Ce qui manque au modèle mécanique

Classé par ce que ça change réellement à l'oreille et au chrono.

### 4.1 Le cache du disque et la lecture anticipée — l'absent le plus lourd

Aucune trace de cache dans `DiskMechanics`. Or :

- le Fireball de 1996 avait 128 Ko de tampon segmenté, le Barracuda ATA IV
  2 Mo, le 7200.10 16 Mo ;
- la **lecture anticipée** était active par défaut : après une lecture, le
  disque continue de remplir son tampon jusqu'à la fin de la piste. La requête
  séquentielle suivante est servie **à la vitesse du bus, sans latence
  rotationnelle ni pas de piste**. C'est le mécanisme qui, dans la réalité,
  masque exactement le problème du §2 ;
- la **lecture sans latence** (*zero-latency read*) : sur une requête d'une
  piste entière, le disque commence à lire au secteur qui se présente et
  réordonne dans le tampon. La latence moyenne d'une grosse lecture n'est donc
  pas un demi-tour ;
- le **cache d'écriture** était activé par défaut sur IDE dès la fin des années
  90 : une petite écriture est acquittée immédiatement et vidée plus tard, par
  paquets triés. Ici toute écriture est synchrone, ce qui allonge
  mécaniquement les installations et les journées, et surtout leur donne un
  rythme régulier là où le vrai disque produisait des **salves**.

Un cache même rudimentaire — un segment de piste courante, lecture anticipée
jusqu'à la fin de la piste, invalidation sur seek — change qualitativement le
son d'une lecture séquentielle et rapprocherait le modèle de la réalité bien
plus qu'un réglage de plus.

### 4.2 Aucun coût par commande

Chaque requête ne coûte que de la mécanique. Il manque l'overhead de commande —
décodage ATA, interruption, mise en place DMA — de l'ordre de 0,1 à 0,3 ms sur
ces générations, et bien davantage en PIO sur une machine de 1993, où c'est le
processeur qui transfère mot à mot. Sur un démarrage qui émet des dizaines de
milliers de requêtes de 64 Ko, ce n'est pas négligeable, et c'est le genre de
constante qui devrait vivre dans `DriveReference` plutôt que dans le *think
time* du système.

De même, le **débit du bus** n'est jamais une borne : le 7200.11 lit à
84 Mo/s simulés sans que rien ne vérifie que l'interface suit. Pour les disques
du catalogue ce n'est pas bloquant ; pour un 1993 en PIO mode 2 (8,3 Mo/s
crête, ~2-3 Mo/s utiles derrière un 486), ça le serait.

### 4.3 Le settle d'écriture

`SeekProfile.settle` est le même en lecture et en écriture. Sur un disque réel,
l'écriture exige une position de tête bien plus serrée — on ne détruit pas la
piste voisine — d'où un settle plus long (souvent +0,5 à 1 ms, et les fiches
publient d'ailleurs un « write seek » supérieur au « read seek »). C'est
audible : une passe d'écriture « traîne » davantage qu'une passe de lecture.
`serve()` connaît déjà `request.isWrite`, le branchement est trivial.

### 4.4 La recalibration thermique — un manque d'époque

Les disques d'avant ~1996, et le Conner de 1993 au premier chef, faisaient une
**recalibration thermique** périodique : toutes les quelques minutes, le disque
interrompt tout et va rechercher ses repères de piste, avec une seconde de
crépitement caractéristique. C'était l'événement sonore signature des disques
de cette génération — au point que les constructeurs ont dû sortir des modèles
« AV » sans recal pour le montage vidéo. Le modèle a déjà tout ce qu'il faut
(`IdleBehavior`, une mécanique qui accepte des seeks non demandés) ; il manque
un événement périodique, conditionné à l'année du disque. Ce serait, pour les
deux disques les plus anciens de la galerie, l'ajout le plus payant à l'oreille.

### 4.5 Le parcage au bout d'une seconde

`Scenario.parkDelay = 1.0` (`Scenario.swift:595`) : le bras retourne se parquer
une seconde après la dernière requête. Aucun disque à plateaux de cette période
ne faisait cela — le déchargement des têtes au repos est une pratique de
disques à rampe, des portables des années 2000. Un disque de bureau de 1996
laisse le bras là où il est, et ne parque qu'à la coupure d'alimentation.

C'est assumé dans le README (« c'est elle qui referme une passe au lieu d'un
blanc ») et c'est un bon choix **dramatique**. Mais il devrait être nommé comme
une licence, pas comme de la mécanique, et idéalement rendu optionnel — ou
mieux, remplacé par ce qui produisait réellement ce bruit-là en fin de session :
la coupure du moteur, qui est déjà modélisée juste à côté.

### 4.6 La séquence de mise en route

`spinUpAt` + rampe du premier ordre, puis premier accès depuis le cylindre de
parcage. La réalité est en trois temps, et les trois s'entendent : le moteur qui
démarre, les têtes qui se décollent du plateau (*stiction*, le claquement sec),
puis la **recherche de la piste 0 et le chargement de l'asservissement** — une
courte salve de seeks avant que le disque soit prêt. Le « clac » franc d'ouverture
existe donc bien, mais c'est la recalibration de mise en route, pas la première
lecture ; et à la fin de cette séquence le bras est **au bord**, pas au moyeu,
ce qui change la distance du premier accès réel.

---

## 5. Système de fichiers et métadonnées

Le placement est la meilleure partie du projet. La FAT *next-fit* de VFAT, le
motif « temporaire écrit avant libération de l'original » de Word
(`Simulator.replaceViaTemporary`), la zone MFT à 12,5 % qui ne cède que par
moitiés : c'est exact, et c'est ce qui produit les bonnes textures. Deux
réserves, plus une vraie question.

**L'entrée de répertoire est toujours écrite dans la racine.**
`commitAccesses` (`VolumeLayout.swift`) écrit en FAT16 à
`rootLBA + cluster % rootSectorCount` — un secteur essentiellement arbitraire de
la racine — et en FAT32, où `rootSectorCount` vaut 0, à `rootLBA + 0`,
c'est-à-dire au premier cluster de données. Dans la réalité l'entrée d'un
fichier est dans **son** répertoire, qui est un fichier ordinaire vivant là où
l'allocateur l'a posé. Conséquence sonore : le modèle fait revenir le bras au
tout début à chaque validation, y compris sur FAT32 où ce n'était vrai que pour
les deux copies de la table. Le catalogue connaît déjà le répertoire de chaque
fichier (`FileRecord.directory`) ; il manque de lui allouer des clusters comme à
un fichier.

**`$LogFile` n'existe qu'à l'installation.** `MachineWriter` écrit bien le
journal à chaque vidage (`journaled`), mais le commentaire de `VolumeFormat` dit
que « sur NTFS le bras n'a aucune raison de revenir au bord ». C'est faux pour
tout ce qui **écrit** : NTFS journalise en écriture anticipée, et `$LogFile` est
un fichier de quelques mégaoctets à position fixe. La signature sonore d'une
écriture NTFS, c'est précisément cet aller-retour régulier vers le journal.
En lecture, en revanche, le commentaire est juste.

**La position de `$MFT` mérite vérification.** Le modèle la pose au tout début
de la zone de données. Les outils de formatage de l'époque ne la plaçaient pas
toujours là — selon la version de Windows et la taille du volume, `$MFT`
démarrait bien plus loin dans le volume, et `$MFTMirr` a changé de place entre
NT 4 et les versions suivantes. Comme tout le son d'un démarrage NTFS vient de
l'aller-retour « enregistrement MFT → données », cette position mérite d'être
tranchée sur une source plutôt que supposée.

**Un point qui est juste et qu'il faut garder :** lire un fichier fragmenté sur
FAT ne coûte **pas** d'accès supplémentaire à la table, parce que la FAT entière
était en mémoire. Beaucoup de simulations se trompent là-dessus ; celle-ci a
raison, et le commentaire de `openAccesses` le dit correctement.

---

## 6. Acoustique

**Ce qui est juste.** Les fréquences de modes fixes, indépendantes de la vitesse
de seek, avec seule l'excitation qui varie : c'est la bonne lecture de la
littérature, et c'est ce qui sépare une simulation d'un échantillon transposé.
La règle de fusion des trains héritée de MAME est également la bonne, et la
décomposition speedup / coast / slowdown / settle donne un « clac » dont la
*forme* change avec la distance.

**Le ronronnement ne dépend pas assez du régime.** `SpindleVoice` a trois
résonances fixes (185, 520, 1 450 Hz) que la vitesse ne fait glisser que pendant
la rampe (`scale = 0,35 + 0,65·speed`) : à plein régime, un 3 600 tr/min et un
7 200 tr/min ont **exactement le même timbre**, et ne diffèrent que par une
composante tonale volontairement discrète à `rpm/60`. Or c'est justement là que
l'oreille reconnaît une époque : le bruit d'écoulement d'air croît très
fortement avec la vitesse périphérique et déplace son spectre vers l'aigu, et
les raies dominantes d'un moteur sont liées à sa commutation, donc au régime.
Faire dépendre les fréquences de bande et la pondération grave/aigu du rapport
`rpm / 7200` — même grossièrement — rendrait la galerie beaucoup plus lisible à
l'oreille qu'elle ne l'est. Le README identifie déjà cette voix comme le maillon
faible ; c'est le paramètre le plus rentable avant même de chercher un
échantillon.

**Le filtre à 18 ms écrase le rythme des pistes.**
`AudioCueBuilder.minimumTickSpacing = 0.018` alors qu'une lecture séquentielle
sur le disque de 2001 franchit une piste **tous les 8,33 ms** (un cylindre = un
tour, une seule tête). La cadence réelle est donc de 120 Hz : ce n'est plus une
suite de tics, c'est une **hauteur** — le sifflement rythmique très
reconnaissable d'une grosse lecture. Le filtre en supprime une sur deux et le
transforme en cliquetis à 55 Hz, ce qui est une autre sensation. Sur le Fireball
à 4 têtes, c'est la commutation de tête qui arrive toutes les 11,1 ms et le pas
de piste toutes les 44 ms — deux périodicités emboîtées, et c'est *ça* le son
d'une lecture séquentielle sur un disque à plusieurs plateaux.

La motivation du filtre (éviter la mitraillette) est légitime, mais la bonne
réponse n'est pas de décimer : c'est de **rendre le train dense en continu**,
exactement comme c'est déjà fait pour les seeks rapprochés — un rendu unique
passé une fois dans le banc de résonateurs, modulé par la densité. Le mécanisme
existe déjà dans `renderChatter` ; il n'est simplement pas appliqué aux
micro-transitoires.

**Deux bruits manquent**, tous deux faciles et très typés : l'atterrissage des
têtes sur le plateau à la coupure (CSS — le petit *crac* qui termine un
arrêt), et le décollement au démarrage.

---

## 7. Priorités

1. **Corriger le skew et l'arrondi de latence rotationnelle** (§2). C'est un
   bug, il coûte un facteur 2 à 4 sur tout séquentiel, et il fausse la
   calibration des durées de démarrage. Prévoir de recaler `ThinkModel` après.
2. **Dériver la commutation de tête du piste-à-piste** (§3.1). Une ligne, et
   elle supprime une inversion physique sur six disques du catalogue sur huit.
3. **Un cache de piste avec lecture anticipée** (§4.1). C'est le plus gros écart
   conceptuel restant entre ce modèle et un disque réel.
4. **Le régime dans le timbre du plateau** (§6). Le meilleur rapport
   effort/effet sur toute la galerie.
5. Facteur de format sur le débit (§3.3), settle d'écriture (§4.3),
   recalibration thermique pour 1993-1996 (§4.4), entrée de répertoire hors
   racine (§5).
6. Vérifier sur fiche le piste-à-piste du Fireball (§3.2) et la position de
   `$MFT` (§5) — deux constantes aujourd'hui prises par défaut, dans un projet
   dont c'est justement la règle de ne pas le faire.
