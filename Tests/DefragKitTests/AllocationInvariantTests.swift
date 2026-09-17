import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// L'invariant d'allocation : ce qu'aucun défragmenteur n'a le droit de faire,
/// quel que soit son algorithme et quelle que soit son époque.
///
/// Un défragmenteur qui écrit sur une donnée encore référencée est un
/// défragmenteur qui détruit le volume. C'était la hantise de l'époque, et la
/// lenteur de ces outils est précisément le prix qu'ils payaient pour l'éviter :
/// quand `DEFRAG.EXE` ne pouvait pas déloger un fichier, il sautait la place et
/// laissait le trou plutôt que de se poser dessus.
///
/// L'invariant se vérifie en deux temps, et les deux comptent :
///
/// - **l'état d'arrivée** — `plan.arrangement` reposé sur le volume de départ
///   ne doit référencer aucun cluster deux fois, ni recouvrir ce que le système
///   de fichiers occupe sans qu'aucun fichier ne le décrive ;
/// - **le déroulé** — aucune `writeExtent` ne doit tomber sur un cluster qui
///   porte encore la donnée vivante d'un autre fichier. Le recouvrement final
///   n'est que la partie visible : chaque écriture fautive fait perdre le compte
///   à la bitmap, et les trous ressortent là où il n'y en avait pas.
///
/// La règle du déroulé est la plus permissive qui reste juste : une écriture a
/// le droit de tomber sur les clusters que **la même opération** libère, parce
/// que leur contenu vient d'être lu dans le tampon — c'est ce que fait tout
/// déplacement dont la destination recouvre la source. Les stratégies qui
/// retiennent en plus leurs clusters jusqu'au point de contrôle, comme le fait
/// NTFS, sont vérifiées séparément et plus sévèrement par
/// `expectWritesOnlyOnReleasedClusters`.
enum AllocationAudit {

    struct Report {
        /// Clusters référencés par deux fichiers dans l'état d'arrivée.
        var doubleBooked = 0
        /// Clusters d'arrivée posés sur un extent système.
        var onSystem = 0
        /// Écritures tombées sur une donnée encore vivante, et leur volume.
        var overwrites = 0
        var overwrittenClusters = 0

        var isClean: Bool { doubleBooked == 0 && onSystem == 0 && overwrites == 0 }

        var description: String {
            "\(doubleBooked) clusters référencés deux fois, \(onSystem) posés sur un extent "
            + "système, \(overwrites) écritures sur une donnée vivante (\(overwrittenClusters) clusters)"
        }
    }

    static func audit(_ plan: DefragPlan, of volume: DefragVolume) -> Report {
        var report = Report()
        let count = plan.partition.clusterCount

        // 1. L'état d'arrivée : un cluster, un propriétaire. `-1` libre, `-2`
        //    système, et sinon le rang du fichier qui le tient.
        var owner = [Int32](repeating: -1, count: count)
        for extent in volume.systemExtents {
            for cluster in Int(extent.start)..<min(Int(extent.end), count) { owner[cluster] = -2 }
        }
        for (position, file) in plan.arrangement.enumerated() {
            for extent in file.extents {
                for cluster in Int(extent.start)..<min(Int(extent.end), count) {
                    switch owner[cluster] {
                    case -1: break
                    case -2: report.onSystem += 1
                    default: report.doubleBooked += 1
                    }
                    owner[cluster] = Int32(position)
                }
            }
        }

        // 2. Le déroulé : ce qui est vivant au moment de chaque écriture.
        //
        // Le flux d'opérations ne nomme pas le fichier déplacé — il n'a pas à
        // le faire, c'est une liste de requêtes au disque. Mais il porte ses
        // **validations**, et un déplacement tient entre deux d'entre elles :
        // ses lectures et ses écritures partagent le même intervalle. La règle
        // s'énonce alors sans identité : une écriture ne tombe que sur un
        // cluster libre, ou sur un cluster que le même déplacement vient de
        // lire — sa propre empreinte, dont le contenu est déjà dans le tampon.
        // Tout le reste est la donnée vivante de quelqu'un d'autre.
        var live = [Bool](repeating: false, count: count)
        for run in plan.initialRuns {
            for cluster in Int(run.start)..<min(Int(run.end), count) { live[cluster] = true }
        }
        var readIn = [Int32](repeating: -1, count: count)
        var move: Int32 = 0
        let clusterSectors = max(plan.partition.clusterSectors, 1)

        for operation in plan.operations {
            switch operation.kind {
            case .readExtent:
                guard let start = operation.cluster else { break }
                let length = operation.sectors / clusterSectors
                for cluster in start..<min(start + length, count) { readIn[cluster] = move }

            case .writeExtent:
                let first = Int(operation.mutationStart)
                let slice = plan.mutations[first..<(first + Int(operation.mutationCount))]
                for mutation in slice where mutation.category != .free {
                    var hit = 0
                    for cluster in mutation.start..<min(mutation.start + mutation.count, count) {
                        if live[cluster] && readIn[cluster] != move { hit += 1 }
                        live[cluster] = true
                    }
                    if hit > 0 {
                        report.overwrites += 1
                        report.overwrittenClusters += hit
                    }
                }
                for mutation in slice where mutation.category == .free {
                    for cluster in mutation.start..<min(mutation.start + mutation.count, count) {
                        live[cluster] = false
                    }
                }

            case .metadata:
                move += 1

            case .scan:
                break
            }
        }
        return report
    }
}

