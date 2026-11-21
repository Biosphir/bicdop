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
            return @{ tag_name = 'v0.4.1'; body = 'Example release notes' }
        }
    } $registry $root
}

try {
    Set-TestConfig $module
    bicdop
    Assert-That ((prompt) -like 'bicdop*') 'Prompt did not activate'
    $workspace = Join-Path $root 'Workspace'
    [void][IO.Directory]::CreateDirectory($workspace)
    Set-Location $workspace
    bicdop workspace --set
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
    Assert-That (($scan[0].PSObject.Properties.Name -join ',') -eq 'No.,Project,Workspace,Path,Status') 'Wrong scan columns'
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
    bicdop plant --all
    Assert-That (Test-Path (Join-Path $scan[1].Path '.bicdop')) 'Plant all did not plant remaining row'
    $outsideMarker = Get-Content (Join-Path $outside '.bicdop') -Raw | ConvertFrom-Json
    Assert-That ($null -eq $outsideMarker.workspace) 'Outside project automatically associated'
    Assert-Throws { bicdop scan --new } 'Usage'
    Assert-Throws { bicdop plant --all } 'No current'
    $known = @(bicdop projects)
    Assert-That ($known.Count -eq 3) 'Project list is incorrect'
    bicdop switch 1
    Assert-That ((Get-Location).Path -eq $known[0].Path) 'Switch did not update the real location'
    Assert-That ((1..3 | Measure-Object).Count -eq 3) 'Native pipelines failed'
    bicdop exit
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
    Assert-That ($update.Installed -eq '0.4.0' -and $update.UpdateAvailable) 'Update check returned the wrong version'
    Assert-Throws { bicdop update --yes } 'supports update --check only'
    'Bicdop smoke tests passed.'
} finally {
    Set-Location $original
    Remove-Module Bicdop -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force
}
