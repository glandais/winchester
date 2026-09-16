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

### Rebasé sur `develop` : six défragmenteurs et les blocs pleins

`develop` a reçu deux stratégies écrites dans le projet, et une option pour
trois des outils existants (`6da1772`). L'écran de choix les suit :

- **Tassage à la frontière** (`frontierCompaction`), proposé sur FAT seulement,
  grisé sur NTFS ; mesuré de 5 min 22 à 53 min 45 sur les douze volumes FAT.
- **Recollage économe** (`fragmentMerge`), sur NTFS seulement ; mesuré de 8 s à
  23 min 37 sur les huit volumes NTFS.
- Ni l'un ni l'autre n'est marqué « D'époque », et leur carte dit « écrit pour
  DiskNoise ».
- **« Déplacer par blocs pleins »**, un interrupteur au-dessus de **Lancer la
  passe**, quand l'outil choisi a l'option (`DefragPlanner.withFullBlocks`) :
  XP, UltraDefrag et les modes de JkDefrag. Il dit que ce n'est pas le
  comportement de l'outil, et que les durées mesurées ne valent plus.
- Deux fourchettes recalées sur les nouveaux tableaux : UltraDefrag et XP
  descendent à quelques secondes sur `gamer-2003`.

Vérifié sur le simulateur, `secretaire-2003` : tassage grisé (« Réservé à
FAT »), recollage proposé, interrupteur visible avec XP présélectionné.

## Chantier U4 — l'écran de la passe

**Fait** · branche `interface-grand-public`

### Le problème

L'onglet Passe était resté le long défilement d'avant, moins ce que U0 avait
déménagé : titre « DiskNoise », panneau du volume avec sa carte et un
paragraphe de chiffres, plateau, bandeau de phase, frise, transport. Le
pourcentage était une ligne sous la carte, le temps écoulé au fond de la
frise, et seuls **Relancer** et lecture/pause existaient.

### Les décisions

- **Un bandeau de passe en tête** (maquettes 09 et 10) : titre du scénario,
  outil ou système, « PHASE 2 · FICHIERS SYSTÈME » et son détail, puis
  l'avancement en grand, le temps écouté dessous et la barre de progression.
  La LED d'activité passe dans le bandeau.
- **Deux vues, Carte et Plateau**, par un sélecteur segmenté. Une passe de
  démarrage n'a pas de carte : elle ne montre que le plateau, sans sélecteur.
- **Carte** : la carte, une légende lecture ambre / écriture turquoise, la
  légende des catégories, le plein écran, puis quatre compteurs et la phrase
  « Au départ… À l'arrivée… » en chiffres français.
- **Plateau** : le plateau, « CYLINDRE 141 / 3 835 » et le modèle de disque, le
  bilan du démarrage s'il y a lieu, les **phases écoutées** avec leur durée, et
  la frise de la dernière minute.
- **Transport fixe en bas** : **Arrêter**, lecture/pause, **Relancer**. Arrêter
  revient au début sans rejouer : pause puis relance de la passe, qui ne
  reprend la lecture que si elle jouait.
- **Le temps passé par phase est cumulé dans `LivePass`** (`phaseTimes`).
  Les repères de phase ne suffisaient pas : ils sont oubliés au-delà d'une
  minute, et une passe de Windows 95 alterne sans arrêt entre les fichiers et
  la réécriture des tables. Le cumul est tenu à l'avance de l'écoute, une
  entrée par phase, dans l'ordre d'apparition, reprises comprises. Il ne
  touche à rien de ce qui est produit : ni repères, ni son, ni carte.
- **Fichiers déplacés et évacuations s'affichent au bilan**, « — au bilan »
  jusque-là. Ces compteurs vivent dans la stratégie, qui ne les publie qu'avec
  son plan ; les donner en direct demande de les faire passer par la chaîne de
  datation, pour onze stratégies. C'est un chantier du moteur, pas de l'écran.
- `FrenchFormat.duration` : « 42 s », « 12 min 41 », « 1 h 07 ».

