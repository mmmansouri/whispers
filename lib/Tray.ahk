; =====================================================================
; What the tray says: the icon for each state, the status line at the
; top of the menu, and the entries whose wording depends on state.
;
; The menu is rebuilt each time it opens, from these functions, so what
; it says is never older than the click that opened it.
; =====================================================================

; assets\tray\<name>.ico for each state SetState knows.
TrayIconName(state) {
    switch state {
        case "rec":    return "recording"
        case "work":   return "working"
        case "paused": return "paused"
    }
    return "ready"
}

; The disabled first line of the menu: the state, in words, with what
; the key does right now.
TrayHeader(state, hotkey) {
    switch state {
        case "rec":    return "Listening - release " hotkey " to transcribe"
        case "work":   return "Transcribing..."
        case "paused": return "Paused - " hotkey " does nothing"
    }
    return "Ready - hold " hotkey " to dictate"
}

; The model entry. A loaded model is offered for unloading with what it
; holds, after a tab so Windows right-aligns it like a shortcut key; the
; CPU tier holds no video memory, so it says nothing about a GPU.
ModelMenuLabel(loaded, vramMb) {
    if !loaded
        return "Load the model now"
    if (vramMb <= 0)
        return "Unload the model now"
    return "Free the GPU now`t" Format("{:.1f} GB", vramMb / 1000)
}

UpdateMenuLabel(tag) => "Update to " NormalizeVersion(tag)
