import Foundation
import GhosttyVT

/// A headless terminal emulator that processes VT sequences without UI or PTY.
///
/// Use this to parse and evaluate terminal escape sequences in memory,
/// then query the resulting screen state (cell contents, cursor position,
/// title, colors, etc.).
///
/// This does **not** require `GhosttyAppManager` or `ghostty_init()` — the VT
/// library is fully standalone.
///
/// Thread safety: the caller must serialize all access to a single instance.
public final class GhosttyInMemoryTerminal: @unchecked Sendable {

    // MARK: - Types

    /// Options for creating an in-memory terminal.
    public struct Options: Sendable {
        public var cols: UInt16
        public var rows: UInt16
        public var maxScrollback: Int

        public init(cols: UInt16 = 80, rows: UInt16 = 24, maxScrollback: Int = 10_000) {
            self.cols = cols
            self.rows = rows
            self.maxScrollback = maxScrollback
        }
    }

    /// Cursor position in the terminal grid.
    public struct CursorPosition: Sendable {
        public let x: UInt16
        public let y: UInt16
        public let isVisible: Bool
        public let pendingWrap: Bool
    }

    public enum InitError: Error, Sendable {
        case terminalCreationFailed(Int32)
        case formatterCreationFailed(Int32)
    }

    public enum ResizeError: Error, Sendable {
        case failed(Int32)
    }

    // MARK: - Callbacks

    /// Called when the terminal needs to write response data back to the PTY
    /// (e.g. for device attribute queries). The `Data` is only valid for the
    /// duration of the closure call.
    public var onWritePTY: ((Data) -> Void)?

    /// Called when a BEL character (0x07) is received.
    public var onBell: (() -> Void)?

    /// Called when the terminal title changes via OSC sequences.
    public var onTitleChanged: (() -> Void)?

    // MARK: - Private State

    private var terminal: GhosttyTerminal!

    // MARK: - Lifecycle

    /// Create a headless terminal with the given options.
    public init(options: Options = Options()) throws {
        var handle: GhosttyTerminal?
        let opts = GhosttyTerminalOptions(
            cols: options.cols,
            rows: options.rows,
            max_scrollback: options.maxScrollback
        )
        let result = ghostty_terminal_new(nil, &handle, opts)
        guard result == GHOSTTY_SUCCESS, let handle else {
            throw InitError.terminalCreationFailed(result.rawValue)
        }
        self.terminal = handle

        // Set userdata so callbacks can recover `self`
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, selfPtr)

        // Install callbacks — ghostty_terminal_set takes `const void*` for the value,
        // so we pass function pointers by converting them to raw pointers.
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                             unsafeBitCast(writePtyTrampoline, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL,
                             unsafeBitCast(bellTrampoline, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
                             unsafeBitCast(titleChangedTrampoline, to: UnsafeRawPointer.self))
    }

    deinit {
        if terminal != nil {
            ghostty_terminal_free(terminal)
        }
    }

    // MARK: - Writing