### Ce qui valide

- **`swift test` : 96 tests `DiskCore` et 145 `DefragKit` passent**, dont deux
  nouveaux (`PhaseTimeTests`) : une phase reprise cumule ses durées dans
  l'ordre d'apparition, et le cumul tient au-delà de la minute où les repères
  sont oubliés.
- Construit en Debug pour le simulateur iPhone 17 Pro, sans erreur.
- **Le son ne change pas.** Rendu hors-ligne de la base de la branche
  (`fbbcfd3`) et de la branche, sur `windowsBoot`, `defrag`,
  `boot:dev-1993`, `boot:famille-2007`, `gamer-2003` et `secretaire-2003` :
  six WAV identiques à l'octet (`md5`).
- Sur le simulateur, démo de défragmentation : bandeau « PHASE 2 · FICHIERS
  SYSTÈME », 39 % à 25 s ; vue Carte avec légende et compteurs ; vue Plateau
  avec « CYLINDRE 141 / 3 835 » et « Analyse du volume 4 s », « Fichiers
  système en cours » ; **Arrêter** ramène à 0 %, 0 s, « Rien encore », lecture
  en pause.

### Laissé ouvert

- **Fichiers déplacés et évacuations en direct** : compter dans les
  stratégies, dater avec la requête qui valide le déplacement, et vérifier que
  les WAV restent identiques. À faire avant U6, qui en a aussi besoin.
- ~~`Tools/build-render.sh` ne compile plus sous Xcode 27~~ : corrigé sur
  `develop` (`968e7df`). Après le rebase, le script compile tel quel, et la
  comparaison a été refaite contre `develop` : `windowsBoot`, `defrag`,
  `boot:famille-2007`, `gamer-2003`, `dev-1993` et le recollage économe sur
  `secretaire-2003`, six WAV identiques à l'octet.
- **L'effet de bord de défilement d'iOS 26** laisse deviner le contenu sous la
  barre de transport et sous la barre d'onglets flottante : comportement du
  système, laissé tel quel.
- La vue choisie (Carte ou Plateau) n'est pas retenue d'une passe à l'autre.
- Le démarrage garde l'ancien panneau de témoin : c'est U7.

---

## Chantier U5 — la carte en plein écran, touchée

**Fait** · branche `interface-grand-public`

### Le problème

La carte en plein écran montrait jusqu'à seize mille blocs, et aucun ne disait
ce qu'il était. Un bloc vaut quelques clusters sur un volume de 1996, des
milliers sur un 320 Go : sa couleur dit une catégorie dominante et un
remplissage, pas quels fichiers il porte.

### Les décisions

- **Toucher un bloc l'entoure** et ouvre un panneau : sa catégorie, son numéro,
  sa plage de clusters, son remplissage. Toucher le même bloc, ou la croix,
  referme. `ClusterMapView` n'écoute le doigt que si on lui passe `onCellTap`
  : la carte en pouce garde son geste, ouvrir le plein écran.
- **Pour un disque de la galerie, les fichiers du bloc**, les trois plus
  présents : chemin, taille, « d'un seul tenant » ou nombre de morceaux, puis
  « Et N autres fichiers » et les clusters réservés par le système.
- **La recherche vit dans `DiskCore`** (`GeneratedDisk.contents(ofCell:cellCount:limit:)`)
  et reprend **exactement le découpage de la carte** (`clusterRange(ofCell:cellCount:)`,
  la même part fractionnaire de clusters par bloc que `shaded(count:)`). Elle
  parcourt le catalogue à chaque toucher : un geste, pas une image.
- **Pendant une passe, pas de fichiers.** La carte rejouée n'est qu'une suite de
  plages colorées, et les fichiers changent de place : le panneau donne la
  catégorie et le remplissage à l'instant écouté, et le dit (« Les fichiers ne
  sont pas suivis pendant une passe »).
