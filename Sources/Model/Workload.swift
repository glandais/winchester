import Foundation
import DiskCore

// MARK: - Requête bloc

/// Qui attend une requête, et quand elle part.
///
/// Le disque sert une commande à la fois, dans l'ordre du plan ; ce qui
/// change est **l'hôte**. Un démarrage ou une installation a un fil qui
/// calcule, puis demande, puis attend : c'est le premier plan. Sous NT,
/// d'autres requêtes partent sans que ce fil les attende — le préchargeur
/// qui émet tout un lot avant d'attendre (`pfsup.c:318-388`), le *lazy
/// writer* sur ses fils de travail, la lecture anticipée du cache — et le
/// calcul du premier plan continue pendant qu'elles occupent le disque.
enum RequestFlow: UInt8, Sendable {
    /// Le fil de l'hôte calcule `thinkTime`, puis émet et attend : la
    /// requête part quand le disque est libre et le calcul fini.
    case foreground
    /// Émise pour l'hôte sans qu'il l'attende : elle part dès que le disque
    /// est libre, et son `thinkTime` est du calcul que le fil fait pendant ce
    /// temps.
    case background
    /// Le fil attend d'abord que le disque ait fini tout ce qui a été émis
    /// avant elle — un événement qu'il attend, la fin d'un lot du
    /// préchargeur (`prefboot.c:936-955`) —, puis calcule, puis émet.
    case barrier
}

struct BlockRequest {
    /// Date d'émission imposée, ou 0 : dès que le disque se libère.
    let issueTime: Double
    let lba: Int
    let sectorCount: Int
    let isWrite: Bool
    let phaseIndex: Int
    /// Temps de calcul qui s'intercale entre la fin de la requête précédente et
    /// l'émission de celle-ci.
    ///
    /// Une passe qui part dès que le disque se libère — défragmentation,
    /// installation — n'en a pas besoin. Un démarrage décrit en fichiers, lui,
    /// n'est pas de ce genre : le système ouvre un fichier, le lit, en fait
    /// quelque chose, puis ouvre le suivant.
    /// C'est ce « en fait quelque chose » qui fixe le plancher d'un démarrage,
    /// et ce que le disque y ajoute est exactement ce qu'on écoute.
    let thinkTime: Double
    /// Qui l'attend (`RequestFlow`) : le premier plan partout, sauf ce que le
    /// noyau de NT émet de lui-même.
    let flow: RequestFlow

    init(issueTime: Double, lba: Int, sectorCount: Int, isWrite: Bool,
         phaseIndex: Int, thinkTime: Double = 0, flow: RequestFlow = .foreground) {
        self.issueTime = issueTime
        self.lba = lba
        self.sectorCount = sectorCount
        self.isWrite = isWrite
        self.phaseIndex = phaseIndex
        self.thinkTime = thinkTime
        self.flow = flow
    }
}

/// Tranche de chronologie occupée par une phase. Aucune n'est décrétée : une
/// phase ne se connaît qu'une fois la simulation faite, et c'est
/// `closedLoop(firstStarts:descriptors:duration:)` qui les date toutes.
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

extension PhaseSpan {

    /// Les phases d'un scénario en boucle fermée ne se datent qu'après coup :
    /// chacune commence quand sa première opération est prise en charge et
    /// s'arrête quand la suivante démarre.
    static func closedLoop(firstStarts: [Int: Double],
                           descriptors: [PhaseDescriptor],
                           duration: Double) -> [PhaseSpan] {
        // Une phase peut n'avoir aucune opération — le POST d'un démarrage, où
        // le plateau monte en régime sans que rien ne soit lu. Elle garde sa
        // place et sa durée : elle s'arrête quand la suivante commence.
        var starts = [Double](repeating: duration, count: descriptors.count)
        var next = duration
        for index in stride(from: descriptors.count - 1, through: 0, by: -1) {
            if let time = firstStarts[index] { next = min(next, time) }
            starts[index] = next
        }

        var spans: [PhaseSpan] = []
        var cursor = 0.0
        for index in descriptors.indices {
            // La première phase commence à zéro : ce qui précède la première
            // opération lui appartient, c'est le temps de mise en rotation.
            let start = index == 0 ? 0 : max(starts[index], cursor)
            let end = index + 1 < descriptors.count
                ? max(starts[index + 1], start)
                : duration
            spans.append(PhaseSpan(descriptor: descriptors[index], index: index,
                                   start: start, end: end))
            cursor = end
        }
        return spans
    }
}
