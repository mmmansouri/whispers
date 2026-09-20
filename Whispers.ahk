#Requires AutoHotkey v2.0
#SingleInstance Force

; The pure core. These files define functions only - including them runs
; nothing - which is what lets the test runner load them in isolation.
#Include %A_LineFile%\..\lib\Text.ahk
#Include %A_LineFile%\..\lib\Config.ahk
#Include %A_LineFile%\..\lib\Tiers.ahk
#Include %A_LineFile%\..\lib\Devices.ahk
#Include %A_LineFile%\..\lib\Commands.ahk

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
APP_VERSION := "2.0.0"

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
gRecTick     := 0
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
gInd         := ""
gIndText     := ""
gGpu         := ""

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
ResolvePaths()
CreateIndicator()
LoadHistory()
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
    Toast("Detecting your microphone...", 3000)
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
Toast(APP_NAME " ready - hold " Cfg["Hotkey"], 2500)

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
        IndSet("Loading model... " Round((A_TickCount - started) / 1000) "s", "C87A00")
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
StartRec() {
    global Cfg, gRecording, gPaused, gBusy, gStopping, gRecStart, gRecTick
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
    LogMsg("DEBUG", "StartRec")

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
    gRecTick  := A_TickCount

    if (Cfg["PlaySounds"])
        SoundBeep(1500, 120)

    Run(ShellCmd(CmdRecord(FFMPEG_EXE, Cfg["Mic"], TEMP_RAW, MIC_LOG)), ROOT_DIR, "Hide", &pid)
    gFfmpegPid := pid

    gRecording := true
    SetState("rec")
    IndShow()
    SetTimer(TickIndicator, 100)

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
    global Cfg, gRecording, gStopping, TEMP_RAW, TEMP_WAV, MIC_LOG, ROOT_DIR, FFMPEG_EXE

    if !gRecording
        return false

    ; Same reasoning as StartRec: the state transition must be atomic.
    ; Critical is lifted again before the slow part (file checks and the
    ; ffmpeg conversion), so the tray and timers stay responsive.
    Critical("On")
    gStopping := true
    LogMsg("DEBUG", "StopRec")
    SetTimer(TickIndicator, 0)
    if (Cfg["PlaySounds"])
        SoundBeep(800, 120)

    KillRecorder()
    Sleep(150)
    gRecording := false
    Critical("Off")

    if !FileExist(TEMP_RAW) {
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

    IndSet("Converting...", "C87A00")

    RunWait(ShellCmd(CmdConvert(FFMPEG_EXE, TEMP_RAW, TEMP_WAV, MIC_LOG, Cfg["TrimSilence"])), ROOT_DIR, "Hide")

    if !FileExist(TEMP_WAV) {
        Fail("WAV conversion failed", TailFile(MIC_LOG, 220))
        gStopping := false
        return false
    }
    gStopping := false
    return true
}

TickIndicator() {
    global gRecTick
    IndSet(Format("Recording  {:.1f}s", (A_TickCount - gRecTick) / 1000), "B00000")
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
    IndSet("Transcribing...", "C87A00")
    try FileDelete(TEMP_TXT)

    text := ""
    if (Cfg["VramPolicy"] = "never") {
        text := TranscribeViaCli(false)
    } else {
        if EnsureServerReady()
            text := TranscribeViaServer()
        if (text = "" && Cfg["CpuFallback"]) {
            LogMsg("WARN", "Server path failed, falling back to whisper-cli")
            IndSet("GPU busy - CPU fallback...", "C87A00")
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
    global Cfg

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

    preview := PreviewText(text)
    IndSet("Done", "1E7A1E")
    SetTimer(IndHide, -900)
    Toast(Cfg["AutoPaste"] ? "Pasted: " preview : "Copied: " preview, 2200)
    SetState(gPausedState())
}

; =====================================================================
; User feedback
; =====================================================================
Fail(msg, detail) {
    global Cfg
    LogMsg("ERROR", msg (detail != "" ? " | " detail : ""))
    IndSet(msg, "8B0000")
    SetTimer(IndHide, -4500)
    if (Cfg["PlaySounds"])
        SoundBeep(300, 250)
    Toast(msg (detail != "" ? "`n" detail : ""), 5000)
    SetState(gPausedState())
}

Warn(msg) {
    LogMsg("WARN", msg)
    IndSet(msg, "8A6D00")
    SetTimer(IndHide, -2500)
    Toast(msg, 2500)
    SetState(gPausedState())
}

Toast(msg, duration := 2000) {
    ToolTip(msg)
    SetTimer(() => ToolTip(), -duration)
}

; =====================================================================
; Recording indicator (click-through, always on top)
; =====================================================================
CreateIndicator() {
    global gInd, gIndText, APP_NAME
    gInd := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 -DPIScale", APP_NAME "Indicator")
    gInd.BackColor := "202020"
    gInd.MarginX := 0
    gInd.MarginY := 0
    gInd.SetFont("s11 Bold cFFFFFF", "Segoe UI")
    gIndText := gInd.Add("Text", "w300 h34 Center +0x200", "Ready")
}

IndShow() {
    global gInd, Cfg
    if !Cfg["ShowIndicator"]
        return
    x := (A_ScreenWidth - 300) // 2
    y := A_ScreenHeight - 160
    gInd.Show(Format("x{} y{} w300 h34 NoActivate", x, y))
}

IndHide() {
    global gInd
    try gInd.Hide()
}

IndSet(msg, color) {
    global gInd, gIndText, Cfg
    if !Cfg["ShowIndicator"]
        return
    gInd.BackColor := color
    gIndText.Value := msg
    IndShow()
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
    StartRec()
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
    global gCurHotkey, APP_NAME
    switch state {
        case "rec":
            try TraySetIcon("shell32.dll", 28)
            A_IconTip := APP_NAME " - RECORDING"
        case "work":
            try TraySetIcon("shell32.dll", 239)
            A_IconTip := APP_NAME " - transcribing"
        case "paused":
            try TraySetIcon("shell32.dll", 110)
            A_IconTip := APP_NAME " - PAUSED (hotkey disabled)"
        default:
            try TraySetIcon("shell32.dll", 294)
            A_IconTip := APP_NAME " - ready (hold " gCurHotkey ")"
    }
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
        Toast("Dictation paused - " gCurHotkey " released", 2000)
    } else {
        try Hotkey(gCurHotkey, "On")
        try Hotkey(gCurHotkey " Up", "On")
        LogMsg("INFO", "Resumed")
        Toast("Dictation active - hold " gCurHotkey, 2000)
    }
    BuildTray()
    SetState(gPausedState())
}

; =====================================================================
; Tray menu
; =====================================================================
BuildTray() {
    global gPaused
    m := A_TrayMenu
    m.Delete()
    m.Add("Settings...", (*) => ShowSettings())
    m.Add(gPaused ? "Resume dictation" : "Pause dictation", TogglePause)
    m.Add()
    m.Add("History...", (*) => ShowSettings(3))
    m.Add("Log...", (*) => ShowSettings(4))
    m.Add()
    m.Add(ServerAlive() ? "Unload model (free VRAM)" : "Preload model", ToggleServer)
    m.Add("Reload script", (*) => Reload())
    m.Add()
    m.Add("Exit", (*) => ExitApp())
    m.Default := "Settings..."
}

ToggleServer(*) {
    if ServerAlive() {
        StopServer("user request")
        Toast("Model unloaded - VRAM released", 2500)
    } else {
        Toast("Loading model...", 2000)
        if EnsureServerReady() {
            Toast("Model loaded and resident", 2500)
            IndHide()
        }
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

    ; ---------- History ----------
    tab.UseTab(3)
    gHistView := g.Add("ListView", "xm+10 y+14 w630 h340", ["Time", "Text"])
    gHistView.OnEvent("DoubleClick", HistCopy)
    g.Add("Text", "xm+10 y+6 w630", "Double-click a line to copy it back to the clipboard.")

    ; ---------- Log ----------
    tab.UseTab(4)
    gLogView := g.Add("Edit", "xm+10 y+14 w630 h340 ReadOnly -Wrap +HScroll")
    g.Add("Button", "xm+10 y+6 w160", "Open log folder").OnEvent("Click", (*) => Run(LogDirPath()))

    ; ---------- Buttons ----------
    tab.UseTab()
    g.Add("Button", "xm+430 y+14 w100 Default", "Save").OnEvent("Click", SaveSettings)
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
    Toast("Copied to clipboard", 1500)
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
    ; that can leave Whispers unable to transcribe, so say so immediately
    ; instead of failing at the next key press.
    if !FileExist(ModelPath()) {
        MsgBox("Tier '" Cfg["Tier"] "' needs " TierFile(Cfg["Tier"]) ", which is not installed yet.`n`n"
             . "Dictation will fail until that model is fetched.", "Whispers", "Icon!")
    }

    BuildTray()
    SetState(gPausedState())
    RefreshStatus()
    Toast("Settings saved", 1800)
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

SetAutostart(enable) {
    lnk := ShortcutPath()
    if (enable) {
        if !FileExist(lnk) {
            try {
                FileCreateShortcut(A_ScriptFullPath, lnk, A_ScriptDir)
                LogMsg("INFO", "Autostart enabled")
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
