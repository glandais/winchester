import Foundation

/// Ce que l'outil de formatage pose devant la zone de données, et combien de
/// clusters il en reste.
///
/// Deux modules ont besoin de la réponse, et doivent avoir **la même** : le
/// générateur, qui compte les clusters que l'allocateur peut servir
/// (`ProfileSpec.clusterCount`), et le simulateur, qui pose la partition autour
/// (`PartitionGeometry`). Jusqu'au lot 8, le premier divisait la taille du
/// disque par celle d'un cluster sans rien déduire : sur `gamer-1999`, les deux
/// tables FAT32 font 17 Mo, et le volume généré dépassait d'autant le disque
/// qui le portait.
///
/// - **FAT** : les secteurs réservés — un sur FAT16, trente-deux sur FAT32 —,
///   les **deux** copies de la table, puis la racine de taille fixe d'un FAT16,
///   512 entrées de 32 octets. La table décrit aussi les deux entrées réservées
///   du début, d'où `n + 2` entrées pour `n` clusters. Le calcul est circulaire —
///   la table dépend du nombre de clusters, qui dépend de la place que la table
///   laisse — et se résout par itérations, comme le fait `FORMAT`.
/// - **NTFS** : rien devant. `$Boot` est le cluster 0, un fichier du volume
///   comme les autres métafichiers ; seule la copie du secteur d'amorçage, au
///   **dernier secteur** de la partition, est hors des clusters.
public enum FormatOverhead {

    /// 512 entrées de 32 octets : la racine d'un FAT16, de taille fixe.
    public static let fat16RootSectors = 32

    /// Secteurs réservés en tête de partition, avant la première table.
    public static func reservedSectors(_ kind: FileSystemKind) -> Int {
        switch kind {
        case .fat16, .vfat: return 1
        case .fat32:        return 32
        case .ntfs:         return 0
        }
    }

    public static func rootSectors(_ kind: FileSystemKind) -> Int {
        switch kind {
        case .fat16, .vfat: return fat16RootSectors
        case .fat32, .ntfs: return 0
        }
    }

    /// Octets décrivant un cluster dans la table d'allocation.
    public static func entryBytes(_ kind: FileSystemKind) -> Int {
        switch kind {
        case .fat16, .vfat: return 2
        case .fat32:        return 4
        case .ntfs:         return 0
        }
    }

    /// Secteurs d'une copie de la table, pour `clusterCount` clusters de
    /// données et les deux entrées réservées.
    public static func tableSectors(clusterCount: Int, kind: FileSystemKind) -> Int {
        let entry = entryBytes(kind)
        guard entry > 0 else { return 0 }
        let bytes = (clusterCount + 2) * entry
        return (bytes + DriveGeometry.bytesPerSector - 1) / DriveGeometry.bytesPerSector
    }

    /// Secteurs que le format occupe hors des clusters de données.
    public static func overheadSectors(clusterCount: Int, kind: FileSystemKind) -> Int {
        switch kind {
        case .ntfs:
            return 1
        case .fat16, .vfat, .fat32:
            return reservedSectors(kind) + 2 * tableSectors(clusterCount: clusterCount, kind: kind)
                + rootSectors(kind)
        }
    }

    /// Clusters de données d'une partition de `volumeSectors` secteurs : le
    /// plus grand nombre qui tienne avec ses tables.
    public static func clusterCount(volumeSectors: Int, clusterSectors: Int,
                                    kind: FileSystemKind) -> Int {
        guard clusterSectors > 0 else { return 0 }
        var count = max((volumeSectors - overheadSectors(clusterCount: 0, kind: kind)) / clusterSectors, 0)
        // La table grandit avec les clusters : on retire ce qu'elle prend
        // jusqu'à ce que tout tienne. Deux ou trois tours suffisent.
        while count > 0,
              overheadSectors(clusterCount: count, kind: kind) + count * clusterSectors > volumeSectors {
            let excess = overheadSectors(clusterCount: count, kind: kind) + count * clusterSectors
                - volumeSectors
            count -= max((excess + clusterSectors - 1) / clusterSectors, 1)
        }
        count = max(count, 0)
        // Et on reprend ce que le dernier retrait a pris de trop.
        while overheadSectors(clusterCount: count + 1, kind: kind) + (count + 1) * clusterSectors
                <= volumeSectors {
            count += 1
        }
        return count
    }
}
