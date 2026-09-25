# Winchester

Simulation d'I/O au niveau bloc d'un disque dur à plateaux, convertie en son par
AVFAudio, dans une application iOS 17+ (SwiftUI, Swift 6). `README.md` est la
référence du projet : ce qui est modélisé, la chaîne, les vingt-quatre disques
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
puis `SCENARIO=<id> /tmp/rendertrace out.wav`, et comparer les `md5` — ou, pour
tout un chantier, `Tools/Measure/` (`snapshot.sh`, `run.sh <étape> full`,
`compare.py --identical`, `wav-md5.py`), décrit dans le `README.md`.

Deux suites ne tournent pas d'office. **`Calibration`** est sautée en Debug :
`swift test -c release --filter CalibrationTests`, ou `DISKCORE_CALIBRATION=1`
en Debug. **`GalleryAllocationAudit`** ne tourne qu'avec
`DEFRAG_GALLERY_AUDIT` (`=1` pour les vingt-quatre volumes, ou une liste de
profils), en Release : une vingtaine de minutes. Les chantiers 49 à 51, qui
touchaient allocateur et stratégies, les ont lancées toutes les deux.

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
cette machine, mais il y fonctionne mal : ne pas s'en servir.
`WINCHESTER_SIM_DEVICE` bascule d'appareil pour une session entière
— exporté dans l'environnement, pas préfixé sur une commande, sinon le hook ne
le voit pas. `WINCHESTER_DERIVED_DATA` déplace le dossier de construction.

Un `iPad Pro 13-inch (M4)` (iOS 26.5, `IPAD_DEVICE` dans le même fichier)
n'existe que pour les captures de l'App Store : seul `scripts/screenshots.sh`
le démarre, après avoir éteint tout autre simulateur, et l'éteint en partant
en rallumant l'iPhone. Ne pas le démarrer à la main.

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
  `Tools/build-render.sh`, sans quoi le rendu hors-ligne ne compile plus — et
  `swift test` n'en dit rien, puisque le paquet prend tout le dossier. Pour
  Xcode, `./scripts/xcb.sh gen` : le `.xcodeproj` d'un worktree n'est pas
  versionné et ne voit pas le fichier neuf avant d'être régénéré.

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
- les **vingt-quatre disques d'époque**, dont le nom et le résumé vivent dans les JSON
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
mégaoctets — le 2²⁰ du système de fichiers : un disque étiqueté « 210 Mo »
(décimaux, `DiskSpec.sizeMB`) en montre 200 une fois formaté, comme CHKDSK le
faisait, et c'est l'étiquette que la galerie affiche.

**Deux textes restent français exprès**, parce que les outils les relisent au
mot près : le rapport de cache (`BootSession.softwareCacheReport`, que
`Tools/Measure/bilan.py` cherche sous « dont N relues après éviction »), qui ne
va nulle part dans l'app, et le nom de système `MS-DOS 6 et Windows 3.1`, que
`readme-tables.py` recopie dans la table des démarrages du `README.md`. Ce nom-là
**s'affiche**, lui, tel quel et « et » compris, même en anglais : carte de la
galerie, « Mes disques », titre de la passe, centre de contrôle, et
l'assistant, qui le propose sous le même nom (`SystemOption`). Le commentaire
de `BootScript.Era` dit pourquoi il reste français ; le traduire à l'affichage
reste à faire. Avant de traduire une chaîne du
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

Le build 2 (1.0.0) est le premier build TestFlight, envoyé le 21 septembre
2026 ; le build 3, du même jour, l'a remplacé sur la version (vibrations tues
sur l'iPad, tuiles alignées), et le build 4, du même jour, a remplacé le 3
pour porter 2012 (chantiers 33 et 34). Le build 1 a été refusé à l'envoi (erreur
90474) : le multitâche de l'iPad exige les quatre orientations, d'où les deux clés
`UISupportedInterfaceOrientations_iPhone` et `_iPad` de `project.yml`. Un envoi
refusé consomme quand même son numéro : `asc builds next-build-number --app
6814382619 --platform IOS` donne le suivant. Le groupe TestFlight **Internal**
(`21d0297a-b842-4385-8ffd-54a2127412ff`) est interne et a accès à tous les
builds : un build traité y arrive tout seul. Les notes « À tester » s'écrivent en
`en-US` et en `fr-FR`.

