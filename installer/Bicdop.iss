#ifndef BicdopVersion
  #error Provide BicdopVersion when building the installer
#endif
#ifndef LauncherPath
  #error Provide LauncherPath when building the installer
#endif

[Setup]
AppId=Biosphir.Bicdop
AppName=Bicdop
AppVersion={#BicdopVersion}
AppPublisher=BIOSPHIR
DefaultDirName={localappdata}\Programs\Bicdop
DefaultGroupName=Bicdop
PrivilegesRequired=lowest
OutputBaseFilename=BicdopSetup
SetupIconFile=..\assets\logo-bicdop-favicon-ico.ico
UninstallDisplayIcon={app}\Bicdop.exe
ArchitecturesAllowed=x64compatible
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "..\Bicdop\Bicdop.psd1"; DestDir: "{app}\bundled"; Flags: ignoreversion
Source: "..\Bicdop\Bicdop.psm1"; DestDir: "{app}\bundled"; Flags: ignoreversion
Source: "..\Bicdop\Bicdop.Format.ps1xml"; DestDir: "{app}\bundled"; Flags: ignoreversion
Source: "..\Bicdop\Registry.ps1"; DestDir: "{app}\bundled"; Flags: ignoreversion
Source: "..\Bicdop\Update.ps1"; DestDir: "{app}\bundled"; Flags: ignoreversion
Source: "Uninstall-BicdopData.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#GhPath}\bin\gh.exe"; DestDir: "{app}\tools\gh"; Flags: ignoreversion
Source: "{#GhPath}\LICENSE"; DestDir: "{app}\tools\gh"; Flags: ignoreversion
Source: "{#GitPath}\*"; DestDir: "{app}\tools\git"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#LauncherPath}"; DestDir: "{app}"; DestName: "Bicdop.exe"; Flags: ignoreversion
Source: "Start-Bicdop.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "Install-TerminalProfile.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\logo-bicdop-favicon.png"; DestDir: "{app}"; Flags: ignoreversion

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Icons]
Name: "{group}\Bicdop"; Filename: "{app}\Bicdop.exe"; Parameters: "--terminal"; WorkingDir: "{userdocs}"
Name: "{userdesktop}\Bicdop"; Filename: "{app}\Bicdop.exe"; Parameters: "--terminal"; WorkingDir: "{userdocs}"; Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File ""{app}\Install-TerminalProfile.ps1"""; Flags: runhidden waituntilterminated
Filename: "{app}\Bicdop.exe"; Parameters: "--terminal"; Description: "Open Bicdop"; WorkingDir: "{userdocs}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{localappdata}\Microsoft\Windows Terminal\Fragments\BIOSPHIR.Bicdop\bicdop.json"
Type: dirifempty; Name: "{localappdata}\Microsoft\Windows Terminal\Fragments\BIOSPHIR.Bicdop"

[Code]
procedure ExportModuleFile(const Name, Destination: String);
begin
  ExtractTemporaryFile(Name);
  if not FileCopy(ExpandConstant('{tmp}\') + Name, AddBackslash(Destination) + Name, True) then
    RaiseException('Could not export ' + Name);
end;

function InitializeSetup: Boolean;
var
  Destination: String;
begin
  Destination := ExpandConstant('{param:ExtractModule|}');
  Result := Destination = '';
  if Result then
    Exit;

  { An update supplies an existing, empty staging folder. Returning False
    after extraction skips installation, shortcuts, and registry changes. }
  if not DirExists(Destination) then
    RaiseException('Module staging directory does not exist.');
  ExportModuleFile('Bicdop.psd1', Destination);
  ExportModuleFile('Bicdop.psm1', Destination);
  ExportModuleFile('Bicdop.Format.ps1xml', Destination);
  ExportModuleFile('Registry.ps1', Destination);
  ExportModuleFile('Update.ps1', Destination);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  MarkerSwitch, Args: String;
  ExitCode: Integer;
begin
  if CurUninstallStep <> usUninstall then
    Exit;

  MarkerSwitch := '';
  if not UninstallSilent then
    if MsgBox('Also remove Bicdop project and workspace marker files from registered folders?' + #13#10 +
      'Markers can contain project settings. Choose No to keep them. Your project files and Git repositories are kept.',
      mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
      MarkerSwitch := ' -RemoveMarkers';

  Args := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "' +
    ExpandConstant('{app}\Uninstall-BicdopData.ps1') + '" -DataRoot "' +
    ExpandConstant('{localappdata}\Bicdop') + '"' + MarkerSwitch;
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Args, '',
    SW_HIDE, ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then
  begin
    Log('Bicdop data cleanup could not finish.');
    if not UninstallSilent then
      MsgBox('Some Bicdop data could not be removed. See the uninstall log or the remaining Bicdop data folder.',
        mbInformation, MB_OK);
  end;
end;
