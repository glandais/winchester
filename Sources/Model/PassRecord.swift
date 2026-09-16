import Foundation
import DiskCore

/// Le bilan d'une passe entendue jusqu'au bout.
///
/// Une passe ne garde que son présent ; le bilan est ce qui en reste une fois
/// finie, pour être relu, comparé à une autre, ou prolongé — relancer un autre
/// outil sur le même disque, démarrer le disque rangé.
struct PassRecord: Identifiable {

    enum Kind { case defrag, boot }

    let id = UUID()
    let passNumber: Int
    /// Le profil de la galerie, ou le titre d'un scénario livré.
    let diskID: String
    let title: String
    let kind: Kind
    /// L'outil d'une défragmentation, le système d'un démarrage.
    let toolLabel: String
    let toolID: String?
    /// L'outil qui avait rangé le disque démarré, s'il l'était.
    let rangedBy: String?
    let duration: Double
    let requests: Int
    let seeks: Int
    let averageSeek: Int
    let movedBytes: Int

    // Défragmentation.
    var before: VolumeStats?
    var after: VolumeStats?
    var filesMoved = 0
    var evacuations = 0
    var summary: String?
    var arrangement: [FileArrangement] = []
    /// Contenu du volume au départ, en octets : ce que « déplacé » rapporte.
    var contentBytes = 0.0
    var startMap: (grid: MapGrid, shades: [ClusterShade])?
    var endMap: (grid: MapGrid, shades: [ClusterShade])?

    // Démarrage.
    var freshSeconds: Double?

    /// Le disque d'origine, quand la passe venait de la galerie.
    var disk: GeneratedDisk?
}
