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
Source: "..\Bicdop\Bicdop.psd1"; DestDir: "{app}\bundled"; Flags: ignoreversion
Source: "..\Bicdop\Bicdop.psm1"; DestDir: "{app}\bundled"; Flags: ignoreversion
Source: "..\Bicdop\Bicdop.Format.ps1xml"; DestDir: "{app}\bundled"; Flags: ignoreversion
Source: "..\Bicdop\Registry.ps1"; DestDir: "{app}\bundled"; Flags: ignoreversion
Source: "..\Bicdop\Update.ps1"; DestDir: "{app}\bundled"; Flags: ignoreversion

[Icons]
Name: "{group}\Bicdop"; Filename: "{app}\Bicdop.exe"; WorkingDir: "{userdocs}"

[Run]
Filename: "{app}\Bicdop.exe"; Description: "Open Bicdop"; WorkingDir: "{userdocs}"; Flags: nowait postinstall skipifsilent
