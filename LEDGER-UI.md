# Journal de l'interface

Les chantiers qui font passer DiskNoise d'un banc d'essai à une application
qu'on prend en main en trente secondes. `LEDGER.md` garde la trace du modèle
physique ; ce fichier-ci garde celle de l'interface : ce qui était prévu, ce
qui a été fait, et pourquoi on s'en est écarté.

Point de départ : le prompt donné à Claude Design, recopié dans
[`Design/prompt-claude-design.md`](Design/prompt-claude-design.md), et les
maquettes qu'il a produites —
<https://claude.ai/design/p/e24dba35-01ce-43f9-ad1d-fb8fae1f916e>.

Tant qu'un chantier est **À faire**, sa fiche dit ce qu'on vise et ce que le
code offre déjà. Une fois mené, elle prend la forme des entrées de `LEDGER.md` :
le problème, les décisions, ce qui valide, ce qui reste ouvert.

---

## Les maquettes, validées

**Fait** · 16 septembre 2026 · copie dans [`Design/maquettes.dc.html`](Design/maquettes.dc.html)

Vingt-cinq écrans, en quatre flux. Chacun renvoie au chantier qui le porte.

| écran | flux | chantier |
|---|---|---|
| 01 · Onboarding 1/3, 2/3, 3/3 | première ouverture | U11 |
| 02 · Scénarios démo | première ouverture | U1 |
| 03 · Galerie de 20 disques | première ouverture | U1 |
| 04 · Génération du volume | première ouverture | U2 |
| 05 · Fiche du disque généré | première ouverture | U2 |
| 06 · Assistant 1/6 à 4/6, 6/6 | disque usagé | U9 |
| 07 · Assistant 5/6 — habitudes | disque usagé | U9 |
| 08 · Méthode de défragmentation | passe | U3 |
| 09 · Passe, onglet Carte | passe | U4 |
| 10 · Passe, onglet Plateau | passe | U4 |
| 11 · Instruments | passe | U6 |
| 12 · Carte plein écran, paysage | passe | U5 |
| 13 · Bilan de fin de passe | bilans | U8 |
| 13 · Comparer deux outils | bilans | U8 |
| 14 · Démarrage et témoin | bilans | U7 |
| 14 · « Pourquoi ça sonne comme ça ? » | bilans | U11 |
| 15 · Son et vibrations | réglages | U10 |
| 16 · Mode ambiance | réglages | U10 |
| 17 · Mes disques et états limites | réglages | U9, U12 |

La navigation retenue est une **barre d'onglets** — Disques, Passe,
Instruments, Réglages — et non une pile : c'est elle qui tient lieu de
mini-lecteur persistant (U0).

### Deux tours de corrections

La première version était juste dans sa structure et fausse dans ses chiffres
et ses explications. Relue contre le README et le code, puis corrigée en deux
messages.

**Premier tour** — ce qui contredisait le modèle :

- le « clac de parking » confondait le parking du bras **au moyeu** et le
  retour **au bord** pour réécrire la FAT ;
- la galerie affichait un taux de fragmentation **avant** génération, et des
  noms de disques du commerce que le modèle ne connaît pas ;
- la géométrie d'un 1,08 Go de 1996 était inventée (4 092 cylindres,
  9,4 Mo/s au lieu de 3 835 et 7,6) ;
- l'assistant prédisait qu'un disque serait « très éclaté » ;
- des durées chiffrées par outil, qu'aucun calcul ne donne ;
- les chiffres du préchargeur de Vista sur 320 Go posés sur un démarrage de
  Windows 98, avec une explication fausse du témoin ;
- des états limites impossibles : « reprendre » une passe, une génération qui
  échoue parce que le disque est plein.

**Second tour** — ce qui restait :

- une marque encore présente sur trois écrans ;
- Windows 95 sur 850 Mo en 3 h 18 et 515 % du volume déplacé, ramenés à 52 min,
  4 020 évacuations et 130 % ;
