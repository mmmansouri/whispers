#Requires AutoHotkey v2.0
#SingleInstance Force

; The pure core. These files define functions only - including them runs
; nothing - which is what lets the test runner load them in isolation.
#Include %A_LineFile%\..\lib\Text.ahk
#Include %A_LineFile%\..\lib\Config.ahk
#Include %A_LineFile%\..\lib\Tiers.ahk
#Include %A_LineFile%\..\lib\Devices.ahk
#Include %A_LineFile%\..\lib\Commands.ahk
#Include %A_LineFile%\..\lib\Net.ahk
#Include %A_LineFile%\..\lib\Install.ahk
#Include %A_LineFile%\..\lib\Indicator.ahk
#Include %A_LineFile%\..\lib\Tray.ahk

; =====================================================================
; Whispers - push-to-talk dictation powered by whisper.cpp
;
; Hold the hotkey, speak, release: the text lands in the focused window.
;
; Layout (all of it derived, nothing hard-coded to one machine):
;
;   <script dir>\            installation root, see ROOT_DIR
;     Whispers.ahk           this file
;     AutoHotkey64.exe       interpreter, shipped by the installer
;     versions.json          pinned dependency versions + SHA-256
;     bin\                   whisper-server.exe, whisper-cli.exe, *.dll,
;                            ffmpeg.exe - all fetched by the installer
;     models\                one ggml-*.bin, the tier in use
;
;   %APPDATA%\Whispers\      configuration, logs, history (per user)
;   %TEMP%\Whispers\         capture scratch files (never the repo root)
;
; Both bin\ and models\ can be relocated through the [Paths] section of
; the INI, which is what a development checkout uses to point at a local
; build instead of an installed one.
;
; Architecture notes:
;   * Recording is launched directly (ffmpeg via cmd), no PowerShell
;     middle man. That removes ~200-400 ms of process startup per press.
;   * Transcription goes through whisper-server over HTTP instead of
;     spawning whisper-cli, so the model stays resident in VRAM. The
;     server is warmed up while the user is still speaking, which hides
;     the model load entirely behind the recording.
;   * The server is unloaded after an idle period so it does not hold
;     several GB of VRAM hostage while the GPU is needed elsewhere.
;   * Every failure path reports the real cause and is written to the
;     log - never a bare "Transcription failed".
; =====================================================================

APP_NAME    := "Whispers"
APP_VERSION := "2.1.1"

; === Paths: root is wherever this script sits ===
ROOT_DIR   := A_ScriptDir
VER_FILE   := ROOT_DIR "\versions.json"

DATA_DIR   := EnvGet("APPDATA") "\" APP_NAME
INI_FILE   := DATA_DIR "\" APP_NAME ".ini"
LOG_DIR    := DATA_DIR "\logs"
HIST_FILE  := DATA_DIR "\history.tsv"

TEMP_DIR   := EnvGet("TEMP") "\" APP_NAME
TEMP_RAW   := TEMP_DIR "\capture.raw"
TEMP_WAV   := TEMP_DIR "\capture.wav"
TEMP_TXT   := TEMP_DIR "\capture.txt"

MIC_LOG    := LOG_DIR "\ffmpeg.log"
SRV_LOG    := LOG_DIR "\server.log"
CURL_LOG   := LOG_DIR "\curl.log"
DEV_LOG    := LOG_DIR "\devices.log"
GPU_LOG    := LOG_DIR "\gpu.log"
APP_LOG    := LOG_DIR "\whispers.log"

CURL_EXE   := A_WinDir "\System32\curl.exe"

; Filled in by ResolvePaths() once the INI has been read, because the
; [Paths] section may redirect them.
BIN_DIR    := ""
MODELS_DIR := ""
SERVER_EXE := ""
CLI_EXE    := ""
FFMPEG_EXE := ""

; === Runtime state ===
Cfg          := Map()
gRecording   := false
gPaused      := false
gBusy        := false
gStopping    := false
gRecStart    := ""
gRecMs       := 0       ; A_TickCount at the start of a capture
gFfmpegPid   := 0
gServerPid   := 0
gLastUse     := 0
gHistory     := []
gLogBuf      := []
gCurHotkey   := ""
gSettingsGui := ""
gCtl         := Map()
gHistView    := ""
gLogView     := ""
gReleaseTick := 0       ; A_TickCount when the dictation key went up
gTrayState   := "idle"  ; last SetState, for the menu's status line
gMenuFlush   := 0       ; uxtheme FlushMenuThemes, once the menu follows dark mode
; Indicator (see its section). Sizes are logical px; IndSurface scales.
IND_CANVAS_W := 600     ; widest pill (560) plus room for its glow
IND_MARGIN   := 26      ; above and below the pill, for glow and shadow
gInd          := ""
gIndG         := 0
gIndDC        := 0
gIndBmp       := 0
gIndScale     := 0
gIndPW        := 0
gIndPH        := 0
gIndX         := 0
gIndY         := 0
gIndFontTitle := 0
gIndFontSmall := 0
gIndFmt       := 0
gIndState     := ""
gIndTitle     := ""
gIndSub       := ""
gIndW         := 200
gIndV         := 0
gIndTargetW   := 200
gIndVisible   := false
gIndAlpha     := 0
gIndRecT0     := 0
gIndWarmT0    := 0
gIndLevels    := []
gIndLevelTick := 0
gIndKeyQpc    := 0
gGpu         := ""
gUpdate      := ""      ; Map(tag,url,sha256,name) once one is found
gDlCancel    := false
gWizard      := ""
gWizCtl      := ""
gWizEcho     := false
gFirstRun    := false

; === Bootstrap ===
try DirCreate(DATA_DIR)
try DirCreate(LOG_DIR)
try DirCreate(TEMP_DIR)

; Keep the log from growing without bound; checked once, at startup only.
try {
    if (FileExist(APP_LOG) && FileGetSize(APP_LOG) > 1048576)
        FileDelete(APP_LOG)
}

; Reap orphans from a previous instance, so "is a server running?" can be
; answered by a cheap process check instead of an HTTP probe.
if ProcessExist("whisper-server.exe")
    RunWait("taskkill /IM whisper-server.exe /F",, "Hide")

LoadConfig()

; Captured before microphone detection runs, because detection fills Mic
; in. An upgrade from a working installation must not be greeted by a
; setup window; a genuinely new install must not miss it.
gFirstRun := (!Cfg["Configured"] && Cfg["Mic"] = "")

ResolvePaths()
; Notifications are attributed to the process's AppUserModelID; the
; installer's Start menu shortcut carries the same one, which is what
; makes Windows title them "Whispers" with our icon, not "AutoHotkey".
DllCall("shell32\SetCurrentProcessExplicitAppUserModelID", "WStr", AppUserModelId())
CreateIndicator()
LoadHistory()
InitMenuTheme()
; The menu is rebuilt as it opens, so its status line and the model entry
; are never older than the click; and it follows a light/dark switch.
OnMessage(0x404, OnTrayNotify)
OnMessage(0x1A, OnSettingChange)
BuildTray()
SetTimer(CheckIdle, 30000)

LogMsg("INFO", APP_NAME " " APP_VERSION " started. Root=" ROOT_DIR)

; versions.json is what maps a tier onto a model file. Without it Whispers
; has nothing to load, so fail at startup where it can be explained rather
; than at the first key press where it cannot.
if (VerRead() = "") {
    LogMsg("ERROR", "versions.json missing or unreadable: " VER_FILE)
    MsgBox("versions.json is missing from:`n" ROOT_DIR "`n`n"
         . APP_NAME " cannot tell which model to load and will not transcribe.",
           APP_NAME, "Icon!")
} else {
    LogMsg("INFO", "Tier=" Cfg["Tier"] " (" TierFile(Cfg["Tier"]) ") Policy=" Cfg["VramPolicy"])
}

; A first run has no microphone yet. Resolve it BEFORE arming the hotkey:
; detection can take several seconds when it has to fall back to measuring
; levels, and a key press landing in that window used to fail with "No
; microphone configured" - telling the user to go and fix something that
; was about to fix itself.
if (Cfg["Mic"] = "") {
    LogMsg("INFO", "No microphone configured - running auto-detection")
    Notify("Detecting your microphone...", "This takes a few seconds, once.")
    picked := AutoDetectMic()
    if (picked != "") {
        Cfg["Mic"] := picked
        SaveConfig()
        LogMsg("INFO", "Microphone auto-selected: " picked)
    } else {
        LogMsg("WARN", "Auto-detection found no usable microphone")
    }
}

; From here on the hotkey is safe to press.
ApplyHotkey(Cfg["Hotkey"])
LogMsg("INFO", "Hotkey armed: " Cfg["Hotkey"])

if (Cfg["VramPolicy"] = "resident")
    StartServer("startup resident policy")

SetState("idle")
if (Cfg["PlaySounds"])
    SoundBeep(800, 100)
Notify(APP_NAME " is ready", "Hold " Cfg["Hotkey"] " to dictate in any app.")

if (gFirstRun) {
    LogMsg("INFO", "First run - showing the setup window")
    ShowFirstRun()
}

; Deferred, so a slow or unreachable network cannot delay startup, and
; one-shot (negative period), so it never runs again in this session.
SetTimer(CheckForUpdate, -8000)

LoadConfig() {
    global Cfg, INI_FILE
    Cfg := Map()
    for key, spec in ConfigSpec()
        Cfg[key] := IniRead(INI_FILE, spec[1], key, spec[2])

    ; Clamp on the way in, not only on the way out: the INI is a text file
    ; a user can edit, and a nonsensical value there must not be able to
    ; stop Whispers from starting.
    Cfg["Port"]        := SanitizePort(Cfg["Port"])
    Cfg["IdleMinutes"] := SanitizeIdleMinutes(Cfg["IdleMinutes"])
    Cfg["LoadTimeout"] := SanitizeLoadTimeout(Cfg["LoadTimeout"])
    Cfg["MinBytes"]    := SanitizeMinBytes(Cfg["MinBytes"])
    if !IsValidTier(Cfg["Tier"])
        Cfg["Tier"] := "balanced"
    if !IsValidPolicy(Cfg["VramPolicy"])
        Cfg["VramPolicy"] := "idle"
}

SaveConfig() {
    global Cfg, INI_FILE
    for key, spec in ConfigSpec()
        IniWrite(Cfg[key], INI_FILE, spec[1], key)
    LogMsg("INFO", "Settings saved")
}

; Turns the configured (or default) directories into absolute tool paths.
; Called after LoadConfig and again whenever [Paths] changes.
ResolvePaths() {
    global Cfg, ROOT_DIR, BIN_DIR, MODELS_DIR, SERVER_EXE, CLI_EXE, FFMPEG_EXE

    BIN_DIR    := ResolveDir(Cfg["BinDir"],    ROOT_DIR "\bin")
    MODELS_DIR := ResolveDir(Cfg["ModelsDir"], ROOT_DIR "\models")

    SERVER_EXE := BIN_DIR "\whisper-server.exe"
    CLI_EXE    := BIN_DIR "\whisper-cli.exe"

    ; ffmpeg is normally private to the installation. Falling back to the
    ; PATH keeps a development checkout usable before anything is fetched,
    ; and the log says which one is in play so a version mismatch is never
    ; a mystery.
    if FileExist(BIN_DIR "\ffmpeg.exe") {
        FFMPEG_EXE := BIN_DIR "\ffmpeg.exe"
    } else {
        FFMPEG_EXE := "ffmpeg"
        LogMsg("WARN", "bin\ffmpeg.exe missing - falling back to the ffmpeg on PATH")
    }
}

; =====================================================================
; versions.json
;
; Reads the pinned versions file once and caches it. The parsing itself
; lives in lib\Tiers.ahk, which takes the document as an argument so it
; can be tested against malformed input.
; =====================================================================
VerRead() {
    global VER_FILE
    static cache := ""
    if (cache != "")
        return cache
    if !FileExist(VER_FILE)
        return ""
    try cache := FileRead(VER_FILE, "UTF-8")
    return cache
}


; Returns "" when the tier cannot be resolved. Deliberately NOT falling
; back to some default model: silently loading a different model than the
; one selected is worse than refusing to start.
TierFile(tier) {
    f := TierFileFrom(VerRead(), tier)
    if (f = "")
        LogMsg("ERROR", "versions.json: cannot resolve tier '" tier "' - is the file present and intact?")
    return f
}

TierVram(tier) {
    return TierVramFrom(VerRead(), tier)
}

TierNeedsGpu(tier) {
    return TierNeedsGpuFrom(VerRead(), tier)
}


ModelPath() {
    global MODELS_DIR, Cfg
    f := TierFile(Cfg["Tier"])
    return f = "" ? "" : MODELS_DIR "\" f
}

