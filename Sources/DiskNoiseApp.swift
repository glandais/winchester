import SwiftUI

@main
struct DiskNoiseApp: App {
    init() { DiskNoiseEngine.configureSession() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
