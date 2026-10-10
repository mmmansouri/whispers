#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Off

; =====================================================================
; Unit tests for the pure core.
;
;   AutoHotkey64.exe tests\run-tests.ahk
;
; Writes tests\results.txt and exits with the number of failures, so it
; can gate a build. Loading lib\ runs nothing, which is the whole point
; of keeping the bootstrap out of it: no server is started, no hotkey is
; registered and no microphone is opened by this file.
;
; Several cases below are marked REGRESSION. Those are not hypothetical:
; each one is a bug that reached the running product and was caught by
; hand. They exist so it cannot happen twice.
; =====================================================================

#Include %A_LineFile%\..\..\lib\Text.ahk
#Include %A_LineFile%\..\..\lib\Config.ahk
#Include %A_LineFile%\..\..\lib\Tiers.ahk
#Include %A_LineFile%\..\..\lib\Devices.ahk
#Include %A_LineFile%\..\..\lib\Commands.ahk
#Include %A_LineFile%\..\..\lib\Net.ahk
#Include %A_LineFile%\..\..\lib\Install.ahk
#Include %A_LineFile%\..\..\lib\Indicator.ahk
#Include %A_LineFile%\..\..\lib\Tray.ahk

gPass := 0
gFail := 0
gLines := []
gGroup := ""

; A test runner that can block on a modal error dialog is useless in a
; build: turn any uncaught error into a recorded failure and exit.
OnError(Fatal)

Fatal(err, mode) {
    global gFail, gLines
    gFail++
    gLines.Push("  FAIL uncaught error: " err.Message " (" err.File ":" err.Line ")")
    Report()
    return 1
}

Group(name) {
    global gGroup, gLines
    gGroup := name
    gLines.Push("")
    gLines.Push("--- " name " ---")
}

Eq(what, actual, expected) {
    global gPass, gFail, gLines
    if (actual == expected) {
        gPass++
        gLines.Push("  ok   " what)
        return
    }
    gFail++
    gLines.Push("  FAIL " what)
    gLines.Push("         expected: [" expected "]")
    gLines.Push("         actual:   [" actual "]")
}

Yes(what, actual) {
    Eq(what, actual ? 1 : 0, 1)
}

No(what, actual) {
    Eq(what, actual ? 1 : 0, 0)
}

Has(what, haystack, needle) {
    global gPass, gFail, gLines
    if InStr(haystack, needle) {
        gPass++
        gLines.Push("  ok   " what)
        return
    }
    gFail++
    gLines.Push("  FAIL " what)
    gLines.Push("         [" needle "] not found in:")
    gLines.Push("         " haystack)
}

Lacks(what, haystack, needle) {
    global gPass, gFail, gLines
    if !InStr(haystack, needle) {
        gPass++
        gLines.Push("  ok   " what)
        return
    }
    gFail++
    gLines.Push("  FAIL " what)
    gLines.Push("         [" needle "] should NOT appear in:")
    gLines.Push("         " haystack)
}

; =====================================================================
Group("Commands - cmd.exe wrapping")

Has("ShellCmd uses /s /c", ShellCmd("x"), " /s /c ")
Has("ShellCmd wraps the whole line in one pair of quotes", ShellCmd("abc"), '/c "abc"')
Eq("ShellCmd adds no trailing character", SubStr(ShellCmd("abc"), -1), '"')

Group("Commands - ffmpeg capture")

rec := CmdRecord("C:\p f\ffmpeg.exe", "Microphone (HyperX QuadCast S)", "C:\t\a b.raw", "C:\t\f.log")
Has("device name is quoted", rec, 'audio="Microphone (HyperX QuadCast S)"')
Has("executable with a space is quoted", rec, '"C:\p f\ffmpeg.exe"')
Has("output path with a space is quoted", rec, '"C:\t\a b.raw"')
Has("stderr is redirected to the log", rec, '2> "C:\t\f.log"')
Has("mono", rec, "-ac 1")
Has("16 kHz", rec, "-ar 16000")
Has("raw PCM", rec, "-f s16le")
Has("packets are flushed so a killed capture is still usable", rec, "-flush_packets 1")
Lacks("open-ended: no duration limit", rec, " -t ")

lvl := CmdMicLevel("ffmpeg.exe", "Line 1 (Virtual Audio Cable)", 3, "p.raw", "p.log")
Has("level probe is time limited", lvl, "-t 3")
Has("level probe asks for volumedetect", lvl, "-af volumedetect")

dev := CmdListDevices("C:\p ffmpeg.exe", "C:\l\d.log")
Has("enumeration quotes the executable", dev, '"C:\p ffmpeg.exe"')
Has("enumeration asks dshow to list devices", dev, "-list_devices true -f dshow")
Has("enumeration needs a dummy input", dev, "-i dummy")
Has("the list arrives on stderr, so stderr is what we capture", dev, '2> "C:\l\d.log"')

Group("Commands - conversion")

plain := CmdConvert("ffmpeg.exe", "in.raw", "out.wav", "c.log", false)
Lacks("no filter when trimming is off", plain, "silenceremove")
Has("input format is declared for a headerless file", plain, "-f s16le -ar 16000 -ac 1 -i")
Has("conversion appends to the capture log", plain, '2>> "c.log"')

trimmed := CmdConvert("ffmpeg.exe", "in.raw", "out.wav", "c.log", true)
Has("filter present when trimming is on", trimmed, "silenceremove")
Has("filter trims the start", trimmed, "start_periods=1")
Has("filter trims every trailing silence", trimmed, "stop_periods=-1")

Group("Commands - whisper")

