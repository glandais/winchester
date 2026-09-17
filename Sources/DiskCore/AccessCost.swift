import Foundation

/// Adressage des clusters d'un volume sur le disque : de quoi convertir un
/// numéro de cluster en LBA, sans rien savoir du système de fichiers.
public struct ClusterAddressing: Sendable {

    /// LBA du cluster 0 de la zone de données.
    public let dataStartLBA: Int
    public let sectorsPerCluster: UInt32

    public init(dataStartLBA: Int, sectorsPerCluster: UInt32) {
        precondition(sectorsPerCluster > 0)
        self.dataStartLBA = dataStartLBA
        self.sectorsPerCluster = sectorsPerCluster
    }

    public var clusterBytes: Int { Int(sectorsPerCluster) * DriveGeometry.bytesPerSector }

    public func lba(ofCluster cluster: UInt32) -> Int {
        dataStartLBA + Int(cluster) * Int(sectorsPerCluster)
    }

    public func sectors(forClusters count: UInt32) -> Int {
        Int(count) * Int(sectorsPerCluster)
    }
}

/// Modèle de coût d'accès : combien de temps met le disque à lire une liste
/// d'extents.
///
/// C'est cette fonction qui alimente la simulation de démarrage et qui donne un
/// sens chiffré à la fragmentation : deux fichiers de même taille, l'un
/// contigu et l'autre en cinquante morceaux, ne coûtent pas la même chose, et
/// l'écart est ce qu'on cherche à faire entendre.
///
/// Le débit n'est pas un paramètre : il se déduit de la géométrie zonée. Un
/// cylindre extérieur porte 468 secteurs par piste contre 248 au moyeu, soit un
/// rapport de débit de 1,9 à vitesse de rotation constante — l'effet ZBR
/// n'a pas besoin d'être postulé, il est déjà dans la table des zones. C'est
/// aussi ce qui justifie que le défragmenteur de XP remonte les fichiers de
/// démarrage en tête de volume.
public struct AccessCost: Sendable {

    public let geometry: DriveGeometry
    public let seekModel: SeekModel
    public let addressing: ClusterAddressing

    public init(geometry: DriveGeometry, seekModel: SeekModel, addressing: ClusterAddressing) {
        self.geometry = geometry
        self.seekModel = seekModel
        self.addressing = addressing
    }

    /// Latence rotationnelle moyenne : un demi-tour de plateau. 4,17 ms à
    /// 7 200 tr/min, 6,67 ms à 4 500.
    public var averageRotationalLatency: Double {
        geometry.revolutionDuration / 2
    }

    /// Débit instantané, en octets par seconde, au cylindre donné : une piste
    /// entière défile à chaque tour.
    public func throughput(atCylinder cylinder: Int) -> Double {
        Double(geometry.sectorsPerTrack(cylinder: cylinder) * DriveGeometry.bytesPerSector)
            / geometry.revolutionDuration
    }

    /// Temps de transfert d'une suite de secteurs à partir d'un LBA, pas de
    /// piste et commutations de tête compris.
    public func transferTime(startLBA: Int, sectors: Int) -> Double {
        guard sectors > 0 else { return 0 }
        var remaining = sectors
        var lba = startLBA
        var total = 0.0

        while remaining > 0 {
            let position = geometry.position(ofLBA: lba)
            let spt = geometry.sectorsPerTrack(cylinder: position.cylinder)
            let onThisTrack = min(remaining, spt - position.sector)
            total += Double(onThisTrack) * geometry.revolutionDuration / Double(spt)

            remaining -= onThisTrack
            lba += onThisTrack
            guard remaining > 0 else { break }

            // Fin de piste : commutation de tête dans le même cylindre, ou pas
            // de piste vers le cylindre suivant. Aucune attente rotationnelle
            // n'est facturée là, et ce n'est pas une approximation : c'est
            // exactement ce que le skew de `DriveGeometry.TrackSkew` paie, la
            // piste d'arrivée étant formatée décalée de ce que le
            // franchissement coûte. `DiskMechanics` fait la même hypothèse par
            // le même chemin — `angleOf` —, et `TrackSkewTests` vérifie que les
            // deux modèles facturent le même transfert, pour qu'ils ne divergent
            // pas en silence.
            total += position.head + 1 < geometry.heads
                ? seekModel.headSwitchDuration
                : seekModel.duration(distance: 1)
        }
        return total
    }

    /// Temps de lecture d'une liste d'extents, dans l'ordre logique du fichier.
    ///
    /// - Parameter startCylinder: position de la tête avant le premier accès.
    ///   Par défaut le début du volume, ce qui revient à supposer que le bras
    ///   vient de valider une écriture de métadonnées — le cas courant.
    /// - Returns: la durée totale, seeks inter-extents et latences comprises.
    public func readTime(extents: [Extent], startCylinder: Int = 0) -> TimeInterval {
        guard !extents.isEmpty else { return 0 }
        var total = 0.0
        var cylinder = startCylinder

        for extent in extents where !extent.isEmpty {
            let lba = addressing.lba(ofCluster: extent.start)
            let target = geometry.position(ofLBA: lba).cylinder

            let distance = abs(target - cylinder)
            if distance > 0 { total += seekModel.duration(distance: distance) }
            // Un extent ne commence jamais sous la tête : il faut attendre que
            // le secteur voulu passe. C'est ce demi-tour, payé à chaque
            // fragment, qui coûte cher sur un fichier éclaté — bien plus que le
            // seek lui-même quand les morceaux sont proches.
            total += averageRotationalLatency
            total += transferTime(startLBA: lba,
                                  sectors: addressing.sectors(forClusters: extent.length))

            let lastLBA = lba + addressing.sectors(forClusters: extent.length) - 1
            cylinder = geometry.position(ofLBA: lastLBA).cylinder
        }
        return total
    }

    /// Temps qu'aurait coûté la même lecture si le fichier était contigu, à
    /// partir de son premier extent. Le rapport des deux est la mesure la plus
    /// parlante de ce que la fragmentation coûte réellement.
    public func contiguousReadTime(extents: [Extent], startCylinder: Int = 0) -> TimeInterval {
        guard let first = extents.first else { return 0 }
        return readTime(extents: [Extent(start: first.start, length: extents.clusterCount)],
                        startCylinder: startCylinder)
    }

    /// Distance de seek, en cylindres, entre deux clusters. Sert aux métriques
    /// de sortie — la distance moyenne pondérée par la fréquence d'accès.
    public func seekDistance(from: UInt32, to: UInt32) -> Int {
        let a = geometry.position(ofLBA: addressing.lba(ofCluster: from)).cylinder
        let b = geometry.position(ofLBA: addressing.lba(ofCluster: to)).cylinder
        return abs(b - a)
    }
}
