# Captures de l'App Store

Trois temps, tous scriptés :

```bash
./scripts/screenshots.sh                              # 1. capture  -> screenshots/flat/<appareil>/<locale>/
kou generate screenshots/koubou/iphone.yaml           # 2. cadrage  -> screenshots/koubou/out/iphone/<locale>/<cadre>/
kou generate screenshots/koubou/ipad.yaml             #             -> screenshots/koubou/out/ipad/<locale>/<cadre>/
./screenshots/assemble.sh                             # 3. assemblage -> screenshots/IPHONE_65/ et IPAD_PRO_3GEN_129/
```

La fiche vise l'iPhone et l'iPad (`TARGETED_DEVICE_FAMILY: "1,2"`) : elle réclame un
jeu par type d'affichage, `IPHONE_65` (1242×2688) et `IPAD_PRO_3GEN_129` (2048×2732),
en `en-US` et en `fr-FR`. Six cartes chacun, soit vingt-quatre fichiers.

## 1. Capture

`./scripts/screenshots.sh` produit les **captures brutes** : six écrans × deux langues ×
deux appareils, sans cadre ni navigation à la main, dans `screenshots/flat/` (non versionné).

```bash
./scripts/screenshots.sh                  # les deux appareils, toutes les langues
./scripts/screenshots.sh --iphone fr-FR   # un appareil, une langue
```

Compter une minute par jeu de six sur l'iPhone, deux sur l'iPad (son démarrage compris).

**Un seul simulateur à la fois.** L'iPhone est celui du dépôt (`scripts/sim-config.sh`) ;
l'iPad, `iPad Pro 13-inch (M4)` sur iOS 26.5, n'existe que pour les captures
(`IPAD_DEVICE`, même fichier). Avant de démarrer un appareil, le script éteint tout autre
simulateur ; à la fin — même sur une erreur — il éteint l'iPad et rallume l'iPhone s'il
était démarré en arrivant. L'iPad n'est jamais rallumé, même s'il l'était : cela ferait
deux simulateurs.

**Rien d'autre ne doit piloter le simulateur pendant ce temps** : `./scripts/xcb.sh run`
installerait l'app Debug par-dessus, sous le même identifiant, et l'app Debug n'a pas de
mode capture — elle s'ouvre sur les disques à chaque fois. Le script le repère (deux
captures identiques dans un jeu) et échoue.

### Comment ça marche

- L'app est construite dans la configuration **`Screenshots`** (`project.yml`), un clone de
  Debug qui définit la condition `SCREENSHOTS`. Tout ce qu'il faut au mode capture —
  `Sources/Screenshots/ScreenshotMode.swift`, `WinchesterEngine.fastForward(to:)` et
  quelques blocs `#if SCREENSHOTS` — manque au binaire archivé. Pour le vérifier :
  `xcodebuild -project Winchester.xcodeproj -target Winchester -configuration Release -showBuildSettings | grep SWIFT_ACTIVE`
  doit ne rien donner.
- Chaque capture est un lancement :
  `simctl launch … -screenshotMode YES -screenshotScreen fullmap -onboardingSeen YES -AppleLanguages "(fr)" -AppleLocale fr_FR`.
  `-screenshotScreen` prend `pass`, `platter`, `fullmap`, `instruments`, `disks`, `disk` ou
  `tools`. Aucun tap : rien ne dépend d'un libellé qui change d'une langue à l'autre.
  `-onboardingSeen YES` passe l'accueil sans code : l'`@AppStorage` lit le domaine des
  arguments.
- Tous les écrans ont la **démo de défragmentation** en cours (« Développeur, 1993 »),
  avancée à 150 s de passe sans être jouée (`-screenshotAt` pour en choisir une autre),
  puis laissée jouer **sans le son** — le simulateur sortirait sinon par les haut-parleurs
  du Mac. La fiche et le choix de l'outil ouvrent « Famille, 1999 » (`-screenshotDisk`).
- L'app désinstallée avant chaque appareil repart d'un conteneur neuf : ni historique de
  passes, ni disques construits.
- Le script n'attend pas un délai fixe : l'app écrit `tmp/screenshot-ready` dans son
  conteneur une fois la passe avancée, puis le script laisse 4 s au plein écran et à la
  fiche du disque pour s'ouvrir. Le disque de la démo se fabrique au lancement, et en
  Debug cela prend une dizaine de secondes.
- La **barre d'état** est celle du système, que `-AppleLanguages` ne touche pas : l'iPad
  y écrit la date, et l'écrivait en français sous une capture anglaise. Le script met le
  système du simulateur dans la langue de chaque jeu (et redémarre SpringBoard), puis lui
  rend la sienne. L'heure est forcée à 9:41 ; aucun écran capturé ne dit l'heure qu'il est.
- L'app se force en sombre (`preferredColorScheme(.dark)`) : l'apparence du simulateur
  ne change rien.

**Pas de canal alpha.** App Store Connect refuse toute capture qui en porte un
(`IMAGE_ALPHA_NOT_ALLOWED`), et les coins arrondis d'une capture d'iPhone sont
transparents. Le script aplatit sur du noir, avant Koubou. `asc screenshots validate` ne
le voit **pas** — il ne regarde que les dimensions : c'est `assemble.sh` qui vérifie.

