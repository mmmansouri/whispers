# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Whispers is push-to-talk dictation for Windows: an AutoHotkey v2 script that records with ffmpeg, transcribes through a local whisper.cpp `whisper-server`, and pastes the text. Windows-only; there is no build step for the app itself — `AutoHotkey64.exe Whispers.ahk` runs it. The only thing that is "built" is the Inno Setup installer.

## Commands

Run these from **PowerShell**, not Git Bash: MSYS rewrites the `/ErrorStdOut` switch into a path, and the runner then exits 2 without rewriting `tests\results.txt` (a stale "0 failed" is left behind). From Git Bash, prefix with `MSYS_NO_PATHCONV=1`.

```powershell
# Unit suite (pure core in lib\) - exit code = number of failures, report in tests\results.txt
.\AutoHotkey64.exe /ErrorStdOut tests\run-tests.ahk

# Installer suite, static half - sources vs versions.json, ASCII/CRLF checks. Runs in CI.
pwsh -File tests\installer.ps1 -StaticOnly

# Build dist\Whispers-<version>-setup.exe (needs Inno Setup 6)
.\tools\build-installer.ps1
.\tools\build-installer.ps1 -PinsOnly      # only regenerate installer\pins.iss
```

Local-only, side-effectful — do not run unprompted:

```powershell
pwsh -File tests\integration.ps1           # drives the real app: needs mic, NVIDIA GPU, model on disk; kills running AutoHotkey64/whisper-server/ffmpeg
pwsh -File tests\installer.ps1             # real silent install + uninstall, ~600 MB download; refuses to start while Whispers runs
pwsh -File tests\installer.ps1 -Engine auto  # same on the real CUDA path, ~1.2 GB
```

There is no single-test selector. `tests\run-tests.ahk` is one flat script of `Group(...)` sections using `Eq/Yes/No/Has/Lacks`; run it all (it takes about a second) and read the relevant group in `tests\results.txt`.

`AutoHotkey64.exe`, `bin\`, `models\`, `dist\` and `installer\pins.iss` are gitignored: fetched or generated, never committed. A dev checkout points at a local whisper.cpp build through `[Paths] BinDir=/ModelsDir=` in `%APPDATA%\Whispers\Whispers.ini`.

## Architecture

### Pure core vs. shell

`lib\*.ahk` define functions only — including them executes nothing. That is the property that lets `tests\run-tests.ahk` load them without starting a server, arming a hotkey or opening a microphone. Keep it: no top-level statements, no globals, no file/network/process access in `lib\`. Functions take the text somebody else read (`versions.json` content, an ffmpeg log, a GitHub API response, certutil output) and return what it means.

`Whispers.ahk` is everything with side effects: bootstrap (top of file, runs in order), globals, process management, GUI (settings window, first-run wizard, tray, indicator), downloads. Its thin wrappers (`TierFile`, `ModelSha`, ...) read `versions.json` once via `VerRead()` and delegate to the `...From(json, ...)` functions in `lib\`. New logic that can be pure goes in `lib\` with tests; `Whispers.ahk` only wires it up.

- `lib\Commands.ahk` — every external command line. All spawns go through `ShellCmd()` = `cmd.exe /s /c "<inner>"` so output can be redirected to a log; the quoting contract is documented at the top of that file and is the riskiest thing in the codebase. The one exception is the curl download builders, launched directly so Cancel kills curl rather than cmd.
- `lib\Config.ahk` — `ConfigSpec()` is the single schema (key → [ini section, default]) used by both load and save. Add a setting there, not in two places. Values are clamped on load; a bad INI must never prevent startup.
- `lib\Tiers.ahk` — tier → model resolution and the VRAM thresholds in `RecommendTier`.
- `lib\Net.ahk` — hash parsing/matching, version comparison, release metadata.
- `lib\Devices.ahk` — dshow device list parsing, microphone matching, level parsing.
- `lib\Install.ahk` — the uninstall entry Windows lists (AppId, key, `EstimatedSize` in KB) and whether a directory is the registered installation.
- `lib\Tray.ahk` — the tray's wording and icon per state; the menu is rebuilt from it each time it opens.
- `lib\Indicator.ahk` — the indicator's arithmetic: width per state, the spring and fade steps, voice level from s16le samples, and its text. The GDI+ drawing is in `Whispers.ahk` (ADR-0002).

### Dictation pipeline

`HkDown → StartRec` spawns ffmpeg (dshow → raw s16le, open-ended; the recording ends by killing the process) and schedules `WarmUpServer` so the model loads while the user is still speaking. `HkUp → StopRec` kills the recorder, converts raw → WAV, then `Transcribe` → `EnsureServerReady` → curl POST to `http://127.0.0.1:<port>/inference` → `DeliverText` (clipboard + `^v`). `VramPolicy` selects the path: `idle` (server unloaded by `CheckIdle` after N minutes), `resident` (started at launch), `never` (`whisper-cli` per dictation). `CpuFallback` retries through `whisper-cli -ng` when the server path fails.

