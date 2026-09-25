import Foundation
import DiskCore

/// La passe du **défragmenteur intégré de Windows XP**, puis de Vista et de
/// Windows 7 : le `dfrg.msc` dérivé de Diskeeper, seul outil qu'un
/// utilisateur de 2003, de 2007 ou de 2012 avait réellement sous la main.
///
/// **La source est le code de XP SP1** (`base/fs/utils/dfrg/dfrgntfs/`, en-tête
/// « Microsoft Corporation and Executive Software International », et
/// `base/fs/ntfs/deviosup.c` pour le noyau), tel qu'il a circulé en 2020. Ce
/// n'est pas une source ouverte comme JkDefrag ou UltraDefrag, et le journal
/// le dit (`LEDGER.md`, chantier 45) ; ce qui suit en reconstitue le
/// comportement, pas le code. Le modèle a longtemps affirmé que cet outil
/// « n'évacuait personne » : c'était une hypothèse énoncée comme un fait, et
/// elle était fausse (`LEDGER-REALISME.md`).
///
/// Ce que fait une passe, dans l'ordre de `DefragNtfs` :
///
/// 1. **la MFT d'abord** (`MFTDefrag`, avant et après) : si sa queue — tout
///    sauf le premier extent — est en plus d'un morceau, elle part d'un bloc
///    vers le premier trou qui la tient. En ligne, dès XP ;
/// 2. **défragmenter** (`DefragmentFiles`) : les fichiers et répertoires en
///    plus d'un extent, par taille croissante puis numéro d'enregistrement ;
///    chacun va entier dans **le plus petit trou qui le tient** (*best fit*,
///    `FindFreeSpace` sur une liste triée par taille), hors zone MFT. Au
///    premier fichier sans trou, la phase s'arrête — les suivants sont plus
///    gros — et retient sa taille, `MinimumLength` ;
/// 3. **consolider une région** (`FindRegionToConsolidate`,
///    `ConsolidateFreeSpace`) : la plus longue suite ininterrompue de trous et
///    de fichiers contigus exactement adjacents, d'au moins `MinimumLength`,
///    plus longue que le plus grand trou, occupée à moins de 75 %. Ses
///    fichiers en partent de la fin vers le début, chacun vers le plus petit
///    trou qui le tient hors de la région — n'importe où, y compris après
///    elle. Plus de dix fichiers sans destination, et la région est
///    abandonnée ; la consolidation rend « région parcourue sans abandon »,
///    que des fichiers soient partis ou non ;
/// 4. **vider la zone MFT** de la même façon — mais le premier fichier sans
///    trou y arrête tout, et la zone est retentée au tour suivant tant
///    qu'elle n'a pas été vidée jusqu'au bout ;
/// 5. **tasser vers l'avant** (`MoveFilesForward`) : tous les fichiers
///    contigus, du dernier cluster au premier, chacun vers le trou de plus
///    petit numéro qui le tient et qui commence avant lui. Après un échec, les
///    fichiers au moins aussi gros sont sautés ; la phase s'arrête quand un
///    fichier d'un cluster ne trouve plus rien devant lui.
///
/// Les phases s'enchaînent tant que le nombre de fichiers fragmentés baisse :
/// défragmenter, consolider, défragmenter… puis tasser, consolider, et de
/// nouveau défragmenter. Une passe qui a tout réparé finit par vider la zone
/// MFT et tasser. Il n'y a **pas de plafond de passes** dans la source ; le
/// modèle en met un, hors d'atteinte, pour ne jamais boucler sur un volume
/// pathologique.
///
/// Ce qui ne change pas : `FSCTL_MOVE_FILE` confie la copie au système de
/// fichiers, qui la fait par blocs de **64 Kio** (`LARGE_BUFFER_SIZE`,
/// `ntfsdata.h`), une lecture puis une écriture synchrones par bloc — et non
/// les 4 Mo empruntés à UltraDefrag ; valider un déplacement réécrit un
/// enregistrement de MFT et un secteur de `$Bitmap`, jamais le cluster 0. Sous
/// XP, ce qu'un déplacement quitte est libre tout de suite dans la bitmap que
/// l'outil relit, et s'y poser coûte un vidage du journal
/// (`DefragVolume.reusesWithDeletePending`) ; sous Vista et 7, le modèle le
/// retient jusqu'au point de contrôle (`NTFSCheckpoints`). La liste des trous
/// d'une phase est bâtie une fois, à son début, et consommée : ce qu'une
/// phase libère ne sert qu'à la suivante, comme l'outil relisait la bitmap.
///
/// Ce que la source donne aussi, et que le modèle **ne fait pas** : la zone
/// d'optimisation du démarrage (`layout.ini`, 32 Mo par fichier au plus, hors
/// de portée des trois mécanismes) — `BootLayout` la range à part ; les
/// « 15 % d'espace libre » ne sont qu'un seuil d'avertissement
/// (`FreeSpaceErrorLevel`), le moteur ne change rien en dessous, et le modèle
/// non plus.
///
/// **Vista et Windows 7** (KB 942092) : les fragments de 64 Mo et plus ne sont
/// pas déplacés. Le modèle laisse en place tout fichier dont le plus petit
/// fragment atteint `fragmentCeilingBytes`, et déplace les autres entiers —
/// une approximation, l'outil ne recollant que les petits morceaux.
struct WindowsXPStrategy: DefragStrategy {

