# Winchester

Simulation d'I/O au niveau bloc d'un disque dur à plateaux, convertie en son par
AVFAudio, dans une application iOS 17+ (SwiftUI, Swift 6). `README.md` est la
référence du projet : ce qui est modélisé, la chaîne, les vingt disques
d'époque, la structure des fichiers. Ce fichier-ci ne couvre que la construction,
la traduction et la publication.

## Construire

```bash
./scripts/xcb.sh build            # schéma Winchester, Debug
./scripts/xcb.sh run              # + installe et lance sur le simulateur
./scripts/xcb.sh strings          # construit, puis synchronise le catalogue
./scripts/xcb.sh gen              # (re)génère le .xcodeproj depuis project.yml
./scripts/xcb.sh -- <args...>     # xcodebuild brut, destination épinglée
```

Le noyau ne passe pas par Xcode : `swift test` couvre `Sources/DiskCore` et
`Sources/Model` (recompilée par le paquet sous le nom `DefragKit`), en quelques
secondes, là où un cycle par le simulateur en coûte des dizaines. Il n'y a
**pas** de cible de test Xcode, donc pas de `xcb.sh test`. Pour valider une
modification de `Sources/Model` censée ne rien changer au son, le rendu
hors-ligne reste la vérification de bout en bout : `./Tools/build-render.sh`
puis `SCENARIO=<id> /tmp/rendertrace out.wav`, et comparer les `md5`.

### Simulateur

`./scripts/xcb.sh` est la **seule** façon de lancer `xcodebuild` sur un
simulateur. Il épingle `-destination` (par UDID) sur l'appareil unique du dépôt
et `-derivedDataPath` sur `.build/DerivedData`. Ne jamais écrire une
`-destination` à la main, ni employer `generic/platform=iOS Simulator` : elle
construit sans rien démarrer, si bien que la commande suivante — celle qui a
besoin d'un appareil — en choisit un toute seule. C'est ainsi qu'on se retrouve
avec trois simulateurs démarrés sur une machine qui n'a pas la mémoire pour.
`scripts/guard-simulator.py`, branché en hook `PreToolUse` depuis
`.claude/settings.json`, refuse aux agents toute commande Bash qui piloterait un
autre appareil.

L'appareil est `iPhone 17 Pro Max` (iOS 26.5), déclaré une seule fois dans
`scripts/sim-config.sh`. Un `iPhone 18 Pro Max` (iOS 27.0) existe aussi sur
cette machine : `WINCHESTER_SIM_DEVICE` bascule dessus pour une session entière
— exporté dans l'environnement, pas préfixé sur une commande, sinon le hook ne
le voit pas. `WINCHESTER_DERIVED_DATA` déplace le dossier de construction.

Le schéma construit en **Debug** ; `xcb.sh run` installe le produit par son
chemin explicite. Un `Release-iphonesimulator/` périmé traîne dans le même
dossier, et un `find … | head -1` tombe dessus : on installe alors un binaire
d'avant la modification, ce qui donne l'illusion que la compilation n'a rien
changé. Après un lancement, l'écran reste **blanc une dizaine de secondes** en
Debug — le disque de la démo se fabrique au lancement.

### Génération du projet (XcodeGen)

`Winchester.xcodeproj` est **généré** depuis `project.yml` et n'est pas versionné
— `project.yml` est la source. Un fichier neuf dans `Sources/` n'y entre donc pas
tout seul, et Xcode échoue sur un « cannot find X in scope » qui n'a rien d'une
erreur de code (`swift test`, lui, passe) : réflexe `./scripts/xcb.sh gen` avant
de conclure quoi que ce soit d'une erreur de portée. `xcb.sh` génère de lui-même
si le `.xcodeproj` manque, ce qui suffit dans un worktree neuf.

Deux points qui piègent :

- `Support/Info.plist` existe sur le disque mais il est **écrit** depuis le bloc
  `info.properties` à chaque génération — ne jamais l'éditer à la main.
