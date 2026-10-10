; =====================================================================
; Whispers - Windows installer
;
; Everything the product needs beyond its own source is downloaded here
; and rejected unless its SHA-256 matches versions.json. Nothing is
; resolved as "latest", and no artefact is committed to the repository.
;
; The pins are NOT written twice: pins.iss is generated from
; versions.json by tools\build-installer.ps1, which is the only
; supported way to build this script.
;
; Per-user by design: PrivilegesRequired=lowest, everything under
; %LOCALAPPDATA%. Dictation software has no business asking for
; administrator rights.
; =====================================================================

; The appearance below ("dynamic", the windows11 style, hidebevels) needs
; Inno Setup 6.7. Checked here, by the compiler itself, rather than in
; tools\build-installer.ps1: ISCC.exe and its DLLs carry no version
; resource, and ISPP's Ver is the one version number that cannot be
; wrong. An older compiler would otherwise fail on the WizardStyle line
; with a message that does not say why.
#if Ver < EncodeVer(6, 7, 0)
  #error Inno Setup 6.7 or newer is required - winget upgrade JRSoftware.InnoSetup
#endif

#ifnexist "pins.iss"
  #error pins.iss is missing - build through tools\build-installer.ps1, not ISCC directly
#endif
; The WebView2 binding is shipped, not downloaded at install time, and
; tools\build-installer.ps1 fetches it (tools\fetch-vendor.ps1) before
; compiling. Without it every installation would silently fall back to
; the native windows.
#ifnexist "..\vendor\ahk2_lib\WebView2\WebView2.ahk"
  #error vendor\ is missing - build through tools\build-installer.ps1, which fetches it
#endif
#include "pins.iss"

#define AppName "Whispers"
#define AppPublisher "Whispers"
#define AppUrl "https://github.com/mmmansouri/whispers"

