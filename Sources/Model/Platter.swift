import Foundation
import DiskCore

/// Montée en régime du plateau.
///
/// Un moteur de broche est un système du premier ordre en vitesse, et
/// `SpindleVoice` l'intègre déjà échantillon par échantillon pour le son. On en
/// prend ici la solution analytique, avec la même constante de temps : ce qu'on
/// voit accélérer est exactement ce qu'on entend monter. L'intérêt d'une forme
/// fermée est qu'elle est une **fonction pure du temps** — un saut dans la
/// chronologie retombe sur la même image, ce qu'une vitesse intégrée pas à pas
/// ne permettrait pas.
struct SpindleTimeline: Sendable {

    /// Constante de temps d'une rampe. Partagée avec `SpindleVoice` : si les
    /// deux divergent, l'image cesse de coller au son.
    static func timeConstant(forRamp duration: Double) -> Double {
        max(duration, 0.2) / 3.2
    }

    private let start: Double
    private let tau: Double
    private let revolutionsPerSecond: Double

    init(spinUpAt: Double, duration: Double, rpm: Double) {
        self.start = spinUpAt
        self.tau = Self.timeConstant(forRamp: duration)
        self.revolutionsPerSecond = rpm / 60
    }

    /// Vitesse du plateau : 0 à l'arrêt, 1 au régime nominal.
    func speed(at time: Double) -> Double {
        let delta = time - start
        guard delta > 0 else { return 0 }
        return 1 - exp(-delta / tau)
    }

    /// Tours accomplis depuis la mise en rotation — l'**intégrale** de la
    /// vitesse, et non `ω·t`. Pendant la montée en régime le plateau accomplit
    /// exactement `τ` tours de moins qu'à plein régime, et c'est précisément ce
    /// décalage qui doit se voir.
    func revolutions(at time: Double) -> Double {
        let delta = time - start
        guard delta > 0 else { return 0 }
        return revolutionsPerSecond * (delta - tau * (1 - exp(-delta / tau)))
    }
}

/// Ce que fait la tête à un instant donné.
enum HeadActivity: Sendable {
    /// Bras parqué, moteur à l'arrêt ou disque pas encore sollicité.
    case parked
    case idle
    case seeking
    case reading
    case writing

    var isTransferring: Bool { self == .reading || self == .writing }
}

/// Tout ce que le plateau doit montrer à un instant donné, en une seule passe.
struct PlatterFrame: Sendable {

    let time: Double
    /// Position continue du bras, en cylindres — fractionnaire pendant un seek
    /// comme pendant un transfert séquentiel.
    let cylinder: Double
    /// Étendue balayée pendant l'image écoulée. Sur un train dense le bras fait
    /// plusieurs allers-retours par image : montrer l'enveloppe est plus honnête
    /// que d'en tirer un au sort, qui donnerait un grésillement.
    let sweep: ClosedRange<Double>
    let head: Int
    let activity: HeadActivity
    /// Tours apparents du plateau, ralenti compris.
    let turns: Double
    /// Vitesse de rotation, 0 à 1.
    let spin: Double
    /// Accès récents : une plage d'indices dans les échantillons, du plus ancien
    /// au plus récent. Une plage et non un tableau — la fenêtre est contiguë par
    /// construction, il n'y a donc rien à allouer soixante fois par seconde.
    let trail: Range<Int>
}

/// La trace de position de la tête, interrogée à la cadence de l'écran.
///
/// Toute la géométrie d'affichage du plateau se décide ici plutôt que dans la
/// vue, pour que le rendu hors-ligne puisse en vérifier les invariants.
struct PlatterTrack {

    /// Ralenti de la rotation affichée.
    ///
    /// Un plateau tourne soixante à cent vingt fois par seconde : à l'écran ce
    /// serait un aplat uniforme, et à soixante images par seconde les repères
    /// battraient en arrière — repliement stroboscopique, l'effet « roue de
    /// chariot » des westerns. Divisé par cent, un 7 200 tr/min fait 1,2 tour/s,
    /// soit 7,2° par image : le motif à trois branches se répète toutes les
    /// dix-sept images, huit fois plus lentement que la limite de Nyquist.
    ///
    /// Et **le rapport entre disques est conservé** : un 3 600 tr/min de 1993
    /// tourne deux fois moins vite à l'écran qu'un 7 200 de 2003, comme il sonne
    /// une octave plus bas.
    static let rotationSlowdown = 100.0

    /// Au-delà, on ne balaie plus l'image écoulée échantillon par échantillon.
    /// À mille requêtes par seconde une image en compte dix-sept ; cette borne
    /// n'est là que pour qu'une trace pathologique ne coûte pas une image.
    private static let sweepScanLimit = 512

    /// Nombre maximal de points de traînée dessinés.
    static let trailLimit = 240

    let geometry: DriveGeometry
    let seekModel: SeekModel
    let samples: [HeadSample]
    let spindle: SpindleTimeline

    /// Durée de la traînée : **un tour apparent**.
    ///
    /// C'est la seule valeur qui la garde lisible quel que soit le disque. Les
    /// points tournent avec le plateau ; au-delà d'un tour, les plus anciens
    /// repassent sur les plus récents et la trace devient illisible. Un tour
    /// apparent fait 0,83 s à 7 200 tr/min et 1,67 s à 3 600.
    var trailWindow: Double {
        let apparentTurnsPerSecond = geometry.rpm / 60 / Self.rotationSlowdown
        return min(max(1 / apparentTurnsPerSecond, 0.8), 2.0)
    }

