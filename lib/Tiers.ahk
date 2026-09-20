; =====================================================================
; Performance tiers.
;
; A tier is a user-facing name; versions.json maps it onto exactly one
; model file. The user never picks a file, and the application never
; guesses one: an unresolvable tier returns "" so the caller can refuse
; to start rather than silently transcribe with a different model.
;
; These functions take the versions.json *text* as their first argument
; rather than reading it, so they can be exercised against malformed and
; hostile input without a file on disk.
; =====================================================================

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

; Maps a label from the settings dropdown back onto its tier key.
TierFromLabel(label) {
    for t in TierList()
        if (TierLabel(t) = label)
            return t
    return ""
}

; Reads one field of one tier out of versions.json.
;
; A targeted reader rather than a full JSON parser: the document is
; authored and shipped by us, and every tier object is flat. The two
; traps it has to avoid are both real and both were hit in testing:
;
;   * tier names collide with the engine variant names - "cpu" exists in
;     both sections - so the search is anchored on the "tiers" object
;     first, otherwise the engine variant matches and has no "file" key;
;   * a missing field must return "", never a plausible default.
TierField(json, tier, field) {
    if (json = "" || tier = "")
        return ""
    pos := InStr(json, '"tiers"')
    if (!pos)
        return ""
    scope := SubStr(json, pos)
    if !RegExMatch(scope, '"' tier '"\s*:\s*\{([^}]*)\}', &block)
        return ""
    if RegExMatch(block[1], '"' field '"\s*:\s*"([^"]*)"', &s)
        return s[1]
    if RegExMatch(block[1], '"' field '"\s*:\s*([^,\s}]+)', &n)
        return n[1]
    return ""
}

TierFileFrom(json, tier) {
    return TierField(json, tier, "file")
}

TierVramFrom(json, tier) {
    v := TierField(json, tier, "vram_mb")
    return IsInteger(v) ? Integer(v) : 0
}

TierNeedsGpuFrom(json, tier) {
    return TierField(json, tier, "requires_gpu") = "true"
}

; The tier a machine should run, from what was actually detected.
;
; The thresholds leave headroom above each tier's own VRAM figure,
; because the model is not the only thing on the card: a desktop with a
; browser open already costs several hundred MB.
;
; Without an NVIDIA GPU the answer is always "cpu", and the reason is
; measured rather than assumed - the turbo models share large-v3's
; encoder, so they bring no CPU speedup (9.2 s versus 2.1 s for small,
; on 8 threads of an i9-12900K). See README.md.
RecommendTier(gpuPresent, vramTotalMb) {
    if (!gpuPresent)
        return "cpu"
    if (vramTotalMb >= 8000)
        return "max"
    if (vramTotalMb >= 5000)
        return "balanced"
    if (vramTotalMb >= 3000)
        return "fast"
    return "cpu"
}
