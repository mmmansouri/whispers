; =====================================================================
; Audio device identification.
;
; Two naming systems have to be reconciled: Windows audio endpoints, which
; is where the user's default lives, and DirectShow device names, which is
; what ffmpeg takes on its command line. They usually agree; when they do
; not, it is because dshow truncated the name.
;
; Everything here is pure text work on output captured elsewhere, so the
; awkward cases - truncation, virtual devices, digital silence - can be
; asserted on without a sound card.
; =====================================================================

; Extracts audio device names from `ffmpeg -list_devices true -f dshow`.
; ffmpeg writes this to stderr, and lists video devices in the same block,
; so the "(audio)" suffix is what separates them.
ParseDshowAudioDevices(logText) {
    devices := []
    if (logText = "")
        return devices
    for line in StrSplit(logText, "`n", "`r") {
        if RegExMatch(line, '"([^"]+)"\s+\(audio\)', &m)
            devices.Push(m[1])
    }
    return devices
}

; Pulls the mean level out of ffmpeg's volumedetect output. Returns "" if
; the filter did not report one, which means the capture failed rather
; than that the device was quiet.
ParseMeanVolume(logText) {
    if RegExMatch(logText, "mean_volume:\s*(-?[\d.]+) dB", &m)
        return m[1] + 0
    return ""
}

ParseMaxVolume(logText) {
    if RegExMatch(logText, "max_volume:\s*(-?[\d.]+) dB", &m)
        return m[1] + 0
    return ""
}

; ffmpeg reports digital silence as -91 dB. Anything at or below that
; floor carried no signal at all, as opposed to a quiet room.
IsSilentLevel(level) {
    return level = "" || level <= -90
}

; Devices that route other programs' audio rather than a microphone.
;
; They are excluded from level-based detection because they are often the
; loudest thing on the machine while carrying no speech: on the reference
; machine a virtual audio cable measured -25.9 dB while the real
; microphone sat at -80.3 dB, purely because music was playing.
IsVirtualDevice(name) {
    for pat in ["virtual", "cable", "stereo mix", "mixage", "voicemeeter", "loopback", "what u hear", "sonar"]
        if InStr(name, pat)
            return true
    return false
}

; Maps a Windows endpoint name onto the dshow device list.
;
; Exact match first. The prefix fallback exists because dshow truncates
; some names, so the Windows name can be the longer of the two, or the
; shorter one - hence the test in both directions.
MatchDevice(name, devices) {
    if (name = "")
        return ""
    for d in devices
        if (d = name)
            return d
    for d in devices {
        if (StrLen(name) >= 8 && SubStr(d, 1, StrLen(name)) = name)
            return d
        if (StrLen(d) >= 8 && SubStr(name, 1, StrLen(d)) = d)
            return d
    }
    return ""
}

; ffmpeg needs about a second to open a dshow device before it writes
; the first byte. A press shorter than that is killed before the capture
; file exists at all - which, looking only at the disk, is exactly what
; a broken microphone looks like.
;
; So the elapsed time is what tells the two apart. Without it the user
; who taps the key is told their microphone failed, and goes looking for
; a fault in their hardware that is not there. The same mistake as
; arming the hotkey before detection: blaming the setup for something
; transient.
CaptureTooShort(elapsedMs) {
    return elapsedMs < 1500
}
