import Foundation
import Combine
import DiskCore

/// État d'une génération, tel que l'interface a besoin de le connaître.
enum GenerationState {
    case idle
    case running(fraction: Double, day: UInt32, fileCount: Int, fill: Double)
    case ready(GeneratedDisk)
    case failed(String)

    var disk: GeneratedDisk? {
        if case let .ready(disk) = self { return disk }
        return nil
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Galerie de disques d'époque : choisit un scénario, le génère hors du fil
/// principal, et publie ce qu'il faut pour l'afficher.
///
/// La génération part sur une tâche détachée et rapporte son avancement : sur
/// un scénario de 2007, il y a près d'un million d'événements à rejouer, et
/// l'interface doit rester vivante pendant ce temps. Changer de scénario en
/// cours de route annule le précédent — c'est à cela que sert
/// `Task.checkCancellation` aux bornes d'événements.
@MainActor
final class DiskLibraryModel: ObservableObject {

    @Published private(set) var scenarios: [ProfileSpec] = []
    @Published private(set) var state: GenerationState = .idle
    @Published var selectedID: String? {
        didSet {
            guard selectedID != oldValue, let selectedID else { return }
            generate(selectedID)
        }
    }

    /// Blocs de la grille — catégorie dominante et taux d'occupation —
    /// recalculés à chaque disque généré plutôt qu'à chaque image :
    /// l'agrégation d'un volume de 320 Go n'est pas gratuite.
    @Published private(set) var shades: [ClusterShade] = []

    /// Grille sur laquelle ces cellules sont agrégées. La galerie la porte pour
    /// son compte : elle n'affiche pas la carte d'une passe, mais celle d'un
    /// volume au repos, et les deux vues n'ont aucune raison de partager leur
    /// place à l'écran.
    @Published private(set) var grid: MapGrid = .standard

    /// Change la grille et réagrège le volume affiché, s'il y en a un.
    ///
    /// La réagrégation repart du catalogue et non des cellules : passer d'une
    /// grille à une autre n'est pas un redimensionnement d'image, c'est un
    /// autre découpage des extents.
    func setGrid(_ grid: MapGrid) {
        guard grid != self.grid else { return }
        self.grid = grid
        guard let disk = state.disk else { return }
        let cellCount = grid.cellCount
        Task { [weak self] in
            let shades = await Task.detached(priority: .userInitiated) {
                Self.shades(of: disk, count: cellCount)
            }.value
            guard let self, self.grid.cellCount == cellCount else { return }
            self.shades = shades
        }
    }

    private var task: Task<Void, Never>?

    init() {
        do {
            scenarios = try ScenarioLibrary.loadAll()
        } catch {
            state = .failed("scénarios illisibles : \(error)")
        }
    }

    var selected: ProfileSpec? {
        scenarios.first { $0.id == selectedID }
    }

    /// Scénarios groupés par année, dans l'ordre chronologique.
    var byEpoch: [(year: Int, scenarios: [ProfileSpec])] {
        let grouped = Dictionary(grouping: scenarios) { $0.timeline.start.year }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    func selectFirstIfNeeded() {
        guard selectedID == nil, let first = scenarios.first else { return }
        selectedID = first.id
    }

    func generate(_ id: String) {
        guard let spec = scenarios.first(where: { $0.id == id }) else { return }

        task?.cancel()
        state = .running(fraction: 0, day: 0, fileCount: 0, fill: 0)
        shades = []

        // Le rapport arrive depuis le fil de génération : il est renvoyé sur le
        // fil principal, et seulement lui. La fermeture est construite ici,
        // hors de la tâche, pour capturer `self` faiblement une seule fois —
        // une capture faible imbriquée relirait la capture de la tâche depuis
        // le fil de génération.
        let report: @Sendable (GenerationProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.selectedID == id else { return }
                self.state = .running(fraction: progress.fraction,
                                      day: progress.day,
                                      fileCount: progress.fileCount,
                                      fill: progress.fill)
            }
        }

        // La grille est lue ici, sur le fil principal, et non dans la tâche :
        // elle appartient au modèle isolé, et la tâche ne capture `self` que
        // faiblement.
        let cellCount = grid.cellCount

        task = Task { [weak self] in
            do {
                let disk = try await DiskGenerator.generate(spec, progress: report)
                // L'agrégation de la grille est faite hors du fil principal,
                // elle aussi : elle parcourt tous les extents du catalogue.
                let shades = await Task.detached(priority: .userInitiated) {
                    Self.shades(of: disk, count: cellCount)
                }.value

                guard let self, !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.selectedID == id else { return }
                    self.shades = shades
                    self.state = .ready(disk)
                }
            } catch is CancellationError {
                // Un scénario abandonné au profit d'un autre : rien à signaler.
            } catch {
                guard let self else { return }
                await MainActor.run {
                    guard self.selectedID == id else { return }
                    self.state = .failed("\(error)")
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    // MARK: - Lecture pour l'affichage

    var clustersPerCell: Int {
        guard let disk = state.disk else { return 1 }
        return max(Int(disk.clusterCount) / grid.cellCount, 1)
    }

    /// Catégories réellement présentes, pour ne légender que ce qu'on voit.
    var presentCategories: [ClusterCategory] {
        var seen: [ClusterCategory] = []
        for shade in shades {
            guard let category = ClusterCategory(rawValue: shade.category),
                  category != .free else { continue }
            if !seen.contains(category) { seen.append(category) }
        }
        return seen.sorted { $0.rawValue < $1.rawValue }
    }

    /// Agrégation d'un disque sur une grille, projetée sur la palette de la
    /// carte des clusters.
    ///
    /// Le taux d'occupation vient du même parcours d'extents que la catégorie :
    /// c'est ce qui permet au plein écran de montrer qu'un bloc de quatre mille
    /// clusters n'est pas plein pour autant, sans repasser sur le catalogue.
    /// La fonction est `nonisolated static` parce qu'elle tourne hors du fil
    /// principal, sur une tâche détachée.
    private nonisolated static func shades(of disk: GeneratedDisk, count: Int) -> [ClusterShade] {
        let aggregate = disk.shaded(count: count)
        return aggregate.categories.indices.map { cell in
            guard let category = FileCategory(rawValue: aggregate.categories[cell]) else { return .empty }
            return ClusterShade(category: ClusterCategory(category).rawValue,
                                fill: aggregate.fill[cell],
                                contiguous: aggregate.contiguous[cell])
        }
    }
}