srv := CmdServer("C:\b\whisper-server.exe", "C:\m\ggml-large-v3.bin", "fr", 8910, "C:\l\s.log")
Has("model path is quoted", srv, '-m "C:\m\ggml-large-v3.bin"')
Has("language is passed", srv, "-l fr")
Has("timestamps are suppressed", srv, "-nt")
Has("port is passed", srv, "--port 8910")
Has("stdout and stderr both go to the log", srv, '> "C:\l\s.log" 2>&1')

gpu := CmdCli("cli.exe", "m.bin", "fr", false, "C:\t\out", "C:\t\a.wav", "l.log")
Lacks("no -ng when the GPU is wanted", gpu, "-ng")
cpu := CmdCli("cli.exe", "m.bin", "fr", true, "C:\t\out", "C:\t\a.wav", "l.log")
Has("-ng forces CPU", cpu, " -ng")
Lacks("output base carries no extension: whisper-cli appends .txt itself",
      cpu, 'out.txt" -otxt')
Has("output base is quoted", cpu, '-of "C:\t\out"')

Group("Commands - curl")

inf := CmdInference("curl.exe", 8910, "C:\t\a.wav", "fr", "C:\t\o.txt", "C:\t\e.log")
Has("posts to /inference on loopback", inf, "http://127.0.0.1:8910/inference")
Has("uploads the wav as a file part", inf, '-F "file=@C:\t\a.wav"')
Has("asks for plain text", inf, 'response_format=text')
Has("passes the language", inf, 'language=fr')
Has("suppresses timestamps", inf, 'no_timestamps=true')
Has("body and errors are captured separately", inf, '> "C:\t\o.txt" 2> "C:\t\e.log"')

alive := CmdServerAlive("curl.exe", 8910)
Has("liveness probe discards the body", alive, "-o nul")
Has("liveness probe cannot hang the hotkey thread", alive, "--max-time 2")

Group("Commands - nvidia-smi")

Has("summary asks for the three values in one call",
    CmdGpuSummary("g.log"), "--query-gpu=name,memory.total,memory.free")
Has("summary output is machine readable", CmdGpuSummary("g.log"), "csv,noheader,nounits")
Has("verbose form is used for the CUDA version", CmdGpuFull("g.log"), "nvidia-smi -q")

; =====================================================================
Group("Tiers - parsing")

; A miniature versions.json reproducing the trap that broke the product:
; "cpu" exists both as an engine variant and as a model tier.
J := '
(
{
  "engine": { "variants": {
    "cuda-12.4": { "asset": "whisper-cublas-12.4.0-bin-x64.zip" },
    "cpu": { "asset": "whisper-blas-bin-x64.zip" }
  } },
  "models": { "tiers": {
    "fast":     { "file": "f.bin", "vram_mb": 1500, "requires_gpu": true },
    "balanced": { "file": "b.bin", "vram_mb": 2800, "requires_gpu": true },
    "max":      { "file": "m.bin", "vram_mb": 4700, "requires_gpu": true },
    "cpu":      { "file": "s.bin", "vram_mb": 0,    "requires_gpu": false }
  } }
}
)'

Eq("REGRESSION: cpu resolves to the model tier, not the engine variant",
   TierFileFrom(J, "cpu"), "s.bin")
Eq("fast resolves", TierFileFrom(J, "fast"), "f.bin")
Eq("balanced resolves", TierFileFrom(J, "balanced"), "b.bin")
Eq("max resolves", TierFileFrom(J, "max"), "m.bin")

Eq("unknown tier yields nothing", TierFileFrom(J, "turbo"), "")
Eq("empty tier yields nothing", TierFileFrom(J, ""), "")
Eq("REGRESSION: an empty document never yields a plausible default",
   TierFileFrom("", "max"), "")
Eq("a document without a tiers block yields nothing",
   TierFileFrom('{"engine":{"variants":{"cpu":{"asset":"x"}}}}', "cpu"), "")
Eq("truncated JSON yields nothing", TierFileFrom('{"tiers": {"max": {"file"', "max"), "")

Eq("numeric field is read as an integer", TierVramFrom(J, "max"), 4700)
Eq("zero stays zero", TierVramFrom(J, "cpu"), 0)
Eq("missing numeric field is zero", TierVramFrom(J, "nope"), 0)
Yes("GPU tier requires a GPU", TierNeedsGpuFrom(J, "max"))
No("CPU tier does not", TierNeedsGpuFrom(J, "cpu"))

Eq("TierField reads a string field", TierField(J, "max", "file"), "m.bin")
Eq("TierField reads an unquoted field", TierField(J, "max", "vram_mb"), "4700")
Eq("TierField reads a boolean field", TierField(J, "cpu", "requires_gpu"), "false")
Eq("TierField on an unknown field yields nothing", TierField(J, "max", "colour"), "")
Eq("TierField on an unknown tier yields nothing", TierField(J, "ludicrous", "file"), "")
Eq("REGRESSION: TierField never reaches outside the tiers block",
   TierField(J, "cpu", "asset"), "")

Group("Tiers - removing the previous model")

; A tier change used to keep the previous model on disk, 3 GB for max.
others := OtherTierFiles(J, "max")
Eq("every other tier's model is a candidate", others.Length, 3)
No("the model of the tier being kept never is", HasValue(others, "m.bin"))
Yes("the cpu tier's model is a candidate", HasValue(others, "s.bin"))
No("the cpu engine archive never is, despite sharing the name", HasValue(others, "whisper-blas-bin-x64.zip"))
Eq("a tier that cannot be resolved removes nothing", OtherTierFiles(J, "turbo").Length, 0)
Eq("an empty document removes nothing", OtherTierFiles("", "max").Length, 0)
Eq("a document without tiers removes nothing",
   OtherTierFiles('{"engine":{"variants":{"cpu":{"asset":"x"}}}}', "cpu").Length, 0)

