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

#ifnexist "pins.iss"
  #error pins.iss is missing - build through tools\build-installer.ps1, not ISCC directly
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
UninstallDisplayIcon={app}\AutoHotkey64.exe

; No administrator rights, ever.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

; The archives are .zip, which only the "full" extraction method reads.
ArchiveExtraction=full

; A running Whispers holds AutoHotkey64.exe, and a running engine holds
; the DLLs in bin\. Let Restart Manager notice and offer to close them
; rather than failing halfway through on a locked file.
CloseApplications=yes
RestartApplications=no

WizardStyle=modern
OutputDir=..\dist
OutputBaseFilename={#AppName}-{#AppVersion}-setup
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=..\LICENSE

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

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

[INI]
; Seed the tier the user picked in the wizard. Every other setting keeps
; its built-in default, which the application writes on first run.
Filename: "{userappdata}\{#AppName}\{#AppName}.ini"; Section: "Engine"; Key: "Tier"; \
  String: "{code:ChosenTierValue}"

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\AutoHotkey64.exe"; Parameters: """{app}\Whispers.ahk"""; WorkingDir: "{app}"; IconFilename: "{sys}\shell32.dll"; IconIndex: 28
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\AutoHotkey64.exe"; Parameters: """{app}\Whispers.ahk"""; WorkingDir: "{app}"; IconFilename: "{sys}\shell32.dll"; IconIndex: 28; Tasks: desktopicon
Name: "{userstartup}\{#AppName}"; Filename: "{app}\AutoHotkey64.exe"; Parameters: """{app}\Whispers.ahk"""; WorkingDir: "{app}"; IconFilename: "{sys}\shell32.dll"; IconIndex: 28; Tasks: startup

[Run]
Filename: "{app}\AutoHotkey64.exe"; Parameters: """{app}\Whispers.ahk"""; WorkingDir: "{app}"; \
  Description: "Start {#AppName} now"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Downloaded at install time, so the uninstaller has no record of them.
Type: filesandordirs; Name: "{app}\bin"
Type: filesandordirs; Name: "{app}\models"
Type: files;          Name: "{app}\AutoHotkey64.exe"

[Code]

const
  TIER_COUNT = 4;

var
  TierPage:     TInputOptionWizardPage;
  DownloadPage: TDownloadWizardPage;

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

  DownloadPage := CreateDownloadPage(SetupMessage(msgWizardPreparing),
                                     SetupMessage(msgPreparingDesc), nil);
  DownloadPage.ShowBaseNameInsteadOfUrl := True;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo,
  MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  Detected: String;
begin
  if GpuPresent then
    Detected := GpuName + ' (' + IntToStr(GpuVramMb) +
                ' MB VRAM, driver supports CUDA ' + GpuCudaMax + ')'
  else
    Detected := 'no usable NVIDIA GPU - CPU mode';

  Result := MemoDirInfo + NewLine + NewLine +
            'Detected hardware:' + NewLine + Space + Detected + NewLine + NewLine +
            'Will download:' + NewLine +
            Space + 'whisper.cpp {#EngineTag}, ' + EngineLabel + ' build' + NewLine +
            Space + 'ffmpeg {#FfmpegVersion}' + NewLine +
            Space + 'AutoHotkey {#AhkVersion}' + NewLine +
            Space + 'model ' + TierFile[SelectedTierIndex] + NewLine + NewLine +
            'Every download is rejected unless its SHA-256 matches versions.json.' + NewLine;
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
  DownloadPage.Add('{#AhkUrl}',    'AutoHotkey.zip', '{#AhkSha}');
  DownloadPage.Add('{#FfmpegUrl}', 'ffmpeg.zip',     '{#FfmpegSha}');
  DownloadPage.Add('{#EngineBase}' + EngineAsset, 'engine.zip', EngineSha);
  DownloadPage.Add('{#ModelBase}' + TierFile[Tier], TierFile[Tier], TierSha[Tier]);

  DownloadPage.Show;
  try
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

function KeepFromEngine(const Name: String): Boolean;
begin
  Result := EndsWithText(Name, '.dll') or
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

  Staging := Tmp + '\stage-ahk';
  Unpack(Tmp + '\AutoHotkey.zip', Staging, 'Unpacking AutoHotkey...');
  CopyStaged(Staging, ExpandConstant('{app}'), False, 'AutoHotkey64.exe');
  DelTree(Staging, True, True, True);

  Staging := Tmp + '\stage-engine';
  Unpack(Tmp + '\engine.zip', Staging, 'Unpacking the whisper.cpp engine...');
  CopyStaged(Staging, ExpandConstant('{app}\bin'), True, '');
  DelTree(Staging, True, True, True);

  Staging := Tmp + '\stage-ffmpeg';
  Unpack(Tmp + '\ffmpeg.zip', Staging, 'Unpacking ffmpeg...');
  CopyStaged(Staging, ExpandConstant('{app}\bin'), False, 'ffmpeg.exe');
  DelTree(Staging, True, True, True);

  Model := TierFile[SelectedTierIndex];
  WizardForm.StatusLabel.Caption := 'Placing the model...';
  if not FileCopy(Tmp + '\' + Model, ExpandConstant('{app}\models\') + Model, False) then
    RaiseException('Could not place the model into ' + ExpandConstant('{app}\models'));
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    InstallDownloads;
end;

// ---------------------------------------------------------------------
// Uninstall
// ---------------------------------------------------------------------

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep <> usPostUninstall then
    Exit;
  DataDir := ExpandConstant('{userappdata}\{#AppName}');
  if not DirExists(DataDir) then
    Exit;
  if SuppressibleMsgBox('Also delete your settings, logs and dictation history?' + #13#10 +
                        DataDir, mbConfirmation, MB_YESNO, IDNO) = IDYES then
    DelTree(DataDir, True, True, True);
end;
