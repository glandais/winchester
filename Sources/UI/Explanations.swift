import SwiftUI

/// Les fiches « Pourquoi ça sonne comme ça ? » — maquette 14.
///
/// Des explications courtes, derrière un ⓘ posé à côté du chiffre qu'elles
/// éclairent, plutôt qu'un long texte en bas d'écran. Les quatre premières sont
/// celles des maquettes, relues contre le modèle en deux tours ; les autres
/// reprennent les notes qui tenaient jusque-là dans les Réglages.
enum Explanation: String, CaseIterable, Identifiable {
    case seekLaw
    case edgeReturn
    case prefetch
    case witness
    case installation
    case nextFit
    case mftZone
    case fragmentedVsPieces
    case evacuations
    case pagefile
    case headSound
    case rotation
    case haptics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .seekLaw:            return "La loi de seek"
        case .edgeReturn:         return "Le retour au bord"
        case .prefetch:           return "Le préchargeur"
        case .witness:            return "Le témoin"
        case .installation:       return "L'installation"
        case .nextFit:            return "L'allocateur next-fit"
        case .mftZone:            return "La zone MFT"
        case .fragmentedVsPieces: return "Fragmentés ou en morceaux"
        case .evacuations:        return "Les évacuations"
        case .pagefile:           return "Le fichier d'échange"
        case .headSound:          return "Le timbre du bras"
        case .rotation:           return "Le ronronnement"
        case .haptics:            return "Dans la main"
        }
    }

    var text: String {
        switch self {
        case .seekLaw:
            return "Pour les seeks courts, le temps croît comme la racine de la distance ; au-delà, il devient "
                + "proportionnel. Deux seeks courts prennent donc plus longtemps qu'un seul de même distance "
                + "totale, et sonnent autrement."
        case .edgeReturn:
            return "Sur FAT, chaque déplacement validé réécrit les deux copies de la table d'allocation, au "
                + "tout début de la partition, puis l'entrée du fichier dans son répertoire. Le bras revient au "
                + "bord à peu près une fois par fichier : c'est le « clac » franc qui rythme une passe de "
                + "Windows 95."
        case .prefetch:
            return "Windows XP et Vista rangent la liste des fichiers à lire au démarrage par position sur le "
                + "disque, et la relisent d'une seule course du bras, avec les fiches de la MFT qui les "
                + "décrivent. Avant XP, pas de préchargeur : le bras suit l'ordre dans lequel le système "
                + "demande ses fichiers, pas leur position."
        case .witness:
            return "Les mêmes fichiers, chacun d'un seul tenant, tassés contre le début du volume. L'écart "
                + "mesure ce que coûte le placement réel. Sur FAT il est presque nul ; sur NTFS, le témoin perd "
                + "parfois."
        case .installation:
            return "Le premier jour du disque, rejoué : chaque fichier est écrit là où l'allocateur l'a posé. "
                + "La source bride la copie — une disquette se lit à 45 Ko/s, un CD 24x à 3,6 Mo/s. Les "
                + "installeurs extraient d'abord leurs archives et les relisent en copiant : c'est le "
                + "va-et-vient qui crépite. Puis ils les effacent, et laissent les premiers trous. Chaque "
                + "redémarrage relit ce qui vient d'être posé."
        case .nextFit:
            return "Sous Windows 95 et 98, VFAT et FAT32 repartent du dernier cluster alloué. Tant que ce "
                + "curseur avance, les fichiers sont propres. Arrivé au bout du volume, il revient au début et "
                + "comble les trous laissés des mois plus tôt : c'est là que les fichiers se hachent, par vagues. "
                + "MS-DOS, en FAT16, sert au contraire le premier cluster libre depuis le début : chaque trou est "
                + "rebouché aussitôt, et les fichiers récents s'éclatent en miettes."
        case .mftZone:
            return "NTFS réserve 12,5 % du volume pour que sa table de fichiers puisse grandir, et n'y écrit "
                + "qu'une fois le reste plein. Ouvrir un fichier relit sa fiche dans cette table, en tête du "
                + "volume : sans préchargeur, cela fait deux courses du bras par fichier."
        case .fragmentedVsPieces:
            return "Un fichier est « fragmenté » dès qu'il tient en deux morceaux : ramené de 40 morceaux à 2, "
                + "il l'est encore. Le taux de fichiers fragmentés peut donc stagner pendant que le nombre de "
                + "morceaux s'effondre. Les deux chiffres se lisent ensemble."
        case .evacuations:
            return "La place où doit aller un fichier est presque toujours occupée : l'occupant part d'abord "
                + "au fond du volume, et sera redéplacé quand viendra son tour. C'est ce va-et-vient, plus que la "
                + "quantité de données, qui fait durer une passe. Un outil qui ne déloge personne en compte zéro."
        case .pagefile:
            return "Windows l'a ouvert : le défragmenteur ne peut pas le déplacer et range tout autour. C'est "
                + "le bloc rouge qui ne bouge jamais sur la carte."
        case .headSound:
            return "Un banc de résonateurs à fréquences fixes, vers 4,5 et 5,5 kHz : seule l'excitation varie "
                + "avec la distance, les résonances de l'actionneur ne changent pas avec la vitesse. Deux seeks "
                + "rapprochés ne relancent pas deux sons : ils forment un seul train, fermé par un choc."
        case .rotation:
            return "Le ronronnement est calculé à partir du régime, faute d'enregistrement. C'est le maillon "
                + "faible du modèle : les projets qui sonnent juste bouclent un enregistrement réel."
        case .haptics:
            return "Le Taptic Engine reçoit les mêmes repères que le son : un choc au départ du bras, un "
                + "grondement pendant sa course, un choc à l'arrivée. Les trains rapprochés deviennent une "
                + "texture continue plutôt qu'une salve de chocs."
        }
    }

    /// Les fiches voisines, proposées sous celle qu'on a ouverte.
    var related: [Explanation] {
        switch self {
        case .seekLaw:            return [.edgeReturn, .headSound]
        case .edgeReturn:         return [.seekLaw, .evacuations]
        case .prefetch:           return [.witness, .mftZone]
        case .witness:            return [.prefetch, .nextFit, .mftZone]
        case .installation:       return [.edgeReturn, .nextFit, .witness]
        case .nextFit:            return [.fragmentedVsPieces, .witness]
        case .mftZone:            return [.prefetch, .fragmentedVsPieces]
        case .fragmentedVsPieces: return [.nextFit, .evacuations]
        case .evacuations:        return [.edgeReturn, .fragmentedVsPieces]
        case .pagefile:           return [.evacuations]
        case .headSound:          return [.seekLaw, .haptics]
        case .rotation:           return [.headSound, .haptics]
        case .haptics:            return [.headSound, .rotation]
        }
    }

    /// Les fiches par thème, dans l'ordre des Réglages.
    static let groups: [(title: String, topics: [Explanation])] = [
        ("Le bras et le démarrage", [.seekLaw, .edgeReturn, .prefetch, .witness, .installation]),
        ("Le volume", [.nextFit, .mftZone, .fragmentedVsPieces, .evacuations, .pagefile]),
        ("Le son", [.headSound, .rotation, .haptics]),
    ]
}

