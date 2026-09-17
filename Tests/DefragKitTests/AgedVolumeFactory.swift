import Foundation
import DiskCore
@testable import DefragKit

/// Fabrique un volume tel qu'on le trouvait après deux ans d'usage : une
/// installation propre, puis des mois de création, suppression et extension de
/// fichiers, qui suffisent à disperser les fichiers de démarrage sur tout le
/// volume sans qu'aucun mécanisme exotique n'intervienne.
///
/// C'était le volume du scénario de défragmentation livré, décrit en parts de
/// capacité plutôt qu'en fichiers. Les deux démos tournent désormais sur des
/// disques de la galerie, vieillis par l'histoire d'un profil et par
/// l'allocateur de leur format ; ce vieillissement-ci ne sert plus qu'aux
/// tests, comme **volume d'essai** : il se fabrique en quelques millisecondes,
/// sans générateur ni catalogue, et donne à une stratégie de quoi travailler.
enum VolumeFactory {

    /// Part de la capacité occupée par chaque famille de fichiers à l'issue de
    /// l'installation. Le vieillissement ajoute ensuite son propre régime
    /// permanent de temporaires, et les documents grossissent : le volume finit
    /// aux alentours de 80 % de remplissage.
    private struct Budget {
        let directory: String
        let extension_: String
        let kind: ClusterCategory
        let share: Double
        let sizes: ClosedRange<Int>
    }

    private static let install: [Budget] = [
        Budget(directory: "\\WINDOWS", extension_: "BIN", kind: .system,
               share: 0.15, sizes: 8_000...900_000),
        Budget(directory: "\\WINDOWS\\SYSTEM", extension_: "DLL", kind: .system,
               share: 0.15, sizes: 6_000...600_000),
        Budget(directory: "\\WINDOWS\\HELP", extension_: "HLP", kind: .archive,
               share: 0.05, sizes: 40_000...1_400_000),
        Budget(directory: "\\PROGRA~1\\MSOFFICE", extension_: "DLL", kind: .application,
               share: 0.12, sizes: 20_000...2_200_000),
        Budget(directory: "\\PROGRA~1\\NETSCAPE", extension_: "DLL", kind: .application,
               share: 0.05, sizes: 15_000...1_500_000),
        Budget(directory: "\\MYDOCU~1", extension_: "DOC", kind: .document,
               share: 0.07, sizes: 12_000...900_000),
    ]

    /// Part de la capacité occupée par le fichier d'échange.
    private static let swapShare = 0.06

    /// Remplissage de référence des parts ci-dessus, avant mise à l'échelle.
    private static let referenceFill = 0.80

