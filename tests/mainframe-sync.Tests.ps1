# No Pester dependency. This file has to pass under windows powershell 5.1 AND
# pwsh 7 - the whole point is that the approval flow works in both.
#
# Real git in temp dirs, no network: the "origin" is a local bare repo, so
# every scenario runs offline on any machine with git on PATH. If git is
# missing the test SKIPS loudly (exit 0) instead of failing - a machine
# without git cannot sync, and the sync itself says so the same way.
#
# What it pins: Sync-MainframeCheckout brings a checkout onto its upstream
# tip by itself - fast-forward when it can, stash + fetch + reset + pop
# when history diverged (a rewrite) - and uncommitted work plus untracked
# files always survive. A failed stash pop keeps the work in the stash and
# says so loudly. A checkout that cannot sync (not a repo, no origin, no
# upstream) warns loudly and the caller proceeds with local code.
$ErrorActionPreference = 'Stop'
$syncModule = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\windows\mainframe-sync.psm1'))

$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "FAIL: $Message`n  expected: $Expected`n  actual:   $Actual" }
}

# 1. the module parses
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($syncModule, [ref]$null, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'mainframe-sync.psm1 parses'

$source = Get-Content -LiteralPath $syncModule -Raw

# 2. the contract, in source: untracked files are never touched, a failed
#    pop never drops the stash, and the function never throws.
Assert-True ($source -notmatch 'stash push -u|stash push --include-untracked') 'the stash never takes untracked files'
Assert-True ($source -notmatch 'git clean') 'the sync never cleans untracked files'
Assert-True ($source -notmatch 'stash drop') 'the sync never drops a stash'
Assert-True ($source -match 'never throws') 'the never-throws contract is documented'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host 'mainframe-sync checks: SKIPPED (git not found on PATH)'
    return
}

Import-Module $syncModule -Force -DisableNameChecking

function Invoke-TestGit {
    param([string]$Dir, [string[]]$Arguments)
    $out = & git -C $Dir @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed in $Dir : $($out -join ' ')" }
    return ($out -join "`n")
}

function New-TestRepo {
    param([string]$Dir)
    $null = New-Item -ItemType Directory -Force -Path $Dir
    $null = & git init -b main $Dir 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git init failed in $Dir" }
    Invoke-TestGit -Dir $Dir -Arguments @('config', 'user.email', 'test@example.invalid') | Out-Null
    Invoke-TestGit -Dir $Dir -Arguments @('config', 'user.name', 'test') | Out-Null
    Invoke-TestGit -Dir $Dir -Arguments @('config', 'commit.gpgsign', 'false') | Out-Null
}

function Add-TestCommit {
    param([string]$Dir, [string]$File, [string]$Content, [string]$Message)
    Set-Content -LiteralPath (Join-Path $Dir $File) -Value $Content -Encoding UTF8 -NoNewline
    Invoke-TestGit -Dir $Dir -Arguments @('add', $File) | Out-Null
    Invoke-TestGit -Dir $Dir -Arguments @('commit', '-m', $Message) | Out-Null
}

