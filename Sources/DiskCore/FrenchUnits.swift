import Foundation

/// Les nombres et les octets tels qu'on les écrit en français, en un seul
/// endroit — espace fine insécable entre les milliers, virgule décimale.
///
/// Ce fichier existe parce que deux conventions coexistaient. `FrenchFormat`
/// divisait par 2²⁰ dans l'interface ; une demi-douzaine de divisions écrites
/// à la main divisaient par 10⁶ ailleurs. Comme les deux chemins ne suivaient
/// pas les écrans mais le code, le même disque s'annonçait « 210 Mo » sur sa
/// fiche et « 220 Mo » sur la passe, et la même passe « 49 Mo déplacés » puis
/// « 47 Mo » dans son bilan (`UX_REVIEW.md` §3). Tant qu'un octet se convertit
/// à deux endroits, l'écart revient : il n'y a plus qu'ici.
///
/// Il est dans `DiskCore` et non dans l'interface parce que la couche modèle
/// écrit elle aussi des tailles — `PartitionGeometry.capacityDescription`,
/// l'étiquette d'un disque fabriqué —, et que `DiskCore` est le seul module
/// que les deux voient. `FrenchFormat`, côté interface, s'y ramène.
public enum FrenchUnits {

    private static let thin = "\u{202F}"
    private static let nbsp = "\u{00A0}"

    /// Le mégaoctet **affiché** : **2²⁰ octets**, celui du système de
    /// fichiers, comme CHKDSK l'écrivait.
    ///
    /// Ce n'est pas celui de l'étiquette : `ProfileSpec.sizeBytes` vaut
    /// `sizeMB × 1 000 000`, le mégaoctet décimal des fiches (« secteurs
    /// garantis »). Un disque étiqueté « 210 Mo » en montre donc 200 une fois
    /// formaté, comme il le faisait ; c'est l'étiquette que la galerie
    /// affiche à côté.
    public static let bytesPerMegabyte: Double = 1_048_576

    public static func integer(_ value: Int) -> String {
        let digits = String(abs(value))
        var groups: [Substring] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(digits[start..<end], at: 0)
            end = start
        }
        return (value < 0 ? "−" : "") + groups.joined(separator: thin)
    }

    public static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// Une taille en Mo, en Go au-delà d'un gigaoctet, avec une décimale sous
    /// dix mégaoctets ; en Ko sous un mégaoctet si on le demande.
    public static func megabytes(_ bytes: UInt64, smallInKilobytes: Bool = false) -> String {
        if smallInKilobytes && bytes < UInt64(bytesPerMegabyte) {
            return integer(Int(bytes / 1_024)) + nbsp + "Ko"
        }
        let mb = Double(bytes) / bytesPerMegabyte
        if mb >= 1_024 { return decimal(mb / 1_024, digits: 1) + nbsp + "Go" }
        if mb < 10 { return decimal(mb, digits: 1) + nbsp + "Mo" }
        return integer(Int(mb.rounded())) + nbsp + "Mo"
    }

    /// Un débit en Mo/s, **décimal** celui-là.
    ///
    /// C'est la seule exception, et elle est voulue : un débit ne se compare
    /// pas à une capacité mais aux fiches constructeur des manuels — « 7,0
    /// Mo/s externe » du TULARC, les 72 Mo/s soutenus du 7200.11 —, qui
    /// comptent toutes en 10⁶. Le lire en 2²⁰ ferait mentir la comparaison de
    /// 5 % au moment précis où elle sert à quelque chose. La fonction existe
    /// pour que cette exception soit écrite une fois, ici, au lieu d'être
    /// devinée à chaque division.
    public static func megabytesPerSecond(_ bytesPerSecond: Double) -> Double {
        bytesPerSecond / 1_000_000
    }
}