- **Le panneau se pose sur la carte, pas à la place du transport.** La première
  version remplaçait la légende : la surface de la carte changeait de hauteur,
  la grille se redécoupait, et le changement de grille — qui doit effacer la
  sélection, puisqu'un même numéro ne désigne plus les mêmes clusters — la
  refermait aussitôt. Rien ne se passait au toucher.

### Ce qui valide

- **`swift test` : 99 tests `DiskCore` et 145 `DefragKit` passent**, dont trois
  nouveaux (`CellContentsTests`) :
  - les plages de 1, 7, 1 248 et 16 808 blocs couvrent le volume sans trou ni
    recouvrement ;
  - sur `gamer-1993` et `gamer-2003`, les clusters des fichiers et du système de
    chaque bloc, additionnés, redonnent **exactement** l'occupation de la
    bitmap ;
  - les fichiers listés sont rangés du plus au moins présent.
- Sur le simulateur, en portrait :
  - `secretaire-1996` : bloc 703, « Système », clusters 3 799 à 3 804, 100 %
    occupé, `…SYSTEM\WIN9155.DLL`, 3,5 Mo, d'un seul tenant ;
  - démo de défragmentation à 37 % : bloc 1 453, « Système », clusters 5 808 à
    5 811, 100 % occupé, et la mention des fichiers non suivis.

### Laissé ouvert

- **Les fichiers d'un bloc pendant une passe** demandent de tenir, dans le
  rejeu, qui occupe chaque plage : les mutations de la carte ne portent qu'une
  catégorie. C'est un chantier du moteur.
- **Le plein écran n'a été vu qu'en portrait** : `axe` ne sait pas faire pivoter
  le simulateur. La grille se dérive de la surface, le panneau est posé sur la
  carte ; rien de propre au paysage, mais rien de regardé.
- Pas de glisser pour parcourir les blocs, pas de zoom.
- ~~Deux découpages en blocs, entier pour la passe, fractionnaire pour la
  galerie~~ : repris sur `develop` (`8aabe6a`, `61f3729`). Le découpage entier
  entassait le reste de la division dans le dernier bloc, et la liste d'un bloc
  de la galerie pouvait nommer un cluster peint dans le bloc voisin.
  `CellPartition`, dans `DiskCore`, sert désormais aux deux cartes et à
  `clusterRange(ofCell:cellCount:)`, et la légende n'écrit « = » que pour une
  part entière.

---

## Chantier U6 — les instruments

**Fait** · branche `interface-grand-public`

### Le problème

L'onglet Instruments n'avait que quatre tuiles : requêtes et débit de la
tranche de cent millisecondes en cours — donc des chiffres qui sautaient à
chaque image —, seek moyen en cylindres et nombre de seeks. La maquette 11
demande de dire où passe le temps, comment se répartissent les seeks, où va le
bras, ce qui est lu et écrit, et ce que la passe a déplacé, **en cours de
passe**. Le moteur ne le savait pas : ni lecture/écriture par tranche, ni temps
par composante, et les fichiers déplacés et évacuations n'existaient que dans le
plan final.

### Les décisions — côté moteur

- **La mécanique cumule son temps** (`TraceStats`) : seek (commutations de tête
  comprises), rotation, pas de piste pendant un transfert, calcul de la machine
  entre deux lectures, attente. Avec le transfert, ils recomposent exactement
  l'horloge — hors montée en régime, qui précède la première requête.
- **Les tranches d'activité gardent un détail** (`ActivityDetail`) : lectures,
  octets lus et écrits, temps par composante, seeks par classe de distance
  (`SeekClass` : piste voisine, ≤ 1 %, ≤ 10 %, ≤ 50 % de la course, pleine
  course — la même borne que `fullStrokeSeeks`), requêtes par bande de
  cylindres (24 bandes, du bord au moyeu). Le détail est à part des champs
  historiques : la comparaison avec le calcul d'un bloc l'ignore, et le dit.
- **Les stratégies publient leurs compteurs** sur l'`OperationSink`
  (`moves`), comme elles y publient déjà l'avancement, là où elles les comptent
  pour leur plan : chaque stratégie garde son sens de « fichier déplacé ». La
  chaîne les date à la fin de l'opération suivante ; à la fin du travail, **le
  plan fait foi** et pose le dernier compte. `LivePass.moves` les lit à
  l'instant écouté.
