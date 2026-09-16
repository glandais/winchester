# DiskNoise — prompt Claude Design

Conçois une application iPhone (SwiftUI, iOS 26, mode sombre d'abord) appelée **DiskNoise**. Elle fait **entendre, sentir et voir** un disque dur à plateaux des années 1993 à 2007 en train de démarrer ou de se défragmenter. Le moteur existe et marche déjà. Ce qu'il manque, c'est une interface qu'une personne curieuse, nostalgique mais pas technicienne, prend en main en 30 secondes. Elle doit rester assez riche pour qu'un passionné ait envie de comparer des passes pendant une heure.

Livre des maquettes haute fidélité des écrans ci-dessous, en portrait, plus la carte en plein écran en paysage, avec le parcours entre les écrans.

---

## Ce que fait le moteur (et les contraintes qui en découlent)

- Tout est **simulé en direct** : un planificateur émet des requêtes bloc, un modèle mécanique en tire les seeks, la latence de rotation et les transferts, puis on en tire le son (bras et rotation), l'haptique (Taptic Engine) et l'image.
- **Pas de timeline navigable.** La passe se calcule pendant qu'on l'écoute : pas de barre de lecture, pas de saut, **pas de durée totale connue d'avance**. On peut seulement lancer, mettre en pause, arrêter et relancer depuis le début. N'ajoute ni curseur de lecture ni « temps restant ». En revanche, un pourcentage d'avancement (données déplacées) et le temps écoulé sont disponibles.
- Une passe peut durer **de 8 secondes à plus de 7 heures** de temps réel. L'interface doit rester agréable en fond et, par exemple, montrer clairement où on en est quand on revient dans l'app.
- **Le bilan** (état d'arrivée, fichiers réparés, temps gagné) n'existe **qu'à la fin** de la passe.
- **La fragmentation n'est jamais un réglage.** On raconte une histoire d'usage, un allocateur la rejoue, et la fragmentation en résulte. Aucun écran ne doit proposer « fragmentation : 30 % ».

---

## 1. Choisir un disque prédéfini (écran d'accueil)

Une galerie de **20 disques d'époque** : 5 années × 4 profils (plus un « power user » en 1993). Chaque carte montre le nom, l'année, la capacité, le régime, le système de fichiers, l'OS et une phrase qui raconte le disque.

| id | capacité · tr/min | FS | OS | résumé |
|---|---|---|---|---|
| secretaire-1993 | 170 Mo · 3600 | FAT16 | MS-DOS 6.22 + Win 3.1 | Works et un tableur, des centaines de courriers réenregistrés |
| dev-1993 | 210 Mo · 3600 | FAT16 | MS-DOS 6.22 + Win 3.1 | Borland C++ sur un 486, neuf compilations par jour |
| gamer-1993 | 210 Mo · 3600 | FAT16 | MS-DOS 6.22 + Win 3.1 | Des jeux DOS installés depuis disquettes, et autant désinstallés |
| poweruser-1993 | 340 Mo · 3600 | FAT16 | MS-DOS 6.22 + Win 3.1 | BBS et archives en disquettes de 1,44 Mo, extraites puis effacées |
| famille-1996 | 850 Mo · 5400 | VFAT | Windows 95 | Un peu de tout : courrier, navigation, quelques jeux |
| secretaire-1996 | 850 Mo · 5400 | VFAT | Windows 95 | Office 95 et vingt-six documents par semaine |
| dev-1996 | 1,08 Go · 5400 | VFAT | Windows 95 | Visual C++ 4.2, douze compilations par jour |
| gamer-1996 | 1,08 Go · 5400 | VFAT | Windows 95 | Quake et Doom II, et le swap qui respire |
| secretaire-1999 | 4,3 Go · 5400 | FAT32 | Windows 98 SE | Office 97 pendant deux ans |
| famille-1999 | 6,4 Go · 5400 | FAT32 | Windows 98 SE | Le disque se remplit de MP3 rippés |
| dev-1999 | 6,4 Go · 5400 | FAT32 | Windows 98 SE | Compilations quotidiennes et navigation permanente |
| gamer-1999 | 8,4 Go · 5400 | FAT32 | Windows 98 SE | Half-Life, des démos installées puis effacées |
| dev-2003 | 40 Go · 7200 | NTFS | Windows XP | Visual Studio .NET, cinq cents objets par compilation |
| famille-2003 | 40 Go · 7200 | NTFS | Windows XP | Photos et DivX jusqu'à saturation |
| secretaire-2003 | 40 Go · 7200 | NTFS | Windows XP | Office XP et un .pst Outlook qui grossit |
| gamer-2003 | 80 Go · 7200 | NTFS | Windows XP | Fraîchement installé : Unreal Tournament, rien d'autre |
| dev-2007 | 250 Go · 7200 | NTFS | Vista | Vista, WinSxS, des compilations qui ne fragmentent presque plus |
| secretaire-2007 | 250 Go · 7200 | NTFS | Vista | Office 2007 et la défragmentation planifiée |
| famille-2007 | 320 Go · 7200 | NTFS | Vista | Vidéo de caméscope et iTunes |
| gamer-2007 | 320 Go · 7200 | NTFS | Vista | Crysis et ses paquets de 400 Mo |

Idées de présentation : une frise d'époques (1993 → 2007) avec une petite illustration de disque dont le format évolue, puis des personas (Secrétaire, Développeur, Famille, Gamer). Il faut pouvoir filtrer par époque ou par profil.

**Génération** : quand on choisit un disque, l'appareil fabrique le volume en rejouant l'histoire (jusqu'à environ 1 à 2 s, et plus sur un vieil iPhone). Il faut un état de progression vivant (jour simulé, nombre de fichiers, % occupé, et la carte qui se remplit si possible) et un bouton Annuler.

**Fiche du disque généré** : la carte des clusters (voir §4) et des métriques lisibles : fichiers, % fragmentés, morceaux par fichier, trous dans l'espace libre, slack, taux de remplissage. Ajoute une phrase d'explication en langage courant (« Les clusters de 32 Ko gaspillent un tiers du disque »). Deux actions principales : **Démarrer cet OS** et **Défragmenter ce disque**.

## 2. Construire un disque usagé (éditeur)

On part d'un preset (« dupliquer et modifier ») ou d'une page blanche. On règle **l'histoire**, jamais le résultat. Idéalement, c'est un assistant en étapes avec aperçu :

1. **Le matériel** : année d'achat, capacité (Mo/Go), régime (3600/5400/7200), seek moyen (ms). La géométrie (pistes, plateaux) se déduit de l'année et de la capacité : affiche-la en lecture seule, avec un avertissement doux si la capacité est anachronique (« en 1996, 6,4 Go = plusieurs plateaux »).
2. **Le format** : FAT16, VFAT, FAT32 ou NTFS, et la taille de cluster (Ko). Filtre selon l'époque, ou signale les combinaisons anachroniques.
3. **Le système et les logiciels** : un OS (MS-DOS 6.22 + Win 3.1, Win 95 OSR1, Win 98 SE, XP SP1, Vista) et des installations tirées d'un catalogue (Office 95/97/XP/2007, Works 3, IE5, Netscape 3, Borland C++ 3.1, Visual C++ 4.2, VS .NET, Doom II, Quake, Half-Life, UT2003, Crysis, Winamp, iTunes 7, Nero…). Les désinstallations sont datées.
4. **La période d'usage** : date de début et date de fin (des mois, des années).
5. **Les habitudes** : des curseurs en langage humain, regroupés par activité et activables un par un :
   - bureautique : nouveaux documents par semaine, réenregistrements ;
   - navigation : sessions par jour, pages par session ;
   - développement : compilations par jour, fichiers objets, taille du précompilé ;
   - médias : fichiers par semaine ;
   - téléchargements : par semaine, découpés en parties ;
   - jeux : installations et désinstallations par an, sauvegardes par jour ;
   - accumulation : Go par an, et « fait le ménage à X % de remplissage » ;
   - maintenance : mises à jour par an, fichiers par mise à jour ;
   - défragmentations planifiées (dates).
6. **La graine** : un bouton 🎲 pour tirer un autre disque avec la même histoire.

Montre en permanence une estimation qualitative (« le disque sera plein vers 2001 ») et, une fois généré, le résultat avec un bouton **Refaire avec les mêmes habitudes sur NTFS**. Comparer le même vécu sur trois formats est l'un des moments les plus parlants.

## 3. Choisir une méthode de défragmentation

Un sélecteur d'outil **pédagogique**, pas une liste d'identifiants. Chaque outil a une carte : nom, année, en une phrase ce qu'il fait, ce qu'on va entendre, et un ordre de grandeur de durée sur ce disque. Ce n'est qu'une estimation, pas un compte à rebours.

| outil | disponible sur | principe | ce qu'on entend |
|---|---|---|---|
| **Windows 95/98** (défaut sur FAT) | FAT | Tasse tout au début, dans l'ordre de l'arborescence, en évacuant ce qui gêne | Des allers-retours permanents et un « clac » au bord du plateau à chaque fichier. Très long. |
| **Windows XP** (défaut sur NTFS) | NTFS | Ne répare que les fichiers cassés, en les recopiant dans un trou libre | Court et calme ; échoue quand aucun trou n'est à la taille |
| **UltraDefrag 7.1.1** (2018) | tous | Recolle les petits éclats sans déplacer les gros blocs | Beaucoup de requêtes, moins de morceaux à la fin |
| **JkDefrag 3.36** (2008), mode par défaut | tous | Range par zones et comble les trous, sans jamais évacuer | Rapide sur FAT, a besoin d'espace libre |
| JkDefrag : tasser au début / tasser à la fin | tous | Remplit chaque trou par la fin du fragment le plus haut, ou le plus bas | Court, mais casse plus qu'il ne répare |
| JkDefrag : trier par nom / taille / accès / modification / création | tous | Remet chaque fichier à son rang en délogeant les autres | Le plus long (jusqu'à plus de 7 h) |

Les modes JkDefrag secondaires vont sous un « Options avancées ». Mets en avant le défaut d'époque (« ce qu'un utilisateur de 1999 avait sous la main »). Prévois aussi un mode **Comparer deux outils** sur le même volume : deux bilans côte à côte à la fin.

## 4. La passe en cours : affichage de la grille et du disque

L'écran principal pendant la lecture. Tout y est synchronisé sur l'horloge audio.

- **Carte des clusters**, façon défragmenteur Windows 95 : une grille de blocs colorés, où un bloc vaut N clusters (légende « 1 bloc = 35 clusters = 140 Ko »). Un bloc change de couleur **à l'instant où son écriture s'entend**. Palette existante :
  - libre gris foncé `#292929`, système bleu `#5C8CDB`, applications violet `#9E7ADB`, documents vert `#6BC285`, archives bleu-vert `#61999E`, temporaires et cache orange `#DB944D`, fichier d'échange rouge `#D65C66` (immobile), réservé (FAT, MFT) gris clair `#B8B8B8` ;
  - les fichiers **d'un seul tenant** sont 20 % plus sombres que les fragmentés, et la légende doit l'expliquer simplement (« plus sombre = rangé ») ;
  - lecture en **ambre** `#FFB347`, écriture en **turquoise** `#5CD1D1`, avec une rémanence d'environ 0,3 s ;
  - sur les gros volumes, la teinte est modulée par le taux de remplissage du bloc.
  Prévois l'appui sur un bloc (catégorie, taille, plage de clusters) et le passage **en plein écran paysage**, où la grille remplit tout l'écran (environ 16 800 blocs sur un iPhone 17 Pro Max).
- **Vue plateau** : un disque vu de dessus qui tourne (ralenti ×100), un bras qui se déplace réellement vers le cylindre visé, et une traînée des accès qui dérive avec la rotation, jusqu'à dessiner des spirales en lecture séquentielle. Affiche le cylindre courant et une LED d'activité HDD.
- **Phase en cours** : « Analyse du volume », « Fichiers système », « Applications », « Documents », « Temporaires et cache », « Écriture des tables d'allocation », « Terminé »… avec une phrase de détail. Montre les phases passées sous forme de frise d'activité, **sans** projection des phases futures en durée.
- **Compteurs vivants** : % avancé, Mo déplacés, fichiers déplacés, évacuations, temps écoulé.
- **Transport** : lecture/pause, relancer, arrêter. Rien d'autre.
- Trouve la hiérarchie : sur un iPhone en portrait, il faut arbitrer entre carte, plateau et compteurs. Par exemple, plateau et carte en onglets ou en pile repliable, et un mini-lecteur persistant quand on navigue ailleurs.

## 5. Statistiques (panneau « Instruments »)

Un panneau dédié, accessible pendant la passe (onglet ou tiroir qui glisse depuis le bas) et repris dans le bilan. Il s'adresse au passionné sans effrayer les autres : 4 grands chiffres en tête, le détail en dessous. Chaque chiffre a un « ⓘ » qui l'explique en une phrase.

**En direct, sur une fenêtre glissante** (sparkline des 60 dernières secondes pour chacun) :
- **IOPS** : requêtes par seconde, avec la part lecture (ambre) et écriture (turquoise) ;
- **Débit** en Mo/s, comparé au débit maximal théorique du disque au bord et au moyeu (par exemple 48,6 → 26,7 Mo/s), sous forme de jauge ;
- **Seek moyen** en cylindres et en ms, et le **nombre de seeks** depuis le début ;
- **Où passe le temps** : barre empilée seek / latence de rotation / transfert / calcul (démarrage) / attente. C'est le graphique qui explique le mieux pourquoi une passe est lente ;
- **Position du bras** : histogramme de la distance des seeks (courts, moyens, pleine course) et une carte de chaleur des cylindres visités.

**Cumulés depuis le début de la passe** : requêtes, Mo lus, Mo écrits, Mo déplacés (et ratio « déplacé / taille du volume », qui dépasse 700 % sur un FAT32 plein), fichiers déplacés, évacuations, temps écoulé.

**État du volume, avant → maintenant → après** :
- fichiers fragmentés, en nombre et en **taux** (% des fichiers), en distinguant « parmi les fichiers qui pourraient l'être » ;
- **morceaux** (extents) : total, moyenne par fichier, 95ᵉ centile, pire fichier ;
- trous dans l'espace libre et plus grand trou libre ;
- remplissage, slack (% perdu dans les fins de clusters) ;
- sur NTFS : fichiers résidents dans la MFT, taille de la zone MFT.
Présente les deux indicateurs de fragmentation **côte à côte** avec une note : un fichier ramené de 40 morceaux à 2 reste « fragmenté ». Le taux de fichiers fragmentés peut stagner alors que les morceaux s'effondrent (UltraDefrag : 132 920 → 1 503 morceaux, mais 150 → 157 fichiers fragmentés). Une courbe d'évolution pendant la passe rend ce paradoxe visible.

**Pour le démarrage** : fichiers lus, Mo lus, part du calcul, attente disque, écart avec le témoin, et le nombre de seeks et le seek moyen avec ou sans préchargeur (par exemple 1 142 seeks à 105 289 cylindres, contre 682 à 34 974).

**Comparaison** : quand deux passes ont été faites sur le même disque, le panneau se met en mode deux colonnes (outil A / outil B), avec le vainqueur surligné par indicateur, sans verdict global.

> Note pour la maquette : IOPS, débit, seek moyen, nombre de seeks, requêtes et Mo déplacés existent déjà en direct. Les métriques de volume (fichiers, fragmentés, extents moyens, p95 et maximum, trous, plus grand trou, slack, remplissage, résidents MFT) existent pour l'état initial et final. La répartition du temps, les histogrammes, la séparation lecture/écriture et l'évolution de la fragmentation **pendant** la passe sont à ajouter côté moteur : conçois-les quand même.

## 6. Démarrer un OS (l'autre action)

Même écran de lecture, mais le récit est « Windows 98 SE, puis Office 97 » : étapes noyau, pilotes, application. Tuiles : fichiers lus, temps de calcul (s), attente disque (s), et **le témoin** : la durée qu'aurait eue le même démarrage sur un disque jamais fragmenté, avec l'écart en %. Le résultat surprend souvent (« sur FAT, la fragmentation ne coûte presque rien au démarrage ») et mérite une carte de conclusion claire. Mentionne le préchargeur XP/Vista quand il s'applique (« la liste est triée par position sur le disque »).

## 7. Bilan de fin de passe

Un écran de synthèse partageable : avant → après (fichiers fragmentés, morceaux, trous), Mo déplacés, évacuations, durée, et la phrase de l'outil qui explique ce que les chiffres veulent dire (« 0 évacuation, c'est normal : cet outil ne déloge personne »). Montre les cartes avant et après côte à côte. Propose deux suites : **Essayer un autre outil sur ce disque** et **Démarrer ce disque rangé**.

## 8. Autres éléments à concevoir

- **Son et haptique** : le mixage réel des couches est Rotation, Tête et Général. Pour l'haptique : activé ou non, intensité des transitoires, grondement de rotation et son niveau. Présente-les dans une feuille « Son et vibrations » simple, avec des préréglages (Casque, Haut-parleur, Silencieux et vibrations seules) ; les curseurs fins vont en avancé. Gère l'état « haptique indisponible ».
- **Mode ambiance / veille** : une passe de plusieurs heures comme bruit de fond (écran assombri, plateau minimal, minuterie d'arrêt). C'est l'usage « ASMR » naturel de l'app.
- **Scénarios démo** : deux expériences clés en main pour la première ouverture : « Démarrage Windows + suite bureautique (Seagate Barracuda ATA IV, 2001, 1 min) » et « Défragmentation Windows 95 (Quantum Fireball 1080AT, 1996, 3 min 24) ».
- **Onboarding** en trois écrans : ce qu'on entend (seek, clac de parking, ronronnement), ce que montre la carte, et un conseil de casque.
- **« Pourquoi ça sonne comme ça ? »** : des fiches courtes contextuelles (loi de seek, allocateur next-fit, zone MFT, témoin), accessibles depuis un « ⓘ » à côté de chaque chiffre plutôt qu'un long texte en bas de page.
- **Mes disques** : sauvegarder les disques construits, les renommer, les dupliquer.
- **États** : génération en cours, génération annulée, échec, outil indisponible sur ce format (grisé avec la raison), passe interrompue, retour d'arrière-plan.
- **Accessibilité** : Dynamic Type, VoiceOver sur la carte (résumé par zone plutôt que bloc par bloc), respect de « Réduire les animations » (plateau figé, carte mise à jour sans rémanence), contrastes suffisants pour ambre et turquoise sur fond sombre.

## Direction visuelle

- Base existante : fond `#0E0F12`, panneaux `#191B20` à coins arrondis de 14 pt et liseré blanc à 8 %, texte `#EBEBEB`, texte secondaire `#858585`, accent ambre `#FFB347`, secondaire turquoise `#5CD1D1`, bras du plateau `#C7CCDB`.
- Un ton « instrument de mesure rétro » : chiffres en police monospace, LED d'activité, un clin d'œil discret à l'esthétique Windows 95 **uniquement dans la carte des clusters**. Le reste de l'app est résolument iOS moderne, pas un pastiche.
- Langue de l'interface : français, phrases courtes, chiffres au format français (« 3 min 24 », « 6,4 Go »).
