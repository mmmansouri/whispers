; =====================================================================
; The installation as Windows sees it.
;
; Inno Setup records the size of what it shipped - the script and the
; uninstaller, about 4 MB - while everything that makes up the real
; install (engine, ffmpeg, interpreter, model) is downloaded by code
; afterwards. "Installed apps" showed 4.33 MB for a 3.9 GB install. The
; installer measures the real figure once the downloads have landed; the
; application measures it again whenever a model is added or removed.
; These are the pure halves of that.
; =====================================================================

; Must equal AppId in installer\Whispers.iss: it is the key of the entry
; Windows lists, and the value an upgrade is matched on.
; tests\installer.ps1 asserts that the two copies agree.
AppId() {
    return "{7A1D5F2E-3C48-4B91-9E6D-0F2A8C4B7E13}"
}

; Per-user only: HKCU is the one hive Whispers can write without
; administrator rights. An install made for all users lives under HKLM
; and is simply not found here, which is the right outcome.
UninstallKey() {
    return "HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\" AppId() "_is1"
}

; Inno Setup stores InstallLocation with a trailing backslash, and
; Windows paths are case-insensitive. An empty location never matches:
; a missing value must not make every directory "the installation".
SameDir(a, b) {
    a := RTrim(Trim(a), "\")
    b := RTrim(Trim(b), "\")
    return a != "" && a = b
}

; EstimatedSize is a DWORD of kilobytes. Rounded up, so an install that
; is not empty never reads as 0 KB.
KbFromBytes(bytes) {
    return bytes <= 0 ? 0 : Ceil(bytes / 1024)
}
