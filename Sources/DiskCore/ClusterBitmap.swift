import Foundation

/// Table d'occupation des clusters d'un volume : un bit par cluster, mis à 1
/// quand le cluster est alloué.
///
/// C'est la seule structure dont la taille suit celle du disque, d'où le choix
/// du bit : un volume XP de 80 Go en clusters de 4 Ko compte 20 millions de
/// clusters, soit 2,5 Mo ici — contre 80 Mo pour un octet par cluster et 160 Mo
/// pour le tableau d'identifiants de propriétaire qu'utilisait le modèle
/// statique. Le lien cluster → fichier n'est pas stocké : il se reconstruit à
/// la demande depuis les extents du catalogue, et n'intéresse que le
/// défragmenteur.
///
/// Les bits de bourrage du dernier mot — ceux qui dépassent `clusterCount` —
/// sont posés à 1 dès la construction. Toutes les recherches de place libre
/// travaillent alors sur les mots entiers sans avoir à tester les bornes à
/// chaque tour : un cluster hors du volume n'est jamais libre.
///
/// **Deux niveaux de résumé** servent d'index des trous. `partial` porte un bit
/// par mot de la bitmap, posé quand ce mot a au moins un cluster libre ;
/// `partialSummary` porte un bit par mot de `partial`, posé quand ce mot-là
/// n'est pas nul. Chercher le prochain cluster libre saute ainsi 64 puis 4 096
/// mots pleins d'un coup, au lieu de les lire un à un. C'est ce qui manquait à
/// un volume plein : sur le 250 Go de `dev-2007`, les écritures traversaient
/// huit milliards de mots pleins pour rassembler des trous épars.
///
/// L'index ne décide de rien : la réponse est exactement celle du balayage,
/// seulement plus tôt. Il coûte un bit tous les 64 clusters, 125 Ko sur ce
/// même volume.
public struct ClusterBitmap: Sendable {

    public let clusterCount: UInt32

    private var words: [UInt64]
    private var partial: [UInt64]
    private var partialSummary: [UInt64]
    private var allocatedCount: UInt32

    public init(clusterCount: UInt32) {
        precondition(clusterCount > 0, "volume vide")
        self.clusterCount = clusterCount
        let wordCount = Int((UInt64(clusterCount) + 63) / 64)
        self.words = [UInt64](repeating: 0, count: wordCount)
        self.allocatedCount = 0

        let remainder = Int(UInt64(clusterCount) % 64)
        if remainder != 0 {
            // Bourrage : tout ce qui dépasse le dernier cluster est « occupé ».
            words[wordCount - 1] = ~UInt64(0) << UInt64(remainder)
        }

        // Tous les mots ont un cluster libre, le dernier compris : son
        // bourrage laisse au moins un vrai cluster. Les bits de résumé au-delà
        // du dernier mot restent à zéro — « rien de libre ».
        self.partial = Self.fullMask(bits: wordCount)
        self.partialSummary = Self.fullMask(bits: partial.count)
    }

    /// `bits` bits à un, rangés par mots de 64.
    private static func fullMask(bits: Int) -> [UInt64] {
        var mask = [UInt64](repeating: ~UInt64(0), count: (bits + 63) / 64)
        let remainder = bits % 64
        if remainder != 0 { mask[mask.count - 1] = (UInt64(1) << UInt64(remainder)) - 1 }
        return mask
    }

    // MARK: - État

    public var freeCount: UInt32 { clusterCount - allocatedCount }

    public var usedCount: UInt32 { allocatedCount }

    /// Taux de remplissage, de 0 à 1. Variable de premier ordre d'un scénario :
    /// c'est en passant 90 % qu'un volume se met à fragmenter tout ce qu'on y
    /// écrit, et 87 % qu'un NTFS commence à entamer sa zone MFT.
    public var fill: Double { Double(allocatedCount) / Double(clusterCount) }