    let id = "windowsXP"

    /// L'année du disque, quand elle est connue : le même moteur s'appelle
    /// autrement sous Vista et Windows 7, et y laisse les gros fragments.
    var year: Int? = nil

    var label: String {
        switch year {
        case let y? where y >= 2009:
            return String(localized: "strategy.win7", defaultValue: "Windows 7 Defragmenter")
        case let y? where y >= 2007:
            return String(localized: "strategy.vista", defaultValue: "Windows Vista Defragmenter")
        default:
            return String(localized: "strategy.windowsXP", defaultValue: "Windows XP Defragmenter")
        }
    }

    /// Le bloc du noyau : `NtfsDefragFile` copie par `LARGE_BUFFER_SIZE`,
    /// 64 Kio, bornés à l'extent source — une lecture, puis une écriture, puis
    /// un point de contrôle de transaction, bloc suivant. Le modèle prenait
    /// 4 Mo, empruntés à une courbe d'UltraDefrag.
    var bufferBytes = 64 * 1024

    /// Les trous de la zone MFT sont rognés de toutes les listes
    /// (`BuildFreeSpaceList`) : l'outil n'y range rien. Longtemps une
    /// hypothèse ; c'est un fait de la source.
    static let avoidsMFTZone = true

    /// Déplacer par blocs pleins (`DefragOperations.gatheredMove`) au lieu de
    /// couper chaque tampon aux bornes des extents. Ce n'est pas le
    /// comportement de l'outil ; l'option sert à comparer les algorithmes à
    /// primitive égale avec `FragmentMergeStrategy`.
    var fullBlocks = false

    /// Vista et 7 : les fragments qui atteignent cette taille restent en
    /// place. `nil` sous XP, qui recolle tout.
    var fragmentCeilingBytes: Int? = nil

    /// Le seuil de Vista et de Windows 7 : 64 Mo (KB 942092).
    static let vistaFragmentCeilingBytes = 64 << 20

    /// L'outil d'une année : le même moteur, et à partir de 2007 le seuil de
    /// 64 Mo et le nom de son système.
    static func dated(_ year: Int?) -> WindowsXPStrategy {
        var strategy = WindowsXPStrategy()
        strategy.year = year
        if let year, year >= 2007 { strategy.fragmentCeilingBytes = vistaFragmentCeilingBytes }
        return strategy
    }

    /// Au-delà de ce nombre de tours de la boucle extérieure, la passe
    /// s'arrête : la source n'en a pas, le modèle s'en garde un.
    static let maximumRounds = 32

    /// Combien d'échecs de destination font abandonner une région.
    static let consolidationFailureLimit = 10

    /// Occupation au-delà de laquelle une région n'est pas vidée.
    static let desperationPercent = 75

    /// L'ordre dans lequel les fichiers cassés sont visités.
    ///
    /// L'outil de XP les prend par taille croissante, départagés par numéro
    /// d'enregistrement (`FileEntrySizeCompareRoutine`), et c'est le réglage
    /// par défaut. Les autres ordres sont ceux des outils voisins, rejoués
    /// **avec le même placement** : c'est ce qui permet de mesurer ce que
    /// coûte un ordre de passage seul.
    var order: Order = .sizeThenRecord

    enum Order: String, CaseIterable, Sendable {
        /// Par taille croissante, puis numéro d'enregistrement — l'outil de XP.
        case sizeThenRecord
        /// Les numéros d'enregistrement de la MFT seuls.
        case mftRecord
        /// Le plus fragmenté d'abord, départagé par le chemin — UltraDefrag.
        case mostFragmented
        /// La position du premier cluster sur le disque — `Defragment` de
        /// JkDefrag, figé à l'ordre de départ.
        case diskPosition
        /// Le parcours de l'arborescence — le défragmenteur de Windows 95.
        case directoryWalk
    }

