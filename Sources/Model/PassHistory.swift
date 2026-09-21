import Foundation
import Combine
import DiskCore

/// Ce que les disques gardent de ce qu'on leur a fait, d'un lancement à
/// l'autre.
///
/// Jusqu'ici, tout s'évaporait à la fermeture : `SimulationModel.records` vit
/// en mémoire, douze au plus, et seules les recettes de « Mes disques »
/// survivaient. Au lancement suivant, ni historique, ni état sur les cartes
/// (`UX_REVIEW.md` §2.2). Ce qui survit désormais, c'est le **résumé** de
/// chaque passe — pas ses cartes, pas son arrangement, pas son disque.
///
/// L'écriture est synchrone : un résumé fait deux cents octets, et une passe se
/// termine une fois toutes les quelques minutes.
@MainActor
final class PassHistory: ObservableObject {

    /// Tous les résumés gardés, du plus récent au plus ancien.
    @Published private(set) var digests: [PassDigest] = []
    /// Ce que le magasin n'a pas pu lire ou écrire, pour qui veut le dire.
    @Published private(set) var failure: String?

    private let store: PassHistoryStore

    init(store: PassHistoryStore = .standard()) {
        self.store = store
        do {
            digests = try store.load()
        } catch {
            // Un historique illisible n'empêche pas d'écouter : on repart de
            // rien plutôt que de refuser de démarrer, et le prochain
            // enregistrement réécrira le fichier.
            digests = []
            failure = String(localized: "error.history.read",
                             defaultValue: "The passes heard could not be read back: \(error.localizedDescription)")
        }
    }

    /// L'état d'un disque : sa dernière passe, et le dernier rangement.
    func state(of diskID: String) -> DiskState {
        let passes = digests.filter { $0.diskID == diskID }
        return DiskState(tidied: passes.first(where: \.isTidying),
                         last: passes.first,
                         passes: passes)
    }

    /// Le disque a-t-il été rangé, et par quoi ? C'est ce que dit sa carte.
    func tidyMark(of diskID: String) -> PassDigest? { state(of: diskID).tidied }

    /// Garde le résumé d'une passe qui vient de finir.
    ///
    /// Une passe sans disque de la galerie — il n'y en a plus depuis que les
    /// démos tournent sur des disques du catalogue, mais le modèle l'autorise
    /// encore — n'a pas d'état à porter : on ne la garde pas.
    func record(_ record: PassRecord, at date: Date = Date()) {
        guard record.disk != nil else { return }
        append(Self.digest(of: record, at: date))
    }

    func append(_ digest: PassDigest) {
        digests = PassHistoryStore.trimmed(digests + [digest])
        do {
            try store.save(digests)
            failure = nil
        } catch {
            failure = String(localized: "error.history.save",
                             defaultValue: "The pass heard could not be saved: \(error.localizedDescription)")
        }
    }

    /// Oublie tout ce qui a été gardé. Les disques redeviennent neufs à
    /// l'écran, ce qu'ils n'ont jamais cessé d'être dans le modèle.
    func forgetAll() {
        digests = []
        do {
            try store.save([])
            failure = nil
        } catch {
            failure = String(localized: "error.history.clear",
                             defaultValue: "The history could not be cleared: \(error.localizedDescription)")
        }
    }

    /// Le résumé d'un bilan : ses chiffres, sans son disque ni ses cartes.
    ///
    /// Hors de l'acteur principal : c'est un calcul pur sur une valeur, et les
    /// tests le vérifient sans avoir à s'y rendre.
    nonisolated static func digest(of record: PassRecord, at date: Date = Date()) -> PassDigest {
        var digest = PassDigest(id: record.id,
                                diskID: record.diskID,
                                title: record.title,
                                kind: kind(of: record.kind),
                                toolLabel: record.toolLabel,
                                toolID: record.toolID,
                                finishedAt: date,
                                duration: record.duration,
                                movedBytes: record.movedBytes)
        if let before = record.before, let after = record.after {
            digest.fragmentedBefore = before.fragmentedFiles
            digest.fragmentedAfter = after.fragmentedFiles
            digest.fragmentsBefore = before.fragments
            digest.fragmentsAfter = after.fragments
            digest.holesBefore = before.freeHoles
            digest.holesAfter = after.freeHoles
        }
        digest.filesMoved = record.filesMoved
        digest.evacuations = record.evacuations
        digest.summary = record.summary
        return digest
    }

    nonisolated private static func kind(of kind: PassRecord.Kind) -> PassDigest.Kind {
        switch kind {
        case .defrag:  return .defrag
        case .boot:    return .boot
        case .install: return .install
        case .day:     return .day
        }
    }
}