[Setup]
; Generated once and never changed: it is what lets an upgrade replace
; an existing install instead of stacking a second copy beside it.
AppId={{7A1D5F2E-3C48-4B91-9E6D-0F2A8C4B7E13}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
VersionInfoVersion={#AppVersion}

DefaultDirName={localappdata}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayName={#AppName} {#AppVersion}
UninstallDisplayIcon={app}\assets\Whispers.ico

; No administrator rights, ever.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

; The archives are .zip, which only the "full" extraction method reads.
ArchiveExtraction=full

; Restart Manager only watches the files listed in [Files]. The ones a
; running Whispers actually holds - AutoHotkey64.exe and the engine in
; bin\ - are copied by code, so StopRunningWhispers in [Code] is what
; stops it, on install and on uninstall alike.
CloseApplications=yes
RestartApplications=no

; Follows Windows' light or dark mode with Inno's built-in windows11
; style, without the horizontal bevel lines of older Windows. The images
; are drawn by tools\build-icons.ps1 at 100-200 %; Inno picks the best
; fit for the screen. They are opaque or transparent-backed, so the same
; files serve both modes - but they must be named twice: in dark mode Inno
; reads the *DynamicDark directives, whose default is its own built-in
; image, not the light one (seen: Inno's box in our dark header).
; Identical files are stored once.
WizardStyle=modern dynamic windows11 hidebevels
WizardImageFile=..\assets\installer\wizard-100.png,..\assets\installer\wizard-125.png,..\assets\installer\wizard-150.png,..\assets\installer\wizard-175.png,..\assets\installer\wizard-200.png
WizardSmallImageFile=..\assets\installer\wizard-small-100.png,..\assets\installer\wizard-small-125.png,..\assets\installer\wizard-small-150.png,..\assets\installer\wizard-small-175.png,..\assets\installer\wizard-small-200.png
WizardImageFileDynamicDark=..\assets\installer\wizard-100.png,..\assets\installer\wizard-125.png,..\assets\installer\wizard-150.png,..\assets\installer\wizard-175.png,..\assets\installer\wizard-200.png
WizardSmallImageFileDynamicDark=..\assets\installer\wizard-small-100.png,..\assets\installer\wizard-small-125.png,..\assets\installer\wizard-small-150.png,..\assets\installer\wizard-small-175.png,..\assets\installer\wizard-small-200.png
SetupIconFile=..\assets\Whispers.ico
; The welcome page is the one that shows the side image; Inno 6 hides it
; by default.
DisableWelcomePage=no
OutputDir=..\dist
OutputBaseFilename={#AppName}-{#AppVersion}-setup
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=..\LICENSE

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[Messages]
; What the product is, instead of the stock advice to close every other
; application - which Whispers does not need: it stops its own instance.
WelcomeLabel2=This will install [name/ver] - push-to-talk dictation that runs entirely on this computer.%n%nIt installs for you only, without administrator rights, and downloads the speech model that fits your graphics card. Already installed? Your settings, history and model are kept.

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked
Name: "startup"; Description: "Start {#AppName} when I sign in"

[Dirs]
Name: "{app}\bin"
Name: "{app}\models"
; Settings, logs and history live outside the install root so that an
; uninstall can leave them alone unless the user says otherwise.
Name: "{userappdata}\{#AppName}"

[Files]
; The product itself. Everything else on disk is downloaded.
Source: "..\Whispers.ahk";   DestDir: "{app}";     Flags: ignoreversion
Source: "..\lib\*.ahk";      DestDir: "{app}\lib"; Flags: ignoreversion
Source: "..\versions.json";  DestDir: "{app}";     Flags: ignoreversion
Source: "..\LICENSE";        DestDir: "{app}";     Flags: ignoreversion
Source: "..\README.md";      DestDir: "{app}";     Flags: ignoreversion
; Drawn by tools\build-icons.ps1: the shortcuts' icon and the tray states.
Source: "..\assets\Whispers.ico"; DestDir: "{app}\assets";      Flags: ignoreversion
Source: "..\assets\tray\*.ico";   DestDir: "{app}\assets\tray"; Flags: ignoreversion
; Synthesized by tools\build-sounds.ps1.
Source: "..\assets\sounds\*.wav"; DestDir: "{app}\assets\sounds"; Flags: ignoreversion
; The settings window and the first-run setup (ADR-0001): the pages, and
; the pinned WebView2 binding with Microsoft's loader DLL and its licence.
Source: "..\ui\*";               DestDir: "{app}\ui";              Flags: ignoreversion
Source: "..\vendor\ahk2_lib\*";  DestDir: "{app}\vendor\ahk2_lib"; Flags: ignoreversion recursesubdirs

[INI]
; Seed the tier the user picked in the wizard. Every other setting keeps
; its built-in default, which the application writes on first run.
Filename: "{userappdata}\{#AppName}\{#AppName}.ini"; Section: "Engine"; Key: "Tier"; \
  String: "{code:ChosenTierValue}"

[Icons]
; AppUserModelID must equal AppUserModelId() in lib\Install.ahk: Windows
; titles the app's notifications after the shortcut carrying the ID the
; process declares. tests\installer.ps1 asserts that the copies agree.
Name: "{group}\{#AppName}"; Filename: "{app}\AutoHotkey64.exe"; Parameters: """{app}\Whispers.ahk"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\Whispers.ico"; AppUserModelID: "mmmansouri.Whispers"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\AutoHotkey64.exe"; Parameters: """{app}\Whispers.ahk"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\Whispers.ico"; AppUserModelID: "mmmansouri.Whispers"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}"; Filename: "{app}\AutoHotkey64.exe"; Parameters: """{app}\Whispers.ahk"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\Whispers.ico"; AppUserModelID: "mmmansouri.Whispers"; Tasks: startup

[Run]
Filename: "{app}\AutoHotkey64.exe"; Parameters: """{app}\Whispers.ahk"""; WorkingDir: "{app}"; \
  Description: "Start {#AppName} now"; Flags: nowait postinstall skipifsilent

[InstallDelete]
; The engine DLLs nothing loads (see UnusedEngineDll). An upgrade keeps
; the engine it already has, so they are removed here as well as no
; longer copied.
Type: files; Name: "{app}\bin\llama.dll"
Type: files; Name: "{app}\bin\parakeet.dll"
Type: files; Name: "{app}\bin\SDL2.dll"
Type: files; Name: "{app}\bin\nvblas64_12.dll"

[UninstallDelete]
; Downloaded or written at install time, so the uninstaller has no
; record of them.
Type: filesandordirs; Name: "{app}\bin"
Type: filesandordirs; Name: "{app}\models"
Type: files;          Name: "{app}\AutoHotkey64.exe"
Type: files;          Name: "{app}\downloads.ini"
; The application's scratch directory. Besides the installer of the last
; update, it holds the last dictation's audio and its text - nothing to
; leave behind on a machine Whispers has been removed from.
Type: filesandordirs; Name: "{%TEMP}\Whispers"

[Code]

const
  TIER_COUNT = 4;

var
  TierPage:     TInputOptionWizardPage;
  WebViewPage:  TInputOptionWizardPage;
  DownloadPage: TDownloadWizardPage;
  WebViewMissing: Boolean;

  TierKey:   array[0..TIER_COUNT-1] of String;
  TierFile:  array[0..TIER_COUNT-1] of String;
  TierSha:   array[0..TIER_COUNT-1] of String;
  TierGpu:   array[0..TIER_COUNT-1] of Boolean;

  GpuPresent:   Boolean;
  GpuName:      String;
  GpuVramMb:    Integer;
  GpuCudaMax:   String;
  EngineAsset:  String;
  EngineSha:    String;
  EngineLabel:  String;

  // What is already installed and is not downloaded again; decided when
  // the Ready page is left, honoured by InstallDownloads.
  KeepAhk, KeepFfmpeg, KeepEngine, KeepModel: Boolean;

// ---------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------

function NthField(const S: String; const Sep: Char; const N: Integer): String;
var
  I, Count, Start: Integer;
begin
  Result := '';
  Count := 1;
  Start := 1;
  for I := 1 to Length(S) do begin
    if S[I] = Sep then begin
      if Count = N then begin
        Result := Trim(Copy(S, Start, I - Start));
        Exit;
      end;
      Count := Count + 1;
      Start := I + 1;
    end;
  end;
  if Count = N then
    Result := Trim(Copy(S, Start, Length(S) - Start + 1));
end;

function EndsWithText(const S, Suffix: String): Boolean;
begin
  Result := (Length(S) >= Length(Suffix)) and
            (CompareText(Copy(S, Length(S) - Length(Suffix) + 1, Length(Suffix)), Suffix) = 0);
end;

// A CUDA version is "major.minor". Comparing those as strings ranks
// "11.8" above "12.4", which would ship the wrong engine build.
function CudaAtLeast(const Have: String; const WantMajor, WantMinor: Integer): Boolean;
var
  Major, Minor: Integer;
begin
  Major := StrToIntDef(NthField(Have, '.', 1), -1);
  Minor := StrToIntDef(NthField(Have, '.', 2), 0);
  if Major < 0 then
    Result := False
  else if Major <> WantMajor then
    Result := Major > WantMajor
  else
    Result := Minor >= WantMinor;
end;

// Runs a command line through cmd.exe and returns its output. The /s
// switch makes cmd strip exactly the first and last quote, which is
// what keeps the nested quoting around the redirect predictable - the
// same contract the application documents in lib\Commands.ahk.
function RunCapture(const Cmd: String; var Lines: TArrayOfString): Boolean;
var
  LogFile: String;
  Code: Integer;
begin
  SetArrayLength(Lines, 0);
  LogFile := ExpandConstant('{tmp}\probe.txt');
  DeleteFile(LogFile);
  Result := Exec(ExpandConstant('{cmd}'),
                 '/s /c "' + Cmd + ' > "' + LogFile + '" 2>&1"',
                 '', SW_HIDE, ewWaitUntilTerminated, Code);
  if Result then
    Result := LoadStringsFromFile(LogFile, Lines);
  DeleteFile(LogFile);
end;

// ---------------------------------------------------------------------
// Stopping a running Whispers
//
// A running Whispers survives its own uninstall otherwise. The script is
// already in the interpreter's memory, so the hotkey keeps answering -
// with ffmpeg deleted from under it, every dictation fails - and every
// file a live process holds is left on disk. CloseApplications does not
// cover it: Restart Manager runs for Setup only, and only watches files
// listed in [Files], while the interpreter and the engine are copied by
// code.
//
// Matched on the executable's path, never on a bare image name: the user
// may run other AutoHotkey scripts, or an ffmpeg of their own, and those
// are not ours to kill. Everything Whispers starts - the interpreter,
// whisper-server, ffmpeg - runs from under {app}. The trailing backslash
// keeps "Whispers2\" from matching "Whispers\".
// ---------------------------------------------------------------------

procedure StopRunningWhispers;
var
  Root, Cmd: String;
  Code: Integer;
begin
  Root := AddBackslash(ExpandConstant('{app}'));
  if not DirExists(Root) then
    Exit;
  // A single quote is legal in a Windows path and closes a PowerShell
  // literal; doubling it is how PowerShell escapes it.
  StringChangeEx(Root, '''', '''''', True);
  // The pages' WebView2 processes run from Microsoft's runtime, not from
  // {app}. They are ours when they use Whispers' browser profile, and are
  // stopped too, so that the profile in %TEMP%\Whispers can be deleted.
  Cmd := '$r = ''' + Root + '''; ' +
         '$p = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { ' +
         '$_.Path -and $_.Path.StartsWith($r, [StringComparison]::OrdinalIgnoreCase) }); ' +
         '$p | Stop-Process -Force -ErrorAction SilentlyContinue; ' +
         '$p | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue; ' +
         'Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { ' +
         '$_.Name -eq ''msedgewebview2.exe'' -and $_.CommandLine -like ''*\Whispers\WebView2*'' } | ' +
         'ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }';
  if Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
          '-NoProfile -NonInteractive -Command "' + Cmd + '"',
          '', SW_HIDE, ewWaitUntilTerminated, Code) then
    Log('Stopped any Whispers process running from ' + Root + ' (exit ' + IntToStr(Code) + ')')
  else
    Log('Could not run PowerShell to stop Whispers: ' + SysErrorMessage(Code));
end;

// An install over a running copy would fail on the locked interpreter.
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  StopRunningWhispers;
  Result := '';
end;

// ---------------------------------------------------------------------
// GPU probe
//
// The driver reports the highest CUDA runtime it supports. Reading that
// beats hard-coding a driver-version table, which would silently rot -
// the same reasoning as in the application itself.
// ---------------------------------------------------------------------

procedure ProbeGpu;
var
  Lines: TArrayOfString;
  Line: String;
  I: Integer;
begin
  GpuPresent := False;
  GpuName := '';
  GpuVramMb := 0;
  GpuCudaMax := '';

  if RunCapture('nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits', Lines) then begin
    if GetArrayLength(Lines) > 0 then begin
      Line := Trim(Lines[0]);
      if StrToIntDef(NthField(Line, ',', 2), -1) > 0 then begin
        GpuPresent := True;
        GpuName    := NthField(Line, ',', 1);
        GpuVramMb  := StrToIntDef(NthField(Line, ',', 2), 0);
      end;
    end;
  end;

  if not GpuPresent then
    Exit;

  if RunCapture('nvidia-smi -q', Lines) then
    for I := 0 to GetArrayLength(Lines) - 1 do
      if (Pos('CUDA Version', Lines[I]) > 0) and (GpuCudaMax = '') then
        GpuCudaMax := Trim(Copy(Lines[I], Pos(':', Lines[I]) + 1, 32));
end;

// Which engine build this machine can actually run. The CUDA archives
// bundle their own cudart/cublas, so a driver is enough - no Toolkit.
//
// /ENGINE=cpu forces the CPU build on a machine that could run CUDA.
// An unattended deployment sometimes has to: a machine whose GPU is
// reserved for something else still wants dictation.
procedure ChooseEngine;
begin
  if CompareText(ExpandConstant('{param:engine|}'), 'cpu') = 0 then begin
    EngineAsset := '{#EngCpuAsset}';
    EngineSha   := '{#EngCpuSha}';
    EngineLabel := 'CPU (forced by /ENGINE=cpu)';
  end else if GpuPresent and CudaAtLeast(GpuCudaMax, 12, 4) then begin
    EngineAsset := '{#EngCuda124Asset}';
    EngineSha   := '{#EngCuda124Sha}';
    EngineLabel := 'CUDA 12.4';
  end else if GpuPresent and CudaAtLeast(GpuCudaMax, 11, 8) then begin
    EngineAsset := '{#EngCuda118Asset}';
    EngineSha   := '{#EngCuda118Sha}';
    EngineLabel := 'CUDA 11.8';
  end else begin
    EngineAsset := '{#EngCpuAsset}';
    EngineSha   := '{#EngCpuSha}';
    EngineLabel := 'CPU';
  end;
end;

// Thresholds duplicated from lib\Tiers.ahk, because the application is
// not installed yet when this runs. tests\installer.ps1 asserts that
// the two copies still agree.
function RecommendTierIndex: Integer;
begin
  if not GpuPresent then
    Result := 3
  else if GpuVramMb >= 8000 then
    Result := 2
  else if GpuVramMb >= 5000 then
    Result := 1
  else if GpuVramMb >= 3000 then
    Result := 0
  else
    Result := 3;
end;

// ---------------------------------------------------------------------
// The WebView2 runtime (ADR-0001)
//
// The settings window and the first-run setup are pages shown with
// Microsoft Edge WebView2. It ships with Windows 11 and nearly every
// Windows 10; where it is missing, the user is offered a per-user install
// (Microsoft's bootstrapper, run without elevation, installs for the
// current account only). Declined or failed, nothing else changes:
// Whispers uses its classic windows.
//
// Looked up where the application looks (WebRuntimeVersion in
// Whispers.ahk): per user, then per machine. An uninstall leaves the
// version "0.0.0.0" behind instead of removing the value.
// ---------------------------------------------------------------------

const
  WEBVIEW2_CLIENT = '\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  // Microsoft's Evergreen bootstrapper. Unlike everything else here it is
  // not pinned: it always fetches the current runtime, which Windows then
  // keeps up to date. Its Authenticode signature is checked instead.
  WEBVIEW2_BOOTSTRAPPER = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703';

function WebView2Registered(const Root: Integer; const Key: String): Boolean;
var
  Version: String;
begin
  Result := RegQueryStringValue(Root, Key, 'pv', Version) and
            (Version <> '') and (Version <> '0.0.0.0');
end;

// /WEBVIEW2=missing pretends the runtime is absent, so that the offer can
// be walked through on a machine that has it.
function WebView2Present: Boolean;
begin
  if CompareText(ExpandConstant('{param:webview2|}'), 'missing') = 0 then
    Result := False
  else
    Result := WebView2Registered(HKCU, 'Software' + WEBVIEW2_CLIENT) or
              WebView2Registered(HKLM32, 'SOFTWARE' + WEBVIEW2_CLIENT) or
              WebView2Registered(HKLM64, 'SOFTWARE' + WEBVIEW2_CLIENT);
end;

// Only when the page was shown and its box left ticked. /WEBVIEW2=skip
// declines in an unattended install, which never shows the page.
function WantWebView2: Boolean;
begin
  Result := WebViewMissing and WebViewPage.Values[0] and
            (CompareText(ExpandConstant('{param:webview2|}'), 'skip') <> 0);
end;

function MicrosoftSigned(const Path: String): Boolean;
var
  P, Cmd: String;
  Code: Integer;
begin
  P := Path;
  StringChangeEx(P, '''', '''''', True);
  Cmd := '$s = Get-AuthenticodeSignature -LiteralPath ''' + P + '''; ' +
         'if ($s.Status -eq ''Valid'' -and $s.SignerCertificate.Subject -like ''CN=Microsoft Corporation,*'') ' +
         '{ exit 0 } else { exit 1 }';
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
                 '-NoProfile -NonInteractive -Command "' + Cmd + '"',
                 '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

// Never fails the installation: Whispers works without the runtime.
procedure InstallWebView2;
var
  Setup: String;
  Code: Integer;
begin
  if not WantWebView2 then
    Exit;
  WizardForm.StatusLabel.Caption := 'Installing Microsoft Edge WebView2 for your account...';
  try
    DownloadTemporaryFile(WEBVIEW2_BOOTSTRAPPER, 'MicrosoftEdgeWebview2Setup.exe', '', nil);
  except
    Log('WebView2 bootstrapper download failed: ' + GetExceptionMessage +
        ' - continuing, Whispers will use its classic windows');
    Exit;
  end;
  Setup := ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe');
  if not MicrosoftSigned(Setup) then begin
    Log('The WebView2 bootstrapper is not signed by Microsoft - not run; ' +
        'continuing, Whispers will use its classic windows');
    Exit;
  end;
  if Exec(Setup, '/silent /install', '', SW_HIDE, ewWaitUntilTerminated, Code) and WebView2Present then
    Log('WebView2 runtime installed for the current user (exit ' + IntToStr(Code) + ')')
  else
    Log('WebView2 runtime not installed (exit ' + IntToStr(Code) +
        ') - continuing, Whispers will use its classic windows');
end;

// ---------------------------------------------------------------------
// What an upgrade does not download again
//
// Every upgrade used to download everything again: 3.9 GB on the max
// tier with the CUDA engine, for a release that changed one script.
//
// The model is pinned by the hash of the file itself, so the installed
// copy is hashed and kept when it matches. The other three are pinned by
// the hash of their .zip, which is gone once unpacked, so downloads.ini
// records which archive each one was unpacked from. An entry is removed
// before unpacking and written back only once everything is copied: an
// install that died half way never reads as complete.
// ---------------------------------------------------------------------

function ManifestPath: String;
begin
  Result := ExpandConstant('{app}\downloads.ini');
end;

function ArchiveInstalled(const Key, Sha, Probe: String): Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\') + Probe) and
            (CompareText(GetIniString('Downloads', Key, '', ManifestPath), Sha) = 0);
end;

procedure ForgetArchive(const Key: String);
begin
  DeleteIniEntry('Downloads', Key, ManifestPath);
end;

procedure RecordArchive(const Key, Sha: String);
begin
  if not SetIniString('Downloads', Key, Sha, ManifestPath) then
    Log('Could not record ' + Key + ' in ' + ManifestPath +
        ' - the next upgrade downloads it again');
end;

function ModelPathFor(const Tier: Integer): String;
begin
  Result := ExpandConstant('{app}\models\') + TierFile[Tier];
end;

// About 10 seconds for the 3 GB model, against minutes of download.
function ModelInstalled(const Tier: Integer): Boolean;
var
  Path, Got: String;
begin
  Result := False;
  Path := ModelPathFor(Tier);
  if not FileExists(Path) then
    Exit;
  try
    Got := GetSHA256OfFile(Path);
  except
    Log('Could not hash ' + Path + ': ' + GetExceptionMessage + ' - downloading it again');
    Exit;
  end;
  Result := CompareText(Got, TierSha[Tier]) = 0;
  if not Result then
    Log('The installed ' + TierFile[Tier] + ' hashes to ' + Got +
        ', not the pinned ' + TierSha[Tier] + ' - downloading it again');
end;

// tests\installer.ps1 reads these lines to prove an upgrade kept them.
procedure LogKept(const What: String; const Kept: Boolean);
begin
  if Kept then
    Log(What + ' is already installed - not downloading it again');
end;

// ---------------------------------------------------------------------
// Wizard
// ---------------------------------------------------------------------

procedure InitTierTable;
begin
  TierKey[0] := 'fast';     TierFile[0] := '{#TierFastFile}';     TierSha[0] := '{#TierFastSha}';     TierGpu[0] := True;
  TierKey[1] := 'balanced'; TierFile[1] := '{#TierBalancedFile}'; TierSha[1] := '{#TierBalancedSha}'; TierGpu[1] := True;
  TierKey[2] := 'max';      TierFile[2] := '{#TierMaxFile}';      TierSha[2] := '{#TierMaxSha}';      TierGpu[2] := True;
  TierKey[3] := 'cpu';      TierFile[3] := '{#TierCpuFile}';      TierSha[3] := '{#TierCpuSha}';      TierGpu[3] := False;
end;

function SelectedTierIndex: Integer;
var
  I: Integer;
begin
  Result := 3;
  for I := 0 to TIER_COUNT - 1 do
    if TierPage.Values[I] then
      Result := I;
end;

// Exposed to the [INI] section through {code:ChosenTierValue}.
function ChosenTierValue(Param: String): String;
begin
  Result := TierKey[SelectedTierIndex];
end;

// /TIER=fast|balanced|max|cpu, for unattended deployment: a silent
// install never sees the tier page, so without this it could only ever
// get whatever this machine's hardware suggests. A tier the machine
// cannot run is refused rather than half-honoured.
function ParamTierIndex: Integer;
var
  Wanted: String;
  I: Integer;
begin
  Result := -1;
  Wanted := ExpandConstant('{param:tier|}');
  if Wanted = '' then
    Exit;
  for I := 0 to TIER_COUNT - 1 do
    if (CompareText(Wanted, TierKey[I]) = 0) and (GpuPresent or not TierGpu[I]) then
      Result := I;
end;

// An upgrade must not silently move the user to another tier: if one is
// already configured, that is the preselection.
function ExistingTierIndex: Integer;
var
  Current: String;
  I: Integer;
begin
  Result := -1;
  Current := GetIniString('Engine', 'Tier', '',
               ExpandConstant('{userappdata}\{#AppName}\{#AppName}.ini'));
  for I := 0 to TIER_COUNT - 1 do
    if CompareText(Current, TierKey[I]) = 0 then
      Result := I;
end;

procedure InitializeWizard;
var
  I, Preselect: Integer;
begin
  InitTierTable;
  ProbeGpu;
  ChooseEngine;

  TierPage := CreateInputOptionPage(wpSelectTasks,
    'Performance tier',
    'How accurate, and how much of your machine.',
    'Whispers downloads one model: the one for the tier you pick. You can ' +
    'change tier later from the settings window, which downloads the new ' +
    'model then.',
    True, False);

  TierPage.Add('{#TierFastLabel}');
  TierPage.Add('{#TierBalancedLabel}');
  TierPage.Add('{#TierMaxLabel}');
  TierPage.Add('{#TierCpuLabel}');

  if not GpuPresent then
    for I := 0 to TIER_COUNT - 1 do
      if TierGpu[I] then
        TierPage.CheckListBox.ItemEnabled[I] := False;

  Preselect := ParamTierIndex;
  if Preselect < 0 then
    Preselect := ExistingTierIndex;
  if Preselect < 0 then
    Preselect := RecommendTierIndex
  else if (not GpuPresent) and TierGpu[Preselect] then
    Preselect := RecommendTierIndex;
  TierPage.Values[Preselect] := True;

  WebViewMissing := not WebView2Present;
  WebViewPage := CreateInputOptionPage(TierPage.ID,
    'Microsoft Edge WebView2',
    'What the settings window and the first-run setup are shown with.',
    'Whispers shows its settings and its first-run setup with Microsoft Edge ' +
    'WebView2, which is not installed on this PC. It installs for your account ' +
    'only, without administrator rights: a small program from Microsoft, which ' +
    'then downloads the runtime (about 150 MB).' + #13#10#13#10 +
    'Without it, dictation works exactly the same, and Whispers uses its classic windows.',
    False, False);
  WebViewPage.Add('Install Microsoft Edge WebView2 for my account (recommended)');
  WebViewPage.Values[0] := True;

  DownloadPage := CreateDownloadPage(SetupMessage(msgWizardPreparing),
                                     SetupMessage(msgPreparingDesc), nil);
  DownloadPage.ShowBaseNameInsteadOfUrl := True;
end;

// The WebView2 page is for machines without the runtime only.
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (PageID = WebViewPage.ID) and not WebViewMissing;
end;

// Only the cheap checks run here; hashing the model waits for Next, so
// the Ready page never hangs before it is drawn.
procedure MemoItem(const Item: String; const Kept: Boolean;
                   const Space, NewLine: String; var Fetch, Keep: String);
begin
  if Kept then
    Keep := Keep + Space + Item + NewLine
  else
    Fetch := Fetch + Space + Item + NewLine;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo,
  MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  Detected, Fetch, Keep: String;
  Tier: Integer;
begin
  if GpuPresent then
    Detected := GpuName + ' (' + IntToStr(GpuVramMb) +
                ' MB VRAM, driver supports CUDA ' + GpuCudaMax + ')'
  else
    Detected := 'no usable NVIDIA GPU - CPU mode';

  Tier := SelectedTierIndex;
  Fetch := '';
  Keep := '';
  MemoItem('whisper.cpp {#EngineTag}, ' + EngineLabel + ' build',
           ArchiveInstalled('engine', EngineSha, 'bin\whisper-server.exe'), Space, NewLine, Fetch, Keep);
  MemoItem('ffmpeg {#FfmpegVersion}',
           ArchiveInstalled('ffmpeg', '{#FfmpegSha}', 'bin\ffmpeg.exe'), Space, NewLine, Fetch, Keep);
  MemoItem('AutoHotkey {#AhkVersion}',
           ArchiveInstalled('AutoHotkey', '{#AhkSha}', 'AutoHotkey64.exe'), Space, NewLine, Fetch, Keep);
  if FileExists(ModelPathFor(Tier)) then
    Keep := Keep + Space + 'model ' + TierFile[Tier] +
            ' - downloaded again if its SHA-256 no longer matches' + NewLine
  else
    Fetch := Fetch + Space + 'model ' + TierFile[Tier] + NewLine;

  Result := MemoDirInfo + NewLine + NewLine +
            'Detected hardware:' + NewLine + Space + Detected + NewLine + NewLine;
  if Keep <> '' then
    Result := Result + 'Already installed, kept:' + NewLine + Keep + NewLine;
  if Fetch <> '' then
    Result := Result + 'Will download:' + NewLine + Fetch + NewLine;
  Result := Result +
            'Every download is rejected unless its SHA-256 matches versions.json.' + NewLine;
  if WantWebView2 then
    Result := Result + NewLine + 'Microsoft Edge WebView2:' + NewLine + Space +
              'installed for your account by Microsoft''s own installer, once its' + NewLine + Space +
              'signature is checked (not pinned: it installs the current runtime)' + NewLine
  else if WebViewMissing then
    Result := Result + NewLine + 'Microsoft Edge WebView2:' + NewLine + Space +
              'not installed - Whispers will use its classic windows' + NewLine;
  if MemoTasksInfo <> '' then
    Result := Result + NewLine + MemoTasksInfo;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Tier: Integer;
  Error: String;
begin
  Result := True;
  if CurPageID <> wpReady then
    Exit;

  Tier := SelectedTierIndex;
  DownloadPage.Clear;
  DownloadPage.Show;
  try
    KeepAhk    := ArchiveInstalled('AutoHotkey', '{#AhkSha}', 'AutoHotkey64.exe');
    KeepFfmpeg := ArchiveInstalled('ffmpeg', '{#FfmpegSha}', 'bin\ffmpeg.exe');
    KeepEngine := ArchiveInstalled('engine', EngineSha, 'bin\whisper-server.exe');
    DownloadPage.SetText('Checking the installed model...', TierFile[Tier]);
    KeepModel  := ModelInstalled(Tier);

    LogKept('AutoHotkey {#AhkVersion}', KeepAhk);
    LogKept('ffmpeg {#FfmpegVersion}', KeepFfmpeg);
    LogKept('engine ' + EngineAsset, KeepEngine);
    LogKept('model ' + TierFile[Tier], KeepModel);

    if not KeepAhk then
      DownloadPage.Add('{#AhkUrl}',    'AutoHotkey.zip', '{#AhkSha}');
    if not KeepFfmpeg then
      DownloadPage.Add('{#FfmpegUrl}', 'ffmpeg.zip',     '{#FfmpegSha}');
    if not KeepEngine then
      DownloadPage.Add('{#EngineBase}' + EngineAsset, 'engine.zip', EngineSha);
    if not KeepModel then
      DownloadPage.Add('{#ModelBase}' + TierFile[Tier], TierFile[Tier], TierSha[Tier]);

    try
      DownloadPage.Download;
    except
      if DownloadPage.AbortedByUser then
        Log('Download aborted by the user.')
      else begin
        Error := Format('%s: %s', [DownloadPage.LastBaseNameOrUrl, GetExceptionMessage]);
        SuppressibleMsgBox(AddPeriod(Error), mbCriticalError, MB_OK, IDOK);
      end;
      Result := False;
    end;
  finally
    DownloadPage.Hide;
  end;
end;

// ---------------------------------------------------------------------
// Install
//
// The engine archive carries 23 executables Whispers never runs, and
// ffmpeg's carries ffplay and ffprobe at 105 MB each. Extraction cannot
// filter, so everything lands in a staging directory and only what the
// product actually loads is copied out of it.
// ---------------------------------------------------------------------

// Four DLLs of the engine archive are loaded by nothing Whispers runs:
// measured on the CUDA 12.4 build by listing the modules a transcribing
// whisper-server holds, then transcribing on GPU and CPU without them.
// The ggml-cpu-* variants stay (one per processor family, loaded by
// name at run time) and so does nvrtc (the CUDA runtime may load it).
function UnusedEngineDll(const Name: String): Boolean;
begin
  Result := (CompareText(Name, 'llama.dll') = 0) or
            (CompareText(Name, 'parakeet.dll') = 0) or
            (CompareText(Name, 'SDL2.dll') = 0) or
            (CompareText(Name, 'nvblas64_12.dll') = 0);
end;

function KeepFromEngine(const Name: String): Boolean;
begin
  Result := (EndsWithText(Name, '.dll') and not UnusedEngineDll(Name)) or
            (CompareText(Name, 'whisper-cli.exe') = 0) or
            (CompareText(Name, 'whisper-server.exe') = 0);
end;

function WantedFile(const Name: String; const EngineRules: Boolean;
                    const SingleName: String): Boolean;
begin
  if EngineRules then
    Result := KeepFromEngine(Name)
  else
    Result := CompareText(Name, SingleName) = 0;
end;

procedure CopyStaged(const StageDir, DestDir: String; const EngineRules: Boolean;
                     const SingleName: String);
var
  FindRec: TFindRec;
  Copied: Integer;
begin
  Copied := 0;
  if FindFirst(AddBackslash(StageDir) + '*', FindRec) then begin
    try
      repeat
        if (FindRec.Attributes and FILE_ATTRIBUTE_DIRECTORY = 0) and
           WantedFile(FindRec.Name, EngineRules, SingleName) then begin
          if FileCopy(AddBackslash(StageDir) + FindRec.Name,
                      AddBackslash(DestDir) + FindRec.Name, False) then
            Copied := Copied + 1
          else
            RaiseException('Could not place ' + FindRec.Name + ' into ' + DestDir);
        end;
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
  if Copied = 0 then
    RaiseException('Nothing usable was extracted into ' + StageDir +
                   ' - the archive layout is not what this installer expects.');
end;

procedure Unpack(const Archive, StageDir, Status: String);
begin
  WizardForm.StatusLabel.Caption := Status;
  DelTree(StageDir, True, True, True);
  CreateDir(StageDir);
  // FullPaths=False flattens the archive, which is what makes this
  // independent of the "Release\" and "ffmpeg-<version>\bin\" prefixes
  // that change between upstream releases.
  ExtractArchive(Archive, StageDir, '', False, nil);
end;

procedure InstallDownloads;
var
  Tmp, Staging, Model: String;
begin
  Tmp := ExpandConstant('{tmp}');

  if not KeepAhk then begin
    ForgetArchive('AutoHotkey');
    Staging := Tmp + '\stage-ahk';
    Unpack(Tmp + '\AutoHotkey.zip', Staging, 'Unpacking AutoHotkey...');
    CopyStaged(Staging, ExpandConstant('{app}'), False, 'AutoHotkey64.exe');
    DelTree(Staging, True, True, True);
    RecordArchive('AutoHotkey', '{#AhkSha}');
  end;

  if not KeepEngine then begin
    ForgetArchive('engine');
    Staging := Tmp + '\stage-engine';
    Unpack(Tmp + '\engine.zip', Staging, 'Unpacking the whisper.cpp engine...');
    CopyStaged(Staging, ExpandConstant('{app}\bin'), True, '');
    DelTree(Staging, True, True, True);
    RecordArchive('engine', EngineSha);
  end;

  if not KeepFfmpeg then begin
    ForgetArchive('ffmpeg');
    Staging := Tmp + '\stage-ffmpeg';
    Unpack(Tmp + '\ffmpeg.zip', Staging, 'Unpacking ffmpeg...');
    CopyStaged(Staging, ExpandConstant('{app}\bin'), False, 'ffmpeg.exe');
    DelTree(Staging, True, True, True);
    RecordArchive('ffmpeg', '{#FfmpegSha}');
  end;

  if not KeepModel then begin
    Model := TierFile[SelectedTierIndex];
    WizardForm.StatusLabel.Caption := 'Placing the model...';
    if not FileCopy(Tmp + '\' + Model, ExpandConstant('{app}\models\') + Model, False) then
      RaiseException('Could not place the model into ' + ExpandConstant('{app}\models'));
  end;
end;

// ---------------------------------------------------------------------
// Installed size
//
// Inno Setup records the size of [Files] only - the script and the
// uninstaller, about 4 MB - while everything that makes up the real
// install is downloaded by code. "Installed apps" showed 4.33 MB for a
// 3.9 GB install. The real figure depends on the tier and the engine, so
// it is measured once the downloads have landed rather than written in
// at compile time. The application measures it again when a tier change
// adds or removes a model; lib\Install.ahk carries the same AppId.
// ---------------------------------------------------------------------

function DirSize(const Dir: String): Int64;
var
  FindRec: TFindRec;
  SizeHi: Int64;
begin
  Result := 0;
  if FindFirst(AddBackslash(Dir) + '*', FindRec) then begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') then begin
          if FindRec.Attributes and FILE_ATTRIBUTE_DIRECTORY <> 0 then
            Result := Result + DirSize(AddBackslash(Dir) + FindRec.Name)
          else begin
            SizeHi := FindRec.SizeHigh;
            Result := Result + SizeHi * 65536 * 65536 + FindRec.SizeLow;
          end;
        end;
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
end;

procedure RecordInstalledSize;
var
  Key: String;
  Kb: Cardinal;
begin
  // SetupSetting returns the AppId as written in [Setup], with its
  // doubled opening brace; ExpandConstant turns that back into one.
  Key := ExpandConstant('Software\Microsoft\Windows\CurrentVersion\Uninstall\{#SetupSetting("AppId")}_is1');
  Kb := (DirSize(ExpandConstant('{app}')) + 1023) div 1024;
  if RegWriteDWordValue(HKA, Key, 'EstimatedSize', Kb) then
    Log('Installed size recorded: ' + IntToStr(Kb) + ' KB')
  else
    Log('Could not record the installed size under ' + Key);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    InstallDownloads;
    RecordInstalledSize;
    InstallWebView2;
  end;
end;

// ---------------------------------------------------------------------
// Uninstall
// ---------------------------------------------------------------------

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  // usUninstall comes after the user confirmed and before anything is
  // deleted: stopping Whispers any earlier would kill it for an
  // uninstall that is then cancelled.
  if CurUninstallStep = usUninstall then begin
    StopRunningWhispers;
    Exit;
  end;
  if CurUninstallStep <> usPostUninstall then
    Exit;
  DataDir := ExpandConstant('{userappdata}\{#AppName}');
  if not DirExists(DataDir) then
    Exit;
  if SuppressibleMsgBox('Also delete your settings, logs and dictation history?' + #13#10 +
                        DataDir, mbConfirmation, MB_YESNO, IDNO) = IDYES then
    DelTree(DataDir, True, True, True);
end;
