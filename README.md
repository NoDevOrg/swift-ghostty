# swift-ghostty

A Swift package wrapping [Ghostty](https://github.com/ghostty-org/ghostty)'s terminal engine for embedding in macOS apps.

## Requirements

- macOS 26+
- Swift 6.2+
- [Zig](https://ziglang.org) 0.15.2 (installed automatically via [mise](https://mise.jdx.dev))

## Setup

The package depends on a pre-built GhosttyKit xcframework. Build it first:

```bash
git submodule update --init --recursive
make xcframework
```

This compiles the Ghostty C library from source using Zig and packages it as `Frameworks/GhosttyKit.xcframework.zip`.

## Usage

Add the package as a dependency:

```swift
.package(path: "/path/to/swift-ghostty")
```

Then import and use:

```swift
import Ghostty

// Initialize once at app launch
GhosttyAppManager.shared.initialize()

// Embed a terminal in SwiftUI
GhosttyTerminalView(appManager: GhosttyAppManager.shared)
```

See [`Examples/BasicTerminal`](Examples/BasicTerminal) for a complete working app.

## Running the Example

```bash
make xcframework
cd Examples/BasicTerminal
swift run
```

## Package Structure

- **`Ghostty`** - Swift library with SwiftUI/AppKit terminal views
  - `GhosttyAppManager` - Singleton managing the ghostty app lifecycle
  - `GhosttyTerminalView` - SwiftUI view embedding a terminal
  - `GhosttyTerminalSurface` - AppKit NSView with Metal rendering
- **`GhosttyKit`** - Binary target wrapping the C xcframework
