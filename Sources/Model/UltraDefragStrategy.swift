import Foundation
import DiskCore

/// La passe de défragmentation d'**UltraDefrag 7.1.1** — `defrag_routine`,
/// `src/dll/udefrag/defrag.c`.
///
/// Elle n'est pas là pour l'époque : UltraDefrag est de 2018, et aucun des
/// vingt disques de la galerie n'en a jamais vu la couleur. Elle est là pour
/// un échec mesuré. Le défragmenteur de Windows XP laisse 155 des 244 fichiers
/// cassés de `famille-2007` en morceaux, et toujours les mêmes : les gros —
/// 213 Mo en moyenne — pour lesquels un volume plein à 93 % n'a plus un seul
/// trou à la taille. `WindowsXPStrategy` n'a rien à leur proposer, parce qu'il
/// ne sait faire qu'une chose : recopier un fichier **entier** dans un trou
/// libre, ou renoncer.
///
/// UltraDefrag pose la question autrement. Un fichier de 213 Mo en quatre
/// morceaux n'a pas besoin d'être déplacé pour aller mieux ; il a besoin qu'on
/// recolle **ses petits morceaux**, et qu'on laisse les gros où ils sont. C'est
/// la *défragmentation partielle*, et la comparaison des deux bases de code
/// note que JKDefrag n'a pas d'équivalent.
///
/// Trois choses la distinguent, et toutes les trois s'entendent :
///
/// - **l'ordre.** Les fichiers sont traités *les plus fragmentés d'abord*
///   (`fragmented_files_compare`, `analyze.c:756` : tri décroissant sur le
///   nombre de fragments, départage par chemin), et non dans l'ordre de la MFT.
///   La passe commence donc par le pire cas au lieu d'y arriver par hasard ;
/// - **deux séquences, pas une** (`defrag_sequence`). La première a un seuil de
///   fragment infini, ce qui rend tout fichier « petit » : elle recopie chaque
///   fichier cassé d'un seul tenant, comme le fait XP. La seconde rabaisse le
///   seuil à 20 Mo (`PART_DEFRAG_MAGIC_CONSTANT`) et ne s'occupe plus que de ce
///   que la première a laissé — c'est là que la défragmentation partielle
///   opère. Chacune est rejouée tant qu'elle déplace quelque chose ;
/// - **le grain du déplacement suit la capacité du volume**
///   (`adjust_move_at_once_parameter`), pas le tampon d'un outil.
///
/// Comme la passe de XP, elle n'évacue personne : une destination est toujours
/// un trou déjà libre. Ce qu'elle change n'est pas le va-et-vient, c'est la
/// **taille de ce qui est déplacé** — des rafales courtes sur les bords d'un
/// gros fichier, au lieu d'un transfert de deux cents mégaoctets ou de rien du
/// tout.
///
/// Deux choses du code d'origine n'ont pas de sens ici et sont assumées comme
/// telles. Le second essai de `defragment()`, qui redonne sa chance à un
/// fichier dont le déplacement a échoué parce que la destination avait été
/// prise entre-temps, n'a rien à rattraper : un plan simulé ne perd pas une
/// course contre le système. Et `can_defragment` saute les répertoires sur FAT,
/// distinction qu'un `ClusterCategory` ne porte pas.
///
/// Une troisième, en revanche, est suivie à la lettre parce qu'elle s'entend :
/// sur NTFS, l'espace qu'un déplacement libère ne sert qu'au **tour suivant**
/// de la routine (`move.c:719-727`, voir `apply`). Les destinations d'un tour
/// sont donc prises plus loin qu'elles ne le seraient sur FAT, et le bras
/// voyage d'autant.
struct UltraDefragStrategy: DefragStrategy {

    let id = "ultraDefrag"
    let label = "UltraDefrag"

