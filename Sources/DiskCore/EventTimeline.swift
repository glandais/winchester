import Foundation

/// Ce qu'il faut savoir pour créer un fichier, sans rien savoir du système de
/// fichiers qui l'accueillera.
public struct FileSpec: Sendable {
    public var id: UInt32
    public var name: String
    public var directory: UInt32
    public var category: FileCategory
    public var pattern: WritePattern
    /// Taille **logique**, en octets. Ce qu'elle coûtera réellement dépend du
    /// format : 2 Ko en FAT16 32 Ko, c'est 32 Ko.
    public var bytes: ByteCount
    public var hint: AllocationHint?

    public init(id: UInt32,
                name: String,
                directory: UInt32,
                category: FileCategory,
                pattern: WritePattern = .createOnce,
                bytes: ByteCount,
                hint: AllocationHint? = nil) {
        self.id = id
        self.name = name
        self.directory = directory
        self.category = category
        self.pattern = pattern
        self.bytes = bytes
        self.hint = hint
    }

    public var resolvedHint: AllocationHint { hint ?? category.hint }
}

/// Une opération de système de fichiers, décrite en octets et en identifiants.
///
/// Rien ici ne dépend du format : c'est ce qui permet de rejouer exactement la
/// même histoire sur FAT16, FAT32 et NTFS et de n'attribuer les différences
/// qu'à l'allocateur.
public enum FileEvent: Sendable {

    case create(FileSpec)

    /// Ajout par la fin : le fichier passe à cette nouvelle taille.
    case append(id: UInt32, toBytes: ByteCount)

    /// Réécriture sur place, taille inchangée : aucune allocation.
    case rewrite(id: UInt32)

    /// Word : un temporaire est écrit à côté, puis remplace l'original. Le
    /// fichier survit sous le même identifiant, mais ailleurs sur le disque.
    case replaceViaTemporary(id: UInt32, newBytes: ByteCount)

    /// Le fichier est réduit — le swap qui se dégonfle.
    case truncate(id: UInt32, toBytes: ByteCount)

    case delete(id: UInt32)

    /// Une passe de défragmentation : tout est rendu contigu et tassé vers le
    /// début du volume, dans l'ordre du parcours de l'arborescence.
    case defragment
}

/// Un événement, et le jour où il se produit.
public struct TimedEvent: Sendable {
    /// Jour écoulé depuis le début du scénario. Le noyau ne connaît pas les
    /// calendriers : la conversion en date réelle appartient à la couche
    /// déclarative, au-dessus.
    public var day: UInt32
    public var event: FileEvent

    public init(day: UInt32, event: FileEvent) {
        self.day = day
        self.event = event
    }
}

/// Suite datée et déterministe d'opérations, construite **avant** toute
/// allocation.
///
/// C'est la pièce qui rend le modèle honnête : l'histoire est écrite une fois,
/// indépendamment du disque, puis rejouée. On ne peut donc pas, même par
/// accident, ajuster l'histoire pour obtenir la fragmentation qu'on voulait
/// voir.
public struct EventTimeline: Sendable {

    public private(set) var events: [TimedEvent] = []
    /// Durée couverte, en jours.
    public private(set) var dayCount: UInt32 = 0

    public init() {}

    public init(events: [TimedEvent]) {
        self.events = events
        self.dayCount = (events.map(\.day).max() ?? 0) + 1
    }

    public var count: Int { events.count }
    public var isEmpty: Bool { events.isEmpty }

    public mutating func append(_ event: FileEvent, on day: UInt32) {
        events.append(TimedEvent(day: day, event: event))
        dayCount = max(dayCount, day + 1)
    }

    public mutating func reserveCapacity(_ count: Int) {
        events.reserveCapacity(count)
    }