- UltraDefrag « une heure ou plus » sur un FAT de 1996, où il est **court** ;
- 1 906 fichiers lus au démarrage de Windows 98, ramenés à 620 ;
- quatre fiches « Pourquoi » fausses ou approximatives (loi de seek, next-fit,
  zone MFT, témoin).

### Laissé ouvert

Les chiffres du disque d'exemple — `secretaire-1996`, 850 Mo — sont des
**estimations** interpolées entre `dev-1996` et `gamer-1996`, pas une mesure.
Les caler par `PLAN_ONLY=1 SCENARIO=secretaire-1996` avant de s'en servir
comme référence d'écran.

---

## Ce qui ne se négocie pas

Ces règles viennent du moteur, pas du goût. Une maquette qui les enfreint se
corrige ; elle ne fait pas changer le moteur.

- **Pas de chronologie navigable.** La passe se calcule pendant qu'on l'écoute
  (`PassSession`, `LivePass`) : pas de barre de lecture, pas de saut, pas de
  durée totale ni de temps restant. Lecture, pause, relancer. Le temps écoulé et
  le pourcentage déplacé existent ; le reste n'existe qu'à la fin (`PassEnd`).
- **La fragmentation n'est pas un réglage.** Elle résulte d'une histoire rejouée
  par un allocateur. Aucun curseur « fragmentation ».
- **Une passe dure de 8 s à plus de 7 h.** L'interface doit tenir en fond et
  dire où l'on en est au retour.
- **La carte suit l'horloge audio.** Un bloc change de couleur quand son
  écriture s'entend ; un écran recouvert cesse de suivre et se remet à l'heure
  (chantier 8). Tout nouvel écran de carte respecte ce contrat.
- **Palette unique.** Les couleurs de la carte vivent dans `ClusterPalette` ;
  l'interface les traduit (`Theme.categoryColor`), jamais ne les recopie.
- **Français, chiffres à la française** : « 3 min 24 », « 6,4 Go ».

## L'existant, au départ du journal

Commit `fbbcfd3` sur `develop`.

- `ContentView` : un sélecteur segmenté entre deux espaces, **Simulation** et
  **Disques d'époque**.
- `SimulatorScreen` : un long défilement — en-tête et LED, sélecteur de
  scénario, panneau de défragmentation (carte, progression, bilan) ou de
  démarrage (tuiles, témoin), plateau, bandeau de phase, frise d'activité des
  60 dernières secondes, transport (relancer, lecture/pause), quatre tuiles de
  stats (IOPS, Mo/s, seek moyen, seeks), mixeur et haptique, notes du modèle.
- `DiskLibraryView` : puces par année, progression de génération annulable,
  carte, deux boutons **Démarrer cet OS** / **Défragmenter ce disque**,
  tuiles de métriques d'allocation.
- `ClusterMapFullScreen` : la carte en plein écran, grille dérivée de la
  surface.
- **Le défragmenteur n'est pas choisissable dans l'app** : le format décide
  (Windows 95 sur FAT, XP sur NTFS). UltraDefrag et les modes de JkDefrag ne
  s'atteignent que par `STRATEGY=` dans `RenderTrace`.

---

## Chantier U0 — la charpente

**Fait** · branche `interface-grand-public`

### Le problème

L'application tenait en deux espaces derrière un sélecteur segmenté. La passe
était un seul long défilement où s'empilaient carte, plateau, transport, stats,
mixeur et notes. On y choisissait le scénario par un second sélecteur
segmenté, qui ne pouvait montrer qu'un disque de la galerie à la fois. Rien
ne rappelait qu'une passe jouait quand on retournait à la galerie.

### Les décisions

- **Quatre onglets, comme les maquettes** : Disques, Passe, Instruments,
  Réglages (`AppTab`). `SimulationModel` et `DiskLibraryModel` restent créés
  une fois dans `ContentView` : une passe survit au changement d'onglet, et il
  n'y en a qu'une, puisqu'il n'y a qu'un moteur audio.
- **Disques** (`DisksScreen`) : les deux scénarios livrés en tête, avec
  **Lancer**, puis la galerie telle qu'elle était. Le sélecteur de scénario
  de la passe disparaît : on choisit quoi écouter à un seul endroit.
