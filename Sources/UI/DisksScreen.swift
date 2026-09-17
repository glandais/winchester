import SwiftUI
import DiskCore

/// L'onglet d'accueil : les deux scénarios livrés, prêts à écouter, puis la
/// galerie des disques d'époque, dont chaque carte ouvre la fiche du disque.
///
/// Lancer quoi que ce soit d'ici bascule sur l'onglet **Passe** et démarre la
/// lecture : on a choisi quoi écouter, il n'y a plus à appuyer sur lecture.
struct DisksScreen: View {

    @ObservedObject var model: SimulationModel
    @ObservedObject var library: DiskLibraryModel
    let showsMiniPlayer: Bool
    /// L'app revient d'arrière-plan pendant une passe.
    var returnedFromBackground = false

    /// Montre l'onglet de la passe.
    let onOpenPass: () -> Void

    @State private var path: [String] = []
    @State private var report: PassRecord?
    @State private var wizard: ProfileSpec?
    @State private var renaming: ProfileSpec?
    @State private var newName = ""
    @State private var deleting: ProfileSpec?
    /// Le disque dont on fait défiler la vie.
    @State private var reviving: RevivedDisk?

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            ScreenTitle("Disques", subtitle: "Écouter tout de suite, ou choisir un disque d'époque")
                            Button {
                                wizard = .blank()
                            } label: {
                                Image(systemName: "plus")
                                    .font(.dynamic(size: 18, weight: .semibold))
                                    .frame(width: 40, height: 40)
                                    .background(Circle().fill(Color.white.opacity(0.08)))
                            }
                            .accessibilityLabel("Construire un disque usagé")
                        }
                        demos
                        myDisks
                        Text("DISQUES D'ÉPOQUE")
                            .font(.dynamic(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                            .padding(.top, 6)
                        DiskGallery(model: library)
                    }
                    .padding(16)
                }
            }
            // Le titre ne s'affiche pas — l'écran a le sien — mais c'est lui
            // que prend le bouton de retour de la fiche.
            .navigationTitle("Disques")
            .passMiniPlayer(model: model, isShown: showsMiniPlayer, returned: returnedFromBackground,
                            onOpen: onOpenPass)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $report) { record in
                PassReportSheet(model: model, record: record, onLaunched: onOpenPass)
            }
            .sheet(item: $wizard) { spec in
                DiskWizardSheet(library: library, spec: spec) { disk, activity, strategy in
                    try launch(disk, as: activity, using: strategy)
                }
            }
            .fullScreenCover(item: $reviving) { revived in
                DiskLifeScreen(disk: revived.disk, model: model, onListen: onOpenPass)
            }
            .alert("Renommer le disque", isPresented: Binding(get: { renaming != nil },
                                                              set: { if !$0 { renaming = nil } })) {
                TextField("Nom", text: $newName)
                Button("Renommer") {
                    if let renaming, !newName.isEmpty { library.rename(renaming.id, to: newName) }
                    renaming = nil
                }
                Button("Annuler", role: .cancel) { renaming = nil }
            }
            .confirmationDialog("Supprimer ce disque ?", isPresented: Binding(get: { deleting != nil },
                                                                             set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Supprimer « \(deleting?.displayName ?? "") »", role: .destructive) {
                    if let deleting { library.delete(deleting.id) }
                    deleting = nil
                }
            } message: {
                Text("Son histoire est perdue ; les disques d'époque ne sont pas touchés.")
            }
            .navigationDestination(for: String.self) { id in
                DiskDetailScreen(library: library, id: id,
                                 records: model.records.filter { $0.diskID == id },
                                 onOpenRecord: { report = $0 },
                                 onEdit: { wizard = $0 }) { disk, activity, strategy in
                    try launch(disk, as: activity, using: strategy)
                }
            }
        }
    }

    /// Ce qu'on demande à un disque : une passe, qu'on écoute tout de suite, ou
    /// le défilement de sa vie, qui a son propre écran.
    private func launch(_ disk: GeneratedDisk, as activity: GeneratedActivity,
                        using strategy: (any DefragStrategy)?) throws {
        guard activity != .life else {
            reviving = RevivedDisk(disk: disk)
            return
        }
        try model.load(generated: disk, as: activity, using: strategy)
        play()
    }

    /// Les disques construits dans l'app, enregistrés d'une session à l'autre.
    @ViewBuilder
    private var myDisks: some View {
        if !library.customs.isEmpty || library.storeFailure != nil {
            Text("MES DISQUES")
                .font(.dynamic(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .padding(.top, 6)
            if let failure = library.storeFailure {
                Text(failure)
                    .font(.dynamic(size: 12))
                    .foregroundStyle(Theme.read)
                    .fixedSize(horizontal: false, vertical: true)
                    .panel()
            }
            ForEach(library.customs) { spec in
                NavigationLink(value: spec.id) {
                    DiskCard(spec: spec, fragmentedRatio: library.fragmentedRatios[spec.id])
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Modifier l'histoire", systemImage: "pencil") { wizard = spec }
                    Button("Renommer", systemImage: "character.cursor.ibeam") {
                        newName = spec.displayName
                        renaming = spec
                    }
                    Button("Dupliquer", systemImage: "plus.square.on.square") {
                        library.save(library.duplicate(spec))
                    }
                    Button("Supprimer", systemImage: "trash", role: .destructive) { deleting = spec }
                }
            }
        }
    }

    private var demos: some View {
        VStack(spacing: 10) {
            ForEach(ScenarioKind.allCases) { kind in
                demoCard(kind)
            }
        }
    }

    private func demoCard(_ kind: ScenarioKind) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title.uppercased())
                    .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(kind == .windowsBoot ? Theme.write : Theme.read)
                Text(kind.summary)
                    .font(.dynamic(size: 12))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Lancer") { launch(kind) }
                .font(.dynamic(size: 13, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Theme.background)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func launch(_ kind: ScenarioKind) {
        let selection = ScenarioSelection.builtin(kind)
        if model.selection == selection {
            // Le même scénario, déjà entendu jusqu'au bout : on le relance.
            if model.engine.isFinished { model.restart() }
        } else {
            model.select(selection)
        }
        play()
    }

    private func play() {
        let engine = model.engine
        if !(engine.isPlaying || engine.isBuffering) { engine.play() }
        onOpenPass()
    }
}

/// Un disque dont on fait défiler la vie. Le plein écran en veut un
/// identifiant, et un disque généré n'en porte pas.
struct RevivedDisk: Identifiable {
    let disk: GeneratedDisk
    var id: String { disk.spec.id }
}
