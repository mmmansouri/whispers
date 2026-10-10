; =====================================================================
; The settings window and the first-run setup as web pages (ADR-0001):
; everything about them that can be decided without a window.
;
; Whether the WebView2 runtime is usable, which theme and accent colour
; the pages get, and the messages exchanged with them. The pages run in
; a browser engine, so what they send is treated like any other input
; from outside the process: parsed strictly, matched against a fixed
; list of operations and fields, and every setting value is checked
; against the same rules LoadConfig applies to the INI.
;
; ---------------------------------------------------------------------
; The messages - the one place they are described
;
; Page -> Whispers: chrome.webview.postMessage({op: ..., <fields>}), a
; flat JSON object. UiMessageSpec() lists every op and its fields; a
; message with another op, a missing or extra field, a field of the
; wrong type or a nested value is dropped whole.
;
;   hello          {page}           the page loaded; answered with "state"
;   set            {key, value}     a setting (UiSettableKeys), applied
;                                   at once; answered with "config"
;   hotkey         {value}          a new dictation key, AutoHotkey syntax
;   capture        {on}             recording a key: the dictation key is
;                                   off meanwhile, so pressing it reaches
;                                   the page instead of starting a dictation
;   meter          {on, all}        live microphone level, of the chosen
;                                   device or of every device
;   detectMic                       pick the best microphone
;   tier           {value}          change tier; downloads the model first
;   getModel                        download the current tier's model
;   cancelDownload
;   server         {on}             load or unload the model now
;   refresh                         status, log tail and history again
;   copy           {index}          a history entry back to the clipboard
;   report                          a bug report to the clipboard
;   openLogs
;   checkUpdate / installUpdate
;   autostart      {value}          the Startup shortcut
;   talk           {down}           the setup's "Hold to talk" button
;   finish                          the setup is done
;   close
;
; Whispers -> page: PostWebMessageAsJson({ev: ..., ...}). These may nest.
;
;   state     everything a page shows, sent in answer to hello
;   config    {key, value}           the value actually kept
;   theme     {dark, accent, onAccent, mica}
;   level     {levels: {device: 0..1}}
;   status    {server, gpu, model, ...}
;   history   {items}
;   log       {lines}
;   hotkey    {ok, value, error}
;   download  {label, got, total, phase}
;   rec       {state, title, sub}    the setup's "Try it" pill
;   heard     {text}
;   notice    {text}                 a short confirmation in the page
; =====================================================================

; ---------------------------------------------------------------------
; The runtime
; ---------------------------------------------------------------------

; Below this the binding would call methods the runtime's interfaces do
; not have yet - not an error, a crash. Evergreen runtimes update
; themselves, so this only turns away a machine that has stopped
; updating for years.
WebView2MinRuntime() {
    return "110.0.0.0"
}

; pv is the runtime's version as EdgeUpdate records it under
; Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}. An uninstall leaves
; "0.0.0.0" behind rather than removing the value.
IsUsableWebView2(pv) {
    pv := Trim(pv)
    if !RegExMatch(pv, "^\d+\.\d+\.\d+\.\d+$")
        return false
    if (pv = "0.0.0.0")
        return false
    return VerCompare(pv, WebView2MinRuntime()) >= 0
}

; The newest of the versions found in the two places a runtime can be
; registered (per user, per machine), or "" when neither is usable.
BestWebView2(pvUser, pvMachine) {
    best := ""
    for pv in [pvUser, pvMachine]
        if IsUsableWebView2(pv) && (best = "" || VerCompare(Trim(pv), best) > 0)
            best := Trim(pv)
    return best
}

; ---------------------------------------------------------------------
; Theme and accent
; ---------------------------------------------------------------------

; theme is the Theme setting; appsUseLight the registry value Windows
; keeps for "app mode" (0 = dark), or "" when it could not be read -
; which means a Windows without the setting, and so light.
ThemeIsDark(theme, appsUseLight) {
    if (theme = "dark")
        return true
    if (theme = "light")
        return false
    return (appsUseLight != "" && appsUseLight = 0)
}

; The Windows accent, as the shade Windows 11 itself fills controls
; with: lighter on dark, darker on light, so that text on it stays
; readable. palette is AccentPalette from the registry, as RegRead
; returns a REG_BINARY: 64 hex digits, eight RGBA colours from the
; lightest to the darkest. Anything else gives Windows' default blue.
AccentFromPalette(palette, dark) {
    palette := RegExReplace(palette, "\s")
    if !RegExMatch(palette, "i)^[0-9a-f]{64}$")
        return dark ? "#4CC2FF" : "#005FB8"
    i := dark ? 1 : 4                   ; Light2 / Dark1
    return "#" StrUpper(SubStr(palette, i * 8 + 1, 6))
}

; Text on an accent fill, as Windows draws it.
OnAccentColor(dark) {
    return dark ? "#000000" : "#FFFFFF"
}

; Mica (DWMWA_SYSTEMBACKDROP_TYPE) arrived with Windows 11 22H2; before
; it the window gets a plain background.
SupportsMica(osVersion) {
    return VerCompare(osVersion, "10.0.22621") >= 0
}