Archiver, exporter, envoyer (`generic/platform=iOS` ne démarre aucun simulateur,
le hook le laisse passer) :

```bash
swift test
xcodebuild -project Winchester.xcodeproj -scheme Winchester -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Winchester.xcarchive \
  -derivedDataPath .build/DerivedData -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/Winchester.xcarchive \
  -exportPath build/export -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates
asc builds upload --app 6814382619 --ipa build/export/Winchester.ipa --wait
```

Posé sur le store le 21 septembre 2026 : métadonnées en `en-US` et `fr-FR`
(deux `apply`, voir plus bas), version renommée `1.0` → `1.0.0` avec le
copyright « 2026 Gabriel Landais », build 4 rattaché, détails de revue (contact
et `review-notes.md`), classification 4+ (tout à `NONE`), catégories
Divertissement puis Musique, pas de contenu tiers, gratuit, 174 territoires
(la Chine continentale exclue : elle exige un dépôt ICP), App Privacy publiée
en « Données non collectées ». Distribution **Mac (puce Apple) gardée, Apple
Vision Pro décochée** — Apple coche les deux d'office, ce choix se vérifie dans
Tarifs et disponibilité.

Pièges rencontrés :

- `whatsNew` n'existe pas sur une première version : il n'est pas dans
  `metadata/version/1.0.0/`, et n'y entre qu'à la version suivante.
- Ajouter une langue demande **deux** `apply` : créer la localisation
  `app-info` fait créer par App Store Connect celle de la version, et la moitié
  version du même plan revient en erreur (« already been used »). Refaire le
  plan et appliquer une seconde fois.
- `asc validate` ne regarde ni le prix ni la distribution Mac/Vision Pro : les
  vérifier dans le navigateur.
- `asc web privacy` passe par une session web qui expire et demande un code
  2FA ; la déclaration s'est faite dans le navigateur.

Le **site** que citent les trois adresses de `metadata/` (marketing, support,
confidentialité) vit dans `docs/` et se sert par GitHub Pages depuis ce dossier
sur la branche par défaut (`develop`) : `docs/index.html`, `docs/support/`,
`docs/privacy/`, plus `docs/how-it-works/`. HTML et CSS statiques, sans
JavaScript, sans police ni ressource externe ; liens relatifs à `index.html`
explicite, pour marcher sous le sous-chemin `/winchester/` comme en `file://`.
L'adresse est `https://glandais.github.io/winchester/`, **en minuscules** :
Pages suit la casse du dépôt, et `/Winchester/` répond 404.
Il est **en anglais seul, exprès**, comme celui de WhereIWas. Le garder vrai :
chaque libellé cité est celui de l'unité `en` du catalogue, et la page
confidentialité doit suivre `Sources/Resources/PrivacyInfo.xcprivacy` et
`metadata/app-privacy.json` — une donnée gardée de plus, une autorisation, un
accès réseau, et elle change avec sa date d'effet.

**Pourboires : le modèle est DepthWeaver 1.2.1**, validé par Apple. Dans
l'app, trois achats intégrés (Réglages → « Support Winchester »), sans aucun
lien de don externe ; sur le site, seule la page confidentialité en parle.
Ko-fi n'apparaît **que** dans le pied des pages du site (« Buy me a coffee »)
et dans le `README.md` — jamais dans l'app ni dans les notes de revue.

### Captures

Trois temps, tous scriptés, décrits dans `screenshots/README.md` :

```bash
./scripts/screenshots.sh                     # captures brutes, iPhone et iPad, en et fr
kou generate screenshots/koubou/iphone.yaml  # cartes Koubou (cadre, titre)
kou generate screenshots/koubou/ipad.yaml
./screenshots/assemble.sh                    # -> screenshots/IPHONE_65/ et IPAD_PRO_3GEN_129/
```

La configuration **`Screenshots`** (un Debug avec la condition `SCREENSHOTS`) et
son schéma `Winchester-Screenshots` sont les seuls à compiler le mode capture
(`Sources/Screenshots/`, et quelques `#if SCREENSHOTS`) : rien n'en entre dans
l'archive. Ne rien lancer d'autre sur le simulateur pendant une capture —
`xcb.sh run` installerait l'app Debug par-dessus, sous le même identifiant. Les
titres des cartes se traduisent par `i18n/translations.json` (table `Koubou`),
dont les clés sont la phrase anglaise elle-même.

