import Foundation
import DiskCore

/// La passe « défragmentation complète (fichiers et espace libre) », la commande
/// que proposait le défragmenteur livré avec Windows 95, puis Windows 98 pour
/// FAT32.
///
/// Le principe tient en une phrase : rendre chaque fichier contigu et le tasser
/// contre le début du volume, dans l'ordre du parcours de l'arborescence — le
/// seul ordre dont l'outil disposait. Deux conséquences qui s'entendent :
///
/// - la destination d'un fichier est presque toujours occupée par un autre, qui
///   doit d'abord être **évacué** vers l'espace libre de la fin du volume. Ce
///   fichier-là sera relu et redéplacé quand viendra son tour. C'est ce
///   va-et-vient, et non le volume de données, qui fait durer une passe ;
/// - chaque déplacement validé réécrit les métadonnées, dont l'emplacement
///   dépend du format : sur FAT, les deux copies de la table et l'entrée de
///   répertoire, toutes trois au tout début de la partition. D'où le retour
///   systématique du bras vers le bord du plateau, à peu près une fois par
///   fichier : le « clac … clac … clac » régulier d'une défragmentation.
///
/// Le fichier d'échange n'est pas déplaçable : Windows l'a ouvert, et le
/// défragmenteur tasse tout autour de lui.
///
/// Tout le travail se fait en **extents** et jamais cluster par cluster : c'est
/// ce qui permet de planifier une passe sur un volume de 320 Go, où les 80
/// millions de clusters ne portent en tout que 178 000 extents.
///
/// Ses limites sont celles de son époque, et elles se mesurent : appliquée au
/// 320 Go de `famille-2007`, cette stratégie tasse trois cents gigaoctets par
/// tampons de 256 Ko pour ranger 244 fichiers fragmentés sur 12 220. Ce n'est
/// pas ce que faisaient les outils de 2007 — voir les autres `DefragStrategy`.
struct Windows95Strategy: DefragStrategy {

    let id = "windows95"
    let label = "Défragmenteur de Windows 95"

    /// Tampon de déplacement. L'outil d'époque travaillait sur quelques
    /// centaines de kilo-octets à la fois : c'est cette taille qui fixe le
    /// rythme des allers-retours lecture/écriture, donc le tempo de la passe.
    var bufferBytes = 256 * 1024

    let phases: [PhaseDescriptor] = [
        PhaseDescriptor(id: "analyse", label: "Analyse du volume",
                        detail: "Lecture des tables d'allocation et parcours de l'arborescence"),
        PhaseDescriptor(id: "system", label: "Fichiers système",
                        detail: "\\WINDOWS — les premiers du parcours, souvent déjà en place"),
        PhaseDescriptor(id: "apps", label: "Applications",
                        detail: "\\PROGRA~1 — gros fichiers, évacuations en cascade"),
        PhaseDescriptor(id: "docs", label: "Documents",
                        detail: "Fichiers réenregistrés des dizaines de fois, très éclatés"),
        PhaseDescriptor(id: "churn", label: "Temporaires et cache",
                        detail: "Des milliers de fragments d'un cluster : le martèlement"),
        PhaseDescriptor(id: "commit", label: "Écriture des tables d'allocation",
                        detail: "Réécriture complète des tables et de la racine"),
        PhaseDescriptor(id: "done", label: "Terminé",
                        detail: "Le volume ne tourne plus que pour lui-même"),
    ]