- `LivePass` cumule le détail avec les totaux.

### Les décisions — côté écran

- **En direct, sur la dernière minute, seconde par seconde** : IOPS avec la part
  de lectures, débit comparé au débit soutenu du bord et du moyeu de *ce* disque,
  seek moyen en cylindres et en millisecondes (loi de seek du disque), nombre de
  seeks. Chaque tuile a sa courbe de soixante points ; la valeur est celle de la
  dernière seconde, plus celle d'une tranche.
- **Depuis le début** : la barre « Où passe le temps », l'histogramme des
  distances, la bande des cylindres visités, puis requêtes, Mo lus, écrits,
  déplacés (et en part du contenu du volume), fichiers déplacés, évacuations.
- **Le volume** : fichiers fragmentés (nombre et taux), morceaux à recoller,
  trous libres, morceaux par fichier, **avant → après** — l'après au bilan —,
  avec la phrase qui dit pourquoi fichiers fragmentés et morceaux ne racontent
  pas la même chose. Pour un démarrage : fichiers lus, calcul, attente disque,
  témoin.

### Ce qui valide

- **`swift test` : 99 tests `DiskCore` et 166 `DefragKit` passent**, dont cinq
  nouveaux (`InstrumentsTests`), sur un FAT16 de 40 Mo vieilli :
  - seek + rotation + transfert + pas + calcul + attente recomposent le temps de
    travail à 10⁻⁶ s près, dans la mécanique comme en sommant les tranches ;
  - sur trois requêtes servies directement à la mécanique, un calcul de 0,4 s
    est compté en calcul et non en attente — la passe de défragmentation n'en a
    pas ;
  - les classes de seek redonnent le nombre de seeks, la classe « pleine
    course » `fullStrokeSeeks`, les bandes le nombre de requêtes, les octets lus
    et écrits ceux de la mécanique ;
  - **pour les treize stratégies de `DefragPlanner.all`**, le dernier compteur
    publié égale `filesMoved` et `evacuations` du plan ;
  - `LivePass` rend le compteur à son instant, pas en avance.
- **Le son ne change pas** : huit rendus hors-ligne identiques à l'octet à ceux
  de `develop` — `windowsBoot`, `defrag`, `boot:dev-1993`, XP sur `gamer-2003`,
  UltraDefrag sur `dev-2003`, tassage à la frontière sur `dev-1993`, recollage
  économe sur `secretaire-2003`, JkDefrag sur `dev-1996`.
- Sur le simulateur, démo de défragmentation à 44 s : 45 IOPS dont 33 % de
  lectures, 2,8 Mo/s pour un maximum de 7,6 → 5,1, seek moyen 105 cylindres
  ≈ 5,6 ms ; temps : seek 19 %, rotation 30 %, transfert 43 %, attente 7 % ;
  bras concentré sur les bandes du bord, là où est la partition ; fichiers
  déplacés et évacuations qui montent entre deux captures (148 → 156,
  171 → 176).

### Laissé ouvert

- **L'état du volume pendant la passe.** Fragmentés, morceaux et trous ne sont
  connus qu'au départ et au bilan : les tenir au fil des mutations demande un
  suivi par fichier dans le rejeu, le même qui manque à U5.
- **La comparaison de deux passes en colonnes** : U8.
- **Le démarrage n'a pas été regardé à l'écran**, ni streamé dans un test : la
  séparation du calcul est vérifiée sur la mécanique seule.
- Les compteurs sont datés à la fin de l'opération *suivante* : un fichier est
  compté un tampon après son dernier déplacement. Invisible à l'échelle d'une
  seconde, mais c'est une approximation.

---

## Chantier U7 — le démarrage et son témoin

**Fait** · branche `interface-grand-public`

### Le problème

