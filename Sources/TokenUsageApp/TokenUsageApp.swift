import SwiftUI

@main
struct TokenUsageApplication: App {
    @StateObject private var viewModel = DashboardViewModel()

    var body: some Scene {
        WindowGroup("Codex Token Usage") {
            DashboardView(viewModel: viewModel)
                .frame(minWidth: 1180, minHeight: 700)
        }
        .defaultSize(width: 1480, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新报告") {
                    viewModel.reload()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}