; DWMWA_USE_IMMERSIVE_DARK_MODE is attribute 20 from Windows 10 2004.
SupportsDarkTitleBar(osVersion) {
    return VerCompare(osVersion, "10.0.19041") >= 0
}

; The peak amplitude (0..1) Windows' meter reports for a microphone, on
; the indicator's scale: -50 dBFS is 0. Peaks of speech sit some 6 dB
; above the RMS the indicator reads, hence the top at -6 dBFS.
LevelFromPeak(peak) {
    if (peak <= 0)
        return 0
    level := (20 * Log(peak) + 50) / 44
    return level < 0 ? 0 : level > 1 ? 1 : level
}

; ---------------------------------------------------------------------
; JSON out
; ---------------------------------------------------------------------

; Maps become objects, Arrays arrays, Integer and Float numbers, and
; everything else a string - including the INI values, which are
; strings whatever they hold. There is no boolean in AutoHotkey; 1 and
; 0 travel as numbers.
JsonEncode(v) {
    if IsObject(v) {
        out := ""
        if (v is Map) {
            for k, item in v
                out .= (out = "" ? "" : ",") JsonQuote(k) ":" JsonEncode(item)
            return "{" out "}"
        }
        if (v is Array) {
            for item in v
                out .= (out = "" ? "" : ",") JsonEncode(item ?? "")
            return "[" out "]"
        }
        return "null"
    }
    if (Type(v) = "Integer" || Type(v) = "Float")
        return String(v)
    return JsonQuote(v)
}

JsonQuote(s) {
    s := String(s)
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
    ; The remaining control characters, which JSON forbids raw.
    while RegExMatch(s, "[\x00-\x1F]", &m)
        s := StrReplace(s, m[0], Format("\u{:04x}", Ord(m[0])))
    return '"' s '"'
}

; ---------------------------------------------------------------------
; JSON in
; ---------------------------------------------------------------------

; Parses one flat JSON object - string, number, true, false or null
; values only - into a Map. Returns "" for anything else: a nested value,
; a duplicate key, trailing text, or more than 4 KB. true and false
; become 1 and 0, null "", and kinds tells them apart from the number 1
; or the string "": key -> "string", "number", "bool" or "null".
ParseFlatJson(json, &kinds := "") {
    kinds := Map()
    kinds.CaseSense := true
    if (StrLen(json) > 4096)
        return ""
    pos := 1
    out := Map()
    out.CaseSense := true
    if !JsonSkip(json, &pos, "{")
        return ""
    if JsonSkip(json, &pos, "}")
        return JsonEnd(json, pos) ? out : ""
    loop {
        if !JsonString(json, &pos, &key)
            return ""
        if !JsonSkip(json, &pos, ":")
            return ""
        if !JsonScalar(json, &pos, &value, &kind)
            return ""
        if out.Has(key)
            return ""
        out[key] := value
        kinds[key] := kind
        if JsonSkip(json, &pos, ",")
            continue
        if JsonSkip(json, &pos, "}")
            return JsonEnd(json, pos) ? out : ""
        return ""
    }
}

JsonWs(json, &pos) {
    while (pos <= StrLen(json) && InStr(" `t`r`n", SubStr(json, pos, 1)))
        pos++
}

JsonSkip(json, &pos, ch) {
    JsonWs(json, &pos)
    if (SubStr(json, pos, 1) == ch) {
        pos++
        return true
    }
    return false
}

JsonEnd(json, pos) {
    JsonWs(json, &pos)
    return pos > StrLen(json)
}

JsonString(json, &pos, &out) {
    JsonWs(json, &pos)
    if (SubStr(json, pos, 1) != '"')
        return false
    pos++
    out := ""
    n := StrLen(json)
    while (pos <= n) {
        c := SubStr(json, pos, 1)
        if (c = '"') {
            pos++
            return true
        }
        if (Ord(c) < 0x20)
            return false
        if (c != "\") {
            out .= c
            pos++
            continue
        }
        e := SubStr(json, pos + 1, 1)
        switch e, true {
            case '"': out .= '"'
            case "\": out .= "\"
            case "/": out .= "/"
            case "b": out .= "`b"
            case "f": out .= "`f"
            case "n": out .= "`n"
            case "r": out .= "`r"
            case "t": out .= "`t"
            case "u":
                hex := SubStr(json, pos + 2, 4)
                if !RegExMatch(hex, "^[0-9A-Fa-f]{4}$")
                    return false
                ; AutoHotkey strings are UTF-16, so a surrogate pair is
                ; two code units appended one after the other.
                out .= Chr(Integer("0x" hex))
                pos += 4
            default:
                return false
        }
        pos += 2
    }
    return false
}

