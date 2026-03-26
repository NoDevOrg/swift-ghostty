import SwiftUI
import Ghostty

struct ContentView: View {
    @ObservedObject private var appManager = GhosttyAppManager.shared

    var body: some View {
        Group {
            switch appManager.readyState {
            case .loading:
                ProgressView("Initializing terminal...")
            case .error:
                Text("Failed to initialize Ghostty")
                    .foregroundStyle(.red)
            case .ready:
                GhosttyTerminalView(appManager: appManager)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}