    public func isAllocated(_ cluster: UInt32) -> Bool {
        precondition(cluster < clusterCount, "cluster \(cluster) hors du volume")
        return words[Int(cluster >> 6)] & (1 << UInt64(cluster & 63)) != 0
    }

    public func isFree(_ cluster: UInt32) -> Bool { !isAllocated(cluster) }

    /// Le run est-il entièrement libre ? Répond `false` s'il déborde du volume.
    public func isRunFree(start: UInt32, length: UInt32) -> Bool {
        guard length > 0 else { return true }
        guard UInt64(start) + UInt64(length) <= UInt64(clusterCount) else { return false }
        return countAllocated(start: start, length: length) == 0
    }

    public func isFree(_ extent: Extent) -> Bool {
        isRunFree(start: extent.start, length: extent.length)
    }

    // MARK: - Allocation et libération

    /// - Returns: le nombre de clusters effectivement passés de libre à alloué.
    ///   Un allocateur correct doit toujours obtenir `length` ; l'écart signale
    ///   une double allocation.
    @discardableResult
    public mutating func allocate(start: UInt32, length: UInt32) -> UInt32 {
        setRange(start: start, length: length, allocated: true)
    }

    @discardableResult
    public mutating func allocate(_ extent: Extent) -> UInt32 {
        setRange(start: extent.start, length: extent.length, allocated: true)
    }

    @discardableResult
    public mutating func free(start: UInt32, length: UInt32) -> UInt32 {
        setRange(start: start, length: length, allocated: false)
    }

    @discardableResult
    public mutating func free(_ extent: Extent) -> UInt32 {
        setRange(start: extent.start, length: extent.length, allocated: false)
    }

    @discardableResult
    public mutating func free(_ extents: [Extent]) -> UInt32 {
        var total: UInt32 = 0
        for extent in extents { total &+= free(extent) }
        return total
    }

    /// Pose ou retire les bits d'une plage et tient le compteur à jour. Les
    /// mots entièrement couverts sont traités d'un bloc — c'est ce qui rend
    /// l'allocation d'un `pagefile.sys` de 1,5 Go instantanée.
    @discardableResult
    private mutating func setRange(start: UInt32, length: UInt32, allocated: Bool) -> UInt32 {
        guard length > 0 else { return 0 }
        precondition(UInt64(start) + UInt64(length) <= UInt64(clusterCount),
                     "plage \(start)+\(length) hors du volume de \(clusterCount) clusters")

        let end = start + length
        var firstWord = Int(start >> 6)
        let lastWord = Int((end - 1) >> 6)
        var changed: UInt32 = 0

        while firstWord <= lastWord {
            let wordFirstCluster = UInt32(firstWord) << 6
            let low = max(start, wordFirstCluster) - wordFirstCluster
            let high = min(end, wordFirstCluster &+ 64) - wordFirstCluster   // exclusif

            let mask: UInt64 = high == 64 && low == 0
                ? ~UInt64(0)
                : (((1 << UInt64(high - low)) - 1) << UInt64(low))

            let before = words[firstWord]
            let after = allocated ? (before | mask) : (before & ~mask)
            if before != after {
                changed &+= UInt32((before ^ after).nonzeroBitCount)
                words[firstWord] = after
                if (before == ~0) != (after == ~0) {
                    markWord(firstWord, hasFree: after != ~0)
                }
            }
            firstWord += 1
        }

        allocatedCount = allocated ? allocatedCount &+ changed : allocatedCount &- changed
        return changed
    }

    /// Tient les deux niveaux de résumé quand un mot devient plein, ou cesse
    /// de l'être.
    private mutating func markWord(_ word: Int, hasFree: Bool) {
        let index = word >> 6
        let bit = UInt64(1) << UInt64(word & 63)
        let before = partial[index]
        let after = hasFree ? (before | bit) : (before & ~bit)
        partial[index] = after
        if (before == 0) != (after == 0) {
            let summaryBit = UInt64(1) << UInt64(index & 63)
            if after == 0 {
                partialSummary[index >> 6] &= ~summaryBit
            } else {
                partialSummary[index >> 6] |= summaryBit
            }
        }
    }

