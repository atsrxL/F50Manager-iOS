import SwiftUI

@main
@MainActor
struct F50ManagerApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: model.setForeground(true)
                    case .background: model.setForeground(false)
                    case .inactive: break // Permission / pairing dialogs must not abort the handshake.
                    @unknown default: model.setForeground(false)
                    }
                }
        }
    }
}
