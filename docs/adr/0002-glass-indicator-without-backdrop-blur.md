# The indicator is a per-pixel-alpha pill, with tinted glass and no backdrop blur

Status: accepted (2026-10-10)

The design calls for a floating "liquid glass" pill while the user speaks. It is a native layered window that GDI+ draws with per-pixel alpha and `UpdateLayeredWindow`. That gives smooth anti-aliased edges, a glow that pulses with the voice, an animated change of width between states, and fade in and out. The glass is a dense tint with a highlight along the top and a thin rim. Nothing behind the pill is blurred.

## Considered options

A spike measured the alternatives on Windows 11 (2026-10-10). DWM's acrylic blur (`ACCENT_ENABLE_ACRYLICBLURBEHIND`) always fills the window's whole rectangle:

- On a layered window, `SetWindowRgn` is ignored.
- On an ordinary window, the region clips the content but not the blur.
- Shrinking the window to the pill and asking Windows 11 to round its corners (`DWMWA_WINDOW_CORNER_PREFERENCE`) gives at most 8 px corners: a blurred rounded rectangle with the pill drawn inside it. That window also cannot carry a glow, which would spill outside it.

Real blur in the shape of a pill is not available from DWM to any desktop app, WinUI 3 included. Blur is therefore not something to add later.

## Consequences

- The tint must be dense enough for white text to read over any background (alpha around 0.72). The design mockups were adjusted to match.
- Windows 10 renders it identically.
- The window stays click-through and never takes focus (`WS_EX_TRANSPARENT | WS_EX_NOACTIVATE`), as the old indicator did.