    /// En dessous de cette taille, un fragment est « petit » et vaut d'être
    /// recollé à son voisin — `PART_DEFRAG_MAGIC_CONSTANT`, 20 Mo
    /// (`udefrag-internals.h:37`).
    ///
    /// C'est le seul réglage qui décide de ce que la passe fait vraiment. Trop
    /// bas, elle ne trouve plus rien à recoller et redevient la passe de XP ;
    /// trop haut, elle redéplace des fichiers entiers et en retrouve les
    /// échecs. Le commentaire du code d'origine l'appelle une constante
    /// magique, et c'en est une : rien dans UltraDefrag ne la justifie.
    var fragmentSizeThreshold = 20 * 1024 * 1024

    /// Taille d'un bloc de déplacement, ou `nil` pour la déduire de la capacité
    /// du volume comme le fait `adjust_move_at_once_parameter`.
    var bufferBytes: Int?

    /// Déplacer par blocs pleins (`DefragOperations.gatheredMove`) au lieu de
    /// couper chaque tampon aux bornes des extents.
    ///
    /// Ce n'est pas le comportement modélisé de l'outil, et c'est désactivé par
    /// défaut : l'option sert à comparer les algorithmes à primitive égale avec
    /// `FragmentMergeStrategy`, qui déplace toujours ainsi. Sur les huit volumes
    /// NTFS de la galerie, elle ramène XP de 2 h 08 à 1 h 08, UltraDefrag de
    /// 4 h 03 à 1 h 28 et JkDefrag de 7 h 09 à 4 h 49, sans rien changer à ce
    /// qu'ils laissent.
    var fullBlocks = false

    /// La courbe d'`adjust_move_at_once_parameter` (`analyze.c:90-117`), qui
    /// dimensionne le bloc sur la capacité du volume et non sur ce qu'un
    /// tampon utilisateur saurait tenir.
    ///
    /// La règle qu'elle applique est ergonomique — qu'un bloc se termine assez
    /// vite pour qu'on puisse interrompre la passe en une demi-seconde — et
    /// c'est pour cela qu'elle grandit avec le disque : un volume plus gros est
    /// porté par un disque plus rapide. Les huit volumes NTFS de la galerie
    /// s'échelonnent de 39 à 312 Gio et tombent donc sur 4, 8 ou 16 Mo, là où
    /// `WindowsXPStrategy` retient 4 Mo pour `FSCTL_MOVE_FILE` quelle que soit
    /// la capacité. L'écart est réel mais reste du même ordre : ce qui sépare
    /// les deux passes n'est pas le grain.
    static func moveAtOnce(capacityBytes: Int) -> Int {
        switch capacityBytes {
        case ..<(20 << 30):           return 256 * 1024
        case ..<(100 << 30):          return 4 << 20
        case ..<(250 << 30):          return 8 << 20
        case ..<(1 << 40):            return 16 << 20
        case ..<(2 << 40):            return 32 << 20
        default:                      return 64 << 20
        }
    }

    /// Les deux séquences de `defrag_sequence` sont deux phases distinctes, et
    /// c'est délibéré : ce sont deux sons différents. La première est une suite
    /// de gros transferts d'un bout à l'autre du volume, la seconde une
    /// succession de rafales courtes autour des mêmes cylindres.
    let phases: [PhaseDescriptor] = [
        PhaseDescriptor(id: "analyse", label: "Analyse du volume",
                        detail: "Les fichiers cassés, classés du plus fragmenté au moins"),
        PhaseDescriptor(id: "defrag", label: "Défragmentation",
                        detail: "Chaque fichier cassé recopié d'un seul tenant, tant qu'un trou l'accepte"),
        PhaseDescriptor(id: "partial", label: "Défragmentation partielle",
                        detail: "Sur les fichiers trop gros pour tenir ailleurs : recoller les petits morceaux, laisser les gros"),
        PhaseDescriptor(id: "commit", label: "Écriture des métadonnées",
                        detail: "Les derniers enregistrements de MFT et la bitmap du volume"),
        PhaseDescriptor(id: "done", label: "Terminé",
                        detail: "Le rapport compte séparément ce qui a été réparé entièrement et partiellement"),
    ]

    // MARK: - Planification

