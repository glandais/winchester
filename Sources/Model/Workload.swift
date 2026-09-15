import Foundation
import DiskCore

// MARK: - Requête bloc

struct BlockRequest {
    let issueTime: Double
    let lba: Int
    let sectorCount: Int
    let isWrite: Bool
    let phaseIndex: Int
}

// MARK: - Phase d'activité

/// Rampe linéaire : le débit d'une phase peut aussi bien monter que descendre,
/// ce qu'un `ClosedRange` ne sait pas exprimer.
struct Ramp {
    let start: Double
    let end: Double

    init(_ start: Double, _ end: Double) {
        self.start = start
        self.end = end
    }

    func value(at progress: Double) -> Double {
        start + (end - start) * min(max(progress, 0), 1)
    }
}

struct WorkloadPhase: Identifiable {

    /// Modèle de localité — c'est lui qui décide si le disque ronronne ou
    /// crépite. Le chargement de pilotes Windows est typiquement `clustered`
    /// avec beaucoup de clusters : la tête fait des allers-retours courts mais
    /// incessants entre `system32`, la base de registre et le cache de préchargement.
    enum Access {
        case idle
        /// Lecture séquentielle à partir d'une fraction du disque.
        case sequential(start: Double)
        /// Va-et-vient entre `clusters` zones chaudes réparties autour de `center`.
        case clustered(center: Double, spread: Double, clusters: Int)
        /// Accès uniformément répartis sur une plage.
        case random(low: Double, high: Double)
    }

    enum SpinCommand {
        case unchanged
        case spinUp
        case spinDown
    }

    let id: String
    let label: String
    let detail: String
    let duration: Double
    /// Débit de requêtes, interpolé linéairement du début à la fin de la phase.
    let rate: Ramp
    let sizeSectors: ClosedRange<Int>
    let writeRatio: Double
    let access: Access
    /// 0 = requêtes régulières, 1 = fortement groupées en rafales.
    let burstiness: Double
    let spin: SpinCommand

    var descriptor: PhaseDescriptor {
        PhaseDescriptor(id: id, label: label, detail: detail)
    }
}

/// Tranche de chronologie occupée par une phase, quel que soit le scénario :
/// une phase de scénario déclaratif a une durée imposée, une phase de
/// défragmentation ne se connaît qu'une fois la simulation faite.
struct PhaseSpan: Identifiable {
    let descriptor: PhaseDescriptor
    let index: Int
    let start: Double
    let end: Double
    var id: String { descriptor.id }
    var label: String { descriptor.label }
    var detail: String { descriptor.detail }
    var duration: Double { end - start }
}

// MARK: - Scénario

enum WorkloadLibrary {

    /// Découpage du disque tel qu'il l'est sur une installation Windows fraîche :
    /// le système en tête (LBA bas = cylindres extérieurs = les plus rapides),
    /// puis le fichier d'échange, les applications, et enfin le profil utilisateur.
    enum Region {
        static let bootSector      = 0.000
        static let systemFiles     = 0.045   // \WINDOWS\system32
        static let drivers         = 0.075   // \WINDOWS\system32\drivers
        static let registry        = 0.125   // ruches SYSTEM / SOFTWARE
        static let prefetch        = 0.155
        static let pagefile        = 0.300
        static let programFiles    = 0.470   // \Program Files\...\Office
        static let userProfile     = 0.700
    }

