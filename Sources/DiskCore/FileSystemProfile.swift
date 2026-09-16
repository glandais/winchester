import Foundation

/// Contraintes d'un système de fichiers : ce qu'il sait faire, à quelle
/// granularité, et ce qu'il fait payer.
///
/// Séparé de l'allocateur à dessein : la taille de cluster et la résidence
/// décrivent le *format*, la stratégie de placement décrit le *pilote*. Un même
/// FAT16 en clusters de 32 Ko se comporte très différemment selon qu'il est
/// servi par MS-DOS ou par VFAT, et c'est le pilote qui change, pas le format.
public protocol FileSystemProfile: Sendable {

    var name: String { get }

    /// Taille d'un cluster en octets. **La** variable de l'époque : un FAT16 de
    /// 1996 sur un volume de 2 Go alloue par 32 Ko, et un fichier texte de 2 Ko
    /// en consomme donc trente. Sur un profil secrétaire, c'est un tiers du
    /// disque qui part en pure perte.
    var clusterBytes: UInt32 { get }

    /// Nombre maximal de clusters que le format sait adresser. FAT16 s'arrête à
    /// 65 524, ce qui est exactement la raison pour laquelle les clusters
    /// grossissaient avec le volume au lieu de se multiplier.
    var maxClusterCount: UInt32 { get }

    /// Un petit fichier peut-il vivre dans sa propre entrée de métadonnées,
    /// sans consommer le moindre cluster ? Vrai pour NTFS, faux pour FAT.
    var supportsResidentFiles: Bool { get }

    /// Taille au-delà de laquelle un fichier cesse d'être résident.
    var residentThresholdBytes: UInt64 { get }

    /// Octets consommés par l'entrée de métadonnées d'un fichier — un
    /// enregistrement MFT de 1 Ko, une entrée de répertoire de 32 octets.
    var directoryEntryBytes: UInt64 { get }
}

extension FileSystemProfile {

    /// Clusters nécessaires pour une taille logique. Un fichier non vide occupe
    /// toujours au moins un cluster.
    public func clusters(forBytes bytes: UInt64) -> UInt32 {
        guard bytes > 0 else { return 0 }
        let cluster = UInt64(clusterBytes)
        return UInt32((bytes + cluster - 1) / cluster)
    }

    public func isResident(bytes: UInt64) -> Bool {
        supportsResidentFiles && bytes <= residentThresholdBytes
    }

    /// Octets réellement immobilisés sur le disque.
    public func allocatedBytes(forLogicalSize bytes: UInt64) -> UInt64 {
        isResident(bytes: bytes) ? 0 : UInt64(clusters(forBytes: bytes)) * UInt64(clusterBytes)
    }

    /// Place perdue à la fin du dernier cluster. C'est la signature de l'époque
    /// FAT, et elle se mesure : sur un profil secrétaire de 1996, 30 à 40 % du
    /// volume.
    public func slackBytes(forLogicalSize bytes: UInt64) -> UInt64 {
        let allocated = allocatedBytes(forLogicalSize: bytes)
        return allocated > bytes ? allocated - bytes : 0
    }

    /// Le volume tient-il dans ce que le format sait adresser ?
    public func supports(clusterCount: UInt32) -> Bool {
        clusterCount > 0 && clusterCount <= maxClusterCount
    }
}

// MARK: - FAT16

/// FAT16 : pas de résidence, pas de noms longs sans l'extension VFAT, et
/// surtout 65 524 clusters au maximum. Un volume de 1 Go impose donc des
/// clusters de 16 Ko, un volume de 2 Go des clusters de 32 Ko.
public struct FAT16Profile: FileSystemProfile {

    public let clusterBytes: UInt32

    public var name: String { "FAT16 \(clusterBytes / 1024) Ko" }
    public var maxClusterCount: UInt32 { 65_524 }
    public var supportsResidentFiles: Bool { false }
    public var residentThresholdBytes: UInt64 { 0 }
    public var directoryEntryBytes: UInt64 { 32 }

    public init(clusterKB: UInt32) {
        precondition(clusterKB > 0 && clusterKB.nonzeroBitCount == 1,
                     "une taille de cluster est une puissance de deux")
        self.clusterBytes = clusterKB * 1_024
    }

    /// Taille de cluster qu'aurait choisie `FORMAT` pour ce volume : la plus
    /// petite puissance de deux qui fasse tenir le volume sous les 65 524
    /// clusters. C'est ce calcul, et rien d'autre, qui a donné leurs 32 Ko aux
    /// disques de 1996.
    public static func forVolume(bytes: UInt64) -> FAT16Profile {
        var clusterKB: UInt32 = 2
        while clusterKB < 64 {
            let clusters = bytes / UInt64(clusterKB * 1_024)
            if clusters <= 65_524 { break }
            clusterKB *= 2
        }
        return FAT16Profile(clusterKB: clusterKB)
    }
}

// MARK: - FAT32

/// FAT32 : le plafond de clusters disparaît, les clusters redeviennent petits
/// (4 Ko jusqu'à 8 Go), et le slack s'effondre. Ce qui fragmente change de
/// nature : ce n'est plus la taille du cluster, c'est le hint `next-free`.
public struct FAT32Profile: FileSystemProfile {

    public let clusterBytes: UInt32

    public var name: String { "FAT32 \(clusterBytes / 1024) Ko" }
    public var maxClusterCount: UInt32 { 268_435_444 }
    public var supportsResidentFiles: Bool { false }
    public var residentThresholdBytes: UInt64 { 0 }
    public var directoryEntryBytes: UInt64 { 32 }

    public init(clusterKB: UInt32 = 4) {
        precondition(clusterKB > 0 && clusterKB.nonzeroBitCount == 1)
        self.clusterBytes = clusterKB * 1_024
    }
}

// MARK: - NTFS

/// NTFS : un fichier assez petit tient dans son enregistrement MFT et
/// n'alloue **aucun** cluster. Un développeur de 2003 avec vingt mille fichiers
/// source produit donc une MFT énorme et très peu de clusters de données —
/// c'est exactement l'inverse de ce que produirait le même profil en FAT.
public struct NTFSProfile: FileSystemProfile {

    public let clusterBytes: UInt32

    public var name: String { "NTFS \(clusterBytes / 1024) Ko" }
    public var maxClusterCount: UInt32 { .max }
    public var supportsResidentFiles: Bool { true }

    /// Un enregistrement MFT fait 1 Ko, dont l'en-tête et les attributs
    /// obligatoires consomment la plus grande part : il reste autour de 700
    /// octets pour les données.
    public var residentThresholdBytes: UInt64 { 700 }
    public var directoryEntryBytes: UInt64 { 1_024 }

    /// Part du volume que NTFS réserve à la croissance de la MFT et tient à
    /// l'écart des données ordinaires.
    ///
    /// Aucun seuil de remplissage ne l'ouvre : elle cède de moitié chaque fois
    /// que le reste du volume est plein (`NTFSAllocator`).
    public let mftZoneShare: Double

    public init(clusterKB: UInt32 = 4,
                mftZoneShare: Double = 0.125) {
        precondition(clusterKB > 0 && clusterKB.nonzeroBitCount == 1)
        self.clusterBytes = clusterKB * 1_024
        self.mftZoneShare = mftZoneShare
    }
}
