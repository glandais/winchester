import Foundation
import DiskCore
import Combine

/// Branche un scénario sur le moteur audio, et expose au rendu ce que la passe
/// montre à l'instant écouté.
///
/// Rien n'est plus calculé d'avance : choisir un scénario lance sa passe sur un
/// fil à part, qui avance quelques secondes devant l'écoute. L'écran ne
/// connaît de la passe que son présent — ni sa durée, ni son passé au-delà de
/// ce qu'une image peut encore montrer.
@MainActor
final class SimulationModel: ObservableObject {

    @Published private(set) var selection: ScenarioSelection
    @Published private(set) var scenario: Scenario
    /// La passe en cours d'écoute.
    @Published private(set) var live: LivePass

    let engine: DiskNoiseEngine

    /// Les scénarios décrits, pas leurs passes : un disque de la galerie coûte
    /// sa conversion en volume, qu'on ne refait pas à chaque aller-retour.
    private var cache: [ScenarioSelection: Scenario] = [:]

    var kind: ScenarioKind { scenario.kind }
    var label: ScenarioLabel { scenario.label }
    var geometry: DriveGeometry { scenario.geometry }
    var defrag: DefragPlayback? { scenario.defrag }
    var boot: BootPlayback? { scenario.boot }

    init() {
        let scenario = ScenarioBuilder.build(.windowsBoot)
        let live = scenario.startLivePass()
        self.selection = .builtin(.windowsBoot)
        self.scenario = scenario
        self.live = live
        self.cache = [.builtin(.windowsBoot): scenario]
        self.engine = DiskNoiseEngine(rpm: scenario.geometry.rpm)
        engine.load(feed: live, rpm: scenario.geometry.rpm)
    }

    /// Ce que propose le sélecteur : les scénarios livrés, puis le disque de la
    /// galerie qu'on lui a confié, s'il y en a un.
    ///
    /// Un seul à la fois : c'est un sélecteur segmenté, et vingt profils n'y
    /// tiendraient pas. Revenir sur un disque précédent se fait depuis la
    /// galerie, où il est de toute façon déjà affiché.
    var selections: [ScenarioSelection] {
        ScenarioKind.allCases.map(ScenarioSelection.builtin)
            + cache.keys.filter(\.isGenerated).sorted { $0.sortKey < $1.sortKey }
    }

    /// Bascule de scénario. La passe repart de son début.
    func select(_ selection: ScenarioSelection) {
        guard selection != self.selection else { return }
        guard let scenario = cache[selection] ?? built(selection) else { return }
        cache[selection] = scenario
        adopt(scenario, as: selection)
    }

    private func built(_ selection: ScenarioSelection) -> Scenario? {
        // Un disque généré n'est jamais reconstruit à la volée : il n'existe
        // que dans la galerie, et n'entre ici que par `load(generated:as:)`.
        guard case let .builtin(kind) = selection else { return nil }
        return ScenarioBuilder.build(kind)
    }

    /// Adopte un disque fabriqué par la galerie et bascule dessus.
    ///
    /// Plus rien n'est planifié ici : la conversion du disque en volume est le
    /// seul coût payé sur le fil principal, la passe elle-même se calcule
    /// pendant qu'on l'écoute.
    ///
    /// Un seul disque de la galerie est gardé à la fois, quelle que soit
    /// l'activité : le sélecteur est segmenté, et une quatrième entrée n'y
    /// tiendrait pas. Revenir sur le précédent se fait depuis la galerie.
    ///
    /// `strategy` choisit le défragmenteur ; `nil` laisse le format décider,
    /// comme l'aurait fait la machine de l'époque. Un démarrage l'ignore.
    func load(generated disk: GeneratedDisk,
              as activity: GeneratedActivity,
              using strategy: (any DefragStrategy)? = nil) throws {
        let selection = ScenarioSelection.generated(disk.spec.id, activity)
        let scenario: Scenario
        switch activity {
        case .boot:   scenario = ScenarioBuilder.build(boot: disk)
        case .defrag: scenario = try ScenarioBuilder.build(generated: disk, using: strategy)
        }
        for key in cache.keys where key.isGenerated { cache[key] = nil }
        cache[selection] = scenario
        adopt(scenario, as: selection)
    }