- `MARKETING_VERSION` et `CURRENT_PROJECT_VERSION` dans `project.yml` sont le
  seul endroit où se monte une version : `info.properties` y renvoie par
  `$(...)`. Sans ces deux entrées, XcodeGen écrit ses propres valeurs (`1.0` /
  `1`) et le numéro de build ignore silencieusement `project.yml`.
- Un fichier ajouté à `Sources/Model` doit aussi être listé à la main dans
  `Tools/build-render.sh`, sans quoi le rendu hors-ligne ne compile plus.

## Traduction

L'application vise **deux langues** : l'anglais (source) et le français, listées
dans `knownRegions` de `project.yml`, à travers
`Sources/Resources/Localizable.xcstrings`.

Les **clés sont des noms pointés** (`pass.report.title`, `tab.disks`), jamais la
phrase elle-même : une phrase comme clé transforme chaque reformulation en un
diff dans toutes les langues. Le code ne porte donc plus de prose :

```swift
Text("settings.replayWelcome")                       // clé seule, valeur au catalogue
String(localized: "disk.badge.booted",               // avec arguments : l'anglais
       defaultValue: "Booted · \(when)",             // vit dans defaultValue, et
       comment: "Pastille d'une carte de disque")    // devient %@ au catalogue
```

**Le catalogue est le registre de ce qui reste** : une clé dont le nom n'est
pas un nom pointé est une chaîne que `xcstringstool` a extraite du code telle
quelle, faute d'avoir été migrée. `./scripts/i18n.py export` en donne le compte
(`notYetMigrated`) ; il est à **zéro** depuis le 21 septembre 2026, pour
874 clés. La seule clé qui ne soit pas un nom pointé est la chaîne vide —
l'indice d'accessibilité absent de `accessibilityHint(… : "")`. Un `Text` à
interpolation (`Text("\(a) \(b)")`) en fabrique une aussi, sous le nom
`%@ %@` : c'est le signe qu'il manque un `Text(verbatim:)`.

Trois couches portent du texte, et toutes les trois sont traduites :

- les **écrans** (`Sources/UI/`) ;
- les **libellés du modèle** (`Sources/Model/`) — phases d'une passe, catégories
  de clusters, noms d'outils, résumés de stratégie, étapes d'un démarrage,
  zones de la carte dites par VoiceOver. Ce sont des `String` rendues par
  `String(localized:)`, pas des clés passées à `Text` ;
- les **vingt disques d'époque**, dont le nom et le résumé vivent dans les JSON
  de `Sources/DiskCore/Resources/scenarios/`. On ne traduit pas les fichiers —
  ils sont la référence du `README.md` — : `GalleryStrings`
  (`Sources/Model/DisplayFormat.swift`) les relit par identifiant, et
  `ProfileSpec.localized()` pose la traduction **une fois, au chargement**, si
  bien que tout ce qui suit en hérite.

Le **formatage** suit la langue de l'appareil : `Format`
(`Sources/UI/Theme.swift`) pour les écrans, `DisplayFormat`
(`Sources/Model/`) pour ce que le modèle affiche lui-même. `FrenchUnits`, dans
`DiskCore`, **reste français** : c'est lui qui écrit les tables du `README.md`
et les bilans de `Tools/Measure`. `Format` ne lui emprunte que la conversion en
mégaoctets — le 2²⁰ du catalogue, sans quoi un disque étiqueté « 210 Mo » ne
retrouverait pas ses 210 à l'écran.

**Deux textes restent français exprès**, parce qu'ils ne vont nulle part dans
l'app et que les outils les relisent au mot près : le rapport de cache
(`BootSession.softwareCacheReport`, que `Tools/Measure/bilan.py` cherche sous
« dont N relues après éviction ») et le nom de système `MS-DOS 6.22 et Windows
3.1`, que `readme-tables.py` recopie dans la table des démarrages du
`README.md`. Le commentaire le dit sur place. Avant de traduire une chaîne du
modèle, vérifier qui la lit : `Tools/Shared/Report.swift` imprime le bilan que
les mesures analysent.

