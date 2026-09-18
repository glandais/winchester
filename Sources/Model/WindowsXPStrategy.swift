import Foundation
import DiskCore

/// La passe du **défragmenteur intégré de Windows XP**, puis de Vista : le
/// `dfrg.msc` dérivé de Diskeeper Lite, seul outil qu'un utilisateur de 2003 ou
/// de 2007 avait réellement sous la main.
///
/// Ce n'est pas une version modernisée de la passe de Windows 95, c'est un
/// autre métier. Là où l'outil de 95 range *le volume*, celui de XP répare
/// *les fichiers cassés* et ne touche à rien d'autre. Quatre différences, et
/// toutes les quatre s'entendent :
///
/// - **il ne visite que les fichiers réellement fragmentés.** Pas de frontière
///   qui avance, pas d'ordre de parcours à respecter. Sur un volume de 2007,
///   cela fait quelques centaines de fichiers sur des dizaines de milliers — et
///   c'est toute la différence entre une passe de quelques dizaines de minutes
///   et les dizaines d'heures que coûte le tassage de Windows 95 (le README les
///   compare, volume par volume) ;
/// - **il n'évacue personne.** La destination d'un fichier est un trou déjà
///   libre ; si aucun trou ne convient, le fichier reste en morceaux et finit
///   dans le rapport de fin de passe, sous « fichiers qui n'ont pas pu être
///   défragmentés ». Le va-et-vient qui faisait le tempo d'une passe FAT
///   disparaît complètement : ici, un fichier est lu une fois et écrit une
///   fois ;
/// - **le bras ne revient pas au cluster 0.** Valider un déplacement sur NTFS,
///   c'est réécrire un enregistrement de MFT — un kilo-octet, là où il a été
///   alloué — et un secteur de `$Bitmap`. Ni table à mettre à jour en double,
///   ni entrée de répertoire au bord du plateau. C'est
///   `PartitionGeometry.commitAccesses(forCluster:fileIndex:)` qui porte cette
///   différence, et elle suffit à changer la couleur de la passe ;
/// - **la granularité du déplacement n'est pas celle d'un tampon utilisateur.**
///   `FSCTL_MOVE_FILE` confie la copie au système de fichiers, qui travaille
///   par gros blocs (voir `bufferBytes`).
///
/// Deux fichiers lui échappent, et c'est historique et non pratique : le
/// fichier d'échange, que Windows tient ouvert, et la MFT elle-même, que le
/// défragmenteur de XP ne savait pas réorganiser à chaud — il fallait un
/// traitement au démarrage, que cet outil-là n'avait pas.
///
/// Sa faiblesse se mesure : il échoue quand aucun trou n'est à la taille, et il
/// laisse alors le fichier en morceaux. Attention à la conclusion trop facile —
/// **ce n'est pas le taux de remplissage qui décide**. `dev-2003` et
/// `secretaire-2003` sont deux volumes de 40 Go remplis à 94–95 %, et ils ne
/// laissent pas la même part de leurs fichiers cassés en morceaux (table
/// « Passe de XP sur NTFS » du README). Un volume plein garde des trous, mais
/// pas de *grands* trous : c'est la taille de ce qu'il y a à réparer qui
/// décide.
///
/// Réserve : c'est une hypothèse tant que les échecs ne sont pas comptés par
/// taille. Les chiffres qui la soutenaient ici ne correspondaient plus au
/// générateur après la relecture des experts, et ont été retirés plutôt que
/// rafraîchis : un docstring ne se régénère pas, le README si.
///
/// Sur NTFS, ce qu'il quitte n'est libre qu'au point de contrôle suivant, que
/// Windows fait toutes les cinq secondes (`NTFSCheckpoints`) : le bitmap qu'il
/// relit à chaque fichier le montre occupé d'ici là. Un gros fichier se
/// déplace en plus de cinq secondes, et la règle ne mord que sur les petits,
/// déplacés à la suite.
struct WindowsXPStrategy: DefragStrategy {

    let id = "windowsXP"
    let label = "Défragmenteur de Windows XP"

