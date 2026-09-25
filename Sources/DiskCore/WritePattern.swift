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

/// Comment le programme fait grandir un fichier dont il ne connaît pas la
/// taille — ce que voit le pilote NTFS de XP, seul à en tenir compte
/// (`NTFSAllocator.stream`). FAT, NT 4, Vista et 7 écrivent tous ces
/// fichiers de la même façon, par paquets (`Allocator.streamByPackets`).
///
/// C'est une question de fait sur un programme, comme
/// `FileSpec.sizeKnownInAdvance` : la réponse vient de son code quand on l'a,
/// et le cas par défaut est dit comme une hypothèse.
public enum StreamedGrowth: UInt8, Sendable, Hashable, Codable {

    /// `WriteFile` au-delà de la fin, par écritures de 4 Ko : le tampon de la
    /// bibliothèque C (`_INTERNAL_BUFSIZ`, `base/crts/crtw32/h/stdio.h:265`),
    /// que `NtfsCommonWrite` étend avec sa surallocation
    /// (`NTFSAllocator.xpStream`). **Une hypothèse** pour tout programme dont
    /// le code n'est pas lu — compilateur, navigateur qui écrit son cache,
    /// encodeur, jeu, et le `.pst` d'Outlook (voir `ScenarioCompiler`).
    case buffered

    /// Un fichier composé d'ole32 en mode direct, écrit par Word dans son
    /// `~wrdxxxx.tmp` puis renommé. ole32 le **projette en mémoire**
    /// (`USE_FILEMAPPING`, `com/ole32/stg/h/filest.hxx:79-81` ;
    /// `exp/filest32.cxx:285-296`) : il naît à 512 octets (`MakeFileStub`,
    /// `filest32.cxx:1199-1222`), et chaque page touchée au-delà est engagée
    /// par blocs de 16 Ko (`COMMIT_BLOCK`, `h/filest.hxx:394`,
    /// `filest32.cxx:1492-1580`) — la section étendue, le fichier porté par
    /// `SetEndOfFile` au multiple de 16 Ko (`mm/allocvm.c:1193-1231`,
    /// `mm/extsect.c:470-481`), que NTFS alloue **exactement**, sans
    /// surallocation (`NtfsSetEndOfFileInfo`, `AskForMore = FALSE`,
    /// `ntfs/fileinfo.c:8017-8023`). La fermeture ramène le fichier à sa
    /// taille (`TurnOffMapping`, `filest32.cxx:1316-1415`).
    ///
    /// Que Word passe par ole32 est **déduit** (les `~dftxxxx.tmp` des KB
    /// sont le préfixe d'ole32, `h/filest.hxx:398`), et le pas de 16 Ko est
    /// un **minimum** : une grosse écriture étend le flux d'un coup
    /// (`msf/sstream.cxx:490`), et aucune source ne dit la taille des
    /// écritures de Word (`LEDGER.md`, chantier 49, reprise de 49c).
    case compoundFile

    /// `index.dat`, l'index du cache d'Internet Explorer, que `wininet` tient
    /// **projeté en mémoire** et fait grandir par `SetEndOfFile` de 16 Ko
    /// (`GlobalMapFileGrowSize` = `PAGE_SIZE × ALLOC_PAGES`,
    /// `inetcore/wininet/urlcache/global.h:51`, `cachedef.h:40-41`) : créé à
    /// 16 Ko (`MEMMAP_FILE::Init`, `urlcache/filemap.cxx:1186-1211`), étendu
    /// de 16 Ko chaque fois que la carte de ses blocs est pleine
    /// (`AllocateEntry`, `filemap.cxx:1455-1459` ; `GrowMapFile`,
    /// `filemap.cxx:671-750`), une entrée de plus de 16 Ko l'étendant d'un
    /// multiple de 16 Ko en un seul appel. Sa taille reste donc un multiple
    /// de 16 Ko (`filemap.cxx:1172`), et n'est jamais ramenée. Les
    /// allocations sont exactes (`NtfsSetEndOfFileInfo`, comme
    /// `compoundFile`). Attesté par le code de XP SP1, pour l'Internet
    /// Explorer 6 qu'il porte.
    case urlCacheIndex

    /// Le pas d'un fichier projeté, en octets ; `nil` pour une écriture par
    /// `WriteFile`.
    public var mappedStepBytes: UInt64? {
        switch self {
        case .buffered: nil
        case .compoundFile, .urlCacheIndex: 16 * 1_024
        }
    }

    /// La taille du fichier quand son programme veut y mettre `bytes` :
    /// arrondie au pas pour `index.dat`, dont `wininet` ne donne jamais au
    /// fichier une taille qui n'en soit pas un multiple ; inchangée
    /// ailleurs.
    public func fileBytes(holding bytes: UInt64) -> UInt64 {
        guard self == .urlCacheIndex, let step = mappedStepBytes, bytes > 0 else { return bytes }
        return (bytes + step - 1) / step * step
    }

    /// La taille que le programme donne au fichier à sa création, avant toute
    /// donnée : 512 octets pour ole32 (`MakeFileStub`). Un attribut résident,
    /// que la première extension convertit en non résident en lui donnant
    /// d'abord la place de ces octets (`NtfsConvertToNonresident`,
    /// `ntfs/attrsup.c:4554-4560`, `NtfsAllocateAttribute`,
    /// `allocsup.c:1036-1056`), comme à un fichier neuf.
    public var stubBytes: UInt64 {
        switch self {
        case .buffered, .urlCacheIndex: 0
        case .compoundFile: 512
        }
    }
}
