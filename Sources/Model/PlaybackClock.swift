import Foundation

/// L'allure de l'écoute. Le modèle n'en sait rien : la passe simulée est la
/// même à toute allure, seule l'horloge qui la lit va plus ou moins vite.
enum PlaybackSpeed: Double, CaseIterable, Hashable, Sendable {
    case half = 0.5
    case normal = 1
    case double = 2
    case quadruple = 4
    case octuple = 8

    /// L'allure plus rapide, s'il y en a une.
    var faster: PlaybackSpeed? {
        Self.allCases.first { $0.rawValue > rawValue }
    }

    /// L'allure plus lente, s'il y en a une.
    var slower: PlaybackSpeed? {
        Self.allCases.last { $0.rawValue < rawValue }
    }

    /// Celle qu'un tap sur le bouton choisit : on accélère, et ×8 ramène à la
    /// plus lente, d'où ×1 n'est qu'à un tap.
    var next: PlaybackSpeed {
        faster ?? Self.allCases[0]
    }
}

/// La correspondance entre l'horloge du player et le temps de passe.
///
/// `offset` est le temps de passe à l'instant 0 du player. Changer d'allure,
/// c'est se ré-ancrer : le player repart de zéro, `offset` prend le temps de
/// passe atteint, et le temps écouté reste continu.
struct PlaybackClock: Equatable, Sendable {
    var offset: Double = 0
    var speed: Double = 1

    /// Temps de passe atteint après `elapsed` secondes de player.
    func passTime(elapsed: Double) -> Double {
        offset + elapsed * speed
    }

    /// Instant du player où tombe le temps de passe `time`.
    func playerOffset(of time: Double) -> Double {
        (time - offset) / speed
    }

    /// Ce que `real` secondes d'écoute couvrent de temps de passe : les marges
    /// du moteur — avance de programmation, tolérance de retard — sont des
    /// durées réelles.
    func passSpan(real: Double) -> Double {
        real * speed
    }
}
