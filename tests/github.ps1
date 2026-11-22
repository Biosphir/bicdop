$ErrorActionPreference = 'Stop'
$git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
Import-Module "$PSScriptRoot/../Bicdop/Bicdop.psd1" -Force
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$root = Join-Path $parent ('bicdop-git-test-' + [guid]::NewGuid())
$local = Join-Path $root 'local'
$remote = Join-Path $root 'origin.git'
$peer = Join-Path $root 'nested/peer'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $peer))
[void][IO.Directory]::CreateDirectory($root)

function Invoke-GitFixture([string[]]$Arguments) {
    # Git progress on stderr is not an error unless Git exits unsuccessfully.
    $ErrorActionPreference = 'Continue'
    & $git.Source @Arguments 2>$null
    if ($LASTEXITCODE) { throw "Git fixture failed: $($Arguments -join ' ')" }
}

try {
    Invoke-GitFixture @('init','--bare','-b','main',$remote) | Out-Null
    Invoke-GitFixture @('init','-b','main',$local) | Out-Null
    Invoke-GitFixture @('-C',$local,'remote','add','origin',$remote)
    Invoke-GitFixture @('-C',$local,'config','user.name','Bicdop Test')
    Invoke-GitFixture @('-C',$local,'config','user.email','bicdop-test@example.invalid')
    Invoke-GitFixture @('-C',$local,'config','commit.gpgsign','false')
    # Route the network-facing code to the isolated bare repository.
    & (Get-Module Bicdop) {
        function script:ConvertTo-BicdopGitHubUrl($Remote) { 'https://github.com/fixture/bicdop' }
    }

    Push-Location -LiteralPath $local
    try {
        [IO.File]::WriteAllText((Join-Path $local 'tracked.txt'), 'initial')
        [IO.File]::WriteAllText((Join-Path $local 'unstaged.txt'), 'unstaged')
        bicdop github --stage 'tracked.txt'
        if ((bicdop github --diff --staged | Out-String) -notmatch 'tracked\.txt') { throw 'Staged diff was missing' }
        bicdop github --unstage 'tracked.txt'
        if (!(Test-Path -LiteralPath (Join-Path $local 'tracked.txt')) -or
            @(Invoke-GitFixture @('-C',$local,'diff','--cached','--name-only')).Count) {
            throw 'Unstage failed before the first commit'
        }
        bicdop github --stage 'tracked.txt'
        bicdop github --commit 'Commit with spaces' | Out-Null
        if ((Invoke-GitFixture @('-C',$local,'log','-1','--format=%s')) -ne 'Commit with spaces') { throw 'Wrong commit message' }
        if ((Invoke-GitFixture @('-C',$local,'ls-files')) -contains 'unstaged.txt') { throw 'Commit staged unrelated files' }
        bicdop github --push | Out-Null
        if ((Invoke-GitFixture @('-C',$local,'rev-parse','HEAD')) -ne (Invoke-GitFixture @('-C',$remote,'rev-parse','refs/heads/main'))) {
            throw 'Push did not update origin'
        }

        Invoke-GitFixture @('clone','-b','main',$remote,$peer) | Out-Null
        Invoke-GitFixture @('-C',$peer,'config','user.name','Bicdop Test')
        Invoke-GitFixture @('-C',$peer,'config','user.email','bicdop-test@example.invalid')
        Invoke-GitFixture @('-C',$peer,'config','commit.gpgsign','false')
        [IO.File]::WriteAllText((Join-Path $peer 'remote.txt'), 'from remote')
        Invoke-GitFixture @('-C',$peer,'add','--','remote.txt')
        Invoke-GitFixture @('-C',$peer,'commit','-m','Remote commit') | Out-Null
        Invoke-GitFixture @('-C',$peer,'push','origin','main') | Out-Null

        bicdop github --fetch | Out-Null
        if (Test-Path -LiteralPath (Join-Path $local 'remote.txt')) { throw 'Fetch modified the working tree' }
        if ((bicdop github --status).Commits -ne '0 ahead, 1 behind') { throw 'Fetch did not refresh tracking state' }
        bicdop github --pull | Out-Null
        if (![IO.File]::Exists((Join-Path $local 'remote.txt'))) { throw 'Pull did not fast-forward the branch' }
        if (![IO.File]::Exists((Join-Path $local 'unstaged.txt'))) { throw 'Pull removed a local file' }
        [IO.File]::Delete((Join-Path $local 'tracked.txt'))
        bicdop github --stage 'tracked.txt'
        $selected = @(Invoke-GitFixture @('-C',$local,'diff','--cached','--name-only'))
        if ($selected.Count -ne 1 -or $selected[0] -ne 'tracked.txt') { throw 'Selective stage did not stage only the requested deletion' }
        [IO.File]::WriteAllText((Join-Path $local '.gitignore'), 'ignored.tmp')
        [IO.File]::WriteAllText((Join-Path $local 'ignored.tmp'), 'ignored')
        [IO.File]::WriteAllText((Join-Path $local 'remote.txt'), 'modified')
        $feedback = bicdop github --stage --all 6>&1 | Out-String
        if ($feedback -notmatch 'Staging all changes' -or $feedback -notmatch '4 path\(s\) ready to commit') {
            throw 'Stage all did not report progress and the staged count'
        }
        $staged = @(Invoke-GitFixture @('-C',$local,'diff','--cached','--name-only'))
        if ($staged -notcontains 'tracked.txt' -or $staged -notcontains 'unstaged.txt' -or
            $staged -notcontains 'remote.txt' -or $staged -contains 'ignored.tmp') {
            throw 'Stage all did not respect Git staging and ignore rules'
        }
        $details = bicdop github --status
        if ($details.Staged -notmatch 'D tracked\.txt' -or $details.Unstaged -ne 'None') {
            throw 'Status did not show staged and unstaged files separately'
        }
        bicdop github --unstage --all
        $details = bicdop github --status
        if ($details.Staged -ne 'None' -or $details.Unstaged -notmatch 'D tracked\.txt' -or
            $details.Unstaged -notmatch 'New unstaged\.txt') { throw 'Unstage all or status was incorrect' }
        if ((bicdop github --diff | Out-String) -notmatch 'modified') { throw 'Unstaged diff was missing' }
        bicdop github --publish | Out-Null
        $summary = Invoke-GitFixture @('-C',$remote,'log','-1','--format=%s','refs/heads/main')
        if ($summary -ne '+2 files -1 files 1 Modified') { throw "Wrong summary message: $summary" }
        $pushed = Invoke-GitFixture @('-C',$remote,'rev-parse','refs/heads/main')
        bicdop github --push --force | Out-Null
        if ((Invoke-GitFixture @('-C',$remote,'rev-parse','refs/heads/main')) -ne $pushed) {
            throw 'Shortcut created a commit without changes'
        }
        & (Get-Module Bicdop) {
            param($root)
            $script:GitTestWorkspace = $root
            function script:Read-BicdopRegistry {
                @{ active = 'test'; workspaces = @{ test = @{ name = 'Fixture'; path = $script:GitTestWorkspace } } }
            }
        } $root
        $workspaceStatus = @(bicdop github --workspace)
        if ($workspaceStatus.Count -ne 2 -or $workspaceStatus.Path -notcontains $local -or
            $workspaceStatus.Path -notcontains $peer -or @($workspaceStatus | Where-Object RemoteReachable).Count -ne 2) {
            throw 'Workspace status did not check both Git roots'
        }
        if ((Get-Location).Path -ne $local) { throw 'Workspace status changed the current folder' }
        $beforePeer = Invoke-GitFixture @('-C',$peer,'rev-parse','HEAD')
        bicdop github --workspace --publish | Out-Null
        if ((Invoke-GitFixture @('-C',$peer,'rev-parse','HEAD')) -ne $beforePeer) { throw 'Workspace publish changed a behind repo' }

        $peerRemote = Join-Path $root 'peer-origin.git'
        Invoke-GitFixture @('init','--bare','-b','main',$peerRemote) | Out-Null
        Invoke-GitFixture @('-C',$peer,'remote','set-url','origin',$peerRemote)
        Invoke-GitFixture @('-C',$peer,'push','--set-upstream','origin','main') | Out-Null
        $beforeLocal = Invoke-GitFixture @('-C',$local,'rev-parse','HEAD')
        [IO.File]::WriteAllText((Join-Path $local 'workspace local.txt'), 'local')
        [IO.File]::WriteAllText((Join-Path $peer 'workspace peer.txt'), 'peer')
        & (Get-Module Bicdop) {
            $script:ApproveWorkspacePublish = $false
            function script:Confirm-Bicdop { $script:ApproveWorkspacePublish }
        }
        bicdop github --workspace --publish | Out-Null
        if ((Invoke-GitFixture @('-C',$local,'rev-parse','HEAD')) -ne $beforeLocal -or
            (Invoke-GitFixture @('-C',$peer,'rev-parse','HEAD')) -ne $beforePeer -or
            @(Invoke-GitFixture @('-C',$local,'diff','--cached','--name-only')).Count -or
            @(Invoke-GitFixture @('-C',$peer,'diff','--cached','--name-only')).Count) {
            throw 'Declining changed repositories or staged files'
        }
        & (Get-Module Bicdop) { $script:ApproveWorkspacePublish = $true }
        bicdop github --workspace --publish | Out-Null
        if ((Invoke-GitFixture @('-C',$remote,'log','-1','--format=%s','main')) -ne '+1 files -0 files 0 Modified' -or
            (Invoke-GitFixture @('-C',$peerRemote,'log','-1','--format=%s','main')) -ne '+1 files -0 files 0 Modified' -or
            (Get-Location).Path -ne $local) {
            throw 'Workspace publish did not commit and push both eligible repositories'
        }
        'Bicdop Git commands, workspace status and workspace publish passed.'
    } finally {
        Pop-Location
    }
} finally {
    Remove-Module Bicdop
    $path = [IO.Path]::GetFullPath($root)
    if ($path.StartsWith($parent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar,
                         [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($path) -match '^bicdop-git-test-[0-9a-f-]{36}$') {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}