ModelPathFor(tier) {
    global MODELS_DIR
    f := TierFile(tier)
    return f = "" ? "" : MODELS_DIR "\" f
}

ModelUrl(tier) {
    return ModelUrlFrom(VerRead(), tier)
}

ModelSha(tier) {
    return ModelShaFrom(VerRead(), tier)
}

ModelSize(tier) {
    return ModelSizeFrom(VerRead(), tier)
}

; =====================================================================
; Logging
; =====================================================================
LogMsg(level, msg) {
    global APP_LOG, gLogBuf
    stamp := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
    line  := stamp " [" level "] " msg
    gLogBuf.Push(line)
    if (gLogBuf.Length > 400)
        gLogBuf.RemoveAt(1)
    try FileAppend(line "`r`n", APP_LOG, "UTF-8")
    RefreshLogView()
}

; Reads the tail of a log file, for surfacing a real error message.
TailFile(path, maxChars := 400) {
    if !FileExist(path)
        return ""
    try {
        return TailText(FileRead(path, "UTF-8"), maxChars)
    } catch {
        return ""
    }
}


GetAudioDevices() {
    global FFMPEG_EXE, DEV_LOG, ROOT_DIR
    try FileDelete(DEV_LOG)
    RunWait(ShellCmd(CmdListDevices(FFMPEG_EXE, DEV_LOG)), ROOT_DIR, "Hide")
    if !FileExist(DEV_LOG)
        return []
    try {
        return ParseDshowAudioDevices(FileRead(DEV_LOG, "UTF-8"))
    } catch {
        return []
    }
}

; Records a short sample from one device and returns its mean level in dB
; (-91 means digital silence). Returns "" when the device cannot be opened.
MicLevel(device, seconds := 2) {
    global FFMPEG_EXE, TEMP_DIR, ROOT_DIR
    probe := TEMP_DIR "\miclevel.raw"
    plog  := TEMP_DIR "\miclevel.log"
    try FileDelete(probe)
    try FileDelete(plog)

    RunWait(ShellCmd(CmdMicLevel(FFMPEG_EXE, device, seconds, probe, plog)), ROOT_DIR, "Hide")

    if (!FileExist(probe) || FileGetSize(probe) < 1000)
        return ""
    level := ParseMeanVolume(TailFile(plog, 4000))
    try FileDelete(probe)
    return level
}

; Asks Windows which capture endpoint is the default one.
;
; This is the only deterministic answer available: measuring levels alone
; picks whatever is loudest, and on a machine with a virtual audio cable
; carrying program audio that is reliably the wrong device (measured: the
; cable at -25.9 dB beat the real microphone at -80.3 dB, because nobody
; was speaking during the probe).
;
; Costs about 0 ms - it is a property read, not a capture.
WindowsDefaultMic() {
    static CLSID_MMDeviceEnumerator := "{BCDE0395-E52F-467C-8E3D-C4579291692E}"
    static IID_IMMDeviceEnumerator  := "{A95664D2-9614-4F35-A746-DE8DB63617E6}"
    static PKEY_FriendlyName_FMTID  := "{a45c254e-df1c-4efd-8020-67d146a850e0}"
    static PKEY_FriendlyName_PID    := 14
    try {
        mmEnum := ComObject(CLSID_MMDeviceEnumerator, IID_IMMDeviceEnumerator)
        ; IMMDeviceEnumerator vtable: 0-2 IUnknown, 3 EnumAudioEndpoints,
        ; 4 GetDefaultAudioEndpoint(dataFlow, role, **device).
        ; dataFlow 1 = eCapture, role 0 = eConsole.
        if (ComCall(4, mmEnum, "Int", 1, "Int", 0, "Ptr*", &dev := 0) != 0)
            return ""
        ; IMMDevice vtable: 3 Activate, 4 OpenPropertyStore(access, **store).
        if (ComCall(4, dev, "Int", 0, "Ptr*", &store := 0) != 0) {
            ObjRelease(dev)
            return ""
        }
        key := Buffer(20, 0)
        DllCall("ole32\CLSIDFromString", "WStr", PKEY_FriendlyName_FMTID, "Ptr", key.Ptr)
        NumPut("Int", PKEY_FriendlyName_PID, key, 16)
        pv := Buffer(24, 0)
        name := ""
        ; IPropertyStore vtable: 3 GetCount, 4 GetAt, 5 GetValue(*key, *variant).
        if (ComCall(5, store, "Ptr", key.Ptr, "Ptr", pv.Ptr) = 0) {
            ptr := NumGet(pv, 8, "Ptr")
            if (ptr)
                name := StrGet(ptr, "UTF-16")
        }
        DllCall("ole32\PropVariantClear", "Ptr", pv.Ptr)
        ObjRelease(store)
        ObjRelease(dev)
        return name
    } catch {
        return ""
    }
}


; Picks a microphone without asking the user anything.
;
; Order matters: Windows' own default is authoritative and free, and only
; when it cannot be mapped to a dshow device do we fall back to measuring
; levels - which is a guess, and is logged as one.
AutoDetectMic() {
    devices := GetAudioDevices()
    if (devices.Length = 0) {
        LogMsg("ERROR", "No dshow audio device found - is ffmpeg present?")
        return ""
    }

    winDefault := WindowsDefaultMic()
    if (winDefault != "") {
        matched := MatchDevice(winDefault, devices)
        if (matched != "") {
            LogMsg("INFO", "Using the Windows default capture device: " matched)
            return matched
        }
        LogMsg("WARN", "Windows default '" winDefault "' has no dshow equivalent - measuring instead")
    } else {
        LogMsg("WARN", "Could not read the Windows default capture device - measuring instead")
    }

    if (devices.Length = 1)
        return devices[1]

    best := ""
    bestLevel := -1000
    for dev in devices {
        if IsVirtualDevice(dev) {
            LogMsg("DEBUG", "Mic probe: " dev " -> skipped (virtual device)")
            continue
        }
        lvl := MicLevel(dev, 2)
        if (lvl = "") {
            LogMsg("DEBUG", "Mic probe: " dev " -> unavailable")
            continue
        }
        LogMsg("DEBUG", "Mic probe: " dev " -> " lvl " dB")
        if (lvl > bestLevel) {
            bestLevel := lvl
            best := dev
        }
    }

    ; Every device measuring as digital silence means the probe learned
    ; nothing at all, which is different from a quiet room. Say so instead
    ; of presenting a guess as a measurement.
    if (best = "" || IsSilentLevel(bestLevel)) {
        LogMsg("WARN", "No microphone carried any signal - defaulting to " devices[1])
        return devices[1]
    }
    LogMsg("WARN", "Microphone chosen by level only (" bestLevel " dB) - verify it in Settings")
    return best
}

; =====================================================================
; GPU detection
;
; The driver reports the highest CUDA runtime it supports, which is the
; only number that matters for picking an engine build. Reading it beats
; hard-coding a driver-version table that would silently rot.
; =====================================================================
GpuInfo(refresh := false) {
    global gGpu, GPU_LOG, ROOT_DIR
    if (!refresh && IsObject(gGpu))
        return gGpu

    info := Map("present", false, "name", "", "vramTotal", 0, "vramFree", -1, "cudaMax", "")

    try FileDelete(GPU_LOG)
    RunWait(ShellCmd(CmdGpuSummary(GPU_LOG)), ROOT_DIR, "Hide")
    if FileExist(GPU_LOG) {
        try {
            parts := StrSplit(StrSplit(Trim(FileRead(GPU_LOG)), "`n", "`r")[1], ",")
            if (parts.Length >= 3 && IsInteger(Trim(parts[2]))) {
                info["present"]   := true
                info["name"]      := Trim(parts[1])
                info["vramTotal"] := Integer(Trim(parts[2]))
                info["vramFree"]  := Integer(Trim(parts[3]))
            }
        }
    }

    if (info["present"]) {
        try FileDelete(GPU_LOG)
        RunWait(ShellCmd(CmdGpuFull(GPU_LOG)), ROOT_DIR, "Hide")
        if FileExist(GPU_LOG) {
            try {
                if RegExMatch(FileRead(GPU_LOG), "CUDA Version\s*:\s*([\d.]+)", &m)
                    info["cudaMax"] := m[1]
            }
        }
    }

    gGpu := info
    return info
}

FreeVramMB() {
    return GpuInfo(true)["vramFree"]
}

; The tier this machine should run, shown as a suggestion in the settings
; window. The thresholds themselves live in lib\Tiers.ahk.
RecommendedTier() {
    g := GpuInfo()
    return RecommendTier(g["present"], g["vramTotal"])
}

ServerAlive() {
    global CURL_EXE, Cfg, ROOT_DIR
    return RunWait(ShellCmd(CmdServerAlive(CURL_EXE, Cfg["Port"])), ROOT_DIR, "Hide") = 0
}

StartServer(reason := "?") {
    global SERVER_EXE, Cfg, SRV_LOG, ROOT_DIR, gServerPid

    ; Process check only - no HTTP probe here. A server that is still
    ; loading the model does not answer HTTP yet, and every probe costs a
    ; cmd+curl spawn that keeps this thread interruptible for longer.
    ; Orphans from a previous run are reaped at startup, so any live
    ; whisper-server process is one of ours.
    if ProcessExist("whisper-server.exe") {
        LogMsg("DEBUG", "StartServer(" reason ") skipped - already running/loading")
        return true
    }

    if !FileExist(SERVER_EXE) {
        LogMsg("ERROR", "whisper-server.exe not found at " SERVER_EXE)
        return false
    }

    model := ModelPath()
    if (model = "") {
        LogMsg("ERROR", "Tier '" Cfg["Tier"] "' could not be resolved from versions.json")
        return false
    }
    if !FileExist(model) {
        LogMsg("ERROR", "Model for tier '" Cfg["Tier"] "' not found: " model)
        return false
    }

    ; No VRAM probe here on purpose: it is advisory only, and nvidia-smi is
    ; another blocking spawn on the latency-critical path. The number is
    ; reported instead when the server actually fails to come up, and in the
    ; Engine tab of the settings window.
    try FileDelete(SRV_LOG)
    Run(ShellCmd(CmdServer(SERVER_EXE, model, Cfg["Language"], Cfg["Port"], SRV_LOG)), ROOT_DIR, "Hide", &pid)
    gServerPid := pid
    LogMsg("INFO", "Server starting via " reason " (pid " pid ", port " Cfg["Port"] ", tier " Cfg["Tier"] ")")
    return true
}

StopServer(reason := "manual") {
    global gServerPid
    killed := false
    if (gServerPid) {
        RunWait("taskkill /PID " gServerPid " /T /F",, "Hide")
        gServerPid := 0
        killed := true
    }
    if ProcessExist("whisper-server.exe") {
        RunWait("taskkill /IM whisper-server.exe /F",, "Hide")
        killed := true
    }
    if (killed)
        LogMsg("INFO", "Server stopped (" reason ") - VRAM released")
    SetState(gPausedState())
    return killed
}

; Blocks until the server answers or the timeout expires.
EnsureServerReady() {
    global Cfg, SRV_LOG
    if ServerAlive()
        return true
    if !StartServer("transcribe")
        return false

    budget   := Integer(Cfg["LoadTimeout"]) * 1000
    started  := A_TickCount
    deadline := started + budget
    while (A_TickCount < deadline) {
        if ServerAlive()
            return true
        if !ProcessExist("whisper-server.exe") {
            ; This is where a VRAM shortage actually shows up, so spend the
            ; nvidia-smi call here rather than on the fast path.
            detail := TailFile(SRV_LOG)
            hint := InStr(detail, "out of memory")
                ? "GPU out of memory (" FreeVramMB() " MiB free). Close GPU-heavy apps, drop to a smaller tier, or let it fall back to CPU. "
                : ""
            LogMsg("ERROR", "Server died while loading. " hint detail)
            return false
        }
        IndWarm()
        Sleep(400)
    }
    LogMsg("ERROR", "Server did not answer within " Cfg["LoadTimeout"] "s. " TailFile(SRV_LOG))
    return false
}

CheckIdle() {
    global Cfg, gLastUse, gRecording, gBusy
    if (Cfg["VramPolicy"] != "idle")
        return
    if (gRecording || gBusy || !gLastUse)
        return
    idleMs := Integer(Cfg["IdleMinutes"]) * 60000
    if (A_TickCount - gLastUse > idleMs && ServerAlive())
        StopServer("idle " Cfg["IdleMinutes"] " min")
}

