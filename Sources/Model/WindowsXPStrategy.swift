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
///    elle. Plus de dix fichiers sans destination, et la région est abandonnée ;
/// 4. **vider la zone MFT** de la même façon, une fois par passe ;
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
/// enregistrement de MFT et un secteur de `$Bitmap`, jamais le cluster 0 ; et
/// sur NTFS, ce qu'un déplacement quitte n'est libre qu'au point de contrôle
/// suivant (`NTFSCheckpoints`). La liste des trous d'une phase est bâtie une
/// fois, à son début, et consommée : ce qu'une phase libère ne sert qu'à la
/// suivante, comme l'outil relisait la bitmap.
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

        return DefragPlan(
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
        var alreadyInPlace = 0

        init(strategy: WindowsXPStrategy, volume: DefragVolume, sink: OperationSink) {
            self.strategy = strategy
            self.volume = volume
            self.sink = sink
            alreadyInPlace = volume.files.filter { $0.isContiguous && $0.clusterCount > 0 }.count
        }

        var partition: PartitionGeometry { volume.partition }
        var total: UInt32 { UInt32(volume.partition.clusterCount) }

        var fragmentedCount: Int {
            volume.files.filter { !$0.isContiguous && strategy.canTouch($0, partition: partition) }.count
        }

        // MARK: Les trous d'une phase

        /// Tous les trous du volume, zone MFT rognée, dans l'ordre du disque.
        /// Bâti une fois par phase, comme `BuildFreeSpaceList`.
        func holes(excluding region: Range<UInt32>? = nil) -> [Hole] {
            var result: [Hole] = []
            let zone = WindowsXPStrategy.avoidsMFTZone ? volume.mftZone : nil
            var cursor: UInt32 = 0
            while cursor < total, let run = volume.bitmap.nextFreeRun(from: cursor) {
                cursor = run.end
                var pieces = [Extent(start: run.start, length: run.length)]
                for cut in [zone, region].compactMap({ $0 }) {
                    pieces = pieces.flatMap { piece -> [Extent] in
                        guard piece.start < cut.upperBound, piece.end > cut.lowerBound else { return [piece] }
                        var kept: [Extent] = []
                        if piece.start < cut.lowerBound {
                            kept.append(Extent(start: piece.start, length: cut.lowerBound - piece.start))
                        }
                        if piece.end > cut.upperBound {
                            kept.append(Extent(start: cut.upperBound, length: piece.end - cut.upperBound))
                        }
                        return kept
                    }
                }
                for piece in pieces where !piece.isEmpty {
                    result.append(Hole(start: piece.start, length: piece.length))
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

        /// Un fichier entier vers un trou, validé, retenu jusqu'au point de
        /// contrôle.
        mutating func move(_ position: Int, to target: Extent, phase: Int) {
            let file = volume.files[position]
            DefragOperations.move(source: file.extents, destination: [target],
                                  category: file.category, contiguous: true, phase: phase,
                                  partition: partition, bufferBytes: strategy.bufferBytes,
                                  fullBlocks: strategy.fullBlocks, into: sink)
            DefragOperations.commit(extents: [target], fileIndex: volume.mftRecord(of: position),
                                    entrySector: volume.entrySector(of: position),
                                    phase: phase, partition: partition, into: sink)
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

        // MARK: 1. La MFT

        /// `MFTDefrag` : la queue de la MFT en plus d'un morceau part d'un bloc
        /// vers le premier trou qui la tient — la zone MFT comprise, c'est sa
        /// réserve.
        mutating func defragmentMFT() {
            let extents = volume.mftExtents
            guard extents.count > 2 else { return }
            let tail = Array(extents.dropFirst())
            let need = tail.reduce(0) { $0 + $1.length }
            guard need > 0,
                  let target = DefragOperations.firstGap(in: volume, need: need, avoidingMFTZone: false)
            else { return }
            DefragOperations.move(source: tail, destination: [target],
                                  category: .reserved, contiguous: true, phase: WindowsXPStrategy.defragPhase,
                                  partition: partition, bufferBytes: strategy.bufferBytes,
                                  fullBlocks: strategy.fullBlocks, into: sink)
            DefragOperations.commit(extents: [target], fileIndex: 0, entrySector: nil,
                                    phase: WindowsXPStrategy.defragPhase, partition: partition, into: sink)
            volume.relocateMFTTail(to: target)
            checkpoints.afterCommit(&volume, sink: sink)
            movedClusters += Int(need)
        }

        // MARK: 2. Défragmenter

        /// `DefragmentFiles` : rend `true` si plus rien n'est fragmenté ;
        /// sinon retient dans `minimumLength` la taille du premier fichier
        /// resté sans trou.
        mutating func defragmentFiles(minimumLength: inout UInt32) -> Bool {
            let candidates = volume.files.indices
                .filter { !volume.files[$0].isContiguous && strategy.canTouch(volume.files[$0], partition: partition) }
                .sorted { strategy.order.precedes(volume.files[$0], volume.files[$1]) }
            guard !candidates.isEmpty else { return true }

            var bySize = holes().sorted { $0.length < $1.length }
            var remaining = 0
            for (rank, position) in candidates.enumerated() {
                sink.progress = 0.3 * Double(rank) / Double(candidates.count)
                let file = volume.files[position]
                // Un répertoire FAT : `FSCTL_MOVE_FILE` refuse d'en déplacer
                // le premier cluster ; il reste en morceaux.
                guard volume.moveFileAccepts(position, fromVCN: 0) else { remaining += 1; continue }
                guard let target = Pass.takeBestFit(file.clusterCount, from: &bySize) else {
                    // « Sigh. No free space chunk that's big enough » : les
                    // suivants sont plus gros, inutile de continuer.
                    minimumLength = file.clusterCount
                    remaining += candidates.count - rank
                    break
                }
                move(position, to: target, phase: WindowsXPStrategy.defragPhase)
            }
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

        /// `ConsolidateFreeSpace` : vide la région, de la fin vers le début,
        /// chaque fichier vers le plus petit trou qui le tient hors d'elle.
        /// Rend `true` si au moins un fichier est parti.
        mutating func consolidateFreeSpace(minimumLength: UInt32) -> Bool {
            guard let region = findRegion(minimumLength: minimumLength) else { return false }
            return empty(region: region.start..<region.end, files: region.files)
        }

        /// La zone MFT, vidée une fois par passe.
        mutating func consolidateMFTZone() -> Bool {
            guard let zone = volume.mftZone, !zone.isEmpty else { return true }
            let inside = volume.occupants(of: zone).filter {
                let file = volume.files[$0]
                return file.isContiguous && strategy.canTouch(file, partition: partition)
                    && volume.moveFileAccepts($0, fromVCN: 0)
            }
            guard !inside.isEmpty else { return true }
            return empty(region: zone, files: inside)
        }

        private mutating func empty(region: Range<UInt32>, files: [Int]) -> Bool {
            var bySize = holes(excluding: region).sorted { $0.length < $1.length }
            // De la fin vers le début : la table est triée par LCN décroissant.
            let order = files.sorted { (volume.files[$0].firstCluster ?? 0) > (volume.files[$1].firstCluster ?? 0) }
            var failures = 0
            var moved = 0
            for (rank, position) in order.enumerated() {
                sink.progress = 0.3 + 0.4 * Double(rank) / Double(order.count)
                guard let target = Pass.takeBestFit(volume.files[position].clusterCount, from: &bySize) else {
                    failures += 1
                    if failures > WindowsXPStrategy.consolidationFailureLimit { break }
                    continue
                }
                move(position, to: target, phase: WindowsXPStrategy.consolidatePhase)
                evacuations += 1
                sink.moves.evacuations = evacuations
                moved += 1
            }
            return moved > 0
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
                sink.progress = 0.7 + 0.3 * Double(rank) / Double(candidates.count)
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
    func precedes(_ a: DefragFile, _ b: DefragFile) -> Bool {
        switch self {
        case .sizeThenRecord:
            if a.clusterCount != b.clusterCount { return a.clusterCount < b.clusterCount }
            return a.id < b.id
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
