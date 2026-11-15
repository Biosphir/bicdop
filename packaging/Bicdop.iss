[Setup]
AppId=Biosphir.Bicdop
AppName=Bicdop
AppVersion={#AppVersion}
AppPublisher=BIOSPHIR
DefaultDirName={localappdata}\Programs\Bicdop
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=BicdopSetup-x64
ChangesEnvironment=yes
CloseApplications=yes
RestartApplications=no
UninstallDisplayIcon={app}\bicdop.exe

[Tasks]
Name: "path"; Description: "Add Bicdop to the user PATH"
Name: "python"; Description: "Download and install Python 3.12.10 for project development"; Flags: unchecked

[Files]
Source: "..\dist\bicdop\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Run]
Filename: "{tmp}\bicdop-python.exe"; Parameters: "/passive InstallAllUsers=0 PrependPath=1 Include_test=0"; StatusMsg: "Installing Python for project development..."; Flags: waituntilterminated; Tasks: python

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not WizardIsTaskSelected('python') then exit;
  try
    DownloadTemporaryFile(
      'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe',
      'bicdop-python.exe',
      '67b5635e80ea51072b87941312d00ec8927c4db9ba18938f7ad2d27b328b95fb',
      nil);
  except
    Result := 'Could not download or verify Python. Go back and deselect the Python option to install Bicdop only.';
  end;
end;

const
  EnvKey = 'Environment';
  StateKey = 'Software\BIOSPHIR\Bicdop';

procedure CurStepChanged(CurStep: TSetupStep);
var
  Existing, AppDir: String;
begin
  if (CurStep <> ssPostInstall) or not WizardIsTaskSelected('path') then exit;
  AppDir := ExpandConstant('{app}');
  if not RegQueryStringValue(HKCU, EnvKey, 'Path', Existing) then Existing := '';
  if Pos(';' + Uppercase(AppDir) + ';', ';' + Uppercase(Existing) + ';') = 0 then
  begin
    if (Existing <> '') and (Existing[Length(Existing)] <> ';') then
      Existing := Existing + ';';
    if RegWriteExpandStringValue(HKCU, EnvKey, 'Path', Existing + AppDir) then
      RegWriteStringValue(HKCU, StateKey, 'PathAdded', AppDir)
    else
      MsgBox('Could not add Bicdop to the user PATH.', mbError, MB_OK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Existing, AppDir: String;
  EntryAt: Integer;
begin
  if CurUninstallStep <> usPostUninstall then exit;
  if not RegQueryStringValue(HKCU, StateKey, 'PathAdded', AppDir) then exit;
  if RegQueryStringValue(HKCU, EnvKey, 'Path', Existing) then
  begin
    EntryAt := Pos(';' + Uppercase(AppDir) + ';', ';' + Uppercase(Existing) + ';');
    if EntryAt > 0 then
    begin
      if EntryAt = 1 then
        Delete(Existing, 1, Length(AppDir) + 1)
      else
        Delete(Existing, EntryAt - 1, Length(AppDir) + 1);
      RegWriteExpandStringValue(HKCU, EnvKey, 'Path', Existing);
    end;
  end;
  RegDeleteValue(HKCU, StateKey, 'PathAdded');
end;
