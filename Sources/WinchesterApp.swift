import SwiftUI

@main
struct WinchesterApp: App {
    /// Écoute les transactions dès le lancement : un pourboire approuvé plus
    /// tard (Ask to Buy) ou interrompu doit être fini, écran ouvert ou non.
    @State private var tipJar: TipJar

    init() {
        WinchesterEngine.configureSession()
        let tipJar = TipJar()
        tipJar.start()
        _tipJar = State(initialValue: tipJar)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(tipJar)
                .preferredColorScheme(.dark)
        }
    }
}
