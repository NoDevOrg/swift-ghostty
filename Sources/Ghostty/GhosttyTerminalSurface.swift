@preconcurrency import AppKit
import Combine
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.nodev.AgentWorkspace", category: "TerminalSurface")

/// An NSView that hosts a Ghostty terminal surface with Metal rendering.
/// This is the AppKit view that manages a single terminal instance.
public class GhosttyTerminalSurface: NSView, NSTextInputClient {
    /// The underlying Ghostty surface handle.
    nonisolated(unsafe) public private(set) var surface: ghostty_surface_t?

    /// Current title of the terminal (set by escape sequences).
    @Published public private(set) var title: String = ""

    /// Current working directory (set by escape sequences).
    @Published public private(set) var pwd: String?

    /// Whether the terminal process has exited.
    @Published public private(set) var processExited: Bool = false

    /// Whether the surface is healthy (renderer OK).
    @Published public private(set) var healthy: Bool = true

    /// Whether this surface is focused.
    private var isFocused: Bool = false

    /// Text accumulator for key input handling.
    nonisolated(unsafe) private var keyTextAccumulator: [String]?

    /// Marked text for IME input.
    nonisolated(unsafe) private var markedText = NSMutableAttributedString()

    /// The app manager (weak to avoid retain cycle).
    private weak var appManager: GhosttyAppManager?

    /// Stored init parameters for deferred surface creation.
    private var pendingCommand: String?
    private var pendingWorkingDirectory: String?

    /// Whether we have registered notification observers.
    private var observingNotifications = false

    override public var acceptsFirstResponder: Bool { true }

    /// Create a terminal surface.
    /// - Parameters:
    ///   - appManager: The GhosttyAppManager singleton
    ///   - command: Optional command to run (nil = default shell)
    ///   - workingDirectory: Starting directory
    ///   - environmentVariables: Extra env vars for the terminal process
    public init(
        appManager: GhosttyAppManager,
        command: String? = nil,
        workingDirectory: String? = nil,
        environmentVariables: [String: String] = [:]
    ) {
        self.appManager = appManager
        self.pendingCommand = command
        self.pendingWorkingDirectory = workingDirectory
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        // Note: we do NOT set wantsLayer — ghostty's Metal renderer manages its own layer.

        // Register for notifications about this surface
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(handleTitleChange),
            name: .ghosttySurfaceTitleDidChange, object: nil)
        center.addObserver(
            self, selector: #selector(handlePwdChange),
            name: .ghosttySurfacePwdDidChange, object: nil)
        center.addObserver(
            self, selector: #selector(handleHealthChange),
            name: .ghosttySurfaceHealthDidChange, object: nil)
        observingNotifications = true