    func plan(volume input: DefragVolume, into sink: OperationSink) -> DefragPlan {

        var volume = input
        let partition = volume.partition
        let before = volume.stats
        let initialRuns = volume.categoryRuns()
        let buffer = bufferBytes ?? Self.moveAtOnce(capacityBytes: partition.capacityBytes)

        // MARK: Phase 0 — analyse

        DefragOperations.analysis(partition: partition,
                                  directoryCount: DefragOperations.directoryCount(of: volume),
                                  into: sink)

        let candidates = volume.files.indices.filter { canDefragment(volume.files[$0], fragmented: false) }
        let alreadyInPlace = candidates.filter { volume.files[$0].isContiguous }.count

        var moved = Movements()

        // MARK: Phase 1 — `defrag_sequence`, seuil infini : tout ou rien

        // Un seuil infini rend tout fichier « petit » : la condition
        // `clusters * bytes_per_cluster < 2 * seuil` est vraie partout, et
        // chaque fichier cassé est recopié entier. C'est, à l'ordre de passage
        // près, ce que fait le défragmenteur de XP — et cela laisse derrière
        // exactement les mêmes fichiers.
        repeat {
            moved.clustersThisPass = 0
            routine(threshold: nil, phase: 1, bufferBytes: buffer,
                    volume: &volume, sink: sink, moved: &moved)
        } while moved.clustersThisPass > 0

        // MARK: Phase 2 — la même routine à 20 Mo : la défragmentation partielle

        repeat {
            moved.clustersThisPass = 0
            routine(threshold: fragmentSizeThreshold, phase: 2, bufferBytes: buffer,
                    volume: &volume, sink: sink, moved: &moved)
        } while moved.clustersThisPass > 0

        // MARK: Phase 3 — la MFT et la bitmap, une dernière fois

        // Le bilan est celui d'un volume revenu au repos : ce qui était retenu
        // depuis le dernier tour est rendu.
        volume.releaseHeldClusters()
        sink.progress = 1
        DefragOperations.final(partition: partition, phase: 3, into: sink)

        return DefragPlan(
            strategy: self,
            partition: partition,
            initialRuns: initialRuns,
            operations: [],
            mutations: [],
            phases: phases,
            before: before,
            after: volume.stats,
            movedBytes: moved.clusters * partition.clusterBytes,
            filesMoved: moved.entirely.union(moved.partially).count,
            filesAlreadyInPlace: alreadyInPlace,
            // Une destination est toujours un trou libre : personne n'est
            // délogé, exactement comme sur la passe de XP.
            evacuations: 0,
            arrangement: volume.arrangement
        )
    }

    /// Ce que la passe retient d'elle-même. Les deux ensembles sont distincts
    /// et pas seulement pour le rapport : un fichier peut être recollé
    /// partiellement à un tour puis, devenu plus petit à déplacer, recopié
    /// entier au suivant.
    private struct Movements {
        var clusters = 0
        var clustersThisPass = 0
        var entirely: Set<Int> = []
        var partially: Set<Int> = []
    }

