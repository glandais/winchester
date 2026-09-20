import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// L'invariant d'allocation, rejoué sur les vingt volumes de la galerie.
///
/// `AllocationInvariantTests` le vérifie sur un volume d'essai FAT16 de seize
/// mille clusters : ni NTFS, ni zone MFT, ni clusters retenus jusqu'au point de
/// contrôle, ni aucun des volumes FAT sur lesquels la revue avait trouvé la
/// faute (`dev-1996`, 746 clusters écrasés). L'assertion de `Windows95Strategy`
/// ne le vérifie pas davantage : elle disparaît en release, et aucune autre
/// stratégie n'en a. Ici, chaque plan que l'application sait produire — les
/// quatorze stratégies de `DefragPlanner.all`, et en blocs pleins les dix qui
/// en ont l'option — passe par le même audit, sur les volumes qu'on écoute.
///
/// C'est une mesure lourde : vingt générations, vingt-quatre plans chacune,
/// dont le rangement intelligent sur les NTFS, qui est un tassage complet. Elle ne
/// tourne que si `DEFRAG_GALLERY_AUDIT` est présent, et en release :
///
///     DEFRAG_GALLERY_AUDIT=1 swift test -c release --filter GalleryAllocationAudit
///
/// Les volumes passent un à un : un NTFS de 2007 tient plusieurs centaines de
/// mégaoctets, et vingt en parallèle ne tiendraient pas en mémoire. Une liste
/// de profils à la place de `1` n'audite qu'eux :
///
///     DEFRAG_GALLERY_AUDIT=dev-1996,gamer-1996 swift test -c release …
private let galleryAudit = ProcessInfo.processInfo.environment["DEFRAG_GALLERY_AUDIT"]
private let galleryAuditEnabled = galleryAudit != nil
private let auditedProfiles: Set<String>? = galleryAudit.flatMap { value in
    value == "1" ? nil : Set(value.split(separator: ",").map(String.init))
}

@Suite("Invariant d'allocation, sur la galerie", .serialized, .enabled(if: galleryAuditEnabled))
struct GalleryAllocationAuditTests {

    /// Les plans de l'application : chaque stratégie, munie de `Layout.ini`
    /// quand elle sait le lire, et les trois qui ont l'option en blocs pleins.
    private static func tools(for disk: GeneratedDisk) -> [any DefragStrategy] {
        let layout = BootLayout(disk: disk)
        let informed: [any DefragStrategy] = DefragPlanner.all.map { strategy in
            guard let consumer = strategy as? any BootLayoutConsumer else { return strategy }
            return consumer.informed(by: layout)
        }
        return informed + DefragPlanner.all.compactMap(DefragPlanner.withFullBlocks)
    }

    @Test("Aucun plan n'écrit sur une donnée vivante, sur les vingt volumes",
          arguments: ScenarioLibrary.identifiers)
    func noPlanOverwritesLiveDataOnTheGallery(profile: String) throws {
        guard auditedProfiles?.contains(profile) ?? true else { return }
        let started = Date()
        let disk = try DiskGenerator.generate(try ScenarioLibrary.load(profile))
        let volume = try GeneratedVolumeBridge.volume(from: disk)
        let tools = Self.tools(for: disk)
        for tool in tools {
            let sink = OperationSink()
            let plan = tool.plan(volume: volume, into: sink)
                .with(operations: sink.operations, mutations: sink.mutations)
            let report = AllocationAudit.audit(plan, of: volume)
            let blocks = (tool as? WindowsXPStrategy)?.fullBlocks == true
                || (tool as? UltraDefragStrategy)?.fullBlocks == true
                || (tool as? JKDefragStrategy)?.fullBlocks == true
            #expect(report.isClean,
                    "\(profile), \(tool.id)\(blocks ? " en blocs pleins" : "") : \(report.description)")
        }
        print(String(format: "  %@ : %d plans audités en %.0f s", profile, tools.count,
                     Date().timeIntervalSince(started)))
    }
}