Yes("an empty models setting is Whispers' own directory", UsesDefaultDir(""))
Yes("a cleared field is the default too", UsesDefaultDir("  "))
No("an override is somebody else's directory, never pruned", UsesDefaultDir("C:\dev\whisper.cpp\models"))

Group("Tiers - labels")

for t in TierList()
    Eq("label round-trips for " t, TierFromLabel(TierLabel(t)), t)
Eq("unknown label yields nothing", TierFromLabel("Ludicrous speed"), "")
Eq("four tiers", TierList().Length, 4)

Group("Tiers - recommendation")

Eq("no GPU means CPU", RecommendTier(false, 0), "cpu")
Eq("a large card even without VRAM reported still means CPU when absent",
   RecommendTier(false, 24000), "cpu")
Eq("12 GB card takes the largest model", RecommendTier(true, 12282), "max")
Eq("8 GB is the boundary for max", RecommendTier(true, 8000), "max")
Eq("just under 8 GB drops to balanced", RecommendTier(true, 7999), "balanced")
Eq("5 GB is the boundary for balanced", RecommendTier(true, 5000), "balanced")
Eq("just under 5 GB drops to fast", RecommendTier(true, 4999), "fast")
Eq("3 GB is the boundary for fast", RecommendTier(true, 3000), "fast")
Eq("below 3 GB falls back to CPU", RecommendTier(true, 2999), "cpu")

Group("Tiers - the shipped versions.json")

verPath := A_ScriptDir "\..\versions.json"
Yes("versions.json is present", FileExist(verPath))
ver := FileExist(verPath) ? FileRead(verPath, "UTF-8") : ""
for t in TierList() {
    f := TierFileFrom(ver, t)
    Yes("shipped file declared for tier " t, f != "")
    Has("tier " t " names a ggml model", f, "ggml-")
    Has("tier " t " names a .bin", f, ".bin")
}
Eq("shipped CPU tier uses small, as measured", TierFileFrom(ver, "cpu"), "ggml-small.bin")
Yes("shipped max tier declares its VRAM", TierVramFrom(ver, "max") > 0)
No("shipped CPU tier does not require a GPU", TierNeedsGpuFrom(ver, "cpu"))

; =====================================================================
Group("Devices - parsing ffmpeg output")

; Captured verbatim from this machine, including the video devices that
; must not be mistaken for microphones.
DEVLOG := '
(
[dshow @ 0000] "HD Pro Webcam C920" (video)
[dshow @ 0000]   Alternative name "@device_pnp_\\?\usb#vid_046d"
[dshow @ 0000] "Microphone (HyperX QuadCast S)" (audio)
[dshow @ 0000] "Line 1 (Virtual Audio Cable)" (audio)
[dshow @ 0000] "Microphone (Logitech StreamCam)" (audio)
[dshow @ 0000] "AI Noise-Canceling Microphone (ASUS Utility)" (audio)
[dshow @ 0000] "SteelSeries Sonar - Microphone (SteelSeries Sonar Virtual Audio Device)" (audio)
)'

devs := ParseDshowAudioDevices(DEVLOG)
Eq("five audio devices found", devs.Length, 5)
Eq("first is the HyperX", devs[1], "Microphone (HyperX QuadCast S)")
No("video devices are excluded", HasValue(devs, "HD Pro Webcam C920"))
Eq("no devices in empty output", ParseDshowAudioDevices("").Length, 0)
Eq("no devices in unrelated output", ParseDshowAudioDevices("ffmpeg version 9.0.2").Length, 0)

Group("Devices - level parsing")

VOL := "[Parsed_volumedetect_0 @ 0] mean_volume: -80.3 dB`n[Parsed_volumedetect_0 @ 0] max_volume: -47.1 dB"
Eq("mean level is read", ParseMeanVolume(VOL), -80.3)
Eq("peak level is read", ParseMaxVolume(VOL), -47.1)
Eq("absent mean yields nothing", ParseMeanVolume("no filter ran"), "")
Eq("a positive-looking value is still parsed", ParseMeanVolume("mean_volume: 0.0 dB"), 0)

Yes("the digital silence floor counts as silent", IsSilentLevel(-91))
Yes("exactly -90 counts as silent", IsSilentLevel(-90))
Yes("a failed probe counts as silent", IsSilentLevel(""))
No("a quiet room is not silence", IsSilentLevel(-80.3))
No("normal speech is not silence", IsSilentLevel(-25.9))

Group("Devices - virtual device detection")

Yes("REGRESSION: the virtual cable that beat the real mic is classified virtual",
     IsVirtualDevice("Line 1 (Virtual Audio Cable)"))
Yes("Sonar routing device is virtual",
     IsVirtualDevice("SteelSeries Sonar - Microphone (SteelSeries Sonar Virtual Audio Device)"))
Yes("stereo mix is virtual", IsVirtualDevice("Stereo Mix (Realtek)"))
Yes("localised stereo mix is virtual", IsVirtualDevice("Mixage stereo"))
Yes("VoiceMeeter is virtual", IsVirtualDevice("VoiceMeeter Output"))
No("a real USB microphone is not virtual", IsVirtualDevice("Microphone (HyperX QuadCast S)"))

; A tap on the hotkey used to be reported as "Mic capture failed",
; because ffmpeg is killed before it opens the device and no file exists
; - which on disk is indistinguishable from a broken microphone.
Yes("REGRESSION: a tap is too short to have captured anything", CaptureTooShort(300))
Yes("so is a one-second press", CaptureTooShort(1000))
No("a two-second press is long enough", CaptureTooShort(2000))
No("and a normal dictation certainly is", CaptureTooShort(8000))
; Defensive: a clock that went backwards must not be read as a long press.
Yes("a negative elapsed time is too short", CaptureTooShort(-50))
No("a webcam microphone is not virtual", IsVirtualDevice("Microphone (Logitech StreamCam)"))

