import Foundation
import DiskCore

/// Là où une stratégie pose ses opérations, une à une.
///
/// Une passe de défragmentation se comptait en tableaux : toutes les
/// opérations, toutes les mutations de la carte, puis toutes les requêtes et
/// toute la chronologie qui en sortaient. Sur le FAT32 de 6,4 Go de `dev-1999`
/// cela fait 1,1 million d'opérations et 780 Mo de pic, pour une passe qu'on
/// écoute pendant cinq heures et dont on n'entend jamais que la seconde en
/// cours.
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

    typealias Downstream = (DiskOperation, ArraySlice<MapMutation>, _ progress: Double) -> Void

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
        guard let downstream else {
            operations.append(operation)
            return
        }
        let start = Int(operation.mutationStart)
        let end = start + Int(operation.mutationCount)
        downstream(operation, mutations[start..<end], progress)
        // Les mutations d'une opération sont enregistrées juste avant elle :
        // une fois l'opération partie, plus personne ne les désignera.
        mutations.removeAll(keepingCapacity: true)
    }

    func emit(contentsOf operations: [DiskOperation]) {
        for operation in operations { emit(operation) }
    }
}
