; =====================================================================
; Downloading, hashing and release metadata - pure functions only.
;
; Nothing here touches the network or the disk. Every function takes the
; text somebody else fetched and returns what it means, which is what
; lets the unit suite exercise the parsing against malformed, localised
; and hostile input without a connection.
;
; Two trust models live side by side here, and they are not the same
; thing:
;
;   Models and engine builds are PINNED. versions.json carries the
;   SHA-256 that was recorded when the pin was raised, and a download
;   that does not match it is discarded.
;
;   An application update cannot be pinned - the hash of a release that
;   does not exist yet cannot be written down in advance. There the hash
;   comes from GitHub's own API response over TLS, so the guarantee is
;   "what GitHub served matches what GitHub said it would serve", not
;   "this is the build the author pinned". ReleaseAssetFrom returns that
;   digest so the caller can still reject a truncated or corrupted
;   download, and the difference is stated in the README.
; =====================================================================

; certutil prints the hash on its own line, but the text around it is
; LOCALISED: a French Windows says "Hachage SHA256 de X :". Matching on
; English words would fail on the very machine this was developed on, so
; this looks for the only thing that is not translated - 64 hex digits.
ParseCertutilHash(text) {
    if (text = "")
        return ""
    ; certutil has printed the hash in space-separated pairs in the past.
    compact := RegExReplace(text, "[ \t]", "")
    if RegExMatch(compact, "i)\b([0-9a-f]{64})\b", &m)
        return StrLower(m[1])
    return ""
}

; Both sides must be a real hash. An empty expected value would otherwise
; make every download "valid", which is the one failure mode that must
; never be silent.
HashMatches(expected, actual) {
    ; Trim before validating, not after: a hash read out of a file can
    ; carry a stray space, and rejecting it as "not hexadecimal" would
    ; report a corrupt download where there is none.
    expected := StrLower(Trim(expected))
    actual   := StrLower(Trim(actual))
    if (expected = "" || actual = "")
        return false
    if !RegExMatch(expected, "^[0-9a-f]{64}$")
        return false
    return expected = actual
}

; ---------------------------------------------------------------------
; Versions
; ---------------------------------------------------------------------

; "v2.1.0" and "2.1.0" are the same version: GitHub tags carry the v,
; the application's own constant does not.
NormalizeVersion(v) {
    v := Trim(v)
    if (SubStr(v, 1, 1) = "v" || SubStr(v, 1, 1) = "V")
        v := SubStr(v, 2)
    return v
}

; -1, 0 or 1. Compares field by field as numbers, so 2.10.0 sorts above
; 2.9.0 - which a string comparison gets backwards.
CompareVersions(a, b) {
    pa := StrSplit(NormalizeVersion(a), ".")
    pb := StrSplit(NormalizeVersion(b), ".")
    n := Max(pa.Length, pb.Length)
    loop n {
        x := A_Index <= pa.Length ? Integer(RegExReplace(pa[A_Index], "\D.*$", "") || "0") : 0
        y := A_Index <= pb.Length ? Integer(RegExReplace(pb[A_Index], "\D.*$", "") || "0") : 0
        if (x != y)
            return x > y ? 1 : -1
    }
    return 0
}

; An unparseable or empty candidate is never "newer": a mangled response
; must not be able to push an update.
IsNewerVersion(current, candidate) {
    if (Trim(candidate) = "" || Trim(current) = "")
        return false
    if !RegExMatch(NormalizeVersion(candidate), "^\d+(\.\d+)*$")
        return false
    return CompareVersions(candidate, current) = 1
}

; ---------------------------------------------------------------------
; GitHub release metadata
; ---------------------------------------------------------------------

ReleaseTagFrom(json) {
    if (json = "")
        return ""
    if RegExMatch(json, '"tag_name"\s*:\s*"([^"]+)"', &m)
        return m[1]
    return ""
}

; A draft or a pre-release is not something to offer to everyone. The
; /releases/latest endpoint already excludes both, but a repository that
; has only ever published pre-releases returns 404 and a hand-rolled URL
; could point elsewhere, so this is checked rather than assumed.
IsPublishedRelease(json) {
    if (json = "")
        return false
    if RegExMatch(json, '"draft"\s*:\s*true')
        return false
    if RegExMatch(json, '"prerelease"\s*:\s*true')
        return false
    return ReleaseTagFrom(json) != ""
}

; Returns Map("name", "url", "sha256") for the first asset whose name
; ends with the given suffix, or an empty Map.
;
; The three fields are captured in one match because they belong to one
; asset object and appear in that order inside it. Anchoring on the name
; is what keeps a second asset's URL from being paired with the first
; asset's digest.
ReleaseAssetFrom(json, suffix) {
    empty := Map("name", "", "url", "", "sha256", "")
    if (json = "" || suffix = "")
        return empty
    esc := RegExReplace(suffix, "([\\.\^\$\*\+\?\(\)\[\]\{\}\|])", "\$1")
    pattern := 's)"name"\s*:\s*"([^"]*' esc ')".*?'
             . '"digest"\s*:\s*"sha256:([0-9a-f]{64})".*?'
             . '"browser_download_url"\s*:\s*"([^"]+)"'
    if !RegExMatch(json, pattern, &m)
        return empty
    return Map("name", m[1], "url", m[3], "sha256", StrLower(m[2]))
}

; ---------------------------------------------------------------------
; versions.json
; ---------------------------------------------------------------------

; The Hugging Face revision is pinned, so a model URL always points at
; one immutable commit rather than at whatever the branch holds today.
ModelUrlFrom(json, tier) {
    file := TierFileFrom(json, tier)
    if (file = "")
        return ""
    if !RegExMatch(json, '"source"\s*:\s*"([^"]+)"', &src)
        return ""
    if !RegExMatch(json, '"revision"\s*:\s*"([0-9a-f]{7,40})"', &rev)
        return ""
    return RTrim(src[1], "/") "/resolve/" rev[1] "/" file
}

ModelShaFrom(json, tier) {
    return TierField(json, tier, "sha256")
}

; Only ever used to give a progress bar something to divide by, so a
; missing or unparseable value degrades to 0 and the bar shows bytes
; received instead of a percentage.
ModelSizeFrom(json, tier) {
    v := TierField(json, tier, "size")
    return IsInteger(v) ? Integer(v) : 0
}

; The object a top-level key names, braces excluded, or "" when the key
; is absent. Scoping matters: "repo" appears in the engine block too, and
; an unscoped search for it would happily return ggml-org/whisper.cpp as
; the place to look for Whispers updates.
JsonBlock(json, key) {
    if (json = "" || key = "")
        return ""
    pos := InStr(json, '"' key '"')
    if (!pos)
        return ""
    if !RegExMatch(SubStr(json, pos), '"' key '"\s*:\s*\{([^}]*)\}', &m)
        return ""
    return m[1]
}

; "owner/name" of the repository releases are published to, or "" when
; the file says nothing - in which case update checking stays off.
UpdateRepoFrom(json) {
    block := JsonBlock(json, "updates")
    if (block = "")
        return ""
    if RegExMatch(block, '"repo"\s*:\s*"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)"', &m)
        return m[1]
    return ""
}

UpdateAssetSuffixFrom(json) {
    block := JsonBlock(json, "updates")
    if (block = "")
        return ""
    if RegExMatch(block, '"asset_suffix"\s*:\s*"([^"]+)"', &m)
        return m[1]
    return ""
}

ReleaseApiUrl(repo) {
    if (repo = "" || !RegExMatch(repo, "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
        return ""
    return "https://api.github.com/repos/" repo "/releases/latest"
}