    /// Le premier mot d'indice au moins `word` qui a un cluster libre, lu dans
    /// les résumés plutôt que dans la bitmap.
    private func nextWordWithFree(from word: Int) -> Int? {
        guard word < words.count else { return nil }
        var index = word >> 6
        var bits = partial[index] & (~UInt64(0) << UInt64(word & 63))
        if bits != 0 { return (index << 6) + bits.trailingZeroBitCount }

        index += 1
        guard index < partial.count else { return nil }
        var summary = index >> 6
        var summaryBits = partialSummary[summary] & (~UInt64(0) << UInt64(index & 63))
        while summaryBits == 0 {
            summary += 1
            guard summary < partialSummary.count else { return nil }
            summaryBits = partialSummary[summary]
        }
        index = (summary << 6) + summaryBits.trailingZeroBitCount
        bits = partial[index]
        return (index << 6) + bits.trailingZeroBitCount
    }

    /// Le dernier mot d'indice au plus `word` qui a un cluster libre : la même
    /// descente dans les résumés, dans l'autre sens.
    private func previousWordWithFree(from word: Int) -> Int? {
        guard word >= 0 else { return nil }
        var index = word >> 6
        var bits = partial[index] & (~UInt64(0) >> UInt64(63 - word & 63))
        if bits != 0 { return (index << 6) + 63 - bits.leadingZeroBitCount }

        index -= 1
        guard index >= 0 else { return nil }
        var summary = index >> 6
        var summaryBits = partialSummary[summary] & (~UInt64(0) >> UInt64(63 - index & 63))
        while summaryBits == 0 {
            summary -= 1
            guard summary >= 0 else { return nil }
            summaryBits = partialSummary[summary]
        }
        index = (summary << 6) + 63 - summaryBits.leadingZeroBitCount
        bits = partial[index]
        return (index << 6) + 63 - bits.leadingZeroBitCount
    }

    private func countAllocated(start: UInt32, length: UInt32) -> UInt32 {
        guard length > 0 else { return 0 }
        let end = start + length
        var word = Int(start >> 6)
        let lastWord = Int((end - 1) >> 6)
        var total: UInt32 = 0

        while word <= lastWord {
            let wordFirstCluster = UInt32(word) << 6
            let low = max(start, wordFirstCluster) - wordFirstCluster
            let high = min(end, wordFirstCluster &+ 64) - wordFirstCluster

            let mask: UInt64 = high == 64 && low == 0
                ? ~UInt64(0)
                : (((1 << UInt64(high - low)) - 1) << UInt64(low))

            total &+= UInt32((words[word] & mask).nonzeroBitCount)
            word += 1
        }
        return total
    }

    // MARK: - Recherche de place libre

    /// Premier cluster libre à partir de `cluster` inclus, sans repasser par le
    /// début du volume.
    ///
    /// - Parameter before: abandonne la recherche au-delà de ce cluster. La
    ///   borne doit être **dans** la boucle de scan et non appliquée au
    ///   résultat : c'est toute la différence entre renoncer après huit mots et
    ///   traverser les trois cent mille mots d'un volume de 80 Go avant de
    ///   constater qu'on est allé trop loin.
    public func nextFreeCluster(from cluster: UInt32, before limit: UInt32? = nil) -> UInt32? {
        guard cluster < clusterCount else { return nil }
        let stop = min(limit ?? clusterCount, clusterCount)
        guard cluster < stop else { return nil }

        let firstWord = Int(cluster >> 6)
        let lastWord = Int((stop - 1) >> 6)
        // Les bits déjà dépassés dans le premier mot sont vus comme occupés.
        let first = ~(words[firstWord] | ((1 << UInt64(cluster & 63)) - 1))
        if first != 0 {
            let candidate = UInt32(firstWord << 6) &+ UInt32(first.trailingZeroBitCount)
            return candidate < stop ? candidate : nil
        }

        // Les mots pleins qui suivent sont sautés par l'index.
        guard let word = nextWordWithFree(from: firstWord + 1), word <= lastWord else { return nil }
        let candidate = UInt32(word << 6) &+ UInt32((~words[word]).trailingZeroBitCount)
        return candidate < stop ? candidate : nil
    }

