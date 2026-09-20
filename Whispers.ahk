#Requires AutoHotkey v2.0
#SingleInstance Force

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
ApplyHotkey(Cfg["Hotkey"])
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

; A first run has no microphone yet. Pick one by measuring, not by guessing.
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

if (Cfg["VramPolicy"] = "resident")
    StartServer("startup resident policy")

SetState("idle")
if (Cfg["PlaySounds"])
    SoundBeep(800, 100)
Toast(APP_NAME " ready - hold " Cfg["Hotkey"], 2500)

; =====================================================================
; Configuration
; =====================================================================
LoadConfig() {
    global Cfg, INI_FILE
    Cfg := Map(
        ; Audio. Mic is deliberately empty by default: it is a property of
        ; the machine, never of the product, and is resolved on first run.
        "Mic",           IniRead(INI_FILE, "Audio",  "Mic",           ""),
        "MinBytes",      IniRead(INI_FILE, "Audio",  "MinBytes",      "8000"),
        "TrimSilence",   IniRead(INI_FILE, "Audio",  "TrimSilence",   "0"),
        ; Engine. The user picks a tier, never a model file.
        "Tier",          IniRead(INI_FILE, "Engine", "Tier",          "balanced"),
        "Language",      IniRead(INI_FILE, "Engine", "Language",      "fr"),
        "VramPolicy",    IniRead(INI_FILE, "Engine", "VramPolicy",    "idle"),
        "IdleMinutes",   IniRead(INI_FILE, "Engine", "IdleMinutes",   "5"),
        "Port",          IniRead(INI_FILE, "Engine", "Port",          "8910"),
        "LoadTimeout",   IniRead(INI_FILE, "Engine", "LoadTimeout",   "90"),
        "CpuFallback",   IniRead(INI_FILE, "Engine", "CpuFallback",   "1"),
        ; Paths. Empty means "use the default next to this script".
        "BinDir",        IniRead(INI_FILE, "Paths",  "BinDir",        ""),
        "ModelsDir",     IniRead(INI_FILE, "Paths",  "ModelsDir",     ""),
        ; UI.
        "Hotkey",        IniRead(INI_FILE, "UI",     "Hotkey",        "F9"),
        "AutoPaste",     IniRead(INI_FILE, "UI",     "AutoPaste",     "1"),
        "PlaySounds",    IniRead(INI_FILE, "UI",     "PlaySounds",    "1"),
        "ShowIndicator", IniRead(INI_FILE, "UI",     "ShowIndicator", "1")
    )
}

SaveConfig() {
    global Cfg, INI_FILE
    section := Map(
        "Mic","Audio", "MinBytes","Audio", "TrimSilence","Audio",
        "Tier","Engine", "Language","Engine", "VramPolicy","Engine",
        "IdleMinutes","Engine", "Port","Engine", "LoadTimeout","Engine",
        "CpuFallback","Engine",
        "BinDir","Paths", "ModelsDir","Paths",
        "Hotkey","UI", "AutoPaste","UI", "PlaySounds","UI", "ShowIndicator","UI"
    )
    for key, sec in section
        IniWrite(Cfg[key], INI_FILE, sec, key)
    LogMsg("INFO", "Settings saved")
}

; Turns the configured (or default) directories into absolute tool paths.
; Called after LoadConfig and again whenever [Paths] changes.
ResolvePaths() {
    global Cfg, ROOT_DIR, BIN_DIR, MODELS_DIR, SERVER_EXE, CLI_EXE, FFMPEG_EXE

    BIN_DIR    := Cfg["BinDir"]    != "" ? Cfg["BinDir"]    : ROOT_DIR "\bin"
    MODELS_DIR := Cfg["ModelsDir"] != "" ? Cfg["ModelsDir"] : ROOT_DIR "\models"

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
; A targeted reader rather than a full JSON parser: this file is authored
; and shipped by us, every tier object is flat, and the alternative is
; several hundred lines of parser for four lookups.
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

TierField(tier, field) {
    txt := VerRead()
    if (txt = "")
        return ""
    ; Anchor on the models.tiers object first. Tier names collide with the
    ; engine variant names - "cpu" exists in both - and searching the whole
    ; document would match the engine variant, which has no "file" key.
    pos := InStr(txt, '"tiers"')
    if (!pos)
        return ""
    txt := SubStr(txt, pos)
    ; Scope to the tier's own object: tiers contain no nested braces.
    if RegExMatch(txt, '"' tier '"\s*:\s*\{([^}]*)\}', &block) {
        if RegExMatch(block[1], '"' field '"\s*:\s*"([^"]*)"', &s)
            return s[1]
        if RegExMatch(block[1], '"' field '"\s*:\s*([^,\s}]+)', &n)
            return n[1]
    }
    return ""
}

; Returns "" when the tier cannot be resolved. Deliberately NOT falling back
; to some default model: silently loading a different model than the one the
; user selected is worse than refusing to start.
TierFile(tier) {
    f := TierField(tier, "file")
    if (f = "")
        LogMsg("ERROR", "versions.json: cannot resolve tier '" tier "' - is the file present and intact?")
    return f
}

TierVram(tier) {
    v := TierField(tier, "vram_mb")
    return IsInteger(v) ? Integer(v) : 0
}

TierNeedsGpu(tier) {
    return TierField(tier, "requires_gpu") = "true"
}

TierList() {
    return ["fast", "balanced", "max", "cpu"]
}

TierLabel(tier) {
    switch tier {
        case "fast":     return "Fast - smallest, runs on a modest GPU"
        case "balanced": return "Balanced - recommended"
        case "max":      return "Maximum accuracy - largest"
        case "cpu":      return "CPU only - no NVIDIA GPU required"
    }
    return tier
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
        txt := FileRead(path, "UTF-8")
    } catch {
        return ""
    }
    txt := Trim(StrReplace(StrReplace(txt, "`r", " "), "`n", " "))
    if (StrLen(txt) > maxChars)
        txt := "..." SubStr(txt, -maxChars)
    return txt
}

