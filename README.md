# Whispers

Push-to-talk dictation for Windows. Hold a key, speak, release — the text
lands in whatever window has focus. Runs entirely on your machine: no
account, no cloud, no audio leaves the computer.

Powered by [whisper.cpp](https://github.com/ggml-org/whisper.cpp).

---

## Why it is fast

A naive integration spawns `whisper-cli` per dictation and pays the model
load every single time. Measured on this project's reference machine
(RTX 4070 Ti, i9-12900K), 11 s of audio:

| Path | Per dictation |
| --- | ---: |
| `whisper-cli`, model reloaded each time | 3 246 ms |
| `whisper-server`, model resident | **203–343 ms** |

Two things buy that:

* the model stays resident in a local `whisper-server`, addressed over
  HTTP on `127.0.0.1`;
* the server is **warmed up while you are still speaking**, so the first
  dictation after an idle unload hides the model load behind the
  recording instead of adding it to the wait.

It is unloaded again after an idle period, so it does not hold several GB
of VRAM hostage while you need the GPU for something else.

## Performance tiers

You pick a tier, never a model file. Each tier is one `.bin`; only the
selected one is kept on disk.

| Tier | Model | Download | VRAM |
| --- | --- | ---: | ---: |
| Fast | `ggml-large-v3-turbo-q5_0` | 547 MB | ~1.5 GB |
| Balanced | `ggml-large-v3-turbo` | 1 549 MB | ~2.8 GB |
| Maximum accuracy | `ggml-large-v3` | 2 952 MB | ~4.7 GB |
| CPU only | `ggml-small` | 465 MB | — |

The installer reads the GPU's VRAM and preselects the right one.

### Why CPU mode uses `small` and not a turbo model

Measured, 11 s of audio, CPU only, model load included:

| Model | 4 threads | 8 threads |
| --- | ---: | ---: |
| `large-v3-turbo-q5_0` | 15.6 s | 9.2 s |
| `small` | 3.2 s | **2.1 s** |

The turbo models shrink the *decoder* (4 layers instead of 32) but keep
`large-v3`'s encoder — and whisper pads every clip to a 30-second window
(`WHISPER_CHUNK_SIZE`), so the encoder dominates for dictation-length
audio. On a GPU that is irrelevant; on a CPU it is the whole cost.

The same padding is why a 3-second dictation costs about as much as an
11-second one.

## Layout

Nothing is hard-coded to one machine. The script derives its root from
its own location.

```
<install root>\          %LOCALAPPDATA%\Whispers by default
  Whispers.ahk
  AutoHotkey64.exe       interpreter, shipped alongside
  versions.json          pinned versions + SHA-256
  bin\                   whisper-server, whisper-cli, ffmpeg, DLLs
  models\                the one model for the selected tier

%APPDATA%\Whispers\      Whispers.ini, logs\, history.tsv
%TEMP%\Whispers\         capture scratch files
```

`bin\` and `models\` can be moved through the `[Paths]` section of
`Whispers.ini` — which is how a development checkout points at a local
whisper.cpp build instead of an installed one:

```ini
[Paths]
BinDir=D:\Work\projects\whisper.cpp\build\bin
ModelsDir=D:\Work\projects\whisper.cpp\models
```

## Pinned dependencies

`versions.json` is the single source of truth. Nothing is ever resolved
as `latest`, and every download is rejected unless its SHA-256 matches.

Two things worth knowing about upstream:

* whisper.cpp publishes its Windows binaries on **`bNNNN` build tags**.
  The semantic `vX.Y.Z` tags carry **no assets** from v1.9.3 onward, so
  pinning `v1.9.4` would download nothing.
* the CUDA archives bundle their own `cudart`/`cublas` DLLs, so a target
  machine needs an NVIDIA driver but **no CUDA Toolkit**.

### Raising a pinned version

1. Edit the version, asset name, size and `sha256` in `versions.json`.
   GitHub exposes each release asset's digest in its API response, and
   Hugging Face exposes each model's in `lfs.sha256` — no need to
   download anything to fill these in.
2. Run the validation for whatever you changed. For ffmpeg that means
   exercising all five ways Whispers uses it: `-version`, dshow device
   enumeration, dshow capture, raw→wav conversion, and the
   `silenceremove` filter.
3. Record the result in the `validated` block of `versions.json`.
4. Only then publish.

A pin is never raised automatically, and the application never resolves
a version at run time.

## Microphone selection

On first run Whispers asks Windows which capture endpoint is the default
(`IMMDeviceEnumerator::GetDefaultAudioEndpoint`) and maps it onto
ffmpeg's dshow device list. That is deterministic and costs ~0 ms.

Measuring levels is only a fallback, because it is unreliable on its own:
on the reference machine, probing with nobody speaking ranked a virtual
audio cable carrying program audio at −25.9 dB **above** the real
microphone at −80.3 dB. When the fallback is used, the log says so.

## Requirements

* Windows 10/11 x64
* An NVIDIA GPU for the GPU tiers — driver only, no CUDA Toolkit.
  Without one, Whispers installs in CPU mode and reports the measured
  latency so you know what you are getting.

Everything else — the whisper.cpp binaries, ffmpeg, AutoHotkey and the
model — is fetched or shipped by the installer. Nothing needs to be
installed system-wide and no administrator rights are required.

## Licence

MIT, see [LICENSE](LICENSE). whisper.cpp is MIT; ffmpeg is redistributed
by neither this repository nor its installer — it is downloaded from its
own official release on the target machine.
