import Foundation
import DiskCore

/// Ce qu'une stratégie a déplacé jusqu'ici.
struct MoveCount: Sendable, Equatable {
    var filesMoved = 0
    var evacuations = 0
}

/// Là où une stratégie pose ses opérations, une à une.
///
/// Une passe de défragmentation se comptait en tableaux : toutes les
/// opérations, toutes les mutations de la carte, puis toutes les requêtes et
/// toute la chronologie qui en sortaient — sur le FAT32 de 6,4 Go de
/// `dev-1999`, 1,1 million d'opérations et 780 Mo de pic, mesurés avant que
/// le récepteur ne passe en flux —, pour une passe d'une heure dont on
/// n'entend jamais que la seconde en cours.
///
/// Le récepteur décide de ce qu'il garde :
///
/// - **sans aval**, il empile — c'est ce que lisent les tests, et le plan
///   d'une passe entière reste disponible pour qui le veut ;
/// - **avec un aval**, chaque opération y part aussitôt émise, avec les
///   mutations qu'elle applique, et rien n'est retenu. C'est ce qui permet de
///   simuler, de sonoriser et d'afficher une passe à mesure qu'elle se
///   planifie.
///
/// Une classe et non une valeur : la passe de JkDefrag est une structure
/// qu'on recopie et qu'on passe en `inout`, et c'est le même flux que toutes
/// ses copies doivent alimenter.
final class OperationSink {

    typealias Downstream = (DiskOperation, ArraySlice<MapMutation>,
                            _ progress: Double, _ moves: MoveCount) -> Void

    private(set) var operations: [DiskOperation] = []
    private(set) var mutations: [MapMutation] = []
    private let downstream: Downstream?

    /// Où en est la passe, de 0 à 1, tel que l'outil simulé le montrait.
    ///
    /// C'est la stratégie qui le tient, parce que c'est elle qui sait ce
    /// qu'« avancer » veut dire : un rang dans le parcours de l'arborescence
    /// pour Windows 95, une position sur le disque pour JkDefrag. La durée
    /// d'une passe, elle, n'est plus connue d'avance — l'avancement est la
    /// seule mesure qui reste.
    var progress: Double = 0

    /// Fichiers déplacés et évacuations comptés jusqu'ici, tels que la
    /// stratégie les compte pour son plan.
    ///
    /// Comme l'avancement, c'est la stratégie qui les tient : « un fichier
    /// déplacé » n'a pas le même sens pour un outil qui recopie les fichiers
    /// entiers et pour un autre qui n'en déplace que des morceaux. Ils partent
    /// avec l'opération suivante, et le plan final fait foi.
    var moves = MoveCount()

    /// Validations émises jusqu'ici. Sur NTFS, c'est ce compte qui fait avancer
    /// le journal : une page de `$LogFile` s'écrit quand huit validations
    /// l'ont remplie, quelle que soit la stratégie qui les a produites.
    private(set) var validations = 0

    /// Vidages forcés du journal qu'ont coûtés les réemplois de clusters
    /// récemment désalloués, sous XP (`DefragOperations.deletePending`).
    var logFlushes = 0

    /// Le temps que la passe a pris jusqu'ici, **estimé** requête par requête :
    /// un positionnement et un transfert pour chaque opération émise.
    ///
    /// Un planificateur n'a pas d'horloge — la durée d'une passe n'est connue
    /// qu'une fois ses requêtes jouées par `DiskSimulator`, bien après. Or une
    /// règle du volume se compte en secondes : NTFS fait un point de contrôle
    /// toutes les cinq secondes (`NTFSCheckpoints`). Cette horloge-ci en tient
    /// lieu. Elle ne connaît pas le disque, seulement ceux des volumes NTFS de
    /// la galerie — des 7 200 tr/min de 2003 à 2006 —, et elle ne sert qu'à
    /// placer ces points de contrôle.
    private(set) var plannedSeconds: Double = 0

    /// Les fiches dont cette horloge est tirée : les disques du catalogue de
    /// 2003 à 2006, ceux des volumes NTFS de la galerie — le Barracuda 7200.7
    /// et le 7200.10.
    private static let plannedDrives = DriveCatalog.all.filter { $0.isAnchor && (2003...2006).contains($0.year) }

    /// Un positionnement : le seek moyen des fiches et un demi-tour de plateau.
    /// Tiré du catalogue plutôt que recopié, pour qu'une fiche corrigée le
    /// corrige aussi — le 7200.10 a perdu ses 8,5 ms au profit des 11,0 de son
    /// manuel, et un littéral était resté sur l'ancienne valeur.
    static let plannedPositioning = mean(plannedDrives.map { $0.averageSeekMs / 1_000 + 30.0 / Double($0.rpm) })

    /// Un débit : celui que les fiches soutiennent en périphérie, rapporté au
    /// milieu du plateau — la moyenne du bord et du moyeu, où la piste n'a plus
    /// que `innerRatio` de ses secteurs.
    static let plannedBytesPerSecond = mean(plannedDrives.map {
        ($0.sustainedOuterMBs ?? 0) * (1 + DriveCatalog.innerRatio(year: $0.year)) / 2
    }) * 1_000_000

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    /// Rang de la validation qui commence, et compte d'une de plus.
    func nextValidation() -> Int {
        defer { validations += 1 }
        return validations
    }

    /// Un récepteur qui garde tout.
    init() {
        downstream = nil
    }

    /// Un récepteur qui passe tout à `downstream` et ne garde rien.
    init(downstream: @escaping Downstream) {
        self.downstream = downstream
    }

    /// Indice que portera la prochaine mutation enregistrée : c'est le début
    /// de la tranche qu'une opération désigne.
    var mutationMark: Int32 { Int32(mutations.count) }

    func reserveCapacity(_ count: Int) {
        guard downstream == nil else { return }
        operations.reserveCapacity(count)
        mutations.reserveCapacity(count)
    }

    func record(_ mutation: MapMutation) {
        mutations.append(mutation)
    }

    func emit(_ operation: DiskOperation) {
        plannedSeconds += Self.plannedPositioning
            + Double(operation.sectors * DriveGeometry.bytesPerSector) / Self.plannedBytesPerSecond
        guard let downstream else {
            operations.append(operation)
            return
        }
        let start = Int(operation.mutationStart)
        let end = start + Int(operation.mutationCount)
        downstream(operation, mutations[start..<end], progress, moves)
        // Les mutations d'une opération sont enregistrées juste avant elle :
        // une fois l'opération partie, plus personne ne les désignera.
        mutations.removeAll(keepingCapacity: true)
    }

    func emit(contentsOf operations: [DiskOperation]) {
        for operation in operations { emit(operation) }
    }
}