function Invoke-WithStderr {
    param([scriptblock]$Block)
    $sb = New-Object Text.StringBuilder
    $writer = [IO.StringWriter]::new($sb)
    $oldError = [Console]::Error
    [Console]::SetError($writer)
    try {
        $result = & $Block
    } finally {
        $writer.Flush()
        [Console]::SetError($oldError)
    }
    return @{ Result = $result; Stderr = $sb.ToString() }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('mf-sync-' + [Guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Force -Path $tempRoot
    $origin = Join-Path $tempRoot 'origin.git'
    $null = & git init --bare -b main $origin 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'git init --bare failed' }
    $seed = Join-Path $tempRoot 'seed'
    New-TestRepo -Dir $seed
    # commit 1 holds the files the tests modify (shared prefix - a rewrite
    # of the tip never drops them); commit 2 is the tip the rewrite tests
    # replace (HEAD~1 must exist for the reset).
    Set-Content -LiteralPath (Join-Path $seed 'shared.txt') -Value "line one`nline two`n" -Encoding UTF8 -NoNewline
    Set-Content -LiteralPath (Join-Path $seed 'wip.txt') -Value "wip baseline`n" -Encoding UTF8 -NoNewline
    Invoke-TestGit -Dir $seed -Arguments @('add', 'shared.txt', 'wip.txt') | Out-Null
    Invoke-TestGit -Dir $seed -Arguments @('commit', '-m', 'seed commit') | Out-Null
    Add-TestCommit -Dir $seed -File 'other.txt' -Content "other`n" -Message 'second seed commit'
    Invoke-TestGit -Dir $seed -Arguments @('remote', 'add', 'origin', $origin) | Out-Null
    Invoke-TestGit -Dir $seed -Arguments @('push', '-u', 'origin', 'main') | Out-Null

    # 3. fast-forward: origin advances, work is behind and clean.
    $work = Join-Path $tempRoot 'work-ff'
    $null = & git clone -q $origin $work 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'git clone failed' }
    Invoke-TestGit -Dir $work -Arguments @('config', 'user.email', 'test@example.invalid') | Out-Null
    Invoke-TestGit -Dir $work -Arguments @('config', 'user.name', 'test') | Out-Null
    $pusher = Join-Path $tempRoot 'pusher-ff'
    $null = & git clone -q $origin $pusher 2>&1
    Invoke-TestGit -Dir $pusher -Arguments @('config', 'user.email', 'test@example.invalid') | Out-Null
    Invoke-TestGit -Dir $pusher -Arguments @('config', 'user.name', 'test') | Out-Null
    Add-TestCommit -Dir $pusher -File 'shared.txt' -Content "line one`nline two`nline three`n" -Message 'origin advances'
    Invoke-TestGit -Dir $pusher -Arguments @('push', 'origin', 'main') | Out-Null
    $before = (Invoke-TestGit -Dir $work -Arguments @('rev-parse', 'HEAD')).Trim()
    $after = (Invoke-TestGit -Dir $pusher -Arguments @('rev-parse', 'HEAD')).Trim()
    Assert-True ($before -ne $after) 'the work clone is behind before the sync'
    $run = Invoke-WithStderr { Sync-MainframeCheckout -Checkout $work }
    Assert-True ($run.Result -eq $true) 'fast-forward sync returns true'
    Assert-Equal $after (Invoke-TestGit -Dir $work -Arguments @('rev-parse', 'HEAD')).Trim() 'the work clone fast-forwarded to the origin tip'

    # 4. divergent history + uncommitted work: the rewrite path. the work
    #    clone holds an uncommitted change to a tracked file plus an
    #    untracked file; the origin rewrites its tip. after the sync the
    #    clone is on the new tip and both files survive byte-identical.
    $work2 = Join-Path $tempRoot 'work-divergent'
    $null = & git clone -q $origin $work2 2>&1
    Invoke-TestGit -Dir $work2 -Arguments @('config', 'user.email', 'test@example.invalid') | Out-Null
    Invoke-TestGit -Dir $work2 -Arguments @('config', 'user.name', 'test') | Out-Null
    $wipModified = "wip baseline`nthird line, uncommitted`n"
    Set-Content -LiteralPath (Join-Path $work2 'wip.txt') -Value $wipModified -Encoding UTF8 -NoNewline
    $untrackedContent = "untracked, must survive`n"
    Set-Content -LiteralPath (Join-Path $work2 'notes.txt') -Value $untrackedContent -Encoding UTF8 -NoNewline
    # the origin rewrites its tip (a history rewrite, like the blob scrub):
    Invoke-TestGit -Dir $pusher -Arguments @('reset', '--hard', 'HEAD~1') | Out-Null
    Add-TestCommit -Dir $pusher -File 'shared.txt' -Content "line one rewritten`nline two`n" -Message 'rewritten tip'
    Invoke-TestGit -Dir $pusher -Arguments @('push', '--force', 'origin', 'main') | Out-Null
    $newTip = (Invoke-TestGit -Dir $pusher -Arguments @('rev-parse', 'HEAD')).Trim()
    $run = Invoke-WithStderr { Sync-MainframeCheckout -Checkout $work2 }
    Assert-True ($run.Result -eq $true) 'divergent sync returns true'
    Assert-Equal $newTip (Invoke-TestGit -Dir $work2 -Arguments @('rev-parse', 'HEAD')).Trim() 'the divergent clone reset to the new tip'
    Assert-Equal $wipModified (Get-Content -LiteralPath (Join-Path $work2 'wip.txt') -Raw) 'the uncommitted change survived byte-identical'
    Assert-Equal $untrackedContent (Get-Content -LiteralPath (Join-Path $work2 'notes.txt') -Raw) 'the untracked file survived byte-identical'
    Assert-True ($run.Stderr -match 'reset to origin/main') 'the reset is logged loudly'
    $stashList = Invoke-TestGit -Dir $work2 -Arguments @('stash', 'list')
    Assert-True (-not $stashList.Trim()) 'a clean pop leaves no stash behind'

    # 5. pop conflict: the WIP and the rewrite touch the same lines. the
    #    reset still lands, the pop conflicts, the work stays in the stash
    #    and the warning says so loudly.
    $work3 = Join-Path $tempRoot 'work-conflict'
    $null = & git clone -q $origin $work3 2>&1
    Invoke-TestGit -Dir $work3 -Arguments @('config', 'user.email', 'test@example.invalid') | Out-Null
    Invoke-TestGit -Dir $work3 -Arguments @('config', 'user.name', 'test') | Out-Null
    Set-Content -LiteralPath (Join-Path $work3 'shared.txt') -Value "MY uncommitted line one`nline two`n" -Encoding UTF8 -NoNewline
    Invoke-TestGit -Dir $pusher -Arguments @('reset', '--hard', 'HEAD~1') | Out-Null
    Add-TestCommit -Dir $pusher -File 'shared.txt' -Content "ORIGIN rewritten line one`nline two`n" -Message 'rewrite touching the same lines'
    Invoke-TestGit -Dir $pusher -Arguments @('push', '--force', 'origin', 'main') | Out-Null
    $run = Invoke-WithStderr { Sync-MainframeCheckout -Checkout $work3 }
    Assert-True ($run.Result -eq $false) 'a conflicted pop returns false'
    Assert-True ($run.Stderr -match 'STILL in the stash') 'a conflicted pop warns loudly that the work is in the stash'
    $stashList = Invoke-TestGit -Dir $work3 -Arguments @('stash', 'list')
    Assert-True ($stashList.Trim()) 'a conflicted pop leaves the stash entry in place'

    # 6. not a repo: clean skip, loud warning, false.
    $plain = Join-Path $tempRoot 'plain-dir'
    $null = New-Item -ItemType Directory -Force -Path $plain
    $run = Invoke-WithStderr { Sync-MainframeCheckout -Checkout $plain }
    Assert-True ($run.Result -eq $false) 'a non-repo returns false'
    Assert-True ($run.Stderr -match 'not a git checkout') 'a non-repo warns loudly'

    # 7. no origin: clean skip, loud warning, false.
    $noOrigin = Join-Path $tempRoot 'no-origin'
    New-TestRepo -Dir $noOrigin
    Add-TestCommit -Dir $noOrigin -File 'a.txt' -Content 'x' -Message 'one commit'
    $run = Invoke-WithStderr { Sync-MainframeCheckout -Checkout $noOrigin }
    Assert-True ($run.Result -eq $false) 'a repo with no origin returns false'
    Assert-True ($run.Stderr -match 'no origin remote') 'a repo with no origin warns loudly'

    # 8. no upstream: clean skip, loud warning, false.
    $noUpstream = Join-Path $tempRoot 'no-upstream'
    $null = & git clone -q $origin $noUpstream 2>&1
    Invoke-TestGit -Dir $noUpstream -Arguments @('checkout', '-b', 'orphan-branch') | Out-Null
    $run = Invoke-WithStderr { Sync-MainframeCheckout -Checkout $noUpstream }
    Assert-True ($run.Result -eq $false) 'a branch with no upstream returns false'
    Assert-True ($run.Stderr -match 'no upstream branch') 'a branch with no upstream warns loudly'
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "mainframe-sync checks: $script:checks passed"
