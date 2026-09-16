import Foundation
import DiskCore

/// Une couleur de la carte des clusters, en composantes brutes.
///
/// Pas de `Color` SwiftUI ici : la palette doit être lisible par le rendu par
/// pixels, qui écrit des octets dans un buffer et ne sait rien des vues. C'est
/// aussi ce qui la rend testable — `DefragKit` compile sans SwiftUI, et une
/// couleur SwiftUI ne se relit pas, elle ne sait que se dessiner.
struct ClusterColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(white: Double) {
        self.init(red: white, green: white, blue: white)
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Le pixel opaque correspondant, en RGBA d'octets rangés du poids fort au
    /// poids faible — c'est-à-dire ce qu'un `CGImage` déclaré
    /// `premultipliedLast` + `byteOrder32Big` lit dans un mot de 32 bits.
    ///
    /// L'arrondi passe par 255,999 plutôt que par 255 : multiplier par 255 ne
    /// donne 255 que pour un composant exactement égal à 1, et tasse toutes les
    /// autres valeurs d'un demi-niveau vers le bas.
    var pixel: UInt32 {
        func byte(_ value: Double) -> UInt32 {
            UInt32(min(max(value, 0), 1) * 255.999)
        }
        return byte(red) << 24 | byte(green) << 16 | byte(blue) << 8 | 0xFF
    }
}

/// Couleurs de la carte des clusters.
///
/// Le défragmenteur d'époque n'en avait que deux ; ici chaque famille de
/// fichiers a la sienne, pour qu'on voie l'arborescence se reconstituer bloc
/// par bloc.
///
/// Elle vit dans le modèle et non dans `Theme` parce que deux consommateurs s'en
/// servent désormais : la légende, qui veut des `Color` SwiftUI, et le rendu de
/// la carte, qui veut des octets. La dupliquer aurait laissé les deux dériver
/// l'une de l'autre sans que rien ne le signale — un bloc d'une teinte dans la
/// carte, d'une autre dans sa propre légende. `Theme.categoryColor` n'est plus
/// qu'une conversion de celle-ci.
enum ClusterPalette {

    static func color(_ category: ClusterCategory) -> ClusterColor {
        switch category {
        case .free:        return ClusterColor(white: 0.16)
        case .system:      return ClusterColor(red: 0.36, green: 0.55, blue: 0.86)
        case .application: return ClusterColor(red: 0.62, green: 0.48, blue: 0.86)
        case .document:    return ClusterColor(red: 0.42, green: 0.76, blue: 0.52)
        case .archive:     return ClusterColor(red: 0.38, green: 0.60, blue: 0.62)
        case .churn:       return ClusterColor(red: 0.86, green: 0.58, blue: 0.30)
        case .swap:        return ClusterColor(red: 0.84, green: 0.36, blue: 0.40)
        case .reserved:    return ClusterColor(white: 0.72)
        }
    }

    /// Table catégorie → pixel, indexée par le brut de l'énumération.
    ///
    /// Le rendu la consulte une fois par cellule, donc jusqu'à vingt mille fois
    /// par image : un `switch` par cellule serait du gaspillage pur, la palette
    /// ne comptant que huit entrées fixes.
    private static let pixels: [UInt32] = ClusterCategory.allCases.map { color($0).pixel }

    /// Buffer de pixels d'une carte agrégée, une entrée par cellule.
    ///
    /// C'est tout ce que le rendu a besoin de fabriquer : le `CGImage` fait
    /// exactement une cellule par pixel, et c'est l'agrandissement sans
    /// interpolation qui lui donne sa taille à l'écran.
    ///
    /// Une catégorie inconnue retombe sur « libre » plutôt que de faire tomber
    /// l'application : la carte vient du rejeu, et un octet de travers doit se
    /// voir à l'écran, pas s'y terminer.
    static func pixelBuffer(_ cells: [UInt8]) -> [UInt32] {
        let table = pixels
        let free = table[Int(ClusterCategory.free.rawValue)]
        return cells.map { cell in
            let index = Int(cell)
            return index < table.count ? table[index] : free
        }
    }

    /// Plancher de la teinte proportionnelle.
    ///
    /// Un bloc de quatre mille clusters où huit viennent d'être écrits vaut
    /// deux millièmes : un mélange strictement linéaire le rendrait
    /// indistinguable du vide, et la carte perdrait précisément ce qu'elle est
    /// censée montrer. En dessous de ce plancher, toute présence se voit ; au
    /// dessus, la luminosité suit l'occupation.
    private static let tintFloor = 0.25

    /// Teinte d'un bloc : sa catégorie, éclaircie ou assombrie selon ce qu'il
    /// porte réellement.
    ///
    /// Le mélange se fait **vers la couleur « libre »** plutôt que vers le noir
    /// : le fond de la carte est déjà un gris à 0,16, et un bloc à moitié plein
    /// doit tomber entre ce gris-là et sa propre couleur, pas quelque part en
    /// dessous. Un bloc vide rend donc exactement la couleur libre, un bloc
    /// plein exactement celle de sa catégorie, et tout le reste est entre les
    /// deux.
    static func shadedColor(_ shade: ClusterShade) -> ClusterColor {
        let free = color(.free)
        guard let category = ClusterCategory(rawValue: shade.category),
              category != .free, shade.fill > 0 else { return free }
        let full = color(category)
        let t = tintFloor + (1 - tintFloor) * shade.fraction
        // `fill == 255` doit rendre la couleur pleine au bit près, sans quoi le
        // bloc plein et la légende qui le décrit ne seraient plus de la même
        // teinte.
        guard shade.fill < 255 else { return full }
        return ClusterColor(red: free.red + (full.red - free.red) * t,
                            green: free.green + (full.green - free.green) * t,
                            blue: free.blue + (full.blue - free.blue) * t)
    }

    /// Buffer de pixels d'une carte en teinte proportionnelle.
    ///
    /// Le mélange se paye ici et non par cellule dessinée : huit catégories et
    /// deux cent cinquante-six niveaux font deux mille entrées, mais la carte
    /// en compte vingt mille — la table serait rentable, elle n'est pas
    /// nécessaire. Fabriquer le buffer entier coûte 0,1 ms.
    static func pixelBuffer(_ shades: [ClusterShade]) -> [UInt32] {
        shades.map { shadedColor($0).pixel }
    }
}