    /// Tours apparents accomplis à cet instant.
    func turns(at time: Double) -> Double {
        spindle.revolutions(at: time) / Self.rotationSlowdown
    }

    /// Rayon normalisé de la piste où se trouvait un accès.
    func radius(ofCylinder cylinder: Double) -> Double {
        geometry.normalizedRadius(cylinder: cylinder)
    }

    // MARK: - Interrogation

    /// Dernier échantillon commencé à cet instant.
    private func index(at time: Double) -> Int? {
        guard let first = samples.first, first.time <= time else { return nil }
        var low = 0
        var high = samples.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if samples[mid].time <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func frame(at time: Double, frameDuration: Double = 1.0 / 60) -> PlatterFrame {
        let current = index(at: time)
        let (cylinder, activity) = position(at: time, index: current)
        let head = current.map { Int(samples[$0].head) } ?? 0

        return PlatterFrame(
            time: time,
            cylinder: cylinder,
            sweep: sweep(at: time, index: current, frameDuration: frameDuration, current: cylinder),
            head: head,
            activity: activity,
            turns: turns(at: time),
            spin: spindle.speed(at: time),
            trail: trail(endingAt: current, time: time))
    }

    /// Position du bras, fonction pure du temps.
    ///
    /// Trois cas, dans cet ordre : la tête transfère (le bras descend piste à
    /// piste vers l'intérieur), elle est en train de rejoindre le prochain
    /// accès, ou elle attend là où le dernier transfert l'a laissée.
    private func position(at time: Double, index: Int?) -> (Double, HeadActivity) {
        guard let index else {
            // Rien n'a encore été lu : le bras est à sa place de repos, et c'est
            // de là que partira le « clac » du premier accès.
            return (Double(geometry.parkCylinder), .parked)
        }

        let sample = samples[index]

        if time <= sample.endTime {
            let span = Double(sample.duration)
            let u = span > 0 ? (time - sample.time) / span : 0
            let cylinder = lerp(Double(sample.cylinder), Double(sample.endCylinder), u)
            return (cylinder, sample.isWrite ? .writing : .reading)
        }

        let resting = Double(sample.endCylinder)
        guard index + 1 < samples.count else { return (resting, .idle) }

        let next = samples[index + 1]
        let distance = abs(Int(next.cylinder) - Int(sample.endCylinder))
        guard distance > 0 else { return (resting, .idle) }

        // Le bras part au plus tard, pas au plus tôt : un disque ne déplace pas
        // sa tête pour l'immobiliser ensuite le temps que le secteur arrive. En
        // calant le départ sur la durée du seek, le bras reste immobile après un
        // repos puis s'élance — au lieu d'apparaître à destination avec jusqu'à
        // vingt-huit millisecondes de retard, seek et latence confondus.
        let travel = seekModel.duration(distance: distance)
        let departure = max(sample.endTime, next.time - travel)
        guard time >= departure, next.time > departure else { return (resting, .idle) }

        // `smoothstep` plutôt que les quatre phases du `SeekProfile` : le profil
        // donne des durées, pas une loi de position, et il faudrait intégrer
        // deux fois une vitesse trapézoïdale pour un événement qui dure de
        // 0,06 à 1,2 image. La cubique a déjà la bonne allure — vitesse nulle
        // aux deux bouts, maximale au milieu : c'est le profil speedup +
        // slowdown sans coast, celui des seeks courts, qui sont la majorité.
        let u = (time - departure) / (next.time - departure)
        let eased = u * u * (3 - 2 * u)
        return (lerp(resting, Double(next.cylinder), eased), .seeking)
    }

    /// Étendue balayée pendant l'image écoulée.
    private func sweep(at time: Double, index: Int?, frameDuration: Double,
                       current: Double) -> ClosedRange<Double> {
        guard let index else { return current...current }

        let from = time - frameDuration
        var low = current
        var high = current

        var i = index
        var scanned = 0
        while i >= 0 && scanned < Self.sweepScanLimit {
            let sample = samples[i]
            guard sample.endTime >= from else { break }
            low = min(low, Double(min(sample.cylinder, sample.endCylinder)))
            high = max(high, Double(max(sample.cylinder, sample.endCylinder)))
            i -= 1
            scanned += 1
        }

        // La position au début de l'image compte aussi : entre deux accès
        // éloignés, c'est le seek lui-même qui balaie, et aucun échantillon ne
        // le porte.
        let previous = position(at: from, index: self.index(at: from)).0
        return min(low, previous)...max(high, previous)
    }

    private func trail(endingAt index: Int?, time: Double) -> Range<Int> {
        guard let index else { return 0..<0 }
        let horizon = time - trailWindow
        // Plafond : un train dense produit un millier d'accès par tour apparent,
        // dont l'écran ne montrerait de toute façon qu'un amas. C'est une borne
        // de dessin, pas une fenêtre de temps — le fondu, lui, reste calculé sur
        // l'âge réel de chaque point.
        let floor = max(0, index + 1 - Self.trailLimit)
        var low = index
        while low > floor && samples[low - 1].time >= horizon { low -= 1 }
        return low..<(index + 1)
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * min(max(t, 0), 1)
    }
}
