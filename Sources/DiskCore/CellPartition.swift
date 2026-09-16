import Foundation

/// Le partage des clusters entre les blocs d'une carte.
///
/// Un bloc vaut `clusterCount / cellCount` clusters, **fraction comprise** :
/// arrondir cette part à l'entier inférieur faisait tomber tout le reste de la
/// division dans le dernier bloc. Sur une grille de plein écran le reste est
/// énorme — 850 Mo en FAT16 font 54 400 clusters ; sur 14 000 blocs, trois
/// clusters par bloc n'en couvraient que 42 000, et le cinquième du volume
/// s'entassait dans une seule case. Ici chaque bloc reçoit sa part à un
/// cluster près, en arithmétique entière pour que les bornes et la projection
/// d'un cluster ne se contredisent jamais.
///
/// Les deux cartes s'en servent — celle d'une passe et celle d'un disque de la
/// bibliothèque —, pour que la couleur d'un bloc et la liste de ce qu'il
/// contient parlent des mêmes clusters.
///
/// Quand il y a plus de blocs que de clusters, un bloc vaut un cluster et les
/// blocs au-delà du volume restent vides.
public struct CellPartition: Equatable, Sendable {

    public let clusterCount: Int
    public let cellCount: Int
    /// Ce que la grille découpe : le volume, ou un cluster par bloc s'il est
    /// plus petit que la grille.
    private let span: Int

    public init(clusterCount: Int, cellCount: Int) {
        self.clusterCount = max(clusterCount, 0)
        self.cellCount = max(cellCount, 1)
        self.span = max(self.clusterCount, self.cellCount)
    }

    /// Clusters par bloc, en moyenne — jamais moins d'un.
    public var clustersPerCell: Double { Double(span) / Double(cellCount) }

    /// Le bloc qui porte ce cluster : ⌊k · C / N⌋.
    public func cell(ofCluster cluster: Int) -> Int {
        min(max(cluster, 0) * cellCount / span, cellCount - 1)
    }

    /// Premier cluster du bloc : ⌈c · N / C⌉, la réciproque exacte de
    /// `cell(ofCluster:)`.
    public func start(ofCell cell: Int) -> Int {
        min((cell * span + cellCount - 1) / cellCount, clusterCount)
    }

    /// Les clusters du bloc. Vide pour un bloc au-delà du volume.
    public func clusters(ofCell cell: Int) -> Range<Int> {
        let low = start(ofCell: cell)
        let high = cell >= cellCount - 1 ? clusterCount : start(ofCell: cell + 1)
        return low..<max(low, high)
    }
}