    /// Nom d'un choix dans le sélecteur. Un disque généré porte le nom de son
    /// profil, qui n'est connu qu'une fois le scénario construit.
    func title(of selection: ScenarioSelection) -> String {
        if let scenario = cache[selection] { return scenario.label.title }
        if case let .builtin(kind) = selection { return kind.title }
        return "—"
    }

    private func adopt(_ scenario: Scenario, as selection: ScenarioSelection) {
        self.selection = selection
        self.scenario = scenario
        startPass()
    }

    /// Relance la passe depuis son début — le seul retour en arrière qui
    /// reste. La lecture reprend si elle était en cours.
    func restart() {
        let wasPlaying = engine.isPlaying || engine.isBuffering
        startPass()
        if wasPlaying { engine.play() }
    }

    private func startPass() {
        // La passe abandonnée libère son producteur en partant.
        let grid = live.map?.grid ?? .standard
        live = scenario.startLivePass()
        live.map?.setGrid(grid)
        engine.load(feed: live, rpm: scenario.geometry.rpm)
    }

    // MARK: - L'instant écouté

    /// La phase en cours et son rang, pour la couleur.
    var phase: PhaseDescriptor? { live.phase }
    var phaseIndex: Int { live.phaseIndex }

    /// Le plateau et sa trace de position, tels que la vue les interroge.
    var platter: PlatterTrack { live.platter }

    /// Tout ce que le plateau doit montrer à cet instant, en une seule passe.
    func platterFrame(at time: Double) -> PlatterFrame { live.platter.frame(at: time) }

    /// Le voyant d'activité, comme sur la façade : c'est exactement le signal
    /// dont se contente HDDSynth pour déclencher ses sons.
    var activityLED: Bool { live.requestRate > 0.5 }

    /// Le temps écouté dans chaque phase, dans l'ordre où elles sont apparues.
    var phaseTimes: [PhaseTime] { live.phaseTimes }
    var phases: [PhaseDescriptor] { live.phases }

    var requestRate: Double { live.requestRate }
    var throughputMBs: Double { live.throughputMBs }
    var totals: ActivityTotals { live.totals }

    /// Le bilan, une fois la passe entendue jusqu'au bout de son travail.
    var end: PassEnd? {
        guard let end = live.end, live.now >= end.workEnd else { return nil }
        return end
    }

    // MARK: - Défragmentation

    func clusterShades(at time: Double) -> [ClusterShade] { live.map?.shades(at: time) ?? [] }

    /// Les accès encore visibles sur la carte, en plein écran.
    func mapTrail() -> [MapTrailPoint] { live.mapTrail() }

    /// Cellule en cours d'accès, s'il y en a une à cet instant.
    func activeCell() -> (cell: Int, isWrite: Bool)? { live.activeCell() }

    var clustersPerCell: Double { live.map?.clustersPerCell ?? 1 }

    /// Les clusters d'un bloc de la carte rejouée.
    func clusters(ofCell cell: Int) -> Range<Int> {
        live.map?.partition.clusters(ofCell: cell) ?? 0..<0
    }

    /// Grille sur laquelle la carte est agrégée. La vue la lit ici plutôt que
    /// de la deviner : c'est le modèle qui décide combien de blocs il produit,
    /// et la vue n'en dessine jamais d'autres.
    var mapGrid: MapGrid { live.map?.grid ?? .standard }

    /// Change la grille d'affichage — le plein écran la dérive de la surface
    /// disponible. Le rejeu garde sa position ; seule l'agrégation est refaite.
    func setMapGrid(_ grid: MapGrid) {
        guard let map = live.map, grid != map.grid else { return }
        map.setGrid(grid)
        objectWillChange.send()
    }

    var movedBytes: Double { Double(live.totals.movedBytes) }

    /// Avancement annoncé par le défragmenteur, s'il en annonce un.
    var defragProgress: Double? { live.progress }
}