Group("Devices - endpoint to dshow mapping")

D := ["Microphone (HyperX QuadCast S)", "Line 1 (Virtual Audio Cable)",
      "AI Noise-Canceling Microphone (ASUS Utility)"]

Eq("exact name matches", MatchDevice("Microphone (HyperX QuadCast S)", D),
   "Microphone (HyperX QuadCast S)")
Eq("a Windows name truncated by dshow still matches",
   MatchDevice("AI Noise-Canceling Microphone (ASUS Utility) Extended", D),
   "AI Noise-Canceling Microphone (ASUS Utility)")
Eq("a dshow name longer than the Windows one still matches",
   MatchDevice("AI Noise-Canceling", D), "AI Noise-Canceling Microphone (ASUS Utility)")
Eq("an unrelated name matches nothing", MatchDevice("Realtek Digital Input", D), "")
Eq("an empty name matches nothing", MatchDevice("", D), "")
Eq("nothing matches an empty list", MatchDevice("Microphone (HyperX QuadCast S)", []), "")
Eq("a prefix too short to be meaningful is refused", MatchDevice("Mic", D), "")

; =====================================================================
Group("Text - log tails")

Eq("a short message is returned whole", TailText("boom"), "boom")
Lacks("a short message gets no ellipsis", TailText("boom"), "...")
Eq("empty in, empty out", TailText(""), "")
Eq("newlines are collapsed to spaces", TailText("a`r`nb"), "a b")
long := ""
Loop 300
    long .= "0123456789"
tail := TailText(long, 100)
Has("a long message is marked as truncated", tail, "...")
Yes("the tail is bounded", StrLen(tail) <= 104)
Has("it is the TAIL that is kept, where the error is", TailText("start " long, 20), SubStr(long, -20))

Group("Text - history safety")

Eq("REGRESSION: tabs are stripped before a TSV write",
   FlattenText("col1`tcol2"), "col1 col2")
Eq("newlines are stripped too", FlattenText("line1`r`nline2"), "line1 line2")
Eq("surrounding whitespace is trimmed", FlattenText("  hi  "), "hi")

roundTrip := FormatHistoryText([Map("time", "2026-09-20 18:00:00", "text", "bonjour")])
items := ParseHistoryText(roundTrip)
Eq("history round-trips one entry", items.Length, 1)
Eq("time survives", items[1]["time"], "2026-09-20 18:00:00")
Eq("text survives", items[1]["text"], "bonjour")
Eq("a trailing blank line is ignored", ParseHistoryText("a`tb`r`n`r`n").Length, 1)
Eq("a line without a tab is skipped", ParseHistoryText("garbage").Length, 0)
Eq("an empty file yields no history", ParseHistoryText("").Length, 0)

Group("Text - previews and lookup")

Eq("a short text is shown whole", PreviewText("court"), "court")
Eq("a long text is elided to the limit", StrLen(PreviewText(long, 60)), 60)
Has("the elision is visible", PreviewText(long, 60), "...")
Yes("HasValue finds a member", HasValue(["a", "b"], "b"))
No("HasValue rejects a non-member", HasValue(["a", "b"], "c"))
No("HasValue on an empty list", HasValue([], "a"))

; =====================================================================
Group("Config - schema")

spec := ConfigSpec()
Eq("eighteen settings", spec.Count, 18)
for key, def in spec {
    Yes(key " declares a section", def[1] != "")
    Yes(key " sits in a known section", HasValue(["Audio", "Engine", "Paths", "UI"], def[1]))
}
Eq("the microphone has no default: it belongs to the machine", spec["Mic"][2], "")
Eq("BinDir defaults to empty, meaning next to the script", spec["BinDir"][2], "")
Yes("the default tier is a real tier", IsValidTier(spec["Tier"][2]))
Yes("the default policy is a real policy", IsValidPolicy(spec["VramPolicy"][2]))

Group("Config - path resolution")

Eq("an override wins", ResolveDir("D:\\custom", "C:\\default"), "D:\\custom")
Eq("empty falls back", ResolveDir("", "C:\\default"), "C:\\default")
Eq("REGRESSION: a cleared field is whitespace, not a path",
   ResolveDir("   ", "C:\\default"), "C:\\default")
Eq("an override is trimmed", ResolveDir("  D:\\x  ", "C:\\d"), "D:\\x")

Group("Config - sanitising free text")

Eq("a valid port passes", SanitizePort("8910"), 8910)
Eq("a non-numeric port falls back", SanitizePort("eight thousand"), 8910)
Eq("an empty port falls back", SanitizePort(""), 8910)
Eq("a privileged port is raised to the floor", SanitizePort("80"), 1024)
Eq("a port above the range is capped", SanitizePort("99999"), 65535)
Eq("a negative port is raised to the floor", SanitizePort("-1"), 1024)

Eq("a valid idle delay passes", SanitizeIdleMinutes("5"), 5)
Eq("zero would unload between dictations, so it is raised", SanitizeIdleMinutes("0"), 1)
Eq("a day is the cap", SanitizeIdleMinutes("99999"), 1440)
Eq("nonsense falls back", SanitizeIdleMinutes("soon"), 5)

Eq("a valid timeout passes", SanitizeLoadTimeout("90"), 90)
Eq("too short a timeout is raised", SanitizeLoadTimeout("1"), 10)
Eq("too long a timeout is capped", SanitizeLoadTimeout("9999"), 600)

