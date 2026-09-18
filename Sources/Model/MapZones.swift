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
        guard occupied >= Self.emptyThreshold, let dominant else { return "\(name), vide" }
        return "\(name), \(share) occupé, surtout \(dominant.spokenContent(contiguous: dominantIsContiguous))"
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
        switch count {
        case 1: return ["tout le disque"]
        case 2: return ["première moitié", "seconde moitié"]
        case 3: return ["début du disque", "milieu du disque", "fin du disque"]
        case 4: return ["début du disque", "deuxième quart", "troisième quart", "fin du disque"]
        default:
            return (0..<count).map { index in
                index == 0 ? "début du disque" : index == count - 1 ? "fin du disque" : "zone \(index + 1) sur \(count)"
            }
        }
    }
}

extension ClusterCategory {

    /// Ce que contient une zone, dit à voix haute : « des applications rangées ».
    /// Le fichier d'échange et les tables du système de fichiers ne se rangent
    /// pas : ils ne portent pas la nuance.
    func spokenContent(contiguous: Bool) -> String {
        func state(_ masculine: Bool, plural: Bool) -> String {
            if !contiguous { return "en morceaux" }
            return "rangé" + (masculine ? "" : "e") + (plural ? "s" : "")
        }
        switch self {
        case .free:        return "de l'espace libre"
        case .system:      return "du système \(state(true, plural: false))"
        case .application: return "des applications \(state(false, plural: true))"
        case .document:    return "des documents \(state(true, plural: true))"
        case .archive:     return "de l'aide et des archives \(state(false, plural: true))"
        case .churn:       return "des fichiers temporaires \(state(true, plural: true))"
        case .swap:        return "le fichier d'échange"
        case .reserved:    return "les tables du système de fichiers"
        case .directory:   return "des répertoires \(state(true, plural: true))"
        }
    }
}
