import Foundation
import DiskCore

/// Modification de la carte des clusters, datée après coup par la simulation.
struct MapMutation {
    let start: Int
    let count: Int
    let category: ClusterCategory
}

/// Une requête bloc enrichie de ce qu'elle veut dire pour la carte et pour
/// l'affichage. Le simulateur ne consomme que `lba` / `sectors` / `isWrite` ;
/// le reste sert à rejouer visuellement la passe.
struct DiskOperation {

    enum Kind {
        /// Lecture des tables et des répertoires, pendant l'analyse.
        case scan
        case readExtent
        case writeExtent
        /// Validation d'un déplacement : tables d'allocation et entrée de
        /// répertoire sur FAT, enregistrement MFT sur NTFS.
        case metadata
    }

    let kind: Kind
    let phase: Int
    let lba: Int
    let sectors: Int
    let isWrite: Bool
    /// Date d'émission imposée, ou 0 : dès que le disque se libère.
    let issueTime: Double
    let cluster: Int?
    /// Plage de `DefragPlan.mutations` que cette opération applique.
    ///
    /// Les mutations sont rangées à plat dans le plan et non dans chaque
    /// opération : une passe sur un volume de 6 Go en compte un million, et un
    /// million de petits tableaux Swift coûtait à lui seul plusieurs centaines
    /// de mégaoctets — pour une ou deux mutations par opération.
    let mutationStart: Int32
    let mutationCount: Int32

    init(kind: Kind, phase: Int, lba: Int, sectors: Int, isWrite: Bool,
         issueTime: Double, cluster: Int?,
         mutationStart: Int32 = 0, mutationCount: Int32 = 0) {
        self.kind = kind
        self.phase = phase
        self.lba = lba
        self.sectors = sectors
        self.isWrite = isWrite
        self.issueTime = issueTime
        self.cluster = cluster
        self.mutationStart = mutationStart
        self.mutationCount = mutationCount
    }
}

struct PhaseDescriptor: Identifiable {
    let id: String
    let label: String
    let detail: String
}

struct VolumeStats {
    let fill: Double
    let fragmentedFiles: Int
    let fileCount: Int
    let extentsPerFile: Double
    let freeHoles: Int

    var fragmentedRatio: Double {
        fileCount > 0 ? Double(fragmentedFiles) / Double(fileCount) : 0
    }
}

struct DefragPlan {
    /// L'outil qui a produit ce plan.
    ///
    /// Le plan le porte plutôt que de recopier son nom : les compteurs qui
    /// suivent ne veulent pas dire la même chose d'une stratégie à l'autre —
    /// zéro évacuation est un aveu d'échec pour l'une et le principe même de
    /// l'autre — et c'est la stratégie, et elle seule, qui sait les commenter.
    let strategy: any DefragStrategy
    let partition: PartitionGeometry
    let initialMap: [UInt8]
    let operations: [DiskOperation]
    /// Toutes les mutations de la carte, à plat. Chaque opération en désigne
    /// une tranche.
    let mutations: [MapMutation]
    let phases: [PhaseDescriptor]
    let before: VolumeStats
    let after: VolumeStats
    let movedBytes: Int
    let filesMoved: Int
    let filesAlreadyInPlace: Int
    let evacuations: Int

    /// Le même plan, sans les opérations ni les mutations.
    ///
    /// Une fois la passe simulée et datée, l'écran n'a plus besoin que de la
    /// carte de départ et des compteurs. Les opérations, elles, se comptent en
    /// millions sur un volume d'époque réellement dimensionné.
    func summarized() -> DefragPlan {
        DefragPlan(strategy: strategy, partition: partition, initialMap: initialMap,
                   operations: [], mutations: [], phases: phases,
                   before: before, after: after, movedBytes: movedBytes,
                   filesMoved: filesMoved, filesAlreadyInPlace: filesAlreadyInPlace,
                   evacuations: evacuations)
    }
}

/// Le point d'entrée : à quel défragmenteur ce volume a-t-il affaire ?
///
/// Tout ce qui décide du déroulé d'une passe vit dans une `DefragStrategy` ;
/// ce qui reste ici est le choix de l'une d'entre elles, et il se fait sur le
/// format — c'est lui qui datait l'outil qu'on avait sous la main.
enum DefragPlanner {

    /// Le format date l'outil. Un volume FAT16 ou FAT32, c'est une machine de
    /// 1993 à 1999 : le défragmenteur livré avec Windows 95, puis 98. Un volume
    /// NTFS, c'est 2003 ou 2007, et l'outil qu'on avait sous la main est le
    /// `dfrg.msc` de Windows XP — qui ne range pas le volume, il répare les
    /// fichiers cassés.
    ///
    /// Rien n'interdirait de passer la stratégie de 95 sur un NTFS : cela
    /// marcherait, et ce serait un contresens de vingt-huit millions de
    /// requêtes.
    static func strategy(for format: VolumeFormat) -> any DefragStrategy {
        switch format {
        case .fat16, .fat32: return Windows95Strategy()
        case .ntfs:          return WindowsXPStrategy()
        }
    }

    static func plan(volume: DefragVolume) -> DefragPlan {
        strategy(for: volume.partition.format).plan(volume: volume)
    }

    static func stats(of volume: DefragVolume) -> VolumeStats { volume.stats }
}