Eq("a valid minimum passes", SanitizeMinBytes("8000"), 8000)
Eq("an absurd minimum is capped", SanitizeMinBytes("999999999"), 1000000)

Eq("SanitizeInt keeps a value in range", SanitizeInt("50", 1, 100, 10), 50)
Eq("SanitizeInt raises below the floor", SanitizeInt("0", 1, 100, 10), 1)
Eq("SanitizeInt caps above the ceiling", SanitizeInt("500", 1, 100, 10), 100)
Eq("SanitizeInt falls back on text", SanitizeInt("abc", 1, 100, 10), 10)
Eq("SanitizeInt falls back on the empty string", SanitizeInt("", 1, 100, 10), 10)
Eq("SanitizeInt rejects a decimal rather than truncating it",
   SanitizeInt("3.7", 1, 100, 10), 10)
Eq("SanitizeInt accepts the floor itself", SanitizeInt("1", 1, 100, 10), 1)
Eq("SanitizeInt accepts the ceiling itself", SanitizeInt("100", 1, 100, 10), 100)

Group("Config - validation and units")

Yes("balanced is a tier", IsValidTier("balanced"))
No("turbo is not a tier", IsValidTier("turbo"))
No("empty is not a tier", IsValidTier(""))
Yes("idle is a policy", IsValidPolicy("idle"))
Yes("resident is a policy", IsValidPolicy("resident"))
Yes("never is a policy", IsValidPolicy("never"))

Yes("update checking is a stored setting", spec.Has("CheckUpdates"))
Yes("whether setup has run is a stored setting", spec.Has("Configured"))
Eq("update checking is on by default", spec["CheckUpdates"][2], "1")
; A fresh install has not been through setup. An upgrade is recognised by
; its existing microphone instead, so it is not sent back through it.
Eq("setup has not run by default", spec["Configured"][2], "0")
Eq("both are UI settings", spec["CheckUpdates"][1], "UI")
No("sometimes is not a policy", IsValidPolicy("sometimes"))

Eq("one second of 16 kHz mono 16-bit is 32000 bytes", RawBytesToSeconds(32000), 1)
Eq("half a second", RawBytesToSeconds(16000), 0.5)
Eq("an empty capture is zero seconds", RawBytesToSeconds(0), 0)

; =====================================================================
Group("Net - certutil output")

; Real output from this project's own machine. The words around the hash
; are translated by Windows; the hash is not.
FRENCH := "Hachage SHA256 de D:\x\versions.json :`r`n"
        . "e60abb78b5189b59bfcee190b3334480b9d0af58e834fa78cd4853dca65f828a`r`n"
        . "CertUtil: -hashfile La commande s'est terminee correctement.`r`n"
ENGLISH := "SHA256 hash of D:\x\versions.json:`r`n"
         . "E60ABB78B5189B59BFCEE190B3334480B9D0AF58E834FA78CD4853DCA65F828A`r`n"
         . "CertUtil: -hashfile command completed successfully.`r`n"

Eq("a localised certutil report still yields the hash", ParseCertutilHash(FRENCH),
   "e60abb78b5189b59bfcee190b3334480b9d0af58e834fa78cd4853dca65f828a")
Eq("an English report yields the same hash, lower-cased", ParseCertutilHash(ENGLISH),
   "e60abb78b5189b59bfcee190b3334480b9d0af58e834fa78cd4853dca65f828a")
Eq("space-separated pairs are still one hash",
   ParseCertutilHash("hash:`r`ne6 0a bb 78 b5 18 9b 59 bf ce e1 90 b3 33 44 80 "
                   . "b9 d0 af 58 e8 34 fa 78 cd 48 53 dc a6 5f 82 8a`r`n"),
   "e60abb78b5189b59bfcee190b3334480b9d0af58e834fa78cd4853dca65f828a")
Eq("no hash in the text is no hash", ParseCertutilHash("CertUtil: access denied."), "")
Eq("an empty report is no hash", ParseCertutilHash(""), "")

Group("Net - hash comparison")

H := "e60abb78b5189b59bfcee190b3334480b9d0af58e834fa78cd4853dca65f828a"
Yes("identical hashes match", HashMatches(H, H))
Yes("case does not matter", HashMatches(StrUpper(H), H))
Yes("surrounding whitespace does not matter", HashMatches(" " H " ", H))
No("a different hash does not match", HashMatches(H, StrReplace(H, "e6", "e7")))
; The failure that must never be silent: an absent expected hash would
; otherwise make every download acceptable.
No("an empty expected hash never matches", HashMatches("", H))
No("an empty actual hash never matches", HashMatches(H, ""))
No("a truncated expected hash never matches", HashMatches(SubStr(H, 1, 32), H))
No("a non-hex expected hash never matches", HashMatches(StrReplace(H, "e", "z"), H))

Group("Net - version comparison")

Eq("a leading v is not part of the version", NormalizeVersion("v2.1.0"), "2.1.0")
Eq("an uppercase V too", NormalizeVersion("V2.1.0"), "2.1.0")
Eq("a bare version is unchanged", NormalizeVersion("2.1.0"), "2.1.0")

Eq("equal versions compare equal", CompareVersions("2.0.0", "2.0.0"), 0)
Eq("a tag and a bare version compare equal", CompareVersions("v2.0.0", "2.0.0"), 0)
Eq("2.1.0 is above 2.0.9", CompareVersions("2.1.0", "2.0.9"), 1)
; Field-by-field, as numbers. A string comparison puts 2.10.0 below
; 2.9.0, which would stop offering updates after the ninth release.
Eq("2.10.0 is above 2.9.0", CompareVersions("2.10.0", "2.9.0"), 1)
Eq("2.0 equals 2.0.0", CompareVersions("2.0", "2.0.0"), 0)
Eq("3.0 is above 2.99.99", CompareVersions("3.0", "2.99.99"), 1)