## 2. Cadrage

Koubou fait de chaque capture une **carte** : cadre d'appareil, titre, sous-titre, fond.
Les sources sont versionnées dans `screenshots/koubou/` : `iphone.yaml`, `ipad.yaml`,
`templates/` (quatre compositions) et `koubou-strings.xcstrings` (les douze textes, en
anglais et en français). Les rendus ne le sont pas.

Une seule série de gabarits sert les deux toiles : celle de l'iPad, presque carrée, est
reconnue par `@media (min-aspect-ratio: 3/5)` et y reprend ses tailles, parce qu'un titre
en `vw` y serait deux fois trop gros. Le catalogue est partagé : les deux configurations
portent les mêmes `variables`, et `scripts/i18n.py check` le vérifie.

La direction vient de l'app : son fond presque noir, l'ambre de la lecture et le
turquoise de l'écriture (`Theme.swift`), et la rangée de clusters de l'icône comme filet
sous chaque titre. Six cartes, quatre compositions, jamais deux voisines pareilles :

| Carte | Écran | Gabarit | Ce qu'elle dit |
|---|---|---|---|
| `01-map` | `fullmap` | `hero` | l'accroche : la carte du volume en plein écran |
| `02-pass` | `pass` | `rise` | le son est calculé, pas enregistré |
| `03-platter` | `platter` | `offset` | le bras sur le plateau |
| `04-tools` | `tools` | `crop` | les défragmenteurs d'époque, à comparer |
| `05-disk` | `disk` | `offset` | des disques qui ont vécu |
| `06-instruments` | `instruments` | `hero` | où passe le temps |

La carte plein écran ouvre parce que c'est l'image qu'aucune autre app n'a, et que les
trois premières cartes sont celles des résultats de recherche. `04-tools` n'a pas de cadre
(`frame: false`) : dans un appareil, le texte des fiches ne se lirait plus ; le gabarit
découpe une fenêtre sous la barre de navigation (marge négative en % de la largeur, une
par toile). Aucun titre ne nomme le produit d'une autre société (directive 2.3.7) — les
captures, elles, montrent l'app telle qu'elle est.

Le texte s'ajuste : chaque bloc déclare la part de la hauteur qu'il possède
(`data-fit-budget`, et `-ipad` pour l'autre toile) ; un court script réduit le titre, puis
le sous-titre, jusqu'à ce qu'il y tienne. Le français court plus long que l'anglais ;
l'anglais, lui, ne bouge pas.

`kou generate` n'a pas d'option de langue : pour itérer sur une seule, copier la
configuration en `screenshots/koubou/x.local.yaml` (non versionné) et y réduire
`localization.languages`, ou `kou live screenshots/koubou/iphone.yaml`.

### Les textes

Les titres se traduisent comme le reste, par `i18n/translations.json` (table `Koubou`) :
`./scripts/i18n.py export`, remplir l'unité `fr-FR`, `./scripts/i18n.py import`. **Les clés
de ce catalogue sont la phrase anglaise elle-même** — c'est ainsi que Koubou retrouve la
traduction d'une variable —, à l'inverse du catalogue de l'app : changer un titre, c'est
changer sa clé dans les deux `.yaml` *et* dans le catalogue. `i18n.py check` signale une
variable qui n'est pas une clé, ou deux configurations qui divergent.

Le français met une espace avant `:` `;` `?` `!` : en faire une espace insécable (U+00A0)
dans le catalogue, sans quoi la ponctuation peut passer seule à la ligne.

## 3. Assemblage

Koubou écrit `out/<appareil>/<locale>/<nom du cadre>/NN-*.png` ; App Store Connect veut
`screenshots/<type>/<locale>/NN-*.png`. `./screenshots/assemble.sh` aplatit ce niveau,
efface de la destination ce que le nouveau rendu ne remplace pas (un ancien nommage
partirait sinon avec le nouveau jeu), et refuse un jeu que l'envoi rejetterait :
dimensions exactes, aucun canal alpha, pas vide, pas beaucoup plus léger que la même carte
dans l'autre langue. Il finit par `asc screenshots validate` par locale.
`--keep-stale` saute l'effacement, `--no-validate` la validation.

`screenshots/IPHONE_65/` et `screenshots/IPAD_PRO_3GEN_129/` sont versionnés, numérotés
parce que les fichiers partent par ordre alphabétique.

## Envoi

```bash
asc localizations list --version-id "VERSION_ID"     # les identifiants des localisations

asc screenshots upload --version-localization "LOCALIZATION_ID" \
  --path "./screenshots/IPHONE_65/en-US" --device-type "IPHONE_65"
asc screenshots upload --version-localization "LOCALIZATION_ID" \
  --path "./screenshots/IPAD_PRO_3GEN_129/en-US" --device-type "IPAD_PRO_3GEN_129"
```

Par locale et par type : App Store Connect n'hérite pas les captures de la langue
principale. Un fichier refusé à l'envoi reste dans le jeu à l'état `FAILED` ; le
retirer par `asc screenshots delete --id <id>` avant de réessayer.