Le démarrage d'un disque généré n'avait qu'un panneau de quatre tuiles
(« Jamais fragmenté 55 s », « −9 % » écrit en unité) et un paragraphe fixe qui
expliquait le témoin dans l'absolu, quel que soit le format et le résultat. Le
préchargeur de XP et de Vista — la différence d'époque la plus audible — n'était
dit nulle part, et le témoin ne donnait que sa durée, pas ses seeks.

### Les décisions

- **Vue Plateau d'un démarrage** : le plateau, les **étapes** (les actes du
  script, avec le temps passé dans chacun), quatre tuiles, puis la carte du
  témoin. Plus d'« en cours » une fois le démarrage entendu.
- **Les tuiles se remplissent à l'écoute** : fichiers à lire (et combien dans la
  MFT), octets lus, **calcul** de la machine et **disque** — seek, rotation,
  transfert —, pris aux instruments d'U6. Leur somme tend vers la durée, le
  reste étant la mise sous tension et l'attente.
- **La carte du témoin** (maquette 14) : « DÉMARRAGE TERMINÉ · 51 S », l'écart
  en grand — ambre quand le volume coûte, turquoise quand le témoin perd —, puis
  deux lignes, ce disque et le témoin, chacune avec sa durée, ses seeks et son
  seek moyen.
- **La phrase suit le format et le signe**, pas une conclusion écrite
  d'avance :
  - FAT et écart sous 5 % : ces fichiers ont été écrits d'un seul tenant par
    l'installeur, sur un disque vide ; c'est l'ordre des demandes qui fait le
    bruit ;
  - FAT au-delà : la place des fichiers coûte, plus qu'un démarrage FAT
    d'ordinaire ;
  - NTFS et témoin plus lent : NTFS choisit le trou qui convient, et sa
    disposition bat un empilement dans l'ordre du répertoire ;
  - NTFS et témoin plus rapide : le témoin ne mesure pas la fragmentation
    seule, mais la place réelle face à un rangement naïf.
  Avant la fin, la carte dit que le témoin est déjà simulé et que l'écart se lit
  au bout.
- **Le préchargeur** en ⓘ : « Préchargeur de Windows XP : la liste de lecture
  est rangée par position… » ou « Pas de préchargeur sur MS-DOS 6.22 et
  Windows 3.1 : le bras suit l'ordre dans lequel le système demande ses
  fichiers ». La phrase de la maquette disait « l'ordre du registre », qui
  n'existe pas sous MS-DOS.
- **`BootPlayback` porte ce qu'il faut** : octets à lire, format, préchargeur de
  l'époque (`BootScript.Era.prefetch`), seeks et seek moyen du témoin, pris sur
  la trace qui le simulait déjà.
- Les durées affichées sont **arrondies** et non plus tronquées : l'en-tête
  disait « 50 s » pour 51,0 s.

### Ce qui valide

- Construit en Debug pour le simulateur iPhone 17 Pro, sans erreur ;
  `Tools/build-render.sh` compile, et deux démarrages (`boot:dev-2003`,
  `boot:gamer-1993`) rendent des WAV identiques à ceux de `develop` :
  `Scenario.swift` ne change que ce qu'il décrit.
- Sur le simulateur, joués jusqu'au bout :
  - `gamer-1993` (FAT16) : **29,5 s contre 29,2 s, +0,9 %** — le README donne
    29,5 s et +1 % ; 112 seeks à 180 cylindres contre 101 à 100 ; phrase FAT,
    pas de préchargeur ;
  - `dev-2003` (NTFS) : **51,0 s contre 55,9 s, −8,7 %** — le README donne
    51,0 s et −9 % ; phrase « Le témoin perd », préchargeur de Windows XP ;
    calcul 25 s, disque 16 s.

### Laissé ouvert

- **« Comparer avec un disque 2003 et XP »** n'est pas là : il faudrait ouvrir
  la galerie sur un filtre choisi depuis un autre onglet.
- **Le démarrage livré** (Barracuda 2001) n'a pas de témoin : il est décrit en
  fractions du plateau, sans catalogue de fichiers à remettre d'un seul tenant.
