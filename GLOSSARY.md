# Whispers

Push-to-talk dictation for Windows: hold a key, speak, release, and the text is pasted where the cursor is.

## Dictation

**Dictation**:
One hold-speak-release cycle, from the dictation key going down to the text being pasted.
_Avoid_: Recording (that is only the first half), transcription job

**Dictation key**:
The key or combination held while speaking. F9 by default.
_Avoid_: Hotkey (in user-facing text), shortcut, trigger

**Indicator**:
The floating pill above the taskbar that shows the state of the current dictation: listening, warming up, transcribing, pasted, or an error.
_Avoid_: Overlay, HUD, toast, popup

**Warm-up**:
The wait while the model loads into video memory, which happens on the first dictation after it was unloaded.
_Avoid_: Cold start (in user-facing text), loading screen

## Engine

**Tier**:
One of the four named speech models the user chooses between: Fast, Balanced, Maximum accuracy, CPU only.
_Avoid_: Model size, quality level, preset

**Model memory policy**:
Whether the model stays in video memory between dictations: load on demand, always ready, or never kept.
_Avoid_: VRAM mode, residency

## Getting started

**Installer**:
The downloaded setup program that installs Whispers and its tier's model for the current user.
_Avoid_: Setup (ambiguous), wizard

**First-run setup**:
The guided steps Whispers shows after installing: microphone, dictation key and language, then a test dictation.
_Avoid_: Wizard, onboarding, setup (alone)
