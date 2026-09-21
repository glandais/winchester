#if SCREENSHOTS
import Foundation

/// L'écran sur lequel l'app s'ouvre en mode capture.
///
/// Un lancement par capture, sans un seul tap : le script n'a jamais à trouver
/// un onglet par son libellé, qui change d'une langue à l'autre.
enum ScreenshotScreen: String {
    /// La passe, sur sa carte.
    case pass
    /// La passe, sur le plateau et le bras.
    case platter
    /// La carte de la passe en plein écran.
    case fullmap
    /// Les instruments de la passe.
    case instruments
    /// L'onglet Disques : les démos et la galerie d'époque.
    case disks
    /// La fiche d'un disque de la galerie, sa carte vieillie en tête.
    case disk
    /// Le choix du défragmenteur pour ce disque.
    case tools
}

/// Les arguments de lancement qui mènent les captures de l'App Store.
///
/// Compilé seulement dans la configuration `Screenshots` (voir `project.yml`) :
/// rien de ceci n'existe dans le binaire archivé.
///
/// `simctl launch … -screenshotMode YES -screenshotScreen fullmap` écrit dans le
/// domaine `NSArgumentDomain` d'`UserDefaults` : il n'y a rien à analyser.
enum ScreenshotMode {
    static let isActive = UserDefaults.standard.bool(forKey: "screenshotMode")

    static let screen = ScreenshotScreen(
        rawValue: UserDefaults.standard.string(forKey: "screenshotScreen") ?? "") ?? .pass

    /// Où en est la démo de défragmentation quand on la capture, en secondes
    /// de passe. Elle dure 5 min 22 : à 150 s, la frontière a balayé la moitié
    /// du volume, et la carte montre à la fois le rangé et le reste à ranger.
    static let passTime: Double = {
        let value = UserDefaults.standard.double(forKey: "screenshotAt")
        return value > 0 ? value : 150
    }()

    /// Le disque de la galerie qu'ouvrent la fiche et le choix de l'outil.
    static let diskID = UserDefaults.standard.string(forKey: "screenshotDisk") ?? "famille-1999"

    static var tab: AppTab {
        switch screen {
        case .pass, .platter, .fullmap: return .pass
        case .instruments:              return .instruments
        case .disks, .disk, .tools:     return .disks
        }
    }

    static var disksPath: [String] {
        switch screen {
        case .disk, .tools: return [diskID]
        default:            return []
        }
    }

    /// Met la démo de défragmentation en place, avancée jusqu'à `passTime`,
    /// puis la laisse jouer — sans le son : le simulateur sortirait sinon par
    /// les haut-parleurs du Mac à chaque capture.
    ///
    /// Tous les écrans l'ont : la galerie et la fiche portent le bandeau de la
    /// passe en cours, comme elles le porteraient entre les mains de quelqu'un.
    ///
    /// La fiche et le choix de l'outil attendent en plus que la galerie ait
    /// fabriqué leur disque : « Famille, 1999 » pèse 6,4 Go et se fabrique en
    /// plus de temps que la démo n'en met à s'avancer — la capture montrait
    /// sinon la barre de « Fabrication du volume ».
    @MainActor
    static func stage(_ model: SimulationModel, library: DiskLibraryModel) async {
        model.engine.masterLevel = 0
        model.engine.hapticsEnabled = false
        model.select(.builtin(.defrag))
        await model.engine.fastForward(to: passTime)
        model.engine.play()
        // `play()` attend parfois que la passe ait pris de l'avance : la
        // seconde `passTime` ne s'entend qu'une fois la lecture partie.
        while !model.engine.isPlaying {
            try? await Task.sleep(for: .milliseconds(2))
        }
        let playbackStart = Date()
        if screen == .disk || screen == .tools {
            while library.state.disk?.spec.id != diskID {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        signalReady(playbackStart: playbackStart)
    }

    /// Le fichier que `scripts/screenshots.sh` attend avant de capturer, dans
    /// le `tmp/` du conteneur de l'app : le disque de la démo se fabrique au
    /// lancement, et le temps que cela prend en Debug varie du simple au double
    /// d'une machine à l'autre. Attendre un témoin vaut mieux qu'un délai fixe
    /// qui serait tantôt trop court, tantôt perdu.
    ///
    /// Il porte l'écran, puis l'instant où la lecture est partie de `passTime`,
    /// en secondes Unix : le simulateur partage l'horloge du Mac, et
    /// `scripts/previews.sh` en déduit où tombe cette seconde de passe dans la
    /// vidéo qu'il enregistre, pour y poser le son de `RenderTrace`.
    static let readyMarker = FileManager.default.temporaryDirectory
        .appendingPathComponent("screenshot-ready")

    private static func signalReady(playbackStart: Date) {
        let line = "\(screen.rawValue) \(playbackStart.timeIntervalSince1970)\n"
        try? Data(line.utf8).write(to: readyMarker, options: .atomic)
    }
}

extension AppTab {
    /// L'onglet de départ.
    static var launch: AppTab { ScreenshotMode.isActive ? ScreenshotMode.tab : .disks }
}
#else
extension AppTab {
    static var launch: AppTab { .disks }
}
#endif