- Les octets lus par la mécanique dépassent un peu ceux que compte le plan
  (7,7 Mo contre 7,4 sur `gamer-1993`) : la tuile ne compare donc pas les deux.
- Les seuils des phrases (5 % sur FAT) sont posés à la main d'après les vingt
  démarrages de la galerie.

---

## Chantier U8 — le bilan

**Fait** · branche `interface-grand-public`

### Le problème

Une passe finie ne laissait que la phrase « Au départ… À l'arrivée… » sous sa
carte, jusqu'à la passe suivante. Rien ne gardait l'image du volume avant la
passe, ni ses chiffres une fois qu'on en lançait une autre ; on ne pouvait ni
relancer un autre outil sans repasser par la galerie, ni comparer deux passes,
ni démarrer le volume **tel que la passe l'avait laissé** — le plan ne gardait
de l'état d'arrivée que ses statistiques.

### Les décisions — côté moteur

- **Le plan garde l'arrangement d'arrivée** (`DefragPlan.arrangement`) : pour
  chaque fichier, son identifiant et ses extents à la fin de la passe. Quelques
  octets par fichier, là où garder le volume garderait sa bitmap ; les six
  constructions de plan le remplissent, `summarized()` le conserve.
- **Un disque se réarrange** (`GeneratedDisk.rearranged(extents:)`, dans
  `DiskCore`) : le catalogue reçoit les nouveaux extents, la bitmap est refaite
  des fichiers et des extents système, les métriques sont réévaluées avec le
  profil du format. C'est ce que faisait déjà le témoin pour le seul catalogue.
- **`ScenarioBuilder.build(boot:rangedBy:)`** titre « Joueur, 2003, rangé » et le
  dit dans son résumé ; le témoin du disque rangé est celui du disque d'origine,
  puisque le contenu est le même.

### Les décisions — côté écran

- **`SimulationModel` tient les bilans** (`PassRecord`, douze au plus) : au
  moment où le moteur signale la fin, il garde durée, requêtes, seeks, octets
  déplacés, état avant et après, compteurs, phrase de l'outil, arrangement,
  **carte au départ** — prise à l'instant zéro de la passe — et carte à la fin,
  ainsi que le disque d'origine.
- **« Passe terminée · Voir le bilan »** apparaît en tête de l'onglet Passe, et
  la fiche d'un disque liste ses **passes entendues** ; un appui ouvre le bilan
  dans une feuille (maquette 13) : cartes avant et après, avant → après,
  déplacé et part du contenu, phrase de l'outil, puis
  **Essayer un autre outil** (l'écran de choix d'U3, dans la feuille),
  **Démarrer ce disque rangé**, **Comparer à une autre passe** du même disque,
  **Partager le bilan** en texte.
- **La comparaison** met deux passes en colonnes et marque sur chaque ligne la
  valeur la plus basse — toutes sont des coûts ou des restes —, sans rien
  additionner. Deux valeurs qui s'écrivent pareil ne sont pas départagées : la
  première version marquait « 8 s » contre « 8 s ».
- **Le démarrage rangé se compare** : le témoin ajoute la ligne du même disque
  dans l'autre état, « avant rangement » ou « rangé par … », quand elle a été
  entendue.
- **Le bandeau de passe est posé sur la racine de la pile** de l'onglet Disques,
  plus autour : il recouvrait le bouton **Lancer la passe** de l'écran de choix
  dès qu'une passe avait joué, et un appui dessus ouvrait l'onglet Passe au lieu
  de lancer. Défaut d'U0, trouvé ici.

### Ce qui valide

- **`swift test` : 102 tests `DiskCore` et 170 `DefragKit` passent**, dont :
  - pour les **treize stratégies**, l'arrangement reposé sur le volume de départ
    redonne exactement fichiers fragmentés, morceaux, trous, remplissage et
    morceaux par fichier du plan ; un plan résumé garde son arrangement ;
  - un disque réarrangé sans rien déplacer garde bitmap et métriques ; tassé
    d'un seul tenant, il occupe autant et ne compte plus de fichier en
    morceaux ;
  - sur `gamer-1993` rangé par Windows 95 (622 fichiers déplacés sur 623), le
    catalogue porte les nouvelles places, le démarrage lit **d'autres adresses**
    pour le même nombre de fichiers, et les métriques égalent l'état d'arrivée
    du plan.
