; =====================================================================
; The indicator's arithmetic: how big the pill is in each state, how it
; moves between them, what it says, and how loud the voice is.
;
; The drawing lives in Whispers.ahk, because it needs a window and GDI+.
; Everything here takes numbers, text or a buffer of samples and returns
; numbers or text, so the shape of the animation is testable without a
; screen. Sizes are logical pixels at 96 DPI; the caller scales them.
; =====================================================================

IndicatorHeight() => 56

; The width a state starts from. A state that carries a message grows
; to fit it (IndicatorFitWidth); the listening and warm-up states have
; fixed content, so they never jump while the user is speaking.
IndicatorWidth(state) {
    switch state {
        case "listen": return 340
        case "warm":   return 380
        case "work":   return 230
        case "done":   return 230
        case "error":  return 320
        case "warn":   return 280
    }
    return 200
}

; 56 px of orb on the left and 24 of padding on the right around the
; widest line of text, never narrower than the state's own width and
; never wider than a message the eye can take in at a glance.
IndicatorFitWidth(state, textWidth) {
    base := IndicatorWidth(state)
    if (state = "listen" || state = "warm")
        return base
    return Max(base, Min(560, Ceil(textWidth) + 56 + 24))
}

; One frame of an under-damped spring: the pill overshoots its new width
; by about 9% and settles in some 350 ms, which is the "liquid" in the
; design (22% read as a bounce, not as liquid). Snaps once it is within
; half a pixel, so a settled pill stops changing for good.
; Returns [position, velocity].
SpringStep(pos, vel, target) {
    vel := vel * 0.62 + (target - pos) * 0.12
    pos += vel
    if (Abs(target - pos) < 0.5 && Abs(vel) < 0.5)
        return [target, 0]
    return [pos, vel]
}

; One frame of fading: quick to appear, a little slower to leave.
FadeStep(alpha, visible) {
    alpha := visible ? alpha + (1 - alpha) * 0.45 : alpha * 0.82
    if (alpha > 0.99)
        return 1
    if (alpha < 0.01)
        return 0
    return alpha
}

; Root mean square of little-endian signed 16-bit samples, from 0 to 1.
; An odd trailing byte is half a sample and is ignored.
S16Rms(buf, bytes) {
    n := bytes // 2
    if (n <= 0)
        return 0
    sum := 0
    loop n {
        s := NumGet(buf, (A_Index - 1) * 2, "Short")
        sum += s * s
    }
    return Sqrt(sum / n) / 32768
}

; Loudness as the eye expects it: decibels, not amplitude. -50 dBFS (a
; quiet room) is 0 and -10 dBFS (speech close to the microphone) is 1.
LevelFromRms(rms) {
    if (rms <= 0)
        return 0
    level := (20 * Log(rms) + 50) / 40
    return level < 0 ? 0 : level > 1 ? 1 : level
}

; The waveform scrolls: one bar per recent level, newest on the right.
; Missing history (the first second of a dictation) draws flat bars.
BarHeights(levels, count, minH, maxH) {
    out := []
    missing := count - levels.Length
    loop count {
        i := A_Index - missing
        lvl := i >= 1 ? levels[i] : 0
        out.Push(minH + (maxH - minH) * lvl)
    }
    return out
}

; How far along the warm-up bar is. Nobody knows how long a model takes
; to load on this machine, so the bar approaches the end without ever
; reaching it - a bar that fills and then waits is worse than none.
WarmProgress(ms) {
    p := 1 - Exp(-Max(ms, 0) / 5000)
    return p > 0.95 ? 0.95 : p
}

; "ggml-large-v3-turbo-q5_0.bin" -> "large-v3-turbo-q5_0"
ModelShortName(file) {
    name := RegExReplace(file, "i)\.bin$")
    return RegExReplace(name, "i)^ggml-")
}

WordCount(text) {
    n := 0
    pos := 1
    while (pos := RegExMatch(text, "\S+", &m, pos)) {
        n++
        pos += m.Len
    }
    return n
}

; "11 words in 0.4 s", timed from the key being released.
DoneSubline(words, ms) {
    return Format("{} word{} in {:.1f} s", words, words = 1 ? "" : "s", Max(ms, 0) / 1000)
}

; A failure's detail is often the tail of a log. The pill has room for
; one short line; anything longer stays in the log and the tray message.
ErrorSubline(detail) {
    d := Trim(detail, " `t`r`n")
    if (d = "" || InStr(d, "`n") || StrLen(d) > 64)
        return ""
    return d
}

; Centred on the work area, 40 logical px above its bottom edge, so it
; sits over the taskbar wherever the taskbar is not.
IndicatorAnchor(workLeft, workRight, workBottom, pixelW, pixelH, scale) {
    x := workLeft + ((workRight - workLeft) - pixelW) // 2
    y := workBottom - Round(40 * scale) - pixelH
    return [x, y]
}
