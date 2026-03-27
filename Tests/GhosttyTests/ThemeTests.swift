import Testing
@testable import Ghostty

@Suite("GhosttyTheme")
struct ThemeTests {

    // MARK: - Color

    @Test("Color from hex with hash prefix")
    func colorFromHexWithHash() {
        let color = GhosttyTheme.Color(hex: "#1a1b26")
        #expect(color != nil)
        #expect(color?.r == 0x1a)
        #expect(color?.g == 0x1b)
        #expect(color?.b == 0x26)
    }

    @Test("Color from hex without hash prefix")
    func colorFromHexNoHash() {
        let color = GhosttyTheme.Color(hex: "ff00aa")
        #expect(color != nil)
        #expect(color?.r == 0xFF)
        #expect(color?.g == 0x00)
        #expect(color?.b == 0xAA)
    }

    @Test("Color from invalid hex returns nil")
    func colorFromInvalidHex() {
        #expect(GhosttyTheme.Color(hex: "xyz") == nil)
        #expect(GhosttyTheme.Color(hex: "#12") == nil)
        #expect(GhosttyTheme.Color(hex: "") == nil)
    }

    @Test("Color hexString roundtrips")
    func colorHexRoundtrip() {
        let color = GhosttyTheme.Color(r: 0x1a, g: 0x1b, b: 0x26)
        #expect(color.hexString == "1a1b26")
        #expect(GhosttyTheme.Color(hex: color.hexString) == color)
    }

    // MARK: - Parsing

    @Test("Parse a complete theme")
    func parseCompleteTheme() throws {
        let text = """
        palette = 0=#45475a
        palette = 1=#f38ba8
        palette = 15=#bac2de
        background = #1e1e2e
        foreground = #cdd6f4
        cursor-color = #f5e0dc
        cursor-text = #1e1e2e
        selection-background = #585b70
        selection-foreground = #cdd6f4
        """

        let theme = try GhosttyTheme(parsing: text)
        #expect(theme.foreground == GhosttyTheme.Color(hex: "cdd6f4"))
        #expect(theme.background == GhosttyTheme.Color(hex: "1e1e2e"))
        #expect(theme.cursorColor == GhosttyTheme.Color(hex: "f5e0dc"))
        #expect(theme.cursorText == GhosttyTheme.Color(hex: "1e1e2e"))
        #expect(theme.selectionForeground == GhosttyTheme.Color(hex: "cdd6f4"))
        #expect(theme.selectionBackground == GhosttyTheme.Color(hex: "585b70"))
        #expect(theme.palette[0] == GhosttyTheme.Color(hex: "45475a"))
        #expect(theme.palette[1] == GhosttyTheme.Color(hex: "f38ba8"))
        #expect(theme.palette[15] == GhosttyTheme.Color(hex: "bac2de"))
        #expect(theme.palette.count == 3)
    }

    @Test("Comments and blank lines are ignored")
    func parseIgnoresComments() throws {
        let text = """
        # This is a comment
        foreground = #ffffff

        # Another comment
        background = #000000
        """

        let theme = try GhosttyTheme(parsing: text)
        #expect(theme.foreground == GhosttyTheme.Color(r: 255, g: 255, b: 255))
        #expect(theme.background == GhosttyTheme.Color(r: 0, g: 0, b: 0))
    }

    @Test("Unknown keys are silently ignored")
    func parseIgnoresUnknownKeys() throws {
        let text = """
        foreground = #ffffff
        font-size = 14
        some-unknown-key = whatever
        """

        let theme = try GhosttyTheme(parsing: text)
        #expect(theme.foreground == GhosttyTheme.Color(r: 255, g: 255, b: 255))
    }

    @Test("Invalid color hex throws ParseError")
    func parseInvalidColorThrows() {
        let text = "foreground = not-a-color"
        #expect(throws: GhosttyTheme.ParseError.self) {
            try GhosttyTheme(parsing: text)
        }
    }

    @Test("Invalid palette format throws ParseError")
    func parseInvalidPaletteThrows() {
        let text = "palette = invalid"
        #expect(throws: GhosttyTheme.ParseError.self) {
            try GhosttyTheme(parsing: text)
        }
    }

    @Test("Palette index out of range throws ParseError")
    func parsePaletteOutOfRange() {
        let text = "palette = 256=#ffffff"
        #expect(throws: GhosttyTheme.ParseError.self) {
            try GhosttyTheme(parsing: text)
        }
    }

    // MARK: - Serialization

    @Test("toConfigString roundtrips through parsing")
    func serializationRoundtrip() throws {
        let original = """
        palette = 0=#45475a
        palette = 1=#f38ba8
        background = #1e1e2e
        foreground = #cdd6f4
        cursor-color = #f5e0dc
        cursor-text = #1e1e2e
        selection-background = #585b70
        selection-foreground = #cdd6f4
        """

        let theme1 = try GhosttyTheme(parsing: original)
        let serialized = theme1.toConfigString()
        let theme2 = try GhosttyTheme(parsing: serialized)

        #expect(theme1 == theme2)
    }

    // MARK: - Bundled Themes

    @Test("Bundled theme names are available")
    func bundledThemeNames() {
        let names = GhosttyTheme.bundledThemeNames()
        #expect(names.count > 400)
        #expect(names.contains("TokyoNight"))
        #expect(names.contains("Catppuccin Mocha"))
    }

    @Test("Load a bundled theme by name")
    func loadBundledTheme() {
        let theme = GhosttyTheme.bundled(named: "TokyoNight")
        #expect(theme != nil)
        #expect(theme?.foreground != nil)
        #expect(theme?.background != nil)
        #expect(theme?.palette.count == 16)
    }

    @Test("Loading nonexistent bundled theme returns nil")
    func loadNonexistentTheme() {
        let theme = GhosttyTheme.bundled(named: "ThisThemeDoesNotExist12345")
        #expect(theme == nil)
    }
}
