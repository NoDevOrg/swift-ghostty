import Foundation
import GhosttyKit

/// A terminal color theme containing foreground, background, cursor,
/// selection, and palette colors.
///
/// Themes can be loaded from Ghostty theme config files (simple `key = value` format)
/// and applied to terminal surfaces or the entire app.
public struct GhosttyTheme: Sendable, Equatable {

    /// An RGB color.
    public struct Color: Sendable, Equatable, Hashable {
        public let r: UInt8
        public let g: UInt8
        public let b: UInt8

        public init(r: UInt8, g: UInt8, b: UInt8) {
            self.r = r
            self.g = g
            self.b = b
        }

        /// Initialize from a hex string like `"#1a1b26"` or `"1a1b26"`.
        public init?(hex: String) {
            var hex = hex
            if hex.hasPrefix("#") { hex.removeFirst() }
            guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
            self.r = UInt8((value >> 16) & 0xFF)
            self.g = UInt8((value >> 8) & 0xFF)
            self.b = UInt8(value & 0xFF)
        }

        /// The color as a hex string without the `#` prefix, e.g. `"1a1b26"`.
        public var hexString: String {
            String(format: "%02x%02x%02x", r, g, b)
        }
    }

    public var foreground: Color?
    public var background: Color?
    public var cursorColor: Color?
    public var cursorText: Color?
    public var selectionForeground: Color?
    public var selectionBackground: Color?

    /// Palette colors keyed by index (0-255). Only indices present in the
    /// theme file are included; missing indices are left to the terminal default.
    public var palette: [Int: Color]

    public init() {
        self.palette = [:]
    }

    // MARK: - Parsing

    public enum ParseError: Error, Sendable {
        case invalidFormat(line: Int, content: String)
        case fileNotFound(String)
    }

    /// Load a theme from a file on disk.
    public init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        try self.init(parsing: text)
    }

    /// Parse a theme from Ghostty config text.
    ///
    /// The format is `key = value` per line. Supported keys:
    /// `foreground`, `background`, `cursor-color`, `cursor-text`,
    /// `selection-foreground`, `selection-background`, and
    /// `palette` (as `palette = N=#RRGGBB`).
    public init(parsing configText: String) throws {
        self.init()

        for (lineNumber, rawLine) in configText.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            guard let eqIndex = line.firstIndex(of: "=") else { continue }

            let key = line[line.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "foreground":
                guard let color = Color(hex: value) else {
                    throw ParseError.invalidFormat(line: lineNumber + 1, content: rawLine)
                }
                self.foreground = color
            case "background":
                guard let color = Color(hex: value) else {
                    throw ParseError.invalidFormat(line: lineNumber + 1, content: rawLine)
                }
                self.background = color
            case "cursor-color":
                guard let color = Color(hex: value) else {
                    throw ParseError.invalidFormat(line: lineNumber + 1, content: rawLine)
                }
                self.cursorColor = color
            case "cursor-text":
                guard let color = Color(hex: value) else {
                    throw ParseError.invalidFormat(line: lineNumber + 1, content: rawLine)
                }
                self.cursorText = color
            case "selection-foreground":
                guard let color = Color(hex: value) else {
                    throw ParseError.invalidFormat(line: lineNumber + 1, content: rawLine)
                }
                self.selectionForeground = color
            case "selection-background":
                guard let color = Color(hex: value) else {
                    throw ParseError.invalidFormat(line: lineNumber + 1, content: rawLine)
                }
                self.selectionBackground = color
            case "palette":
                // Format: "N=#RRGGBB"
                guard let eqIdx = value.firstIndex(of: "=") else {
                    throw ParseError.invalidFormat(line: lineNumber + 1, content: rawLine)
                }
                let indexStr = value[value.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)
                let colorStr = value[value.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
                guard let index = Int(indexStr), (0...255).contains(index),
                      let color = Color(hex: colorStr) else {
                    throw ParseError.invalidFormat(line: lineNumber + 1, content: rawLine)
                }
                self.palette[index] = color
            default:
                // Ignore unknown keys — themes may contain keys we don't handle
                break
            }
        }
    }

    // MARK: - Serialization

    /// Serialize the theme back to Ghostty config format.
    public func toConfigString() -> String {
        var lines: [String] = []

        for index in palette.keys.sorted() {
            if let color = palette[index] {
                lines.append("palette = \(index)=#\(color.hexString)")
            }
        }
        if let background { lines.append("background = #\(background.hexString)") }
        if let foreground { lines.append("foreground = #\(foreground.hexString)") }
        if let cursorColor { lines.append("cursor-color = #\(cursorColor.hexString)") }
        if let cursorText { lines.append("cursor-text = #\(cursorText.hexString)") }
        if let selectionBackground { lines.append("selection-background = #\(selectionBackground.hexString)") }
        if let selectionForeground { lines.append("selection-foreground = #\(selectionForeground.hexString)") }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Applying

    /// Apply this theme to a single terminal surface.
    ///
    /// This creates a temporary config file, loads it via the Ghostty config API,
    /// and updates the surface.
    public func apply(to surface: GhosttyTerminalSurface) {
        guard let surfaceHandle = surface.surface else { return }
        guard let config = loadAsGhosttyConfig() else { return }
        defer { ghostty_config_free(config) }
        ghostty_surface_update_config(surfaceHandle, config)
    }

    /// Apply this theme to all terminal surfaces managed by the app.
    public func apply(to appManager: GhosttyAppManager) {
        guard let app = appManager.app else { return }
        guard let config = loadAsGhosttyConfig() else { return }
        defer { ghostty_config_free(config) }
        ghostty_app_update_config(app, config)
    }

    /// Create a `ghostty_config_t` from this theme by writing to a temp file
    /// and loading it through the Ghostty config API.
    private func loadAsGhosttyConfig() -> ghostty_config_t? {
        let configString = toConfigString()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-theme-\(UUID().uuidString).conf")

        guard let _ = try? configString.write(to: tempURL, atomically: true, encoding: .utf8) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let config = ghostty_config_new() else { return nil }
        tempURL.path.withCString { path in
            ghostty_config_load_file(config, path)
        }
        ghostty_config_finalize(config)
        return config
    }

    // MARK: - Theme Discovery

    /// List all bundled Ghostty theme names.
    ///
    /// Themes are bundled as SPM resources in the package. Falls back to
    /// standard Ghostty install locations if the resource bundle is unavailable.
    public static func bundledThemeNames() -> [String] {
        guard let url = bundledThemesDirectory() else { return [] }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        ) else { return [] }

        return contents
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// Load a bundled theme by name.
    public static func bundled(named name: String) -> GhosttyTheme? {
        guard let dir = bundledThemesDirectory() else { return nil }
        let url = dir.appendingPathComponent(name)
        return try? GhosttyTheme(contentsOf: url)
    }

    /// Returns the URL of the bundled themes directory, if available.
    public static func bundledThemesDirectory() -> URL? {
        let candidates: [URL?] = [
            // SPM resource bundle (primary)
            Bundle.module.url(forResource: "Themes", withExtension: nil),
            // Ghostty.app standard location
            URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes"),
            // User-local ghostty themes
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/ghostty/themes"),
        ]

        for case let candidate? in candidates {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        return nil
    }
}