/// Le ⓘ posé à côté d'un chiffre. Il ouvre sa fiche, et porte lui-même la
/// feuille : un écran n'a rien à tenir pour en poser un.
struct WhyButton: View {
    let topic: Explanation
    /// Le chiffre qu'on regardait, repris en tête de la feuille : « SEEK MOYEN ·
    /// 1 214 CYL. ».
    var context: String? = nil
    var color: Color = Theme.write

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .font(.dynamic(size: 13))
                .foregroundStyle(color)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pourquoi : \(topic.title)")
        .sheet(isPresented: $isPresented) {
            WhySheet(topic: topic, context: context)
        }
    }
}

/// La feuille d'une fiche, et ses voisines en dessous.
struct WhySheet: View {
    let topic: Explanation
    var context: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var opened: Set<Explanation> = []

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let context {
                            Text(context.uppercased())
                                .font(.dynamic(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.read)
                        }
                        ExplanationCard(topic: topic, highlighted: true)
                        if !topic.related.isEmpty {
                            Text("VOIR AUSSI")
                                .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                                .padding(.top, 6)
                            ForEach(topic.related) { other in
                                ExplanationRow(topic: other, isOpen: opened.contains(other)) {
                                    if opened.contains(other) { opened.remove(other) } else { opened.insert(other) }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Pourquoi ça sonne comme ça ?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(Theme.read)
    }
}

struct ExplanationCard: View {
    let topic: Explanation
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(topic.title)
                .font(.dynamic(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(topic.text)
                .font(.dynamic(size: 14))
                .foregroundStyle(Theme.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(highlighted ? Theme.read.opacity(0.5) : .clear, lineWidth: 1)
        )
    }
}

/// Une fiche repliée : son titre, et son texte d'un appui.
struct ExplanationRow: View {
    let topic: Explanation
    let isOpen: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack {
                    Text(topic.title)
                        .font(.dynamic(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.dynamic(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isOpen ? "ouverte" : "repliée")
            if isOpen {
                Text(topic.text)
                    .font(.dynamic(size: 13))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}
