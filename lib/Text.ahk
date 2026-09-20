; =====================================================================
; Text handling that has no business touching the disk.
;
; Split out of the file helpers so the awkward cases - a log that is
; mostly one enormous line, text with embedded tabs about to be written
; to a TSV, a history file with a trailing blank line - can be asserted
; on directly.
; =====================================================================

; Collapses a log file into one line and keeps its tail, which is where
; the actual error message sits. Returns the whole thing when it is short
; enough, so short errors are never prefixed with a misleading ellipsis.
TailText(txt, maxChars := 400) {
    if (txt = "")
        return ""
    ; One space per run of whitespace, not one per character: a CRLF would
    ; otherwise leave a double space in every error message shown to the user.
    txt := Trim(RegExReplace(txt, "\s+", " "))
    if (StrLen(txt) <= maxChars)
        return txt
    return "..." SubStr(txt, -maxChars)
}

; History is stored as TSV, so a transcription containing a tab or a
; newline would corrupt the file. Flatten before writing, never after.
FlattenText(text) {
    return Trim(RegExReplace(text, "\s+", " "))
}

; Shortens a transcription for a notification without cutting mid-word
; count: the caller wants a fixed maximum, not a pretty one.
PreviewText(text, maxChars := 60) {
    return StrLen(text) > maxChars ? SubStr(text, 1, maxChars - 3) "..." : text
}

; Parses the history file. Malformed lines are skipped rather than
; failing the load: a truncated history is worth keeping.
ParseHistoryText(txt) {
    items := []
    if (txt = "")
        return items
    for line in StrSplit(txt, "`n", "`r") {
        if (Trim(line) = "")
            continue
        parts := StrSplit(line, "`t")
        if (parts.Length >= 2)
            items.Push(Map("time", parts[1], "text", parts[2]))
    }
    return items
}

FormatHistoryText(items) {
    out := ""
    for item in items
        out .= item["time"] "`t" item["text"] "`r`n"
    return out
}

HasValue(arr, val) {
    for v in arr
        if (v = val)
            return true
    return false
}
