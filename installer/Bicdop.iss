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
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "{#LauncherPath}"; DestDir: "{app}"; DestName: "Bicdop.exe"; Flags: ignoreversion
Source: "Start-Bicdop.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "Install-TerminalProfile.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\logo-bicdop-favicon.png"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Bicdop\Bicdop.psd1"; DestDir: "{app}\bundled"; Flags: ignoreversion
Source: "..\Bicdop\Bicdop.psm1"; DestDir: "{app}\bundled"; Flags: ignoreversion
Source: "..\Bicdop\Bicdop.Format.ps1xml"; DestDir: "{app}\bundled"; Flags: ignoreversion
Source: "..\Bicdop\Registry.ps1"; DestDir: "{app}\bundled"; Flags: ignoreversion
Source: "..\Bicdop\Update.ps1"; DestDir: "{app}\bundled"; Flags: ignoreversion

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
