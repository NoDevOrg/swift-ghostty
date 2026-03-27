import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.nodev.AgentWorkspace", category: "GhosttyApp")

/// Singleton managing the `ghostty_app_t` lifecycle.
/// Call `initialize()` from `applicationDidFinishLaunching` before using.
@MainActor
public final class GhosttyAppManager: ObservableObject {
    public enum ReadyState {
        case loading, ready, error
    }

    @Published public private(set) var readyState: ReadyState = .loading
    nonisolated(unsafe) private(set) var app: ghostty_app_t?
    nonisolated(unsafe) private(set) var config: ghostty_config_t?

    public static let shared = GhosttyAppManager()

    private init() {
        // Intentionally empty — call initialize() after app launch
    }

    /// Initialize the Ghostty app. Must be called from applicationDidFinishLaunching
    /// or later, after the NSApplication run loop is active.
    public func initialize(loadDefaultConfig: Bool = true) {
        guard readyState == .loading else { return }

        // Initialize Ghostty global state — MUST be called before any other ghostty_* function
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            logger.error("ghostty_init failed")
            readyState = .error
            return
        }

        // Load default Ghostty configuration
        guard let cfg = ghostty_config_new() else {
            logger.error("ghostty_config_new failed")
            readyState = .error
            return
        }
        if loadDefaultConfig {
            ghostty_config_load_default_files(cfg)
        }
        ghostty_config_finalize(cfg)
        self.config = cfg

        // Create the runtime config with our callbacks.
        // Callbacks are defined as nonisolated free functions (below) so that
        // Swift 6 does not insert @MainActor isolation checks when they are
        // called from ghostty's renderer or IO threads.
        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: ghosttyWakeupCallback,
            action_cb: ghosttyActionCallback,
            read_clipboard_cb: ghosttyReadClipboardCallback,
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: ghosttyWriteClipboardCallback,
            close_surface_cb: ghosttyCloseSurfaceCallback
        )

        guard let app = ghostty_app_new(&runtime, cfg) else {
            logger.error("ghostty_app_new failed")
            ghostty_config_free(cfg)
            self.config = nil
            readyState = .error
            return
        }
        self.app = app

        // Set initial focus state
        ghostty_app_set_focus(app, NSApp.isActive)

        // Listen for app focus changes
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(keyboardSelectionDidChange),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)

        // Set color scheme based on current appearance
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_app_set_color_scheme(app, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)

        readyState = .ready
        logger.info("GhosttyApp initialized successfully")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }

    /// Apply a Ghostty configuration to all surfaces.
    public func updateConfig(_ config: ghostty_config_t) {
        guard let app else { return }
        ghostty_app_update_config(app, config)
    }

    // MARK: - Tick

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Notifications

    @objc private func appDidBecomeActive(_ notification: Notification) {
        guard let app else { return }
        ghostty_app_set_focus(app, true)
    }

    @objc private func appDidResignActive(_ notification: Notification) {
        guard let app else { return }
        ghostty_app_set_focus(app, false)
    }

    @objc private func keyboardSelectionDidChange(_ notification: Notification) {
        guard let app else { return }
        ghostty_app_keyboard_changed(app)
    }

}

// MARK: - Notification Names

// MARK: - Nonisolated C Callbacks
//
// These must be free functions (not closures inside @MainActor methods)
// so that Swift 6 does not insert MainActor isolation checks when ghostty
// calls them from its renderer or IO threads.

private func ghosttyWakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    nonisolated(unsafe) let ptr = userdata
    DispatchQueue.main.async {
        let mgr = Unmanaged<GhosttyAppManager>.fromOpaque(ptr).takeUnretainedValue()
        mgr.tick()
    }
}

private func ghosttyActionCallback(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    let tag = action.tag

    switch tag {
    case GHOSTTY_ACTION_SET_TITLE:
        let v = action.action.set_title
        guard let ptr = v.title else { return false }
        let title = String(cString: ptr)
        if target.tag == GHOSTTY_TARGET_SURFACE {
            let surface = target.target.surface
            NotificationCenter.default.post(
                name: .ghosttySurfaceTitleDidChange,
                object: nil,
                userInfo: ["surface": surface as Any, "title": title])
        }
        return true

    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
        let v = action.action.mouse_visibility
        NSCursor.setHiddenUntilMouseMoves(v != GHOSTTY_MOUSE_VISIBLE)
        return true

    case GHOSTTY_ACTION_PRESENT_TERMINAL:
        if target.tag == GHOSTTY_TARGET_SURFACE {
            let surface = target.target.surface
            NotificationCenter.default.post(
                name: .ghosttySurfaceRequestFocus,
                object: nil,
                userInfo: ["surface": surface as Any])
        }
        return true

    case GHOSTTY_ACTION_RENDERER_HEALTH:
        if target.tag == GHOSTTY_TARGET_SURFACE {
            let surface = target.target.surface
            let health = action.action.renderer_health
            NotificationCenter.default.post(
                name: .ghosttySurfaceHealthDidChange,
                object: nil,
                userInfo: ["surface": surface as Any, "health": health])
        }
        return true

    case GHOSTTY_ACTION_PWD:
        let v = action.action.pwd
        guard let ptr = v.pwd else { return false }
        let pwd = String(cString: ptr)
        if target.tag == GHOSTTY_TARGET_SURFACE {
            let surface = target.target.surface
            NotificationCenter.default.post(
                name: .ghosttySurfacePwdDidChange,
                object: nil,
                userInfo: ["surface": surface as Any, "pwd": pwd])
        }
        return true

    case GHOSTTY_ACTION_MOUSE_SHAPE:
        return true

    case GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_RING_BELL,
         GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_RELOAD_CONFIG:
        return true

    default:
        return false
    }
}

private func ghosttyReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    guard let userdata else { return false }
    let surfaceView = Unmanaged<GhosttyTerminalSurface>.fromOpaque(userdata).takeUnretainedValue()
    guard let surface = surfaceView.surface else { return false }

    let pasteboard = NSPasteboard.general
    guard let str = pasteboard.string(forType: .string) else { return false }
    str.withCString { ptr in
        ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
    }
    return true
}

private func ghosttyWriteClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ len: Int,
    _ confirm: Bool
) {
    guard let content, len > 0 else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()

    for i in 0..<len {
        let item = content[i]
        if let data = item.data {
            let str = String(cString: data)
            pasteboard.setString(str, forType: .string)
        }
    }
}

private func ghosttyCloseSurfaceCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
) {
    guard let userdata else { return }
    let surfaceView = Unmanaged<GhosttyTerminalSurface>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
        surfaceView.surfaceDidClose(processAlive: processAlive)
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    static let ghosttySurfaceTitleDidChange = Notification.Name("ghosttySurfaceTitleDidChange")
    static let ghosttySurfacePwdDidChange = Notification.Name("ghosttySurfacePwdDidChange")
    static let ghosttySurfaceRequestFocus = Notification.Name("ghosttySurfaceRequestFocus")
    static let ghosttySurfaceHealthDidChange = Notification.Name("ghosttySurfaceHealthDidChange")
    static let ghosttySurfaceDidClose = Notification.Name("ghosttySurfaceDidClose")
}