@Suite("Invariant d'allocation")
struct AllocationInvariantTests {

    /// Un volume d'essai serré : c'est le remplissage qui déclenche le cas, et
    /// pas le format. À 97 %, un occupant de la destination ne trouve plus
    /// toujours de refuge derrière la frontière — et c'est là que le plan de
    /// 1995 se posait quand même par-dessus.
    private static func tightVolume(fill: Double) -> DefragVolume {
        let partition = PartitionGeometry(startLBA: 0, clusterCount: 16_000,
                                          clusterSectors: 64, format: .fat16)
        return VolumeFactory.agedWindows95(partition: partition, fill: fill).defragVolume()
    }

    /// Les treize plans que la galerie sait produire — les huit algorithmes et
    /// les cinq tris de JkDefrag — sur un volume que son remplissage met en
    /// difficulté.
    @Test("Aucun plan n'écrit sur une donnée vivante",
          arguments: DefragPlanner.all.map(\.id), [0.80, 0.97])
    func noPlanOverwritesLiveData(strategyID: String, fill: Double) throws {
        let strategy = try #require(DefragPlanner.strategy(named: strategyID))
        let volume = Self.tightVolume(fill: fill)
        let sink = OperationSink()
        let plan = strategy.plan(volume: volume, into: sink)
            .with(operations: sink.operations, mutations: sink.mutations)

        let report = AllocationAudit.audit(plan, of: volume)
        #expect(report.isClean, "\(strategyID) à \(Int(fill * 100)) % : \(report.description)")
    }

    /// Le cas qui faisait écrire la passe de 1995 sur une donnée vivante, réduit
    /// à ce qui le produit : un occupant trop gros pour la place qui reste.
    ///
    /// `A` fait dix clusters et tient le début du volume ; `B`, deux clusters,
    /// est le premier du parcours et veut donc les clusters 0 et 1. Pour l'y
    /// mettre il faudrait évacuer `A` — mais il ne reste que deux clusters
    /// libres au bout du volume. `A` ne va nulle part, et la place reste prise.
    ///
    /// L'outil d'époque sautait la place. Le code la prenait quand même : les
    /// deux clusters de `B` s'écrivaient sur les deux premiers de `A`, qui
    /// restait pourtant référencé — 746 clusters sur six fichiers de `dev-1996`.
    @Test("Un occupant sans refuge garde sa place")
    func blockedOccupantKeepsItsPlace() {
        let partition = PartitionGeometry(startLBA: 0, clusterCount: 100,
                                          clusterSectors: 8, format: .fat16)
        // L'ordre du tableau est celui du parcours de l'arborescence. Le
        // fichier d'échange remplit le milieu du volume et ne bouge pas : c'est
        // lui qui ne laisse nulle part où évacuer `A`.
        let layout: [(String, ClusterCategory, Extent, Bool)] = [
            ("\\B.DAT", .document, Extent(start: 96, length: 2), true),
            ("\\A.DAT", .application, Extent(start: 0, length: 10), true),
            ("\\WIN386.SWP", .swap, Extent(start: 10, length: 86), false),
        ]
        let files = layout.enumerated().map { position, entry in
            DefragFile(id: UInt32(position), path: entry.0, category: entry.1,
                       walkOrder: position, extents: [entry.2], isMovable: entry.3)
        }
        let volume = DefragVolume(partition: partition, files: files)
        // Deux clusters libres en tout : trop peu pour loger les dix de `A`.
        #expect(volume.bitmap.freeCount == 2)

        let sink = OperationSink()
        let plan = Windows95Strategy().plan(volume: volume, into: sink)
            .with(operations: sink.operations, mutations: sink.mutations)

        let report = AllocationAudit.audit(plan, of: volume)
        #expect(report.isClean, "\(report.description)")
        // `A` n'a pas bougé, et `B` n'est pas venu sur son dos.
        let a = plan.arrangement.first { $0.id == 1 }
        #expect(a?.extents == [Extent(start: 0, length: 10)])
    }
}
