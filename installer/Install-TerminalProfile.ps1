$ErrorActionPreference = 'Stop'
$profileDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Microsoft/Windows Terminal/Fragments/BIOSPHIR.Bicdop'
[void][IO.Directory]::CreateDirectory($profileDirectory)
$launcher = Join-Path $PSScriptRoot 'Bicdop.exe'
$profile = @{
    profiles = @(@{
        guid = '{3cabbd83-d76a-4e06-843c-c063229c9b40}'
        name = 'Bicdop'
        commandline = '"' + $launcher + '"'
        startingDirectory = [Environment]::GetFolderPath('MyDocuments')
        icon = Join-Path $PSScriptRoot 'logo-bicdop-favicon.png'
        tabTitle = 'Bicdop'
        suppressApplicationTitle = $false
    })
}
$fragment = Join-Path $profileDirectory 'bicdop.json'
[IO.File]::WriteAllText($fragment, ($profile | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