Concurrency is the subtle part. AHK threads are interruptible at every `RunWait`/`Sleep`/`SoundBeep`, so the key-up can fire in the middle of `StartRec`. The `Critical("On")` sections and the `gRecording`/`gStopping`/`gBusy` flags exist to make those state transitions atomic; several REGRESSION tests (second server spawned, orphaned recorder, phantom recording) pin bugs from getting this wrong. Do not add blocking spawns (nvidia-smi, HTTP probes) to `StartRec`/`StartServer` — "is the server running" is deliberately a process check, which is only valid because orphaned servers are reaped at startup.

### versions.json is the single source of truth

Every download (engine build, ffmpeg, AutoHotkey, models) is pinned there by exact tag + SHA-256; nothing resolves `latest`, at build time or run time. It is read three ways, and none is a real JSON parser on the AHK side:

- **App**: targeted regex readers (`TierField`, `JsonBlock`). Tier objects must stay flat, and the search is anchored on `"tiers"` first because `cpu` is both a tier name and an engine variant name.
- **Installer**: `tools\build-installer.ps1` projects it into `installer\pins.iss` (`#define`s). `Whispers.iss` refuses to compile without `pins.iss`, so always build through the script, never ISCC directly.
- **CI**: fetches the pinned AutoHotkey from it.

An unresolvable tier returns `""` and the app refuses to transcribe — never add a fallback default model. Post-install downloads go through `FetchVerified`: `.part` file, hash check, rename only on match. App self-update is the one unpinned download (digest comes from GitHub's API response); see README "What the update check does and does not guarantee".

Raising a pin is manual and deliberate: edit `versions.json`, run the validation for what changed, record it in the `validated` block. Process is in README "Raising a pinned version". Raising the AutoHotkey pin means re-running all suites.

### Things duplicated on purpose (guarded by `tests\installer.ps1 -StaticOnly`)

- The app version lives in `APP_VERSION` (`Whispers.ahk`) **and** `"whispers"` (`versions.json`). Bump both.
- The VRAM thresholds live in `lib\Tiers.ahk` **and** in `installer\Whispers.iss` `[Code]`, because the installer runs before the app exists on disk. Change both.
- The AppId lives in `[Setup]` of `installer\Whispers.iss` **and** in `AppId()` of `lib\Install.ahk`: the app rewrites `EstimatedSize` in the uninstall entry named after it. Never change it - upgrades are matched on it.
- The AppUserModelID lives on every shortcut in `[Icons]` of `installer\Whispers.iss` **and** in `AppUserModelId()` of `lib\Install.ahk`: Windows titles the app's notifications after the shortcut carrying the ID the process declares.

## Conventions

- `.ahk`, `.iss` and `.ps1` files are **pure ASCII with CRLF** line endings — asserted by the static installer suite, enforced on checkout by `.gitattributes`. No em dashes, arrows, accented characters or smart quotes in code or comments; write `-` and `->`.
- Comments explain *why*, usually naming the concrete bug or measurement behind a decision. Match that density and tone when editing.
- A bug that reached the running product gets a test marked `REGRESSION` and a row in the README table "What the REGRESSION assertions are for". README also states assertion counts per suite (unit 397, integration 53, installer 95) — update them when adding tests.
- Every failure path reports the real cause via `Fail(msg, detail)` with the tail of the relevant log (`%APPDATA%\Whispers\logs\`), never a bare "failed".
- Per-user only: no administrator rights anywhere (installer is `PrivilegesRequired=lowest`, server port clamped to ≥1024, loopback only).
- User data lives outside the install root: `%APPDATA%\Whispers\` (INI, logs, `history.tsv`), scratch in `%TEMP%\Whispers\`. Both the integration and installer suites back up and restore the real INI.

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues for `mmmansouri/whispers`, driven through the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its role name (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root, created lazily. See `docs/agents/domain.md`.