; =====================================================================
; Recording
; =====================================================================
StartRec(keyQpc := 0) {
    global Cfg, gRecording, gPaused, gBusy, gStopping, gRecStart, gRecMs
    global gFfmpegPid, TEMP_RAW, TEMP_WAV, TEMP_TXT, MIC_LOG, ROOT_DIR, FFMPEG_EXE

    ; gStopping closes the window between "gRecording := false" and the end
    ; of StopRec: a key auto-repeat landing there would otherwise start a
    ; phantom recording that deletes the WAV being transcribed.
    if (gPaused || gRecording || gBusy || gStopping)
        return

    if (Cfg["Mic"] = "") {
        Fail("No microphone configured", "Open Settings and pick one, or restart to re-run detection.")
        return
    }

    ; AHK threads are interruptible at every RunWait/Sleep/SoundBeep. Without
    ; Critical, the matching key-up fires StopRec in the middle of this
    ; function, and StartRec then resumes its tail *after* the transcription
    ; has already finished - re-arming state that StopRec just cleared.
    Critical("On")
    ; The device is logged because nothing else says which one actually
    ; recorded: a capture from the wrong microphone succeeds, and only
    ; shows up as whisper inventing text over silence.
    LogMsg("DEBUG", "StartRec mic=" Cfg["Mic"])

    ; Before anything slow: the pill is the user's proof the key worked.
    IndListen(keyQpc)

    ; Kill any leftover recorder BEFORE starting a new one, and block on
    ; it: an asynchronous taskkill lands a few hundred ms later and
    ; silently murders the recorder we are about to spawn.
    KillRecorder()

    ; Remove every stale artefact so a failed capture can never be
    ; re-transcribed and pasted a second time.
    try FileDelete(TEMP_RAW)
    try FileDelete(TEMP_WAV)
    try FileDelete(TEMP_TXT)
    try FileDelete(MIC_LOG)

    gRecStart := A_Now
    gRecMs := A_TickCount

    if (Cfg["PlaySounds"])
        SoundBeep(1500, 120)

    Run(ShellCmd(CmdRecord(FFMPEG_EXE, Cfg["Mic"], TEMP_RAW, MIC_LOG)), ROOT_DIR, "Hide", &pid)
    gFfmpegPid := pid

    gRecording := true
    SetState("rec")

    ; Warm the model up while the user is still speaking, so the load time
    ; is hidden behind the recording instead of added to it. Deferred to its
    ; own thread: probing the server costs a RunWait, and doing that inline
    ; would keep StartRec alive long enough to be interrupted by the key-up.
    SetTimer(WarmUpServer, -50)
    Critical("Off")
}

; Runs on its own thread, shortly after recording starts. Critical so the
; key-up cannot interrupt it half way and resume it after the transcription.
WarmUpServer() {
    global Cfg, gRecording
    if (!gRecording || Cfg["VramPolicy"] = "never")
        return
    Critical("On")
    StartServer("recording warmup")
    Critical("Off")
}

KillRecorder() {
    global gFfmpegPid
    if (gFfmpegPid) {
        RunWait("taskkill /PID " gFfmpegPid " /T /F",, "Hide")
        gFfmpegPid := 0
    } else if ProcessExist("ffmpeg.exe") {
        RunWait("taskkill /IM ffmpeg.exe /F",, "Hide")
    }
}

; Returns true only when a fresh WAV is ready to transcribe.
StopRec() {
    global Cfg, gRecording, gStopping, gRecMs, gReleaseTick, TEMP_RAW, TEMP_WAV, MIC_LOG, ROOT_DIR, FFMPEG_EXE

    if !gRecording
        return false

    ; Same reasoning as StartRec: the state transition must be atomic.
    ; Critical is lifted again before the slow part (file checks and the
    ; ffmpeg conversion), so the tray and timers stay responsive.
    Critical("On")
    gStopping := true
    gReleaseTick := A_TickCount
    LogMsg("DEBUG", "StopRec")
    if (Cfg["PlaySounds"])
        SoundBeep(800, 120)

    KillRecorder()
    Sleep(150)
    gRecording := false
    Critical("Off")

    if !FileExist(TEMP_RAW) {
        ; No file can mean a broken device, or a press too short for
        ; ffmpeg to have opened one. Only the clock separates them, and
        ; telling someone their microphone failed when they tapped the
        ; key sends them hunting for a fault that is not there.
        if CaptureTooShort(A_TickCount - gRecMs)
            Fail("Too short - hold " Cfg["Hotkey"] " down while you speak", "")
        else
            Fail("Mic capture failed: " Cfg["Mic"], TailFile(MIC_LOG, 220))
        gStopping := false
        return false
    }

    rawSize := FileGetSize(TEMP_RAW)
    if (rawSize < Integer(Cfg["MinBytes"])) {
        Fail("Too short (" RawBytesToSeconds(rawSize) "s) - hold the key while speaking", "")
        gStopping := false
        return false
    }

    IndWork("Transcribing...")

    RunWait(ShellCmd(CmdConvert(FFMPEG_EXE, TEMP_RAW, TEMP_WAV, MIC_LOG, Cfg["TrimSilence"])), ROOT_DIR, "Hide")

    if !FileExist(TEMP_WAV) {
        Fail("WAV conversion failed", TailFile(MIC_LOG, 220))
        gStopping := false
        return false
    }
    gStopping := false
    return true
}

; =====================================================================
; Transcription
; =====================================================================
Transcribe() {
    global Cfg, TEMP_WAV, TEMP_TXT, gRecStart, gBusy, gLastUse

    if !FileExist(TEMP_WAV) {
        Fail("No audio file produced", "")
        return
    }

    ; Never transcribe audio that predates the current recording.
    if (DateDiff(FileGetTime(TEMP_WAV, "M"), gRecStart, "Seconds") < 0) {
        Fail("Stale audio - the capture did not run", "")
        return
    }

    LogMsg("DEBUG", "Transcribe begin")
    gBusy := true
    SetState("work")
    IndWork("Transcribing...")
    try FileDelete(TEMP_TXT)

    text := ""
    if (Cfg["VramPolicy"] = "never") {
        text := TranscribeViaCli(false)
    } else {
        if EnsureServerReady() {
            IndWork("Transcribing...")      ; after a warm-up
            text := TranscribeViaServer()
        }
        if (text = "" && Cfg["CpuFallback"]) {
            LogMsg("WARN", "Server path failed, falling back to whisper-cli")
            IndWork("Transcribing...", "GPU busy - using the CPU")
            text := TranscribeViaCli(true)
        }
    }

    gBusy := false
    gLastUse := A_TickCount

    if (text = "")
        return              ; the failing branch already reported why

    DeliverText(text)
}

TranscribeViaServer() {
    global CURL_EXE, Cfg, TEMP_WAV, TEMP_TXT, CURL_LOG, SRV_LOG, ROOT_DIR

    try FileDelete(CURL_LOG)

    t0 := A_TickCount
    ec := RunWait(ShellCmd(CmdInference(CURL_EXE, Cfg["Port"], TEMP_WAV, Cfg["Language"], TEMP_TXT, CURL_LOG)), ROOT_DIR, "Hide")
    ms := A_TickCount - t0

    if (ec != 0) {
        Fail("Transcription request failed (curl " ec ")", TailFile(CURL_LOG, 200))
        return ""
    }
    if !FileExist(TEMP_TXT) {
        Fail("Server returned nothing", TailFile(SRV_LOG, 200))
        return ""
    }

    text := Trim(FileRead(TEMP_TXT, "UTF-8"))
    if (text = "") {
        Warn("No speech detected")
        return ""
    }
    LogMsg("INFO", "Transcribed via server in " ms " ms (" StrLen(text) " chars)")
    return text
}

TranscribeViaCli(forceCpu) {
    global CLI_EXE, Cfg, TEMP_WAV, TEMP_TXT, ROOT_DIR, SRV_LOG

    if !FileExist(CLI_EXE) {
        Fail("whisper-cli.exe not found", CLI_EXE)
        return ""
    }
    model := ModelPath()
    if !FileExist(model) {
        Fail("Model for tier '" Cfg["Tier"] "' not found", model)
        return ""
    }
    base := SubStr(TEMP_TXT, 1, StrLen(TEMP_TXT) - 4)

    try FileDelete(TEMP_TXT)

    t0 := A_TickCount
    ec := RunWait(ShellCmd(CmdCli(CLI_EXE, model, Cfg["Language"], forceCpu, base, TEMP_WAV, SRV_LOG)), ROOT_DIR, "Hide")
    ms := A_TickCount - t0

    if !FileExist(TEMP_TXT) {
        detail := TailFile(SRV_LOG, 260)
        hint := InStr(detail, "out of memory") ? "GPU out of memory - free VRAM or drop to a smaller tier. " : ""
        Fail("Transcription failed (exit " ec ")", hint detail)
        return ""
    }

    text := Trim(FileRead(TEMP_TXT, "UTF-8"))
    if (text = "") {
        Warn("No speech detected")
        return ""
    }
    LogMsg("INFO", "Transcribed via cli" (forceCpu ? " (CPU)" : "") " in " ms " ms")
    return text
}

DeliverText(text) {
    global Cfg, gWizEcho, gWizCtl, gReleaseTick
    done := DoneSubline(WordCount(text), A_TickCount - gReleaseTick)

    ; While the setup window is open the transcription is shown there and
    ; goes nowhere else. The user is testing their microphone, not
    ; dictating into whatever window happens to be behind it.
    if (gWizEcho) {
        try gWizCtl["Heard"].Value := text
        AddHistory(text)
        if (Cfg["PlaySounds"])
            SoundBeep(1000, 60)
        IndDone("Heard you", done)
        SetState(gPausedState())
        return
    }

    A_Clipboard := ""
    A_Clipboard := text
    if !ClipWait(2) {
        Fail("Could not place text on the clipboard", "")
        return
    }

    if (Cfg["AutoPaste"]) {
        Send("^v")
        Sleep(120)
    }

    AddHistory(text)
    if (Cfg["PlaySounds"])
        SoundBeep(1000, 60)

    IndDone(Cfg["AutoPaste"] ? "Pasted" : "Copied to the clipboard", done)
    ; The pill already says it; the toast is for those who turned it off.
    if !Cfg["ShowIndicator"] {
        preview := PreviewText(text)
        QuietTip(Cfg["AutoPaste"] ? "Pasted: " preview : "Copied: " preview, 2200)
    }
    SetState(gPausedState())
}

; =====================================================================
; Downloads
;
; Everything fetched after installation goes through FetchVerified, and
; it holds one rule: nothing is ever written to its final name until its
; SHA-256 matches what was expected.
;
; The download lands on a .part file. A half-written model that looks
; installed is worse than no model at all - it fails at the first key
; press, with an error about the engine rather than about the download.
; =====================================================================
FetchVerified(url, destPath, expectedSha, label, approxBytes := 0) {
    global CURL_EXE, TEMP_DIR, gBusy, gDlCancel

    if (url = "") {
        Fail("Cannot fetch " label, "No download URL - versions.json may be damaged.")
        return false
    }
    ; Refusing here rather than downloading something unverifiable is the
    ; whole point: an empty expected hash would make any response valid.
    if (expectedSha = "") {
        Fail("Cannot fetch " label, "No expected SHA-256 - refusing an unverifiable download.")
        return false
    }

    part := destPath ".part"
    dlog := TEMP_DIR "\download.log"
    hlog := TEMP_DIR "\hash.log"
    try DirCreate(RegExReplace(destPath, "\\[^\\]+$", ""))
    try FileDelete(dlog)

    LogMsg("INFO", "Fetching " label " -> " url)
    gBusy := true
    gDlCancel := false
    ui := DlWindow(label)

    pid := 0
    try {
        Run(CmdFetch(CURL_EXE, url, part, dlog), TEMP_DIR, "Hide", &pid)
    } catch as e {
        DlClose(ui)
        gBusy := false
        Fail("Cannot start the download", e.Message)
        return false
    }

    while ProcessExist(pid) {
        Sleep(250)
        if (gDlCancel) {
            try ProcessClose(pid)
            Sleep(300)
            DlClose(ui)
            gBusy := false
            LogMsg("INFO", "Download cancelled by the user: " label)
            Notify("Download cancelled")
            return false
        }
        DlProgress(ui, FileExist(part) ? FileGetSize(part) : 0, approxBytes)
    }

    DlProgress(ui, FileExist(part) ? FileGetSize(part) : 0, approxBytes)
    DlSay(ui, "Verifying...")

    if !FileExist(part) {
        DlClose(ui)
        gBusy := false
        Fail("Download failed: " label, TailText(TailFile(dlog, 600), 200))
        return false
    }

    ; The hash is checked whatever curl's exit code was. A resumed
    ; download can end on an HTTP 416 - "you already have all of it" -
    ; which is an error to curl and a success to us.
    try FileDelete(hlog)
    RunWait(ShellCmd(CmdHashFile(part, hlog)), TEMP_DIR, "Hide")
    actual := ""
    try actual := ParseCertutilHash(FileRead(hlog))

    if !HashMatches(expectedSha, actual) {
        try FileDelete(part)
        DlClose(ui)
        gBusy := false
        LogMsg("ERROR", "SHA-256 mismatch for " label ": expected " expectedSha ", got " (actual = "" ? "nothing" : actual))
        Fail("Download rejected: " label, "The file does not match its expected SHA-256 and was deleted.")
        return false
    }

    try FileDelete(destPath)
    try FileMove(part, destPath, 1)
    DlClose(ui)
    gBusy := false
    LogMsg("INFO", "Fetched and verified " label " -> " destPath)
    return FileExist(destPath) ? true : false
}

