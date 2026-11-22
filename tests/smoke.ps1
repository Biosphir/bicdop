$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../Bicdop/Bicdop.psd1" -Force
$module = Get-Module Bicdop
$root = Join-Path ([IO.Path]::GetTempPath()) "bicdop-fixture-$([guid]::NewGuid())"
[void][IO.Directory]::CreateDirectory($root)
$original = Get-Location
$originalPrompt = (Get-Item Function:prompt).ScriptBlock.ToString()
$registry = Join-Path $root 'data/registry.json'

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock]$Command, [string]$Pattern) {
    try { & $Command | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected failure matching $Pattern"
}

function Set-TestConfig($CurrentModule) {
    & $CurrentModule {
        param($Registry, $Root)
        $script:RegistryPath = $Registry
        $script:TestRoot = $Root
        function script:Confirm-Bicdop($Message) { return $Message -notlike 'Assign*' }
        function script:Get-BicdopDrives { return $script:TestRoot }
        function script:Invoke-RestMethod {
            return @{ tag_name = 'v0.8.11'; body = 'Example release notes' }
        }
    } $registry $root
}

try {
    Set-TestConfig $module
    Assert-That ((& (Get-Module Bicdop) { Get-BicdopPrompt }).StartsWith('bicdop no-workspace-selected [')) 'Prompt did not activate'
    $coloredRows = @(& (Get-Module Bicdop) {
        [pscustomobject][ordered]@{ PSTypeName='Bicdop.ScanResult'; 'No.'=1
            Project='Example Project'; Workspace='Example'; Path='C:/example'; Status='Planted'; Size='10 B' } |
            Out-String -Stream -Width 130 | Write-BicdopProjectTable 6>&1
    })
    Assert-That (@($coloredRows | Where-Object { $_.MessageData.Message -eq 'Example Project' -and $_.MessageData.ForegroundColor -eq 'Cyan' }).Count -eq 1) 'Project table name was not cyan'
    $workspace = Join-Path $root 'Workspace'
    [void][IO.Directory]::CreateDirectory($workspace)
    Set-Location $workspace
    bicdop workspace --set
    Assert-That ((& (Get-Module Bicdop) { Get-BicdopPrompt }).StartsWith('bicdop Workspace [')) 'Prompt did not show active workspace'
    $promptParts = @(& (Get-Module Bicdop) { Get-BicdopPrompt -Display 6>&1 })
    $label = $promptParts[0].MessageData
    if ($Host.UI.SupportsVirtualTerminal) {
        $esc = [char]27
        Assert-That ($label.Message -ceq "$esc[38;2;139;79;224mbicdop$esc[39m") 'Bicdop label was not purple'
    } else {
        Assert-That ($label.Message -eq 'bicdop' -and $label.ForegroundColor -eq 'Magenta') 'Bicdop label palette fallback failed'
    }
    Assert-That ($promptParts[1].MessageData.Message -eq ' Workspace' -and $promptParts[1].MessageData.ForegroundColor -eq 'Blue') 'Workspace name was not blue'
    Assert-That ($promptParts[2].MessageData.Message -like '* > : ') 'Prompt suffix changed'
    $colored = @(& (Get-Module Bicdop) { Write-BicdopSyntax 'marker --set field "new value"' 6>&1 })
    $flag = $colored[1].MessageData
    if ($Host.UI.SupportsVirtualTerminal) {
        $esc = [char]27
        Assert-That ($flag.Message -ceq "$esc[38;2;108;108;108m--set$esc[39m") 'Flag did not use the darker RGB color'
    } else {
        Assert-That ($flag.Message -ceq '--set' -and $flag.ForegroundColor -eq 'DarkGray') 'Flag palette fallback failed'
    }
    Assert-That (@($colored | Where-Object { $_.MessageData.Message -eq '"new value"' -and $_.MessageData.ForegroundColor -eq 'Blue' }).Count -eq 1) 'Quoted value color did not match'
    $adapted = @(& (Get-Module Bicdop) { Write-BicdopSyntax 'bicdop ping localhost --count 1' 6>&1 })
    Assert-That (@($adapted | Where-Object { $_.MessageData.Message -eq 'ping' -and $_.MessageData.ForegroundColor -eq 'Yellow' }).Count -eq 1) 'Adapted command was not yellow'
    Assert-That (Test-Path .bicdop-workspace) 'Workspace marker missing'
    mkdir testing-one | Out-Null
    cd testing-one
    bicdop plant
    Assert-That (Test-Path .bicdop) 'Project marker missing'
    $existing = Get-Content .bicdop -Raw
    bicdop plant
    Assert-That ((Get-Content .bicdop -Raw) -ceq $existing) 'Marker overwritten'
    Set-Location $workspace
    mkdir testing-two | Out-Null
    mkdir my-test-three | Out-Null
    mkdir (Join-Path 'testing-one' '.git') | Out-Null
    New-Item -Type File -Path (Join-Path 'testing-two' '.git') | Out-Null
    $scan = @(bicdop scan)
    Assert-That ($scan.Count -eq 1 -and $scan[0].Project -eq 'testing-one') 'Default scan leaked unmarked projects'
    Assert-That (($scan[0].PSObject.Properties.Name -join ',') -eq 'No.,Project,Workspace,Path,Status,Size') 'Wrong scan columns'
    Assert-That (($scan | Out-String -Width 130) -match 'No\.\s+Project\s+Workspace\s+Path\s+Status') 'Scan did not render as a table'
    $scan = @(bicdop scan --project TESTING)
    Assert-That ($scan.Count -eq 1) 'Project filter failed'
    $scan = @(bicdop scan --git)
    Assert-That ($scan.Count -eq 2 -and $scan[1].Status -eq 'Not planted') 'Git scan failed'
    $outside = Join-Path $root 'outside-TEST'
    [void][IO.Directory]::CreateDirectory($outside)
    $before = Get-Content $registry -Raw
    $scan = @(bicdop scan --new TEST)
    Assert-That ($scan.Count -eq 3 -and $scan.Project -notcontains 'testing-one') 'New scan filter failed'
    Assert-That ((Get-Content $registry -Raw) -ceq $before) 'Scan wrote to registry'
    Assert-Throws { bicdop plant 1,1 } 'distinct'
    bicdop plant 1,3
    Assert-That (Test-Path (Join-Path $scan[0].Path '.bicdop')) 'First selected row not planted'
    Assert-That (-not (Test-Path (Join-Path $scan[1].Path '.bicdop'))) 'Unselected row planted'
    Assert-That (Test-Path (Join-Path $scan[2].Path '.bicdop')) 'Third selected row not planted'
    $nestedPlant = Join-Path $scan[1].Path 'Nested'
    $null = New-Item -ItemType Directory -Path $nestedPlant
    Assert-Throws { bicdop scan --new } 'Usage'
    Set-Location $workspace
    bicdop plant --all
    Assert-That (!(Test-Path -LiteralPath (Join-Path $nestedPlant '.bicdop'))) 'Plant all marked a nested folder'
    Assert-That (!(Test-Path -LiteralPath (Join-Path $workspace '.bicdop'))) 'Plant all marked the current folder'
    Assert-That (Test-Path (Join-Path $scan[1].Path '.bicdop')) 'Plant all did not plant remaining row'
    $outsideJson = Get-Content (Join-Path $outside '.bicdop') -Raw
    $outsideMarker = $outsideJson | ConvertFrom-Json
    Assert-That ($null -eq $outsideMarker.workspace) "Outside project automatically associated. Marker: $outsideJson"
    Assert-Throws { bicdop scan --new } 'Usage'
    Assert-Throws { bicdop plant 1 } 'No current'
    $known = @(bicdop projects)
    Assert-That ($known.Count -eq 3) 'Project list is incorrect'
    Assert-That ($known[0].Workspace -eq 'Workspace' -and $known[0].Size) 'Projects did not show workspace and size'
    Assert-That ([bool](bicdop workspace).Size) 'Workspace list did not show size'
    Assert-That (($known | Out-String -Width 140) -match 'Workspace.*Size') 'Projects did not render the size table'
    Assert-That (((bicdop workspace --find) | Out-String -Width 140) -match 'FullName.*Size') 'Workspace search did not render the size table'
    bicdop switch 1
    Assert-That ((Get-Location).Path -eq $known[0].Path) 'Switch did not update the real location'
    Assert-That ((1..3 | Measure-Object).Count -eq 3) 'Native pipelines failed'
    Assert-That ((Get-Item Function:prompt).ScriptBlock.ToString() -eq $originalPrompt) 'Prompt not restored'
    Remove-Module Bicdop
    Import-Module "$PSScriptRoot/../Bicdop/Bicdop.psd1"
    Set-TestConfig (Get-Module Bicdop)
    Assert-That (@(bicdop projects).Count -eq 3) 'Registry did not persist across module sessions'
    Set-Location $root
    $moved = Join-Path $root 'Workspace moved'
    Move-Item -LiteralPath $workspace -Destination $moved
    Set-Location $moved
    bicdop workspace --set
    $relocated = @(bicdop projects)
    Assert-That ($relocated.Count -eq 3) 'Projects were lost after workspace relocation'
    Assert-That ($relocated[0].Path -eq (Join-Path $moved $relocated[0].Project)) 'Relocated project path is incorrect'
    bicdop switch 1
    Assert-That ((Get-Location).Path -eq $relocated[0].Path) 'Switch failed after workspace relocation'
    $update = bicdop update --check
    $version = bicdop version
    Assert-That ($version.Installed -eq $update.Installed -and $version.Latest -eq $update.Latest -and $version.UpdateAvailable) 'Version did not match update --check'
    Assert-That ($update.Installed -eq '0.8.10' -and $update.UpdateAvailable) 'Update check returned the wrong version'
    Assert-Throws { bicdop update --yes } 'Usage: bicdop update'
    $projectMarker = Join-Path (Get-Location).Path '.bicdop'
    $originalId = (Get-Content -LiteralPath $projectMarker -Raw | ConvertFrom-Json).id
    bicdop marker --replant
    Assert-That ((Get-Content -LiteralPath $projectMarker -Raw | ConvertFrom-Json).id -eq $originalId) 'Replant changed project ID'
    bicdop marker --clear
    Assert-That (!(Test-Path -LiteralPath $projectMarker)) 'Clear did not remove the marker'
    Assert-That (@(bicdop projects).Count -eq 2) 'Clear did not remove the registration'
    $nested = Join-Path $moved 'Nested/Child'
    $null = New-Item -ItemType Directory -Path $nested -Force
    Set-Location $root
    $hiddenGitFolder = Join-Path $moved '.git/objects'
    $null = New-Item -ItemType Directory -Path $hiddenGitFolder -Force
    [IO.File]::WriteAllBytes((Join-Path $nested 'sample.bin'), [byte[]]::new(2048))
    $shown = @(bicdop show)
    $direct = (Get-Item -LiteralPath $nested).Parent.FullName
    $unmarked = $shown | Where-Object Path -eq $direct
    Assert-That ($unmarked.Size -eq '2 KB') 'Show did not sum nested file sizes'
    Assert-That ($unmarked.Status -eq 'Not planted') 'Show skipped unmarked direct folder'
    Assert-That ($shown.Path -contains (Get-Item -LiteralPath $hiddenGitFolder -Force).Parent.FullName) 'Show skipped direct Git folder'
    Assert-That ($nested -notin $shown.Path -and $hiddenGitFolder -notin $shown.Path -and $moved -notin $shown.Path) 'Show listed folders beyond one level'
    Assert-That (($unmarked.PSObject.Properties.Name -join ',') -eq 'No.,Project,Workspace,Path,Status,Size') 'Show columns do not match scan'
    Assert-That ($unmarked.PSObject.TypeNames[0] -eq 'Bicdop.ScanResult') 'Show did not reuse scan formatting'
    Assert-Throws { bicdop marker --clear } 'outside the active workspace'
    bicdop workspace --goto
    Assert-That ((Get-Location).Path -eq $moved) 'Workspace goto did not navigate to the active workspace root'
    Set-Location $root
    bicdop marker --replant --all
    Assert-That (!(Test-Path -LiteralPath (Join-Path $nested '.bicdop'))) 'Bulk replant marked a nested child'
    Set-Location $nested
    Assert-Throws { bicdop marker --replant } 'one level below'
    bicdop plant
    Assert-That (!(Test-Path -LiteralPath (Join-Path $nested '.bicdop'))) 'Plant marked a nested child'
    [IO.File]::WriteAllText((Join-Path $nested '.bicdop'), '{}')
    Assert-That (!(Test-Path -LiteralPath (Join-Path $moved '.bicdop'))) 'Bulk replant included the workspace root'
    Assert-That (Test-Path -LiteralPath $projectMarker) 'Bulk replant did not recreate a cleared marker'
    $directMarker = Join-Path $direct '.bicdop'
    $savedMarker = [IO.File]::ReadAllBytes($directMarker)
    [IO.File]::Delete($directMarker)
    $unmarkedProject = bicdop projects | Where-Object Path -eq $direct
    Assert-That ($unmarkedProject.Status -eq 'Not planted') 'Projects reported Planted without a marker'
    [IO.File]::WriteAllBytes($directMarker, $savedMarker)
    $directProjects = @(bicdop projects)
    Assert-That (($directProjects | Where-Object Path -eq $direct).Status -eq 'Planted') 'Projects did not report an existing marker as Planted'
    Assert-That ($directProjects.Path -contains $direct -and $nested -notin $directProjects.Path) 'Projects listed nested registrations'
    bicdop switch 1
    Assert-That ((Get-Location).Path -eq $directProjects[0].Path) 'Filtered project number selected the wrong path'
    Set-Location $direct
    [IO.File]::WriteAllText((Join-Path $direct 'main.py'), 'print("bicdop-python-ok")')
    bicdop marker --replant
    $projectData = Get-Content -LiteralPath (Join-Path $direct '.bicdop') -Raw | ConvertFrom-Json
    Assert-That ($projectData.main_file -eq 'main.py') ("Replant did not detect the Python entry point: " + ($projectData | ConvertTo-Json -Compress))
    $entry = Join-Path $direct 'Start Here.ps1'
    [IO.File]::WriteAllText($entry, '''run-ok''')
    bicdop run --set 'Start Here.ps1'
    bicdop project --version '2.3.4' | Out-Null
    Assert-That ((bicdop project --version) -eq '2.3.4') 'Project did not save manually set version'
    [IO.File]::WriteAllText((Join-Path $direct 'pyproject.toml'), "[project]" + [Environment]::NewLine + 'version = "3.0.0"')
    bicdop marker --replant
    Assert-That ((bicdop project --version) -eq '3.0.0') 'Replant did not detect the project version'
    Assert-That ((Get-Content -LiteralPath (Join-Path $direct '.bicdop') -Raw | ConvertFrom-Json).main_file -eq 'Start Here.ps1') 'Entry point was not stored'
    Assert-That ((bicdop project --main) -eq 'Start Here.ps1') 'Project main did not return the saved entry point'
    $contents = @(bicdop project --list)
    Assert-That ($contents.Name -contains 'Start Here.ps1' -and $contents.Name -contains 'Child') 'Project list missed direct files or folders'
    Assert-That (@($contents | Where-Object Name -eq '.bicdop').Count -eq 1) 'Project list missed the root marker or listed a nested marker'
    Assert-That ((bicdop run) -eq 'run-ok') 'Run failed from current folder'
    Set-Location $root
    [IO.File]::WriteAllText((Join-Path $direct 'pyproject.toml'), "[project]" + [Environment]::NewLine + 'version = "3.1.0"')
    Assert-That ((bicdop project 'Nested' --version) -eq '3.1.0') 'Named project did not refresh its version'
    $updatedMarker = Get-Content -LiteralPath (Join-Path $direct '.bicdop') -Raw | ConvertFrom-Json
    Assert-That ($updatedMarker.version -eq '3.1.0' -and $updatedMarker.main_file -eq 'Start Here.ps1') 'Version refresh did not preserve the entry point'
    Assert-That ((Get-Location).Path -eq $root) 'Named project version changed the current location'
    Assert-That ((bicdop run 'Nested') -eq 'run-ok') 'Run failed for named workspace folder'
    Assert-That ((Get-Location).Path -eq $root) 'Run changed the caller location'
    & (Get-Module Bicdop) {
        function script:Start-Process {
            [CmdletBinding()]
            param($FilePath, $ArgumentList, $WorkingDirectory, [switch]$PassThru)
            $script:Detached = @{
                Runtime = $FilePath; Arguments = $ArgumentList; Folder = $WorkingDirectory; PassThru = $PassThru.IsPresent
            }
            $fakeProcess = [pscustomobject]@{ Id = 12345; HasExited = $false }
            $fakeProcess | Add-Member ScriptMethod CloseMainWindow { return $false }
            $fakeProcess | Add-Member ScriptMethod Kill { $this.HasExited = $true }
            $fakeProcess | Add-Member ScriptMethod WaitForExit { param($Timeout) return $this.HasExited }
            $fakeProcess | Add-Member ScriptMethod Dispose {}
            $fakeProcess
        }
    }
    bicdop run 'Nested' --detach
    $detached = & (Get-Module Bicdop) { $script:Detached }
    Assert-That ($detached.Folder -eq $direct -and $detached.PassThru) 'Detached run did not start in the project folder'
    Assert-That ($detached.Arguments.EndsWith(('"{0}"' -f $entry))) 'Detached run did not quote the entry point'
    Assert-That ((Get-Location).Path -eq $root) 'Detached run changed the caller location'
    $previous = & (Get-Module Bicdop) { param($path) $script:DetachedRuns[$path] } $direct
    bicdop run 'Nested' --detach
    $replacement = & (Get-Module Bicdop) { param($path) $script:DetachedRuns[$path] } $direct
    Assert-That ($previous.HasExited -and !$replacement.HasExited -and ![object]::ReferenceEquals($previous, $replacement)) 'Detached run did not replace the previous process'

    $htmlFolder = Join-Path $direct 'HTML Preview'
    $null = New-Item -ItemType Directory -Path $htmlFolder
    $htmlEntry = Join-Path $htmlFolder 'index.html'
    [IO.File]::WriteAllText($htmlEntry, '<!doctype html><title>Bicdop preview</title>')
    & (Get-Module Bicdop) {
        function script:Start-Process {
            param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch]$PassThru, $ErrorAction)
            Microsoft.PowerShell.Management\Start-Process @PSBoundParameters
        }
        function script:Open-BicdopPreviewUrl($Url) { $Url }
    }
    Set-Location $htmlFolder
    try {
        $url = bicdop run
        Assert-That ($url -like 'http://127.0.0.1:*/index.html') 'Run did not open a localhost HTML preview'
        Assert-That ((bicdop run) -eq $url) 'Run did not reuse the live preview'
    } finally { bicdop stop }

    $customHtml = Join-Path $htmlFolder 'Preview Page.htm'
    [IO.File]::WriteAllText($customHtml, '<!doctype html><title>Bicdop preview</title>')
    [IO.File]::WriteAllText((Join-Path $htmlFolder 'style.css'), 'body { color: green; }')
    Set-Location $direct
    bicdop run --set 'HTML Preview/Preview Page.htm'
    Set-Location $root
    try {
        $url = bicdop run 'Nested'
        Assert-That ($url -like 'http://127.0.0.1:*/Preview%20Page.htm') 'Named run did not use the configured HTML entry point'
        $response = Invoke-WebRequest -Uri ([uri]::new([uri]$url, '/style.css')) -UseBasicParsing
        Assert-That ($response.Content -eq 'body { color: green; }') 'Preview did not use the entry folder as the document root'
    } finally { bicdop stop 'Nested' }
    & (Get-Module Bicdop) {
        function script:Open-BicdopExplorer {
            param($Path)
            $Path
        }
    }
    Assert-That ((bicdop open) -eq $root) 'Open did not use the current folder'
    Assert-That ((bicdop open --workspace) -eq $moved) 'Open did not use the active workspace'
    Assert-That ((bicdop open 'Nested') -eq $direct) 'Open did not resolve the named project'
    Assert-That ((Get-Location).Path -eq $root) 'Open changed the current location'
    Set-Location $direct
    $compile = 'python -m PyInstaller --name "A Project" main.py'
    bicdop pyinstaller --set $compile
    $gitForTest = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gitForTest) {
        Assert-Throws { bicdop github --status } 'not the root of a Git repository'
    }
    if ($gitForTest) {
        & $gitForTest.Source -C $direct init --quiet
        if ($LASTEXITCODE) { throw 'Fixture Git init failed' }
        & $gitForTest.Source -C $direct remote add origin 'https://test-user:dummy-password@github.com/example/sample.git'
        if ($LASTEXITCODE) { throw 'Fixture Git remote failed' }
    }
    bicdop marker --replant
    $preset = Get-Content -LiteralPath (Join-Path $direct '.bicdop') -Raw | ConvertFrom-Json
    Assert-That ($preset.pyinstaller_command -ceq $compile) 'Replant lost the PyInstaller preset'
    if ($gitForTest) {
        Assert-That ($preset.github_url -ceq 'https://github.com/example/sample') 'Marker did not store the credential-free GitHub link'
        Assert-That ($preset.github_release_url -ceq $preset.github_url) 'Release URL did not default to the project URL'
        bicdop marker --set github_release_url '"https://github.com/example/releases"'
        & $gitForTest.Source -C $direct remote set-url origin 'git@github.com:example/renamed.git'
        bicdop marker --replant
        Assert-That (((bicdop marker --check) | ConvertFrom-Json).github_url -ceq 'https://github.com/example/renamed') 'Replant did not refresh the SSH remote link'
        Assert-That (((bicdop marker --check) | ConvertFrom-Json).github_release_url -ceq 'https://github.com/example/releases') 'Replant changed the separate release repository'
        bicdop marker --set github_release_url null
        Assert-That (((bicdop marker --check) | ConvertFrom-Json).github_release_url -ceq 'https://github.com/example/renamed') 'Clearing the release override did not restore the default'
    }
    bicdop marker --set label '"007"'
    bicdop marker --set revision 7
    bicdop marker --set archived false
    bicdop marker --set note null
    Assert-Throws { bicdop marker --set label unquoted } 'Put text values in quotes'
    Assert-Throws { bicdop marker --set schema 2 } 'Bicdop manages'
    bicdop marker --replant
    $typed = bicdop marker --check | ConvertFrom-Json
    Assert-That (($typed.PSObject.Properties.Name[0..2] -join ',') -eq 'schema,id,workspace') 'Marker identity fields were not written first'
    Assert-That ($typed.label -is [string] -and $typed.label -ceq '007') 'Quoted value was not preserved through replant'
    Assert-That ($typed.revision -is [ValueType] -and $typed.revision -eq 7) 'Unquoted number was stored as text'
    Assert-That ($typed.archived -is [bool] -and !$typed.archived) 'Boolean value was not stored'
    Assert-That ($typed.PSObject.Properties.Name -contains 'note' -and $null -eq $typed.note) 'Null value was not stored'
    $localMarker = bicdop marker --check
    Assert-That (($localMarker | ConvertFrom-Json).pyinstaller_command -ceq $compile) 'Marker check missed a stored field'
    Set-Location $root
    Assert-That ((bicdop marker 'Nested' --check) -ceq $localMarker) 'Named marker check did not return the same marker'
    Assert-That ((Get-Location).Path -eq $root) 'Named marker check changed the current location'
    Assert-Throws { bicdop marker --check } 'No .bicdop marker'
    Set-Location $direct
    $argsFromPreset = @(& (Get-Module Bicdop) { param($line) ConvertTo-BicdopPyInstallerArgs $line } $compile)
    Assert-That ($argsFromPreset.Count -eq 3 -and $argsFromPreset[1] -ceq 'A Project') 'PyInstaller did not preserve quoted arguments'
    Assert-Throws { bicdop pyinstaller --set 'cmd.exe /c dir' } 'Enter a full command'
    Set-Location $root
    bicdop marker --clear --all
    Assert-That (!(Test-Path -LiteralPath (Join-Path $nested '.bicdop'))) 'Bulk clear skipped nested child'
    Assert-That (Test-Path -LiteralPath (Join-Path $moved '.bicdop-workspace')) 'Bulk clear removed workspace marker'
    Assert-That (@(bicdop projects).Count -eq 0) 'Bulk clear left project registrations'
    Set-Location $root
    & (Get-Module Bicdop) {
        $script:InputLines = [System.Collections.Generic.Queue[string]]::new()
        foreach ($line in 'mkdir "Shell Test"', 'cd "Shell Test"', 'cd..', 'help', 'exit', 'mkdir skipped') {
            $script:InputLines.Enqueue($line)
        }
        function script:Read-Host { $script:InputLines.Dequeue() }
        function script:Read-BicdopConsoleLine { Read-Host }
    }
    bicdop
    Assert-That ((Get-Location).Path -eq $root) 'cd.. did not move to the parent inside Bicdop'
    $savedSession = & (Get-Module Bicdop) { Read-BicdopSessions }
    Assert-That ($savedSession.last.path -eq (Get-Location).Path) 'Bicdop did not save the current location'
    Assert-That ($savedSession.history -contains 'cd "Shell Test"' -and $savedSession.history -notcontains 'exit') 'Bicdop did not save the usable command history'
    $record = $savedSession.log | Where-Object { $_.command -eq 'cd "Shell Test"' }
    Assert-That ($record.status -eq 'completed') 'Session log did not record the command result'
    Assert-That ((bicdop li).Name -contains 'Shell Test') 'The shell did not create or list the quoted directory'
    Assert-That (!(Test-Path -LiteralPath (Join-Path $root 'skipped'))) 'Exit did not stop the shell'
    Assert-Throws { & (Get-Module Bicdop) { ConvertFrom-BicdopInput 'pwd; Get-Date' } } 'Invalid input'
    Assert-That ((Get-Item Function:prompt).ScriptBlock.ToString() -eq $originalPrompt) 'The shell changed the PowerShell prompt'
    & (Get-Module Bicdop) {
        function script:Clear-Host { 'cleared' }
    }
    Assert-That ((bicdop flush) -eq 'cleared') 'Flush did not clear the host'
    $remove = Join-Path $root 'Delete Me'
    $null = New-Item -ItemType Directory -Path $remove
    [IO.File]::WriteAllText((Join-Path $remove 'file.txt'), 'fixture')
    Assert-Throws { bicdop rmdir $remove } 'not empty'
    Assert-Throws { bicdop rmdir . --recursive } 'current folder'
    & (Get-Module Bicdop) {
        function script:Confirm-Bicdop($Message) { $false }
    }
    bicdop rmdir $remove --recursive
    Assert-That ([IO.Directory]::Exists($remove)) 'Rmdir ignored cancellation'
    & (Get-Module Bicdop) {
        function script:Confirm-Bicdop($Message) { $true }
    }
    $junctionTarget = Join-Path $root 'Junction Target'
    $null = New-Item -ItemType Directory -Path $junctionTarget
    $null = New-Item -ItemType Junction -Path (Join-Path $remove 'Link') -Target $junctionTarget
    $sentinel = Join-Path $junctionTarget 'keep.txt'
    [IO.File]::WriteAllText($sentinel, 'fixture')
    Assert-Throws { bicdop rmdir $remove --recursive } 'contains a symlink or junction'
    Assert-That ([IO.File]::Exists((Join-Path $remove 'file.txt')) -and [IO.File]::Exists($sentinel)) 'Rmdir modified the folder before rejecting a junction'
    $plain = Join-Path $root 'Plain Folder'
    $null = New-Item -ItemType Directory -Path $plain
    [IO.File]::WriteAllText((Join-Path $plain 'file.txt'), 'fixture')
    bicdop rmdir $plain --recursive
    Assert-That (![IO.Directory]::Exists($plain)) 'Recursive rmdir did not delete a regular folder'
    Assert-Throws { bicdop ping localhost --count 0 } 'Usage'
    'Bicdop smoke tests passed.'
} finally {
    Set-Location $original
    Remove-Module Bicdop -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force
}
