; typebud Windows installer (Inno Setup 6).
;
; Build with scripts/make-installer-windows.ps1, which passes:
;   /DAppVersion=<semver>            e.g. 0.3.0 or 0.3.0-beta.1
;   /DAppVersionNumeric=<a.b.c.d>    numeric form for the version resource
;   /DPackageDir=<abs path>          the `zig build package` Windows output (<prefix>\typebud)
;   /DOutputDir=<abs path>           where typebud-setup-<ver>-x86_64.exe is written
;
; Per-user install, no admin prompt, into %LOCALAPPDATA%\Programs\typebud: the same
; directory the in-app updater (updater/src/platform.zig) recognizes and updates in place.
; The AppId below identifies typebud to Windows forever; never change it, or upgrades
; stop replacing the existing install.

#ifndef AppVersion
  #error Define AppVersion (/DAppVersion=1.2.3)
#endif
#ifndef PackageDir
  #error Define PackageDir (/DPackageDir=C:\path\to\out\pkg\typebud)
#endif
#ifndef AppVersionNumeric
  #define AppVersionNumeric "0.0.0.0"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

#define AppName "typebud"
#define AppExe "typebud.exe"
#define RunKey "Software\Microsoft\Windows\CurrentVersion\Run"
; The Run value name the app's "Launch at Login" toggle uses (src/app.zig app_id, written by
; zpui's Windows setLaunchAtLogin as "<exe path>" in quotes), so the two agree.
#define RunValue "typebud"

[Setup]
AppId={{90046696-87F8-4838-81E6-43CEE02FA39E}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=plyght
AppPublisherURL=https://github.com/plyght/typebud
AppSupportURL=https://github.com/plyght/typebud/issues
AppUpdatesURL=https://github.com/plyght/typebud/releases
AppCopyright=typebud contributors
VersionInfoVersion={#AppVersionNumeric}
VersionInfoProductVersion={#AppVersionNumeric}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoDescription={#AppName} setup

PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\typebud
DisableDirPage=yes
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableWelcomePage=no
UsePreviousTasks=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

WizardStyle=modern
WizardImageFile=wizard-large-100.bmp,wizard-large-125.bmp,wizard-large-150.bmp,wizard-large-175.bmp,wizard-large-200.bmp,wizard-large-225.bmp,wizard-large-250.bmp
WizardSmallImageFile=wizard-small-100.bmp,wizard-small-125.bmp,wizard-small-150.bmp,wizard-small-175.bmp,wizard-small-200.bmp,wizard-small-225.bmp,wizard-small-250.bmp
SetupIconFile=..\icons\typebud.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}

; A running typebud holds typebud.exe open: close it before files are replaced.
CloseApplications=force
CloseApplicationsFilter=*.exe
RestartApplications=no

OutputDir={#OutputDir}
OutputBaseFilename=typebud-setup-{#AppVersion}-x86_64
Compression=lzma2/max
SolidCompression=yes
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
WelcomeLabel1=Say hi to typebud
WelcomeLabel2=This will install typebud {#AppVersion}, a cozy pet that types along with you.%n%nIt installs just for you: no administrator rights needed. typebud never records what you type.
FinishedHeadingLabel=typebud is ready
FinishedLabel=typebud is installed. It lives in the notification area; right-click it there for Settings.

[CustomMessages]
StartupGroup=Startup:
StartupTask=Launch typebud when I sign in
RemoveSettingsPrompt=Also delete your typebud settings?%n%nChoose No to keep them in case you install typebud again.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "startup"; Description: "{cm:StartupTask}"; GroupDescription: "{cm:StartupGroup}"; Flags: unchecked

[Files]
Source: "{#PackageDir}\*"; DestDir: "{app}"; Excludes: "*.pdb,*.zip"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Comment: "A cozy pet that types along with you"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "{#RunKey}"; ValueType: string; ValueName: "{#RunValue}"; ValueData: """{app}\{#AppExe}"""; Tasks: startup; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Leftovers from in-app updates (<name>.old, staging dirs) and the updater's state/cache.
Type: filesandordirs; Name: "{app}"
Type: filesandordirs; Name: "{localappdata}\typebud"

[Code]
function HasParam(const Name: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), Name) = 0 then
    begin
      Result := True;
      Exit;
    end;
end;

{ Ask a running typebud (this user's) to quit, then make sure it is gone. }
procedure CloseTypebud();
var
  Code: Integer;
  Filter: String;
begin
  Filter := '/FI "USERNAME eq ' + GetUserNameString() + '" /IM {#AppExe}';
  if Exec(ExpandConstant('{sys}\taskkill.exe'), Filter, '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0) then
  begin
    Sleep(2000);
    Exec(ExpandConstant('{sys}\taskkill.exe'), '/F ' + Filter, '', SW_HIDE, ewWaitUntilTerminated, Code);
    Sleep(500);
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  if FileExists(ExpandConstant('{app}\{#AppExe}')) then
    CloseTypebud();
  Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  CloseTypebud();
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Settings: String;
begin
  if CurUninstallStep = usUninstall then
    { Also covers a Run value the app's own Launch at Login toggle wrote. }
    RegDeleteValue(HKCU, '{#RunKey}', '{#RunValue}');
  if CurUninstallStep = usPostUninstall then
  begin
    Settings := ExpandConstant('{userappdata}\typebud');
    if DirExists(Settings) then
      if HasParam('/REMOVESETTINGS') or
         ((not UninstallSilent()) and
          (SuppressibleMsgBox(CustomMessage('RemoveSettingsPrompt'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES)) then
        DelTree(Settings, True, True, True);
  end;
end;