    /// Trie par jour en **conservant l'ordre d'insertion** à l'intérieur d'une
    /// même journée. Le tri de la bibliothèque standard n'étant pas stable, il
    /// faut passer par le rang : sans cela, deux exécutions pourraient ordonner
    /// différemment deux événements du même jour, et les volumes divergeraient.
    public mutating func sortByDay() {
        let indexed = events.enumerated().sorted { lhs, rhs in
            lhs.element.day != rhs.element.day
                ? lhs.element.day < rhs.element.day
                : lhs.offset < rhs.offset
        }
        events = indexed.map(\.element)
    }
}

// MARK: - Traduction des motifs d'écriture en événements

/// Écrit dans une timeline la vie complète d'un fichier, telle que son motif
/// d'écriture la dicte.
///
/// C'est ici que les motifs deviennent des événements, et donc de la
/// fragmentation. Un même fichier de 40 Ko donne une seule écriture s'il est
/// copié depuis un CD, et cent vingt allocations éparpillées s'il est
/// réenregistré chaque semaine par Word.
public struct PatternWriter {

    public var timeline: EventTimeline

    public init(timeline: EventTimeline = EventTimeline()) {
        self.timeline = timeline
    }

    /// Déroule la vie d'un fichier, du jour `from` au jour `to`.
    ///
    /// - Parameter touchesPerPeriod: nombre de sollicitations sur la période —
    ///   enregistrements, ajouts au journal, cycles de gonflement. Zéro laisse
    ///   le fichier tranquille quel que soit son motif.
    public mutating func write(_ spec: FileSpec,
                               from startDay: UInt32,
                               to endDay: UInt32,
                               touches: Int,
                               rng: inout SeededGenerator) {
        timeline.append(.create(spec), on: startDay)

        // La mort d'un fichier éphémère ne dépend pas du nombre de fois qu'on y
        // touche : un `.obj` est supprimé à la fin de la compilation, qu'il ait
        // été relu ou non.
        if case let .createDeleteShortLived(lifetime) = spec.pattern {
            let death = startDay &+ max(lifetime, 1)
            timeline.append(.delete(id: spec.id), on: endDay > startDay ? min(death, endDay) : death)
            return
        }

        guard touches > 0, endDay > startDay else { return }

        let span = endDay - startDay
        /// Jours des sollicitations, étalés sur la période et **triés** : une
        /// vie de fichier ne remonte pas le temps.
        var days: [UInt32] = []
        days.reserveCapacity(touches)
        for _ in 0..<touches {
            days.append(startDay + 1 + rng.cluster(below: max(span, 1)))
        }
        days.sort()

        switch spec.pattern {
        case .createOnce, .createDeleteShortLived:
            break

        case let .append(growth):
            var size = spec.bytes
            for day in days {
                // Le journal ne grossit jamais deux fois du même nombre exact
                // d'octets : la dispersion évite un motif d'allocation
                // artificiellement régulier.
                size += ByteCount(Double(growth) * rng.uniform(0.6...1.4))
                timeline.append(.append(id: spec.id, toBytes: size), on: day)
            }

        case .rewriteInPlace:
            for day in days {
                timeline.append(.rewrite(id: spec.id), on: day)
            }

        case .writeTempThenRename:
            var size = spec.bytes
            for day in days {
                // Le *fast save* de Word ajoute les modifications à la fin du
                // fichier au lieu de le réécrire : un document travaillé grossit
                // sans raison apparente.
                size += ByteCount(Double(size) * rng.uniform(0.02...0.12))
                timeline.append(.replaceViaTemporary(id: spec.id, newBytes: size), on: day)
            }

        case let .growShrinkDynamic(minBytes, maxBytes):
            var size = spec.bytes
            for day in days {
                let target = minBytes + ByteCount(rng.unitInterval() * Double(maxBytes - minBytes))
                if target > size {
                    timeline.append(.append(id: spec.id, toBytes: target), on: day)
                } else if target < size {
                    timeline.append(.truncate(id: spec.id, toBytes: target), on: day)
                }
                size = target
            }
        }
    }
}