DlWindow(label) {
    global APP_NAME
    g := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", APP_NAME " - downloading")
    g.SetFont("s9", "Segoe UI")
    g.Add("Text", "xm w430", label)
    pbar := g.Add("Progress", "xm y+8 w430 h18 Range0-1000")
    info := g.Add("Text", "xm y+8 w430", "Starting...")
    g.Add("Button", "xm y+10 w110", "Cancel").OnEvent("Click", (*) => CancelDownload())
    g.OnEvent("Close", (*) => CancelDownload())
    g.Show()
    return Map("gui", g, "bar", pbar, "info", info)
}

CancelDownload() {
    global gDlCancel
    gDlCancel := true
}

DlSay(ui, msg) {
    try ui["info"].Value := msg
}

DlProgress(ui, got, total) {
    mb := Round(got / 1048576)
    if (total > 0) {
        pos := Round(got / total * 1000)
        try ui["bar"].Value := pos > 1000 ? 1000 : pos
        DlSay(ui, mb " of " Round(total / 1048576) " MB")
    } else {
        DlSay(ui, mb " MB")
    }
}

DlClose(ui) {
    try ui["gui"].Destroy()
}

; True when the tier's model is on disk, fetching it first if the user
; agrees. This is what makes switching tier in the settings window a
; complete action rather than advice to go and find a file.
EnsureModelInstalled(tier, ask := true) {
    global APP_NAME
    file := TierFile(tier)
    if (file = "")
        return false
    path := ModelPathFor(tier)
    if FileExist(path)
        return true

    size := ModelSize(tier)
    mb := size > 0 ? " (" Round(size / 1048576) " MB)" : ""
    if (ask) {
        if (MsgBox("The '" tier "' tier needs " file mb ", which is not installed.`n`n"
                 . "Download it now?", APP_NAME, "YesNo Icon?") != "Yes")
            return false
    }
    return FetchVerified(ModelUrl(tier), path, ModelSha(tier), "Model " file, size)
}

; Called once a tier change is committed and its model is on disk. A
; change used to leave the previous model behind - 3 GB for max - so
; disk use grew with every change, against what the README promises.
; Only in Whispers' own models\ directory, and only files versions.json
; names (see OtherTierFiles and UsesDefaultDir).
PruneOtherModels() {
    global Cfg, MODELS_DIR
    if !UsesDefaultDir(Cfg["ModelsDir"]) {
        LogMsg("INFO", "Models directory is overridden - previous models left in place")
        return
    }
    for f in OtherTierFiles(VerRead(), Cfg["Tier"]) {
        p := MODELS_DIR "\" f
        if !FileExist(p)
            continue
        try {
            FileDelete(p)
            LogMsg("INFO", "Removed the model of a previous tier: " f)
        } catch as e {
            LogMsg("WARN", "Could not remove " p ": " e.Message)
        }
    }
}

; Keeps the size in "Installed apps" true after a model was added or
; removed. Only for the installation Windows has registered: a
; development checkout must not rewrite the entry of the installed copy.
UpdateInstalledSize() {
    global ROOT_DIR
    key := UninstallKey()
    loc := ""
    try {
        loc := RegRead(key, "InstallLocation")
    } catch {
        return
    }
    if !SameDir(loc, ROOT_DIR)
        return
    bytes := 0
    Loop Files, ROOT_DIR "\*", "FR"
        bytes += A_LoopFileSize
    try {
        RegWrite(KbFromBytes(bytes), "REG_DWORD", key, "EstimatedSize")
        LogMsg("INFO", "Installed size recorded: " Round(bytes / 1048576) " MB")
    } catch as e {
        LogMsg("WARN", "Could not record the installed size: " e.Message)
    }
}

; =====================================================================
; Updates
;
; Checked once at startup, never installed without a click. What the
; check sends is a plain GET to the GitHub releases API: no identifier,
; no configuration, nothing about the machine.
;
; The hash used here is NOT a pin. A release that does not exist yet
; cannot have its hash written into versions.json, so the digest comes
; from the same API response as the URL. It proves the download arrived
; intact; it does not prove who built it. README.md says so in the same
; words.
; =====================================================================
CheckForUpdate(*) {
    global Cfg, TEMP_DIR, CURL_EXE, APP_VERSION, gUpdate

    if (!Cfg["CheckUpdates"]) {
        LogMsg("INFO", "Update check skipped: turned off in settings")
        return
    }
    api := ReleaseApiUrl(UpdateRepoFrom(VerRead()))
    if (api = "") {
        LogMsg("INFO", "Update check skipped: versions.json names no repository")
        return
    }

    dest := TEMP_DIR "\release.json"
    dlog := TEMP_DIR "\release.log"
    try FileDelete(dest)
    RunWait(ShellCmd(CmdFetchJson(CURL_EXE, api, dest, dlog)), TEMP_DIR, "Hide")
    if !FileExist(dest) {
        LogMsg("INFO", "Update check: no answer from " api)
        return
    }

    json := ""
    try json := FileRead(dest, "UTF-8")
    if !IsPublishedRelease(json) {
        LogMsg("INFO", "Update check: no published release")
        return
    }

    tag := ReleaseTagFrom(json)
    if !IsNewerVersion(APP_VERSION, tag) {
        LogMsg("INFO", "Up to date (" APP_VERSION ", latest published is " tag ")")
        return
    }

    asset := ReleaseAssetFrom(json, UpdateAssetSuffixFrom(VerRead()))
    if (asset["url"] = "" || asset["sha256"] = "") {
        LogMsg("WARN", "Release " tag " has no installer asset with a digest - not offering it")
        return
    }

    gUpdate := Map("tag", NormalizeVersion(tag), "url", asset["url"],
                   "sha256", asset["sha256"], "name", asset["name"])
    LogMsg("INFO", "Update available: " tag " (" asset["name"] ")")
    BuildTray()
    Notify("Whispers " NormalizeVersion(tag) " is ready to install", "Right-click the tray icon and choose Update.")
}

InstallUpdate(*) {
    global gUpdate, TEMP_DIR, APP_NAME, APP_VERSION
    if !IsObject(gUpdate)
        return

    dest := TEMP_DIR "\" gUpdate["name"]
    if !FetchVerified(gUpdate["url"], dest, gUpdate["sha256"],
                      "Whispers " gUpdate["tag"] " installer", 0)
        return

    if (MsgBox("Whispers " gUpdate["tag"] " has been downloaded and its checksum matches.`n`n"
             . APP_NAME " will now close and the installer will start.`n"
             . "Your settings, history and model are kept.", APP_NAME, "OKCancel Icon?") != "OK") {
        LogMsg("INFO", "Update downloaded but not installed - user cancelled")
        return
    }

    LogMsg("INFO", "Installing update " gUpdate["tag"] " from " dest)
    try Run('"' dest '"')
    ExitApp()
}

; =====================================================================
; User feedback
; =====================================================================
Fail(msg, detail) {
    global Cfg
    LogMsg("ERROR", msg (detail != "" ? " | " detail : ""))
    IndError(msg, detail)
    if (Cfg["PlaySounds"])
        SoundBeep(300, 250)
    ; The pill shows it where the user is looking; the full detail is in
    ; the log. Without the pill, a notification is the only trace.
    if !Cfg["ShowIndicator"]
        Notify(msg, detail)
    SetState(gPausedState())
}

Warn(msg) {
    global Cfg
    LogMsg("WARN", msg)
    IndWarn(msg)
    if !Cfg["ShowIndicator"]
        Notify(msg)
    SetState(gPausedState())
}

; A Windows notification, silent: Whispers never makes a sound the user
; did not ask for with PlaySounds. Option 4 shows the tray icon in it.
Notify(title, text := "") {
    TrayTip(text = "" ? " " : text, title, 4 | 16)
}

; A tooltip by the cursor. Only for the one message that would otherwise
; become a notification per dictation - "Pasted" when the indicator is
; turned off - which would bury the notification centre.
QuietTip(msg, duration := 2000) {
    ToolTip(msg)
    SetTimer(() => ToolTip(), -duration)
}

; =====================================================================
; Indicator: the glass pill above the taskbar (ADR-0002)
;
; A layered window that GDI+ draws with per-pixel alpha. There is no
; backdrop blur on purpose: DWM's acrylic fills the whole window
; rectangle whatever its shape (measured, see the ADR), so the glass is
; a dense tint with a highlight and a rim instead.
;
; The window is created per-monitor DPI aware, so it draws at physical
; pixels on every monitor instead of being bitmap-stretched by Windows.
; Its frame timer runs only while the pill is on screen or fading out,
; and the window is hidden in between: a visible topmost window, even a
; transparent one, can knock a fullscreen game out of its fast path.
; =====================================================================
CreateIndicator() {
    global gInd, gIndFontTitle, gIndFontSmall, gIndFmt, APP_NAME
    DllCall("LoadLibrary", "Str", "gdiplus", "Ptr")
    si := Buffer(24, 0)
    NumPut("UInt", 1, si)
    if DllCall("gdiplus\GdiplusStartup", "Ptr*", &tok := 0, "Ptr", si, "Ptr", 0) {
        LogMsg("WARN", "GDI+ did not start - no on-screen indicator")
        return
    }
    old := DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
    ; WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE: click-through,
    ; and never takes the focus away from where the text is going.
    gInd := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x80000 +E0x20 +E0x08000000", APP_NAME "Indicator")
    if (old)
        DllCall("SetThreadDpiAwarenessContext", "Ptr", old, "Ptr")
    gIndFontTitle := GpFont("Segoe UI Semibold", 14)
    gIndFontSmall := GpFont("Segoe UI", 12)
    DllCall("gdiplus\GdipCreateStringFormat", "Int", 0x1000, "UShort", 0, "Ptr*", &fmt := 0)   ; NoWrap
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", fmt, "Int", 1)
    DllCall("gdiplus\GdipSetStringFormatTrimming", "Ptr", fmt, "Int", 3)                       ; ellipsis
    gIndFmt := fmt
}

; --- what the rest of the script calls ------------------------------

; Shown first thing on key-down, before the recorder is even spawned.
IndListen(keyQpc := 0) {
    global gIndRecT0, gIndLevels, gIndLevelTick, gIndKeyQpc
    gIndRecT0 := A_TickCount
    gIndLevels := []
    ; Not sampled before 50 ms: until StartRec has deleted it, the capture
    ; on disk is the previous dictation's.
    gIndLevelTick := A_TickCount
    gIndKeyQpc := keyQpc
    IndSetState("listen", "", "", true)
}

IndWarm() {
    global gIndWarmT0, gIndState
    if (gIndState != "warm")
        gIndWarmT0 := A_TickCount
    IndSetState("warm", "Waking up the model", "")
}

IndWork(title, sub := "") => IndSetState("work", title, sub)

IndDone(title, sub) {
    IndSetState("done", title, sub)
    SetTimer(IndHide, -1400)
}

IndError(msg, detail) {
    IndSetState("error", msg, ErrorSubline(detail))
    SetTimer(IndHide, -4500)
}

IndWarn(msg) {
    IndSetState("warn", msg, "")
    SetTimer(IndHide, -2500)
}

IndHide() {
    global gIndVisible
    gIndVisible := false
}

; --- state and placement --------------------------------------------

IndSetState(state, title, sub, place := false) {
    global gInd, Cfg, gIndState, gIndTitle, gIndSub, gIndTargetW, gIndW, gIndV
    global gIndVisible, gIndAlpha, gIndG
    if (!gInd || !Cfg["ShowIndicator"])
        return
    ; A new state cancels the hide a previous one scheduled, or a failure
    ; shown 4 s ago would whisk away the pill of the next dictation.
    SetTimer(IndHide, 0)
    wasHidden := !gIndVisible && gIndAlpha = 0
    if (place || wasHidden)
        IndPlace()
    gIndState := state
    gIndTitle := title
    gIndSub := sub
    textW := Max(GpMeasure(title, gIndFontTitle), GpMeasure(sub, gIndFontSmall))
    gIndTargetW := IndicatorFitWidth(state, textW)
    if (wasHidden) {
        ; Appears at its final width; only changes of state morph.
        gIndW := gIndTargetW
        gIndV := 0
    }
    gIndVisible := true
    if wasHidden
        gInd.Show("NA")
    IndFrame()
    SetTimer(IndFrame, 15)
}

