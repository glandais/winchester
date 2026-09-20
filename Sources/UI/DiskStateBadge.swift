import SwiftUI
import DiskCore

/// Ce qu'un disque dit de ce qu'on lui a fait, sur sa carte et sur sa fiche.
///
/// L'écart central de l'audit (`UX_REVIEW.md` §2.1) : on rangeait un disque de
/// 321 à 2 fichiers fragmentés, on revenait sur sa fiche, et elle affichait
/// toujours 16 % — l'état d'avant. Le disque rangé n'existait que derrière un
/// bouton du bilan, et il s'évaporait à la fermeture.
///
/// La ligne dit l'outil et la date, parce que c'est ce dont on se souvient : le
/// pourcentage d'arrivée, lui, est dans le bilan.
struct DiskStateBadge: View {

    let digest: PassDigest
    /// Sur une carte de galerie, une seule ligne discrète ; sur une fiche, une
    /// tuile qui porte aussi le chiffre.
    var compact = true

    var body: some View {
        if compact {
            Text(headline)
                .font(.dynamic(size: 10, design: .monospaced))
                .foregroundStyle(Theme.read)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: digest.isTidying ? "checkmark.seal" : "clock.arrow.circlepath")
                    .font(.dynamic(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.read)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.dynamic(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    if let detail {
                        Text(detail)
                            .font(.dynamic(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }

    /// « Rangé par UltraDefrag · il y a 3 min », ou ce qu'on a fait d'autre.
    private var headline: String {
        let when = FrenchFormat.sinceNow(digest.finishedAt)
        switch digest.kind {
        case .defrag where digest.isTidying:
            return "Rangé par \(digest.toolLabel) · \(when)"
        case .defrag:
            // Une passe qui n'a rien recollé a bien eu lieu : le dire, plutôt
            // que de laisser croire que rien ne s'est passé.
            return "\(digest.toolLabel) passé sans rien ranger · \(when)"
        case .boot:
            return "Démarré · \(when)"
        case .install:
            return "\(digest.toolLabel) installé · \(when)"
        case .day:
            return "Une journée écoutée · \(when)"
        }
    }

    /// L'avant → après d'une défragmentation, quand il y en a un.
    private var detail: String? {
        guard let before = digest.fragmentedBefore, let after = digest.fragmentedAfter else { return nil }
        return "\(FrenchFormat.integer(before)) → \(FrenchFormat.integer(after)) fichiers fragmentés"
    }
}
