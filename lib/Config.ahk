; =====================================================================
; Configuration schema and value sanitising.
;
; The schema lives here as data rather than being spelled out twice in
; the load and save paths, where the two copies drift apart: a key added
; to one and forgotten in the other is silently never persisted.
;
; Sanitising matters because three settings are free-text edit boxes in
; the settings window. A port of "eight thousand" or an idle delay of -5
; would otherwise be written to the INI and only surface later as a
; server that refuses to start, with no obvious cause.
; =====================================================================

; key -> [ini section, default value]
;
; Mic is deliberately empty: a microphone is a property of the machine,
; never of the product, and is resolved on first run.
; BinDir and ModelsDir are empty too, meaning "next to the script".
ConfigSpec() {
    return Map(
        "Mic",           ["Audio",  ""],
        "MinBytes",      ["Audio",  "8000"],
        "TrimSilence",   ["Audio",  "0"],
        "Tier",          ["Engine", "balanced"],
        "Language",      ["Engine", "fr"],
        "VramPolicy",    ["Engine", "idle"],
        "IdleMinutes",   ["Engine", "5"],
        "Port",          ["Engine", "8910"],
        "LoadTimeout",   ["Engine", "90"],
        "CpuFallback",   ["Engine", "1"],
        "BinDir",        ["Paths",  ""],
        "ModelsDir",     ["Paths",  ""],
        "Hotkey",        ["UI",     "F9"],
        "AutoPaste",     ["UI",     "1"],
        "PlaySounds",    ["UI",     "1"],
        "ShowIndicator", ["UI",     "1"],
        "CheckUpdates",  ["UI",     "1"],
        "Configured",    ["UI",     "0"]
    )
}

; An empty override means "use the default location next to the script".
; Whitespace counts as empty: an INI line left as "ModelsDir= " is a
; user who cleared the field, not a path named " ".
ResolveDir(override, fallback) {
    return Trim(override) != "" ? Trim(override) : fallback
}

; Clamps a free-text integer into range, falling back when it is not a
; number at all. Never throws: a bad setting must not prevent startup.
SanitizeInt(value, min, max, fallback) {
    v := Trim(value)
    if !IsInteger(v)
        return fallback
    n := Integer(v)
    if (n < min)
        return min
    if (n > max)
        return max
    return n
}

; Ports below 1024 need privileges Whispers does not have, and the server
; only ever listens on the loopback interface.
SanitizePort(value) {
    return SanitizeInt(value, 1024, 65535, 8910)
}

; Zero would unload the model between every dictation, defeating the
; resident server entirely; a day is long enough to mean "never".
SanitizeIdleMinutes(value) {
    return SanitizeInt(value, 1, 1440, 5)
}

; Loading large-v3 from a cold page cache on a slow disk genuinely takes
; tens of seconds, so the floor is generous.
SanitizeLoadTimeout(value) {
    return SanitizeInt(value, 10, 600, 90)
}

; Below this many bytes of 16 kHz mono s16le, the capture holds less than
; a syllable and whisper will hallucinate rather than return nothing.
SanitizeMinBytes(value) {
    return SanitizeInt(value, 1000, 1000000, 8000)
}

IsValidTier(tier) {
    for t in TierList()
        if (t = tier)
            return true
    return false
}

IsValidPolicy(policy) {
    for p in ["idle", "resident", "never"]
        if (p = policy)
            return true
    return false
}

; Raw bytes of 16 kHz mono 16-bit PCM to seconds.
RawBytesToSeconds(bytes) {
    return Round(bytes / 32000, 2)
}
