import SwiftUI

@main
struct WinchesterApp: App {
    init() { WinchesterEngine.configureSession() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