    /// « Démarrage Windows puis lancement d'une suite bureautique », ~60 s.
    /// Les durées et débits sont calés à l'oreille sur un PC de 2001 ;
    /// aucune trace réelle n'a été rejouée ici.
    static let windowsBootAndOffice: [WorkloadPhase] = [

        WorkloadPhase(
            id: "post",
            label: "POST BIOS",
            detail: "Mise en rotation du plateau, aucun accès",
            duration: 6.0,
            rate: Ramp(0, 0),
            sizeSectors: 1...1,
            writeRatio: 0,
            access: .idle,
            burstiness: 0,
            spin: .spinUp
        ),

        WorkloadPhase(
            id: "mbr",
            label: "MBR / secteur d'amorçage",
            detail: "Quelques lectures isolées en LBA 0",
            duration: 1.2,
            rate: Ramp(3, 5),
            sizeSectors: 1...4,
            writeRatio: 0,
            access: .sequential(start: Region.bootSector),
            burstiness: 0,
            spin: .unchanged
        ),

        WorkloadPhase(
            id: "loader",
            label: "Chargeur d'amorçage",
            detail: "boot.ini, détection matérielle — petites lectures groupées",
            duration: 2.0,
            rate: Ramp(12, 25),
            sizeSectors: 2...16,
            writeRatio: 0,
            access: .clustered(center: Region.bootSector + 0.004, spread: 0.006, clusters: 3),
            burstiness: 0.3,
            spin: .unchanged
        ),

        WorkloadPhase(
            id: "kernel",
            label: "Noyau + HAL",
            detail: "Lecture majoritairement séquentielle des fichiers système",
            duration: 3.5,
            rate: Ramp(40, 70),
            sizeSectors: 16...128,
            writeRatio: 0,
            access: .sequential(start: Region.systemFiles),
            burstiness: 0.2,
            spin: .unchanged
        ),

        WorkloadPhase(
            id: "drivers",
            label: "Chargement des pilotes",
            detail: "Le crépitement caractéristique : petites lectures dispersées",
            duration: 7.5,
            rate: Ramp(90, 150),
            sizeSectors: 2...24,
            writeRatio: 0.02,
            access: .clustered(center: Region.drivers, spread: 0.055, clusters: 14),
            burstiness: 0.65,
            spin: .unchanged
        ),

        WorkloadPhase(
            id: "services",
            label: "Démarrage des services",
            detail: "Lectures de registre entrecoupées d'écritures de journaux",
            duration: 8.0,
            rate: Ramp(70, 110),
            sizeSectors: 1...16,
            writeRatio: 0.22,
            access: .clustered(center: Region.registry, spread: 0.11, clusters: 9),
            burstiness: 0.5,
            spin: .unchanged
        ),

        WorkloadPhase(
            id: "shell",
            label: "Ouverture de session",
            detail: "Explorateur, icônes, profil utilisateur — accès très dispersés",
            duration: 7.0,
            rate: Ramp(110, 45),
            sizeSectors: 2...48,
            writeRatio: 0.15,
            access: .random(low: Region.systemFiles, high: Region.userProfile + 0.05),
            burstiness: 0.7,
            spin: .unchanged
        ),

        WorkloadPhase(
            id: "settle",
            label: "Bureau au repos",
            detail: "Traînards : préchargement, indexation",
            duration: 6.0,
            rate: Ramp(8, 2),
            sizeSectors: 1...32,
            writeRatio: 0.4,
            access: .random(low: Region.prefetch, high: Region.pagefile),
            burstiness: 0.85,
            spin: .unchanged
        ),

        WorkloadPhase(
            id: "office-prefetch",
            label: "Lancement suite bureautique · préchargement",
            detail: "Le fichier de préchargement est lu d'un trait",
            duration: 1.8,
            rate: Ramp(60, 90),
            sizeSectors: 32...256,
            writeRatio: 0,
            access: .sequential(start: Region.prefetch),
            burstiness: 0.1,
            spin: .unchanged
        ),

        WorkloadPhase(
            id: "office-dlls",
            label: "Lancement · chargement des bibliothèques",
            detail: "Dizaines de DLL éparpillées dans Program Files",
            duration: 5.5,
            rate: Ramp(130, 80),
            sizeSectors: 4...96,
            writeRatio: 0.05,
            access: .clustered(center: Region.programFiles, spread: 0.085, clusters: 18),
            burstiness: 0.6,
            spin: .unchanged
        ),

        WorkloadPhase(
            id: "office-warm",
            label: "Application prête",
            detail: "Modèle par défaut, polices, sauvegarde automatique",
            duration: 5.5,
            rate: Ramp(20, 6),
            sizeSectors: 2...64,
            writeRatio: 0.35,
            access: .random(low: Region.programFiles, high: Region.userProfile + 0.1),
            burstiness: 0.8,
            spin: .unchanged
        ),

        WorkloadPhase(
            id: "quiet",
            label: "Repos",
            detail: "Plus que la rotation du plateau",
            duration: 6.0,
            rate: Ramp(1, 0.4),
            sizeSectors: 1...8,
            writeRatio: 0.5,
            access: .random(low: Region.pagefile, high: Region.userProfile),
            burstiness: 0.9,
            spin: .unchanged
        ),
    ]
}