- **Choisir, c'est lancer.** Lancer une démo, **Démarrer cet OS** et
  **Défragmenter ce disque** démarrent la lecture et ouvrent l'onglet Passe.
  Relancer une démo déjà entendue jusqu'au bout la reprend du début.
- **Passe** garde carte, plateau, phase, frise et transport. Les quatre tuiles
  vont dans **Instruments** (`InstrumentsScreen`), le mixage, l'haptique et les
  notes du modèle dans **Réglages** (`SettingsScreen`).
- **Un bandeau de passe** (`passMiniPlayer`) au-dessus de la barre d'onglets,
  hors de l'onglet Passe : titre, phase, temps écouté, lecture/pause, et un
  appui ouvre la passe. Il ne suit pas l'horloge du moteur mais un
  `TimelineView` à deux images par seconde : l'écran qu'il recouvre n'a pas à
  se redessiner soixante fois par seconde pour un chronomètre au dixième.
- **Un onglet caché ne suit pas l'horloge.** Passe et Instruments passent par
  leur `ClockRelay`, coupé quand leur onglet n'est pas affiché. C'est le
  contrat du chantier 8 étendu aux onglets : un écran que personne ne voit ne
  se redessine pas.
- **Réglages n'observe pas le moteur du tout** : rien n'y dépend de l'instant
  écouté. Il se redessine quand on touche un réglage, par un compteur local
  que l'écriture incrémente.
- **Les jetons de thème existaient déjà** : `Theme` porte exactement les
  couleurs des maquettes (fond, panneau, texte, secondaire, ambre, turquoise).
  Seul `ScreenTitle`, le titre d'onglet, est ajouté.

### Ce qui valide

- Construit en Debug pour le simulateur iPhone 17 Pro Max, sans erreur.
  Aucun fichier de `Sources/Model` n'est touché : `swift test` et le rendu
  hors-ligne ne sont pas concernés.
- Sur le simulateur : **Lancer** la démo de défragmentation ouvre la passe en
  lecture ; revenir sur Disques, Instruments ou Réglages montre le bandeau, dont
  le temps et la phase avancent ; les tuiles d'Instruments suivent la passe.
- **CPU de l'app pendant la démo de défragmentation**, sur 20 s, par onglet
  affiché. Un seul essai par onglet, à des moments différents de la passe : ces
  chiffres disent un ordre de grandeur, pas un écart.

  | onglet affiché | CPU |
  |---|---:|
  | Passe | 28 à 43 % |
  | Instruments | 27 à 31 % |
  | Réglages | 29 % |
  | Disques | 24 à 27 % |

  Aucun onglet caché n'ajoute le coût de la passe à celui de l'écran visible.

### Laissé ouvert

- **Pas de mesure avant/après.** Le CPU de `develop` sur les mêmes instants
  n'a pas été relevé ; le bénéfice de la coupure des onglets cachés est
  raisonné, pas mesuré. Pour le mesurer : un `worktree --detach` de `develop`,
  même démo, même instant.
- **Rien n'a été écouté** sur l'appareil ; le haptique ne se vérifie pas sur le
  simulateur (« indisponible »).
- **L'écran Passe est encore le long défilement d'avant**, sans onglets Carte
  et Plateau ni bouton Arrêter : c'est U4.
- La galerie génère toujours son premier disque à l'ouverture
  (`selectFirstIfNeeded`), désormais sur l'onglet d'accueil, donc dès le
  lancement de l'app. À revoir avec U1 et U2.
- `SimulationModel.selections` et `title(of:)` ne servent plus à aucun écran.

---

## Chantier U1 — la galerie des disques prédéfinis

**Fait** · branche `interface-grand-public`

### Le problème

La galerie était une grille de puces « Développeur », « Joueur »… rangées par
année, sans rien d'autre que le profil : ni capacité, ni système, ni résumé
avant d'avoir généré le disque. Le premier disque se générait tout seul à
l'ouverture, et depuis U0 dès le lancement de l'app. Carte, métriques et
boutons s'empilaient sous les puces, sur le même écran.

