import SwiftUI
import DiskCore

/// Les chiffres de la passe, à l'instant écouté.
///
/// Pour l'instant les quatre tuiles qui existaient sous le plateau ; le reste
/// des instruments des maquettes attend son chantier (U6).
struct InstrumentsScreen: View {

    @ObservedObject var model: SimulationModel
    @StateObject private var clock: ClockRelay
    let isVisible: Bool

    init(model: SimulationModel, engine: DiskNoiseEngine, isVisible: Bool) {
        _model = ObservedObject(wrappedValue: model)
        _clock = StateObject(wrappedValue: ClockRelay(engine: engine))
        self.isVisible = isVisible
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ScreenTitle("Instruments", subtitle: model.label.title)
                    stats
                }
                .padding(16)
            }
        }
        .onAppear { clock.isRelaying = isVisible }
        .onChange(of: isVisible) { _, visible in clock.isRelaying = visible }
    }

    private var stats: some View {
        let requestRate = model.requestRate
        let throughput = model.throughputMBs
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            StatTile(label: "Requêtes / s", value: String(format: "%.0f", requestRate), unit: "IOPS")
            StatTile(label: "Débit", value: String(format: "%.1f", throughput), unit: "Mo/s")
            StatTile(label: "Seek moyen", value: "\(model.totals.averageSeekDistance)", unit: "cyl.")
            StatTile(label: "Seeks simulés", value: "\(model.totals.seeks)", unit: "jusqu'ici")
        }
    }
}
