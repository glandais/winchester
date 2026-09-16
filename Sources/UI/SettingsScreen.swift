import SwiftUI
import DiskCore

/// Le mixage, l'haptique et les notes du modèle, sortis de l'écran de la passe.
///
/// Rien ici ne dépend de l'instant écouté : l'écran ne suit donc pas l'horloge
/// du moteur, qui le ferait redessiner soixante fois par seconde. Il ne se
/// redessine que quand on touche un réglage.
struct SettingsScreen: View {

    @ObservedObject var model: SimulationModel
    let engine: DiskNoiseEngine
    @State private var showsModelNotes = false
    /// Change à chaque réglage touché, pour redessiner ce qui en dépend.
    @State private var revision = 0

    var body: some View {
        let _ = revision
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ScreenTitle("Réglages", subtitle: "Son, vibrations et notes du modèle")
                    mixer
                    notes
                }
                .padding(16)
            }
        }
    }

    private var mixer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mixage des couches")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)

            LevelSlider(label: "Rotation (procédurale)", value: engineBinding(\.spindleLevel))
            LevelSlider(label: "Tête (banc de résonateurs)", value: engineBinding(\.transientLevel))
            LevelSlider(label: "Général", value: engineBinding(\.masterLevel))

            Divider().overlay(Theme.stroke).padding(.vertical, 4)

            if engine.supportsHaptics {
                Toggle(isOn: engineBinding(\.hapticsEnabled)) {
                    Text("Retour haptique")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
                if engine.hapticsEnabled {
                    LevelSlider(label: "Intensité des transitoires", value: engineBinding(\.hapticIntensity))
                    Toggle(isOn: engineBinding(\.spindleHaptics)) {
                        Text("Grondement de rotation")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim)
                    }
                    if engine.spindleHaptics {
                        LevelSlider(label: "Niveau du grondement", value: engineBinding(\.spindleHapticLevel))
                    }
                    Text(engine.hapticReport)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Retour haptique indisponible sur cet appareil")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    /// Un réglage du moteur. L'écran n'observe pas le moteur : c'est l'écriture
    /// qui le fait redessiner.
    private func engineBinding<Value>(_ keyPath: ReferenceWritableKeyPath<DiskNoiseEngine, Value>) -> Binding<Value> {
        let engine = engine
        let revision = $revision
        return Binding(get: { engine[keyPath: keyPath] },
                       set: { engine[keyPath: keyPath] = $0; revision.wrappedValue += 1 })
    }

    /// La géométrie change d'un scénario à l'autre — et d'un disque généré à
    /// l'autre : la note la lit plutôt que de la réciter.
    private var geometryNote: String {
        let g = model.geometry
        let rpm = String(format: "%d\u{202F}%03d", Int(g.rpm) / 1_000, Int(g.rpm) % 1_000)
        return "\(g.cylinders) cylindres, \(g.heads) têtes, \(g.zones.count) "
            + "zone\(g.zones.count > 1 ? "s" : "") ZBR, \(rpm) tr/min. La latence "
            + "rotationnelle et les pas de piste sont simulés secteur par secteur."
    }

    private var notes: some View {
        DisclosureGroup(isExpanded: $showsModelNotes) {
            VStack(alignment: .leading, spacing: 9) {
                if model.defrag != nil {
                    NoteRow("Volume", model.label.volumeNote)
                    NoteRow("Passe", "« Défragmentation complète » de Windows 95 : chaque fichier rendu contigu et tassé contre le début du volume, dans l'ordre du parcours de l'arborescence — le seul ordre dont l'outil disposait.")
                    NoteRow("Évacuations", "La destination d'un fichier est presque toujours occupée : l'occupant part d'abord vers la fin du volume, et sera redéplacé quand viendra son tour. C'est ce va-et-vient, pas le volume de données, qui fait durer une passe.")
                    NoteRow("Retours FAT", "Chaque déplacement validé réécrit les deux copies de la FAT et l'entrée de répertoire, au tout début de la partition. D'où le retour du bras vers le bord, environ une fois par fichier.")
                    NoteRow("Fichier d'échange", "Windows l'a ouvert : le défragmenteur ne peut pas le déplacer et tasse tout autour. C'est le bloc rouge qui ne bouge jamais.")
                }
                NoteRow("Seek", "Durée en deux régimes, a + b·√d puis c + e·d (Ruemmler & Wilkes 1994), découpée en speedup / coast / slowdown / settle.")
                NoteRow("Timbre", "Banc de résonateurs à fréquences fixes (modes ~4,5 et ~5,5 kHz). Seule l'excitation varie avec la distance : les résonances de l'actionneur ne se transposent pas avec la vitesse de seek.")
                NoteRow("Trains", "Deux seeks rapprochés ne relancent jamais deux one-shots : un seul rendu continu, transitoire terminal en fin de train (règle issue de l'émulation de disquette de MAME).")
                NoteRow("Rotation", "Procédurale faute d'échantillon. C'est le maillon faible : la littérature et tous les projets qui fonctionnent bouclent un enregistrement plutôt que de synthétiser le ronronnement à partir du régime.")
                NoteRow("Haptique", "Le Taptic Engine reçoit les mêmes repères que l'audio : choc à la mise en mouvement, grondement pendant le coast, choc à la décélération, tic d'asservissement. Les trains rapprochés passent en texture continue modulée plutôt qu'en salve de transitoires.")
                NoteRow("Géométrie", geometryNote)
            }
            .padding(.top, 10)
        } label: {
            Text("Ce que modélise le spike")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
        .panel()
    }
}

private struct LevelSlider: View {
    let label: String
    @Binding var value: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text(String(format: "%.0f %%", value * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .monospacedDigit()
            }
            Slider(value: $value, in: 0...1)
        }
    }
}

private struct NoteRow: View {
    let title: String
    let body_: String

    init(_ title: String, _ body: String) {
        self.title = title
        self.body_ = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.read)
            Text(body_)
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
