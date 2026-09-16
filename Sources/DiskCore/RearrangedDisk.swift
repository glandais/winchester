import Foundation

extension GeneratedDisk {

    /// Le même disque, ses fichiers posés ailleurs : ce que devient un volume
    /// après une défragmentation.
    ///
    /// Seule la place change. Les fichiers gardent leurs noms, leurs tailles,
    /// leurs dates et leur ordre dans le catalogue ; la bitmap est refaite des
    /// nouveaux extents et de ce que le système se réserve, et les métriques
    /// sont réévaluées, de sorte qu'un démarrage — ou une autre passe — lise ce
    /// volume-là et non celui d'avant.
    ///
    /// Un fichier que `extents` ne nomme pas garde sa place : un défragmenteur
    /// ne touche ni aux fichiers résidents ni aux fichiers vides.
    public func rearranged(extents places: [UInt32: [Extent]]) -> GeneratedDisk {
        var copy = self
        for record in catalog.files {
            guard let extents = places[record.id] else { continue }
            var updated = record
            updated.entry.extents = extents
            copy.catalog[record.id] = updated
        }

        var bitmap = ClusterBitmap(clusterCount: self.bitmap.clusterCount)
        for extent in systemExtents where !extent.isEmpty { _ = bitmap.allocate(extent) }
        for record in copy.catalog.files where !record.isResident {
            for extent in record.extents where !extent.isEmpty { _ = bitmap.allocate(extent) }
        }
        copy.bitmap = bitmap

        let profile: any FileSystemProfile = spec.fileSystem.type == .ntfs
            ? NTFSProfile(clusterKB: spec.fileSystem.clusterKB ?? 4)
            : spec.resolvedFileSystem()
        copy.metrics = AllocationMetrics.evaluate(files: copy.catalog.files.map(\.entry),
                                                  bitmap: bitmap, profile: profile)
        return copy
    }
}