; Puts the pill on the monitor the user is working on, and rebuilds the
; drawing surface when that monitor has a different scale.
IndPlace() {
    global gInd, gIndX, gIndY, gIndScale, gIndPW, gIndPH, IND_CANVAS_W, IND_MARGIN
    old := DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
    hmon := DllCall("MonitorFromWindow", "Ptr", DllCall("GetForegroundWindow", "Ptr"), "UInt", 2, "Ptr")
    mi := Buffer(40, 0)
    NumPut("UInt", 40, mi)
    DllCall("GetMonitorInfoW", "Ptr", hmon, "Ptr", mi)
    dpi := 96
    try DllCall("shcore\GetDpiForMonitor", "Ptr", hmon, "Int", 0, "UInt*", &dpi, "UInt*", &dpiY := 0)
    if (old)
        DllCall("SetThreadDpiAwarenessContext", "Ptr", old, "Ptr")
    scale := dpi / 96
    if (scale != gIndScale)
        IndSurface(scale)
    at := IndicatorAnchor(NumGet(mi, 20, "Int"), NumGet(mi, 28, "Int"), NumGet(mi, 32, "Int"), gIndPW, gIndPH, scale)
    gIndX := at[1]
    gIndY := at[2]
}

IndSurface(scale) {
    global gIndScale, gIndPW, gIndPH, gIndDC, gIndBmp, gIndG, IND_CANVAS_W, IND_MARGIN
    if (gIndG) {
        DllCall("gdiplus\GdipDeleteGraphics", "Ptr", gIndG)
        DllCall("DeleteObject", "Ptr", gIndBmp)
        DllCall("DeleteDC", "Ptr", gIndDC)
    }
    gIndScale := scale
    gIndPW := Round(IND_CANVAS_W * scale)
    gIndPH := Round((IndicatorHeight() + 2 * IND_MARGIN) * scale)
    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0), NumPut("Int", gIndPW, bi, 4), NumPut("Int", -gIndPH, bi, 8)
    NumPut("UShort", 1, bi, 12), NumPut("UShort", 32, bi, 14)
    screen := DllCall("GetDC", "Ptr", 0, "Ptr")
    gIndDC := DllCall("CreateCompatibleDC", "Ptr", screen, "Ptr")
    gIndBmp := DllCall("CreateDIBSection", "Ptr", gIndDC, "Ptr", bi, "UInt", 0, "Ptr*", &bits := 0, "Ptr", 0, "UInt", 0, "Ptr")
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", screen)
    DllCall("SelectObject", "Ptr", gIndDC, "Ptr", gIndBmp)
    DllCall("gdiplus\GdipCreateFromHDC", "Ptr", gIndDC, "Ptr*", &g := 0)
    gIndG := g
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)       ; AntiAlias
    DllCall("gdiplus\GdipSetPixelOffsetMode", "Ptr", g, "Int", 4)     ; Half
    ; ClearType needs an opaque background; on per-pixel alpha it fringes.
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", g, "Int", 4)   ; AntiAlias
}

; --- the frame -------------------------------------------------------

IndFrame() {
    ; Critical for the duration of one frame (well under 2 ms): a key-down
    ; landing mid-frame would draw a second frame into the same surface
    ; half way through this one. Restored, not switched off, because
    ; StartRec draws the first frame from inside its own Critical section.
    prev := A_IsCritical
    Critical("On")
    IndFrameDraw()
    Critical(prev)
}

IndFrameDraw() {
    global gInd, gIndG, gIndState, gIndTitle, gIndSub, gIndW, gIndV, gIndTargetW
    global gIndVisible, gIndAlpha, gIndScale, gIndKeyQpc, IND_CANVAS_W, IND_MARGIN
    r := SpringStep(gIndW, gIndV, gIndTargetW)
    gIndW := r[1]
    gIndV := r[2]
    gIndAlpha := FadeStep(gIndAlpha, gIndVisible)
    if (!gIndVisible && gIndAlpha = 0) {
        SetTimer(IndFrame, 0)
        IndPresent(0)
        gInd.Hide()
        return
    }
    if (gIndState = "listen")
        IndSampleLevel()

    g := gIndG
    t := A_TickCount / 1000.0
    DllCall("gdiplus\GdipGraphicsClear", "Ptr", g, "UInt", 0)
    DllCall("gdiplus\GdipResetWorldTransform", "Ptr", g)
    DllCall("gdiplus\GdipScaleWorldTransform", "Ptr", g, "Float", gIndScale, "Float", gIndScale, "Int", 0)

    h := IndicatorHeight()
    w := Max(gIndW, h)
    x := (IND_CANVAS_W - w) / 2
    y := IND_MARGIN
    lvl := IndLevelNow(t)

    ; Shadow, then the glow, as stacks of faint pills: GDI+ has no blur.
    loop 8
        GpFillPill(x - A_Index, y + 6 - A_Index * 0.5, w + 2 * A_Index, h + A_Index, 0x0A000000)
    if (gIndState = "listen") {
        a := Round(5 + 9 * lvl)
        loop 10
            GpFillPill(x - A_Index * 1.8, y - A_Index * 1.2, w + A_Index * 3.6, h + A_Index * 2.4, (a << 24) | 0x7C5CFF)
    } else if (gIndState = "error") {
        loop 8
            GpFillPill(x - A_Index * 1.8, y - A_Index * 1.2, w + A_Index * 3.6, h + A_Index * 2.4, 0x09FF7A45)
    }

    ; The glass: dense enough for white text over anything (ADR-0002).
    GpFillPill(x, y, w, h, 0xB8181820)
    p := GpRRectPath(x, y, w, h, h / 2)
    DllCall("gdiplus\GdipSetClipPath", "Ptr", g, "Ptr", p, "Int", 0)
    rc := GpRectF(x + 14, y + 1, w - 28, 24)
    DllCall("gdiplus\GdipCreateLineBrushFromRect", "Ptr", rc, "UInt", 0x55FFFFFF, "UInt", 0x00FFFFFF, "Int", 1, "Int", 1, "Ptr*", &br := 0)
    hp := GpRRectPath(x + 14, y + 1, w - 28, 24, 12)
    DllCall("gdiplus\GdipFillPath", "Ptr", g, "Ptr", br, "Ptr", hp)
    DllCall("gdiplus\GdipDeletePath", "Ptr", hp)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)

    IndContent(x, y, w, t)

    DllCall("gdiplus\GdipResetClip", "Ptr", g)
    GpStrokePath(p, 0x40FFFFFF, 1)
    DllCall("gdiplus\GdipDeletePath", "Ptr", p)

    IndPresent(Round(255 * gIndAlpha))

    if (gIndKeyQpc) {
        DllCall("QueryPerformanceCounter", "Int64*", &q := 0)
        DllCall("QueryPerformanceFrequency", "Int64*", &f := 0)
        LogMsg("DEBUG", Format("Indicator on screen {:.1f} ms after key-down", (q - gIndKeyQpc) * 1000 / f))
        gIndKeyQpc := 0
    }
}

IndContent(x, y, w, t) {
    global gIndState, gIndTitle, gIndSub, gIndRecT0, gIndWarmT0, gIndLevels, gIndFontTitle, gIndFontSmall, Cfg
    h := IndicatorHeight()
    cx := x + 29
    cy := y + h / 2
    tx := x + 56
    tw := w - 56 - 22
    switch gIndState {
        case "listen":
            rc := GpRectF(cx - 17, cy - 17, 34, 34)
            DllCall("gdiplus\GdipCreateLineBrushFromRectWithAngle", "Ptr", rc, "UInt", 0xFF7C5CFF, "UInt", 0xFF3DD6F5, "Float", Mod(t * 150, 360), "Int", 1, "Int", 0, "Ptr*", &br := 0)
            DllCall("gdiplus\GdipFillEllipse", "Ptr", IndG(), "Ptr", br, "Float", cx - 17, "Float", cy - 17, "Float", 34, "Float", 34)
            DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
            GpFillEllipse(cx - 14, cy - 14, 28, 28, 0x8C0F0F19)
            IndMicGlyph(cx, cy)
            n := 26
            step := (w - 56 - 60) / n
            heights := BarHeights(gIndLevels, n, 4, 28)
            for i, bh in heights {
                ; A little shimmer on top of the voice, so silence still
                ; reads as "listening" rather than as frozen.
                bh += 2 * Abs(Sin(t * 6 + i * 0.9))
                GpFillRRect(tx + 2 + (i - 1) * step, cy - bh / 2, 3, bh, 1.5, i & 1 ? 0xFFFFFFFF : 0xFFBDF2FC)
            }
            secs := (A_TickCount - gIndRecT0) // 1000
            GpText(Format("{}:{:02}", secs // 60, Mod(secs, 60)), gIndFontTitle, 0xF2FFFFFF, x + w - 60, y, 42, h, 2)
        case "warm":
            IndSpinner(cx, cy, t)
            GpText(gIndTitle, gIndFontTitle, 0xFFFFFFFF, tx, y + 7, tw - 70, 24, 0)
            GpFillRRect(tx, y + 36, tw - 70, 4, 2, 0x29FFFFFF)
            GpFillRRect(tx, y + 36, (tw - 70) * WarmProgress(A_TickCount - gIndWarmT0), 4, 2, 0xFF3DD6F5)
            GpText(ModelShortName(TierFile(Cfg["Tier"])), gIndFontSmall, 0xBFFFFFFF, x + w - 92, y, 70, h, 2)
        case "work":
            IndSpinner(cx, cy, t)
            a := Round(150 + 105 * (0.5 + 0.5 * Sin(t * 5)))
            if (gIndSub = "") {
                GpText(gIndTitle, gIndFontTitle, (a << 24) | 0xFFFFFF, tx, y, tw, h, 0)
            } else {
                GpText(gIndTitle, gIndFontTitle, (a << 24) | 0xFFFFFF, tx, y + 7, tw, 22, 0)
                GpText(gIndSub, gIndFontSmall, 0xBFFFFFFF, tx, y + 27, tw, 20, 0)
            }
        case "done":
            GpFillEllipse(cx - 17, cy - 17, 34, 34, 0xFF2FBF8F)
            DllCall("gdiplus\GdipCreatePen1", "UInt", 0xFFFFFFFF, "Float", 3, "Int", 0, "Ptr*", &pen := 0)
            DllCall("gdiplus\GdipSetPenStartCap", "Ptr", pen, "Int", 2)
            DllCall("gdiplus\GdipSetPenEndCap", "Ptr", pen, "Int", 2)
            DllCall("gdiplus\GdipDrawLine", "Ptr", IndG(), "Ptr", pen, "Float", cx - 7, "Float", cy + 0.5, "Float", cx - 2.5, "Float", cy + 5)
            DllCall("gdiplus\GdipDrawLine", "Ptr", IndG(), "Ptr", pen, "Float", cx - 2.5, "Float", cy + 5, "Float", cx + 7, "Float", cy - 4.5)
            DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
            IndTwoLines(tx, y, tw)
        case "error", "warn":
            GpFillEllipse(cx - 17, cy - 17, 34, 34, gIndState = "error" ? 0xFFE8590C : 0xFFB7791F)
            GpFillRRect(cx - 1.5, cy - 9, 3, 11, 1.5, 0xFFFFFFFF)
            GpFillEllipse(cx - 2, cy + 5, 4, 4, 0xFFFFFFFF)
            IndTwoLines(tx, y, tw)
    }
}

IndTwoLines(tx, y, tw) {
    global gIndTitle, gIndSub, gIndFontTitle, gIndFontSmall
    h := IndicatorHeight()
    if (gIndSub = "") {
        GpText(gIndTitle, gIndFontTitle, 0xFFFFFFFF, tx, y, tw, h, 0)
        return
    }
    GpText(gIndTitle, gIndFontTitle, 0xFFFFFFFF, tx, y + 7, tw, 22, 0)
    GpText(gIndSub, gIndFontSmall, 0xCCFFFFFF, tx, y + 27, tw, 20, 0)
}

IndG() {
    global gIndG
    return gIndG
}

IndSpinner(cx, cy, t) {
    DllCall("gdiplus\GdipCreatePen1", "UInt", 0x2EFFFFFF, "Float", 3, "Int", 0, "Ptr*", &pen := 0)
    DllCall("gdiplus\GdipDrawEllipse", "Ptr", IndG(), "Ptr", pen, "Float", cx - 14, "Float", cy - 14, "Float", 28, "Float", 28)
    DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
    DllCall("gdiplus\GdipCreatePen1", "UInt", 0xFF3DD6F5, "Float", 3, "Int", 0, "Ptr*", &pen := 0)
    DllCall("gdiplus\GdipSetPenStartCap", "Ptr", pen, "Int", 2)
    DllCall("gdiplus\GdipSetPenEndCap", "Ptr", pen, "Int", 2)
    DllCall("gdiplus\GdipDrawArc", "Ptr", IndG(), "Ptr", pen, "Float", cx - 14, "Float", cy - 14, "Float", 28, "Float", 28, "Float", Mod(t * 400, 360), "Float", 100)
    DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
}

IndMicGlyph(cx, cy) {
    DllCall("gdiplus\GdipCreatePen1", "UInt", 0xFFFFFFFF, "Float", 1.8, "Int", 0, "Ptr*", &pen := 0)
    DllCall("gdiplus\GdipSetPenStartCap", "Ptr", pen, "Int", 2)
    DllCall("gdiplus\GdipSetPenEndCap", "Ptr", pen, "Int", 2)
    p := GpRRectPath(cx - 3, cy - 8, 6, 10, 3)
    DllCall("gdiplus\GdipDrawPath", "Ptr", IndG(), "Ptr", pen, "Ptr", p)
    DllCall("gdiplus\GdipDeletePath", "Ptr", p)
    DllCall("gdiplus\GdipDrawArc", "Ptr", IndG(), "Ptr", pen, "Float", cx - 6, "Float", cy - 6, "Float", 12, "Float", 11, "Float", 0, "Float", 180)
    DllCall("gdiplus\GdipDrawLine", "Ptr", IndG(), "Ptr", pen, "Float", cx, "Float", cy + 5, "Float", cx, "Float", cy + 8)
    DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
}

IndPresent(alpha) {
    global gInd, gIndDC, gIndX, gIndY, gIndPW, gIndPH
    pt := Buffer(8), NumPut("Int", gIndX, "Int", gIndY, pt)
    sz := Buffer(8), NumPut("Int", gIndPW, "Int", gIndPH, sz)
    src := Buffer(8, 0)
    blend := Buffer(4), NumPut("UChar", 0, "UChar", 0, "UChar", alpha, "UChar", 1, blend)   ; AC_SRC_ALPHA
    DllCall("UpdateLayeredWindow", "Ptr", gInd.Hwnd, "Ptr", 0, "Ptr", pt, "Ptr", sz, "Ptr", gIndDC, "Ptr", src, "UInt", 0, "Ptr", blend, "UInt", 2)
}

; --- the voice --------------------------------------------------------

; Every 50 ms, the loudness of the last 50 ms of the capture ffmpeg is
; writing (it flushes every packet, so the tail is current).
IndSampleLevel() {
    global gIndLevels, gIndLevelTick, TEMP_RAW
    if (A_TickCount - gIndLevelTick < 50)
        return
    gIndLevelTick := A_TickCount
    level := -1
    ; Runs inside the frame's Critical section, and must: StartRec deletes
    ; the previous capture before spawning ffmpeg, and a key-down landing
    ; while this handle is open would leave that delete pending, so ffmpeg
    ; could not create the new file and the dictation would fail as "Mic
    ; capture failed". The open-read-close takes well under a millisecond.
    try {
        f := FileOpen(TEMP_RAW, "r")
        if (f.Length >= 1600) {
            f.Pos := (f.Length - 1600) & ~1
            buf := Buffer(1600)
            level := LevelFromRms(S16Rms(buf, f.RawRead(buf, 1600)))
        }
        f.Close()
    }
    if (level >= 0) {
        gIndLevels.Push(level)
        if (gIndLevels.Length > 26)
            gIndLevels.RemoveAt(1)
    }
}

; The glow follows the newest level; before the first one arrives (or if
; the capture cannot be read) it breathes slowly instead.
IndLevelNow(t) {
    global gIndLevels
    if (gIndLevels.Length)
        return gIndLevels[gIndLevels.Length]
    return 0.35 + 0.25 * Sin(t * 2.4)
}

; --- GDI+ helpers ------------------------------------------------------

GpFont(name, px) {
    fam := 0
    if DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", name, "Ptr", 0, "Ptr*", &fam)
        DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", "Segoe UI", "Ptr", 0, "Ptr*", &fam)
    DllCall("gdiplus\GdipCreateFont", "Ptr", fam, "Float", px, "Int", 0, "Int", 2, "Ptr*", &f := 0)   ; UnitPixel
    return f
}

GpRectF(x, y, w, h) {
    b := Buffer(16)
    NumPut("Float", x, "Float", y, "Float", w, "Float", h, b)
    return b
}

GpRRectPath(x, y, w, h, r) {
    DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &p := 0)
    d := Min(2 * r, w, h)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", p, "Float", x, "Float", y, "Float", d, "Float", d, "Float", 180, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", p, "Float", x + w - d, "Float", y, "Float", d, "Float", d, "Float", 270, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", p, "Float", x + w - d, "Float", y + h - d, "Float", d, "Float", d, "Float", 0, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", p, "Float", x, "Float", y + h - d, "Float", d, "Float", d, "Float", 90, "Float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "Ptr", p)
    return p
}

GpFillRRect(x, y, w, h, r, argb) {
    p := GpRRectPath(x, y, w, h, r)
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &br := 0)
    DllCall("gdiplus\GdipFillPath", "Ptr", IndG(), "Ptr", br, "Ptr", p)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
    DllCall("gdiplus\GdipDeletePath", "Ptr", p)
}

