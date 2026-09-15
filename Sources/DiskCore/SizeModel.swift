import Foundation

/// Distributions de tailles, **par catégorie**.
///
/// Une log-normale unique pour tout le disque donnerait un histogramme lisse et
/// faux. La vraie distribution est multimodale : un pic de fichiers source à
/// 3 Ko, un autre de DLL autour de 80 Ko, un troisième de MP3 très resserré
/// autour de 3,5 Mo parce qu'un MP3 n'est rien d'autre qu'un débit multiplié
/// par une durée. Ce sont ces pics, et le mélange que chaque profil en fait,
/// qui donnent sa signature à un volume.
public enum SizeModel {

    /// Une distribution de tailles : log-normale continue, ou choix discret.
    public enum Distribution: Sendable {
        case logNormal(median: ByteCount, sigma: Double)
        /// Tailles possibles et leurs poids. Les assets de jeu et les volumes
        /// d'archives ne sont pas continus : un `.pak` fait 40, 200 ou 600 Mo,
        /// et une partie de RAR fait exactement 1,44, 5 ou 15 Mo.
        case discrete(values: [ByteCount], weights: [Double])

        public func sample(_ rng: inout SeededGenerator) -> ByteCount {
            switch self {
            case let .logNormal(median, sigma):
                return ByteCount(max(1, rng.logNormal(median: Double(median), sigma: sigma)))
            case let .discrete(values, weights):
                return values[min(rng.pick(weights: weights), values.count - 1)]
            }
        }
    }

    // MARK: - Les distributions du modèle

    public static let sourceFile = Distribution.logNormal(median: 3_000, sigma: 1.2)
    public static let header = Distribution.logNormal(median: 6_000, sigma: 1.0)
    public static let library = Distribution.logNormal(median: 80_000, sigma: 1.6)

    /// Le `.obj` d'un compilateur des années 90 : plus gros que la source dont
    /// il vient, et beaucoup plus régulier.
    public static let objectFile = Distribution.logNormal(median: 16_000, sigma: 0.9)

    /// Word 6 à 97. Le *fast save* n'est pas dans la taille, il est dans le
    /// motif d'écriture — c'est lui qui fait grossir le document au fil des
    /// enregistrements.
    public static let wordDocument = Distribution.logNormal(median: 25_000, sigma: 0.9)
    public static let spreadsheet = Distribution.logNormal(median: 40_000, sigma: 1.0)

    /// MP3 à 128 kbit/s : débit × durée, donc quasi déterministe. Trois minutes
    /// et demie font 3,4 Mo, et la dispersion ne vient que de la durée des
    /// morceaux.
    public static let mp3 = Distribution.logNormal(median: 3_500_000, sigma: 0.35)

    /// Photo d'un appareil de 3 mégapixels, 2003.
    public static let jpeg2003 = Distribution.logNormal(median: 900_000, sigma: 0.5)
    /// Photo d'un reflex de 2007.
    public static let jpeg2007 = Distribution.logNormal(median: 2_600_000, sigma: 0.5)

    /// Un film en DivX tient sur un CD, ou sur deux.
    public static let divx = Distribution.discrete(values: [700_000_000, 1_400_000_000],
                                                   weights: [3, 1])
    /// Vidéo de caméscope, 2007.
    public static let homeVideo = Distribution.logNormal(median: 1_200_000_000, sigma: 0.6)

    /// Le cache d'un navigateur : des milliers de fichiers minuscules, avec
    /// quelques images plus grosses.
    public static let browserCache = Distribution.logNormal(median: 6_000, sigma: 1.1)

    /// Assets de jeu : discrets, par nature. Un moteur découpe ses ressources
    /// en gros paquets, pas selon une loi continue.
    public static let gameAsset = Distribution.discrete(
        values: [40_000_000, 120_000_000, 300_000_000, 600_000_000],
        weights: [4, 3, 2, 1])

    /// Sauvegarde de partie.
    public static let gameSave = Distribution.logNormal(median: 400_000, sigma: 0.8)

    /// Archive en parties de taille fixe : disquette, CD par tranches, ou les
    /// 15 Mo des groupes de discussion. L'alternance de trous parfaitement
    /// réguliers qu'elle laisse est reconnaissable au premier coup d'œil.
    public static let archivePart = Distribution.discrete(
        values: [1_440_000, 5_000_000, 15_000_000],
        weights: [1, 3, 4])

    public static func document(forYear year: Int) -> Distribution {
        year <= 1996 ? wordDocument : .logNormal(median: 38_000, sigma: 1.0)
    }

    public static func photo(forYear year: Int) -> Distribution {
        year >= 2007 ? jpeg2007 : jpeg2003
    }
}
