import Foundation
import DiskCore

/// Ce qu'un démarrage lit, dans l'ordre où il le lit : ce que le préchargeur
/// de Windows XP écrit dans `Layout.ini` après quelques démarrages, et que le
/// défragmenteur relit pour poser ces fichiers à la suite. Windows 98 avait la
/// même idée, plus tôt : le moniteur de tâches notait ce que chaque programme
/// ouvrait, et « Réorganiser les fichiers programme pour accélérer leur
/// démarrage » s'en servait.
///
/// Ce n'est pas une information que le défragmenteur devine : c'est le système
/// qui la lui donne. Le disque la fabrique ici en planifiant un démarrage
/// (`BootPlanner`), sans le simuler.
struct BootLayout: Sendable {

    /// Les identifiants du catalogue, dans l'ordre de lecture.
    let files: [UInt32]

    init(files: [UInt32]) { self.files = files }

    init(disk: GeneratedDisk) {
        files = BootPlanner.plan(disk: disk).readOrder
    }
}

/// Une stratégie qui sait lire `Layout.ini`.
protocol BootLayoutConsumer: DefragStrategy {
    func informed(by layout: BootLayout) -> Self
}