    /// Run libre **maximal** commençant au premier cluster libre trouvé à partir
    /// de `cluster`. C'est la primitive sur laquelle sont bâties les trois
    /// stratégies d'allocation : elles ne diffèrent que par la façon dont elles
    /// parcourent la suite de runs que produit cette fonction.
    ///
    /// - Parameter limit: mesure au plus `limit` clusters. Un appelant qui sait
    ///   combien de place il cherche n'a aucune raison de faire compter le
    ///   reste : sur un volume neuf, le premier trou fait la taille du disque
    ///   entier, et le mesurer à chaque allocation rend le remplissage
    ///   quadratique.
    public func nextFreeRun(from cluster: UInt32, limit: UInt32 = .max, before: UInt32? = nil) -> Extent? {
        guard let start = nextFreeCluster(from: cluster, before: before) else { return nil }
        return Extent(start: start, length: freeRunLength(at: start, limit: limit))
    }

    /// Dernier cluster libre **strictement avant** `limit`.
    public func previousFreeCluster(before limit: UInt32) -> UInt32? {
        let stop = min(limit, clusterCount)
        guard stop > 0 else { return nil }
        let last = stop - 1
        let lastWord = Int(last >> 6)
        // Les bits au-delà de `last` dans son mot sont vus comme occupés.
        let keep: UInt64 = last & 63 == 63 ? ~0 : (1 << UInt64((last & 63) + 1)) - 1
        let free = ~words[lastWord] & keep
        if free != 0 {
            return UInt32(lastWord << 6) + 63 - UInt32(free.leadingZeroBitCount)
        }
        guard let word = previousWordWithFree(from: lastWord - 1) else { return nil }
        return UInt32(word << 6) + 63 - UInt32((~words[word]).leadingZeroBitCount)
    }

    /// Run libre **maximal** qui finit au dernier cluster libre avant `limit`.
    ///
    /// C'est `nextFreeRun` lu du fond du disque vers le début : ce que cherche un
    /// outil qui remplit les trous par le haut. Sans lui, trouver le dernier trou
    /// sous une borne demandait de les énumérer tous depuis le début du volume.
    public func previousFreeRun(before limit: UInt32) -> Extent? {
        guard let last = previousFreeCluster(before: limit) else { return nil }
        var word = Int(last >> 6)
        let bit = last & 63
        let below: UInt64 = bit == 63 ? ~0 : (1 << UInt64(bit + 1)) - 1
        var allocated = words[word] & below
        while allocated == 0 {
            guard word > 0 else { return Extent(start: 0, length: last + 1) }
            word -= 1
            allocated = words[word]
        }
        let start = UInt32(word << 6) + 64 - UInt32(allocated.leadingZeroBitCount)
        return Extent(start: start, length: last + 1 - start)
    }

    /// Longueur du run libre qui commence exactement à `start`, plafonnée à
    /// `limit`. Une longueur rendue égale à `limit` signifie « au moins
    /// autant », pas « exactement autant ».
    public func freeRunLength(at start: UInt32, limit: UInt32 = .max) -> UInt32 {
        guard limit > 0 else { return 0 }
        guard start < clusterCount, !isAllocated(start) else { return 0 }
        var word = Int(start >> 6)
        var value = words[word] >> UInt64(start & 63)
        var length: UInt32 = 0
        var bitsInWord = 64 - UInt32(start & 63)

        while true {
            if value != 0 {
                let run = UInt32(value.trailingZeroBitCount)
                return min(length &+ min(run, bitsInWord), limit)
            }
            length &+= bitsInWord
            if length >= limit { return limit }
            word += 1
            guard word < words.count else { break }
            value = words[word]
            bitsInWord = 64
        }
        // Le bourrage du dernier mot garantit qu'on ne sort jamais du volume,
        // mais le compte est tronqué par sécurité si le volume tombe pile.
        return min(length, clusterCount - start, limit)
    }

