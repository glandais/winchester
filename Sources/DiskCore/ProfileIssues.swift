import Foundation

/// Ce qui ne va pas dans un profil écrit à la main.
///
/// Les vingt scénarios du bundle sont relus ; un profil saisi dans l'app ne
/// l'est pas. Deux sortes de remarques : ce qui empêcherait de le fabriquer —
/// le générateur s'arrêterait net sur un cluster qui n'est pas une puissance de
/// deux —, et ce qui se fabrique mais ne ressemble à rien de ce qui a existé,
/// ou ne fera pas ce qu'on croit. Les secondes n'interdisent rien : un disque
/// anachronique est une question légitime.
public struct ProfileIssue: Sendable, Equatable, Identifiable {

    public enum Severity: Sendable, Equatable {
        /// Le disque ne se fabrique pas.
        case blocking
        /// Il se fabrique, mais ce n'est pas ce qu'on croit.
        case warning
    }

    public let severity: Severity
    /// Une phrase d'écran.
    public let message: String

    public var id: String { message }
}

extension ProfileSpec {

    /// Année d'arrivée des formats sur les machines grand public.
    private static let formatYears: [FileSystemKind: Int] = [
        .fat16: 1981, .vfat: 1995, .fat32: 1996, .ntfs: 2001,
    ]

    public var issues: [ProfileIssue] {
        var issues: [ProfileIssue] = []
        func block(_ message: String) { issues.append(ProfileIssue(severity: .blocking, message: message)) }
        func warn(_ message: String) { issues.append(ProfileIssue(severity: .warning, message: message)) }

        // Le matériel.
        if disk.sizeMB < 10 { block("Un disque de moins de 10 Mo n'a pas de place pour un système.") }
        if disk.rpm <= 0 { block("Le régime doit être positif.") }
        if disk.averageSeekMs <= 0 { block("Le seek moyen doit être positif.") }

        // Le format.
        if let cluster = fileSystem.clusterKB {
            if cluster == 0 || cluster.nonzeroBitCount != 1 {
                block("Une taille de cluster est une puissance de deux : \(cluster) Ko n'en est pas une.")
            } else if cluster > 64 {
                block("Aucun format de l'époque ne prend des clusters de plus de 64 Ko.")
            }
        }
        let clusterSizeIsValid = fileSystem.clusterKB.map { $0 > 0 && $0.nonzeroBitCount == 1 && $0 <= 64 } ?? true
        if clusterSizeIsValid && disk.sizeMB >= 10 {
            let profile = resolvedFileSystem()
            let wanted = disk.sizeBytes / UInt64(profile.clusterBytes)
            if wanted > UInt64(profile.maxClusterCount) {
                let reachable = UInt64(profile.maxClusterCount) * UInt64(profile.clusterBytes) / 1_048_576
                warn("\(fileSystem.type.rawValue.uppercased()) n'adresse que \(reachable) Mo avec des clusters de "
                     + "\(profile.clusterBytes / 1_024) Ko : le reste du disque ne servira pas.")
            }
        }
        let start = timeline.start.year
        if let year = Self.formatYears[fileSystem.type], start < year {
            warn("\(fileSystem.type.rawValue.uppercased()) n'arrive qu'en \(year) sur les machines grand public.")
        }

        // La période.
        if timeline.end <= timeline.start {
            block("La période d'usage doit finir après avoir commencé.")
        }
        for uninstall in uninstalls ?? [] {
            if !installs.contains(uninstall.app) {
                warn("« \(uninstall.app) » est désinstallé sans avoir été installé.")
            }
            if uninstall.date < timeline.start || uninstall.date > timeline.end {
                warn("Une désinstallation tombe hors de la période d'usage : elle sera ramenée à ses bornes.")
            }
        }
        if (defragRuns ?? []).contains(where: { $0 < timeline.start || $0 > timeline.end }) {
            warn("Une défragmentation planifiée tombe hors de la période d'usage : elle sera ramenée à ses bornes.")
        }

        // Les logiciels.
        let unknown = installs.filter { AppLibrary.manifest(id: $0) == nil }
        if !unknown.isEmpty {
            warn("Logiciels inconnus, ignorés : \(unknown.joined(separator: ", ")).")
        }
        return issues
    }

    public var isBuildable: Bool { !issues.contains { $0.severity == .blocking } }
}
