import SwiftUI

@main
struct TRXVanityApp: App {
    @StateObject private var viewModel: VanityViewModel

    init() {
        _viewModel = StateObject(
            wrappedValue: VanityViewModel(searcher: NativeVanitySearcher())
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 940, minHeight: 700)
                .onDisappear {
                    viewModel.stopIfRunning()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("生成") {
                Button(viewModel.isRunning ? "停止生成" : "开始生成") {
                    if viewModel.isRunning {
                        viewModel.stop()
                    } else {
                        viewModel.start()
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }
}
