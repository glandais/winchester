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
        case .seekLaw:
            return String(localized: "explanation.seekLaw.title", defaultValue: "The seek law")
        case .edgeReturn:
            return String(localized: "explanation.edgeReturn.title", defaultValue: "The return to the edge")
        case .prefetch:
            return String(localized: "explanation.prefetch.title", defaultValue: "The prefetcher")
        case .witness:
            return String(localized: "explanation.witness.title", defaultValue: "The witness")
        case .installation:
            return String(localized: "explanation.installation.title", defaultValue: "The installation")
        case .nextFit:
            return String(localized: "explanation.nextFit.title", defaultValue: "The next-fit allocator")
        case .mftZone:
            return String(localized: "explanation.mftZone.title", defaultValue: "The MFT zone")
        case .fragmentedVsPieces:
            return String(localized: "explanation.fragmentedVsPieces.title", defaultValue: "Fragmented, or in pieces")
        case .evacuations:
            return String(localized: "explanation.evacuations.title", defaultValue: "Evacuations")
        case .pagefile:
            return String(localized: "explanation.pagefile.title", defaultValue: "The page file")
        case .headSound:
            return String(localized: "explanation.headSound.title", defaultValue: "The timbre of the arm")
        case .rotation:
            return String(localized: "explanation.rotation.title", defaultValue: "The hum")
        case .haptics:
            return String(localized: "explanation.haptics.title", defaultValue: "In your hand")
        }
    }

    var text: String {
        switch self {
        case .seekLaw:
            return String(localized: "explanation.seekLaw.text",
                          defaultValue: "For short seeks, the time grows as the square root of the distance; beyond that it becomes proportional. Two short seeks therefore take longer than a single one covering the same total distance, and sound different.")
        case .edgeReturn:
            return String(localized: "explanation.edgeReturn.text",
                          defaultValue: "On FAT, every committed move rewrites both copies of the allocation table, at the very start of the partition, then the file's entry in its directory. The arm comes back to the edge roughly once per file: that is the sharp “clack” that paces a Windows 95 pass.")
        case .prefetch:
            return String(localized: "explanation.prefetch.text",
                          defaultValue: "Windows XP and Vista sort the list of files read at boot by position on the disk, and read it back in a single sweep of the arm, together with the MFT records that describe them. Before XP there was no prefetcher: the arm follows the order in which the system asks for its files, not their position.")
        case .witness:
            return String(localized: "explanation.witness.text",
                          defaultValue: "The same files, each in one piece, packed against the start of the volume. The gap measures what the real placement costs. On FAT it is almost nil; on NTFS, the witness sometimes loses.")
        case .installation:
            return String(localized: "explanation.installation.text",
                          defaultValue: "The disk's first day, replayed: every file is written where the allocator put it. The source throttles the copy — a floppy reads at 45 KB/s, a 24x CD at 3.6 MB/s. Installers first extract their archives and read them back while copying: that is the back-and-forth that crackles. Then they delete them, and leave the first holes. Every restart reads back what was just laid down.")
        case .nextFit:
            return String(localized: "explanation.nextFit.text",
                          defaultValue: "Under Windows 95 and 98, VFAT and FAT32 resume from the last allocated cluster. As long as that cursor moves forward, files stay clean. Once it reaches the end of the volume it wraps around and fills the holes left months earlier: that is where files get chopped up, in waves. MS-DOS, on FAT16, serves the first free cluster from the start instead: every hole is plugged at once, and recent files shatter into crumbs.")
        case .mftZone:
            return String(localized: "explanation.mftZone.text",
                          defaultValue: "NTFS reserves 12.5% of the volume so its file table can grow, and writes there only once the rest is full. Opening a file reads its record back from that table, at the head of the volume: with no prefetcher, that makes two sweeps of the arm per file.")
        case .fragmentedVsPieces:
            return String(localized: "explanation.fragmentedVsPieces.text",
                          defaultValue: "A file counts as “fragmented” the moment it sits in two pieces: brought down from 40 pieces to 2, it still is. The share of fragmented files can therefore stall while the number of pieces collapses. The two figures are read together.")
        case .evacuations:
            return String(localized: "explanation.evacuations.text",
                          defaultValue: "The place a file has to go is nearly always taken: the occupant first leaves for the far end of the volume, and will be moved again when its turn comes. It is that back-and-forth, more than the amount of data, that makes a pass long. A tool that evicts nobody counts zero.")
        case .pagefile:
            return String(localized: "explanation.pagefile.text",
                          defaultValue: "Windows has it open: the defragmenter cannot move it and tidies around it. It is the red block that never moves on the map.")
        case .headSound:
            return String(localized: "explanation.headSound.text",
                          defaultValue: "A bank of fixed-frequency resonators, around 4.5 and 5.5 kHz: only the excitation varies with distance, the actuator's resonances do not change with speed. Two seeks close together do not start two sounds: they form a single train, closed by a thud.")
        case .rotation:
            return String(localized: "explanation.rotation.text",
                          defaultValue: "The hum is computed from the spindle speed, for lack of a recording. It is the weak link of the model: projects that sound right start from a real recording.")
        case .haptics:
            return String(localized: "explanation.haptics.text",
                          defaultValue: "The Taptic Engine gets the same cues as the sound: a thud as the arm leaves, a rumble along its travel, a thud on arrival. Trains close together become a continuous texture rather than a burst of thuds.")
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
    static var groups: [(title: String, topics: [Explanation])] {
        [
            (String(localized: "explanation.group.arm", defaultValue: "The arm and the boot"),
             [.seekLaw, .edgeReturn, .prefetch, .witness, .installation]),
            (String(localized: "explanation.group.volume", defaultValue: "The volume"),
             [.nextFit, .mftZone, .fragmentedVsPieces, .evacuations, .pagefile]),
            (String(localized: "explanation.group.sound", defaultValue: "The sound"),
             [.headSound, .rotation, .haptics]),
        ]
    }
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
        .accessibilityLabel(String(localized: "explanation.why",
                                   defaultValue: "Why: \(topic.title)",
                                   comment: "Étiquette du ⓘ posé à côté d'un chiffre"))
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
                            Text("explanation.seeAlso")
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
            .navigationTitle("settings.explanations.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.ok") { dismiss() }
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
            .accessibilityValue(isOpen ? "common.expanded" : "common.collapsed")
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
