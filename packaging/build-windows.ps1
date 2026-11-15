param(
    [string]$Python = 'python',
    [string]$InnoCompiler = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
)
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    & $Python -c "import struct; assert struct.calcsize('P') == 8"
    if ($LASTEXITCODE) { throw 'Use a 64-bit Windows Python.' }
    $version = & $Python -c "from importlib.metadata import version; print(version('bicdop'))"
    if ($LASTEXITCODE -or $version -notmatch '^\d+\.\d+\.\d+$') { throw 'Install the local Bicdop package before building.' }
    & $Python -m PyInstaller --noconfirm --name bicdop --onedir --copy-metadata bicdop --specpath build packaging/launcher.py
    if ($LASTEXITCODE) { throw 'PyInstaller build failed.' }
    & $InnoCompiler "/DAppVersion=$version" packaging/Bicdop.iss
    if ($LASTEXITCODE) { throw 'Inno Setup build failed.' }
}
finally {
    Pop-Location
}
