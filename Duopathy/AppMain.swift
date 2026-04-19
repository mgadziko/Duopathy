import SwiftUI

@main
struct DuopathyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: ConversationViewModel())
                .frame(minWidth: 900, minHeight: 640)
        }
        .windowResizability(.contentSize)
    }
}
