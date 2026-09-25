import Foundation

/// Ce qui ne va pas dans un profil écrit à la main.
///
/// Les vingt-quatre scénarios du bundle sont relus ; un profil saisi dans
/// l'app ne l'est pas. Deux sortes de remarques : ce qui empêcherait de le fabriquer —
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

    /// Ce qui ne va pas, avec ce qu'il faut pour le dire. La phrase d'écran
    /// n'est pas écrite ici : `DiskCore` ne se traduit pas, et l'app la
    /// compose dans la langue de l'appareil (`ProfileIssue.message`, dans
    /// `Sources/Model/DisplayFormat.swift`).
    public enum Kind: Sendable, Hashable {
        case diskTooSmall
        case nonPositiveRPM
        case nonPositiveSeek
        case clusterNotPowerOfTwo(kilobytes: UInt32)
        case clusterTooLarge
        /// Le format n'adresse qu'une partie du disque : `reachableMB` Mo
        /// (2²⁰ octets) avec des clusters de `clusterKB` Ko.
        case formatAddressesLess(FileSystemKind, reachableMB: UInt64, clusterKB: Int)
        /// Le format n'arrive qu'en `year` sur les machines grand public.
        case formatTooEarly(FileSystemKind, year: Int)
        case periodEndsBeforeStart
        case uninstalledWithoutInstall(app: String)
        case uninstallOutsidePeriod
        case defragOutsidePeriod
        case unknownSoftware([String])
        /// Un logiciel installé au premier jour sort après lui.
        case installedBeforeRelease(app: String, released: CivilDate)
    }

    public let severity: Severity
    public let kind: Kind

    public var id: Kind { kind }
}

extension ProfileSpec {

    /// Année d'arrivée des formats sur les machines grand public.
    private static let formatYears: [FileSystemKind: Int] = [
        .fat16: 1981, .vfat: 1995, .fat32: 1996, .ntfs: 2001,
    ]

    public var issues: [ProfileIssue] {
        var issues: [ProfileIssue] = []
        func block(_ kind: ProfileIssue.Kind) { issues.append(ProfileIssue(severity: .blocking, kind: kind)) }
        func warn(_ kind: ProfileIssue.Kind) { issues.append(ProfileIssue(severity: .warning, kind: kind)) }

        // Le matériel.
        if disk.sizeMB < 10 { block(.diskTooSmall) }
        if disk.rpm <= 0 { block(.nonPositiveRPM) }
        if disk.averageSeekMs <= 0 { block(.nonPositiveSeek) }

        // Le format.
        if let cluster = fileSystem.clusterKB {
            if cluster == 0 || cluster.nonzeroBitCount != 1 {
                block(.clusterNotPowerOfTwo(kilobytes: cluster))
            } else if cluster > 64 {
                block(.clusterTooLarge)
            }
        }
        let clusterSizeIsValid = fileSystem.clusterKB.map { $0 > 0 && $0.nonzeroBitCount == 1 && $0 <= 64 } ?? true
        if clusterSizeIsValid && disk.sizeMB >= 10 {
            let profile = resolvedFileSystem()
            if unclampedClusterCount > UInt64(profile.maxClusterCount) {
                let reachable = UInt64(profile.maxClusterCount) * UInt64(profile.clusterBytes) / 1_048_576
                warn(.formatAddressesLess(fileSystem.type, reachableMB: reachable,
                                          clusterKB: Int(profile.clusterBytes / 1_024)))
            }
        }
        let start = timeline.start.year
        if let year = Self.formatYears[fileSystem.type], start < year {
            warn(.formatTooEarly(fileSystem.type, year: year))
        }

        // La période.
        if timeline.end <= timeline.start {
            block(.periodEndsBeforeStart)
        }
        for uninstall in uninstalls ?? [] {
            if !installs.contains(uninstall.app) {
                warn(.uninstalledWithoutInstall(app: uninstall.app))
            }
            if uninstall.date < timeline.start || uninstall.date > timeline.end {
                warn(.uninstallOutsidePeriod)
            }
        }
        if (defragRuns ?? []).contains(where: { $0 < timeline.start || $0 > timeline.end }) {
            warn(.defragOutsidePeriod)
        }

        // Les logiciels.
        let unknown = installs.filter { AppLibrary.manifest(id: $0) == nil }
        if !unknown.isEmpty {
            warn(.unknownSoftware(unknown))
        }
        // Tout s'installe au premier jour ; un logiciel qui n'existait pas
        // encore ce jour-là est un anachronisme — dit, pas interdit.
        for manifest in installs.compactMap(AppLibrary.manifest(id:)) {
            if let released = manifest.releaseDate, released > timeline.start {
                warn(.installedBeforeRelease(app: manifest.displayName, released: released))
            }
        }
        return issues
    }

    public var isBuildable: Bool { !issues.contains { $0.severity == .blocking } }
}