- **Le son ne change pas** : `defrag`, `boot:dev-2003`, Windows 95 sur
  `dev-1993`, recollage économe sur `secretaire-2003`, identiques à l'octet à
  `develop`.
- Sur le simulateur, `gamer-2003` : démarrage (1 min 09), passe XP (8 s), carte
  « Passe terminée », bilan avec cartes, lignes et actions ; **Essayer un autre
  outil** → recollage économe (8 s) ; comparaison des deux ; **Démarrer ce
  disque rangé** → « Joueur, 2003, rangé », témoin avec « avant rangement
  68,9 s », « rangé par Recollage économe 68,9 s », « jamais fragmenté 69,6 s » ;
  la fiche liste la passe et rouvre son bilan.

### Laissé ouvert

- **Le démarrage rangé de `gamer-2003` dure exactement autant que l'autre** : le
  recollage n'y a touché aucun fichier que le démarrage lit. Le mécanisme est
  prouvé par le test sur `gamer-1993`, pas par une écoute où l'écart s'entend ;
  à refaire sur un FAT de 1996 après Windows 95, une passe de plusieurs minutes.
- **Les bilans ne survivent pas à l'app** : ils vivent dans le modèle, douze au
  plus. « Mes disques » (U9) devra décider ce qui se garde.
- **Ranger un disque rangé** n'est pas proposé : « Essayer un autre outil » repart
  toujours du volume d'origine.
- Un scénario livré (la démo Windows 95) a son bilan, mais ni autre outil ni
  démarrage rangé : il n'a pas de disque de la galerie derrière lui.
- Les cartes du bilan sont prises à la grille en cours : ouvrir le plein écran
  pendant la passe change la grille de la carte d'arrivée.

---

## Chantier U9 — construire un disque usagé

**Fait** · branche `interface-grand-public`

### Le problème

Les seuls disques de l'app étaient les vingt profils du bundle. Écrire un disque
voulait dire écrire un JSON à la main, et rien ne le relisait : une taille de
cluster qui n'est pas une puissance de deux, un régime nul arrêtaient net le
générateur, et un FAT16 trop grand pour ses 65 524 clusters était tronqué sans
un mot. Aucun disque construit ne survivait à l'app.

### Les décisions — côté moteur

- **`ProfileSpec.issues`** (`DiskCore`) relit un profil. **Bloquant** : moins de
  10 Mo, régime ou seek moyen nuls, cluster qui n'est pas une puissance de deux
  ou dépasse 64 Ko, période qui finit avant de commencer. **Avertissement** :
  FAT qui n'adresse pas tout le disque (avec la capacité réellement utilisée),
  format arrivé après l'année d'achat, désinstallation d'un logiciel absent ou
  hors période, défragmentation hors période, logiciel inconnu. Un avertissement
  n'interdit rien : un disque anachronique est une question légitime.
- **La galerie refuse de fabriquer un profil bloquant** et dit pourquoi, au lieu
  de laisser le générateur s'arrêter.
- **`CustomDiskStore`** garde « Mes disques » : un fichier JSON dans Application
  Support, la liste des profils, réécrite en entier. Un fichier illisible **lève**
  plutôt que de rendre une liste vide qu'un enregistrement écraserait ; l'écran
  le dit. Un disque construit porte un identifiant `perso-…`.
- **Ce qui se garde, c'est l'histoire**, pas le volume ni les bilans : le volume
  se refait à l'identique depuis la graine, et un bilan tient le disque entier.
  C'est la décision que U8 renvoyait ici.
- `DiskLibraryModel` connaît les disques construits et un **brouillon** : celui
  que l'assistant fabrique sans l'avoir enregistré.

### Les décisions — côté écran