    /// Les phases de l'écran de XP, telles que le journal de l'outil les
    /// nomme : analyser, défragmenter, « Consolidating free space », « Moving
    /// files forward », rendre compte.
    let phases: [PhaseDescriptor] = [
        PhaseDescriptor(id: "analyse", label: String(localized: "phase.analyse", defaultValue: "Analysing the volume"),
                        detail: String(localized: "phase.analyse.xp.detail", defaultValue: "Reading the MFT: which files are in pieces, and where the holes are")),
        PhaseDescriptor(id: "defrag", label: String(localized: "phase.defragFiles", defaultValue: "Defragmenting the files"),
                        detail: String(localized: "phase.defragFiles.xp.detail", defaultValue: "Every broken file, smallest first, copied whole into the smallest hole that fits")),
        PhaseDescriptor(id: "consolidate", label: String(localized: "phase.consolidate", defaultValue: "Consolidating free space"),
                        detail: String(localized: "phase.consolidate.detail", defaultValue: "A region is emptied, file by file, to open one hole big enough")),
        PhaseDescriptor(id: "forward", label: String(localized: "phase.forward", defaultValue: "Moving files forward"),
                        detail: String(localized: "phase.forward.detail", defaultValue: "From the end of the volume, every file that fits in a hole before it moves there")),
        PhaseDescriptor.commit(on: .ntfs),
        PhaseDescriptor(id: "done", label: String(localized: "phase.done", defaultValue: "Finished"),
                        detail: String(localized: "phase.done.xp.detail", defaultValue: "The report lists what stayed in pieces, for want of a big enough hole")),
    ]

    private static let analysePhase = 0, defragPhase = 1, consolidatePhase = 2,
                       forwardPhase = 3, commitPhase = 4

    func plan(volume input: DefragVolume, into sink: OperationSink) -> DefragPlan {
        var pass = Pass(strategy: self, volume: input, sink: sink)
        let before = pass.volume.stats
        let initialRuns = pass.volume.categoryRuns()

        DefragOperations.analysis(volume: pass.volume, into: sink)
        pass.defragmentMFT()

        // `DefragNtfs`, à la lettre : la boucle intérieure alterne
        // défragmentation et consolidation tant que le nombre de fichiers
        // cassés baisse ; la boucle extérieure tasse, consolide, et recommence.
        var minimumLength: UInt32 = 0
        var done = false
        var mftZoneDone = false
        var previousFragmented = -1
        var previousFragmented2 = -1
        var rounds = 0
        outer: while rounds < Self.maximumRounds {
            rounds += 1
            var inner = 0
            while inner < Self.maximumRounds {
                inner += 1
                done = pass.defragmentFiles(minimumLength: &minimumLength)
                let fragmented = pass.fragmentedCount
                if done || fragmented == previousFragmented { break }
                let consolidated = pass.consolidateFreeSpace(minimumLength: minimumLength)
                previousFragmented = fragmented
                if !consolidated { break }
                if !mftZoneDone { mftZoneDone = pass.consolidateMFTZone() }
            }
            let fragmented = pass.fragmentedCount
            if done || fragmented == previousFragmented2 { break outer }
            previousFragmented2 = fragmented
            pass.moveFilesForward()
            _ = pass.consolidateFreeSpace(minimumLength: minimumLength)
        }
        if done {
            if !mftZoneDone { _ = pass.consolidateMFTZone() }
            pass.moveFilesForward()
        }
        pass.defragmentMFT()

        // Le bilan est celui d'un volume revenu au repos, le dernier point de
        // contrôle passé.
        pass.volume.releaseHeldClusters()
        sink.progress = 1
        DefragOperations.final(partition: pass.volume.partition, phase: Self.commitPhase, into: sink)

        var plan = DefragPlan(
            strategy: self,
            partition: pass.volume.partition,
            initialRuns: initialRuns,
            operations: [],
            mutations: [],
            phases: phases,
            before: before,
            after: pass.volume.stats,
            movedBytes: pass.movedClusters * pass.volume.partition.clusterBytes,
            filesMoved: pass.filesMoved,
            filesAlreadyInPlace: pass.alreadyInPlace,
            evacuations: pass.evacuations,
            arrangement: pass.volume.arrangement
        )
        plan.logFlushes = sink.logFlushes
        return plan
    }

    func summary(of plan: DefragPlan) -> String {
        let repaired = plan.before.fragmentedFiles - plan.after.fragmentedFiles
        var text = String(localized: "summary.windowsXP",
                          defaultValue: "The pass repairs \(repaired) files out of \(plan.before.fragmentedFiles), each copied whole into the smallest hole that fits, evicts \(plan.evacuations) files to open a hole big enough, and packs the rest towards the start of the volume — \(plan.filesMoved) files moved in all.")
        if plan.after.fragmentedFiles > 0 {
            text += " " + String(localized: "summary.windowsXP.remaining",
                                 defaultValue: "\(plan.after.fragmentedFiles) stay in pieces, for want of a big enough hole — that is what the tool listed at the end of a pass.")
        }
        return text
    }