    /// Feed raw bytes into the terminal for VT processing.
    public func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ghostty_terminal_vt_write(terminal, ptr, buffer.count)
        }
    }

    /// Feed a UTF-8 string into the terminal for VT processing.
    public func write(_ string: String) {
        var string = string
        string.withUTF8 { buffer in
            ghostty_terminal_vt_write(terminal, buffer.baseAddress, buffer.count)
        }
    }

    /// Perform a full terminal reset (RIS).
    public func reset() {
        ghostty_terminal_reset(terminal)
    }

    // MARK: - Resize

    /// Resize the terminal grid.
    public func resize(cols: UInt16, rows: UInt16) throws {
        let result = ghostty_terminal_resize(terminal, cols, rows, 1, 1)
        guard result == GHOSTTY_SUCCESS else {
            throw ResizeError.failed(result.rawValue)
        }
    }

    // MARK: - State Queries

    /// Terminal width in cells.
    public var cols: UInt16 {
        var value: UInt16 = 0
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &value)
        return value
    }

    /// Terminal height in cells.
    public var rows: UInt16 {
        var value: UInt16 = 0
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, &value)
        return value
    }

    /// Current cursor position and state.
    public var cursorPosition: CursorPosition {
        var x: UInt16 = 0
        var y: UInt16 = 0
        var visible = true
        var pendingWrap = false
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &visible)
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP, &pendingWrap)
        return CursorPosition(x: x, y: y, isVisible: visible, pendingWrap: pendingWrap)
    }

    /// The terminal title as set by OSC escape sequences.
    public var title: String? {
        var str = GhosttyString(ptr: nil, len: 0)
        let result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &str)
        guard result == GHOSTTY_SUCCESS, let ptr = str.ptr, str.len > 0 else { return nil }
        return String(bytes: UnsafeBufferPointer(start: ptr, count: str.len), encoding: .utf8)
    }

    /// The terminal working directory as set by OSC 7.
    public var workingDirectory: String? {
        var str = GhosttyString(ptr: nil, len: 0)
        let result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &str)
        guard result == GHOSTTY_SUCCESS, let ptr = str.ptr, str.len > 0 else { return nil }
        return String(bytes: UnsafeBufferPointer(start: ptr, count: str.len), encoding: .utf8)
    }

    // MARK: - Screen Text

    /// Dump the visible screen content as plain text.
    public func screenText(trimmed: Bool = true) -> String {
        var formatter: GhosttyFormatter?
        var opts = GhosttyFormatterTerminalOptions(
            size: MemoryLayout<GhosttyFormatterTerminalOptions>.size,
            emit: GHOSTTY_FORMATTER_FORMAT_PLAIN,
            unwrap: false,
            trim: trimmed,
            extra: GhosttyFormatterTerminalExtra(
                size: MemoryLayout<GhosttyFormatterTerminalExtra>.size,
                palette: false,
                modes: false,
                scrolling_region: false,
                tabstops: false,
                pwd: false,
                keyboard: false,
                screen: GhosttyFormatterScreenExtra(
                    size: MemoryLayout<GhosttyFormatterScreenExtra>.size,
                    cursor: false,
                    style: false,
                    hyperlink: false,
                    protection: false,
                    kitty_keyboard: false,
                    charsets: false
                )
            )
        )

        let createResult = ghostty_formatter_terminal_new(nil, &formatter, terminal, opts)
        guard createResult == GHOSTTY_SUCCESS, let formatter else { return "" }
        defer { ghostty_formatter_free(formatter) }

        var outPtr: UnsafeMutablePointer<UInt8>?
        var outLen: Int = 0
        let formatResult = ghostty_formatter_format_alloc(formatter, nil, &outPtr, &outLen)
        guard formatResult == GHOSTTY_SUCCESS, let ptr = outPtr, outLen > 0 else { return "" }
        defer { ghostty_free(nil, ptr, outLen) }

        return String(bytes: UnsafeBufferPointer(start: ptr, count: outLen), encoding: .utf8) ?? ""
    }

    // MARK: - Colors

    /// Set the default foreground color.
    public func setForegroundColor(r: UInt8, g: UInt8, b: UInt8) {
        var color = GhosttyColorRgb(r: r, g: g, b: b)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &color)
    }

    /// Set the default background color.
    public func setBackgroundColor(r: UInt8, g: UInt8, b: UInt8) {
        var color = GhosttyColorRgb(r: r, g: g, b: b)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &color)
    }

    /// Set the default cursor color.
    public func setCursorColor(r: UInt8, g: UInt8, b: UInt8) {
        var color = GhosttyColorRgb(r: r, g: g, b: b)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &color)
    }

    /// Set the full 256-color palette. The array must have exactly 256 entries.
    public func setPalette(_ colors: [(r: UInt8, g: UInt8, b: UInt8)]) {
        precondition(colors.count == 256, "Palette must have exactly 256 entries")
        var palette = colors.map { GhosttyColorRgb(r: $0.r, g: $0.g, b: $0.b) }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &palette)
    }

    // MARK: - Scrolling

    /// Scroll the viewport to the top of scrollback.
    public func scrollToTop() {
        let scroll = GhosttyTerminalScrollViewport(
            tag: GHOSTTY_SCROLL_VIEWPORT_TOP,
            value: GhosttyTerminalScrollViewportValue(delta: 0)
        )
        ghostty_terminal_scroll_viewport(terminal, scroll)
    }

    /// Scroll the viewport to the bottom (active area).
    public func scrollToBottom() {
        let scroll = GhosttyTerminalScrollViewport(
            tag: GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
            value: GhosttyTerminalScrollViewportValue(delta: 0)
        )
        ghostty_terminal_scroll_viewport(terminal, scroll)
    }

    /// Scroll by a delta number of rows (negative = up, positive = down).
    public func scroll(delta: Int) {
        let scroll = GhosttyTerminalScrollViewport(
            tag: GHOSTTY_SCROLL_VIEWPORT_DELTA,
            value: GhosttyTerminalScrollViewportValue(delta: delta)
        )
        ghostty_terminal_scroll_viewport(terminal, scroll)
    }
}

// MARK: - C Callback Trampolines

private let writePtyTrampoline: GhosttyTerminalWritePtyFn = { terminal, userdata, data, len in
    guard let userdata else { return }
    let term = Unmanaged<GhosttyInMemoryTerminal>.fromOpaque(userdata).takeUnretainedValue()
    guard let data, len > 0, let callback = term.onWritePTY else { return }
    callback(Data(bytes: data, count: len))
}

private let bellTrampoline: GhosttyTerminalBellFn = { terminal, userdata in
    guard let userdata else { return }
    let term = Unmanaged<GhosttyInMemoryTerminal>.fromOpaque(userdata).takeUnretainedValue()
    term.onBell?()
}

private let titleChangedTrampoline: GhosttyTerminalTitleChangedFn = { terminal, userdata in
    guard let userdata else { return }
    let term = Unmanaged<GhosttyInMemoryTerminal>.fromOpaque(userdata).takeUnretainedValue()
    term.onTitleChanged?()
}
