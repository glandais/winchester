import Foundation
import DiskCore

/// Les nombres, les tailles et les durées tels que l'app les écrit — dans la
/// langue de l'appareil, pas dans une seule.
///
/// `FrenchUnits`, dans `DiskCore`, garde le français **pour les outils** :
/// c'est lui qui écrit les tables du `README.md` et les bilans de
/// `Tools/Measure`, qui sont français et le resteront. Ici, on lui emprunte
/// seulement la conversion en mégaoctets — `bytesPerMegabyte`, le 2²⁰ du
/// catalogue — et on laisse la locale décider du séparateur de milliers, de la
/// virgule décimale et du nom des unités.
public enum DisplayFormat {

    private static let nbsp = "\u{00A0}"

    public static func integer(_ value: Int) -> String {
        value.formatted(.number)
    }

    public static func decimal(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).rounded(rule: .toNearestOrEven))
    }

    /// Une taille en Mo, en Go au-delà d'un gigaoctet, avec une décimale sous
    /// dix mégaoctets ; en Ko sous un mégaoctet si on le demande.
    ///
    /// Les seuils et la conversion sont ceux de `FrenchUnits.megabytes` — un
    /// disque étiqueté « 210 Mo » doit retrouver ses 210 à l'écran ; seuls le
    /// nombre et le nom de l'unité suivent la langue.
    public static func megabytes(_ bytes: UInt64, smallInKilobytes: Bool = false) -> String {
        if smallInKilobytes && bytes < UInt64(FrenchUnits.bytesPerMegabyte) {
            return String(localized: "unit.kilobytes",
                          defaultValue: "\(integer(Int(bytes / 1_024)))\(nbsp)KB",
                          comment: "Une taille en kilooctets : le nombre, une espace insécable, l'unité")
        }
        let mb = Double(bytes) / FrenchUnits.bytesPerMegabyte
        if mb >= 1_024 {
            return String(localized: "unit.gigabytes",
                          defaultValue: "\(decimal(mb / 1_024, digits: 1))\(nbsp)GB")
        }
        if mb < 10 {
            return String(localized: "unit.megabytes",
                          defaultValue: "\(decimal(mb, digits: 1))\(nbsp)MB")
        }
        return String(localized: "unit.megabytes",
                      defaultValue: "\(integer(Int(mb.rounded())))\(nbsp)MB")
    }
}

/// Les vingt disques d'époque, dits dans la langue de l'appareil.
///
/// Leur nom et leur phrase de résumé vivent dans les JSON de
/// `Sources/DiskCore/Resources/scenarios/` : c'est là que la galerie les
/// décrit, et ces fichiers sont la référence du `README.md` autant que de
/// l'app. On ne les traduit donc pas sur place — on les relit par leur
/// identifiant, qui est stable, et on retombe sur le texte du fichier quand
/// aucune clé ne répond.
///
/// La traduction est posée **au chargement**, une fois, sur les `var` du
/// `ProfileSpec` : tout ce qui suit — la carte de la galerie, le titre d'une
/// passe, le bilan partagé — la reçoit sans avoir à y penser.
public extension ProfileSpec {

    func localized() -> ProfileSpec {
        var copy = self
        copy.displayName = GalleryStrings.name(of: id) ?? displayName
        copy.summary = GalleryStrings.summary(of: id) ?? summary
        return copy
    }
}

enum GalleryStrings {

    /// `nil` pour un disque construit dans l'app : son nom est celui que la
    /// personne lui a donné, et ne se traduit pas.
    static func name(of id: String) -> String? {
        switch id {
        case "dev-1993":        return String(localized: "gallery.dev-1993.name", defaultValue: "Developer, 1993")
        case "dev-1996":        return String(localized: "gallery.dev-1996.name", defaultValue: "Developer, 1996")
        case "dev-1999":        return String(localized: "gallery.dev-1999.name", defaultValue: "Developer, 1999")
        case "dev-2003":        return String(localized: "gallery.dev-2003.name", defaultValue: "Developer, 2003")
        case "dev-2007":        return String(localized: "gallery.dev-2007.name", defaultValue: "Developer, 2007")
        case "dev-2012":        return String(localized: "gallery.dev-2012.name", defaultValue: "Developer, 2012")
        case "famille-1996":    return String(localized: "gallery.famille-1996.name", defaultValue: "Family, 1996")
        case "famille-1999":    return String(localized: "gallery.famille-1999.name", defaultValue: "Family, 1999")
        case "famille-2003":    return String(localized: "gallery.famille-2003.name", defaultValue: "Family, 2003")
        case "famille-2007":    return String(localized: "gallery.famille-2007.name", defaultValue: "Family, 2007")
        case "famille-2012":    return String(localized: "gallery.famille-2012.name", defaultValue: "Family, 2012")
        case "gamer-1993":      return String(localized: "gallery.gamer-1993.name", defaultValue: "Gamer, 1993")
        case "gamer-1996":      return String(localized: "gallery.gamer-1996.name", defaultValue: "Gamer, 1996")
        case "gamer-1999":      return String(localized: "gallery.gamer-1999.name", defaultValue: "Gamer, 1999")
        case "gamer-2003":      return String(localized: "gallery.gamer-2003.name", defaultValue: "Gamer, 2003")
        case "gamer-2007":      return String(localized: "gallery.gamer-2007.name", defaultValue: "Gamer, 2007")
        case "gamer-2012":      return String(localized: "gallery.gamer-2012.name", defaultValue: "Gamer, 2012")
        case "poweruser-1993":  return String(localized: "gallery.poweruser-1993.name", defaultValue: "Tinkerer, 1993")
        case "secretaire-1993": return String(localized: "gallery.secretaire-1993.name", defaultValue: "Office work, 1993")
        case "secretaire-1996": return String(localized: "gallery.secretaire-1996.name", defaultValue: "Office work, 1996")
        case "secretaire-1999": return String(localized: "gallery.secretaire-1999.name", defaultValue: "Office work, 1999")
        case "secretaire-2003": return String(localized: "gallery.secretaire-2003.name", defaultValue: "Office work, 2003")
        case "secretaire-2007": return String(localized: "gallery.secretaire-2007.name", defaultValue: "Office work, 2007")
        case "secretaire-2012": return String(localized: "gallery.secretaire-2012.name", defaultValue: "Office work, 2012")
        default:                return nil
        }
    }