    /// **First-fit** : premier run d'au moins `minLength` clusters, en partant
    /// de `cluster`. C'est la stratégie de FAT16 (avec `from: 2`, donc un scan
    /// complet à chaque allocation, qui rebouche les trous aussitôt) et celle
    /// de FAT32 (avec `from:` le dernier cluster alloué, d'où le `wrap`).
    ///
    /// - Parameter wrap: reprendre au début du volume après en avoir atteint la
    ///   fin. C'est le retour en arrière du hint `next-free` de FSINFO, celui
    ///   qui fabrique la fragmentation par vagues de FAT32.
    /// - Parameter maxLength: place réellement recherchée, quand l'appelant en
    ///   connaît le plafond. Le run rendu n'est jamais plus long, et le trou
    ///   n'est mesuré que jusque-là : c'est ce qui garde le remplissage d'un
    ///   volume linéaire plutôt que quadratique.
    public func firstFitRun(minLength: UInt32,
                            maxLength: UInt32 = .max,
                            from cluster: UInt32 = 0,
                            wrap: Bool = false) -> Extent? {
        guard minLength > 0, minLength <= freeCount else { return nil }
        let start: UInt32
        if cluster < clusterCount {
            start = cluster
        } else if wrap {
            start = 0                 // le hint a dépassé la fin : il repart au début
        } else {
            return nil
        }

        let cap = max(minLength, maxLength)
        var position = start
        while let run = nextFreeRun(from: position, limit: cap) {
            if run.length >= minLength { return run }
            position = run.end
            if position >= clusterCount { break }
        }

        guard wrap, start > 0 else { return nil }
        position = 0
        while let run = nextFreeRun(from: position, limit: cap), run.start < start {
            if run.length >= minLength { return run }
            position = run.end
            if position >= clusterCount { break }
        }
        return nil
    }