; Wraps a command line for cmd.exe. /s makes cmd strip exactly the
; first and last quote, which keeps embedded quoting predictable.
ShellCmd(inner) {
    return A_ComSpec ' /s /c "' inner '"'
}

; =====================================================================
; Device enumeration and microphone auto-detection
; =====================================================================
GetAudioDevices() {
    global FFMPEG_EXE, DEV_LOG, ROOT_DIR
    devices := []
    try FileDelete(DEV_LOG)
    RunWait(ShellCmd('"' FFMPEG_EXE '" -hide_banner -list_devices true -f dshow -i dummy 2> "' DEV_LOG '"'), ROOT_DIR, "Hide")
    if !FileExist(DEV_LOG)
        return devices
    try {
        txt := FileRead(DEV_LOG, "UTF-8")
    } catch {
        return devices
    }
    for line in StrSplit(txt, "`n", "`r") {
        if RegExMatch(line, '"([^"]+)"\s+\(audio\)', &m)
            devices.Push(m[1])
    }
    return devices
}

; Records a short sample from one device and returns its mean level in dB
; (-91 means digital silence). Returns "" when the device cannot be opened.
MicLevel(device, seconds := 2) {
    global FFMPEG_EXE, TEMP_DIR, ROOT_DIR
    probe := TEMP_DIR "\miclevel.raw"
    plog  := TEMP_DIR "\miclevel.log"
    try FileDelete(probe)
    try FileDelete(plog)

    inner := '"' FFMPEG_EXE '" -y -f dshow -i audio="' device '" -t ' seconds
           . ' -ac 1 -ar 16000 -af volumedetect -f s16le "' probe '" 2> "' plog '"'
    RunWait(ShellCmd(inner), ROOT_DIR, "Hide")

    if (!FileExist(probe) || FileGetSize(probe) < 1000)
        return ""
    detail := TailFile(plog, 4000)
    try FileDelete(probe)
    if RegExMatch(detail, "mean_volume:\s*(-?[\d.]+) dB", &m)
        return m[1] + 0
    return ""
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

; Windows endpoint names and ffmpeg's dshow names usually match exactly,
; but dshow truncates some of them, so fall back to a prefix match before
; giving up.
MatchDevice(name, devices) {
    if (name = "")
        return ""
    for d in devices
        if (d = name)
            return d
    for d in devices
        if (SubStr(d, 1, StrLen(name)) = name || SubStr(name, 1, StrLen(d)) = name)
            return d
    return ""
}

; Devices that route other programs' audio rather than a microphone. They
; are excluded from the measured fallback because they are frequently the
; loudest thing on the machine while carrying no speech at all.
IsVirtualDevice(name) {
    for pat in ["virtual", "cable", "stereo mix", "mixage", "voicemeeter", "loopback", "what u hear", "sonar"]
        if InStr(name, pat)
            return true
    return false
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

    if (best = "") {
        LogMsg("WARN", "No physical microphone could be probed - defaulting to " devices[1])
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
    RunWait(ShellCmd('nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader,nounits > "' GPU_LOG '" 2>&1'), ROOT_DIR, "Hide")
    if FileExist(GPU_LOG) {
        try {
            line := StrSplit(Trim(FileRead(GPU_LOG)), "`n", "`r")[1]
            parts := StrSplit(line, ",")
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
        RunWait(ShellCmd('nvidia-smi -q > "' GPU_LOG '" 2>&1'), ROOT_DIR, "Hide")
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

; The tier this machine should run, used by the installer and offered as
; a suggestion in the settings window.
RecommendedTier() {
    g := GpuInfo()
    if (!g["present"])
        return "cpu"
    total := g["vramTotal"]
    if (total >= 8000)
        return "max"
    if (total >= 5000)
        return "balanced"
    if (total >= 3000)
        return "fast"
    return "cpu"
}

; =====================================================================
; whisper-server lifecycle
; =====================================================================
ServerAlive() {
    global CURL_EXE, Cfg, ROOT_DIR
    inner := '"' CURL_EXE '" -s -o nul --max-time 2 http://127.0.0.1:' Cfg["Port"] '/'
    return RunWait(ShellCmd(inner), ROOT_DIR, "Hide") = 0
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
    inner := '"' SERVER_EXE '" -m "' model '" -l ' Cfg["Language"] ' -nt --port ' Cfg["Port"] ' > "' SRV_LOG '" 2>&1'
    Run(ShellCmd(inner), ROOT_DIR, "Hide", &pid)
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

    inner := '"' FFMPEG_EXE '" -y -f dshow -i audio="' Cfg["Mic"] '" -ac 1 -ar 16000 -f s16le -flush_packets 1 "' TEMP_RAW '" 2> "' MIC_LOG '"'
    Run(ShellCmd(inner), ROOT_DIR, "Hide", &pid)
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
        Fail("Too short (" Round(rawSize / 32000, 2) "s) - hold the key while speaking", "")
        gStopping := false
        return false
    }

    IndSet("Converting...", "C87A00")

    filter := Cfg["TrimSilence"]
        ? ' -af silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.1:stop_periods=-1:stop_threshold=-50dB:stop_silence=0.4 '
        : ' '
    inner := '"' FFMPEG_EXE '" -y -f s16le -ar 16000 -ac 1 -i "' TEMP_RAW '"' filter '"' TEMP_WAV '" 2>> "' MIC_LOG '"'
    RunWait(ShellCmd(inner), ROOT_DIR, "Hide")

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
    inner := '"' CURL_EXE '" -s --max-time 120 -X POST http://127.0.0.1:' Cfg["Port"] '/inference'
           . ' -F "file=@' TEMP_WAV '"'
           . ' -F "response_format=text"'
           . ' -F "language=' Cfg["Language"] '"'
           . ' -F "no_timestamps=true"'
           . ' > "' TEMP_TXT '" 2> "' CURL_LOG '"'

    t0 := A_TickCount
    ec := RunWait(ShellCmd(inner), ROOT_DIR, "Hide")
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
    gpu  := forceCpu ? " -ng" : ""

    try FileDelete(TEMP_TXT)
    inner := '"' CLI_EXE '" -m "' model '" -l ' Cfg["Language"] ' -nt' gpu
           . ' -of "' base '" -otxt -f "' TEMP_WAV '" > "' SRV_LOG '" 2>&1'

    t0 := A_TickCount
    ec := RunWait(ShellCmd(inner), ROOT_DIR, "Hide")
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

    preview := StrLen(text) > 60 ? SubStr(text, 1, 57) "..." : text
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

; =====================================================================
; History
; =====================================================================
LoadHistory() {
    global HIST_FILE, gHistory
    gHistory := []
    if !FileExist(HIST_FILE)
        return
    try {
        txt := FileRead(HIST_FILE, "UTF-8")
    } catch {
        return
    }
    for line in StrSplit(txt, "`n", "`r") {
        if (Trim(line) = "")
            continue
        parts := StrSplit(line, "`t")
        if (parts.Length >= 2)
            gHistory.Push(Map("time", parts[1], "text", parts[2]))
    }
}

AddHistory(text) {
    global gHistory, HIST_FILE
    flat := Trim(StrReplace(StrReplace(StrReplace(text, "`r", " "), "`n", " "), "`t", " "))
    gHistory.InsertAt(1, Map("time", FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss"), "text", flat))
    while (gHistory.Length > 20)
        gHistory.Pop()

    out := ""
    for item in gHistory
        out .= item["time"] "`t" item["text"] "`r`n"
    try FileDelete(HIST_FILE)
    try FileAppend(out, HIST_FILE, "UTF-8")
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

HasValue(arr, val) {
    for v in arr
        if (v = val)
            return true
    return false
}

LogDirPath() {
    global LOG_DIR
    return LOG_DIR
}

; Maps the human-readable dropdown entry back to its tier key.
SelectedTier() {
    global gCtl
    for t in TierList()
        if (TierLabel(t) = gCtl["Tier"].Text)
            return t
    return "balanced"
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
    gCtl["MicResult"].Value := (lvl <= -90)
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
    Cfg["IdleMinutes"] := gCtl["IdleMinutes"].Value
    Cfg["Port"] := gCtl["Port"].Value
    Cfg["LoadTimeout"] := gCtl["LoadTimeout"].Value
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