Yes("a higher version is newer", IsNewerVersion("2.0.0", "2.0.1"))
Yes("a tagged higher version is newer", IsNewerVersion("2.0.0", "v3.0.0"))
No("the same version is not newer", IsNewerVersion("2.0.0", "2.0.0"))
No("an older version is not newer", IsNewerVersion("2.0.0", "1.9.9"))
; A mangled or hostile response must not be able to push an update.
No("an empty candidate is not newer", IsNewerVersion("2.0.0", ""))
No("a non-numeric candidate is not newer", IsNewerVersion("2.0.0", "latest"))
No("a candidate with a suffix is not newer", IsNewerVersion("2.0.0", "9.9.9-evil"))
No("an unknown current version accepts nothing", IsNewerVersion("", "9.9.9"))

Group("Net - leftover update installers")
Yes("a downloaded update installer is recognised", IsUpdateInstallerName("Whispers-2.2.0-setup.exe"))
Yes("so is a half-downloaded one", IsUpdateInstallerName("Whispers-2.2.0-setup.exe.part"))
Yes("the case does not matter", IsUpdateInstallerName("whispers-2.10.1-SETUP.EXE"))
No("the capture is not an installer", IsUpdateInstallerName("capture.wav"))
No("another program's installer is not ours", IsUpdateInstallerName("Other-1.0-setup.exe"))
No("a name merely containing ours is not ours", IsUpdateInstallerName("old-Whispers-2.2.0-setup.exe"))

Group("Net - release metadata")

; Trimmed from a real api.github.com response, keeping the field order
; and a second asset, because pairing one asset's name with another
; asset's URL is the mistake this shape invites.
REL := '{"tag_name":"v2.1.0","draft":false,"prerelease":false,"assets":['
     . '{"name":"Whispers-2.1.0-portable.zip","size":12,'
     . '"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111",'
     . '"browser_download_url":"https://github.com/o/r/releases/download/v2.1.0/Whispers-2.1.0-portable.zip"},'
     . '{"name":"Whispers-2.1.0-setup.exe","size":34,'
     . '"digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222",'
     . '"browser_download_url":"https://github.com/o/r/releases/download/v2.1.0/Whispers-2.1.0-setup.exe"}]}'

Eq("the tag is read", ReleaseTagFrom(REL), "v2.1.0")
Eq("an empty document has no tag", ReleaseTagFrom(""), "")
Yes("a normal release is published", IsPublishedRelease(REL))
No("a draft is not published", IsPublishedRelease(StrReplace(REL, '"draft":false', '"draft":true')))
No("a pre-release is not published", IsPublishedRelease(StrReplace(REL, '"prerelease":false', '"prerelease":true')))
No("an empty document is not a release", IsPublishedRelease(""))

asset := ReleaseAssetFrom(REL, "-setup.exe")
Eq("the asset is selected by suffix", asset["name"], "Whispers-2.1.0-setup.exe")
Eq("it carries its OWN url", asset["url"],
   "https://github.com/o/r/releases/download/v2.1.0/Whispers-2.1.0-setup.exe")
Eq("it carries its OWN digest, not the previous asset's", asset["sha256"],
   "2222222222222222222222222222222222222222222222222222222222222222")

zipAsset := ReleaseAssetFrom(REL, ".zip")
Eq("a different suffix selects a different asset", zipAsset["name"], "Whispers-2.1.0-portable.zip")
Eq("with that asset's digest", zipAsset["sha256"],
   "1111111111111111111111111111111111111111111111111111111111111111")

Eq("an unknown suffix selects nothing", ReleaseAssetFrom(REL, ".msi")["url"], "")
Eq("an empty document selects nothing", ReleaseAssetFrom("", "-setup.exe")["url"], "")
Eq("an empty suffix selects nothing", ReleaseAssetFrom(REL, "")["url"], "")
; An asset published without a digest must not borrow the next one's.
Eq("an asset with no digest is not half-matched",
   ReleaseAssetFrom('{"name":"a-setup.exe","browser_download_url":"https://x/y"}', "-setup.exe")["url"], "")

Group("Net - release API URL")

Eq("a well-formed repository yields the releases endpoint", ReleaseApiUrl("mmmansouri/whispers"),
   "https://api.github.com/repos/mmmansouri/whispers/releases/latest")
Eq("an empty repository yields no URL", ReleaseApiUrl(""), "")
Eq("a bare name yields no URL", ReleaseApiUrl("whispers"), "")
; The repository name is interpolated into a URL, so anything that could
; redirect the request elsewhere has to be refused outright.
Eq("a path traversal yields no URL", ReleaseApiUrl("../../evil"), "")
Eq("an absolute URL yields no URL", ReleaseApiUrl("https://evil.example/x"), "")
Eq("a query string yields no URL", ReleaseApiUrl("o/r?x=1"), "")
Eq("an at-sign host yields no URL", ReleaseApiUrl("o/r@evil.example"), "")

Group("Net - the shipped versions.json")

NJ := FileRead(A_ScriptDir "\..\versions.json", "UTF-8")

Eq("the update repository is read from the updates block", UpdateRepoFrom(NJ), "mmmansouri/whispers")
Eq("the update asset suffix is read", UpdateAssetSuffixFrom(NJ), "-setup.exe")
; The engine block has a "repo" key too. An unscoped search would send
; the update check to whisper.cpp's releases - the same class of mistake
; the tier lookup made before it was anchored on its own block.
Lacks("the update repository is never the engine's", UpdateRepoFrom(NJ), "whisper.cpp")
Eq("a document with no updates block disables update checking",
   UpdateRepoFrom('{"engine":{"repo":"ggml-org/whisper.cpp"}}'), "")

