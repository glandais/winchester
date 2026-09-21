import Foundation

/// La carte des clusters racontée par zones, pour VoiceOver.
///
/// Lire vingt mille blocs un par un ne dit rien à personne. La carte se découpe
/// donc en quelques zones, dans l'ordre du volume — les blocs se lisent ligne
/// après ligne, du début à la fin —, et chacune se dit en une phrase : « début du
/// disque, 84 % occupé, surtout des applications rangées ».
struct MapZone: Equatable, Sendable {

    /// « début du disque », « deuxième quart »…
    let name: String
    /// Part occupée de la zone, de 0 à 1.
    let occupied: Double
    /// La catégorie qui y occupe le plus de place, s'il y a quoi que ce soit.
    let dominant: ClusterCategory?
    /// Vrai quand la plupart des blocs de cette catégorie sont d'un seul tenant.
    let dominantIsContiguous: Bool

    /// En dessous, la zone est dite vide : un bloc de temporaires égaré ne fait
    /// pas une zone « surtout temporaire ».
    static let emptyThreshold = 0.02

    var description: String {
        // Arrondi à l'unité : VoiceOver lit « 84 pour cent », une décimale n'y
        // ajouterait qu'une attente.
        let share = "\(Int((occupied * 100).rounded()))\u{00A0}%"
        guard occupied >= Self.emptyThreshold, let dominant else {
            return String(localized: "mapZone.empty", defaultValue: "\(name), empty")
        }
        let content = dominant.spokenContent(contiguous: dominantIsContiguous)
        return String(localized: "mapZone.description",
                      defaultValue: "\(name), \(share) used, mostly \(content)",
                      comment: "Une zone de la carte, dite par VoiceOver")
    }

    /// Découpe la carte en `count` zones de blocs consécutifs.
    static func zones(of shades: [ClusterShade], count: Int = 4) -> [MapZone] {
        guard !shades.isEmpty, count > 0 else { return [] }
        let names = zoneNames(count)
        let size = Int((Double(shades.count) / Double(count)).rounded(.up))
        return (0..<count).compactMap { index in
            let lower = index * size
            guard lower < shades.count else { return nil }
            let slice = shades[lower..<min(lower + size, shades.count)]
            return zone(names[index], slice)
        }
    }

    private static func zone(_ name: String, _ slice: ArraySlice<ClusterShade>) -> MapZone {
        var filled = 0.0
        var weight: [UInt8: Double] = [:]
        var contiguousWeight: [UInt8: Double] = [:]
        for shade in slice where shade.category != ClusterCategory.free.rawValue {
            let fraction = shade.fraction
            filled += fraction
            weight[shade.category, default: 0] += fraction
            if shade.contiguous { contiguousWeight[shade.category, default: 0] += fraction }
        }
        let top = weight.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }
        let dominant = top.flatMap { ClusterCategory(rawValue: $0.key) }
        let contiguous = top.map { (contiguousWeight[$0.key] ?? 0) >= $0.value / 2 } ?? false
        return MapZone(name: name,
                       occupied: slice.isEmpty ? 0 : filled / Double(slice.count),
                       dominant: dominant,
                       dominantIsContiguous: contiguous)
    }

    private static func zoneNames(_ count: Int) -> [String] {
        let start = String(localized: "mapZone.name.start", defaultValue: "start of the disk")
        let end = String(localized: "mapZone.name.end", defaultValue: "end of the disk")
        switch count {
        case 1: return [String(localized: "mapZone.name.whole", defaultValue: "the whole disk")]
        case 2: return [String(localized: "mapZone.name.firstHalf", defaultValue: "first half"),
                        String(localized: "mapZone.name.secondHalf", defaultValue: "second half")]
        case 3: return [start, String(localized: "mapZone.name.middle", defaultValue: "middle of the disk"), end]
        case 4: return [start, String(localized: "mapZone.name.secondQuarter", defaultValue: "second quarter"),
                        String(localized: "mapZone.name.thirdQuarter", defaultValue: "third quarter"), end]
        default:
            return (0..<count).map { index in
                index == 0 ? start : index == count - 1 ? end
                    : String(localized: "mapZone.name.nth",
                             defaultValue: "zone \(index + 1) of \(count)")
            }
        }
    }
}

extension ClusterCategory {

    /// Ce que contient une zone, dit à voix haute : « des applications rangées ».
    /// Le fichier d'échange et les tables du système de fichiers ne se rangent
    /// pas : ils ne portent pas la nuance.
    ///
    /// Chaque cas porte sa phrase entière, rangé et en morceaux séparément :
    /// le français accorde l'adjectif au nom, et le coller après coup —
    /// « rangé » + « e » + « s » — ne se traduit dans aucune autre langue.
    func spokenContent(contiguous: Bool) -> String {
        switch (self, contiguous) {
        case (.free, _):        return String(localized: "mapZone.content.free", defaultValue: "free space")
        case (.swap, _):        return String(localized: "mapZone.content.swap", defaultValue: "the page file")
        case (.reserved, _):    return String(localized: "mapZone.content.reserved", defaultValue: "the file system tables")
        case (.system, true):        return String(localized: "mapZone.content.system.tidy", defaultValue: "tidy system files")
        case (.system, false):       return String(localized: "mapZone.content.system.broken", defaultValue: "system files in pieces")
        case (.application, true):   return String(localized: "mapZone.content.application.tidy", defaultValue: "tidy applications")
        case (.application, false):  return String(localized: "mapZone.content.application.broken", defaultValue: "applications in pieces")
        case (.document, true):      return String(localized: "mapZone.content.document.tidy", defaultValue: "tidy documents")
        case (.document, false):     return String(localized: "mapZone.content.document.broken", defaultValue: "documents in pieces")
        case (.archive, true):       return String(localized: "mapZone.content.archive.tidy", defaultValue: "tidy help and archives")
        case (.archive, false):      return String(localized: "mapZone.content.archive.broken", defaultValue: "help and archives in pieces")
        case (.churn, true):         return String(localized: "mapZone.content.churn.tidy", defaultValue: "tidy temporary files")
        case (.churn, false):        return String(localized: "mapZone.content.churn.broken", defaultValue: "temporary files in pieces")
        case (.directory, true):     return String(localized: "mapZone.content.directory.tidy", defaultValue: "tidy directories")
        case (.directory, false):    return String(localized: "mapZone.content.directory.broken", defaultValue: "directories in pieces")
        }
    }
}
