import Foundation
import DiskCore

/// Ce qu'un défragmenteur décide de faire d'un volume.
///
/// Le volume, sa géométrie et le coût d'une validation ne dépendent pas de
/// l'outil : ils sont dans `DefragVolume` et `PartitionGeometry`. Ce qui change
/// d'un outil à l'autre, c'est **l'ordre dans lequel les fichiers sont touchés
/// et l'endroit où ils atterrissent** — et c'est cela, plus que le format, qui
/// fait la signature sonore d'une passe :
///
/// - le défragmenteur de Windows 95 tasse tout contre le début du volume dans
///   l'ordre du parcours de l'arborescence, donc évacue sans arrêt et revient
///   au bord du plateau une fois par fichier ;
/// - `OptimizeVolume` de JKDefrag ne comble que les trous : presque pas
///   d'évacuations, des rafales courtes et dispersées ;
/// - une passe NTFS façon `FSCTL_MOVE_FILE` ne touche que les fichiers
///   réellement fragmentés — sur un volume de 2007, deux cents sur douze mille.
///
/// Une stratégie est une valeur et non un espace de noms : les variantes d'un
/// même outil (analyse seule, optimisation complète, comblement seul) sont des
/// réglages, pas des algorithmes différents.
protocol DefragStrategy {

    /// Identifiant stable, pour les réglages et les traces.
    var id: String { get }

    /// L'outil simulé, tel qu'un écran peut le nommer.
    var label: String { get }

    /// Les étapes traversées, dans l'ordre : l'indice d'une phase dans ce
    /// tableau est celui que portent ses opérations.
    var phases: [PhaseDescriptor] { get }

    /// Le volume passé n'est pas modifié — une stratégie travaille sur sa
    /// propre copie, où elle rejoue chaque déplacement pour connaître l'état
    /// d'arrivée.
    func plan(volume: DefragVolume) -> DefragPlan

    /// Ce que les compteurs de la passe veulent dire, en une phrase d'écran.
    ///
    /// Les mêmes nombres ne racontent pas la même histoire selon l'outil.
    /// « 921 évacuations » est la mécanique normale d'un tassage ; « 0
    /// évacuation » n'est pas un tassage qui aurait échoué, c'est le principe
    /// d'un outil qui ne déloge personne. Laisser l'écran commenter lui-même
    /// revenait à lui faire dire, sur une passe XP, que la destination est
    /// « presque toujours occupée » juste au-dessus d'un zéro.
    func summary(of plan: DefragPlan) -> String
}

// MARK: - Fabriques d'opérations

/// Ce que toute stratégie a besoin d'émettre : lire une zone, l'écrire
/// ailleurs, valider, et parcourir le volume au départ.
///
/// Rien ici ne décide de *quoi* déplacer ni *où* — ces fonctions ne savent que
/// traduire une décision déjà prise en requêtes bloc et en mutations de la
/// carte. C'est la frontière entre ce qui est commun à tous les défragmenteurs
/// et ce qui les distingue.
enum DefragOperations {

    /// L'analyse lit les tables d'allocation, la racine, puis chaque
    /// répertoire. Elle est étalée sur quelques secondes : à l'époque le coût
    /// dominant n'était pas le disque mais le parcours des chaînes en mémoire.
    static func analysis(partition: PartitionGeometry,
                         directoryCount: Int) -> [DiskOperation] {
        var ops: [DiskOperation] = []
        let span = 4.5

        for (index, access) in partition.scanAccesses.enumerated() {
            ops.append(DiskOperation(kind: .scan, phase: 0, lba: access.lba,
                                     sectors: access.sectors, isWrite: false,
                                     issueTime: 0.30 + 0.45 * Double(index),
                                     cluster: nil))
        }

        // Parcours des répertoires : leurs clusters sont dispersés dans la zone
        // de données, chaque lecture est un seek isolé au milieu du silence.
        var rng = SeededGenerator(seed: 0xDEF7_A61C)
        let count = max(directoryCount, 1)
        for index in 0..<count {
            let t = 2.0 + span * Double(index) / Double(count) * 0.55
            let cluster = rng.uniform(0...(partition.clusterCount - 1))
            ops.append(DiskOperation(kind: .scan, phase: 0,
                                     lba: partition.lba(ofCluster: cluster),
                                     sectors: partition.clusterSectors, isWrite: false,
                                     issueTime: t, cluster: cluster))
        }
        return ops
    }