    static func summary(of id: String) -> String? {
        switch id {
        case "dev-1993":        return String(localized: "gallery.dev-1993.summary", defaultValue: "Borland C++ on a 486, nine builds a day on a 210 MB disk")
        case "dev-1996":        return String(localized: "gallery.dev-1996.summary", defaultValue: "Visual C++ 4.2, twelve builds a day and a 22 MB precompiled header")
        case "dev-1999":        return String(localized: "gallery.dev-1999.summary", defaultValue: "Daily builds and constant browsing on a 6,400 MB FAT32")
        case "dev-2003":        return String(localized: "gallery.dev-2003.summary", defaultValue: "Visual Studio .NET: fourteen builds a day, five hundred objects each time")
        case "dev-2007":        return String(localized: "gallery.dev-2007.summary", defaultValue: "Vista, WinSxS, and builds that barely fragment anything any more")
        case "dev-2012":        return String(localized: "gallery.dev-2012.summary", defaultValue: "Visual Studio 2010 on a 10,000 rpm VelociRaptor: seeks drop under 4 ms")
        case "famille-1996":    return String(localized: "gallery.famille-1996.summary", defaultValue: "A bit of everything: mail, browsing, a few games")
        case "famille-1999":    return String(localized: "gallery.famille-1999.summary", defaultValue: "The disk fills with ripped MP3s — clean, contiguous, and bulky")
        case "famille-2003":    return String(localized: "gallery.famille-2003.summary", defaultValue: "Photos and DivX until saturation: everything written afterwards is chopped up")
        case "famille-2007":    return String(localized: "gallery.famille-2007.summary", defaultValue: "Camcorder video and iTunes: the disk fills by the gigabyte")
        case "famille-2012":    return String(localized: "gallery.famille-2012.summary", defaultValue: "A terabyte for 16-megapixel photos and camcorder video")
        case "gamer-1993":      return String(localized: "gallery.gamer-1993.summary", defaultValue: "DOS games installed from floppies, and as many uninstalled")
        case "gamer-1996":      return String(localized: "gallery.gamer-1996.summary", defaultValue: "Quake and Doom II, few files but huge ones, and the swap breathing")
        case "gamer-1999":      return String(localized: "gallery.gamer-1999.summary", defaultValue: "Half-Life, demos installed then deleted, and plenty of saved games")
        case "gamer-2003":      return String(localized: "gallery.gamer-2003.summary", defaultValue: "Freshly installed: Unreal Tournament copied from the DVD, nothing else")
        case "gamer-2007":      return String(localized: "gallery.gamer-2007.summary", defaultValue: "Crysis and its 400 MB packs, installed and uninstalled")
        case "gamer-2012":      return String(localized: "gallery.gamer-2012.summary", defaultValue: "Battlefield 3 and its one-gigabyte archives, then Skyrim, on a VelociRaptor")
        case "poweruser-1993":  return String(localized: "gallery.poweruser-1993.summary", defaultValue: "BBS and archives on 1.44 MB floppies, extracted then deleted")
        case "secretaire-1993": return String(localized: "gallery.secretaire-1993.summary", defaultValue: "Works and a spreadsheet, hundreds of letters re-saved")
        case "secretaire-1996": return String(localized: "gallery.secretaire-1996.summary", defaultValue: "Office 95 and twenty-six documents a week, re-saved endlessly")
        case "secretaire-1999": return String(localized: "gallery.secretaire-1999.summary", defaultValue: "Office 97 for two years, and nothing but documents")
        case "secretaire-2003": return String(localized: "gallery.secretaire-2003.summary", defaultValue: "Office XP and an Outlook .pst growing for three years")
        case "secretaire-2007": return String(localized: "gallery.secretaire-2007.summary", defaultValue: "Office 2007 and the scheduled defragmentation running on its own")
        case "secretaire-2012": return String(localized: "gallery.secretaire-2012.summary", defaultValue: "Office 2010 on Windows 7, and the scheduled defragmentation twice a year")
        default:                return nil
        }
    }
}
