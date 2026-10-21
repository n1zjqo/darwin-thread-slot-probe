import SwiftUI

@main
@MainActor
struct Switch2IOSApp: App {
    @StateObject private var session = SessionModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(session)
                .onChange(of: phase) { session.transition(to: $0) }
        }
    }
}
