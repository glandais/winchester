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
///   qui avance, pas d'ordre de parcours à respecter. Sur le 320 Go de
///   `famille-2007`, cela fait 244 fichiers au lieu de 12 220 — et c'est toute
///   la différence entre une passe de quelques minutes et les quatre-vingt-
///   quatorze heures que coûtait le tassage ;
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
/// `secretaire-2003` sont deux volumes de 40 Go remplis à 94 % : le premier
/// répare 260 fichiers sur 299, le second 57 sur 141. Ce qui les sépare est la
/// taille de ce qu'il y a à réparer — 11 Mo par fichier déplacé contre 21, et
/// 213 Mo sur le 320 Go de `famille-2007`, qui n'en répare qu'un tiers. Un
/// volume plein garde des trous, mais pas de *grands* trous.
///
/// Réserve : cette taille moyenne est celle des fichiers effectivement
/// déplacés, pas de ceux qui sont restés fragmentés. La corrélation est nette,
/// le mécanisme reste une hypothèse tant que les échecs ne sont pas comptés par
/// taille.
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

    func plan(volume input: DefragVolume) -> DefragPlan {

        var volume = input
        let partition = volume.partition
        let total = UInt32(partition.clusterCount)
        let before = volume.stats
        let initialMap = volume.categoryMap()

        var operations: [DiskOperation] = []
        var mutations: [MapMutation] = []
        var movedClusters = 0
        var filesMoved = 0
        var alreadyInPlace = 0

        // MARK: Phase 0 — analyse

        operations.append(contentsOf: DefragOperations.analysis(
            partition: partition,
            directoryCount: DefragOperations.directoryCount(of: volume)))

        // MARK: Phase 1 — les fichiers cassés, et eux seuls

        // L'ordre est celui de la MFT, c'est-à-dire des numéros
        // d'enregistrement : c'est ainsi que l'outil énumère le volume, et non
        // par répertoire — il n'a pas parcouru l'arborescence pour en arriver
        // là. Deux fichiers voisins dans la MFT ont été créés à peu près en
        // même temps, donc alloués à peu près au même endroit : la passe avance
        // globalement dans un sens, avec des retours en arrière.
        let candidates = volume.files.indices
            .filter { canTouch(volume.files[$0]) }
            .sorted { volume.files[$0].id < volume.files[$1].id }

        for position in candidates {
            let file = volume.files[position]

            // Déjà d'un seul tenant : rien à faire, et surtout rien à lire. Un
            // volume NTFS de 2007 est dans ce cas à 98 %, et c'est pour cela
            // que la passe est courte.
            guard !file.isContiguous else {
                alreadyInPlace += 1
                continue
            }

            // Un trou libre assez grand, le premier venu depuis le début du
            // volume — `FindGap(MinimumLcn: 0, FindHighestGap: NO)`. Il est par
            // construction disjoint des extents du fichier, puisqu'il est
            // libre : aucun recouvrement à gérer, et aucun occupant à évacuer.
            guard let target = firstGap(in: volume, need: file.clusterCount,
                                        total: total, avoiding: volume.mftZone) else {
                // Aucun trou à la taille : le fichier reste en morceaux. C'est
                // exactement ce que faisait l'outil — il n'a jamais déplacé
                // personne pour se faire de la place.
                continue
            }

            DefragOperations.move(source: file.extents, destination: [target],
                                  category: file.category, phase: 1,
                                  partition: partition, bufferBytes: bufferBytes,
                                  into: &operations, mutations: &mutations)
            DefragOperations.commit(cluster: Int(target.start), fileIndex: position,
                                    phase: 1, partition: partition, into: &operations)
            volume.relocate(position, to: [target])
            movedClusters += Int(file.clusterCount)
            filesMoved += 1
        }

        // MARK: Phase 2 — la MFT et la bitmap, une dernière fois

        operations.append(contentsOf: DefragOperations.final(partition: partition, phase: 2))

        return DefragPlan(
            strategy: self,
            partition: partition,
            initialMap: initialMap,
            operations: operations,
            mutations: mutations,
            phases: phases,
            before: before,
            after: volume.stats,
            movedBytes: movedClusters * partition.clusterBytes,
            filesMoved: filesMoved,
            filesAlreadyInPlace: alreadyInPlace,
            // Le chiffre qui dit tout de cette stratégie : elle ne déloge
            // personne. Sur FAT, la même passe en comptait deux fois plus que
            // de fichiers déplacés.
            evacuations: 0
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

    // MARK: - Placement

    /// Le premier trou d'au moins `need` clusters, depuis le début du volume,
    /// en dehors de la zone réservée à la MFT.
    ///
    /// La recherche repart de zéro à chaque fichier, et ce n'est pas une
    /// négligence : c'est ce que fait `FindGap`, qui relit le bitmap du volume
    /// à chaque appel plutôt que de le mettre en cache. La conséquence est
    /// visible sur la carte — les fichiers réparés se regroupent vers l'avant,
    /// dans les trous que la passe vient elle-même d'ouvrir — et le coût reste
    /// modeste : quelques centaines de fichiers, pas quelques milliers.
    ///
    /// `limit: need` est ce qui évite le piège quadratique : on ne mesure
    /// jamais un trou au-delà de la taille cherchée. Sur un volume presque
    /// vide, le premier trou fait la taille du disque.
    ///
    /// La zone MFT est libre dans la bitmap, et c'est précisément le piège :
    /// sur un volume de 320 Go elle fait quarante gigaoctets d'un seul tenant,
    /// donc le plus grand trou du volume et de très loin. Un défragmenteur qui
    /// l'ignore y range le premier gros fichier cassé venu et condamne la MFT
    /// à se fragmenter dès la prochaine création de fichier. On la saute, comme
    /// le fait `FindGap` avec ses `MftExcludes`.
    private func firstGap(in volume: DefragVolume, need: UInt32,
                          total: UInt32, avoiding mftZone: Range<UInt32>?) -> Extent? {
        var cursor: UInt32 = 0
        while cursor < total {
            guard let run = volume.bitmap.nextFreeRun(from: cursor, limit: need) else { return nil }

            // Un trou qui mord sur la zone MFT est tronqué à ce qui la précède,
            // et la recherche reprend derrière elle.
            if let zone = mftZone, run.start < zone.upperBound, run.start + run.length > zone.lowerBound {
                if run.start < zone.lowerBound, zone.lowerBound - run.start >= need {
                    return Extent(start: run.start, length: need)
                }
                cursor = max(zone.upperBound, run.start + run.length)
                continue
            }

            if run.length >= need { return Extent(start: run.start, length: need) }
            // Le trou est plus court que demandé : `limit` n'a pas tronqué la
            // mesure, il est bien maximal, on peut sauter par-dessus.
            cursor = run.start + run.length
        }
        return nil
    }
}
