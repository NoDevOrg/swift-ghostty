import SwiftUI
import Ghostty

struct ContentView: View {
    @ObservedObject private var appManager = GhosttyAppManager.shared
    @State private var selectedTheme: String?
    @State private var surfaceRef: GhosttyTerminalSurface?

    private var themeNames: [String] {
        GhosttyTheme.bundledThemeNames()
    }

    var body: some View {
        Group {
            switch appManager.readyState {
            case .loading:
                ProgressView("Initializing terminal...")
            case .error:
                Text("Failed to initialize Ghostty")
                    .foregroundStyle(.red)
            case .ready:
                HSplitView {
                    themeList
                        .frame(minWidth: 200, maxWidth: 250)

                    GhosttyTerminalView(
                        appManager: appManager,
                        surfaceRef: $surfaceRef
                    )
                }
            }
        }
        .frame(minWidth: 800, minHeight: 480)
    }

    private var themeList: some View {
        VStack(spacing: 0) {
            List(themeNames, id: \.self, selection: $selectedTheme) { name in
                Text(name)
                    .font(.system(.body, design: .monospaced))
            }
            .onChange(of: selectedTheme) { _, newTheme in
                applyTheme(named: newTheme)
            }

            if let selectedTheme {
                themePreview(name: selectedTheme)
                    .padding(8)
            }
        }
    }

    private func themePreview(name: String) -> some View {
        Group {
            if let theme = GhosttyTheme.bundled(named: name) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        if let bg = theme.background {
                            colorSwatch(bg, label: "bg")
                        }
                        if let fg = theme.foreground {
                            colorSwatch(fg, label: "fg")
                        }
                        if let cursor = theme.cursorColor {
                            colorSwatch(cursor, label: "cur")
                        }
                    }

                    // Show ANSI palette colors 0-15
                    let indices = (0...15).filter { theme.palette[$0] != nil }
                    if !indices.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(16), spacing: 2), count: 8), spacing: 2) {
                            ForEach(indices, id: \.self) { i in
                                if let color = theme.palette[i] {
                                    Rectangle()
                                        .fill(Color(
                                            red: Double(color.r) / 255,
                                            green: Double(color.g) / 255,
                                            blue: Double(color.b) / 255
                                        ))
                                        .frame(width: 16, height: 16)
                                        .cornerRadius(2)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func colorSwatch(_ color: GhosttyTheme.Color, label: String) -> some View {
        VStack(spacing: 2) {
            Rectangle()
                .fill(Color(
                    red: Double(color.r) / 255,
                    green: Double(color.g) / 255,
                    blue: Double(color.b) / 255
                ))
                .frame(width: 32, height: 20)
                .cornerRadius(3)
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func applyTheme(named name: String?) {
        guard let name, let surface = surfaceRef else { return }
        guard let theme = GhosttyTheme.bundled(named: name) else { return }
        theme.apply(to: surface)
    }
}
