# The settings window and the first-run setup are web pages hosted in WebView2

Status: accepted (2026-10-10)

The settings window and the first-run setup move from AutoHotkey's native Win32 controls to HTML/CSS pages hosted in a WebView2 control, still driven by `Whispers.ahk`. The visual target is Windows 11 / Fluent: Mica, rounded cards, toggle switches, segmented choices, and a theme that follows Windows. Win32 tab controls, drop-down lists and check boxes cannot reach that look. Drawing every control by hand in GDI+ would cost more than the pages and still look wrong at the edges.

## Considered options

- **Native Win32 with Mica and a dark title bar.** No new dependency, but the controls keep the Windows 7 look and the visual ceiling stays low.
- **A WinUI 3 / C# front end.** The most native result, but it adds a build step, a second toolchain and a second executable to a project whose app has none ("`AutoHotkey64.exe Whispers.ahk` runs it").
- **WebView2 (chosen).** No build step and full visual freedom. The cost is the dependency below.

## Consequences

- **A runtime the project does not pin.** WebView2's runtime belongs to the operating system and Microsoft updates it, like the self-update digest it is an exception to "everything is pinned in `versions.json`". It ships with Windows 11 and is almost always present on Windows 10. The installer detects it and offers a per-user install. If it is still missing at run time, Whispers falls back to the native windows it has today, so a dictation tool never becomes unconfigurable because of a browser component.
- **Pinned parts we do ship.** The AutoHotkey WebView2 binding and `WebView2Loader.dll` are pinned in `versions.json` by tag and SHA-256, like every other download.
- **One source of truth for settings.** The pages call into AutoHotkey for every read and write. `ConfigSpec()` stays the only schema, and settings logic stays out of JavaScript.
- **The indicator is not part of this decision.** It must appear the instant the hotkey goes down, so it stays a native window (ADR-0002).
