import SwiftUI

@main
struct TRXVanityMonitorApp: App {
    @StateObject private var store = FleetStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 1080, minHeight: 720)
                .withoutFocusRing()
                .task { store.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1260, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("添加机器…") { store.isAddSheetPresented = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}