    func plan(volume input: DefragVolume, into sink: OperationSink) -> DefragPlan {

        var volume = input
        let partition = volume.partition
        let total = UInt32(partition.clusterCount)
        let before = volume.stats
        let initialRuns = volume.categoryRuns()

        // Trois opérations par fichier au minimum — une lecture, une écriture,
        // une validation — et bien plus dès que les fichiers sont éclatés.
        sink.reserveCapacity(volume.files.count * 8)
        var movedClusters = 0
        var filesMoved = 0
        var alreadyInPlace = 0
        var evacuations = 0

        // MARK: Phase 0 — analyse

        DefragOperations.analysis(partition: partition,
                                  directoryCount: DefragOperations.directoryCount(of: volume),
                                  into: sink)

        // MARK: Clusters intouchables

        // Ils tiennent en quelques extents — le fichier d'échange, et sur NTFS
        // la MFT et sa copie : aucune raison d'en faire un tableau de booléens
        // de la taille du volume.
        let blocked = (volume.files
            .filter { !$0.isMovable }
            .flatMap(\.extents) + volume.systemExtents)
            .sorted { $0.start < $1.start }

        // MARK: Empaquetage

        var frontier: UInt32 = 0
        var phase = 1

        for position in volume.files.indices {
            let file = volume.files[position]
            // L'outil comptait les fichiers du parcours : c'est son avancement.
            sink.progress = Double(position) / Double(volume.files.count)
            guard file.isMovable, file.clusterCount > 0 else { continue }
            phase = max(phase, file.category.packingGroup + 1)

            let need = file.clusterCount
            guard let destination = destination(from: frontier, need: need,
                                                blocked: blocked, total: total)
            else { break }
            let target = Extent(start: destination, length: need)

            // Déjà contigu et déjà au bon endroit : le défragmenteur ne le
            // touche pas. C'est pour cela qu'une passe démarre dans le calme,
            // puis s'emballe dès qu'elle atteint la zone remuée.
            if file.extents.count == 1 && file.extents[0] == target {
                frontier = target.end
                alreadyInPlace += 1
                continue
            }

            // 1. Évacuer ce qui occupe la destination.
            //
            // Un occupant qui ne trouve aucun refuge bloque la place : le
            // fichier ne se pose pas là. `DEFRAG.EXE` ne s'est jamais permis
            // d'écrire sur une donnée encore référencée — c'eût été détruire le
            // volume, et c'était la hantise de l'époque. Il sautait la place et
            // laissait le trou, exactement comme `FrontierCompactionStrategy`
            // le fait avec ses `shelters` ; la lenteur de ces outils est le prix
            // qu'ils payaient pour cette garantie-là.
            let reserved = frontier..<target.end
            var blockedHere = false
            for occupantPosition in volume.occupants(of: target.start..<target.end)
            where occupantPosition != position {
                let occupant = volume.files[occupantPosition]
                guard occupant.isMovable else { blockedHere = true; break }
                guard let refuge = freeRuns(in: volume, count: occupant.clusterCount,
                                            from: target.end, excluding: reserved, total: total)
                else { blockedHere = true; break }

                DefragOperations.move(source: occupant.extents, destination: refuge,
                                      category: occupant.category,
                                      contiguous: refuge.coalesced().count <= 1, phase: phase,
                                      partition: partition, bufferBytes: bufferBytes,
                                      into: sink)
                DefragOperations.commit(cluster: Int(refuge[0].start), fileIndex: occupantPosition,
                                        phase: phase, partition: partition, into: sink)
                volume.relocate(occupantPosition, to: refuge)
                movedClusters += Int(occupant.clusterCount)
                evacuations += 1
                sink.moves.evacuations = evacuations
            }

            // La place est restée prise : on la saute et on laisse le trou,
            // comme en 1995. La frontière avance quand même — l'outil ne
            // revenait jamais en arrière.
            if blockedHere {
                frontier = target.end
                continue
            }

            // 2. Déplacer le fichier vers sa destination définitive.
            //
            // L'invariant vaut pour les huit stratégies et pas pour celle-ci
            // seulement : tout plan qui écrit sur un cluster encore référencé
            // est faux. Il ne s'énonce pas en `bitmap.isFree(target)` — le
            // fichier occupe souvent déjà une partie de sa destination, et ces
            // clusters-là sont les siens. Ce que la place ne doit plus porter,
            // c'est la donnée de **quelqu'un d'autre**. L'audit de
            // `AllocationInvariantTests` le vérifie sur les treize plans ;
            // celle-ci le vérifie sur place, là où le manquement s'écrivait.
            assert(volume.occupants(of: target.start..<target.end).allSatisfy { $0 == position }
                   && !blocked.contains { $0.start < target.end && $0.end > target.start },
                   "\(id) : dépôt de \(file.path) sur \(target), encore occupé")
            DefragOperations.move(source: volume.files[position].extents, destination: [target],
                                  category: file.category, contiguous: true, phase: phase,
                                  partition: partition, bufferBytes: bufferBytes,
                                  into: sink)
            DefragOperations.commit(cluster: Int(target.start), fileIndex: position,
                                    phase: phase, partition: partition, into: sink)
            volume.relocate(position, to: [target])
            movedClusters += Int(need)
            filesMoved += 1
            sink.moves.filesMoved = filesMoved

            frontier = target.end
        }

        // MARK: Phase finale — réécriture complète des tables

        sink.progress = 1
        DefragOperations.final(partition: partition, phase: 5, into: sink)

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
            evacuations: evacuations,
            arrangement: volume.arrangement
        )
    }

    /// Ce qui fait durer une passe de 1995 n'est pas le volume de données, mais
    /// le va-et-vient : la destination d'un fichier est presque toujours prise.
    func summary(of plan: DefragPlan) -> String {
        String(format: "La passe déplace %d fichiers et en laisse %d en place, mais force "
               + "%d évacuations : la destination d'un fichier est presque toujours occupée "
               + "par un autre, qu'il faut d'abord pousser vers la fin du volume.",
               plan.filesMoved, plan.filesAlreadyInPlace, plan.evacuations)
    }

    // MARK: - Placement

    /// Première position ≥ `from` où `need` clusters consécutifs ne heurtent
    /// aucun cluster intouchable.
    private func destination(from: UInt32, need: UInt32,
                             blocked: [Extent], total: UInt32) -> UInt32? {
        var start = from
        while UInt64(start) + UInt64(need) <= UInt64(total) {
            if let hit = blocked.first(where: { $0.start < start + need && $0.end > start }) {
                start = hit.end
            } else {
                return start
            }
        }
        return nil
    }

    /// Des clusters libres où évacuer un occupant : au-delà de la zone en cours
    /// d'empaquetage, et sans toucher à la destination en préparation.
    ///
    /// L'occupant ressort souvent en plusieurs morceaux, et c'est normal : il
    /// n'est là qu'en transit, et sera relu puis redéplacé quand viendra son
    /// tour dans le parcours.
    private func freeRuns(in volume: DefragVolume, count: UInt32,
                          from: UInt32, excluding reserved: Range<UInt32>,
                          total: UInt32) -> [Extent]? {
        var result: [Extent] = []
        var remaining = count
        var cursor = max(from, reserved.upperBound)

        while remaining > 0, cursor < total {
            guard let run = volume.bitmap.nextFreeRun(from: cursor) else { break }
            guard run.start < total else { break }
            let take = min(run.length, remaining)
            result.append(Extent(start: run.start, length: take))
            remaining -= take
            cursor = run.start + run.length
        }
        return remaining == 0 ? result : nil
    }
}
