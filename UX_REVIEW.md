# Audit du parcours : le cycle de vie d'un disque

Relecture du point de vue de l'utilisateur, pas du modèle : que devient un
disque quand on agit dessus, comment on s'y retrouve, et ce qu'on retrouve en
revenant. Les trois revues d'experts ont relu le modèle ; celle-ci regarde ce
que l'écran en dit.

Méthode : lecture du code de `develop`, puis le parcours rejoué sur le
simulateur (iPhone 17 Pro Max, iOS 26.5, build Debug de `a2af0e6`) le
19 septembre 2026. Tous les constats ont été revérifiés sur `d72aa81`
(lot 8) : ils tiennent, et les lignes citées sont celles de ce commit. Rien n'a été corrigé ici.

Parcours rejoué : accueil → « Développeur, 1993 » → Défragmenter → UltraDefrag
→ passe entendue jusqu'au bout (2 min 31) → bilan → retour à la fiche et à
l'accueil → Revivre → repère suivant → « Écouter le jour 13 » → Revivre rouvert
→ Instruments.

---

## 1. Le modèle tel que l'utilisateur le vit

Un disque est une **recette** (histoire, matériel, graine) refabriquée à
chaque ouverture. Les actions ne le modifient jamais : elles produisent des
**passes**, dont chacune laisse un **bilan** gardé en mémoire.

```
Accueil ─► Fiche (fabrication) ─► Défragmenter › choix de l'outil ─┐
   ▲           │  Démarrer / Installer ────────────────────────────┤─► onglet Passe ─► « Passe terminée » ─► Bilan
   │           └─ Revivre (plein écran) ─► « Écouter le jour N » ──┘                                        │
   └─────────── (aucun retour de la Passe vers la fiche) ◄── autre outil / disque rangé / disque installé ◄─┘
```

L'utilisateur, lui, pense « mon disque » : il l'a défragmenté, il s'attend à
le retrouver rangé. C'est l'écart central de cet audit.

## 2. Constats, du plus grave au moins grave

### 2.1 Un disque défragmenté ne le reste pas — *vu à l'écran*

UltraDefrag sur « Développeur, 1993 » : 321 → 2 fichiers fragmentés. De retour
sur la fiche, les tuiles disent toujours **16 % fragmentés**, et la carte est
celle d'avant. Sur l'accueil, la carte du disque dit « déjà généré · 16 %
fragmentés » (`DiskGallery.swift:183`) — l'état *avant*. La seule trace est la
ligne « UltraDefrag · 35 morceaux · 461 trous à la fin », tout en bas de la
fiche, sous « Plus de détails ». Le disque rangé n'existe que derrière un
bouton du bilan, « Démarrer ce disque rangé ».

### 2.2 Tout s'évapore au relancement — *code*

`SimulationModel.records` vit en mémoire, douze au plus
(`SimulationModel.swift:50`). Seules les recettes de « Mes disques »
survivent (`CustomDiskStore`). Au lancement suivant : ni historique, ni
pourcentage sur les cartes, et la Passe revient sur la démo de démarrage.

### 2.3 Le disque en cours n'est signalé nulle part hors de l'accueil — *vu à l'écran*

Pendant la défragmentation, puis pendant l'écoute du jour 13, la fiche du
disque qu'on écoute n'a **ni bandeau de lecture ni aucun signe** : le
mini-lecteur n'est posé que sur la racine de la pile de l'onglet Disques
(`DisksScreen.swift:62`), les écrans poussés en sont privés. Sur l'accueil, le
bandeau est là, mais aucune carte ne porte « en écoute ».

### 2.4 La Passe ne ramène pas au disque — *vu à l'écran*

Le nom du disque est en titre de l'onglet Passe, et ne se touche pas. Pour
retrouver la fiche, il faut deviner que l'onglet Disques a gardé sa pile. Le
sélecteur de scénarios a disparu de l'écran ; `SimulationModel.selections`
(`SimulationModel.swift:99`) et son cache n'ont plus de lecteur.

### 2.5 La suite n'est proposée que par le bilan, et le bilan se perd — *code*

- La carte « Passe terminée » ne vit que tant que la passe est la courante :
  « Relancer » ou tout autre lancement la fait disparaître.
- Un démarrage n'a pas de bilan : sa ligne dans l'historique ne s'ouvre pas
  (`DiskGallery.swift:274`). « Vieilli → rangé » ne s'enchaîne pas depuis
  l'historique.
- Le bilan d'une journée n'offre rien (`PassReport.swift:120`, `EmptyView`),
  alors que son commentaire promet de « rouvrir » le défilement.

### 2.6 Revivre repart toujours du jour 0 — *vu à l'écran*

Avancé jusqu'au jour 12, « Écouter le jour 13 », puis Revivre rouvert :
« JOUR 0 / 730 », « Écouter le jour 1 ». Le `DiskLifeModel` naît avec le plein
écran et meurt avec lui. Le commentaire « le défilement reprendra ensuite au
lendemain » (`SimulationModel.swift:171`) décrit ce qui ne se passe pas.

### 2.7 L'assistant — *code*

- « Fermer » après avoir fabriqué un brouillon non enregistré le perd sans
  demander.