### Les décisions

- **Une carte par disque** (`DiskGallery`) : nom, système de fichiers, ligne
  matérielle « IDE 850 Mo · 5 400 tr/min · Windows 95 », résumé. Rien qui ne
  soit connu **avant** génération.
- **« Déjà généré · 12 % fragmentés »** n'apparaît que pour un disque fabriqué
  dans la session. `DiskLibraryModel.fragmentedRatios` le retient par profil,
  avec le même taux que la tuile de la fiche (parmi les fichiers
  fragmentables).
- **Deux rangées de filtres**, par année et par profil, combinables ; un
  second appui sur un filtre actif le retire.
- **Le profil se lit du préfixe de l'identifiant** (`Persona`) et garde les noms
  des `displayName` — Secrétariat, Développeur, Famille, Joueur, Bidouilleur —
  plutôt que ceux des maquettes, pour que filtre et titre de carte disent le
  même mot. Rien n'est ajouté à `ProfileSpec` ni aux JSON.
- **Le nom du système** vient de `BootScript.Era`, celui que dit déjà le
  démarrage : une seule table, pas deux orthographes.
- **La capacité est commerciale** : gigaoctets de mille mégaoctets, jusqu'à deux
  décimales (« 1,08 Go », « 6,4 Go », « 40 Go »), comme sur les maquettes.
- **Ouvrir une carte ouvre la fiche** (`DiskDetailScreen`, dans une pile de
  navigation) et c'est là, et seulement là, que la génération part
  (`DiskLibraryModel.open`). `selectFirstIfNeeded` disparaît.
- **La fiche garde la vue d'avant** (`DiskLibraryView`) sans ses puces. Ses
  deux états d'échec sont ceux des maquettes : « Génération annulée » avec
  **Générer depuis le début**, « Génération impossible » avec **Réessayer**.

### Ce qui valide

- Construit en Debug pour le simulateur iPhone 17 Pro, sans erreur. Rien dans
  `Sources/Model` n'est touché hors `DiskLibraryModel.swift`, que ni
  `swift test` ni le rendu hors-ligne ne compilent.
- Sur le simulateur :
  - la galerie liste les vingt disques avec leur ligne matérielle, relue dans
    l'arbre d'accessibilité (« IDE 1,08 Go », « IDE 6,4 Go ») ;
  - le filtre 1996 ne laisse que les quatre disques de 1996 ;
  - ouvrir « Développeur, 1996 » génère le volume et montre carte, boutons et
    métriques (11,5 % fragmentés) ; au retour, la carte porte « déjà généré ·
    12 % fragmentés » ;
  - **au lancement, rien ne se génère** : 0,06 s de CPU en 10 s, contre une
    génération complète auparavant.

### Laissé ouvert

- **Deux typographies de capacité.** La carte dit « 1,08 Go » (commercial),
  l'en-tête de la passe dit ce que calcule `GeneratedVolume` en gigaoctets de
  1 024 Mo (« 1,1 Go », et « 39,1 Go » pour un 40 Go). À unifier, sans doute
  du côté de la passe.
- **Le titre du disque apparaît deux fois** sur la fiche, dans la barre de
  navigation et en tête de la carte : c'est la mise en page de U2.
- Quitter la fiche pendant une génération ne l'annule pas ; ouvrir un autre
  disque, si.
- Pas de frise illustrée des époques ni de filtre du profil « Power user » sous
  ce nom : le mot des scénarios a été préféré.

---

## Chantier U2 — la génération et la fiche du disque

**Fait** · branche `interface-grand-public`

### Le problème

La fiche reprenait l'ancienne galerie : un panneau de carte titré en petit,
deux boutons côte à côte, puis neuf tuiles et un en-tête technique
(« VFAT · clusters de 32 Ko · 1080 Mo · 580 jours simulés »). Depuis U1, le nom
du disque s'y lisait deux fois, dans la barre et sur la carte. La fabrication
disait « jour 62 », un compteur que personne ne sait lire.

### Les décisions