GpFillPill(x, y, w, h, argb) => GpFillRRect(x, y, w, h, h / 2, argb)

GpStrokePath(p, argb, width) {
    DllCall("gdiplus\GdipCreatePen1", "UInt", argb, "Float", width, "Int", 0, "Ptr*", &pen := 0)
    DllCall("gdiplus\GdipDrawPath", "Ptr", IndG(), "Ptr", pen, "Ptr", p)
    DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
}

GpFillEllipse(x, y, w, h, argb) {
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &br := 0)
    DllCall("gdiplus\GdipFillEllipse", "Ptr", IndG(), "Ptr", br, "Float", x, "Float", y, "Float", w, "Float", h)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
}

GpText(str, font, argb, x, y, w, h, align) {
    global gIndFmt
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &br := 0)
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", gIndFmt, "Int", align)
    DllCall("gdiplus\GdipDrawString", "Ptr", IndG(), "WStr", str, "Int", -1, "Ptr", font, "Ptr", GpRectF(x, y, w, h), "Ptr", gIndFmt, "Ptr", br)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
}

; Width in logical px of one line of text, for sizing the pill to it.
GpMeasure(str, font) {
    global gIndFmt
    if (str = "" || !IndG())
        return 0
    box := Buffer(16, 0)
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", gIndFmt, "Int", 0)
    DllCall("gdiplus\GdipMeasureString", "Ptr", IndG(), "WStr", str, "Int", -1, "Ptr", font, "Ptr", GpRectF(0, 0, 2000, 60), "Ptr", gIndFmt, "Ptr", box, "Ptr", 0, "Ptr", 0)
    return NumGet(box, 8, "Float")
}

; =====================================================================
; Hotkey and state
; =====================================================================
ApplyHotkey(key) {
    global gCurHotkey, APP_NAME
    if (gCurHotkey != "") {
        try Hotkey(gCurHotkey, "Off")
        try Hotkey(gCurHotkey " Up", "Off")
    }
    try {
        Hotkey(key, HkDown, "On")
        Hotkey(key " Up", HkUp, "On")
        gCurHotkey := key
        return true
    } catch as e {
        MsgBox("Cannot register hotkey '" key "'.`n`n" e.Message, APP_NAME, "Icon!")
        if (gCurHotkey != "") {
            try Hotkey(gCurHotkey, HkDown, "On")
            try Hotkey(gCurHotkey " Up", HkUp, "On")
        }
        return false
    }
}

HkDown(*) {
    ; Taken first, so the indicator can log how long it took to appear.
    DllCall("QueryPerformanceCounter", "Int64*", &keyQpc := 0)
    StartRec(keyQpc)
}

HkUp(*) {
    if StopRec()
        Transcribe()
    else
        SetState(gPausedState())
}

gPausedState() {
    global gPaused
    return gPaused ? "paused" : "idle"
}

; Tray icon + tooltip reflect the current state at a glance.
SetState(state) {
    global gCurHotkey, APP_NAME, ROOT_DIR, gTrayState
    gTrayState := state
    try TraySetIcon(ROOT_DIR "\assets\tray\" TrayIconName(state) ".ico")
    A_IconTip := APP_NAME " - " TrayHeader(state, gCurHotkey)
}

TogglePause(*) {
    global gPaused, gCurHotkey, gRecording
    gPaused := !gPaused
    if (gPaused) {
        try Hotkey(gCurHotkey, "Off")
        try Hotkey(gCurHotkey " Up", "Off")
        if gRecording
            StopRec()
        LogMsg("INFO", "Paused")
        Notify("Dictation paused", gCurHotkey " does nothing until you resume.")
    } else {
        try Hotkey(gCurHotkey, "On")
        try Hotkey(gCurHotkey " Up", "On")
        LogMsg("INFO", "Resumed")
        Notify("Dictation resumed", "Hold " gCurHotkey " to dictate.")
    }
    BuildTray()
    SetState(gPausedState())
}

; =====================================================================
; Tray menu
; =====================================================================
BuildTray() {
    global gPaused, gUpdate, gTrayState, gCurHotkey, Cfg
    m := A_TrayMenu
    m.Delete()
    header := TrayHeader(gTrayState, gCurHotkey)
    m.Add(header, (*) => 0)
    m.Disable(header)
    m.Add()
    ; An available update goes first and is the default action: it is the
    ; only entry that is not there all the time, so burying it would make
    ; the check pointless.
    if IsObject(gUpdate) {
        update := UpdateMenuLabel(gUpdate["tag"])
        MenuItem(m, update, InstallUpdate, 0xE896)          ; Download
    }
    MenuItem(m, gPaused ? "Resume dictation" : "Pause dictation", TogglePause, gPaused ? 0xE768 : 0xE769)
    ; A process check, not ServerAlive: the menu must open at once, and an
    ; HTTP probe costs up to two seconds while a model is loading.
    loaded := ProcessExist("whisper-server.exe") != 0
    MenuItem(m, ModelMenuLabel(loaded, TierVram(Cfg["Tier"])), ToggleServer, 0xE9F5)   ; Processing
    m.Add()
    MenuItem(m, "History...", (*) => ShowSettings(3), 0xE81C)
    MenuItem(m, "Settings...", (*) => ShowSettings(), 0xE713)
    MenuItem(m, "Diagnostics...", (*) => ShowSettings(4), 0xE9D9)
    MenuItem(m, "Run setup again...", (*) => ShowFirstRun(), 0xE720)   ; Microphone
    m.Add()
    MenuItem(m, "Restart Whispers", (*) => Reload(), 0xE72C)          ; Refresh
    MenuItem(m, "Quit Whispers", (*) => ExitApp(), 0xE7E8)            ; Power
    m.Default := IsObject(gUpdate) ? update : "Settings..."
}

MenuItem(m, label, callback, glyph) {
    m.Add(label, callback)
    icon := MenuGlyph(glyph)
    if icon
        try m.SetIcon(label, "HICON:*" icon)
}

; One glyph of the Windows icon font as a small icon, in the menu's text
; colour. Segoe Fluent Icons ships with Windows 11 and Segoe MDL2 Assets
; with Windows 10; they share these code points. Kept for the session:
; there are a dozen of them, and the "*" above tells AutoHotkey they are
; not its to destroy.
MenuGlyph(cp) {
    static cache := Map(), family := ""
    global gIndFmt
    if !gIndFmt         ; GDI+ did not start (see CreateIndicator)
        return 0
    dark := IsDarkTheme()
    key := cp "|" dark
    if cache.Has(key)
        return cache[key]
    if (family = "") {
        family := "Segoe MDL2 Assets"
        if !DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", "Segoe Fluent Icons", "Ptr", 0, "Ptr*", &probe := 0) {
            family := "Segoe Fluent Icons"
            DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", probe)
        }
    }
    s := DllCall("GetSystemMetrics", "Int", 49)          ; SM_CXSMICON
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", s, "Int", s, "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &bmp := 0)
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", bmp, "Ptr*", &g := 0)
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", g, "Int", 4)
    DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", family, "Ptr", 0, "Ptr*", &fam := 0)
    DllCall("gdiplus\GdipCreateFont", "Ptr", fam, "Float", s * 0.875, "Int", 0, "Int", 2, "Ptr*", &font := 0)
    DllCall("gdiplus\GdipStringFormatGetGenericTypographic", "Ptr*", &typo := 0)
    DllCall("gdiplus\GdipCloneStringFormat", "Ptr", typo, "Ptr*", &fmt := 0)
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", fmt, "Int", 1)
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", fmt, "Int", 1)
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", dark ? 0xFFFFFFFF : 0xFF1A1A1A, "Ptr*", &br := 0)
    DllCall("gdiplus\GdipDrawString", "Ptr", g, "WStr", Chr(cp), "Int", -1, "Ptr", font, "Ptr", GpRectF(0, 0, s, s), "Ptr", fmt, "Ptr", br)
    DllCall("gdiplus\GdipCreateHICONFromBitmap", "Ptr", bmp, "Ptr*", &hicon := 0)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
    DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", fmt)
    DllCall("gdiplus\GdipDeleteFont", "Ptr", font)
    DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", fam)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", bmp)
    cache[key] := hicon
    return hicon
}

