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

    /// Montre l'onglet de la passe.
    let onOpenPass: () -> Void

    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ScreenTitle("Disques", subtitle: "Écouter tout de suite, ou choisir un disque d'époque")
                        demos
                        Text("DISQUES D'ÉPOQUE")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
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
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                DiskDetailScreen(library: library, id: id) { disk, activity in
                    try model.load(generated: disk, as: activity)
                    play()
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
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(kind == .windowsBoot ? Theme.write : Theme.read)
                Text(kind.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Lancer") { launch(kind) }
                .font(.system(size: 13, weight: .semibold))
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