**Les tests vérifient la langue source.** Hors de l'app, `Bundle.main` est le
binaire de test et ne porte pas le catalogue : `String(localized:)` retombe sur
son `defaultValue`, donc sur l'anglais. Un test qui affirme un libellé —
`MapZoneTests`, `DaySessionTests`, `InstallSessionTests`, `DefragPlannerTests` —
l'affirme en anglais, et le dit en commentaire. Mieux vaut encore ne pas
dépendre de la langue du tout : `SoftwareCacheTests` lit le premier nombre du
rapport au lieu de compter les mots.

Les règles qui tiennent, quelle que soit la tranche :

- `Text("…")`, `Label("…")`, `Section("…")` et les étiquettes d'accessibilité
  prennent une `LocalizedStringKey` et se traduisent seules. Une **`String`
  passée à `Text`** ne se traduit pas — c'est l'initialiseur verbatim : la
  construire avec `String(localized:)` à la source, ou passer par
  `Text(verbatim:)` quand la valeur est une donnée (un nom de disque, un chiffre).
  `ScreenTitle` a deux initialiseurs pour cette raison : `subtitle:` prend une
  clé, `verbatimSubtitle:` une donnée.
- **Une vue d'aide qui prend un `String` ne traduit rien.** `StatTile`,
  `InstrumentTile`, `MetricTile` et les `row`/`single`/`line` des bilans
  reçoivent une valeur déjà résolue, donc un `String(localized:)` ; `ScreenTitle`,
  `LevelSlider`, `ExplanationRow`, `actionLabel`, `badge`, `legendDot` et
  `transportButton` prennent une `LocalizedStringKey`, donc une clé nue. Y passer
  une clé nue alors que le paramètre est un `String` compile sans broncher et
  affiche `pass.report.title` à l'écran.
- **Les capitales sont dans le catalogue**, pas dans un `.uppercased()` : cette
  méthode suit la locale de l'appareil et non celle du texte, et abîme quelques
  alphabets. Les en-têtes de section et les pastilles portent donc leur valeur
  déjà en capitales.
- **Ne jamais recoller une terminaison** (`"rangé" + (masculine ? "" : "e")`) :
  le français accorde, et le montage ne se traduit dans aucune autre langue.
  `ClusterCategory.spokenContent` porte pour cette raison une phrase entière
  par cas.
- **Ne jamais partager une clé entre deux sujets** : le français accorde, et un
  couple nom/verbe identique en anglais demande deux clés.
- Donner des variations de pluriel à toute clé qui porte un `%lld`, **dans les
  deux langues** — sans unité `en`, le singulier retombe sur la clé.
- Les clés courtes (onglets, étiquettes de `LabeledContent`, tuiles) partagent
  leur ligne avec une valeur : les garder près de la longueur de l'autre langue
  plutôt que de traduire littéralement.

`xcodebuild` compile le catalogue mais n'y écrit jamais de clé neuve : une clé
entre par le code. `SWIFT_EMIT_LOC_STRINGS` fait écrire un `.stringsdata` par
tranche d'architecture, d'où `./scripts/xcb.sh strings` tire les clés. Ce script
existe parce que `xcstringstool sync` a deux façons silencieuses de détruire un
catalogue, toutes deux traitées par lui : synchroniser une **copie** hors du
dépôt (elle ne résout aucune source, donc **toutes** les clés reviennent
`stale`, et les supprimer vide le catalogue), et ne passer que la **première**
tranche `.stringsdata` (une clé définie ailleurs paraît sortie du code, passe
`stale`, et le ménage suivant détruit une chaîne vivante).

Vérifier une traduction dans le simulateur :

```bash
xcrun simctl launch "$(source scripts/sim-config.sh && sim_udid)" \
  io.github.glandais.winchester -AppleLanguages "(en)" -AppleLocale en_US
```

### `i18n/translations.json`

**C'est la source de toutes les traductions** ; le catalogue et les métadonnées
du store en sont tirés. `scripts/i18n.py export` / `import` font l'aller-retour,
exact à l'octet (`scripts/i18n.py check` le prouve), si bien que le JSON peut
être modifié — ou confié à quelqu'un — puis reposé sans rien perdre des
variations de pluriel, des commentaires, des états d'extraction, de l'ordre des
clés ni du formatage.

