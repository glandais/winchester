import SwiftUI
import DiskCore

/// L'onglet d'accueil : les deux démos, prêtes à écouter et posées chacune sur
/// un disque du catalogue qu'elles nomment, puis la galerie des disques
/// d'époque, dont chaque carte ouvre la fiche du disque.
///
/// Lancer quoi que ce soit d'ici bascule sur l'onglet **Passe** et démarre la
/// lecture : on a choisi quoi écouter, il n'y a plus à appuyer sur lecture.
struct DisksScreen: View {

    @ObservedObject var model: SimulationModel
    @ObservedObject var library: DiskLibraryModel
    /// La pile de l'onglet, tenue par `ContentView` : le titre de la Passe y
    /// pousse la fiche du disque qu'on écoute.
    @Binding var path: [String]
    let showsMiniPlayer: Bool
    /// L'app revient d'arrière-plan pendant une passe.
    var returnedFromBackground = false

    /// Montre l'onglet de la passe.
    let onOpenPass: () -> Void

    @State private var report: PassRecord?
    @State private var wizard: ProfileSpec?
    @State private var renaming: ProfileSpec?
    @State private var newName = ""
    @State private var deleting: ProfileSpec?
    /// Le disque dont on fait défiler la vie.
    @State private var reviving: RevivedDisk?
    /// Les défilements en cours, par disque : ils survivent à la fermeture de
    /// leur plein écran, pour qu'on reprenne là où on s'était arrêté
    /// (`UX_REVIEW.md` §2.6). Un défilement pèse une carte et deux courbes.
    @State private var lives: [String: DiskLifeModel] = [:]
    /// Un lancement retenu le temps de demander si l'on remplace la passe en
    /// cours. Un seul moteur : lancer quoi que ce soit remplaçait ce qu'on
    /// écoutait, sans prévenir (`UX_REVIEW.md` §2.8).
    @State private var pendingLaunch: PendingLaunch?
    /// Ce qu'un lancement différé a refusé. Le lancement immédiat, lui, lève
    /// jusqu'à la fiche, qui écrit la raison sous son bouton ; une fois la
    /// question posée, cette fiche n'est plus là pour l'entendre.
    @State private var launchFailure: String?

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
                        DiskGallery(model: library, history: model.history,
                                    playingDiskID: model.playingDiskID)
                    }
                    .padding(16)
                }
            }
            // Le titre ne s'affiche pas — l'écran a le sien — mais c'est lui
            // que prend le bouton de retour de la fiche.
            .navigationTitle("Disques")
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $report) { record in
                PassReportSheet(model: model, record: record, onLaunched: onOpenPass,
                                onResumeLife: resumeLife(of: record))
            }
            .sheet(item: $wizard) { spec in
                DiskWizardSheet(library: library, spec: spec) { disk, activity, strategy in
                    try launch(disk, as: activity, using: strategy)
                }
            }
            .confirmationDialog("Remplacer la passe en cours ?",
                                isPresented: Binding(get: { pendingLaunch != nil },
                                                     set: { if !$0 { pendingLaunch = nil } }),
                                titleVisibility: .visible) {
                Button("Remplacer") {
                    let launch = pendingLaunch
                    pendingLaunch = nil
                    launch?.start()
                }
                Button("Continuer d'écouter", role: .cancel) { pendingLaunch = nil }
            } message: {
                Text("« \(pendingLaunch?.running ?? "") » est en cours d'écoute. "
                     + "Il n'y a qu'un moteur : la nouvelle passe prend sa place.")
            }
            .alert("La passe n'a pas pu démarrer", isPresented: Binding(
                get: { launchFailure != nil }, set: { if !$0 { launchFailure = nil } })) {
                Button("Fermer", role: .cancel) { launchFailure = nil }
            } message: {
                Text(launchFailure ?? "")
            }
            .fullScreenCover(item: $reviving) { revived in
                DiskLifeScreen(life: revived.life, model: model, onListen: onOpenPass)
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
                DiskDetailScreen(library: library, history: model.history, id: id,
                                 records: model.records.filter { $0.diskID == id },
                                 onOpenRecord: { report = $0 },
                                 onEdit: { wizard = $0 }) { disk, activity, strategy in
                    try launch(disk, as: activity, using: strategy)
                }
            }
        }
        // Le bandeau est posé autour de la pile et non sur sa racine : sinon
        // les écrans poussés en étaient privés, et rien n'y disait qu'une passe
        // tournait (`UX_REVIEW.md` §2.3). En `safeAreaInset` de la pile, il
        // réserve sa place sur tous les écrans au lieu d'en recouvrir le bas.
        .passMiniPlayer(model: model, isShown: showsMiniPlayer, returned: returnedFromBackground,
                        onOpen: onOpenPass)
    }

    /// Ce qu'on demande à un disque : une passe, qu'on écoute tout de suite, ou
    /// le défilement de sa vie, qui a son propre écran.
    private func launch(_ disk: GeneratedDisk, as activity: GeneratedActivity,
                        using strategy: (any DefragStrategy)?) throws {
        guard activity != .life else {
            // Le défilement est fabriqué ici, dans une action, et gardé : le
            // créer dans le `fullScreenCover` le referait à chaque ouverture,
            // et l'écran repartirait du jour 0 comme avant.
            let life = lives[disk.spec.id] ?? DiskLifeModel(disk: disk)
            lives[disk.spec.id] = life
            reviving = RevivedDisk(disk: disk, life: life)
            return
        }
        // Le défilement ne touche pas au moteur ; tout le reste le prend.
        try replacingPass {
            try model.load(generated: disk, as: activity, using: strategy)
            play()
        }
    }

    /// Ce qui tourne en ce moment, s'il faut demander avant de le remplacer.
    ///
    /// Une passe finie, en pause au bout, ou pas encore commencée ne se
    /// « remplace » pas : on ne demande que si le moteur joue vraiment.
    private var runningPass: String? {
        let engine = model.engine
        guard engine.isPlaying || engine.isBuffering, !engine.isFinished else { return nil }
        return model.label.title
    }

    /// Exécute un lancement, ou le retient le temps d'une question.
    ///
    /// Sans passe en cours, la levée traverse jusqu'à l'appelant — la fiche du
    /// disque écrit la raison sous son bouton. Une fois la question posée, la
    /// levée arrive trop tard pour elle : on la garde ici.
    private func replacingPass(_ start: @escaping () throws -> Void) rethrows {
        guard let running = runningPass else { return try start() }
        pendingLaunch = PendingLaunch(running: running) {
            do {
                try start()
            } catch {
                launchFailure = error.localizedDescription
            }
        }
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
                    DiskCard(spec: spec, fragmentedRatio: library.fragmentedRatios[spec.id],
                             state: model.history.state(of: spec.id),
                             isPlaying: model.playingDiskID == spec.id)
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
        // Relancer ce qu'on écoute déjà n'est pas le remplacer.
        guard model.selection != selection else {
            if model.engine.isFinished { model.restart() }
            play()
            return
        }
        replacingPass {
            model.select(selection)
            play()
        }
    }

    private func play() {
        let engine = model.engine
        if !(engine.isPlaying || engine.isBuffering) { engine.play() }
        onOpenPass()
    }
}