IsDarkTheme() {
    try return RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme") = 0
    return false
}

; Lets the tray menu follow Windows' dark mode. uxtheme exports this only
; by ordinal and documents none of it, but it has been stable since
; Windows 10 1903 and is what Explorer's own menus use: 135 is
; SetPreferredAppMode (1 = follow the system), 136 FlushMenuThemes.
; Builds before 1903 exported other functions at those ordinals, so they
; are left with the light menu rather than called blind.
InitMenuTheme() {
    global gMenuFlush
    if (VerCompare(A_OSVersion, "10.0.18362") < 0)
        return
    try {
        ux := DllCall("LoadLibrary", "Str", "uxtheme", "Ptr")
        setMode := DllCall("GetProcAddress", "Ptr", ux, "Ptr", 135, "Ptr")
        flush := DllCall("GetProcAddress", "Ptr", ux, "Ptr", 136, "Ptr")
        if (setMode && flush) {
            DllCall(setMode, "Int", 1)
            DllCall(flush)
            gMenuFlush := flush
        }
    }
}

OnTrayNotify(wParam, lParam, msg, hwnd) {
    ; WM_RBUTTONDOWN, or WM_CONTEXTMENU from the keyboard: AutoHotkey
    ; shows the menu after this returns, so it shows the rebuilt one.
    if ((lParam & 0xFFFF) = 0x204 || (lParam & 0xFFFF) = 0x7B)
        BuildTray()
}

OnSettingChange(wParam, lParam, msg, hwnd) {
    global gMenuFlush
    if (gMenuFlush && lParam && StrGet(lParam) = "ImmersiveColorSet")
        DllCall(gMenuFlush)
}

ToggleServer(*) {
    if ServerAlive() {
        StopServer("user request")
        Notify("Model unloaded", "The next dictation loads it again.")
    } else {
        ok := EnsureServerReady()
        ; EnsureServerReady shows the warm-up pill; nothing else will
        ; replace it when the load was asked for from the tray.
        IndHide()
        if ok
            Notify("Model loaded", "The next dictation will not wait for it.")
    }
    BuildTray()
}

LoadHistory() {
    global HIST_FILE, gHistory
    gHistory := []
    if !FileExist(HIST_FILE)
        return
    try gHistory := ParseHistoryText(FileRead(HIST_FILE, "UTF-8"))
}

