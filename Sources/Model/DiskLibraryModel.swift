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

    /// Cellules de la grille, recalculées à chaque disque généré plutôt qu'à
    /// chaque image : l'agrégation d'un volume de 320 Go n'est pas gratuite.
    @Published private(set) var cells: [UInt8] = []

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
        cells = []

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

        task = Task { [weak self] in
            let cellCount = ClusterMapPlayer.cellCount
            do {
                let disk = try await DiskGenerator.generate(spec, progress: report)
                // L'agrégation de la grille est faite hors du fil principal,
                // elle aussi : elle parcourt tous les extents du catalogue.
                let cells = await Task.detached(priority: .userInitiated) {
                    disk.cells(count: cellCount)
                }.value

                guard let self, !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.selectedID == id else { return }
                    self.cells = cells
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
        return max(Int(disk.clusterCount) / ClusterMapPlayer.cellCount, 1)
    }

    /// Catégories réellement présentes, pour ne légender que ce qu'on voit.
    var presentCategories: [ClusterCategory] {
        var seen: [ClusterCategory] = []
        for raw in cells {
            guard let category = FileCategory(rawValue: raw) else { continue }
            let projected = ClusterCategory(category)
            if !seen.contains(projected) { seen.append(projected) }
        }
        return seen.sorted { $0.rawValue < $1.rawValue }
    }

    /// Cellules projetées sur la palette de la carte des clusters.
    var displayCells: [UInt8] {
        cells.map { raw in
            guard let category = FileCategory(rawValue: raw) else {
                return ClusterCategory.free.rawValue
            }
            return ClusterCategory(category).rawValue
        }
    }
}