        // Surface creation is deferred to viewDidMoveToWindow so the Metal layer is ready.
    }

    /// Creates the ghostty surface. Called once when the view first moves to a window.
    private func createSurface() {
        guard surface == nil else { return }
        guard let ghosttyApp = appManager?.app else { return }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        let command = pendingCommand
        let workingDirectory = pendingWorkingDirectory
        pendingCommand = nil
        pendingWorkingDirectory = nil

        let createFn = { (cfg: inout ghostty_surface_config_s) -> ghostty_surface_t? in
            ghostty_surface_new(ghosttyApp, &cfg)
        }

        let createdSurface: ghostty_surface_t?
        if let command, let workingDirectory {
            createdSurface = command.withCString { cmdPtr in
                workingDirectory.withCString { wdPtr in
                    config.command = cmdPtr
                    config.working_directory = wdPtr
                    return createFn(&config)
                }
            }
        } else if let command {
            createdSurface = command.withCString { cmdPtr in
                config.command = cmdPtr
                return createFn(&config)
            }
        } else if let workingDirectory {
            createdSurface = workingDirectory.withCString { wdPtr in
                config.working_directory = wdPtr
                return createFn(&config)
            }
        } else {
            createdSurface = createFn(&config)
        }

        guard let createdSurface else {
            logger.error("ghostty_surface_new failed")
            return
        }
        self.surface = createdSurface
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if observingNotifications { NotificationCenter.default.removeObserver(self) }
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    // MARK: - Public API

    /// Called when the close_surface_cb fires for this surface.
    public func surfaceDidClose(processAlive: Bool) {
        processExited = true
        NotificationCenter.default.post(
            name: .ghosttySurfaceDidClose,
            object: nil,
            userInfo: ["surface": surface as Any, "processAlive": processAlive])
        logger.info("Surface closed, processAlive=\(processAlive)")
    }

    /// Check if the process has exited.
    public func checkProcessExited() -> Bool {
        guard let surface else { return true }
        let exited = ghostty_surface_process_exited(surface)
        if exited { processExited = true }
        return exited
    }

    /// Apply a Ghostty configuration to this surface.
    public func updateConfig(_ config: ghostty_config_t) {
        guard let surface else { return }
        ghostty_surface_update_config(surface, config)
    }

    /// Read the visible terminal screen text as a plain string.
    /// Returns `nil` if the surface isn't ready or reading fails.
    public func readText() -> String? {
        guard let surface else { return nil }

        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0 else { return nil }

        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: UInt32(size.columns) - 1,
                y: UInt32(size.rows) - 1
            ),
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        guard let ptr = text.text, text.text_len > 0 else { return nil }
        return String(cString: ptr)
    }

    // MARK: - Notification Handlers

    @objc private func handleTitleChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let surfacePtr = info["surface"] as? ghostty_surface_t,
              surfacePtr == self.surface,
              let newTitle = info["title"] as? String else { return }
        self.title = newTitle
    }

    @objc private func handlePwdChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let surfacePtr = info["surface"] as? ghostty_surface_t,
              surfacePtr == self.surface,
              let newPwd = info["pwd"] as? String else { return }
        self.pwd = newPwd
    }

    @objc private func handleHealthChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let surfacePtr = info["surface"] as? ghostty_surface_t,
              surfacePtr == self.surface else { return }
        let health = info["health"] as? ghostty_action_renderer_health_e
        self.healthy = health == GHOSTTY_RENDERER_HEALTH_HEALTHY
    }

    // MARK: - View Lifecycle

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window != nil {
            // Create the surface the first time we're added to a window,
            // so the Metal layer is ready for the renderer.
            createSurface()

            if let surface {
                let scaledSize = convertToBacking(frame.size)
                ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
            }
        }
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface else { return }

        let scaledSize = convertToBacking(newSize)
        ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface else { return }

        if let scale = window?.backingScaleFactor {
            ghostty_surface_set_content_scale(surface, scale, scale)
        }
        let scaledSize = convertToBacking(frame.size)
        ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
    }

    override public func updateTrackingAreas() {
        // Remove existing tracking areas
        trackingAreas.forEach { removeTrackingArea($0) }

        // Add a new tracking area for mouse events
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)

        super.updateTrackingAreas()
    }

    override public func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            isFocused = true
            if let surface {
                ghostty_surface_set_focus(surface, true)
            }
        }
        return result
    }

    override public func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            isFocused = false
            if let surface {
                ghostty_surface_set_focus(surface, false)
            }
        }
        return result
    }

    // MARK: - Keyboard Input

    override public func keyDown(with event: NSEvent) {
        guard surface != nil else {
            interpretKeyEvents([event])
            return
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Accumulate text from interpretKeyEvents for IME support
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        interpretKeyEvents([event])

        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            // We got composed text from IME
            for text in accumulated {
                sendKeyEvent(action, event: event, text: text)
            }
        } else {
            // Normal key event
            sendKeyEvent(action, event: event, text: event.ghosttyCharacters)
        }
    }

    override public func keyUp(with event: NSEvent) {
        sendKeyEvent(GHOSTTY_ACTION_RELEASE, event: event, text: nil)
    }

    nonisolated override public func doCommand(by selector: Selector) {
        // Don't call super — that triggers NSBeep for unhandled selectors.
        // Ghostty handles all key input via ghostty_surface_key.
    }

    override public func flagsChanged(with event: NSEvent) {
        guard let surface else { return }

        let mods = Self.ghosttyMods(event.modifierFlags)
        var key_ev = ghostty_input_key_s()
        key_ev.action = GHOSTTY_ACTION_PRESS
        key_ev.mods = mods
        key_ev.keycode = UInt32(event.keyCode)
        key_ev.text = nil
        key_ev.composing = false
        key_ev.unshifted_codepoint = 0
        key_ev.consumed_mods = GHOSTTY_MODS_NONE
        ghostty_surface_key(surface, key_ev)
    }

    private func sendKeyEvent(_ action: ghostty_input_action_e, event: NSEvent, text: String?) {
        guard let surface else { return }

        var key_ev = ghostty_input_key_s()
        key_ev.action = action
        key_ev.keycode = UInt32(event.keyCode)
        key_ev.mods = Self.ghosttyMods(event.modifierFlags)
        key_ev.consumed_mods = Self.ghosttyMods(
            event.modifierFlags.subtracting([.control, .command]))
        key_ev.composing = false

        // Compute unshifted codepoint
        key_ev.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                key_ev.unshifted_codepoint = codepoint.value
            }
        }

        if let text {
            text.withCString { ptr in
                key_ev.text = ptr
                ghostty_surface_key(surface, key_ev)
            }
        } else {
            key_ev.text = nil
            ghostty_surface_key(surface, key_ev)
        }
    }

    // MARK: - Mouse Input

    override public func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        window?.makeFirstResponder(self)

        let point = convert(event.locationInWindow, from: nil)
        let scaledPoint = convertToBacking(point)
        ghostty_surface_mouse_pos(surface, scaledPoint.x, scaledPoint.y, Self.ghosttyMods(event.modifierFlags))
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Self.ghosttyMods(event.modifierFlags))
    }

    override public func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scaledPoint = convertToBacking(point)
        ghostty_surface_mouse_pos(surface, scaledPoint.x, scaledPoint.y, Self.ghosttyMods(event.modifierFlags))
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Self.ghosttyMods(event.modifierFlags))
    }

    override public func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scaledPoint = convertToBacking(point)
        ghostty_surface_mouse_pos(surface, scaledPoint.x, scaledPoint.y, Self.ghosttyMods(event.modifierFlags))
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.ghosttyMods(event.modifierFlags))
    }

    override public func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scaledPoint = convertToBacking(point)
        ghostty_surface_mouse_pos(surface, scaledPoint.x, scaledPoint.y, Self.ghosttyMods(event.modifierFlags))
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.ghosttyMods(event.modifierFlags))
    }

    override public func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scaledPoint = convertToBacking(point)
        ghostty_surface_mouse_pos(surface, scaledPoint.x, scaledPoint.y, Self.ghosttyMods(event.modifierFlags))
    }

    override public func mouseDragged(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scaledPoint = convertToBacking(point)
        ghostty_surface_mouse_pos(surface, scaledPoint.x, scaledPoint.y, Self.ghosttyMods(event.modifierFlags))
    }

    override public func scrollWheel(with event: NSEvent) {
        guard let surface else { return }

        var mods = ghostty_input_scroll_mods_t(0)
        if event.hasPreciseScrollingDeltas { mods |= 1 } // precise bit

        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, mods)
    }

    // MARK: - NSTextInputClient

    nonisolated public func insertText(_ string: Any, replacementRange: NSRange) {
        guard let str = string as? String else { return }

        if keyTextAccumulator != nil {
            // We're in a keyDown — accumulate for later
            keyTextAccumulator?.append(str)
        } else {
            // Direct text insertion (e.g., from services menu)
            guard let surface else { return }
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    ghostty_surface_text(surface, ptr, UInt(len - 1))
                }
            }
        }
    }

    nonisolated public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let attrStr: NSAttributedString
        if let str = string as? String {
            attrStr = NSAttributedString(string: str)
        } else if let attr = string as? NSAttributedString {
            attrStr = attr
        } else {
            return
        }

        markedText = NSMutableAttributedString(attributedString: attrStr)

        // Send preedit text to Ghostty
        guard let surface else { return }
        let text = attrStr.string
        let len = text.utf8CString.count
        text.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(max(0, len - 1)))
        }
    }

    nonisolated public func unmarkText() {
        markedText = NSMutableAttributedString()
        guard let surface else { return }
        ghostty_surface_preedit(surface, nil, 0)
    }

    nonisolated public func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    nonisolated public func markedRange() -> NSRange {
        if markedText.length > 0 {
            return NSRange(location: 0, length: markedText.length)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    nonisolated public func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    nonisolated public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    nonisolated public func validAttributedString(for proposedString: NSAttributedString, range: NSRange) -> NSAttributedString {
        proposedString
    }

    nonisolated public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        MainActor.assumeIsolated {
            guard let surface, let windowFrame = window?.frame else { return .zero }

            var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
            ghostty_surface_ime_point(surface, &x, &y, &w, &h)

            // Convert from surface coordinates to screen coordinates
            let viewPoint = NSPoint(x: x, y: frame.height - y)
            let windowPoint = convert(viewPoint, to: nil)
            let screenPoint = NSPoint(
                x: windowFrame.origin.x + windowPoint.x,
                y: windowFrame.origin.y + windowPoint.y - h
            )

            return NSRect(x: screenPoint.x, y: screenPoint.y, width: w, height: h)
        }
    }

    nonisolated public func characterIndex(for point: NSPoint) -> Int {
        0
    }

    nonisolated public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    // MARK: - Modifier Conversion

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }
}

// MARK: - NSEvent Extension

extension NSEvent {
    /// Returns the text to set for a Ghostty key event.
    /// Avoids control characters and PUA range function keys.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }

        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            // Control characters — let Ghostty handle encoding
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            // PUA function keys — don't send to terminal
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}
