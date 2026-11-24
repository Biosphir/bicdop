param([string]$TestDirectory = [Environment]::GetFolderPath('MyDocuments'))
$ErrorActionPreference = 'Stop'
$module = Import-Module "$PSScriptRoot/../Bicdop/Bicdop.psd1" -Force -PassThru
$root = Join-Path $TestDirectory ('bicdop-cluster-test-' + [guid]::NewGuid().ToString('N'))
$data = Join-Path $root 'state'
$target = Join-Path $root 'workspace'
[void][IO.Directory]::CreateDirectory($data)
[void][IO.Directory]::CreateDirectory($target)

function Assert-Cluster($Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}

function Assert-ClusterThrows([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null }
    catch { if ($_.Exception.Message -match $Pattern) { return }; throw }
    throw "Expected error matching '$Pattern'."
}

try {
    & $module {
        param($registry)
        $script:RegistryPath = $registry
        function script:Confirm-Bicdop($Text) { $true }
    } (Join-Path $data 'registry.json')
    Push-Location $target
    try {
        bicdop blueprint create developer
        $file = (bicdop blueprint list | Select-Object -First 1).FullName
        [IO.File]::WriteAllText($file, @"
{
  "apiVersion": "bicdop.io/v1", "kind": "Blueprint", "metadata": { "name": "developer" },
  "spec": { "resources": [
    { "id": "text", "type": "file", "path": "src/readme.txt", "value": "hello", "dependsOn": ["folder"] },
    { "id": "folder", "type": "directory", "path": "src" }
  ]}
}
"@)
        Assert-Cluster ((bicdop blueprint validate developer).Status -eq 'Valid') 'Validation failed'
        $plan = @(bicdop blueprint plan developer)
        Assert-Cluster ($plan.Count -eq 2 -and $plan[0].Resource -eq 'folder' -and $plan[1].Status -eq 'Changes required') 'Dependency ordering or plan failed'
        Assert-Cluster (!(Test-Path -LiteralPath (Join-Path $target 'src'))) 'Plan modified the workspace'
        $first = @(bicdop blueprint apply developer)
        Assert-Cluster (@($first | Where-Object Status -eq 'Changed').Count -eq 2) 'Apply did not create resources'
        Assert-Cluster ((Get-Content -LiteralPath (Join-Path $target 'src/readme.txt') -Raw) -ceq 'hello') 'Text did not persist'
        $second = @(bicdop blueprint apply developer)
        Assert-Cluster (@($second | Where-Object Status -eq 'Compliant').Count -eq 2) 'Reapply is not idempotent'
        [IO.File]::WriteAllText((Join-Path $target 'src/readme.txt'), 'drift')
        Assert-Cluster (@(bicdop blueprint drift developer | Where-Object Status -eq 'Changes required').Count -eq 1) 'Drift was not detected'
        bicdop blueprint apply developer | Out-Null
        Assert-Cluster ((Get-Content -LiteralPath (Join-Path $target 'src/readme.txt') -Raw) -ceq 'hello') 'Drift was not reconciled'
        $valid = [IO.File]::ReadAllText($file)
        [IO.File]::WriteAllText($file, $valid.Replace('src/readme.txt','../outside.txt'))
        Assert-ClusterThrows { bicdop blueprint validate developer } 'Unsafe path'
        [IO.File]::WriteAllText($file, $valid.Replace('"path": "src"','"path": "src", "dependsOn": ["text"]'))
        Assert-ClusterThrows { bicdop blueprint validate developer } 'dependency cycle'
        [IO.File]::WriteAllText($file, $valid)

        $agent = bicdop agent enable $target
        Assert-Cluster ($agent.Enabled -and $agent.DeviceId) 'Agent was not enabled'
        & $module {
            param($file, $id)
            $request = @{ protocol = 1; id = 'abcdefabcdefabcdefabcdefabcdefab'; deviceId = $id; operation = 'plan'; blueprint = Read-BicdopJson $file }
            $agentState = (Read-BicdopCluster).agent
            if (@(Invoke-BicdopAgentOperation $request $agentState).Count -ne 2) { throw 'Agent plan failed.' }
            $request.deviceId = 'wrong-device'
            try { Invoke-BicdopAgentOperation $request $agentState | Out-Null; throw 'Accepted wrong device.' }
            catch { if ($_.Exception.Message -notmatch 'Device identity does not match') { throw } }
            $request.deviceId = $id
            $request.operation = 'exec'
            $request.command = 'cmd /c dir'
            try { Invoke-BicdopAgentOperation $request $agentState | Out-Null; throw 'Accepted unrestricted command.' }
            catch { if ($_.Exception.Message -notmatch 'allows git status') { throw } }
        } $file $agent.DeviceId
        $bootstrap = Join-Path $data 'wire-agent.ps1'
        $bootstrapLines = @(
            'param($Manifest, $Registry)'
            '$ErrorActionPreference = ''Stop'''
            '$loaded = Import-Module $Manifest -Force -PassThru'
            '& $loaded { param($Path); $script:RegistryPath = $Path } $Registry'
            'bicdop agent serve'
        )
        [IO.File]::WriteAllLines($bootstrap, $bootstrapLines)
        $manifest = (Resolve-Path "$PSScriptRoot/../Bicdop/Bicdop.psd1").Path
        $registry = Join-Path $data 'registry.json'
        $engine = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' })
        $wire = @{protocol=1; id=[guid]::NewGuid().ToString('N'); deviceId=$agent.DeviceId; operation='apply'
            blueprint=(Get-Content -LiteralPath $file -Raw | ConvertFrom-Json) }
        $message = ConvertTo-Json -InputObject $wire -Depth 10 -Compress
        $reply = $message | & $engine -NoProfile -NonInteractive -File $bootstrap $manifest $registry | ConvertFrom-Json
        Assert-Cluster ($reply.status -eq 'Completed' -and $reply.id -eq $wire.id -and $reply.deviceId -eq $wire.deviceId) 'Agent wire request failed'
        $replay = $message | & $engine -NoProfile -NonInteractive -File $bootstrap $manifest $registry | ConvertFrom-Json
        Assert-Cluster ($replay.status -eq 'Failed' -and $replay.error -like '*already processed*') 'Agent accepted a replayed mutation'
        bicdop agent revoke
        $revoked = bicdop agent status
        Assert-Cluster (!$revoked.Enabled -and $revoked.DeviceId -ne $agent.DeviceId) 'Revocation failed'
        Assert-Cluster (@(bicdop blueprint history developer).Count -eq 3) 'Missing apply audit records'
        Assert-ClusterThrows { bicdop fleet list } 'Unknown Bicdop command'
        & $module {
            function script:Invoke-BicdopAgentSetupApproval($Settings) { $script:TestSetup = $Settings }
            function script:Show-BicdopManagedAgentInfo { [pscustomobject]@{ Controller = $script:TestSetup.Controller } }
            function script:Start-BicdopShell([switch]$KeepLocation) {
                [pscustomobject]@{ Directory = (Get-Location).Path; KeepLocation = [bool]$KeepLocation }
            }
        }
        $key = bicdop cluster key
        Assert-Cluster ((Test-Path -LiteralPath $key.PublicKey) -and (Test-Path -LiteralPath $key.IdentityFile)) 'Controller key generation failed'
        $setup = bicdop agent setup 192.168.1.20 $key.PublicKey
        Assert-Cluster ($setup.Controller -eq '192.168.1.20') 'Agent setup did not pass the validated IPv4 address'
        Assert-ClusterThrows { bicdop agent setup 127.0.0.1 $key.PublicKey } 'Controller IPv4'
        $directory = Join-Path $target 'Folder with spaces'
        [void][IO.Directory]::CreateDirectory($directory)
        $opened = bicdop --directory $directory
        Assert-Cluster ($opened.Directory -eq $directory -and $opened.KeepLocation) 'Explicit directory did not suppress session restore'

    } finally { Pop-Location }
    'Bicdop Cluster and Blueprint tests passed.'
} finally {
    [IO.Directory]::Delete($root, $true)
}