- L'assistant partage `library.selectedID` avec la fiche ouverte en dessous :
  « Dupliquer et modifier » → « Fabriquer » → « Fermer », et la fiche d'origine
  montre le brouillon (`DiskLibraryView` lit `model.selected`, pas l'`id` de
  la fiche).

### 2.8 Une passe en remplace une autre sans prévenir — *code*

Un seul moteur : lancer une démo ou un disque pendant une passe la remplace,
sans confirmation.

## 3. Ce que l'écran dit du modèle

Aucun nombre n'est faux ; ce sont les libellés qui ne disent pas ce qu'ils
comptent. Diagnostic croisé avec la session du chantier `experts`.

| Vu à l'écran | Cause | Où |
|---|---|---|
| Phase 4 « Les derniers enregistrements de MFT et la bitmap du volume » sur un **FAT16** | Libellé en dur, sans condition de format — **vrai défaut**, sur les douze volumes FAT | `UltraDefragStrategy.swift:147`, `WindowsXPStrategy.swift:153`, `FragmentMergeStrategy.swift:91` |
| Fiche 4 016 fichiers, bilan « 4 027 fichiers » | Le bilan compte des éléments, répertoires compris (lot 4) | `GeneratedVolume.swift` |
| Fiche 16 % fragmentés, bilan « 8,0 % » | Rapporté aux fichiers fragmentables d'un côté, à tous de l'autre | `AllocationMetrics` |
| Fiche 210 Mo, Passe « 220 Mo · FAT16 » | Mo de 2²⁰ d'un côté, de 10⁶ de l'autre | `FrenchFormat.megabytes` (`Theme.swift:153`) contre `VolumeLayout.swift:175` |
| Passe « 49 Mo déplacés », bilan « 47 Mo » pour la même passe | Idem | `PassScreen.swift:345` et `:388` contre `FrenchFormat.megabytes` |
| Débit des Instruments | ÷ 10⁶ à la main | `InstrumentsScreen.swift:392`, `:402` |

Les deux conventions ne suivent pas les écrans mais les chemins de code :
`FrenchFormat` d'un côté, des divisions écrites à la main de l'autre. La
correction n'est pas de choisir entre Mio et Mo mais de **tout faire passer
par `FrenchFormat`** ; tant qu'un octet se convertit à deux endroits, l'écart
revient. Question laissée aux experts : si le générateur lit `"sizeMB": 210`
en Mio alors que les fiches d'époque annoncent des mégaoctets décimaux, le
disque simulé est 5 % plus grand que son étiquette — le décimal à l'affichage
le montrerait.

## 4. Détails vus en passant

- La tuile « Mo déplacés » dit encore « jusqu'ici » une fois la passe finie.
- « Répertoires » est dans la légende de la Passe, mais aucune case jaune ne se
  voit sur la carte en pouce, et la légende de la fiche ne la nomme pas : la
  catégorie du lot 4 n'a toujours pas été vue sur une carte.
- Au choix de l'outil, l'outil d'époque est présélectionné avec « de 8 min à
  1 h » : c'est le plus long qu'on propose d'abord.
- Instruments : « max 1,8 → 1,2 Mo/s » sous le débit ne se lit pas seul.

## 5. Ce qui marche

- Le bandeau de lecture sur l'accueil, Instruments et Réglages, et son état au
  retour d'arrière-plan.
- L'accueil d'onboarding qui se referme sur les disques ; « Lancer » qui
  démarre sans étape de plus.
- La pile de l'onglet Disques gardée pendant l'écoute.
- Le bilan : avant/après, une phrase qui explique, et la suite là où on la
  cherche (« Essayer un autre outil », « Démarrer ce disque rangé »).
- Les écrans du lot 7 (choix de l'outil, Instruments) : XP grisé avec sa
  raison, « Où passe le temps » et « Distance des seeks » lisibles.

## 6. Pistes, par priorité

1. **Donner un état au disque**, au moins pour la session : « Rangé par
   UltraDefrag · il y a 3 min » sur la carte et la fiche, et une bascule
   « d'origine / rangé » sur la carte du volume.
2. **Signaler le disque en cours** : bandeau sur les écrans poussés, marque
   « en écoute » sur sa carte.
3. **Relier la Passe à la fiche** : le titre du disque mène à sa fiche.
4. **Garder les bilans** d'un lancement à l'autre, résumés, sans leurs cartes.
5. **Garder Revivre** au-delà de son plein écran, et donner au bilan d'une
   journée son « Reprendre la vie du disque ».
6. **Le libellé MFT** conditionné au format ; **une seule conversion des
   octets**, par `FrenchFormat` ; des libellés qui disent ce qu'ils comptent
   (« fichiers » ou « éléments », « parmi les fragmentables »).
7. L'assistant : demander avant de perdre un brouillon fabriqué, et ne plus
   partager la sélection avec la fiche d'en dessous.

## 7. Laissé ouvert

- Mes disques, Installer, Démarrer, la comparaison de deux passes et le
  retour d'arrière-plan n'ont pas été rejoués à l'écran.
- VoiceOver n'a pas été passé sur le parcours.
- Le constat 2.2 (bilans perdus au relancement) est lu dans le code, pas
  observé.