// MARK: - Génération de la trace bloc

struct WorkloadGenerator {

    let geometry: DriveGeometry

    func generate(phases: [WorkloadPhase], seed: UInt64 = 0xD15C_0FFE)
        -> (requests: [BlockRequest], spans: [PhaseSpan]) {

        var rng = SeededGenerator(seed: seed)
        var requests: [BlockRequest] = []
        var spans: [PhaseSpan] = []
        var clock: Double = 0

        for (index, phase) in phases.enumerated() {
            let start = clock
            let end = clock + phase.duration
            spans.append(PhaseSpan(descriptor: phase.descriptor, index: index,
                                   start: start, end: end))
            clock = end

            guard case .idle = phase.access else {
                emit(phase: phase, index: index, start: start, end: end, rng: &rng, into: &requests)
                continue
            }
        }

        return (requests, spans)
    }

    private func emit(phase: WorkloadPhase,
                      index: Int,
                      start: Double,
                      end: Double,
                      rng: inout SeededGenerator,
                      into requests: inout [BlockRequest]) {

        let total = geometry.totalSectors

        // État de localité, propre à la phase.
        var sequentialCursor = geometry.lba(ofFraction: {
            if case .sequential(let s) = phase.access { return s }
            return 0
        }())

        var clusterCenters: [Int] = []
        var currentCluster = 0
        var clusterSpread = 0.0
        if case .clustered(let center, let spread, let count) = phase.access {
            clusterSpread = spread
            for _ in 0..<max(count, 1) {
                let f = center + rng.gaussian() * spread * 0.6
                clusterCenters.append(geometry.lba(ofFraction: f))
            }
            currentCluster = rng.uniform(0...(clusterCenters.count - 1))
        }

        var t = start
        while t < end {
            let progress = (t - start) / max(phase.duration, 1e-9)
            let rate = phase.rate.value(at: progress)
            guard rate > 0.01 else { break }

            let lba: Int
            let size = rng.uniform(phase.sizeSectors)

            switch phase.access {
            case .idle:
                return

            case .sequential:
                lba = sequentialCursor % max(total - size, 1)
                // Un fichier n'est jamais parfaitement contigu : on saute de
                // temps en temps, ce qui produit un seek court et audible.
                sequentialCursor += size
                if rng.chance(0.06) {
                    sequentialCursor += rng.uniform(1_000...240_000)
                }

            case .clustered:
                if rng.chance(0.30) {
                    currentCluster = rng.uniform(0...(clusterCenters.count - 1))
                }
                let jitter = rng.gaussian() * clusterSpread * 0.12 * Double(total)
                lba = clamp(clusterCenters[currentCluster] + Int(jitter), total: total, size: size)

            case .random(let low, let high):
                let f = rng.uniform(low...high)
                lba = clamp(geometry.lba(ofFraction: f), total: total, size: size)
            }

            requests.append(BlockRequest(
                issueTime: t,
                lba: lba,
                sectorCount: size,
                isWrite: rng.chance(phase.writeRatio),
                phaseIndex: index
            ))

            // Rafales : avec une probabilité liée à `burstiness`, la requête
            // suivante suit quasi immédiatement ; sinon on laisse un trou plus
            // long pour conserver le débit moyen.
            let meanInterval = 1.0 / rate
            if rng.chance(phase.burstiness) {
                t += meanInterval * rng.uniform(0.02...0.18)
            } else {
                t += meanInterval * rng.uniform(0.8...2.4)
            }
        }
    }

    private func clamp(_ lba: Int, total: Int, size: Int) -> Int {
        min(max(lba, 0), max(total - size - 1, 0))
    }
}
