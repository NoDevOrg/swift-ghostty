// GhosttyVT — umbrella header for the libghostty-vt C API.
// This provides the headless terminal emulator, formatter, and grid APIs.

#ifndef GHOSTTY_VT_SHIM_H
#define GHOSTTY_VT_SHIM_H

// The main ghostty.h defines GHOSTTY_SUCCESS as a macro (#define GHOSTTY_SUCCESS 0).
// The VT library defines it as an enum value (GHOSTTY_SUCCESS = 0) inside GhosttyResult.
// Undef the macro so the VT enum compiles correctly when both modules coexist.
#ifdef GHOSTTY_SUCCESS
#undef GHOSTTY_SUCCESS
#endif

#include <ghostty/vt/types.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/color.h>
#include <ghostty/vt/device.h>
#include <ghostty/vt/modes.h>
#include <ghostty/vt/point.h>
#include <ghostty/vt/screen.h>
#include <ghostty/vt/size_report.h>
#include <ghostty/vt/style.h>
#include <ghostty/vt/grid_ref.h>
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/formatter.h>

#endif /* GHOSTTY_VT_SHIM_H */