    /// Déplacement d'une suite d'extents vers une autre, par tampons successifs.
    ///
    /// Chaque tampon est une lecture d'une portion de la source suivie de
    /// l'écriture de la portion de destination correspondante. Les deux
    /// découpages ne coïncident jamais — c'est tout le problème d'un fichier
    /// fragmenté — d'où le pas à pas sur la plus longue portion contiguë des
    /// deux côtés, plafonnée à la taille du tampon.
    ///
    /// `bufferBytes` est ce qui fixe le rythme des allers-retours
    /// lecture/écriture, donc le tempo de la passe : c'est un réglage de l'outil
    /// simulé, pas une constante.
    static func move(source: [Extent],
                     destination: [Extent],
                     category: ClusterCategory,
                     phase: Int,
                     partition: PartitionGeometry,
                     bufferBytes: Int,
                     into ops: inout [DiskOperation],
                     mutations store: inout [MapMutation]) {
        let buffer = UInt32(max(bufferBytes / partition.clusterBytes, 1))

        var sourceIndex = 0
        var sourceOffset: UInt32 = 0
        var destinationIndex = 0
        var destinationOffset: UInt32 = 0

        // Ce que la destination recouvre de la source : ces clusters-là ne
        // repassent pas en « libre », ils changent simplement de contenu.
        let kept = destination

        while sourceIndex < source.count && destinationIndex < destination.count {
            let from = source[sourceIndex]
            let to = destination[destinationIndex]
            let length = min(from.length - sourceOffset, to.length - destinationOffset, buffer)
            guard length > 0 else { break }

            let readStart = from.start + sourceOffset
            let writeStart = to.start + destinationOffset

            ops.append(DiskOperation(
                kind: .readExtent, phase: phase,
                lba: partition.lba(ofCluster: Int(readStart)),
                sectors: Int(length) * partition.clusterSectors,
                isWrite: false, issueTime: 0, cluster: Int(readStart)))

            let first = Int32(store.count)
            store.append(MapMutation(start: Int(writeStart), count: Int(length),
                                     category: category))
            store.append(contentsOf: freed(start: readStart, length: length, kept: kept))

            ops.append(DiskOperation(
                kind: .writeExtent, phase: phase,
                lba: partition.lba(ofCluster: Int(writeStart)),
                sectors: Int(length) * partition.clusterSectors,
                isWrite: true, issueTime: 0, cluster: Int(writeStart),
                mutationStart: first, mutationCount: Int32(store.count) - first))

            sourceOffset += length
            destinationOffset += length
            if sourceOffset == from.length { sourceIndex += 1; sourceOffset = 0 }
            if destinationOffset == to.length { destinationIndex += 1; destinationOffset = 0 }
        }
    }

    /// Les clusters d'une portion de source qui redeviennent libres : tout ce
    /// qui n'est pas recouvert par la destination du même fichier.
    private static func freed(start: UInt32, length: UInt32,
                              kept: [Extent]) -> [MapMutation] {
        var mutations: [MapMutation] = []
        var cursor = start
        let end = start + length

        while cursor < end {
            // Le premier extent conservé qui couvre `cursor` ?
            if let covering = kept.first(where: { $0.start <= cursor && $0.end > cursor }) {
                cursor = min(covering.end, end)
                continue
            }
            // Jusqu'où peut-on libérer sans heurter un extent conservé ?
            let next = kept.filter { $0.start > cursor }.map(\.start).min() ?? end
            let stop = min(next, end)
            if stop > cursor {
                mutations.append(MapMutation(start: Int(cursor), count: Int(stop - cursor),
                                             category: .free))
            }
            cursor = max(stop, cursor + 1)
        }
        return mutations
    }

    /// Validation d'un déplacement — ce que le format fait payer, et où.
    static func commit(cluster: Int,
                       fileIndex: Int,
                       phase: Int,
                       partition: PartitionGeometry,
                       into ops: inout [DiskOperation]) {
        for access in partition.commitAccesses(forCluster: cluster, fileIndex: fileIndex) {
            ops.append(DiskOperation(kind: .metadata, phase: phase, lba: access.lba,
                                     sectors: access.sectors, isWrite: true,
                                     issueTime: 0, cluster: nil))
        }
    }

    /// Réécriture complète des tables, en fin de passe.
    static func final(partition: PartitionGeometry, phase: Int) -> [DiskOperation] {
        var ops = partition.finalAccesses.map {
            DiskOperation(kind: .metadata, phase: phase, lba: $0.lba, sectors: $0.sectors,
                          isWrite: true, issueTime: 0, cluster: nil)
        }
        // Une dernière relecture, pour le point final.
        if let first = partition.finalAccesses.first {
            ops.append(DiskOperation(kind: .scan, phase: phase, lba: first.lba,
                                     sectors: first.sectors, isWrite: false,
                                     issueTime: 0, cluster: nil))
        }
        return ops
    }

    // MARK: - Mesures du volume

    /// Combien de répertoires l'analyse aura à parcourir.
    static func directoryCount(of volume: DefragVolume) -> Int {
        var directories = Set<String>()
        for file in volume.files {
            guard let slash = file.path.lastIndex(of: "\\") else { continue }
            directories.insert(String(file.path[file.path.startIndex..<slash]))
        }
        return max(directories.count, 1)
    }
}