    /// Taille d'un bloc de déplacement.
    ///
    /// Le défragmenteur ne recopie pas lui-même la donnée : il appelle
    /// `FSCTL_MOVE_FILE`, et c'est le système de fichiers qui déplace, par
    /// blocs bien plus gros que les quelques centaines de kilo-octets d'un
    /// tampon utilisateur de 1995. Reste à fixer « bien plus gros ».
    ///
    /// La seule valeur citable vient d'UltraDefrag, qui dimensionne son bloc
    /// sur la capacité du volume (`adjust_move_at_once_parameter`,
    /// `src/dll/udefrag/analyze.c:90-117`) : 256 Ko en dessous de 20 Go, 64 Mo
    /// au-delà de 2 To. La règle qu'il applique est ergonomique — qu'un bloc se
    /// termine assez vite pour qu'on puisse interrompre la passe en une
    /// demi-seconde. Les volumes NTFS de la galerie font 40 à 320 Go, c'est-à-
    /// dire le milieu de cette échelle, et 4 Mo y tombent juste : à la
    /// quarantaine de mégaoctets par seconde que soutient un disque de 2003,
    /// un bloc de 4 Mo passe en moins de 100 ms, très en deçà de la
    /// demi-seconde.
    ///
    /// Physiquement, un bloc reste une lecture suivie d'une écriture : ce
    /// réglage ne change pas la nature des requêtes, seulement leur taille —
    /// donc le nombre de seeks, donc le grain de la passe.
    var bufferBytes = 4 * 1024 * 1024

    /// L'outil de XP ne range rien dans la zone réservée à la MFT.
    ///
    /// **C'est une hypothèse**, et la moins mauvaise des deux. Aucune source ne
    /// dit ce que faisait `dfrg.msc` ; la relecture de défragmentation
    /// (`DEFRAG_REVIEW.md` §5) pense qu'il ne la respectait pas, parce que
    /// l'API autorise l'écriture dans la zone et que le noyau la cède de
    /// lui-même au-delà de ~87 % de remplissage. Deux choses font pencher dans
    /// l'autre sens :
    ///
    /// - l'API donne les bornes de la zone aux défragmenteurs
    ///   (`FSCTL_GET_NTFS_VOLUME_DATA`, `MftZoneStart` et `MftZoneEnd`), et ceux
    ///   de NT 4.0 — Diskeeper, dont `dfrg.msc` est la version allégée — s'en
    ///   servaient pour l'« identifier » (Russinovich, *Inside Windows NT Disk
    ///   Defragmenting*, 1997) ;
    /// - UltraDefrag, qui s'en sert, le justifie par sa propre routine
    ///   d'optimisation de la MFT (`analyze.c:259-261` : « Since we have MFT
    ///   optimization routine, let's use MFT zone for files placement ») —
    ///   routine que l'outil de XP n'avait pas (voir `canTouch`).
    ///
    /// Le modèle garde donc le comportement d'avant la relecture, et le dit
    /// hypothèse. La zone qui a cédé au générateur, elle, est déjà plus petite :
    /// `mftZone` est la zone du moment, pas celle du formatage.
    static let avoidsMFTZone = true

    /// Déplacer par blocs pleins (`DefragOperations.gatheredMove`) au lieu de
    /// couper chaque tampon aux bornes des extents.
    ///
    /// Ce n'est pas le comportement modélisé de l'outil, et c'est désactivé par
    /// défaut : l'option sert à comparer les algorithmes à primitive égale avec
    /// `FragmentMergeStrategy`, qui déplace toujours ainsi. Elle raccourcit les
    /// passes sans changer ce qu'elles laissent, au point de contrôle près : une
    /// passe plus courte ne voit pas tomber ses points de contrôle aux mêmes
    /// déplacements. Le README en donne la mesure sur les huit volumes NTFS
    /// (« Recollage économe »).
    var fullBlocks = false

    /// L'ordre dans lequel les fichiers cassés sont visités.
    ///
    /// L'outil de XP suit la MFT, et c'est le réglage par défaut. Les autres
    /// ordres sont ceux des outils voisins, rejoués **avec le même placement** :
    /// c'est ce qui permet de mesurer ce que coûte un ordre de passage seul,
    /// sans qu'un algorithme de placement différent vienne brouiller l'écart.
    var order: Order = .mftRecord