- **En-tête de page** (maquette 05) : le nom en grand, une ligne matérielle
  « 1996 · 850 Mo · 5 400 tr/min · VFAT 16 Ko · Windows 95 », le résumé. La
  barre de navigation ne répète plus le titre ; le retour dit « Disques ».
- **La taille de cluster vient du volume fabriqué**, et du profil tant qu'il
  ne l'est pas : un profil peut la laisser au format, qui la choisit d'après
  la capacité.
- **Six métriques sur trois colonnes** : fichiers, fragmentés (en ambre),
  morceaux par fichier, trous, slack, rempli. Le reste — pire fichier,
  95ᵉ centile, plus grand trou, jours simulés, résidents et MFT — passe dans
  **Plus de détails**, fermé par défaut.
- **L'explication dans sa carte ⓘ**, entre les chiffres et les boutons.
- **Défragmenter d'abord**, pleine largeur et en ambre ; **Démarrer cet OS**
  dessous, en contour. C'est l'ordre des maquettes, et l'action que l'app
  sait le mieux raconter.
- **Fabrication** (maquette 04) : « Fabrication du volume », le **jour simulé en
  date** (« 14 mars 1997 », tiré de `timeline.start` et du jour courant), la
  barre, fichiers et remplissage, **Annuler** pleine largeur.
- **Les nombres à la française partout** (`FrenchFormat`) : espace fine entre
  les milliers, virgule, une décimale sous 10 %, « < 0,1 % » plutôt que
  « 0,0 % ». La légende de la carte passe aux Mo au-delà d'un mégaoctet par
  bloc, et dit « plus sombre : rangé d'un seul tenant ».
- **L'explication NTFS ne ment plus.** Elle disait « des fichiers bien plus
  contigus — 14,34 morceaux par fichier en moyenne » sur `famille-2007`, ce qui
  se contredit. La moyenne se prend sur tous les fichiers, et quelques gros
  fichiers hachés la tirent : 2,2 % des fichiers en morceaux, dont le pire en
  compte 10 941. Le texte le dit maintenant, et dit « aucun fichier en
  morceaux » quand c'est le cas (`gamer-2003`). Le slack cité par
  l'explication FAT16 reprend l'arrondi de la tuile.

### Ce qui valide

- Construit en Debug pour le simulateur iPhone 17 Pro, sans erreur. Rien dans
  `Sources/Model` n'est touché.
- Sur le simulateur, relu à l'écran et dans l'arbre d'accessibilité :
  - `famille-2007` en fabrication : « 1er avril 2007 », 0 fichier, Annuler ;
  - la fiche prête : en-tête, carte, « 1 bloc = 65 641 clusters = 256 Mo »,
    six tuiles (12 222 fichiers, 2,2 %, 14,34, 6 382 trous, 0,0 %, 93 %) —
    le « 0,0 % » a fait écrire « < 0,1 % », pas recapturé depuis —,
    explication, deux boutons, détails ;
  - `secretaire-1993` : slack de 5,3 % sur la tuile et dans la phrase ;
  - `gamer-2003` : « aucun fichier de ce volume n'est en morceaux ».

### Laissé ouvert