    // MARK: - Ce à quoi l'outil a le droit de toucher

    /// Le fichier d'échange est ouvert par Windows ; les métafichiers autres
    /// que la MFT ne bougent pas. Sous Vista et 7, un fichier dont le plus
    /// petit fragment atteint le plafond reste en place.
    func canTouch(_ file: DefragFile, partition: PartitionGeometry) -> Bool {
        guard file.isMovable, file.category != .reserved, file.clusterCount > 0 else { return false }
        if let ceiling = fragmentCeilingBytes, !file.isContiguous {
            let smallest = file.extents.map(\.length).min() ?? 0
            if Int(smallest) * partition.clusterBytes >= ceiling { return false }
        }
        return true
    }
}

// MARK: - La passe

extension WindowsXPStrategy {

    /// Un trou, dans la liste qu'une phase se bâtit à son début.
    private struct Hole {
        var start: UInt32
        var length: UInt32
        var end: UInt32 { start + length }
    }

    /// L'état d'une passe : le volume tel qu'il devient, les compteurs, et le
    /// puits où partent les opérations.
    private struct Pass {
        let strategy: WindowsXPStrategy
        var volume: DefragVolume
        let sink: OperationSink
        var checkpoints = NTFSCheckpoints()
        var movedClusters = 0
        var filesMoved = 0
        var evacuations = 0
        /// Les fichiers qu'un déplacement a touchés, une fois chacun.
        var moved = Set<Int>()
        /// Les fichiers contigus au départ que l'outil avait le droit de
        /// déplacer : ceux d'entre eux qu'aucune phase n'a touchés sont « déjà
        /// en place ».
        let contiguousAtStart: [Int]

        init(strategy: WindowsXPStrategy, volume: DefragVolume, sink: OperationSink) {
            self.strategy = strategy
            self.volume = volume
            self.sink = sink
            contiguousAtStart = volume.files.indices.filter {
                let file = volume.files[$0]
                return file.isContiguous && strategy.canTouch(file, partition: volume.partition)
            }
        }

        /// Contigus au départ, déplaçables, et jamais déplacés : ni le fichier
        /// d'échange ni les métafichiers, que l'outil ne touche pas, ni ceux
        /// que la consolidation ou le tassement ont emmenés ailleurs (B#17) —
        /// comme les autres outils, qui comptent les déplaçables moins les
        /// touchés.
        var alreadyInPlace: Int {
            contiguousAtStart.filter { !moved.contains($0) }.count
        }

        var partition: PartitionGeometry { volume.partition }
        var total: UInt32 { UInt32(volume.partition.clusterCount) }

        var fragmentedCount: Int {
            volume.files.filter { !$0.isContiguous && strategy.canTouch($0, partition: partition) }.count
        }

        // MARK: L'avancement

        /// Chaque phase compte son avancement sur sa propre plage, et les
        /// phases reviennent à chaque tour : la barre retomberait à zéro.
        /// `SendStatusData` (`dfrgntfs.cpp:981-985`) ne laisse jamais le
        /// pourcentage envoyé descendre sous le dernier : `uLastPercentDone`
        /// le borne. La barre de XP plafonne donc au lieu de reculer (B#16).
        func advance(to value: Double) {
            sink.progress = max(sink.progress, value)
        }

        // MARK: Les trous d'une phase

        /// Tous les trous du volume, zone MFT rognée, dans l'ordre du disque.
        /// Bâti une fois par phase, comme `BuildFreeSpaceList`.
        ///
        /// Le rognage est celui de l'outil (`freespace.cpp:305-318`, la même
        /// règle dans les trois constructeurs de listes et pour la région
        /// exclue, 434-476) : un trou qui chevauche une zone n'en garde que
        /// la partie d'avant s'il commence avant elle — même s'il la
        /// traverse, la partie d'après est perdue pour cette liste —, la
        /// partie d'après s'il commence dedans, rien s'il y tient.
        func holes(excluding region: Range<UInt32>? = nil) -> [Hole] {
            var result: [Hole] = []
            let zone = WindowsXPStrategy.avoidsMFTZone ? volume.mftZone : nil
            let cuts = [zone, region].compactMap { $0 }.filter { !$0.isEmpty }
            var cursor: UInt32 = 0
            while cursor < total, let run = volume.bitmap.nextFreeRun(from: cursor) {
                cursor = run.end
                var start = run.start, end = run.end
                var dropped = false
                for cut in cuts where start < cut.upperBound && end > cut.lowerBound {
                    if start < cut.lowerBound {
                        end = cut.lowerBound
                    } else if end <= cut.upperBound {
                        dropped = true
                        break
                    } else {
                        start = cut.upperBound
                    }
                }
                if !dropped, end > start {
                    result.append(Hole(start: start, length: end - start))
                }
            }
            return result
        }