Les vingt-quatre captures sont envoyées depuis le 21 septembre 2026 (six
écrans × deux langues × `IPHONE_65` et `IPAD_PRO_3GEN_129`), et `asc validate`
ne remontait plus aucune erreur le 21 septembre 2026. **La 1.0.0 n'est pas
prête à être soumise** : le build 4 ne porte ni la section « À propos »
(chantier 37) ni les pourboires (chantier 38), dont les trois achats intégrés
partent avec la version ; il faut un nouveau build, fait après la fusion de la
branche `xp` (chantiers 47 à 52, `LEDGER-XP.md`, puis 53 : les pourboires
dits partout, B#31 à B#34, B#36 et B#45 d'`AUDIT_REALISME.md`) dans
`develop`. Avant la soumission reste à pousser les notes de revue
(`asc review details-update`). L'envoi prend
parfois une erreur 500 d'App Store Connect sur un fichier : relancer le même `asc screenshots upload` avec `--skip-existing`, qui
ne renvoie que ce qui manque.

### App previews

Une vidéo de 29,5 s par appareil et par langue, en tête de la fiche, la seule
chose du store qui fasse entendre le disque :

```bash
./scripts/previews.sh                        # iPhone et iPad, en et fr (~25 min)
./scripts/previews.sh --iphone en-US         # un jeu seul (~5 min)
```

L'image est filmée dans l'app (`simctl io recordVideo`, par
`scripts/sim-record.py`), le son vient de `RenderTrace` (`SCENARIO=defrag`),
aux mêmes secondes de passe : la démo est déterministe, et le simulateur, qui
ne filme pas le son, partage l'horloge du Mac. Le témoin de `ScreenshotMode`
porte pour cela l'instant où la lecture part. Les plans sont décrits dans
`previews/montage.txt` ; Remotion (`previews/remotion/`, Node) les monte avec
les titres des cartes Koubou, l'invitation « Turn the sound on » (même table
`Koubou`) et une carte de fin. Apple n'accepte que des images de l'app : les
vidéos de `Tools/RenderVideo`, redessinées, n'y ont pas leur place.

**Rien n'est versionné** de ce qui sort : `previews/out/<IPHONE_65|IPAD_PRO_3GEN_129>/<locale>/01-defrag.mp4`
se refait à l'identique, et App Store Connect garde l'exemplaire envoyé
(`asc video-previews download`). `screenshots.sh` et `previews.sh` partagent
`scripts/sim-capture.sh` (un simulateur à la fois, langue du système, barre
d'état) : ne rien lancer d'autre sur le simulateur pendant l'un ou l'autre.

La synchronisation se vérifie en corrélant le mouvement du bras du plan
`platter` aux attaques du son : entre -20 et +5 ms sur les vidéos finales,
pour une image de 33 ms. `LATENCY` dans le script porte les 40 ms de retard d'affichage mesurés.

Envoi, quatre fois (`--version-localization` est l'identifiant rendu par
`asc localizations list --version <VERSION_ID> --locale <locale>`, pas le code
de langue) :

```bash
asc video-previews upload --version-localization <ID> \
  --path previews/out/IPHONE_65/en-US --device-type IPHONE_65 --dry-run
asc video-previews upload --version-localization <ID> \
  --path previews/out/IPHONE_65/en-US --device-type IPHONE_65 --skip-existing
asc video-previews set-poster-frame --id <PREVIEW_ID> --time-code "00:00:02:00"
```

L'App Store joue la vidéo **sans le son** : le premier plan doit tenir seul, et
l'affiche se choisit à 2 s, titre posé. Les médias d'une version se figent
quand elle part en revue : une vidéo pour la 1.0.0 s'envoie avant de soumettre,
sinon elle attend la version suivante.

Les quatre vidéos sont envoyées depuis le 21 septembre 2026, affiche à 2 s
(Apple la pose d'office à 5 s, titre déjà parti), et `asc validate` ne remonte
aucune erreur. Pour les renvoyer : `--replace --confirm` au lieu de
`--skip-existing`, puis reposer l'affiche.