extension DisksScreen {

    /// Rouvrir le défilement du disque d'un bilan de journée, s'il en reste un.
    ///
    /// Le défilement survit à son plein écran mais pas au lancement de l'app :
    /// un bilan relu le lendemain n'a plus de défilement à rouvrir, et le
    /// bouton ne se montre pas plutôt que de repartir du jour 0.
    func resumeLife(of record: PassRecord) -> (() -> Void)? {
        guard record.kind == .day, let disk = record.disk,
              let life = lives[disk.spec.id] else { return nil }
        return { reviving = RevivedDisk(disk: disk, life: life) }
    }
}

/// Un lancement en attente de confirmation : ce qu'il remplacerait, et ce
/// qu'il fera si on le confirme.
struct PendingLaunch {
    let running: String
    let start: () -> Void
}

/// Un disque dont on fait défiler la vie. Le plein écran en veut un
/// identifiant, et un disque généré n'en porte pas.
///
/// L'élément porte **aussi le défilement**, au lieu de le laisser chercher
/// dans un dictionnaire d'état : le contenu d'un `fullScreenCover` est capturé
/// à la présentation, donc avec la valeur de l'écran d'avant la mutation. Le
/// défilement venait d'y être rangé, et le plein écran s'ouvrait vide — noir.
struct RevivedDisk: Identifiable {
    let disk: GeneratedDisk
    let life: DiskLifeModel
    var id: String { disk.spec.id }
}