        /// Le plus petit trou qui tient `need`, retiré de la liste (ce qui en
        /// reste y revient) — `FindFreeSpace` sur une liste triée par taille.
        static func takeBestFit(_ need: UInt32, from bySize: inout [Hole]) -> Extent? {
            // `bySize` est triée par taille croissante.
            var low = 0, high = bySize.count
            while low < high {
                let mid = (low + high) / 2
                if bySize[mid].length < need { low = mid + 1 } else { high = mid }
            }
            guard low < bySize.count else { return nil }
            let hole = bySize.remove(at: low)
            let taken = Extent(start: hole.start, length: need)
            if hole.length > need {
                let rest = Hole(start: hole.start + need, length: hole.length - need)
                var at = 0, top = bySize.count
                while at < top {
                    let mid = (at + top) / 2
                    if bySize[mid].length < rest.length { at = mid + 1 } else { top = mid }
                }
                bySize.insert(rest, at: at)
            }
            return taken
        }

        // MARK: Déplacer

        /// Un fichier entier vers un trou, validé. Ce qu'il quitte est retenu
        /// jusqu'au point de contrôle hors XP ; sous XP, libre tout de suite,
        /// et le réemployer coûte un vidage du journal.
        mutating func move(_ position: Int, to target: Extent, phase: Int) {
            let file = volume.files[position]
            DefragOperations.moveFile(source: file.extents, destination: [target],
                                      category: file.category, contiguous: true, phase: phase,
                                      volume: &volume, fileIndex: volume.mftRecord(of: position),
                                      entrySector: volume.entrySector(of: position),
                                      bufferBytes: strategy.bufferBytes, fullBlocks: strategy.fullBlocks,
                                      validBytes: file.bytes, into: sink)
            if volume.releaseWaitsForCheckpoint {
                volume.relocateHoldingReleased(position, to: [target])
            } else {
                volume.relocate(position, to: [target])
            }
            checkpoints.afterCommit(&volume, sink: sink)
            movedClusters += Int(file.clusterCount)
            filesMoved += 1
            moved.insert(position)
            sink.moves.filesMoved = filesMoved
        }

        // MARK: 1. La MFT

        /// `MFTDefrag` (`mftdefrag.cpp:78-160`), avant et après la passe.
        ///
        /// `GetMFTSize` (`277-330`) lit les extents de toute la MFT : leur
        /// nombre, la taille du premier, et la taille de **toute** la MFT dès
        /// qu'elle en a deux. L'outil agit dès **deux** extents
        /// (`lMFTFragments > 1`, ligne 122 ; le commentaire d'en-tête dit
        /// « in two fragments », le code non) et si le premier dépasse seize
        /// enregistrements (`lMFTStartingVcn > ClustersPerFRS * 16`, ligne
        /// 120) — mais `ClustersPerFRS` vaut `ClustersPerFileRecordSegment`,
        /// que le pilote laisse à zéro quand un enregistrement est plus petit
        /// qu'un cluster (`fsctrl.c:1283-1292`, `9148`) : sur des clusters de
        /// 4 Ko, la condition se réduit à un premier extent non vide.
        ///
        /// Il cherche un trou de la taille de la MFT **entière**
        /// (`FindFreeSpaceChunk`, ligne 126, `freeSpaceChunk`) et n'en retire
        /// le premier extent qu'ensuite (131) ; puis `FSCTL_MOVE_FILE` pour la
        /// queue, que le pilote accepte au-delà des seize premiers
        /// enregistrements (`deviosup.c:10112-10125`) et copie bloc par bloc.
        /// Recollée en deux extents, la MFT repart donc à chaque appel.
        mutating func defragmentMFT() {
            let extents = volume.mftExtents
            guard extents.count > 1 else { return }
            let first = extents[0].length
            let clustersPerFRS = UInt32(1_024 / partition.clusterBytes)
            guard first > clustersPerFRS * 16 else { return }
            // Le pilote refuse de déplacer les seize premiers enregistrements.
            let firstUserVCN = UInt32(partition.clusters(forBytes: 16 * 1_024))
            guard first >= firstUserVCN else { return }
            let whole = extents.reduce(0) { $0 + $1.length }
            guard let start = freeSpaceChunk(size: whole) else { return }
            let tail = Array(extents.dropFirst())
            let movable = clustersMovable(tail, to: start)
            guard movable > 0 else { return }
            let target = Extent(start: start, length: movable)
            var source: [Extent] = []
            var left = movable
            for piece in tail where left > 0 {
                let length = min(piece.length, left)
                source.append(Extent(start: piece.start, length: length))
                left -= length
            }
            DefragOperations.moveFile(source: source, destination: [target],
                                      category: .reserved, contiguous: true,
                                      phase: WindowsXPStrategy.defragPhase,
                                      volume: &volume, fileIndex: 0,
                                      bufferBytes: strategy.bufferBytes, fullBlocks: strategy.fullBlocks,
                                      firstVCN: first, into: sink)
            volume.relocateMFTTail(to: target)
            checkpoints.afterCommit(&volume, sink: sink)
            movedClusters += Int(movable)
        }