    enum Order: String, CaseIterable, Sendable {
        /// Les numéros d'enregistrement de la MFT — l'outil de XP.
        case mftRecord
        /// Le plus fragmenté d'abord, départagé par le chemin — UltraDefrag.
        case mostFragmented
        /// La position du premier cluster sur le disque — `Defragment` de
        /// JkDefrag, figé à l'ordre de départ.
        case diskPosition
        /// Le parcours de l'arborescence — le défragmenteur de Windows 95.
        case directoryWalk
    }

    /// Le découpage de l'écran de XP, et il n'en a que trois : analyser,
    /// défragmenter, rendre compte. Pas de \WINDOWS ni de \PROGRA~1 — cet
    /// outil-là ne parcourt pas l'arborescence, il lit la liste des fichiers
    /// cassés et la traite.
    let phases: [PhaseDescriptor] = [
        PhaseDescriptor(id: "analyse", label: "Analyse du volume",
                        detail: "Lecture de la MFT : quels fichiers sont en morceaux, et où sont les trous"),
        PhaseDescriptor(id: "defrag", label: "Défragmentation des fichiers",
                        detail: "Chaque fichier cassé relu d'un bout à l'autre, réécrit d'un seul tenant"),
        PhaseDescriptor(id: "commit", label: "Écriture des métadonnées",
                        detail: "Les derniers enregistrements de MFT et la bitmap du volume"),
        PhaseDescriptor(id: "done", label: "Terminé",
                        detail: "Le rapport liste ce qui est resté en morceaux, faute de trou assez grand"),
    ]

    func plan(volume input: DefragVolume, into sink: OperationSink) -> DefragPlan {

        var volume = input
        let partition = volume.partition
        let before = volume.stats
        let initialRuns = volume.categoryRuns()

        var movedClusters = 0
        var filesMoved = 0
        var alreadyInPlace = 0
        var checkpoints = NTFSCheckpoints()

        // MARK: Phase 0 — analyse

        DefragOperations.analysis(partition: partition,
                                  directoryCount: DefragOperations.directoryCount(of: volume),
                                  into: sink)

        // MARK: Phase 1 — les fichiers cassés, et eux seuls

        // L'ordre est celui de la MFT, c'est-à-dire des numéros
        // d'enregistrement : c'est ainsi que l'outil énumère le volume, et non
        // par répertoire — il n'a pas parcouru l'arborescence pour en arriver
        // là. Deux fichiers voisins dans la MFT ont été créés à peu près en
        // même temps, donc alloués à peu près au même endroit : la passe avance
        // globalement dans un sens, avec des retours en arrière.
        let candidates = volume.files.indices
            .filter { canTouch(volume.files[$0]) }
            .sorted { order.precedes(volume.files[$0], volume.files[$1]) }

        for (rank, position) in candidates.enumerated() {
            let file = volume.files[position]
            sink.progress = Double(rank) / Double(candidates.count)

            // Déjà d'un seul tenant : rien à faire, et surtout rien à lire. Un
            // volume NTFS de 2007 est dans ce cas à 98 %, et c'est pour cela
            // que la passe est courte.
            guard !file.isContiguous else {
                alreadyInPlace += 1
                continue
            }

            // Un répertoire FAT : `FSCTL_MOVE_FILE` refuse d'en déplacer le
            // premier cluster, et l'outil déplace les fichiers entiers. L'appel
            // échoue sans rien copier, le répertoire reste en morceaux.
            guard volume.moveFileAccepts(position, fromVCN: 0) else { continue }

            // Un trou libre assez grand, le premier venu depuis le début du
            // volume — `FindGap(MinimumLcn: 0, FindHighestGap: NO)`. Il est par
            // construction disjoint des extents du fichier, puisqu'il est
            // libre : aucun recouvrement à gérer, et aucun occupant à évacuer.
            guard let target = DefragOperations.firstGap(in: volume, need: file.clusterCount,
                                                         avoidingMFTZone: Self.avoidsMFTZone) else {
                // Aucun trou à la taille : le fichier reste en morceaux. C'est
                // exactement ce que faisait l'outil — il n'a jamais déplacé
                // personne pour se faire de la place.
                continue
            }

            DefragOperations.move(source: file.extents, destination: [target],
                                  category: file.category, contiguous: true, phase: 1,
                                  partition: partition, bufferBytes: bufferBytes,
                                  fullBlocks: fullBlocks, into: sink)
            DefragOperations.commit(cluster: Int(target.start), fileIndex: volume.mftRecord(of: position),
                                    entrySector: volume.entrySector(of: position),
                                    phase: 1, partition: partition, into: sink)
            // Ce que le fichier quitte n'est libre qu'au point de contrôle
            // suivant, et le bitmap que l'outil relit pour chercher le trou du
            // fichier suivant le montre occupé d'ici là.
            if volume.releaseWaitsForCheckpoint {
                volume.relocateHoldingReleased(position, to: [target])
            } else {
                volume.relocate(position, to: [target])
            }
            checkpoints.afterCommit(&volume, sink: sink)
            movedClusters += Int(file.clusterCount)
            filesMoved += 1
            sink.moves.filesMoved = filesMoved
        }

        // MARK: Phase 2 — la MFT et la bitmap, une dernière fois

        // Le bilan est celui d'un volume revenu au repos, le dernier point de
        // contrôle passé.
        volume.releaseHeldClusters()
        sink.progress = 1
        DefragOperations.final(partition: partition, phase: 2, into: sink)

        return DefragPlan(
            strategy: self,
            partition: partition,
            initialRuns: initialRuns,
            operations: [],
            mutations: [],
            phases: phases,
            before: before,
            after: volume.stats,
            movedBytes: movedClusters * partition.clusterBytes,
            filesMoved: filesMoved,
            filesAlreadyInPlace: alreadyInPlace,
            // Le chiffre qui dit tout de cette stratégie : elle ne déloge
            // personne. Sur FAT, la même passe en comptait deux fois plus que
            // de fichiers déplacés.
            evacuations: 0,
            arrangement: volume.arrangement
        )
    }

