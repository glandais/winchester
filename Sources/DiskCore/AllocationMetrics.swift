import Foundation

/// Ce qu'on mesure sur un volume une fois l'histoire rejouée.
///
/// Aucune de ces valeurs n'est un paramètre d'entrée : ce sont toutes des
/// conséquences. C'est le sens du modèle — on ne demande pas « 23 % de
/// fragmentation », on constate ce que la séquence d'événements a produit en
/// passant dans un allocateur donné.
public struct AllocationMetrics: Sendable, Equatable {

    public var fileCount: Int
    public var residentFileCount: Int
    /// Fichiers occupant plus d'un extent.
    public var fragmentedFileCount: Int
    /// Fichiers occupant plus d'un cluster — les seuls qui *puissent* être
    /// fragmentés. La distinction n'est pas un détail : en FAT16 avec des
    /// clusters de 32 Ko, l'écrasante majorité des fichiers d'un volume tient
    /// dans un cluster et ne sera jamais fragmentée, quoi qu'il arrive. Un taux
    /// de fragmentation rapporté à l'ensemble des fichiers mesure donc d'abord
    /// la population du volume, et seulement ensuite l'allocateur.
    public var fragmentableFileCount: Int

    public var meanExtentsPerFile: Double
    /// Percentile 95 du nombre d'extents : c'est lui qui dit si quelques
    /// fichiers sont catastrophiques, là où la moyenne reste présentable.
    public var p95ExtentsPerFile: Int
    public var maxExtentsPerFile: Int
    public var meanExtentClusters: Double

    public var usedClusters: UInt32
    public var freeClusters: UInt32
    public var freeRunCount: Int
    public var largestFreeRunClusters: UInt32

    /// Octets perdus en fin de cluster, et leur part du volume.
    public var slackBytes: UInt64
    public var logicalBytes: UInt64
    public var allocatedBytes: UInt64

    public var fill: Double

    public var fragmentedRatio: Double {
        let nonResident = fileCount - residentFileCount
        return nonResident > 0 ? Double(fragmentedFileCount) / Double(nonResident) : 0
    }

    /// Taux de fragmentation rapporté aux seuls fichiers qui pouvaient l'être.
    /// C'est la mesure qui juge l'allocateur.
    public var fragmentedRatioAmongFragmentable: Double {
        fragmentableFileCount > 0
            ? Double(fragmentedFileCount) / Double(fragmentableFileCount)
            : 0
    }

    /// Part du **volume** perdue en slack. Sur un FAT16 en clusters de 32 Ko
    /// peuplé de petits documents, elle dépasse 30 %.
    public var slackRatio: Double {
        allocatedBytes > 0 ? Double(slackBytes) / Double(allocatedBytes) : 0
    }

    /// Mesure un ensemble de fichiers sur un volume donné. Les fichiers sont
    /// passés dans un ordre stable par l'appelant : aucune mesure ne doit
    /// dépendre de l'ordre d'itération d'un dictionnaire.
    public static func evaluate(files: [FileEntry],
                                bitmap: ClusterBitmap,
                                profile: any FileSystemProfile) -> AllocationMetrics {
        var extentCounts: [Int] = []
        extentCounts.reserveCapacity(files.count)

        var residents = 0
        var fragmented = 0
        var fragmentable = 0
        var totalExtents = 0
        var totalClusters: UInt64 = 0
        var logical: UInt64 = 0
        var allocated: UInt64 = 0
        var slack: UInt64 = 0

        for file in files {
            logical += file.logicalSize
            if file.isResident {
                residents += 1
                continue
            }
            let count = file.extents.count
            extentCounts.append(count)
            totalExtents += count
            totalClusters += UInt64(file.clusterCount)
            if count > 1 { fragmented += 1 }
            if file.clusterCount > 1 { fragmentable += 1 }

            let bytes = UInt64(file.clusterCount) * UInt64(profile.clusterBytes)
            allocated += bytes
            slack += bytes > file.logicalSize ? bytes - file.logicalSize : 0
        }

        extentCounts.sort()
        let nonResident = extentCounts.count

        return AllocationMetrics(
            fileCount: files.count,
            residentFileCount: residents,
            fragmentedFileCount: fragmented,
            fragmentableFileCount: fragmentable,
            meanExtentsPerFile: nonResident > 0 ? Double(totalExtents) / Double(nonResident) : 0,
            p95ExtentsPerFile: percentile(extentCounts, 0.95),
            maxExtentsPerFile: extentCounts.last ?? 0,
            meanExtentClusters: totalExtents > 0 ? Double(totalClusters) / Double(totalExtents) : 0,
            usedClusters: bitmap.usedCount,
            freeClusters: bitmap.freeCount,
            freeRunCount: bitmap.freeRunCount(),
            largestFreeRunClusters: bitmap.largestFreeRun()?.length ?? 0,
            slackBytes: slack,
            logicalBytes: logical,
            allocatedBytes: allocated,
            fill: bitmap.fill
        )
    }

    /// Percentile sur une suite **déjà triée**, par rang au plus proche : pas
    /// d'interpolation, la grandeur mesurée est un nombre d'extents.
    private static func percentile(_ sorted: [Int], _ p: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

extension AllocationMetrics: CustomStringConvertible {

    public var description: String {
        String(format: """
        %d fichiers (%d résidents) · %.1f %% fragmentés
        dont %d de plus d'un cluster, fragmentés à %.1f %%
        extents/fichier : %.2f moyen, %d au p95, %d au pire
        espace libre : %d trous, plus grand bloc %d clusters
        slack : %.1f %% · remplissage %.1f %%
        """,
        fileCount, residentFileCount, fragmentedRatio * 100,
        fragmentableFileCount, fragmentedRatioAmongFragmentable * 100,
        meanExtentsPerFile, p95ExtentsPerFile, maxExtentsPerFile,
        freeRunCount, largestFreeRunClusters,
        slackRatio * 100, fill * 100)
    }
}