        /// `FindFreeSpaceChunk` (`defragcommon.cpp:80-168`) : la bitmap relue,
        /// la zone MFT marquée occupée (`MarkBitMapforNTFS`, 147-168 ; la zone
        /// de démarrage, elle, ne l'est pas), puis les trous dans l'ordre des
        /// LCN depuis le début, jusqu'au premier d'au moins `size` clusters.
        /// Faute de trou assez grand, l'outil rend le début du **dernier trou
        /// examiné** si celui-ci touche la fin du volume (`FindFreeExtent`,
        /// `freespace.cpp:1637-1765`, remet son résultat à zéro à chaque appel,
        /// et zéro veut dire « rien ») ; sinon rien.
        func freeSpaceChunk(size: UInt32) -> UInt32? {
            let zone = volume.mftZone.flatMap { $0.isEmpty ? nil : $0 }
            // `FindFreeExtent` ne reconnaît jamais le LCN 0 comme un début.
            var cursor: UInt32 = 1
            while cursor < total {
                guard var run = volume.bitmap.nextFreeRun(from: cursor) else { return nil }
                if let zone, run.start < zone.upperBound, run.end > zone.lowerBound {
                    guard run.start < zone.lowerBound else { cursor = zone.upperBound; continue }
                    run = Extent(start: run.start, length: zone.lowerBound - run.start)
                }
                if run.length >= size { return run.start }
                if run.end >= total { return run.start }
                cursor = run.end
            }
            return nil
        }

        /// Ce que `FSCTL_MOVE_FILE` pose de `source` à partir de `start` avant
        /// de buter : bloc par bloc, chacun borné au tampon de 64 Kio et à
        /// l'extent source, refusé s'il dépasse la fin du volume
        /// (`STATUS_ALREADY_COMMITTED`, `deviosup.c:10499-10523`) ou s'il
        /// tombe sur un cluster occupé (`NtfsRunIsClear`). L'outil n'en sait
        /// rien : le déplacement « échoue », et ce qui a bougé a bougé.
        func clustersMovable(_ source: [Extent], to start: UInt32) -> UInt32 {
            let block = UInt32(max(strategy.bufferBytes / partition.clusterBytes, 1))
            var destination = start
            var moved: UInt32 = 0
            for piece in source {
                var offset: UInt32 = 0
                while offset < piece.length {
                    let length = min(block, piece.length - offset)
                    guard destination + length <= total,
                          volume.bitmap.isFree(Extent(start: destination, length: length))
                    else { return moved }
                    destination += length
                    offset += length
                    moved += length
                }
            }
            return moved
        }

        // MARK: 2. Défragmenter

        /// `DefragmentFiles` : rend `true` si plus rien n'est fragmenté ;
        /// sinon retient dans `minimumLength` la taille du premier fichier
        /// resté sans trou.
        mutating func defragmentFiles(minimumLength: inout UInt32) -> Bool {
            let candidates = volume.files.indices
                .filter { !volume.files[$0].isContiguous && strategy.canTouch(volume.files[$0], partition: partition) }
                .sorted {
                    strategy.order.precedes(volume.files[$0], record: volume.mftRecord(of: $0),
                                            volume.files[$1], record: volume.mftRecord(of: $1))
                }
            guard !candidates.isEmpty else { return true }

            var bySize = holes().sorted { $0.length < $1.length }
            var remaining = 0
            var smallestFailure: UInt32?
            for (rank, position) in candidates.enumerated() {
                advance(to: 0.3 * Double(rank) / Double(candidates.count))
                let file = volume.files[position]
                // Un répertoire FAT : `FSCTL_MOVE_FILE` refuse d'en déplacer
                // le premier cluster ; il reste en morceaux.
                guard volume.moveFileAccepts(position, fromVCN: 0) else { remaining += 1; continue }
                guard let target = Pass.takeBestFit(file.clusterCount, from: &bySize) else {
                    // « Sigh. No free space chunk that's big enough » : dans
                    // l'ordre de XP, les suivants sont plus gros, inutile de
                    // continuer. Un autre ordre, rejoué avec le même placement,
                    // n'a pas cette garantie : il passe au suivant, et retient
                    // le plus petit fichier resté sans trou (B#21).
                    guard strategy.order == .sizeThenRecord else {
                        smallestFailure = min(smallestFailure ?? .max, file.clusterCount)
                        remaining += 1
                        continue
                    }
                    minimumLength = file.clusterCount
                    remaining += candidates.count - rank
                    break
                }
                move(position, to: target, phase: WindowsXPStrategy.defragPhase)
            }
            if let smallestFailure { minimumLength = smallestFailure }
            return remaining == 0
        }

