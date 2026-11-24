param([string]$TestDirectory = [Environment]::GetFolderPath('MyDocuments'))
$ErrorActionPreference = 'Stop'
$module = Import-Module "$PSScriptRoot/../Bicdop/Bicdop.psd1" -Force -PassThru
$root = Join-Path $TestDirectory ('bicdop-automation-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)

function Assert-Automation($Condition,[string]$Message) { if (!$Condition) { throw $Message } }

try {
    & $module {
        param($registry)
        $script:RegistryPath=$registry
        function script:Confirm-Bicdop($Message) { $true }
    } (Join-Path $root 'registry.json')
    $name='email-archiver'
    $source=Join-Path $PSScriptRoot '../examples/automation/email-archiver'
    bicdop automation register $name --path $source | Out-Null
    bicdop automation schedule $name --daily 08:00 --timezone Asia/Jakarta | Out-Null
    bicdop automation enable $name | Out-Null
    $queued=bicdop automation run $name
    $run=bicdop automation tick
    Assert-Automation ($run.Status -eq 'Succeeded' -and $run.RunId -eq $queued.RunId) "Manual dispatch failed: $($run | ConvertTo-Json -Depth 6 -Compress)"
    Assert-Automation ($run.Metrics.mailboxes_checked -eq 3 -and $run.Metrics.mailboxes_processed -eq 2) 'Validated metrics missing.'
    $scheduled=& $module { Invoke-BicdopAutomationWorker 'email-archiver' ([datetime]::new(2026,11,22,1,0,0,[DateTimeKind]::Utc)) }
    Assert-Automation ($scheduled.Status -eq 'Succeeded') '08:00 Asia/Jakarta was not dispatched.'
    $repeat=& $module { Invoke-BicdopAutomationWorker 'email-archiver' ([datetime]::new(2026,11,22,1,0,30,[DateTimeKind]::Utc)) }
    Assert-Automation (!$repeat) 'Scheduled execution duplicated.'
    $blueprint = Join-Path $root 'Blueprints/policy.blueprint.yaml'
    bicdop blueprint create policy
    [IO.File]::WriteAllText($blueprint,'{"apiVersion":"bicdop.io/v1","kind":"Blueprint","metadata":{"name":"policy"},"spec":{"resources":[{"id":"job","type":"automation","name":"email-archiver","value":{"enabled":true,"time":"09:00","timezone":"Asia/Jakarta"}}]}}')
    Push-Location $root
    try {
        Assert-Automation ((bicdop blueprint plan policy).Status -eq 'Changes required') 'Blueprint plan missed schedule drift.'
        Assert-Automation ((bicdop automation inspect $name).schedule.time -eq '08:00') 'Plan wrote a job definition.'
        Assert-Automation ((bicdop blueprint apply policy).Status -eq 'Changed') 'Blueprint did not reconcile schedule.'
        Assert-Automation ((bicdop blueprint apply policy).Status -eq 'Compliant') 'Blueprint apply was not idempotent.'
        Assert-Automation (@(bicdop automation history $name).Count -eq 2) 'Blueprint apply started a job.'
    } finally { Pop-Location }
    bicdop automation run $name | Out-Null
    bicdop automation stop $name | Out-Null
    Assert-Automation (!(bicdop automation inspect $name).pending) 'Stop did not clear a pending request.'
    $zip = Join-Path $root 'demo.zip'
    Compress-Archive -LiteralPath @((Join-Path $source 'main.py'),(Join-Path $source 'bicdop-job.json')) -DestinationPath $zip
    $secondRegistry = Join-Path $root 'deployed/registry.json'
    & $module { param($registry) $script:RegistryPath=$registry } $secondRegistry
    $deployed = bicdop automation deploy $zip
    Assert-Automation ($deployed.id -eq $name -and !$deployed.enabled) 'ZIP did not register a disabled job.'
    Assert-Automation (!(bicdop automation history $name)) 'Deployment ran a job immediately.'
    'Bicdop Automation and Blueprint integration tests passed.'
} finally {
    [IO.Directory]::Delete($root,$true)
}
