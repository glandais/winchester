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
    @State private var showsSound = false
    /// Change quand la feuille « Son et vibrations » se ferme, pour relire le
    /// mixage qu'on y a laissé.
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
        // La feuille fermée, la ligne relit le mixage qu'on y a laissé.
        .sheet(isPresented: $showsSound, onDismiss: { revision += 1 }) {
            SoundSheet(engine: engine)
        }
    }

    /// Le mixage se règle dans sa feuille ; la ligne dit seulement lequel est
    /// en place.
    private var mixer: some View {
        Button {
            showsSound = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2")
                    .font(.dynamic(size: 17))
                    .foregroundStyle(Theme.read)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Son et vibrations")
                        .font(.dynamic(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(engine.mix.preset?.label ?? "Réglage personnel")
                        .font(.dynamic(size: 12))
                        .foregroundStyle(Theme.dim)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.dynamic(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .panel()
        }
        .buttonStyle(.plain)
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