    /// Les deux chiffres qui comptent ici sont ceux que l'outil affichait
    /// lui-même : ce qu'il a réparé, et ce qu'il a dû laisser en morceaux faute
    /// de trou à la taille. Le nombre d'évacuations, lui, ne vaut d'être dit
    /// que parce qu'il est nul.
    func summary(of plan: DefragPlan) -> String {
        let repaired = plan.before.fragmentedFiles - plan.after.fragmentedFiles
        var text = String(format: "La passe répare %d fichiers sur %d et n'évacue personne : "
                          + "chacun est recopié dans un trou déjà libre, jamais aux dépens "
                          + "d'un voisin.",
                          repaired, plan.before.fragmentedFiles)
        if plan.after.fragmentedFiles > 0 {
            text += String(format: " %d restent en morceaux, faute d'un trou assez grand — "
                           + "c'est ce que l'outil listait en fin de passe.",
                           plan.after.fragmentedFiles)
        }
        return text
    }

    // MARK: - Ce à quoi l'outil a le droit de toucher

    /// Le fichier d'échange est ouvert par Windows, et la MFT — comme les
    /// autres fichiers de métadonnées — ne se réorganise pas à chaud : le
    /// défragmenteur de XP les signalait dans son rapport et passait son
    /// chemin.
    private func canTouch(_ file: DefragFile) -> Bool {
        file.isMovable && file.category != .reserved && file.clusterCount > 0
    }
}

extension WindowsXPStrategy.Order {

    /// Un ordre total : chaque critère est départagé jusqu'à l'identifiant,
    /// sans quoi le tri — donc le son — dépendrait de l'implémentation de
    /// `sorted`.
    func precedes(_ a: DefragFile, _ b: DefragFile) -> Bool {
        switch self {
        case .mftRecord:
            return a.id < b.id
        case .mostFragmented:
            if a.fragmentCount != b.fragmentCount { return a.fragmentCount > b.fragmentCount }
            if a.path != b.path { return a.path < b.path }
            return a.id < b.id
        case .diskPosition:
            let left = a.firstCluster ?? .max, right = b.firstCluster ?? .max
            if left != right { return left < right }
            return a.id < b.id
        case .directoryWalk:
            if a.walkOrder != b.walkOrder { return a.walkOrder < b.walkOrder }
            return a.id < b.id
        }
    }
}
