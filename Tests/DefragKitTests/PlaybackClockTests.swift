import Testing
import Foundation
@testable import DefragKit

/// L'horloge de l'écoute : le temps de passe reste continu quand l'allure change.
@Suite("Horloge de l'écoute")
struct PlaybackClockTests {

    @Test("À ×1, l'horloge est celle d'avant le variateur",
          arguments: [0.0, 0.7, 12.5, 2_652.0])
    func normalSpeedIsIdentity(elapsed: Double) {
        let clock = PlaybackClock(offset: 30, speed: 1)
        #expect(clock.passTime(elapsed: elapsed) == 30 + elapsed)
        // Au bit près ce que le moteur calculait : `cue.time - timelineOffset`.
        #expect(clock.playerOffset(of: 30 + elapsed) == (30 + elapsed) - 30)
        #expect(clock.passSpan(real: 0.05) == 0.05)
    }

    @Test("Un repère retombe sur son instant, à toute allure", arguments: PlaybackSpeed.allCases)
    func roundTrip(speed: PlaybackSpeed) {
        let clock = PlaybackClock(offset: 41.25, speed: speed.rawValue)
        for elapsed in [0.0, 0.016, 1.0, 93.5] {
            let time = clock.passTime(elapsed: elapsed)
            #expect(abs(clock.playerOffset(of: time) - elapsed) < 1e-9)
        }
    }

    @Test("À ×4, une seconde d'écoute couvre quatre secondes de passe")
    func fasterCoversMore() {
        let clock = PlaybackClock(offset: 10, speed: 4)
        #expect(clock.passTime(elapsed: 1) == 14)
        // Deux seeks à 200 ms de passe tombent à 50 ms l'un de l'autre.
        #expect(abs(clock.playerOffset(of: 10.2) - 0.05) < 1e-12)
        #expect(clock.passSpan(real: 0.70) == 2.8)
    }

    @Test("Le bouton fait le tour des allures, et VoiceOver monte ou descend")
    func cycling() {
        var speed = PlaybackSpeed.normal
        var seen: [PlaybackSpeed] = []
        for _ in PlaybackSpeed.allCases { speed = speed.next; seen.append(speed) }
        #expect(seen == [.double, .quadruple, .octuple, .half, .normal])
        #expect(PlaybackSpeed.octuple.faster == nil)
        #expect(PlaybackSpeed.half.slower == nil)
        #expect(PlaybackSpeed.normal.slower == .half)
    }

    @Test("Se ré-ancrer ne fait ni sauter ni reculer le temps écouté")
    func reanchoringIsContinuous() {
        var clock = PlaybackClock()
        var listened = 0.0
        // Trois secondes réelles à chaque allure, le player repartant de zéro.
        for speed in [PlaybackSpeed.normal, .octuple, .half, .double] {
            clock.offset = listened
            clock.speed = speed.rawValue
            #expect(clock.passTime(elapsed: 0) == listened)
            listened = clock.passTime(elapsed: 3)
        }
        let expected: Double = 34.5   // 3 s × (1 + 8 + 0,5 + 2)
        #expect(listened == expected)
    }
}