- **La carte ne se remplit pas pendant la fabrication**, contrairement à la
  maquette 04 : le générateur ne publie que des compteurs. Montrer une carte
  qui se remplit par un décor serait mentir ; il faut que `GenerationProgress`
  porte un instantané agrégé du volume, à mesurer (l'agrégation d'un 320 Go
  n'est pas gratuite).
- **La fabrication est une carte dans la fiche**, pas une feuille qui monte
  sur la galerie comme sur la maquette : on arrive sur la fiche, et elle se
  remplit. Plus simple, et Annuler laisse sur la bonne page.
- **« Morceaux/f. » reste une moyenne** sur tous les fichiers, que
  l'explication doit corriger sur NTFS. Une médiane parmi les fichiers
  fragmentés serait plus honnête dans la tuile, mais n'est pas calculée par
  `AllocationMetrics`.
- Les deux typographies de capacité relevées en U1 sont toujours là.

---

## Chantier U3 — choisir le défragmenteur

**Fait** · branche `interface-grand-public`

### Le problème

L'app ne jouait que l'outil que le format imposait : Windows 95 sur FAT, XP sur
NTFS. UltraDefrag et les huit modes de JkDefrag — tout le travail de
comparaison des chantiers 2, 9 et 11 — ne s'entendaient que par
`STRATEGY=` dans `RenderTrace`.

### Les décisions

- **« Défragmenter ce disque » ouvre « Avec quel outil ? »** (maquette 08,
  `DefragToolChoiceScreen`), poussé depuis la fiche. **Démarrer cet OS** ne
  demande rien.
- **Une carte par outil** : nom, année, principe en une phrase, ce qu'on
  entend. L'outil de l'époque du format est **présélectionné** et marqué
  « D'époque ». UltraDefrag et le mode par défaut de JkDefrag suivent ; les
  deux tassements et les cinq tris vont dans **Options avancées**.
- **Windows 95 et Windows XP sont grisés hors de leur format**, avec la raison
  (« Réservé à NTFS · ce volume est en VFAT »). Le moteur les passerait
  pourtant : c'est l'écran qui refuse le contresens, pas le planificateur.
- **Aucune durée estimée.** Rien ne calcule la durée d'une passe avant de
  l'entendre. Chaque carte donne, par format, la **fourchette mesurée** sur les
  disques de la galerie, relevée dans le README et `LEDGER.md` (« Mesuré sur la
  galerie : de 30 min à 5 h »), et rien là où l'outil n'a pas été mesuré.
  UltraDefrag sur FAT n'a qu'une mesure (`dev-1996`, 79 s) : la carte le dit.
- **La stratégie descend jusqu'au modèle** : `SimulationModel.load(generated:as:using:)`
  la passe à `ScenarioBuilder.build(generated:using:)`, qui l'acceptait déjà.
  `nil` garde le choix du format. Le pont des écrans devient `DiskHandover`,
  qui porte la stratégie.
- **Après le lancement**, l'écran de choix se referme : revenu sur l'onglet
  Disques, on retrouve la fiche.

### Ce qui valide

- Construit en Debug pour le simulateur iPhone 17 Pro, sans erreur. `Sources/Model`
  n'est touché que dans `SimulationModel.swift`, hors tests et hors rendu
  hors-ligne.
- Sur le simulateur, `secretaire-1996` (VFAT) : Windows 95/98 présélectionné et
  « D'époque », Windows XP grisé avec sa raison, fourchettes affichées ;
  JkDefrag choisi puis **Lancer la passe** : l'onglet Passe annonce
  « JkDefrag 3.36 » et montre la carte de ce volume.

### Laissé ouvert

- **Les fourchettes sont figées dans le code**, recopiées des tableaux de
  mesure. Si un chantier du modèle change une durée, elles ne suivront pas.
  Certaines datent d'avant les chantiers 9 à 12.
- **« Comparer deux outils »** n'est pas là : c'est U8, qui demande de garder le
  bilan d'une passe.
- **Pas de choix d'outil pour les démos** : la défragmentation livrée reste
  celle de Windows 95.
- **Les maquettes avaient faux sur le disque d'exemple.** `secretaire-1996`,
  une fois généré, compte 3 128 fichiers, 9 % fragmentés et 642 trous, là où
  les maquettes en supposaient 7 412, 41 % et 38. La réserve notée à leur
  validation se confirme : ne pas s'en servir comme référence de chiffres.

---

## Chantier U4 — l'écran de la passe

**À faire** · prompt §4

### Visé

- **Carte des clusters** : lecture ambre, écriture turquoise, rémanence ;
  légende « plus sombre = rangé » ; « 1 bloc = N clusters = X Ko ».
- **Plateau** : rotation ralentie ×100, bras sur le cylindre visé, traînée,
  cylindre courant, LED HDD.
- **Phase en cours** et frise des phases passées, sans projection des phases
  à venir.
- **Compteurs** : % avancé, Mo déplacés, fichiers déplacés, évacuations, temps
  écoulé.
- **Transport** : lecture/pause, relancer, arrêter.
- Hiérarchie en portrait : carte et plateau ne tiennent pas ensemble avec les
  compteurs — onglets ou piles repliables, à décider sur les maquettes.

### Ce que le code offre

`ClusterMapView`, `PlatterView`, `ActivityTimeline`, `PhaseDescriptor`,
`model.restart()`, `engine.toggle()`. **Arrêter** n'existe pas en tant que
tel : relancer puis pause, ou un vrai arrêt qui libère la passe.

### À ajouter côté moteur

Fichiers déplacés et évacuations **en cours de passe** : `ActivityTotals` ne
compte que requêtes, seeks, distance et octets déplacés ; les autres
compteurs n'arrivent qu'avec le plan final.

---

## Chantier U5 — la carte en plein écran, touchée

**À faire** · prompt §4

### Visé

Paysage, grille pleine surface (≈ 16 800 blocs sur un 17 Pro Max). Un appui
sur un bloc dit sa catégorie, sa plage de clusters, et le ou les fichiers
qu'il contient.

### À ajouter côté moteur

La carte est une suite de plages sans nom de fichier (chantier 4). Retrouver
un fichier depuis un cluster demande un index extent → fichier sur le volume
courant — qui bouge pendant la passe.

---

## Chantier U6 — les instruments

**À faire** · prompt §5

### Visé

- **En direct** (sparklines 60 s) : IOPS lecture/écriture, débit comparé au
  maximum théorique au bord et au moyeu, seek moyen en cylindres et en ms,
  nombre de seeks, répartition du temps (seek / rotation / transfert / calcul /
  attente), histogramme des distances, chaleur des cylindres.
- **Cumulés** : requêtes, Mo lus, Mo écrits, Mo déplacés et ratio au volume,
  fichiers déplacés, évacuations.
- **Volume avant → maintenant → après** : fichiers fragmentés en nombre et en
  taux (dont parmi les fragmentables), morceaux (total, moyenne, p95, pire),
  trous et plus grand trou, remplissage, slack, résidents MFT. Taux et
  morceaux côte à côte, avec la courbe qui montre que l'un peut stagner quand
  l'autre s'effondre.
- **Démarrage** : fichiers lus, Mo lus, calcul, attente disque, écart au
  témoin, seeks avec et sans préchargeur.
- **Comparaison** de deux passes en colonnes, sans verdict global.

### Ce que le code offre

| indicateur | où | quand |
|---|---|---|
| IOPS, Mo/s | `SimulatorScreen.stats` | direct |
| seeks, seek moyen (cyl.), requêtes, octets déplacés | `ActivityTotals` | direct |
| débit théorique d'un cylindre | `DriveGeometry.sustainedMBs(cylinder:)` | statique |
| fichiers, fragmentés, extents moyen/p95/max, trous, plus grand trou, slack, remplissage, résidents | `AllocationMetrics` | avant, après |
| fichiers déplacés, évacuations, bilan | `DefragPlan` via `PassEnd.plan` | fin |
| calcul, attente disque, témoin | `BootSession` | direct / fin |

### À ajouter côté moteur

- Séparation lecture / écriture des requêtes et des octets.
- Répartition du temps par composante : `DiskMechanics` la connaît requête par
  requête, rien ne la cumule.
- Histogramme des distances de seek et visites par cylindre.
- Seek moyen en ms, pas seulement en cylindres.
- Métriques d'allocation **pendant** la passe : recalculer `AllocationMetrics`
  à chaque validation est trop cher sur 2,7 millions de clusters ; il faudra
  les tenir incrémentalement, aux mutations.
- Garder le bilan d'une passe pour la comparaison.

---

## Chantier U7 — le démarrage et son témoin

**À faire** · prompt §6

### Visé

Le récit (« Windows 98 SE, puis Office 97 »), les étapes, les tuiles, et une
carte de conclusion sur le témoin : sur FAT la fragmentation ne coûte presque
rien au démarrage, sur NTFS le témoin ne gagne pas toujours. Mention du
préchargeur XP/Vista quand il joue.

### Ce que le code offre

`BootSession` et le panneau `bootPanel` actuel : c'est surtout un chantier de
mise en forme.

---

## Chantier U8 — le bilan

**À faire** · prompt §7

### Visé

Avant → après, cartes côte à côte, la phrase de l'outil
(`DefragStrategy.summary(of:)`), partage, et deux suites : **Essayer un autre
outil sur ce disque**, **Démarrer ce disque rangé**.

### À ajouter côté moteur

- Garder l'image de la carte au départ : la passe ne garde que le présent.
- **Démarrer le disque rangé** : le volume d'arrivée existe dans le plan, mais
  il n'y a pas de pont `DefragVolume` → `GeneratedDisk` pour le démarrage.

---

## Chantier U9 — construire un disque usagé

**À faire** · prompt §2

### Visé

Un assistant qui édite un `ProfileSpec`, jamais un résultat :

1. matériel — année, capacité, régime, seek moyen ; géométrie déduite en
   lecture seule, avertissement si la capacité est anachronique ;
2. format — FAT16, VFAT, FAT32, NTFS, taille de cluster ;
3. OS et logiciels installés, désinstallations datées ;
4. période d'usage ;
5. habitudes — `ActivitySpec` : bureautique, navigation, développement,
   médias, téléchargements, jeux, accumulation, maintenance, défragmentations
   planifiées ;
6. graine, avec un 🎲.

Puis **Mes disques** (sauvegarder, renommer, dupliquer) et **Refaire avec les
mêmes habitudes sur un autre format**.

### Ce que le code offre

`ProfileSpec` est `Codable` et se génère déjà tel quel ;
`DriveGeometry.era(model:…)` donne la géométrie d'une année et d'une capacité ;
les logiciels et OS connus sont ceux d'`AppManifest`.

### À ajouter côté moteur

- La liste des OS et des logiciels exposée proprement, avec leur époque.
- La persistance des disques construits.
- L'estimation « plein vers 2001 » : une génération rapide, ou un calcul
  approché du volume écrit par an — à mesurer avant de promettre.
- Valider un profil saisi à la main avant de le générer, sans planter.

---

## Chantier U10 — son, vibrations, ambiance

**À faire** · prompt §8

### Visé

- Feuille **Son et vibrations** : préréglages (Casque, Haut-parleur,
  Silencieux et vibrations seules), curseurs fins en avancé (rotation, tête,
  général ; haptique, intensité, grondement et son niveau), état « haptique
  indisponible ».
- **Mode ambiance** : écran assombri, plateau minimal, minuterie d'arrêt.

### Ce que le code offre

Tous les niveaux existent sur `DiskNoiseEngine` et `DiskHaptics`.

### Questions

- Lecture en arrière-plan (session audio, écran verrouillé) : pas vérifié que
  le fil producteur de `PassSession` et le moteur tiennent app suspendue.

---

## Chantier U11 — accueil et explications

**À faire** · prompt §8

### Visé

Onboarding en trois écrans (ce qu'on entend, ce que montre la carte, mettre un
casque) ; fiches « Pourquoi ça sonne comme ça ? » derrière un ⓘ à côté des
chiffres — loi de seek, next-fit, zone MFT, témoin — au lieu du long texte de
`notes`.

---

## Chantier U12 — états et accessibilité

**À faire** · transversal

### Visé

- États : génération en cours, annulée, échouée ; outil indisponible ; passe
  interrompue ; retour d'arrière-plan.
- Dynamic Type ; VoiceOver sur la carte par zones, pas par blocs ;
  « Réduire les animations » : plateau figé, carte sans rémanence ; contraste
  de l'ambre et du turquoise sur fond sombre.

---

## Ordre proposé

U0 d'abord, parce que tout le reste s'y accroche. Puis U1 → U2 → U3 → U4 :
c'est le parcours principal, et U3 débloque la seule fonction nouvelle qui ne
demande qu'un pont. U6, U8 et U9 sont ceux qui demandent le plus au moteur ;
chacun mérite de commencer par sa partie moteur, testée par `swift test` et
`RenderTrace`, avant d'avoir un écran.