        // MARK: 3. Consolider une région

        /// Une suite ininterrompue de trous et de fichiers contigus exactement
        /// adjacents : ce que `FindRegionToConsolidate` mesure.
        private struct Region {
            var start: UInt32
            var end: UInt32
            var files: [Int]
            var used: UInt32
            var length: UInt32 { end - start }
        }

        /// `FindRegionToConsolidate` : la plus longue région qui contient au
        /// moins un fichier, mesure au moins `minimumLength`, dépasse le plus
        /// grand trou et est occupée à moins de 75 %.
        private func findRegion(minimumLength: UInt32) -> Region? {
            let zone = volume.mftZone
            let largestHole = holes().map(\.length).max() ?? 0
            var best: Region?
            var current: Region?
            var cursor: UInt32 = 0
            var seenFiles = Set<Int>()

            func close() {
                if let region = current, !region.files.isEmpty,
                   region.length >= minimumLength, region.length > largestHole,
                   Int(region.used) * 100 < Int(region.length) * WindowsXPStrategy.desperationPercent,
                   best.map({ region.length > $0.length }) ?? true {
                    best = region
                }
                current = nil
            }
            func extend(to end: UInt32, file: Int?, used: UInt32, at start: UInt32) {
                if current == nil { current = Region(start: start, end: start, files: [], used: 0) }
                current!.end = end
                current!.used += used
                if let file { current!.files.append(file) }
            }

            while cursor < total {
                if let zone, zone.contains(cursor) { close(); cursor = zone.upperBound; continue }
                if volume.bitmap.isFree(cursor) {
                    let run = volume.bitmap.nextFreeRun(from: cursor) ?? Extent(start: cursor, length: 1)
                    let end = zone.map { min(run.end, $0.lowerBound > cursor ? $0.lowerBound : run.end) } ?? run.end
                    let end2 = max(end, cursor + 1)
                    extend(to: end2, file: nil, used: 0, at: cursor)
                    cursor = end2
                    continue
                }
                // Un cluster occupé : par un fichier contigu déplaçable, ou par
                // un obstacle qui coupe la suite.
                guard let owner = volume.occupants(of: cursor..<(cursor + 1)).first else {
                    // Un métafichier : coupe.
                    close()
                    cursor = systemExtentEnd(at: cursor)
                    continue
                }
                let file = volume.files[owner]
                guard file.isContiguous, strategy.canTouch(file, partition: partition),
                      volume.moveFileAccepts(owner, fromVCN: 0),
                      file.clusterCount <= largestHole || largestHole == 0,
                      !seenFiles.contains(owner),
                      let extent = file.extents.first(where: { $0.start <= cursor && cursor < $0.end }),
                      extent.start == cursor
                else {
                    close()
                    let end = file.extents.first(where: { $0.start <= cursor && cursor < $0.end })?.end ?? cursor + 1
                    cursor = max(end, cursor + 1)
                    continue
                }
                seenFiles.insert(owner)
                extend(to: file.extents.last!.end, file: owner, used: file.clusterCount, at: cursor)
                cursor = file.extents.last!.end
            }
            close()
            return best
        }

        private func systemExtentEnd(at cluster: UInt32) -> UInt32 {
            volume.systemExtents.first { $0.start <= cluster && cluster < $0.end }?.end ?? cluster + 1
        }

        /// `ConsolidateFreeSpace` (`dfrgntfs.cpp:3570-3897`) : vide la région,
        /// de la fin vers le début, chaque fichier vers le plus petit trou qui
        /// le tient hors d'elle. Rend **« région parcourue sans abandon »**
        /// (`bSuccess`, 3897) : vrai quand la boucle va au bout, même sans
        /// rien déplacer ; faux quand elle abandonne, même après des
        /// déplacements — et faux sans région.
        mutating func consolidateFreeSpace(minimumLength: UInt32) -> Bool {
            guard let region = findRegion(minimumLength: minimumLength) else { return false }
            return empty(region: region.start..<region.end, files: region.files, isMFTZone: false)
        }