- **L'assistant** (maquettes 06 et 07) s'ouvre par **+** dans l'onglet Disques,
  par **Dupliquer et modifier** sur la fiche de n'importe quel disque, et par
  **Modifier l'histoire** sur un disque construit. Six étapes, un brouillon, une
  barre Retour / Suivant ; les remarques de `issues` sous chaque étape.
  1. **Matériel** : année, capacité sur une échelle logarithmique arrondie à
     deux chiffres, régime, seek moyen ; la **géométrie déduite** par
     `DriveGeometry.era` — plateaux, cylindres, débit bord → moyeu —, et la
     phrase des plateaux ajoutés quand la capacité devance l'époque.
  2. **Format** : FAT16, VFAT, FAT32, NTFS, ce que fait chaque allocateur, la
     taille de cluster (ou celle de `FORMAT`) et le nombre de clusters.
  3. **Système et logiciels** : un système, qui pose aussi ses manifestes ; les
     logiciels du catalogue avec leur année, « trop récent » quand ils sortent
     après la fin de la période ; une date de désinstallation par logiciel.
  4. **Période** : début, fin, durée, défragmentations planifiées.
  5. **Habitudes** : les huit activités de `ActivitySpec`, chacune activable, avec
     des valeurs ordinaires au départ.
  6. **Graine et résultat** : nom, résumé, graine et 🎲, **Fabriquer le disque**,
     puis la fiche du disque fabriqué — carte, métriques, défragmenter ou
     démarrer tout de suite —, **Refaire avec les mêmes habitudes** sur les
     trois autres formats, et **Enregistrer dans Mes disques**.
- **Mes disques** apparaît entre les démos et la galerie dès qu'il y en a un :
  mêmes cartes, et un menu pour modifier, renommer, dupliquer ou supprimer
  (avec confirmation).
- **Pas d'estimation « plein vers 2001 »** : rien ne la calcule sans fabriquer le
  disque, et la fabrication prend une ou deux secondes. L'étape 6 fabrique.

### Ce qui valide

- **`swift test` : 106 tests `DiskCore` et 174 `DefragKit` passent**, dont :
  - les vingt scénarios du bundle n'ont aucune remarque bloquante ; un cluster
    de 12 Ko, une période vide, un régime nul bloquent ; un FAT16 de 2 Go en
    clusters de 4 Ko, un NTFS de 1993, un logiciel inconnu avertissent ; un
    profil anachronique mais valide se fabrique ;
  - « Mes disques » : un fichier absent donne une liste vide, deux profils se
    relisent octet pour octet, les identifiants ne se répètent pas, un fichier
    illisible lève.
- Sur le simulateur : **+**, six étapes, géométrie d'un 1,08 Go de 1996 à
  3 835 cylindres et 2 plateaux — ceux du Fireball 1080AT ; **Fabriquer** : 5,6 %
  de fichiers fragmentés en VFAT ; **Refaire en NTFS** : 0,1 % ; **Enregistrer** ;
  la carte « Nouveau disque » est dans Mes disques, et y est encore **après
  relance de l'app**. **Dupliquer et modifier** sur « Famille, 1999 » ouvre
  l'assistant sur « Famille, 1999 (copie) » avec son histoire.

### Laissé ouvert

- **Les bilans ne survivent pas à l'app**, par décision : les rejouer coûte une
  écoute, les garder coûterait le disque.
- **Le catalogue des logiciels est figé** et leurs années sont écrites côté écran
  (`SoftwareYears`), pas dans `AppManifest`.
- **Renommer, supprimer et les étapes 2, 4 et 6 n'ont pas été touchés à l'écran**
  au-delà du parcours ci-dessus ; les messages bloquants ne l'ont été que par les
  tests.
- La capacité se règle par curseur, pas par saisie : une valeur exacte
  (« 850 Mo ») n'est atteignable qu'à l'arrondi près, sauf en dupliquant un
  disque qui l'a déjà.
- Pas d'aperçu de la fragmentation avant d'avoir fabriqué : c'est voulu.

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
