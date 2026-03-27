import Testing
@testable import Ghostty

@Suite("GhosttyInMemoryTerminal")
struct InMemoryTerminalTests {

    @Test("Creates terminal with default options")
    func createDefault() throws {
        let terminal = try GhosttyInMemoryTerminal()
        #expect(terminal.cols == 80)
        #expect(terminal.rows == 24)
    }

    @Test("Creates terminal with custom dimensions")
    func createCustom() throws {
        let terminal = try GhosttyInMemoryTerminal(
            options: .init(cols: 120, rows: 40, maxScrollback: 500)
        )
        #expect(terminal.cols == 120)
        #expect(terminal.rows == 40)
    }

    @Test("Writes plain text and reads it back")
    func writePlainText() throws {
        let terminal = try GhosttyInMemoryTerminal(options: .init(cols: 40, rows: 5))
        terminal.write("Hello, World!")
        let text = terminal.screenText()
        #expect(text.contains("Hello, World!"))
    }

    @Test("Cursor advances after writing text")
    func cursorAdvances() throws {
        let terminal = try GhosttyInMemoryTerminal()
        #expect(terminal.cursorPosition.x == 0)
        #expect(terminal.cursorPosition.y == 0)

        terminal.write("ABCDE")
        #expect(terminal.cursorPosition.x == 5)
        #expect(terminal.cursorPosition.y == 0)
    }

    @Test("Newline moves cursor down")
    func newlineMovesDown() throws {
        let terminal = try GhosttyInMemoryTerminal()
        terminal.write("line1\r\nline2")
        #expect(terminal.cursorPosition.y == 1)
        let text = terminal.screenText()
        #expect(text.contains("line1"))
        #expect(text.contains("line2"))
    }

    @Test("Title is set by OSC 2 sequence")
    func oscTitle() throws {
        let terminal = try GhosttyInMemoryTerminal()
        #expect(terminal.title == nil)

        // OSC 2 ; title ST
        terminal.write("\u{1b}]2;My Terminal\u{1b}\\")
        #expect(terminal.title == "My Terminal")
    }

    @Test("Bell callback fires on BEL character")
    func bellCallback() throws {
        let terminal = try GhosttyInMemoryTerminal()
        var bellCount = 0
        terminal.onBell = { bellCount += 1 }

        terminal.write("\u{07}")
        #expect(bellCount == 1)

        terminal.write("\u{07}\u{07}")
        #expect(bellCount == 3)
    }

    @Test("Title changed callback fires")
    func titleChangedCallback() throws {
        let terminal = try GhosttyInMemoryTerminal()
        var titleChanged = false
        terminal.onTitleChanged = { titleChanged = true }

        terminal.write("\u{1b}]2;New Title\u{1b}\\")
        #expect(titleChanged)
    }

    @Test("Reset clears screen content")
    func resetClearsScreen() throws {
        let terminal = try GhosttyInMemoryTerminal(options: .init(cols: 40, rows: 5))
        terminal.write("Some content here")
        #expect(terminal.screenText().contains("Some content"))

        terminal.reset()
        #expect(terminal.cursorPosition.x == 0)
        #expect(terminal.cursorPosition.y == 0)
    }

    @Test("Resize changes dimensions")
    func resize() throws {
        let terminal = try GhosttyInMemoryTerminal(options: .init(cols: 80, rows: 24))
        #expect(terminal.cols == 80)
        #expect(terminal.rows == 24)

        try terminal.resize(cols: 120, rows: 40)
        #expect(terminal.cols == 120)
        #expect(terminal.rows == 40)
    }

    @Test("Write with Data works like write with String")
    func writeData() throws {
        let terminal = try GhosttyInMemoryTerminal(options: .init(cols: 40, rows: 5))
        let data = "Hello from Data".data(using: .utf8)!
        terminal.write(data)
        #expect(terminal.screenText().contains("Hello from Data"))
    }

    @Test("SGR color sequences are processed without crashing")
    func sgrColors() throws {
        let terminal = try GhosttyInMemoryTerminal(options: .init(cols: 40, rows: 5))
        // Red foreground, write text, reset
        terminal.write("\u{1b}[31mRed Text\u{1b}[0m Normal")
        let text = terminal.screenText()
        #expect(text.contains("Red Text"))
        #expect(text.contains("Normal"))
    }

    @Test("Cursor visibility is queryable")
    func cursorVisibility() throws {
        let terminal = try GhosttyInMemoryTerminal()
        #expect(terminal.cursorPosition.isVisible)

        // DECTCEM: hide cursor
        terminal.write("\u{1b}[?25l")
        #expect(!terminal.cursorPosition.isVisible)

        // DECTCEM: show cursor
        terminal.write("\u{1b}[?25h")
        #expect(terminal.cursorPosition.isVisible)
    }

    @Test("Setting colors does not crash")
    func setColors() throws {
        let terminal = try GhosttyInMemoryTerminal()
        terminal.setForegroundColor(r: 0xCD, g: 0xD6, b: 0xF4)
        terminal.setBackgroundColor(r: 0x1E, g: 0x1E, b: 0x2E)
        terminal.setCursorColor(r: 0xF5, g: 0xE0, b: 0xDC)
    }

    @Test("Alternate screen mode works")
    func alternateScreen() throws {
        let terminal = try GhosttyInMemoryTerminal(options: .init(cols: 40, rows: 5))
        terminal.write("Primary content")

        // Switch to alternate screen
        terminal.write("\u{1b}[?1049h")
        terminal.write("Alternate content")
        let altText = terminal.screenText()
        #expect(altText.contains("Alternate content"))
        #expect(!altText.contains("Primary content"))

        // Switch back to primary
        terminal.write("\u{1b}[?1049l")
        let primaryText = terminal.screenText()
        #expect(primaryText.contains("Primary content"))
    }
}