    /// Un tour de `defrag_routine` : tous les fichiers cassés, les plus
    /// fragmentés d'abord, chacun traité une fois.
    ///
    /// `threshold` à `nil` est le seuil par défaut d'UltraDefrag
    /// (`DEFAULT_FRAGMENT_SIZE_THRESHOLD`, la moitié du plus grand entier) :
    /// il ne borne rien, et tout fichier passe par la branche « entier ».
    private func routine(threshold: Int?,
                         phase: Int,
                         bufferBytes: Int,
                         volume: inout DefragVolume,
                         sink: OperationSink,
                         moved: inout Movements) {

        let partition = volume.partition

        // `release_temp_space_regions` : les clusters quittés au tour
        // précédent sont enfin libres, et seulement maintenant.
        volume.releaseHeldClusters()

        // L'arbre rouge-noir `jp->fragmented_files`, dans son ordre de
        // parcours : décroissant sur le nombre de fragments, départagé par le
        // chemin. C'est cet ordre-là, et non celui de la MFT, qui fait qu'une
        // passe UltraDefrag attaque par le fichier le plus abîmé du volume.
        let order = volume.files.indices
            .filter { canDefragment(volume.files[$0]) }
            .sorted { left, right in
                let a = volume.files[left], b = volume.files[right]
                if a.fragmentCount != b.fragmentCount { return a.fragmentCount > b.fragmentCount }
                return a.path < b.path
            }

        for (rank, position) in order.enumerated() {
            // Un tour de la routine après l'autre : l'avancement repart de zéro
            // à chacun, comme la barre de l'outil.
            sink.progress = Double(rank) / Double(order.count)
            guard canDefragment(volume.files[position]) else { continue }
            let file = volume.files[position]

            let entirely = threshold.map {
                Int(file.clusterCount) * partition.clusterBytes < 2 * $0
            } ?? true

            if entirely {
                // Assez petit pour qu'il soit absurde de ruser : on le recopie
                // d'un bout à l'autre dans le premier trou venu, ou on le
                // laisse tel quel.
                guard let target = DefragOperations.firstGap(in: volume,
                                                             need: file.clusterCount) else { continue }
                DefragOperations.move(source: file.extents, destination: [target],
                                      category: file.category, contiguous: true, phase: phase,
                                      partition: partition, bufferBytes: bufferBytes,
                                      fullBlocks: fullBlocks, into: sink)
                DefragOperations.commit(cluster: Int(target.start), fileIndex: position,
                                        entrySector: volume.entrySector(of: position),
                                        phase: phase, partition: partition, into: sink)
                apply(position, to: [target], in: &volume)
                moved.clusters += Int(file.clusterCount)
                moved.clustersThisPass += Int(file.clusterCount)
                moved.entirely.insert(position)
                sink.moves.filesMoved = moved.entirely.union(moved.partially).count
            } else if let threshold {
                eliminateLittleFragments(of: position, threshold: threshold, phase: phase,
                                         bufferBytes: bufferBytes, volume: &volume,
                                         sink: sink,
                                         moved: &moved)
            }
        }
    }

    // MARK: - La défragmentation partielle

