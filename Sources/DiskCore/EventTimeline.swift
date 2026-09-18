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
    /// Le programme qui écrit ce fichier savait-il quelle taille il ferait ?
    ///
    /// C'est une question de fait sur un programme, et la seule qu'on pose :
    /// une copie (`CopyFile` appelle `SetEndOfFile` avant d'écrire), un
    /// installeur qui lit la taille dans son catalogue, un éditeur qui écrit un
    /// tampon qu'il a en mémoire la connaissent ; un compilateur qui produit
    /// son `.obj` au fil du code, un navigateur qui reçoit une page, un
    /// logiciel de téléchargement, un compresseur ne la connaissent pas. Les
    /// premiers obtiennent leur place en une fois, les seconds par paquets
    /// (`Allocator.stream`). Aucun taux de fragmentation n'entre ici.
    public var sizeKnownInAdvance: Bool

    public init(id: UInt32,
                name: String,
                directory: UInt32,
                category: FileCategory,
                pattern: WritePattern = .createOnce,
                bytes: ByteCount,
                hint: AllocationHint? = nil,
                sizeKnownInAdvance: Bool = true) {
        self.id = id
        self.name = name
        self.directory = directory
        self.category = category
        self.pattern = pattern
        self.bytes = bytes
        self.hint = hint
        self.sizeKnownInAdvance = sizeKnownInAdvance
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

/// Le programme qui écrit.
///
/// Un programme écrit ses fichiers l'un après l'autre ; deux programmes
/// ouverts le même jour écrivent en même temps, et se disputent le curseur de
/// l'allocateur (`Simulator`). Les cas sont des programmes, pas des
/// catégories de fichiers : l'environnement de développement écrit les sources,
/// les objets et l'exécutable dans cet ordre-là, sans jamais les mêler.
///
/// L'ordre des cas est celui du tourniquet, et il ne sert qu'à le rendre
/// reproductible.
public enum Program: UInt8, Sendable, CaseIterable {
    /// Installeurs, mises à jour, désinstallations.
    case setup
    /// L'utilisateur qui fait de la place dans l'Explorateur.
    case explorer
    /// Le gestionnaire de mémoire, qui gonfle et dégonfle le fichier d'échange.
    case pager
    /// L'environnement de développement : éditeur, compilateur, éditeur de
    /// liens, et l'archive qu'on fait d'une version.
    case developer
    case browser
    /// Le traitement de texte.
    case office
    /// La messagerie, et sa boîte aux lettres qui grossit.
    case mail
    /// Encodeur MP3, import de l'appareil photo, capture vidéo.
    case media
    case download
    case game
    /// Ce que l'utilisateur entasse : archives, images de CD, sauvegardes.
    case collector
}

/// Un événement, et le jour où il se produit.
public struct TimedEvent: Sendable {
    /// Jour écoulé depuis le début du scénario. Le noyau ne connaît pas les
    /// calendriers : la conversion en date réelle appartient à la couche
    /// déclarative, au-dessus.
    public var day: UInt32
    public var event: FileEvent
    /// Qui l'écrit : c'est ce qui dit, dans une journée, ce qui se passe en
    /// même temps.
    public var program: Program

    public init(day: UInt32, event: FileEvent, program: Program = .setup) {
        self.day = day
        self.event = event
        self.program = program
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

    public mutating func append(_ event: FileEvent, on day: UInt32, by program: Program = .setup) {
        events.append(TimedEvent(day: day, event: event, program: program))
        dayCount = max(dayCount, day + 1)
    }

    public mutating func reserveCapacity(_ count: Int) {
        events.reserveCapacity(count)
    }

    /// Trie par jour en **conservant l'ordre d'insertion** à l'intérieur d'une
    /// même journée. Le tri de la bibliothèque standard n'étant pas stable, il
    /// faudrait sinon passer par le rang : sans cela, deux exécutions
    /// pourraient ordonner différemment deux événements du même jour, et les
    /// volumes divergeraient.
    ///
    /// Tri par comptage plutôt que comparaison : les jours sont des entiers
    /// bornés et connus d'avance, donc un seul passage suffit. Sur les millions
    /// d'événements d'un scénario de 2007, la différence n'est pas seulement de
    /// vitesse — un tri par comparaison sur des paires (rang, événement)
    /// allouerait des centaines de mégaoctets de tuples.
    public mutating func sortByDay() {
        guard events.count > 1 else { return }
        let days = Int(dayCount)
        var counts = [Int](repeating: 0, count: days + 1)
        for event in events { counts[Int(event.day)] += 1 }

        var offsets = [Int](repeating: 0, count: days + 1)
        var running = 0
        for day in 0...days {
            offsets[day] = running
            running += counts[day]
        }

        var sorted = events
        for event in events {
            let day = Int(event.day)
            sorted[offsets[day]] = event
            offsets[day] += 1
        }
        events = sorted
    }

    /// Renomme chaque fichier créé sous un nom que porte encore un fichier
    /// présent du même répertoire.
    ///
    /// FAT comme NTFS refusent deux fois le même nom dans un répertoire, sans
    /// distinction de casse, et les défragmenteurs s'appuient dessus : un tri
    /// par nom ou un départage par chemin n'est un ordre unique qu'à cette
    /// condition. Le compilateur, lui, nomme les fichiers d'après ce qu'ils
    /// sont — `MODULE.C`, `SAVE.DAT` — sans savoir ce qui existe encore au jour
    /// où ils sont écrits.
    ///
    /// Seuls les fichiers **présents en même temps** sont en conflit : un nom
    /// libéré par une suppression est repris tel quel, comme le ferait
    /// Windows. D'où une passe sur la timeline déjà triée, qui rejoue les
    /// créations et les suppressions dans l'ordre où le simulateur les verra.
    ///
    /// L'alias suit les noms courts de Windows : `MODULE~1.C`, radical ramené à
    /// huit caractères, extension gardée — c'est elle que lisent les requêtes
    /// du démarrage et les masques de JkDefrag. Aucun tirage aléatoire n'est
    /// consommé : la disposition sur le disque ne change pas.
    public mutating func giveUniqueNames() {
        /// Un nom dans son répertoire, comparé sans la casse des lettres ASCII.
        /// L'empreinte est calculée une fois, en un seul passage sur les
        /// octets : hacher la chaîne à chaque insertion et à chaque suppression
        /// coûtait près d'une seconde sur les millions de fichiers de
        /// `dev-2007`.
        struct Key: Hashable {
            let directory: UInt32
            let name: String
            let fingerprint: UInt64

            init(directory: UInt32, name: String) {
                var hash: UInt64 = 0xCBF2_9CE4_8422_2325 ^ UInt64(directory)
                for byte in name.utf8 {
                    hash = (hash ^ UInt64(Self.folded(byte))) &* 0x0000_0100_0000_01B3
                }
                self.directory = directory
                self.name = name
                self.fingerprint = hash
            }

            private static func folded(_ byte: UInt8) -> UInt8 {
                (0x61...0x7A).contains(byte) ? byte - 0x20 : byte
            }

            static func == (a: Key, b: Key) -> Bool {
                a.fingerprint == b.fingerprint && a.directory == b.directory
                    && a.name.utf8.elementsEqual(b.name.utf8) { folded($0) == folded($1) }
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine(fingerprint)
            }
        }
        func key(_ name: String, in directory: UInt32) -> Key {
            Key(directory: directory, name: name)
        }

        var live = Set<Key>()
        live.reserveCapacity(1 << 16)
        /// Le nom accordé à chaque fichier présent, rangé par identifiant : ceux
        /// du compilateur sont denses, un tableau évite un hachage par
        /// événement.
        var keyOfFile: [Key?] = []
        /// Prochain numéro d'alias à essayer, par nom demandé. Il ne repart à
        /// un que lorsque le nom lui-même se libère.
        var nextAlias: [Key: Int] = [:]

        for index in events.indices {
            switch events[index].event {
            case var .create(spec):
                let requested = key(spec.name, in: spec.directory)
                var granted = requested
                if !live.insert(requested).inserted {
                    let dot = spec.name.lastIndex(of: ".")
                    let stem = dot.map { spec.name[..<$0] } ?? spec.name[...]
                    let suffix = dot.map { spec.name[$0...] } ?? ""
                    var number = nextAlias[requested, default: 1]
                    repeat {
                        let tilde = "~\(number)"
                        spec.name = stem.prefix(max(1, 8 - tilde.count)) + tilde + suffix
                        granted = key(spec.name, in: spec.directory)
                        number += 1
                    } while !live.insert(granted).inserted
                    nextAlias[requested] = number
                    events[index].event = .create(spec)
                } else if !nextAlias.isEmpty {
                    nextAlias.removeValue(forKey: requested)
                }
                let slot = Int(spec.id)
                if slot >= keyOfFile.count { keyOfFile.append(contentsOf: repeatElement(nil, count: slot + 1 - keyOfFile.count)) }
                keyOfFile[slot] = granted

            case let .delete(id):
                let slot = Int(id)
                if slot < keyOfFile.count, let freed = keyOfFile[slot] {
                    live.remove(freed)
                    keyOfFile[slot] = nil
                }

            default:
                break
            }
        }
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
    /// Le programme qui écrit ce qu'on déroule en ce moment.
    public var program: Program = .setup

    public init(timeline: EventTimeline = EventTimeline()) {
        self.timeline = timeline
    }

    /// Un événement isolé, au nom du programme courant.
    public mutating func append(_ event: FileEvent, on day: UInt32) {
        timeline.append(event, on: day, by: program)
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
        append(.create(spec), on: startDay)

        // La mort d'un fichier éphémère ne dépend pas du nombre de fois qu'on y
        // touche : un `.obj` est supprimé à la fin de la compilation, qu'il ait
        // été relu ou non.
        if case let .createDeleteShortLived(lifetime) = spec.pattern {
            let death = startDay &+ max(lifetime, 1)
            append(.delete(id: spec.id), on: endDay > startDay ? min(death, endDay) : death)
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
                append(.append(id: spec.id, toBytes: size), on: day)
            }

        case .rewriteInPlace:
            for day in days {
                append(.rewrite(id: spec.id), on: day)
            }

        case .writeTempThenRename:
            // Le *fast save* de Word n'écrit que les modifications, à la fin du
            // fichier : le document gonfle d'un peu à chaque enregistrement,
            // **en valeur absolue** et non en proportion. Composer un
            // pourcentage ferait d'un rapport de 30 Ko un fichier de plus d'un
            // gigaoctet au bout de cent enregistrements.
            //
            // Et de loin en loin, Word procède à un enregistrement complet, qui
            // réécrit le document proprement et le ramène à sa taille utile.
            // C'est ce va-et-vient — gonflement lent, compactage brutal — qui
            // fait qu'un document travaillé change de place sans arrêt.
            var content = spec.bytes
            var saved = spec.bytes
            let increment = max(spec.bytes / 12, 1_500)
            var untilFullSave = 12 + Int(rng.below(16))

            for day in days {
                content += ByteCount(Double(increment) * rng.uniform(0.2...0.8))
                untilFullSave -= 1
                if untilFullSave <= 0 {
                    saved = content
                    untilFullSave = 12 + Int(rng.below(16))
                } else {
                    saved += ByteCount(Double(increment) * rng.uniform(0.5...1.5))
                }
                append(.replaceViaTemporary(id: spec.id, newBytes: saved), on: day)
            }

        case let .growShrinkDynamic(minBytes, maxBytes):
            var size = spec.bytes
            for day in days {
                let target = minBytes + ByteCount(rng.unitInterval() * Double(maxBytes - minBytes))
                if target > size {
                    append(.append(id: spec.id, toBytes: target), on: day)
                } else if target < size {
                    append(.truncate(id: spec.id, toBytes: target), on: day)
                }
                size = target
            }
        }
    }
}
