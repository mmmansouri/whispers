; =====================================================================
; Command-line construction.
;
; Every external program Whispers launches is spawned through cmd.exe so
; that stdout/stderr can be redirected to a log file. That makes quoting
; the single riskiest thing in this codebase, and it is why these builders
; live here as pure functions: they take strings, they return a string,
; and they can be asserted on without launching anything.
;
; The contract, which every builder relies on:
;
;   cmd.exe /s /c "<inner>"
;
; /s tells cmd to strip exactly the first and the last quote of <inner>
; and to leave everything between them untouched. Without /s, cmd applies
; a convoluted rule about the number of quotes on the line and mangles
; paths that contain spaces - which every path here does, because they
; sit under "Program Files", "AppData\Local\Temp" or a user name.
;
; Consequences for callers:
;   * <inner> must start and end with a quote if either end is a quoted
;     path. All builders below satisfy that, or start with a bare token
;     (ffmpeg, nvidia-smi) and end with a quoted redirection target.
;   * paths are wrapped individually in double quotes,
;   * no path may itself contain a double quote - Windows forbids it.
; =====================================================================

; Wraps a command line for cmd.exe. See the contract above.
ShellCmd(inner) {
    return A_ComSpec ' /s /c "' inner '"'
}

; --- ffmpeg -----------------------------------------------------------

; Open-ended capture: runs until the process is killed, which is how
; push-to-talk ends a recording. -flush_packets keeps the raw file usable
; even though the process is terminated rather than closed cleanly.
CmdRecord(ffmpeg, device, rawPath, logPath) {
    return '"' ffmpeg '" -y -f dshow -i audio="' device '"'
         . ' -ac 1 -ar 16000 -f s16le -flush_packets 1'
         . ' "' rawPath '" 2> "' logPath '"'
}

; Fixed-length capture with level measurement, used to test a microphone
; and as the fallback path of automatic detection.
CmdMicLevel(ffmpeg, device, seconds, rawPath, logPath) {
    return '"' ffmpeg '" -y -f dshow -i audio="' device '" -t ' seconds
         . ' -ac 1 -ar 16000 -af volumedetect -f s16le'
         . ' "' rawPath '" 2> "' logPath '"'
}

; Raw s16le to WAV. whisper-server needs a container; the raw capture has
; none. trimSilence drops leading and trailing silence, which reduces the
; hallucinated text whisper produces on near-empty audio.
CmdConvert(ffmpeg, rawPath, wavPath, logPath, trimSilence := false) {
    filter := trimSilence
        ? ' -af silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.1:stop_periods=-1:stop_threshold=-50dB:stop_silence=0.4 '
        : ' '
    return '"' ffmpeg '" -y -f s16le -ar 16000 -ac 1 -i "' rawPath '"'
         . filter '"' wavPath '" 2>> "' logPath '"'
}

CmdListDevices(ffmpeg, logPath) {
    return '"' ffmpeg '" -hide_banner -list_devices true -f dshow -i dummy 2> "' logPath '"'
}

; --- whisper ----------------------------------------------------------

CmdServer(serverExe, modelPath, language, port, logPath) {
    return '"' serverExe '" -m "' modelPath '" -l ' language
         . ' -nt --port ' port ' > "' logPath '" 2>&1'
}

; outBase has no extension: whisper-cli appends .txt itself when -otxt is
; given, so passing "x.txt" would produce "x.txt.txt".
CmdCli(cliExe, modelPath, language, forceCpu, outBase, wavPath, logPath) {
    return '"' cliExe '" -m "' modelPath '" -l ' language ' -nt'
         . (forceCpu ? " -ng" : "")
         . ' -of "' outBase '" -otxt -f "' wavPath '" > "' logPath '" 2>&1'
}

; --- curl -------------------------------------------------------------

CmdInference(curlExe, port, wavPath, language, outPath, errPath) {
    return '"' curlExe '" -s --max-time 120 -X POST http://127.0.0.1:' port '/inference'
         . ' -F "file=@' wavPath '"'
         . ' -F "response_format=text"'
         . ' -F "language=' language '"'
         . ' -F "no_timestamps=true"'
         . ' > "' outPath '" 2> "' errPath '"'
}

; Liveness probe. Deliberately short: it runs on the latency-critical
; path and a server that is still loading its model will not answer.
CmdServerAlive(curlExe, port) {
    return '"' curlExe '" -s -o nul --max-time 2 http://127.0.0.1:' port '/'
}

; --- downloads --------------------------------------------------------

; The two builders below are the ONE exception to the cmd.exe contract
; above: they are launched directly, and they use curl's own --stderr
; instead of a shell redirection.
;
; The reason is Cancel. Wrapped in cmd.exe, the process id handed back is
; cmd's, and killing it leaves curl running - still writing, still
; holding the file. Launched directly, the id is curl's and Cancel means
; what it says.
;
; A download that resumes rather than restarting: a 2.9 GB model over a
; hotel connection will be interrupted, and starting again from zero is
; how a user gives up. -C - continues from whatever is already on disk.
; Resuming onto a corrupted part file is safe here because the caller
; hashes the result and deletes it when it does not match, so the next
; attempt starts clean.
;
; --fail makes curl return non-zero on an HTTP error instead of writing
; the error page to the destination, which would otherwise be hashed as
; if it were a model.
CmdFetch(curlExe, url, destPath, logPath) {
    return '"' curlExe '" -L --fail --retry 3 --retry-delay 2 -C - --progress-bar'
         . ' --stderr "' logPath '"'
         . ' -o "' destPath '" "' url '"'
}

; The releases API. No credentials and no user data are sent: the only
; header is the one GitHub requires to serve the versioned JSON.
CmdFetchJson(curlExe, url, destPath, logPath) {
    return '"' curlExe '" -L --fail --max-time 20 -H "Accept: application/vnd.github+json"'
         . ' --stderr "' logPath '"'
         . ' -o "' destPath '" "' url '"'
}

; certutil ships with Windows, so hashing needs nothing installed. Its
; surrounding text is localised; ParseCertutilHash in lib\Net.ahk reads
; the digits rather than the words.
CmdHashFile(filePath, logPath) {
    return 'certutil -hashfile "' filePath '" SHA256 > "' logPath '" 2>&1'
}

; --- nvidia-smi -------------------------------------------------------

CmdGpuSummary(logPath) {
    return 'nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader,nounits > "' logPath '" 2>&1'
}

; The verbose form, only for the CUDA version the driver supports. That
; number is not available through --query-gpu.
CmdGpuFull(logPath) {
    return 'nvidia-smi -q > "' logPath '" 2>&1'
}