        /// La zone MFT vidée (`ConsolidateFreeSpace(0, 100, TRUE, 1)`) : les
        /// fichiers contigus qui **commencent** dans la zone — l'énumération
        /// part de sa fin et s'arrête au premier fichier qui commence avant
        /// elle (3706-3712). Le premier fichier sans trou arrête tout et rend
        /// faux (3858-3866) : la zone reste à vider, et la boucle de
        /// `DefragNtfs` la retentera au tour suivant (4268-4272, 4297-4300).
        mutating func consolidateMFTZone() -> Bool {
            guard let zone = volume.mftZone, !zone.isEmpty else { return true }
            let inside = volume.occupants(of: zone).filter {
                let file = volume.files[$0]
                guard let first = file.firstCluster, zone.contains(first) else { return false }
                return file.isContiguous && strategy.canTouch(file, partition: partition)
                    && volume.moveFileAccepts($0, fromVCN: 0)
            }
            guard !inside.isEmpty else { return true }
            return empty(region: zone, files: inside, isMFTZone: true)
        }

        private mutating func empty(region: Range<UInt32>, files: [Int], isMFTZone: Bool) -> Bool {
            var bySize = holes(excluding: region).sorted { $0.length < $1.length }
            // De la fin vers le début : la table est triée par LCN décroissant.
            let order = files.sorted { (volume.files[$0].firstCluster ?? 0) > (volume.files[$1].firstCluster ?? 0) }
            var failures = 0
            for (rank, position) in order.enumerated() {
                advance(to: 0.3 + 0.4 * Double(rank) / Double(order.count))
                guard let target = Pass.takeBestFit(volume.files[position].clusterCount, from: &bySize) else {
                    // « Unable to move file out » : la zone MFT abandonne au
                    // premier, une région au onzième (`++iCount > 10`).
                    failures += 1
                    if isMFTZone || failures > WindowsXPStrategy.consolidationFailureLimit { return false }
                    continue
                }
                move(position, to: target, phase: WindowsXPStrategy.consolidatePhase)
                evacuations += 1
                sink.moves.evacuations = evacuations
            }
            return true
        }

        // MARK: 4. Tasser vers l'avant

        /// `MoveFilesForward` : les fichiers contigus du dernier cluster au
        /// premier, chacun vers le trou de plus petit numéro qui le tient et
        /// qui commence avant lui.
        mutating func moveFilesForward() {
            let candidates = volume.files.indices
                .filter {
                    let file = volume.files[$0]
                    return file.isContiguous && strategy.canTouch(file, partition: partition)
                        && volume.moveFileAccepts($0, fromVCN: 0)
                }
                .sorted { (volume.files[$0].firstCluster ?? 0) > (volume.files[$1].firstCluster ?? 0) }
            guard !candidates.isEmpty else { return }

            // Par ordre du disque ; un trou consommé est retiré ou raccourci.
            var byStart = holes()
            var maximumUseful = UInt32.max
            for (rank, position) in candidates.enumerated() {
                advance(to: 0.7 + 0.3 * Double(rank) / Double(candidates.count))
                let file = volume.files[position]
                let need = file.clusterCount
                guard let start = file.firstCluster else { continue }
                if need >= maximumUseful { continue }
                var found: Int?
                for (index, hole) in byStart.enumerated() {
                    if hole.start >= start { break }
                    if hole.length >= need { found = index; break }
                }
                guard let index = found else {
                    // « No free space before Lcn » : un fichier d'un cluster
                    // qui ne trouve rien arrête la phase ; sinon les fichiers
                    // au moins aussi gros sont sautés.
                    if need <= 1 { break }
                    maximumUseful = need
                    continue
                }
                let hole = byStart[index]
                let target = Extent(start: hole.start, length: need)
                if hole.length > need {
                    byStart[index] = Hole(start: hole.start + need, length: hole.length - need)
                } else {
                    byStart.remove(at: index)
                }
                move(position, to: target, phase: WindowsXPStrategy.forwardPhase)
            }
        }
    }
}

extension WindowsXPStrategy.Order {

    /// Un ordre total : chaque critère est départagé jusqu'à l'identifiant,
    /// sans quoi le tri — donc le son — dépendrait de l'implémentation de
    /// `sorted`.
    ///
    /// `record` est l'enregistrement de MFT de chaque fichier
    /// (`DefragVolume.mftRecord(of:)`). XP départage par lui, et non par
    /// l'identifiant du modèle (`FileEntrySizeCompareRoutine`,
    /// `dfrgntfs.cpp:395-432`) : un répertoire, dont l'identifiant porte le
    /// bit de poids fort, passe avant les fichiers de même taille, puisque
    /// `MFTNumbering` numérote les répertoires d'abord (`xp-defrag-tri`).
    func precedes(_ a: DefragFile, record ra: Int, _ b: DefragFile, record rb: Int) -> Bool {
        switch self {
        case .sizeThenRecord:
            if a.clusterCount != b.clusterCount { return a.clusterCount < b.clusterCount }
            if ra != rb { return ra < rb }
            return a.id < b.id
        case .mftRecord:
            if ra != rb { return ra < rb }
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