**Ne jamais éditer un fichier généré à la main** : la modification survit
jusqu'au prochain `import`, puis disparaît. Et `import` fait autorité sur le jeu
de clés : une clé retirée du JSON disparaît du catalogue — ce qui retire une clé
périmée, mais détruit aussi une clé vivante par mégarde.

Le cycle d'une clé neuve : écrire le code, `./scripts/xcb.sh strings`,
`./scripts/i18n.py export`, remplir l'unité `en` et l'unité `fr`,
`./scripts/i18n.py import`.

## Publier

App Store Connect : app **`6814382619`**, nom `Winchester: Defrag Sounds` en
anglais et `Winchester : défragmentation` en français (le « Winchester » seul
est pris ; l'écran d'accueil garde `Winchester` par `CFBundleDisplayName`),
langue principale `en-US`, aussi `fr-FR`, bundle `io.github.glandais.winchester`
(la fiche avait d'abord été créée sur celui d'un autre projet : le vérifier par
`asc apps view --id 6814382619` avant le premier envoi d'un build). Nom et sous-titre tiennent en
**30 caractères** chacun, mots-clés en 100.

Les métadonnées canoniques vivent sous `./metadata/`, un fichier par portée et
par locale (`app-info/<locale>.json`, `version/<version>/<locale>.json`), tirées
de `i18n/translations.json` comme le catalogue : lancer `i18n.py import` avant
qu'`asc` ne lise un changement de formulation, et `i18n.py export` après tout
`asc metadata pull` (qui écrit ces fichiers depuis le store), sinon le prochain
`import` annule le pull.

Nom, sous-titre et mots-clés forment **un seul vivier indexé** : ne jamais y
répéter un mot, garder les mots-clés séparés par des virgules sans espaces et
près de 100 caractères, et ne pas nommer le produit d'une autre société
(directive 2.3.7).

Ne jamais `apply` sans avoir lu le plan :

```bash
asc metadata pull     --app 6814382619 --version "1.0.0" --dir "./metadata"
asc metadata validate --dir "./metadata"
asc metadata plan     --app 6814382619 --version "1.0.0" --dir "./metadata"
asc metadata approve  --review-dir ".asc/metadata/review" --all
asc metadata apply    --app 6814382619 --version "1.0.0" --dir "./metadata" \
                      --review-dir ".asc/metadata/review" --confirm
```

`asc metadata` ne couvre **pas** les notes pour la revue : elles vivent dans
`metadata/review-notes.md` et se poussent par `asc review details-update`. Les
garder vraies, une personne les lit avec l'app ouverte — celles-ci expliquent
pourquoi le mode d'arrière-plan `audio` est déclaré (une passe dure des dizaines
de minutes et doit continuer écran verrouillé), ce qu'attend la directive 2.5.4
du même genre.

L'archivage et l'export passent par `ExportOptions.plist`
(`app-store-connect`, équipe `7Q49262697`). `.asc/` garde l'état local d'`asc`
et n'est pas versionné.

L'app vise **iPhone et iPad** (`TARGETED_DEVICE_FAMILY: "1,2"`), si bien que
la fiche réclame deux jeux de captures : un grand iPhone et un iPad 13 pouces.

L'icône (`Sources/Resources/Assets.xcassets`, une seule image 1024×1024 sans
canal alpha) et `Sources/Resources/PrivacyInfo.xcprivacy` sont en place. Le
manifeste déclare ne rien pister et ne rien collecter, comme
`metadata/app-privacy.json`, et une seule API à raison déclarée :
`UserDefaults` (`CA92.1`), qui garde le mixage sonore et l'accueil déjà vu.
Sans lui, Apple renvoie ITMS-91053 à chaque envoi. Le relire dès qu'une autre
API de cette liste entre dans le code (dates de fichier, temps écoulé depuis le
démarrage, espace disque libre).

Ce qui manque encore avant une première soumission :

- le site que citent les trois adresses de `metadata/` — elles pointent vers
  `https://glandais.github.io/Winchester/`, qui n'existe pas ;
- les captures d'écran (iPhone et iPad), la classification d'âge, les
  catégories, la grille tarifaire et la disponibilité.
