import Foundation

public typealias ByteCount = UInt64

/// Comment un fichier est écrit au fil de sa vie.
///
/// C'est le paramètre le plus important du modèle — plus que la distribution
/// des tailles. Deux volumes peuplés exactement des mêmes fichiers, aux mêmes
/// tailles, n'ont rien à voir l'un avec l'autre si les uns ont été copiés depuis
/// un CD et les autres réenregistrés cent fois. La taille dit combien de place
/// est occupée ; le motif dit **dans quel ordre** elle a été prise et rendue, et
/// c'est cet ordre qui fabrique les trous.
public enum WritePattern: Sendable, Hashable, Codable {

    /// Écrit une fois, jamais retouché : installation depuis un CD, copie de
    /// fichiers. Ne fragmente que si le volume était déjà mité.
    case createOnce

    /// Grossit par la fin, indéfiniment : journaux, `index.dat`, le `.pst`
    /// d'Outlook sur trois ans. Chaque ajout est alloué là où l'allocateur en
    /// est rendu, donc très loin du début du fichier. Le motif le plus
    /// fragmentant qui soit sur FAT.
    case append(growthPerEvent: ByteCount)

    /// Réécrit sur place, à taille constante. N'alloue rien et ne fragmente
    /// rien — c'est le cas de référence, celui qui montre que tout ne
    /// fragmente pas.
    case rewriteInPlace

    /// Écrit un temporaire, puis remplace l'original : c'est ce que fait Word
    /// à chaque enregistrement (`~WRD0001.TMP` puis un `rename`). Le fichier
    /// change donc de place à chaque sauvegarde, et laisse un trou de son
    /// ancienne taille derrière lui.
    case writeTempThenRename

    /// Créé puis supprimé peu après : les `.obj` d'une compilation, le cache du
    /// navigateur. Ne laisse rien derrière lui, sauf les trous — qui sont
    /// précisément le sujet.
    case createDeleteShortLived(lifetimeDays: UInt32)

    /// Grossit et rétrécit au gré de l'usage : `WIN386.SWP`. Alterne allocation
    /// et libération au même endroit, ce qui déplace le reste du volume autour
    /// de lui.
    case growShrinkDynamic(minBytes: ByteCount, maxBytes: ByteCount)
}

extension WritePattern {

    /// Le fichier peut-il changer de taille après sa création ?
    public var isMutable: Bool {
        switch self {
        case .createOnce, .rewriteInPlace: return false
        case .append, .writeTempThenRename, .createDeleteShortLived, .growShrinkDynamic: return true
        }
    }

    /// Le fichier est-il destiné à disparaître de lui-même ?
    public var isEphemeral: Bool {
        if case .createDeleteShortLived = self { return true }
        return false
    }
}