; The scoping helper the two readers above are built on.
TWO := '{"engine":{"repo":"ggml-org/whisper.cpp"},"updates":{"repo":"me/mine"}}'
Has("a block is read by its own key", JsonBlock(TWO, "updates"), '"repo":"me/mine"')
Lacks("and stops at that block's closing brace", JsonBlock(TWO, "updates"), "ggml-org")
Has("an earlier block is read by its own key too", JsonBlock(TWO, "engine"), "ggml-org")
Eq("an absent key yields nothing", JsonBlock(TWO, "nope"), "")
Eq("an empty key yields nothing", JsonBlock(TWO, ""), "")
Eq("an empty document yields nothing", JsonBlock("", "updates"), "")
; A key whose value is not an object is not a block.
Eq("a scalar is not a block", JsonBlock('{"whispers":"2.0.0"}', "whispers"), "")
Eq("an empty document disables update checking", UpdateRepoFrom(""), "")

Eq("the cpu model URL points at the pinned revision", ModelUrlFrom(NJ, "cpu"),
   "https://huggingface.co/ggerganov/whisper.cpp/resolve/"
   . "5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.bin")
Has("the max model URL names its own file", ModelUrlFrom(NJ, "max"), "ggml-large-v3.bin")
Eq("an unknown tier has no model URL", ModelUrlFrom(NJ, "nope"), "")
Eq("an empty document has no model URL", ModelUrlFrom("", "cpu"), "")
Eq("the cpu model hash is the pinned one", ModelShaFrom(NJ, "cpu"),
   "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b")
Eq("an unknown tier has no hash", ModelShaFrom(NJ, "nope"), "")
Eq("the cpu model size is the pinned one", ModelSizeFrom(NJ, "cpu"), 487601967)
; Only ever a divisor for a progress bar, so it degrades to 0 rather than
; throwing and taking the download down with it.
Eq("an unknown tier has size zero", ModelSizeFrom(NJ, "nope"), 0)
Eq("an empty document has size zero", ModelSizeFrom("", "cpu"), 0)

Group("Commands - downloads")

f := CmdFetch("C:\w\curl.exe", "https://h/f.bin", "C:\t\a b.bin", "C:\t\d.log")
Has("the destination is quoted", f, '-o "C:\t\a b.bin"')
Has("the url is quoted", f, '"https://h/f.bin"')
Has("redirects are followed", f, " -L ")
; Without --fail, curl writes the HTTP error page to the destination and
; the caller hashes a page of HTML instead of a model.
Has("an HTTP error is a failure, not a file", f, "--fail")
Has("an interrupted multi-gigabyte download resumes", f, "-C -")
; curl writes its own stderr rather than a shell doing it, because this
; builder is launched directly: wrapped in cmd.exe the process id would
; be cmd's, and Cancel would leave curl running and still writing.
Has("curl writes its own stderr to the log", f, '--stderr "C:\t\d.log"')
Lacks("no shell redirection, so the process id is curl's", f, "2>")

j := CmdFetchJson("C:\w\curl.exe", "https://api.github.com/x", "C:\t\r.json", "C:\t\d.log")
Has("the API request asks for the versioned media type", j, "Accept: application/vnd.github+json")
Has("the API request cannot hang", j, "--max-time 20")
Has("its stderr goes to the log too", j, '--stderr "C:\t\d.log"')
; The update check must never carry anything about the user.
Lacks("no cookie is sent", j, "-b ")
Lacks("no credentials are sent", j, "-u ")

h := CmdHashFile("C:\t\a b.bin", "C:\t\h.log")
Has("the file to hash is quoted", h, '"C:\t\a b.bin"')
Has("SHA-256 is requested explicitly", h, " SHA256")
Has("both streams go to the log", h, '> "C:\t\h.log" 2>&1')

Group("Install - the entry Windows lists")