AddHistory(text) {
    global gHistory, HIST_FILE
    gHistory.InsertAt(1, Map("time", FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss"), "text", FlattenText(text)))
    while (gHistory.Length > 20)
        gHistory.Pop()
    try FileDelete(HIST_FILE)
    try FileAppend(FormatHistoryText(gHistory), HIST_FILE, "UTF-8")
    RefreshHistoryView()
}

; =====================================================================
; Settings window
; =====================================================================
ShowSettings(startTab := 1) {
    global gSettingsGui, gCtl, gHistView, gLogView, Cfg, APP_NAME, APP_VERSION

    if (gSettingsGui) {
        try {
            gSettingsGui.Show()
            return
        }
    }

    g := Gui("+Resize", APP_NAME " " APP_VERSION " - Settings")
    g.SetFont("s9", "Segoe UI")
    gSettingsGui := g
    gCtl := Map()

    tab := g.Add("Tab3", "w660 h430", ["General", "Engine", "History", "Log"])

    ; ---------- General ----------
    tab.UseTab(1)
    g.Add("Text", "xm+16 y+16 w120", "Microphone")
    devices := GetAudioDevices()
    if (devices.Length = 0)
        devices := [Cfg["Mic"]]
    if (Cfg["Mic"] != "" && !HasValue(devices, Cfg["Mic"]))
        devices.InsertAt(1, Cfg["Mic"])
    gCtl["Mic"] := g.Add("DropDownList", "x+8 yp-4 w420", devices)
    if (Cfg["Mic"] != "")
        gCtl["Mic"].Text := Cfg["Mic"]

    g.Add("Button", "xm+16 y+10 w140", "Test microphone").OnEvent("Click", TestMic)
    g.Add("Button", "x+8 yp w140", "Detect best").OnEvent("Click", DetectMicClick)
    gCtl["MicResult"] := g.Add("Text", "x+10 yp+4 w250", "Records 3 s and reports the captured level.")

    g.Add("Text", "xm+16 y+18 w120", "Hotkey")
    gCtl["Hotkey"] := g.Add("Hotkey", "x+8 yp-4 w160")
    gCtl["Hotkey"].Value := Cfg["Hotkey"]
    g.Add("Text", "x+10 yp+4 w300", "Hold to record, release to transcribe.")

    g.Add("Text", "xm+16 y+18 w120", "Language")
    gCtl["Language"] := g.Add("DropDownList", "x+8 yp-4 w160", ["fr", "en", "auto"])
    gCtl["Language"].Text := Cfg["Language"]

    gCtl["AutoPaste"] := g.Add("CheckBox", "xm+16 y+20", "Paste automatically after transcription")
    gCtl["AutoPaste"].Value := Cfg["AutoPaste"]
    gCtl["PlaySounds"] := g.Add("CheckBox", "xm+16 y+8", "Play beeps")
    gCtl["PlaySounds"].Value := Cfg["PlaySounds"]
    gCtl["ShowIndicator"] := g.Add("CheckBox", "xm+16 y+8", "Show on-screen recording indicator")
    gCtl["ShowIndicator"].Value := Cfg["ShowIndicator"]
    gCtl["TrimSilence"] := g.Add("CheckBox", "xm+16 y+8", "Trim leading/trailing silence (reduces hallucinations)")
    gCtl["TrimSilence"].Value := Cfg["TrimSilence"]
    gCtl["Autostart"] := g.Add("CheckBox", "xm+16 y+8", "Start with Windows")
    gCtl["Autostart"].Value := IsAutostart()
    gCtl["CheckUpdates"] := g.Add("CheckBox", "xm+16 y+8", "Check for a new version at startup")
    gCtl["CheckUpdates"].Value := Cfg["CheckUpdates"]

    ; ---------- Engine ----------
    tab.UseTab(2)
    g.Add("Text", "xm+16 y+16 w120", "Performance tier")
    labels := []
    for t in TierList()
        labels.Push(TierLabel(t))
    gCtl["Tier"] := g.Add("DropDownList", "x+8 yp-4 w420", labels)
    gCtl["Tier"].Text := TierLabel(Cfg["Tier"])
    gCtl["TierInfo"] := g.Add("Text", "xm+16 y+10 w600", "")

    g.Add("Text", "xm+16 y+16 w120", "VRAM policy")
    gCtl["VramPolicy"] := g.Add("DropDownList", "x+8 yp-4 w260", ["idle", "resident", "never"])
    gCtl["VramPolicy"].Text := Cfg["VramPolicy"]
    g.Add("Text", "xm+16 y+8 w600", "idle - load on first use, unload after the delay below (recommended)`nresident - keep the model in VRAM permanently (fastest)`nnever - spawn whisper-cli per dictation (no VRAM held, much slower)")

    g.Add("Text", "xm+16 y+14 w120", "Unload after (min)")
    gCtl["IdleMinutes"] := g.Add("Edit", "x+8 yp-4 w60")
    gCtl["IdleMinutes"].Value := Cfg["IdleMinutes"]

    g.Add("Text", "xm+16 y+14 w120", "Server port")
    gCtl["Port"] := g.Add("Edit", "x+8 yp-4 w80")
    gCtl["Port"].Value := Cfg["Port"]

    g.Add("Text", "xm+16 y+14 w120", "Load timeout (s)")
    gCtl["LoadTimeout"] := g.Add("Edit", "x+8 yp-4 w60")
    gCtl["LoadTimeout"].Value := Cfg["LoadTimeout"]

    gCtl["CpuFallback"] := g.Add("CheckBox", "xm+16 y+14 w500", "Fall back to CPU when the GPU cannot allocate")
    gCtl["CpuFallback"].Value := Cfg["CpuFallback"]

    gCtl["Status"] := g.Add("Text", "xm+16 y+16 w600", "")
    g.Add("Button", "xm+16 y+6 w160", "Refresh status").OnEvent("Click", (*) => RefreshStatus())
    g.Add("Button", "x+10 yp w180", "Download selected model").OnEvent("Click", GetModelClick)

    ; ---------- History ----------
    tab.UseTab(3)
    gHistView := g.Add("ListView", "xm+10 y+14 w630 h340", ["Time", "Text"])
    gHistView.OnEvent("DoubleClick", HistCopy)
    gCtl["HistHint"] := g.Add("Text", "xm+10 y+6 w630", "Double-click a line to copy it back to the clipboard.")

    ; ---------- Log ----------
    tab.UseTab(4)
    gLogView := g.Add("Edit", "xm+10 y+14 w630 h340 ReadOnly -Wrap +HScroll")
    g.Add("Button", "xm+10 y+6 w160", "Open log folder").OnEvent("Click", (*) => Run(LogDirPath()))

    ; ---------- Buttons ----------
    tab.UseTab()
    gCtl["Save"] := g.Add("Button", "xm+430 y+14 w100 Default", "Save")
    gCtl["Save"].OnEvent("Click", SaveSettings)
    g.Add("Button", "x+10 yp w100", "Close").OnEvent("Click", (*) => g.Hide())

    g.OnEvent("Close", (*) => g.Hide())
    g.OnEvent("Escape", (*) => g.Hide())

    RefreshHistoryView()
    RefreshLogView()
    RefreshStatus()

    tab.Value := startTab
    g.Show("w690 h500")
}


LogDirPath() {
    global LOG_DIR
    return LOG_DIR
}

; Maps the human-readable dropdown entry back to its tier key.
SelectedTier() {
    global gCtl
    t := TierFromLabel(gCtl["Tier"].Text)
    return t != "" ? t : "balanced"
}

RefreshStatus() {
    global gCtl, Cfg, MODELS_DIR
    if !IsSet(gCtl) || !gCtl.Has("Status")
        return

    g := GpuInfo(true)
    gpuTxt := g["present"]
        ? g["name"] " - " g["vramFree"] " of " g["vramTotal"] " MiB free (CUDA " g["cudaMax"] ")"
        : "no NVIDIA GPU detected - CPU only"
    try gCtl["Status"].Value := "Server: " (ServerAlive() ? "running on port " Cfg["Port"] : "stopped") "`nGPU: " gpuTxt

    if gCtl.Has("TierInfo") {
        t := SelectedTier()
        file := TierFile(t)
        if (file = "") {
            try gCtl["TierInfo"].Value := "Cannot resolve this tier - versions.json is missing or damaged."
            return
        }
        path := MODELS_DIR "\" file
        present := FileExist(path)
            ? "installed"
            : "NOT installed - this tier will not start until the model is fetched"
        vram := TierVram(t)
        try gCtl["TierInfo"].Value := file " | " (vram ? vram " MiB VRAM" : "runs on CPU") " | " present
            . "   (recommended for this machine: " TierLabel(RecommendedTier()) ")"
    }
}

RefreshHistoryView() {
    global gHistView, gHistory
    if (gHistView = "")
        return
    try {
        gHistView.Delete()
        for item in gHistory
            gHistView.Add("", item["time"], item["text"])
        gHistView.ModifyCol(1, 140)
        gHistView.ModifyCol(2, 470)
    }
}

RefreshLogView() {
    global gLogView, gLogBuf
    if (gLogView = "")
        return
    try {
        out := ""
        start := gLogBuf.Length > 200 ? gLogBuf.Length - 199 : 1
        Loop gLogBuf.Length - start + 1
            out .= gLogBuf[start + A_Index - 1] "`r`n"
        gLogView.Value := out
    }
}

HistCopy(lv, row) {
    global gHistory
    if (row < 1 || row > gHistory.Length)
        return
    A_Clipboard := gHistory[row]["text"]
    ClipWait(1)
    ; Said under the list rather than in a notification: the user is
    ; looking at the window, and this is not news worth keeping.
    try gCtl["HistHint"].Value := "Copied to the clipboard."
    SetTimer(HistHintReset, -2000)
}

HistHintReset() {
    global gCtl
    try gCtl["HistHint"].Value := "Double-click a line to copy it back to the clipboard."
}

TestMic(btn, *) {
    global gCtl
    mic := gCtl["Mic"].Text
    if (mic = "") {
        gCtl["MicResult"].Value := "Pick a microphone first."
        return
    }
    gCtl["MicResult"].Value := "Recording 3 s..."
    lvl := MicLevel(mic, 3)
    if (lvl = "") {
        gCtl["MicResult"].Value := "FAILED - could not open this device"
        return
    }
    gCtl["MicResult"].Value := IsSilentLevel(lvl)
        ? "Silent (" lvl " dB) - wrong device, or muted"
        : "OK - mean level " lvl " dB"
}

DetectMicClick(btn, *) {
    global gCtl, Cfg
    gCtl["MicResult"].Value := "Measuring every device, speak now..."
    picked := AutoDetectMic()
    if (picked = "") {
        gCtl["MicResult"].Value := "No usable microphone found"
        return
    }
    gCtl["Mic"].Text := picked
    gCtl["MicResult"].Value := "Selected: " picked
}

SaveSettings(btn, *) {
    global gCtl, Cfg, gCurHotkey

    newHotkey := gCtl["Hotkey"].Value
    if (newHotkey = "") {
        MsgBox("Pick a hotkey first.", "Whispers", "Icon!")
        return
    }

    oldTier := Cfg["Tier"]
    oldLang := Cfg["Language"]
    oldPort := Cfg["Port"]

    Cfg["Mic"] := gCtl["Mic"].Text
    Cfg["Language"] := gCtl["Language"].Text
    Cfg["AutoPaste"] := gCtl["AutoPaste"].Value
    Cfg["PlaySounds"] := gCtl["PlaySounds"].Value
    Cfg["ShowIndicator"] := gCtl["ShowIndicator"].Value
    Cfg["TrimSilence"] := gCtl["TrimSilence"].Value
    Cfg["CheckUpdates"] := gCtl["CheckUpdates"].Value

    Cfg["Tier"] := SelectedTier()
    Cfg["VramPolicy"] := gCtl["VramPolicy"].Text
    ; Three free-text boxes: clamp before storing, and write the clamped
    ; value straight back so the user sees what was actually kept.
    Cfg["IdleMinutes"] := SanitizeIdleMinutes(gCtl["IdleMinutes"].Value)
    Cfg["Port"] := SanitizePort(gCtl["Port"].Value)
    Cfg["LoadTimeout"] := SanitizeLoadTimeout(gCtl["LoadTimeout"].Value)
    gCtl["IdleMinutes"].Value := Cfg["IdleMinutes"]
    gCtl["Port"].Value := Cfg["Port"]
    gCtl["LoadTimeout"].Value := Cfg["LoadTimeout"]
    Cfg["CpuFallback"] := gCtl["CpuFallback"].Value

    if (newHotkey != gCurHotkey)
        ApplyHotkey(newHotkey)
    Cfg["Hotkey"] := gCurHotkey

    SetAutostart(gCtl["Autostart"].Value)
    SaveConfig()
    ResolvePaths()

    ; A tier, language or port change invalidates the running server.
    if (oldTier != Cfg["Tier"] || oldLang != Cfg["Language"] || oldPort != Cfg["Port"]) {
        if ServerAlive() {
            StopServer("settings changed")
            LogMsg("INFO", "Server will reload with the new settings on next use")
        }
    }
    if (Cfg["VramPolicy"] = "resident" && !ServerAlive())
        StartServer("policy set to resident")
    if (Cfg["VramPolicy"] = "never" && ServerAlive())
        StopServer("policy set to never")

    ; Changing tier without the matching model installed is the one setting
    ; that can leave Whispers unable to transcribe. Offering the download
    ; here is what makes switching tier a complete action rather than a
    ; warning telling the user to go and find a file.
    if !FileExist(ModelPath())
        EnsureModelInstalled(Cfg["Tier"], true)

    ; Only once the new model is really there: a declined or failed
    ; download keeps the previous one, so going back costs nothing. The
    ; server holding the old file was stopped above.
    if (oldTier != Cfg["Tier"]) {
        if FileExist(ModelPath())
            PruneOtherModels()
        UpdateInstalledSize()
    }

    BuildTray()
    SetState(gPausedState())
    RefreshStatus()
    ; Confirmed on the button itself: the window stays open.
    try gCtl["Save"].Text := "Saved"
    SetTimer(SaveLabelReset, -1500)
}

SaveLabelReset() {
    global gCtl
    try gCtl["Save"].Text := "Save"
}

; =====================================================================
; Setup window
;
; Shown once, on a genuinely new installation, and reachable from the
; tray afterwards. It ends on a real dictation through the real pipeline
; - microphone, ffmpeg, server, model - rather than on a claim that
; everything is configured.
;
; While it is open, transcriptions are echoed into it and pasted
; nowhere: someone testing their microphone has some other window behind
; this one, and it is not a place to drop text.
; =====================================================================
ShowFirstRun() {
    global gWizard, gWizCtl, gWizEcho, Cfg, APP_NAME, APP_VERSION

    if (gWizard) {
        try {
            gWizEcho := true
            WizRefreshModel()
            gWizard.Show()
            return
        }
    }

    g := Gui("+AlwaysOnTop", APP_NAME " " APP_VERSION " - setup")
    g.SetFont("s9", "Segoe UI")
    gWizard := g
    gWizCtl := Map()

    g.SetFont("s11 Bold")
    g.Add("Text", "xm w520", "Let's check that dictation works.")
    g.SetFont("s9 Norm")

    g.Add("Text", "xm y+14 w520", "1.  Microphone")
    devices := GetAudioDevices()
    if (devices.Length = 0)
        devices := [Cfg["Mic"]]
    if (Cfg["Mic"] != "" && !HasValue(devices, Cfg["Mic"]))
        devices.InsertAt(1, Cfg["Mic"])
    gWizCtl["Mic"] := g.Add("DropDownList", "xm+20 y+6 w500", devices)
    if (Cfg["Mic"] != "")
        gWizCtl["Mic"].Text := Cfg["Mic"]
    gWizCtl["Mic"].OnEvent("Change", WizMicChanged)
    g.Add("Button", "xm+20 y+8 w150", "Say a sentence").OnEvent("Click", WizTestMic)
    gWizCtl["MicResult"] := g.Add("Text", "x+10 yp+4 w330", "Records 3 seconds and reports the level.")

    g.Add("Text", "xm y+16 w520", "2.  Hotkey and language")
    gWizCtl["Hotkey"] := g.Add("Hotkey", "xm+20 y+6 w120")
    gWizCtl["Hotkey"].Value := Cfg["Hotkey"]
    gWizCtl["Language"] := g.Add("DropDownList", "x+10 yp w80", ["fr", "en", "auto"])
    gWizCtl["Language"].Text := Cfg["Language"]
    gWizCtl["Language"].OnEvent("Change", WizLanguageChanged)
    g.Add("Text", "x+10 yp+4 w280", "Hold the key, speak, release.")
    ; The hotkey alone waits for Finish: the control reports every
    ; intermediate state while keys are pressed, and registering each of
    ; those would fail on half-typed combinations.
    g.Add("Text", "xm+20 y+8 w500", "A new hotkey takes effect when you click Finish.")

    g.Add("Text", "xm y+16 w520", "3.  Model")
    gWizCtl["Model"] := g.Add("Text", "xm+20 y+8 w320", "")
    gWizCtl["GetModel"] := g.Add("Button", "x+10 yp-4 w160", "Download model")
    gWizCtl["GetModel"].OnEvent("Click", WizGetModel)

    g.Add("Text", "xm y+16 w520", "4.  Try it - hold the hotkey and say a sentence")
    gWizCtl["Heard"] := g.Add("Edit", "xm+20 y+6 w500 h70 ReadOnly -Wrap +HScroll")
    g.Add("Text", "xm+20 y+6 w500", "What you dictate appears here and is pasted nowhere.")

    g.Add("Button", "xm+420 y+16 w100 Default", "Finish").OnEvent("Click", WizFinish)
    g.OnEvent("Close", (*) => WizFinish(0))
    g.OnEvent("Escape", (*) => WizFinish(0))

    WizRefreshModel()
    gWizEcho := true
    g.Show("w560")
}

WizTestMic(btn, *) {
    global gWizCtl, gBusy
    device := gWizCtl["Mic"].Text
    if (device = "") {
        try gWizCtl["MicResult"].Value := "Pick a microphone first."
        return
    }
    try btn.Enabled := false
    try gWizCtl["MicResult"].Value := "Listening for 3 seconds - say something..."
    gBusy := true
    level := MicLevel(device, 3)
    gBusy := false
    try btn.Enabled := true

    if (level = "") {
        try gWizCtl["MicResult"].Value := "Nothing was captured. Try another device."
        return
    }
    try gWizCtl["MicResult"].Value := IsSilentLevel(level)
        ? "Heard " Round(level, 1) " dB - that is silence."
        : "Heard " Round(level, 1) " dB - that works."
}

; Step 4 dictates through the real pipeline, which reads Cfg. Applying
; these only on Finish meant the test recorded from the microphone
; detected at startup while the window showed another one, and whisper
; turned the silence into an invented caption. Writing them to the INI
; still waits for Finish.
WizMicChanged(ctl, *) {
    global Cfg
    Cfg["Mic"] := ctl.Text
    LogMsg("INFO", "Setup: microphone set to " ctl.Text)
}

; The language travels with every request, so the running server picks
; it up without a restart.
WizLanguageChanged(ctl, *) {
    global Cfg
    Cfg["Language"] := ctl.Text
    LogMsg("INFO", "Setup: language set to " ctl.Text)
}

WizGetModel(btn, *) {
    global Cfg
    EnsureModelInstalled(Cfg["Tier"], true)
    UpdateInstalledSize()
    WizRefreshModel()
}

WizRefreshModel() {
    global gWizCtl, Cfg
    if !IsObject(gWizCtl) || !gWizCtl.Has("Model")
        return
    file := TierFile(Cfg["Tier"])
    if (file = "") {
        try gWizCtl["Model"].Value := "versions.json is missing or damaged."
        try gWizCtl["GetModel"].Enabled := false
        return
    }
    installed := FileExist(ModelPathFor(Cfg["Tier"])) ? true : false
    try gWizCtl["Model"].Value := (installed ? "Installed: " : "Not installed: ") file
    try gWizCtl["GetModel"].Enabled := !installed
}

WizFinish(btn, *) {
    global gWizard, gWizCtl, gWizEcho, Cfg, gCurHotkey
    Cfg["Mic"] := gWizCtl["Mic"].Text
    Cfg["Language"] := gWizCtl["Language"].Text

    key := gWizCtl["Hotkey"].Value
    if (key != "" && key != gCurHotkey)
        ApplyHotkey(key)
    Cfg["Hotkey"] := gCurHotkey

    Cfg["Configured"] := 1
    SaveConfig()
    LogMsg("INFO", "Setup finished: mic=" Cfg["Mic"] " hotkey=" Cfg["Hotkey"] " lang=" Cfg["Language"])

    gWizEcho := false
    try gWizard.Hide()
    BuildTray()
    SetState(gPausedState())
    Notify("Setup done", "Hold " gCurHotkey " to dictate in any app.")
}

GetModelClick(btn, *) {
    ; No pruning here: the tier picked in the dropdown is not saved yet,
    ; and the committed tier's model must stay until it is.
    EnsureModelInstalled(SelectedTier(), true)
    UpdateInstalledSize()
    RefreshStatus()
}

; =====================================================================
; Autostart
; =====================================================================
ShortcutPath() {
    global APP_NAME
    return A_Startup "\" APP_NAME ".lnk"
}

IsAutostart() {
    return FileExist(ShortcutPath()) ? 1 : 0
}

; The shortcut points at the interpreter that is running this script,
; with the script as its argument - NOT at the .ahk file.
;
; A shortcut to the .ahk only works where Windows has an association for
; that extension, which means where AutoHotkey was installed system-wide.
; Whispers ships its own interpreter beside the script and installs
; nothing system-wide, so on an installed machine a .ahk shortcut is a
; file that opens in Notepad, or in nothing at all.
SetAutostart(enable) {
    lnk := ShortcutPath()
    if (enable) {
        if !FileExist(lnk) {
            try {
                FileCreateShortcut(A_AhkPath, lnk, A_ScriptDir, '"' A_ScriptFullPath '"',, A_ScriptDir "\assets\Whispers.ico")
                LogMsg("INFO", "Autostart enabled -> " A_AhkPath)
            } catch as e {
                LogMsg("ERROR", "Autostart shortcut failed: " e.Message)
            }
        }
    } else if FileExist(lnk) {
        try FileDelete(lnk)
        LogMsg("INFO", "Autostart disabled")
    }
}

; =====================================================================
; Cleanup
; =====================================================================
OnExit(Cleanup)

Cleanup(*) {
    KillRecorder()
    StopServer("script exit")
    LogMsg("INFO", "Stopped")
}