JsonScalar(json, &pos, &out, &kind) {
    JsonWs(json, &pos)
    if (SubStr(json, pos, 1) = '"') {
        kind := "string"
        return JsonString(json, &pos, &out)
    }
    for word, value in Map("true", 1, "false", 0, "null", "") {
        if (SubStr(json, pos, StrLen(word)) == word) {
            pos += StrLen(word)
            out := value
            kind := word = "null" ? "null" : "bool"
            return true
        }
    }
    ; \G anchors at pos; ^ would only ever match at the start of json.
    if RegExMatch(json, "\G-?(0|[1-9]\d{0,14})(\.\d{1,15})?", &m, pos) {
        pos += StrLen(m[0])
        out := m[2] = "" ? Integer(m[0]) : Float(m[0])
        kind := "number"
        return true
    }
    return false
}

; ---------------------------------------------------------------------
; Messages from the pages
; ---------------------------------------------------------------------

; op -> its fields and their types: s string, b boolean, i integer.
UiMessageSpec() {
    return Map(
        "hello",          Map("page", "s"),
        "set",            Map("key", "s", "value", "s"),
        "hotkey",         Map("value", "s"),
        "capture",        Map("on", "b"),
        "meter",          Map("on", "b", "all", "b"),
        "detectMic",      Map(),
        "tier",           Map("value", "s"),
        "getModel",       Map(),
        "cancelDownload", Map(),
        "server",         Map("on", "b"),
        "refresh",        Map(),
        "copy",           Map("index", "i"),
        "report",         Map(),
        "openLogs",       Map(),
        "checkUpdate",    Map(),
        "installUpdate",  Map(),
        "autostart",      Map("value", "b"),
        "talk",           Map("down", "b"),
        "finish",         Map(),
        "close",          Map()
    )
}

; The message as a Map of typed fields (booleans as 1/0), or "" when it
; is not exactly one of UiMessageSpec().
ParseUiMessage(json) {
    m := ParseFlatJson(json, &kinds)
    if !IsObject(m) || !m.Has("op") || kinds["op"] != "string"
        return ""
    spec := UiMessageSpec()
    if !spec.Has(m["op"])
        return ""
    fields := spec[m["op"]]
    if (m.Count != fields.Count + 1)
        return ""
    out := Map("op", m["op"])
    for name, kind in fields {
        if !m.Has(name)
            return ""
        v := m[name]
        switch kind {
            case "s":
                if (kinds[name] != "string" || StrLen(v) > 512)
                    return ""
            case "b":
                if (kinds[name] != "bool")
                    return ""
            case "i":
                if (kinds[name] != "number" || Type(v) != "Integer")
                    return ""
        }
        out[name] := v
    }
    return out
}

; The settings a page may write with "set". The rest of ConfigSpec() is
; either changed through its own op (Tier, Hotkey, which need more than
; a write) or not the pages' business (paths, Configured, MinBytes).
UiSettableKeys() {
    return ["Mic", "Language", "AutoPaste", "PlaySounds", "ShowIndicator",
            "TrimSilence", "CheckUpdates", "CpuFallback", "VramPolicy",
            "IdleMinutes", "Port", "LoadTimeout", "Theme", "NativeWindows"]
}

; The value to keep for a "set", as a string, or "" to refuse it. Free
; numbers go through the sanitisers LoadConfig uses, so the page is told
; the clamped value rather than refused. Whether a microphone exists is
; for the caller to check against the device list.
UiSettingValue(key, value) {
    switch key, true {
        case "AutoPaste", "PlaySounds", "ShowIndicator", "TrimSilence",
             "CheckUpdates", "CpuFallback", "NativeWindows":
            return (value == "0" || value == "1") ? value : ""
        case "Language":
            return IsValidLanguage(value) ? value : ""
        case "VramPolicy":
            return IsValidPolicy(value) ? value : ""
        case "Theme":
            return IsValidTheme(value) ? value : ""
        case "IdleMinutes":
            return String(SanitizeIdleMinutes(value))
        case "Port":
            return String(SanitizePort(value))
        case "LoadTimeout":
            return String(SanitizeLoadTimeout(value))
        case "Mic":
            return (StrLen(value) <= 256 && !RegExMatch(value, "[\x00-\x1F]")) ? value : ""
    }
    return ""
}

; A dictation key as the pages produce it: AutoHotkey modifier symbols
; and one key name, such as F9, ^+Space or RCtrl. Only a sanity check -
; whether AutoHotkey accepts it is learned by registering it - but it
; keeps custom combinations ("a & b") and option strings out.
IsPlausibleHotkey(key) {
    return StrLen(key) <= 32
        && RegExMatch(key, "^[#!^+<>]*(?:[A-Za-z][A-Za-z0-9]*|[0-9]|[``\-=\[\];',./\\])$") != 0
}

; The text "Copy for a bug report" puts on the clipboard: enough to
; reproduce, nothing personal beyond what the log already holds.
BugReport(version, tier, model, gpu, os, runtime, logLines) {
    out := "Whispers " version "`r`n"
         . "Tier: " tier " (" model ")`r`n"
         . "GPU: " gpu "`r`n"
         . "Windows: " os "`r`n"
         . "WebView2: " (runtime = "" ? "not installed" : runtime) "`r`n"
         . "`r`nLast log lines:`r`n"
    for line in logLines
        out .= line "`r`n"
    return out
}