Has("the uninstall entry is looked up per user", UninstallKey(), "HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\")
Has("it is Inno Setup's entry for this AppId", UninstallKey(), AppId() "_is1")
Yes("Inno Setup's trailing backslash does not matter",
    SameDir("C:\Users\me\AppData\Local\Whispers\", "C:\Users\me\AppData\Local\Whispers"))
Yes("neither does case", SameDir("c:\users\me\appdata\local\whispers", "C:\Users\me\AppData\Local\Whispers"))
No("a development checkout is not the installation",
   SameDir("C:\Users\me\AppData\Local\Whispers\", "D:\Work\projects\whispers"))
No("a sibling with a longer name is another directory", SameDir("C:\A\Whispers2", "C:\A\Whispers"))
No("a missing location never matches", SameDir("", ""))

Eq("sizes are recorded in KB", KbFromBytes(2048), 2)
Eq("a partial KB rounds up", KbFromBytes(1025), 2)
Eq("nothing is zero", KbFromBytes(0), 0)
Eq("the max model fits a DWORD of KB", KbFromBytes(3095033483), 3022494)

Group("Indicator - shape")
Eq("the pill is 56 px tall", IndicatorHeight(), 56)
Yes("every state has its own width", IndicatorWidth("listen") != IndicatorWidth("work"))
Eq("an unknown state still gets a width", IndicatorWidth("bogus"), 200)
Eq("listening never resizes to its text", IndicatorFitWidth("listen", 900), IndicatorWidth("listen"))
Eq("warm-up never resizes to its text", IndicatorFitWidth("warm", 900), IndicatorWidth("warm"))
Eq("a short message keeps the state's width", IndicatorFitWidth("error", 40), IndicatorWidth("error"))
Eq("a long message widens the pill around it", IndicatorFitWidth("error", 300), 300 + 56 + 24)
Eq("but never past 560 px", IndicatorFitWidth("error", 2000), 560)

Group("Indicator - motion")
pos := 230, vel := 0, peak := 0
loop 120 {
    r := SpringStep(pos, vel, 340), pos := r[1], vel := r[2], peak := Max(peak, pos)
}
Eq("the spring settles exactly on its target", pos, 340)
Eq("and stops moving", vel, 0)
Yes("it overshoots on the way, which is the liquid feel", peak > 340)
Yes("but by less than a fifth of the change", peak < 340 + 0.2 * (340 - 230))
r := SpringStep(340, 0, 340)
Yes("a settled spring stays settled", r[1] = 340 && r[2] = 0)
a := 0
loop 20
    a := FadeStep(a, true)
Eq("fading in reaches fully opaque", a, 1)
loop 40
    a := FadeStep(a, false)
Eq("fading out reaches fully transparent", a, 0)

Group("Indicator - voice level")
buf := Buffer(8, 0)
Eq("silence has no energy", S16Rms(buf, 8), 0)
NumPut("Short", 32767, "Short", -32768, "Short", 32767, "Short", -32768, buf)
Yes("a full-scale square wave is at full energy", Abs(S16Rms(buf, 8) - 1) < 0.001)
NumPut("Short", 16384, "Short", -16384, buf)
Yes("a half-scale square wave is at half energy", Abs(S16Rms(buf, 4) - 0.5) < 0.001)
Eq("an odd trailing byte is not half a sample", S16Rms(buf, 5), S16Rms(buf, 4))
Eq("no bytes, no energy", S16Rms(buf, 0), 0)
Eq("a quiet room shows nothing", LevelFromRms(0.003), 0)
Eq("speech close to the microphone fills the meter", LevelFromRms(0.5), 1)
Yes("-30 dBFS sits in the middle", Abs(LevelFromRms(10 ** (-30 / 20)) - 0.5) < 0.001)
Eq("zero is zero, not a log error", LevelFromRms(0), 0)
bars := BarHeights([1, 0.5], 4, 4, 28)
Eq("missing history draws flat bars", bars[1], 4)
Eq("the newest level is on the right", bars[4], 16)
Eq("the level before it is next to it", bars[3], 28)
Eq("as many bars as asked for, even with no history", BarHeights([], 26, 4, 28).Length, 26)

Group("Indicator - text")
Yes("the warm-up bar moves at once", WarmProgress(1000) > 0.1)
Eq("the warm-up bar never claims to be done", WarmProgress(600000), 0.95)
Eq("a negative clock is the start", WarmProgress(-5), 0)
Eq("the model is named the way people say it", ModelShortName("ggml-large-v3.bin"), "large-v3")
Eq("a quantised model keeps its suffix", ModelShortName("ggml-large-v3-turbo-q5_0.bin"), "large-v3-turbo-q5_0")
Eq("words are counted on whitespace", WordCount("  Review the new`tsettings`r`nwindow "), 5)
Eq("no text, no words", WordCount(""), 0)
Eq("the done line counts words and time", DoneSubline(11, 412), "11 words in 0.4 s")
Eq("one word is singular", DoneSubline(1, 1000), "1 word in 1.0 s")
Eq("a short detail fits under the message", ErrorSubline("  Rode NT-USB was unplugged`r`n"), "Rode NT-USB was unplugged")
Eq("a log tail stays out of the pill", ErrorSubline("line one`nline two"), "")
Eq("so does a detail too long to read at a glance", ErrorSubline(Format("{:065}", 0)), "")

Group("Tray")
Eq("a recording shows the recording icon", TrayIconName("rec"), "recording")
Eq("a transcription shows the working icon", TrayIconName("work"), "working")
Eq("paused has its own icon", TrayIconName("paused"), "paused")
Eq("anything else is ready", TrayIconName("idle"), "ready")
Eq("the menu says what the key does when ready", TrayHeader("idle", "F9"), "Ready - hold F9 to dictate")
Eq("and while recording", TrayHeader("rec", "F9"), "Listening - release F9 to transcribe")
Eq("and when paused", TrayHeader("paused", "^F9"), "Paused - ^F9 does nothing")
Eq("an unloaded model is offered for loading", ModelMenuLabel(false, 4700), "Load the model now")
Eq("a loaded GPU model says what it holds", ModelMenuLabel(true, 4700), "Free the GPU now`t4.7 GB")
Eq("the CPU tier holds no GPU memory", ModelMenuLabel(true, 0), "Unload the model now")
Eq("the update entry names the version without its v", UpdateMenuLabel("v2.2.0"), "Update to 2.2.0")
Eq("the notification identity is the one the shortcuts carry", AppUserModelId(), "mmmansouri.Whispers")

Group("Indicator - placement")
at := IndicatorAnchor(0, 2560, 1392, 900, 162, 1.5)
Eq("centred on the work area", at[1], 830)
Eq("40 logical px above the taskbar", at[2], 1392 - 60 - 162)
at := IndicatorAnchor(-1920, 0, 1040, 600, 108, 1)
Eq("a monitor left of the primary has negative coordinates", at[1], -1260)

; =====================================================================
Report()

Report() {
    global gPass, gFail, gLines
    head := "Whispers unit tests`r`n"
          . "====================`r`n"
          . gPass " passed, " gFail " failed"
    body := head "`r`n"
    for line in gLines
        body .= line "`r`n"
    body .= "`r`n" head "`r`n"

    out := A_ScriptDir "\results.txt"
    try FileDelete(out)
    FileAppend(body, out, "UTF-8")
    ExitApp(gFail)
}