    /// Recoller les petits morceaux d'un gros fichier, et ne toucher à rien
    /// d'autre.
    ///
    /// La boucle avance dans le fichier — `min_vcn` ne recule jamais, c'est ce
    /// qui garantit la terminaison — et à chaque tour cherche **la première
    /// suite de petits fragments** et la réécrit d'un seul tenant ailleurs. Les
    /// gros fragments, eux, ne bougent pas : c'est tout l'intérêt, puisque ce
    /// sont eux qui pèsent.
    ///
    /// Deux détails du code d'origine méritent d'être suivis à la lettre, parce
    /// qu'ils décident du nombre de déplacements :
    ///
    /// - **la suite est plafonnée par le plus grand trou du volume.** Inutile
    ///   de composer un bloc de 60 Mo là où le disque n'offre plus que 40 Mo
    ///   d'un tenant : la recherche de destination échouerait après coup ;
    /// - **une suite d'un seul fragment ne vaut pas le déplacement** (`n < 2`).
    ///   Déplacer un fragment isolé, c'est déplacer un morceau sans en
    ///   supprimer un seul — du bruit pour rien.
    ///
    /// Et un troisième qui surprend : si la suite reste plus courte que le
    /// seuil, UltraDefrag y **annexe un bout du gros fragment voisin** pour
    /// l'atteindre, en aval s'il y en a un, en amont sinon. L'idée est qu'un
    /// fragment de moins de 20 Mo reste un fragment ; autant que le morceau
    /// recollé naisse au-dessus du seuil plutôt qu'en dessous, quitte à
    /// recopier quelques mégaoctets de plus.
    private func eliminateLittleFragments(of position: Int,
                                          threshold: Int,
                                          phase: Int,
                                          bufferBytes: Int,
                                          volume: inout DefragVolume,
                                          sink: OperationSink,
                                          moved: inout Movements) {

        let partition = volume.partition
        let clusterBytes = partition.clusterBytes
        let category = volume.files[position].category
        let maxVCN = volume.files[position].clusterCount
        var minVCN: UInt32 = 0
        var succeeded = false

        while minVCN < maxVCN, canDefragment(volume.files[position]) {

            // Les morceaux réels du fichier, dans son ordre logique, tronqués à
            // ce qui n'a pas encore été traité.
            let window = fragments(of: volume.files[position].extents)
                .filter { $0.vcn >= minVCN && $0.vcn + $0.length <= maxVCN }
            if window.isEmpty { break }

            guard let largest = DefragOperations.largestGap(in: volume) else { break }

            var vcn: UInt32 = 0
            var length: UInt32 = 0
            var count = 0
            var nextMinVCN: UInt32 = 0

            for (index, fragment) in window.enumerated() {
                // On ne s'intéresse qu'au premier petit fragment ; tout ce qui
                // précède est gros, donc hors sujet.
                guard Int(fragment.length) * clusterBytes < threshold else { continue }

                // Même lui ne tiendrait nulle part : il n'y a rien à tenter sur
                // ce fichier pour l'instant.
                if fragment.length >= largest.length { break }

                vcn = fragment.vcn
                length = fragment.length
                count = 1
                nextMinVCN = fragment.vcn + fragment.length

                // Les petits fragments qui suivent, tant qu'ils sont petits et
                // que le tout tient encore dans le plus grand trou.
                var stopper: Fragment?
                var overflowed = false
                var cursor = index + 1
                while cursor < window.count {
                    let next = window[cursor]
                    if Int(next.length) * clusterBytes >= threshold { stopper = next; break }
                    if length + next.length > largest.length { overflowed = true; break }
                    length += next.length
                    count += 1
                    nextMinVCN = next.vcn + next.length
                    cursor += 1
                }
                if overflowed { break }

                // Le disque n'a plus un seul trou à la taille d'un fragment :
                // rien à annexer, on déplace ce qu'on a.
                if Int(largest.length) * clusterBytes < threshold { break }

                // Le morceau recollé naîtrait encore « petit » : on l'étoffe
                // avec un bout du gros fragment voisin.
                if Int(length) * clusterBytes < threshold {
                    let wanted = UInt32((threshold + clusterBytes - 1) / clusterBytes)
                    let cut = wanted - length
                    if let next = stopper {
                        // En aval. Si le reste du voisin devait tomber sous le
                        // seuil, autant le prendre en entier.
                        if Int(next.length - cut) * clusterBytes < threshold {
                            length += next.length
                            count += 1
                            nextMinVCN = next.vcn + next.length
                        } else {
                            length += cut
                            count += 1
                            nextMinVCN = next.vcn + cut
                        }
                    } else if index > 0 {
                        // En amont : le début du morceau recule dans le voisin.
                        let previous = window[index - 1]
                        if Int(previous.length - cut) * clusterBytes < threshold {
                            vcn = previous.vcn
                            length += previous.length
                            count += 1
                        } else {
                            vcn = previous.vcn + (previous.length - cut)
                            length += cut
                            count += 1
                        }
                    }
                }
                break
            }

            guard length > 0, count >= 2 else {
                // Rien à recoller ici : le fichier restera tel quel.
                minVCN = maxVCN
                continue
            }

            if let target = DefragOperations.firstGap(in: volume, need: length) {
                let (source, result) = DefragOperations.relocation(of: volume.files[position].extents,
                                                                    vcn: vcn, length: length, to: target)
                let extents = result.coalesced()
                let contiguous = extents.count <= 1
                DefragOperations.move(source: source, destination: [target],
                                      category: category, contiguous: contiguous, phase: phase,
                                      partition: partition, bufferBytes: bufferBytes,
                                      fullBlocks: fullBlocks, into: sink)
                DefragOperations.commit(cluster: Int(target.start), fileIndex: position,
                                        entrySector: volume.entrySector(of: position),
                                        phase: phase, partition: partition,
                                        repaint: contiguous == volume.files[position].isContiguous
                                            || length >= volume.files[position].clusterCount
                                            ? nil : (extents, category, contiguous),
                                        into: sink)
                apply(position, to: extents, in: &volume)
                moved.clusters += Int(length)
                moved.clustersThisPass += Int(length)
                succeeded = true
            }
            minVCN = nextMinVCN
        }

        if succeeded {
            moved.partially.insert(position)
            sink.moves.filesMoved = moved.entirely.union(moved.partially).count
        }
    }