    /// - Parameter fill: taux de remplissage entretenu par l'utilisateur au fil
    ///   des mois. Toutes les parts d'installation sont mises à l'échelle pour
    ///   l'atteindre, et les temporaires sont purgés dès qu'il est dépassé.
    static func agedWindows95(partition: PartitionGeometry,
                              fill: Double = 0.80,
                              seed: UInt64 = 0x5EED_1995,
                              days: Int = 220) -> Volume {
        let fillCeiling = fill
        let scale = fill / referenceFill
        let volume = Volume(partition: partition)
        var rng = SeededGenerator(seed: seed)
        let capacity = Double(partition.capacityBytes)

        /// Distribution très dissymétrique : beaucoup de petits fichiers,
        /// quelques gros. Une loi uniforme donnerait un volume irréaliste.
        func size(_ range: ClosedRange<Int>, _ rng: inout SeededGenerator) -> Int {
            let u = Double.random(in: 0..<1, using: &rng)
            return range.lowerBound + Int(pow(u, 2.4) * Double(range.upperBound - range.lowerBound))
        }

        // 1. Installation de MS-DOS puis de Windows, répertoire par répertoire.
        //    L'ordre de création est celui du parcours de l'arborescence — c'est
        //    lui que suivra le défragmenteur.
        volume.create(path: "\\IO.SYS", kind: .system, bytes: 223_148)
        volume.create(path: "\\MSDOS.SYS", kind: .system, bytes: 1_676)
        volume.create(path: "\\COMMAND.COM", kind: .system, bytes: 93_890)

        var documentPaths: [String] = []
        for budget in install {
            var remaining = Int(capacity * budget.share * scale)
            var index = 0
            while remaining > 0 {
                let bytes = min(size(budget.sizes, &rng), remaining)
                let path = String(format: "%@\\F%04d.%@", budget.directory, index, budget.extension_)
                guard volume.create(path: path, kind: budget.kind, bytes: bytes) != nil else { break }
                if budget.kind == .document { documentPaths.append(path) }
                remaining -= max(bytes, partition.clusterBytes)
                index += 1
            }
        }

        // 2. Le fichier d'échange, créé au premier démarrage de Windows : il
        //    tombe donc après l'installation, au milieu du volume, et Windows le
        //    gardera ouvert — le défragmenteur ne pourra pas y toucher.
        volume.create(path: "\\WIN386.SWP", kind: .swap, bytes: Int(capacity * swapShare * scale))

        // 3. Deux ans d'usage. Chaque « journée » crée des temporaires et du
        //    cache, en supprime, et fait grossir quelques documents.
        var churnFiles: [Int] = []
        var churnCounter = 0
        let churnScale = max(capacity / 400_000_000, 0.15)
        // Croissance totale des documents sur la période, en octets. Sans ce
        // budget les réenregistrements saturent le volume et ne laissent plus
        // de place au cache — or c'est le cache qui fragmente le plus.
        var growthBudget = Int(capacity * 0.04)

        for day in 0..<days {
            // Régime permanent : un volume réel n'est jamais rempli à ras bord,
            // l'utilisateur fait de la place dès qu'il manque d'espace. C'est
            // cette limite qui fixe le taux de remplissage final.
            while volume.fill > fillCeiling, !churnFiles.isEmpty {
                let index = rng.uniform(0...(churnFiles.count - 1))
                volume.delete(churnFiles.remove(at: index))
            }

            let creations = volume.fill < fillCeiling
                ? max(Int(Double(rng.uniform(4...14)) * churnScale), 1) : 0
            for _ in 0..<creations {
                let isCache = rng.chance(0.65)
                let path = isCache
                    ? String(format: "\\WINDOWS\\TEMPOR~1\\C%05d.TMP", churnCounter)
                    : String(format: "\\WINDOWS\\TEMP\\T%05d.TMP", churnCounter)
                churnCounter += 1
                let bytes = isCache ? size(2_000...90_000, &rng) : size(4_000...700_000, &rng)
                if let id = volume.create(path: path, kind: .churn, bytes: bytes) {
                    churnFiles.append(id)
                }
            }

            // Le cache et les temporaires sont purgés en permanence : ce sont
            // eux qui creusent les trous dans lesquels tombera tout le reste.
            let deletions = min(churnFiles.count, max(Int(Double(rng.uniform(3...12)) * churnScale), 1))
            for _ in 0..<deletions where !churnFiles.isEmpty {
                let index = rng.uniform(0...(churnFiles.count - 1))
                volume.delete(churnFiles.remove(at: index))
            }

            // Extensions : un document rouvert et réenregistré, un journal qui
            // grossit. L'allocateur next-fit place la suite très loin du début.
            if !documentPaths.isEmpty, growthBudget > 0, volume.fill < fillCeiling {
                for _ in 0..<rng.uniform(2...7) where growthBudget > 0 {
                    let path = documentPaths[rng.uniform(0...(documentPaths.count - 1))]
                    let bytes = min(size(4_000...260_000, &rng), growthBudget)
                    if let id = volume.fileID(atPath: path) {
                        volume.append(id, bytes: bytes)
                        growthBudget -= bytes
                    }
                }
            }

            // Mise à jour trimestrielle : quelques fichiers système réécrits,
            // donc supprimés puis recréés ailleurs.
            if day % 55 == 40 {
                let systemPaths = volume.files.values
                    .filter { $0.kind == .system && $0.directory.hasSuffix("SYSTEM") }
                    .map(\.path)
                    .sorted()   // l'ordre d'un dictionnaire n'est pas reproductible
                guard !systemPaths.isEmpty else { continue }
                for _ in 0..<rng.uniform(6...18) {
                    let path = systemPaths[rng.uniform(0...(systemPaths.count - 1))]
                    if let id = volume.fileID(atPath: path), let old = volume.file(id: id) {
                        let bytes = old.chain.count * partition.clusterBytes
                        volume.delete(id)
                        volume.create(path: path, kind: .system,
                                      bytes: bytes + size(0...120_000, &rng))
                    }
                }
            }
        }

        return volume
    }
}