    /// **Best-fit** : le plus petit run capable d'accueillir `minLength`
    /// clusters, et à égalité de taille le plus proche du début du volume.
    /// C'est la stratégie de NTFS, celle qui garde les fichiers contigus
    /// beaucoup plus longtemps — et qui, une fois le volume plein, n'a plus que
    /// des miettes à distribuer.
    ///
    /// Contrairement au first-fit, le best-fit doit connaître la taille exacte
    /// de chaque trou qu'il examine : il ne peut donc pas plafonner ses mesures,
    /// et un trou de plusieurs millions de clusters lui coûte le parcours
    /// complet. **L'appelant doit restreindre la plage** à la partie du volume
    /// déjà servie, faute de quoi chaque allocation re-mesure tout l'espace
    /// vierge restant. C'est aussi pour cette raison qu'un vrai NTFS ne fait pas
    /// du best-fit pur : il choisit dans ce que son cache de zones libres lui
    /// montre.
    ///
    /// - Parameter range: restreint la recherche à une plage. Sert à tenir
    ///   l'allocateur NTFS hors de la zone MFT tant qu'il reste de la place
    ///   ailleurs.
    /// - Parameter from: cluster où commencer le parcours. Par défaut le début
    ///   de la plage.
    /// - Parameter maxRunsExamined: nombre maximal de trous examinés avant de se
    ///   décider. Un best-fit exact coûte un parcours complet de la bitmap à
    ///   **chaque** allocation, ce qui rend la génération d'un volume de 80 Go
    ///   quadratique. Un vrai NTFS ne fait pas mieux : il travaille sur un cache
    ///   partiel de sa table d'occupation et choisit le meilleur trou qu'il y
    ///   trouve, pas le meilleur du volume. Borner la recherche est donc à la
    ///   fois plus rapide et plus fidèle.
    /// - Parameter maxClustersScanned: distance maximale parcourue. C'est la
    ///   borne qui compte vraiment : sur un volume de vingt millions de
    ///   clusters dont plusieurs millions sont occupés d'un seul tenant, ce
    ///   n'est pas le nombre de trous examinés qui coûte, c'est la traversée
    ///   des zones pleines qui les sépare.
    /// - Parameter measureLimit: mesure chaque trou au plus jusque-là. Un trou
    ///   rendu à cette longueur signifie « au moins autant », pas « exactement
    ///   autant » — l'appelant l'utilise pour dire « au-delà de cette taille,
    ///   les trous ne m'intéressent plus, je préfère écrire ailleurs ». Sans ce
    ///   plafond, chaque recherche mesure entièrement l'espace libre qu'elle
    ///   croise : sur un volume de 250 Go rempli aux trois quarts, c'est la
    ///   différence entre deux secondes et une minute de génération.
    public func bestFitRun(minLength: UInt32,
                           in range: Range<UInt32>? = nil,
                           from: UInt32? = nil,
                           maxRunsExamined: Int = .max,
                           maxClustersScanned: UInt32 = .max,
                           measureLimit: UInt32 = .max) -> Extent? {
        guard minLength > 0 else { return nil }
        let lower = range?.lowerBound ?? 0
        let upper = min(range?.upperBound ?? clusterCount, clusterCount)
        guard lower < upper else { return nil }

        var best: Extent?
        var examined = 0
        let origin = max(from ?? lower, lower)
        var position = origin
        let horizon = maxClustersScanned == .max
            ? upper
            : min(upper, origin &+ maxClustersScanned)

        while let run = nextFreeRun(from: position, limit: measureLimit, before: horizon) {
            // Un run qui dépasse la plage n'y est utilisable que pour sa part
            // interne : c'est ce qui permet de s'arrêter net au bord de la MFT.
            let usable = min(run.end, upper) - run.start
            if usable >= minLength, best == nil || usable < best!.length {
                best = Extent(start: run.start, length: usable)
                if usable == minLength { break }   // impossible de faire mieux
            }
            // Tous les trous traversés comptent, pas seulement ceux qui
            // conviennent : sur un volume mité, ce sont les miettes qu'on
            // enjambe qui coûtent cher, et un vrai allocateur ne les voit pas
            // non plus.
            examined += 1
            if examined >= maxRunsExamined { break }
            position = run.end
            if position >= clusterCount { break }
        }
        return best
    }

    /// Plus grand bloc libre du volume — l'une des métriques de sortie, et le
    /// test qui dit si un fichier à placement contraint (`pagefile.sys`,
    /// `hiberfil.sys`) peut encore tenir d'un seul tenant.
    public func largestFreeRun() -> Extent? {
        var best: Extent?
        var position: UInt32 = 0
        while let run = nextFreeRun(from: position) {
            if best == nil || run.length > best!.length { best = run }
            position = run.end
            if position >= clusterCount { break }
        }
        return best
    }

    /// Nombre de trous distincts dans l'espace libre. Mesure à quel point le
    /// volume va fragmenter le prochain fichier écrit.
    public func freeRunCount() -> Int {
        var count = 0
        var position: UInt32 = 0
        while let run = nextFreeRun(from: position) {
            count += 1
            position = run.end
            if position >= clusterCount { break }
        }
        return count
    }

    /// Parcourt les runs libres dans l'ordre des adresses. L'ordre est celui du
    /// volume, jamais celui d'une table de hachage : c'est une des conditions du
    /// déterminisme.
    public func forEachFreeRun(from cluster: UInt32 = 0, _ body: (Extent) -> Bool) {
        var position = cluster
        while let run = nextFreeRun(from: position) {
            if !body(run) { return }
            position = run.end
            if position >= clusterCount { return }
        }
    }
}
