import AppKit
import Combine
import GhosttyKit
import SwiftUI

/// SwiftUI wrapper for `GhosttyTerminalSurface`.
/// Embeds a fully interactive terminal in a SwiftUI view hierarchy.
public struct GhosttyTerminalView: NSViewRepresentable {
    public typealias NSViewType = GhosttyTerminalSurface

    let appManager: GhosttyAppManager
    let command: String?
    let workingDirectory: String?
    let environmentVariables: [String: String]

    /// Binding that receives the surface instance after creation.
    @Binding var surfaceRef: GhosttyTerminalSurface?

    public init(
        appManager: GhosttyAppManager,
        command: String? = nil,
        workingDirectory: String? = nil,
        environmentVariables: [String: String] = [:],
        surfaceRef: Binding<GhosttyTerminalSurface?> = .constant(nil)
    ) {
        self.appManager = appManager
        self.command = command
        self.workingDirectory = workingDirectory
        self.environmentVariables = environmentVariables
        self._surfaceRef = surfaceRef
    }

    public func makeNSView(context: Context) -> GhosttyTerminalSurface {
        let surface = GhosttyTerminalSurface(
            appManager: appManager,
            command: command,
            workingDirectory: workingDirectory,
            environmentVariables: environmentVariables
        )
        DispatchQueue.main.async {
            self.surfaceRef = surface
        }
        return surface
    }

    public func updateNSView(_ nsView: GhosttyTerminalSurface, context: Context) {
        // Nothing to update — the terminal surface manages its own state
    }
}