    /// Valide un déplacement dans le volume de travail.
    ///
    /// Sur NTFS, ce que le fichier quitte reste hors d'atteinte jusqu'au tour
    /// suivant : Windows tient ces clusters pour temporairement alloués, et
    /// UltraDefrag ne les rend pas à sa liste de régions libres
    /// (`move.c:719-727`). Sur FAT, ils sont réutilisables aussitôt.
    private func apply(_ position: Int, to extents: [Extent], in volume: inout DefragVolume) {
        if volume.partition.format == .ntfs {
            volume.relocateHoldingReleased(position, to: extents)
        } else {
            volume.relocate(position, to: extents)
        }
    }

    // MARK: - Morceaux d'un fichier

    /// Un morceau réel du fichier : sa position dans le fichier (`vcn`), sa
    /// position sur le plateau (`lcn`), sa longueur.
    private struct Fragment {
        let vcn: UInt32
        let lcn: UInt32
        let length: UInt32
    }

    /// Les morceaux que la tête devra aller chercher — `build_fragments_list`.
    ///
    /// Deux extents qui se suivent dans le fichier et se touchent sur le
    /// plateau n'en font qu'un, par la même règle que
    /// `DefragFile.fragmentCount` : sans cela, la passe croirait avoir des
    /// petits fragments à recoller là où il n'y a qu'une seule rafale de
    /// lecture. `fragments(of:).count` et `fragmentCount` sont donc égaux.
    private func fragments(of extents: [Extent]) -> [Fragment] {
        var result: [Fragment] = []
        var vcn: UInt32 = 0
        for extent in extents where !extent.isEmpty {
            if let last = result.last, last.lcn + last.length == extent.start {
                result[result.count - 1] = Fragment(vcn: last.vcn, lcn: last.lcn,
                                                    length: last.length + extent.length)
            } else {
                result.append(Fragment(vcn: vcn, lcn: extent.start, length: extent.length))
            }
            vcn += extent.length
        }
        return result
    }

    // MARK: - Ce à quoi l'outil a le droit de toucher

    /// `can_defragment` : déplaçable, cassé, et qui ne soit ni la MFT ni un
    /// fichier de métadonnées.
    private func canDefragment(_ file: DefragFile, fragmented: Bool = true) -> Bool {
        guard file.isMovable, file.category != .reserved, file.clusterCount > 0 else { return false }
        return fragmented ? !file.isContiguous : true
    }

    // MARK: - Ce que les compteurs veulent dire

    /// La séparation entre « entièrement » et « partiellement » est celle du
    /// rapport de fin de passe d'UltraDefrag, et c'est elle qui justifie
    /// l'outil : un fichier réparé partiellement est un fichier que la passe de
    /// XP aurait laissé intact, faute de trou à sa taille.
    func summary(of plan: DefragPlan) -> String {
        let repaired = plan.before.fragmentedFiles - plan.after.fragmentedFiles
        var text = String(format: "La passe traite %d fichiers cassés sur %d en n'évacuant personne, "
                          + "et commence par les plus abîmés.",
                          plan.filesMoved, plan.before.fragmentedFiles)
        if repaired < plan.filesMoved {
            text += String(format: " %d d'entre eux sont trop gros pour tenir ailleurs : "
                           + "elle n'en recolle que les petits morceaux, et les laisse sur place.",
                           plan.filesMoved - repaired)
        }
        if plan.after.fragmentedFiles > 0 {
            text += String(format: " %d restent en morceaux — moins qu'ils ne l'étaient, "
                           + "mais en morceaux.", plan.after.fragmentedFiles)
        }
        return text
    }
}
