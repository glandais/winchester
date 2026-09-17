import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Le temps passé dans chaque phase survit à l'oubli des repères.
@Suite("Temps par phase")
struct PhaseTimeTests {

    private static func pass() -> LivePass {
        let drive = DriveCatalog.fireball1996
        let spindle = SpindleTimeline(spinUpAt: 0, duration: 1.0, rpm: drive.geometry.rpm,
                                      spinDownAt: nil, spinDownDuration: 4)
        let phases = ["a", "b", "c"].map { PhaseDescriptor(id: $0, label: $0, detail: "") }
        return LivePass(session: nil, geometry: drive.geometry, seekModel: drive.seekModel,
                        spindle: spindle, phases: phases)
    }

    @Test("Une phase reprise cumule ses durées, dans l'ordre d'apparition")
    func alternatingPhasesAccumulate() {
        let live = Self.pass()
        var batch = PassBatch()
        // 0 → 10 : a ; 10 → 12 : b ; 12 → 20 : a ; 20 → : c
        batch.phases = [PhaseMark(index: 0, time: 0), PhaseMark(index: 1, time: 10),
                        PhaseMark(index: 0, time: 12), PhaseMark(index: 2, time: 20)]
        live.absorb(batch)

        // Par petits pas, comme les images d'un écran.
        var t = 0.0
        while t < 25 { t += 0.25; live.advance(to: t) }

        #expect(live.phaseTimes.map(\.index) == [0, 1, 2])
        #expect(abs(live.phaseTimes[0].seconds - 18) < 1e-9)
        #expect(abs(live.phaseTimes[1].seconds - 2) < 1e-9)
        #expect(abs(live.phaseTimes[2].seconds - 5) < 1e-9)
    }

    @Test("Le cumul tient au-delà de la fenêtre où les repères sont oubliés")
    func survivesForgetting() {
        let live = Self.pass()
        var batch = PassBatch()
        batch.phases = [PhaseMark(index: 0, time: 0), PhaseMark(index: 1, time: 30),
                        PhaseMark(index: 2, time: 200)]
        live.absorb(batch)

        var t = 0.0
        while t < 260 { t += 0.5; live.advance(to: t) }

        #expect(live.phaseMarks.count < 3)
        #expect(live.phaseTimes.map(\.index) == [0, 1, 2])
        #expect(abs(live.phaseTimes[0].seconds - 30) < 1e-9)
        #expect(abs(live.phaseTimes[1].seconds - 170) < 1e-9)
        #expect(abs(live.phaseTimes[2].seconds - 60) < 1e-9)
    }
}
