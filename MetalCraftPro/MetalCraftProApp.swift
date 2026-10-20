import SwiftUI
import SwiftData

@main
struct MetalCraftProApp: App {
    @State private var store = LocalStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = store.container {
                    RootView().modelContainer(container)
                } else if let message = store.startupProblem {
                    ContentUnavailableView {
                        Label("Projekte sicher verwahrt", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Erneut versuchen") { store.open() }.buttonStyle(.glassProminent)
                    }
                } else {
                    ProgressView("Lokale Projekte öffnen …")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .environment(store)
            .tint(Theme.accent)
            .preferredColorScheme(.dark)
            .background(Theme.appBackground)
            .task { store.open() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { store.saveOnBackground() }
            }
        }
    }
}
