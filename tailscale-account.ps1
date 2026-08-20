$ErrorActionPreference = 'Stop'

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\tailscale'
$currentFile = Join-Path $accountRoot 'current.json'

function Show-Usage {
    @(
        'Tailscale account profile helper (wireguard mesh vpn)',
        '',
        'Profiles are keyed by account email only and stored in:',
        '  %APPDATA%\mainframe\accounts\tailscale\<email>',
        '',
        'Tailscale is machine-level: one tailnet login per node at a time (this is',
        'tracked by the helper as the active profile). login <email> authenticates the',
        'machine into that email''s tailnet via browser oauth; run <email> -- <args>',
        'proxies to the tailscale cli; ssh <email> <user@host> [cmd] connects to a',
        'tailnet peer using the saved ssh key or tailscale ssh.',
        '',
        'Usage:',
        '  .\tailscale-account.ps1 login <email>',
        '  .\tailscale-account.ps1 use <email>',
        '  .\tailscale-account.ps1 current',
        '  .\tailscale-account.ps1 list',
        '  .\tailscale-account.ps1 status [email]',
        '  .\tailscale-account.ps1 status-all',
        '  .\tailscale-account.ps1 path [email]',
        '  .\tailscale-account.ps1 env [email]',
        '  .\tailscale-account.ps1 run [email] -- <tailscale args>',
        '  .\tailscale-account.ps1 up [email]',
        '  .\tailscale-account.ps1 down',
        '  .\tailscale-account.ps1 ssh [email] <user@host> [command...]',
        '  .\tailscale-account.ps1 ip [email]',
        '  .\tailscale-account.ps1 peers [email]',
        '  .\tailscale-account.ps1 nodes',
        '  .\tailscale-account.ps1 key-add <email> <tskey-...>',
        '  .\tailscale-account.ps1 key-remove [email]',
        '  .\tailscale-account.ps1 provision <email> <hostname>',
        '  .\tailscale-account.ps1 backup [email]',
        '  .\tailscale-account.ps1 restore [email]',
        '  .\tailscale-account.ps1 logout [email]',
        '',
        'Fleet workflow (10 pcs, mainframe backup/restore):',
        '  1. on one machine: key-add <email> <reusable-tskey-...>  (stored under',
        '     %APPDATA%\mainframe\accounts\tailscale\<email>\authkey.txt - travels',
        '     with the mainframe backup automatically)',
        '  2. on any machine: scoop install tailscale, then',
        '     provision <email> <hostname>  (joins the tailnet as its own node,',
        '     no browser, no per-machine key)',
        '  3. identity migration: backup <email> on source, restore <email> on',
        '     target + restart Tailscale service (target becomes that node)',
        '',
        'Examples:',
        '  .\tailscale-account.ps1 key-add <email> tskey-auth-xxxx',
        '  .\tailscale-account.ps1 provision <email> pc-02',
        '  .\tailscale-account.ps1 nodes',
        '  .\tailscale-account.ps1 backup <email>',
        '  .\tailscale-account.ps1 restore <email>',
        '  .\tailscale-account.ps1 login <email>',
        '  .\tailscale-account.ps1 status-all',
        '  .\tailscale-account.ps1 run -- status',
        '  .\tailscale-account.ps1 run -- ssh admin@desktop',
        '  .\tailscale-account.ps1 ssh <user>@<host> dir C:\tmp',
        '  .\tailscale-account.ps1 up',
        '  .\tailscale-account.ps1 down'
    ) -join [Environment]::NewLine | Write-Host
}

function Normalize-ProfileName {
    param([string]$Profile)

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        throw 'Email profile is required.'
    }

    $normalized = $Profile.Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw "Tailscale profile must be an account email, not a label or username: $Profile"
    }

    foreach ($char in [IO.Path]::GetInvalidFileNameChars()) {
        $invalidChar = [string]$char
        if ([string]::IsNullOrEmpty($invalidChar)) {
            continue
        }

        if ($normalized.IndexOf($invalidChar, [StringComparison]::Ordinal) -ge 0) {
            throw "Profile contains a character that cannot be used in a Windows folder name: $Profile"
        }
    }

    return $normalized
}

function Get-ProfilePath {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    return Join-Path $accountRoot $normalized
}

function Set-ActiveProfile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    [ordered]@{
        tool = 'tailscale'
        service = 'Tailscale'
        profile = $normalized
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $currentFile -Encoding UTF8
}

function Get-ActiveProfile {
    if (-not (Test-Path -LiteralPath $currentFile)) {
        return $null
    }

    $current = Get-Content -LiteralPath $currentFile -Raw | ConvertFrom-Json
    try {
        return Normalize-ProfileName -Profile ([string]$current.profile)
    } catch {
        return $null
    }
}

function Get-ProfileOrActive {
    param([AllowNull()][string]$Profile)

    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        return Normalize-ProfileName -Profile $Profile
    }

    $active = Get-ActiveProfile
    if (-not $active) {
        throw 'No email was provided and no active Tailscale email profile is set. Run .\tailscale-account.ps1 use <email> or login <email>.'
    }

    return Normalize-ProfileName -Profile $active
}

function Get-TailscaleState {
    $raw = & tailscale status --json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        return $null
    }

    try {
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-LoggedInEmail {
    $state = Get-TailscaleState
    if (-not $state -or -not $state.Self) {
        return $null
    }

    $selfUser = $state.User.($state.Self.UserID)
    if ($selfUser -and $selfUser.LoginName) {
        return [string]$selfUser.LoginName
    }

    if ($state.CurrentTailnet.Name -match '@') {
        return [string]$state.CurrentTailnet.Name
    }

    return $null
}

function Get-ProfileStatus {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $active = Get-ActiveProfile
    $state = Get-TailscaleState
    $loggedInEmail = Get-LoggedInEmail

    [pscustomobject]@{
        Profile = $normalized
        Exists = Test-Path -LiteralPath $profilePath
        IsActive = ($active -eq $normalized)
        LoggedIn = ($loggedInEmail -eq $normalized)
        BackendState = if ($state) { $state.BackendState } else { 'unknown' }
        Machine = if ($state -and $state.Self) { $state.Self.DNSName } else { $null }
        Tailnet = if ($state) { $state.CurrentTailnet.Name } else { $null }
        LoggedInEmail = $loggedInEmail
    }
}

function Get-AuthKeyPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'authkey.txt'
}

function Get-StateFileCandidates {
    return @(
        'C:\ProgramData\Tailscale\tailscaled.state',
        (Join-Path $env:LOCALAPPDATA 'Tailscale\tailscaled.state')
    )
}

function Test-AuthKeyValid {
    param([AllowNull()][string]$Key)

    return (-not [string]::IsNullOrWhiteSpace($Key)) -and ($Key -match '^tskey-')
}

function Convert-SecureStringToPlainText {
    param([Security.SecureString]$SecureString)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

switch ($args[0]) {
    { $_ -in @('-h', '-help', '--help', 'help') } {
        Show-Usage
    }
    'login' {
        $profile = Normalize-ProfileName -Profile $args[1]
        $profilePath = Get-ProfilePath -Profile $profile
        New-Item -ItemType Directory -Force -Path $profilePath | Out-Null

        Write-Host "Tailscale login for: $profile"
        Write-Host 'A browser window will open at login.tailscale.com. Sign in with the Google account for this profile.'
        Write-Host 'The node will join that account''s tailnet once authenticated.'
        & tailscale login

        $loggedInEmail = Get-LoggedInEmail
        if (-not $loggedInEmail) {
            Write-Host 'Login flow did not report a logged-in email yet. Check `tailscale status` and re-run login if needed.' -ForegroundColor Yellow
        } elseif ($loggedInEmail -ne $profile) {
            Write-Warning "Tailscale logged in as $loggedInEmail, which does not match the requested profile $profile."
        } else {
            Set-ActiveProfile -Profile $profile
            Write-Host "Tailscale profile ready and active: $profile"
        }
    }
    'use' {
        $profile = Get-ProfileOrActive -Profile $(if ($args.Count -ge 2) { $args[1] } else { $null })
        $profilePath = Get-ProfilePath -Profile $profile
        New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
        Set-ActiveProfile -Profile $profile
        Write-Host "Active Tailscale profile: $profile"
    }
    'current' {
        $active = Get-ActiveProfile
        if ($active) {
            Write-Host $active
        } else {
            Write-Host 'No active Tailscale profile set.' -ForegroundColor Yellow
        }
    }
    'list' {
        if (Test-Path -LiteralPath $accountRoot) {
            Get-ChildItem -LiteralPath $accountRoot -Directory | ForEach-Object {
                Get-ProfileStatus -Profile $_.Name
            } | Format-Table -AutoSize
        } else {
            Write-Host 'No Tailscale profiles yet.'
        }
    }
    'status' {
        $profile = Get-ProfileOrActive -Profile $(if ($args.Count -ge 2) { $args[1] } else { $null })
        Get-ProfileStatus -Profile $profile | Format-List
    }
    'status-all' {
        Write-Host 'Profiles:' -ForegroundColor Cyan
        if (Test-Path -LiteralPath $accountRoot) {
            $dirs = Get-ChildItem -LiteralPath $accountRoot -Directory
            if ($dirs.Count -eq 0) {
                Write-Host '  (none)'
            } else {
                $dirs | ForEach-Object {
                    Get-ProfileStatus -Profile $_.Name
                } | Format-Table -AutoSize
            }
        } else {
            Write-Host '  (none)'
        }

        Write-Host 'Tailscale node state:' -ForegroundColor Cyan
        $state = Get-TailscaleState
        if (-not $state) {
            Write-Host '  tailscale CLI not responding (service down?).' -ForegroundColor Yellow
        } else {
            Write-Host "  BackendState : $($state.BackendState)"
            if ($state.Self) {
                Write-Host "  Machine      : $($state.Self.DNSName)"
            }
            Write-Host "  Tailnet      : $($state.CurrentTailnet.Name)"
            Write-Host "  LoggedInAs   : $(Get-LoggedInEmail)"
            $peers = @($state.Peer | Where-Object { $_.Active })
            Write-Host "  ActivePeers  : $($peers.Count)"
        }
    }
    'path' {
        $profile = Get-ProfileOrActive -Profile $(if ($args.Count -ge 2) { $args[1] } else { $null })
        Write-Host (Get-ProfilePath -Profile $profile)
    }
    'env' {
        $profile = Get-ProfileOrActive -Profile $(if ($args.Count -ge 2) { $args[1] } else { $null })
        Write-Host "MAINFRAME_TAILSCALE_EMAIL=$profile"
        Write-Host "MAINFRAME_TAILSCALE_DIR=$(Get-ProfilePath -Profile $profile)"
    }
    'run' {
        $tsArgs = @($args[1..($args.Count - 1)])
        if ($tsArgs.Count -gt 0 -and $tsArgs[0] -eq '--') {
            $tsArgs = @($tsArgs[1..($tsArgs.Count - 1)])
        }
        if ($tsArgs.Count -eq 0) {
            throw 'run requires tailscale args: run [<email> --] <tailscale args>'
        }
        & tailscale @tsArgs
        exit $LASTEXITCODE
    }
    'up' {
        & tailscale up
        exit $LASTEXITCODE
    }
    'down' {
        & tailscale down
        exit $LASTEXITCODE
    }
    'ssh' {
        $profile = Get-ProfileOrActive -Profile $(if ($args.Count -ge 2 -and $args[1] -match '@') { $args[1] } else { $null })
        $target = if ($args.Count -ge 2 -and $args[1] -match '@') { $args[2] } else { $args[1] }
        $cmd = if ($args.Count -ge 3 -and $args[1] -match '@') { @($args[3..($args.Count - 1)]) } else { @($args[2..($args.Count - 1)]) }

        if (-not $target) {
            throw 'ssh requires a target: ssh <email> <user@host> [command...]'
        }

        $state = Get-TailscaleState
        if (-not $state -or -not $state.Self) {
            throw 'Tailscale is not up. Run .\tailscale-account.ps1 up first.'
        }

        $sshKeyName = $env:TAILSCALE_SSH_KEY_NAME
        if (-not $sshKeyName) { $sshKeyName = 'id_ed25519' }
        $sshKey = Join-Path $env:USERPROFILE ".ssh\$sshKeyName"

        $ran = $false
        if (Test-Path -LiteralPath $sshKey) {
            $hostname = ($target -split '@')[-1].TrimEnd('.')
            $ip = (& tailscale status --json | ConvertFrom-Json).Peer.PSObject.Properties.Value | `
                Where-Object { $_.HostName -eq $hostname -or $_.DNSName -like "$hostname*" } | `
                Select-Object -First 1 -ExpandProperty TailscaleIPs | Select-Object -First 1
            if (-not $ip) { $ip = $hostname }
            $user = ($target -split '@')[0]
            if ($cmd.Count -eq 0) {
                & ssh -i $sshKey -o StrictHostKeyChecking=accept-new "$user@$ip"
            } else {
                & ssh -i $sshKey -o StrictHostKeyChecking=accept-new "$user@$ip" ($cmd -join ' ')
            }
            $ran = $true
        }

        if (-not $ran) {
            if ($cmd.Count -eq 0) {
                & tailscale ssh $target
            } else {
                & tailscale ssh $target ($cmd -join ' ')
            }
        }
        exit $LASTEXITCODE
    }
    'ip' {
        & tailscale ip -4
        exit $LASTEXITCODE
    }
    'peers' {
        & tailscale status
        exit $LASTEXITCODE
    }
    'key-add' {
        $profile = Get-ProfileOrActive -Profile $(if ($args.Count -ge 2 -and $args[1] -match '@') { $args[1] } else { $null })
        $key = $null
        if ($args.Count -ge 2 -and $args[1] -match '@') {
            $key = if ($args.Count -ge 3) { $args[2] } else { $null }
        } else {
            $key = if ($args.Count -ge 2) { $args[1] } else { $null }
        }
        if (-not (Test-AuthKeyValid -Key $key)) {
            if ([Console]::IsInputRedirected) {
                throw 'An auth key (tskey-...) is required as an argument when stdin is redirected.'
            }
            $key = Read-Host -AsSecureString 'Paste the reusable Tailscale auth key'
            $key = Convert-SecureStringToPlainText -SecureString $key
        }
        if (-not (Test-AuthKeyValid -Key $key)) {
            throw 'Invalid auth key: expected a tskey-... value.'
        }
        $profilePath = Get-ProfilePath -Profile $profile
        New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
        Set-Content -LiteralPath (Get-AuthKeyPath -ProfilePath $profilePath) -Value $key -Encoding ASCII -NoNewline
        Write-Host "Auth key stored for $profile (last 4: ...$($key.Substring([Math]::Max(0, $key.Length - 4))))"
    }
    'key-remove' {
        $profile = Get-ProfileOrActive -Profile $(if ($args.Count -ge 2) { $args[1] } else { $null })
        $keyPath = Get-AuthKeyPath -ProfilePath (Get-ProfilePath -Profile $profile)
        if (Test-Path -LiteralPath $keyPath) {
            Remove-Item -LiteralPath $keyPath -Force
            Write-Host "Auth key removed for $profile"
        } else {
            Write-Host "No auth key stored for $profile"
        }
    }
    'provision' {
        if ($args.Count -lt 2) {
            throw 'provision requires a hostname: provision <email> <hostname>'
        }
        $profile = Normalize-ProfileName -Profile $args[1]
        $hostname = $args[2]
        $profilePath = Get-ProfilePath -Profile $profile
        $keyPath = Get-AuthKeyPath -ProfilePath $profilePath
        if (-not (Test-Path -LiteralPath $keyPath)) {
            throw "No auth key stored for $profile. Run key-add <email> <tskey-...> first."
        }
        $key = (Get-Content -LiteralPath $keyPath -Raw).Trim()
        if (-not (Test-AuthKeyValid -Key $key)) {
            throw "Stored key for $profile is not a valid tskey-... value. Re-run key-add."
        }
        Write-Host "Joining this machine as $hostname into the tailnet of $profile..."
        & tailscale up --authkey=$key --unattended --hostname=$hostname --timeout=40s
        if ($LASTEXITCODE -ne 0) {
            throw "tailscale up failed with exit $LASTEXITCODE. Check firewall (Plucky/Windscribe allow tailscaled.exe egress)."
        }
        $loggedInEmail = Get-LoggedInEmail
        if ($loggedInEmail -ne $profile) {
            Write-Warning "Tailscale reports login as $loggedInEmail (expected $profile)."
        }
        Set-ActiveProfile -Profile $profile
        & tailscale set --auto-update
        Write-Host "Provisioned: $hostname -> $loggedInEmail tailnet, active profile set."
        & tailscale status
    }
    'backup' {
        $profile = Get-ProfileOrActive -Profile $(if ($args.Count -ge 2) { $args[1] } else { $null })
        $profilePath = Get-ProfilePath -Profile $profile
        New-Item -ItemType Directory -Force -Path (Join-Path $profilePath 'state') | Out-Null
        $copied = @()
        foreach ($candidate in Get-StateFileCandidates) {
            if (Test-Path -LiteralPath $candidate) {
                Copy-Item -LiteralPath $candidate -Destination (Join-Path $profilePath 'state\tailscaled.state') -Force
                $copied += $candidate
            }
        }
        if ($copied.Count -eq 0) {
            Write-Host 'No tailscaled.state found on this machine (not logged in yet?) - nothing to back up.'
        } else {
            Write-Host "Backed up state to $profilePath\state\tailscaled.state from: $($copied -join ', ')"
        }
    }
    'restore' {
        $profile = Get-ProfileOrActive -Profile $(if ($args.Count -ge 2) { $args[1] } else { $null })
        $profilePath = Get-ProfilePath -Profile $profile
        $statePath = Join-Path $profilePath 'state\tailscaled.state'
        if (-not (Test-Path -LiteralPath $statePath)) {
            throw "No backed-up state for $profile. Run backup <email> on the source machine first."
        }
        foreach ($candidate in Get-StateFileCandidates) {
            if (Test-Path -LiteralPath $candidate) {
                Write-Warning "A live tailscaled.state already exists at $candidate - restore will overwrite it. Stop the Tailscale service first if it is running."
            }
        }
        $dest = 'C:\ProgramData\Tailscale\tailscaled.state'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $statePath -Destination $dest -Force
        Write-Host "Restored state to $dest. Restart the Tailscale service to adopt this node identity."
    }
    'nodes' {
        $state = Get-TailscaleState
        if (-not $state -or -not $state.Self) {
            throw 'Tailscale is not up. Run up first.'
        }
        Write-Host "Tailnet: $($state.CurrentTailnet.Name)"
        Write-Host ('{0,-16} {1,-24} {2,-10} {3}' -f 'IP', 'Name', 'OS', 'Online')
        $self = $state.Self
        Write-Host ('{0,-16} {1,-24} {2,-10} {3}' -f ($self.TailscaleIPs -join ','), $self.DNSName, $self.OS, $self.Online)
        $peers = @($state.Peer.PSObject.Properties.Value)
        if ($peers.Count -eq 0) { $peers = @($state.Peer) }
        foreach ($peer in $peers | Sort-Object DNSName) {
            Write-Host ('{0,-16} {1,-24} {2,-10} {3}' -f ($peer.TailscaleIPs -join ','), $peer.DNSName, $peer.OS, $peer.Online)
        }
    }
    'logout' {
        $profile = Get-ProfileOrActive -Profile $(if ($args.Count -ge 2) { $args[1] } else { $null })
        & tailscale logout
        if (Test-Path -LiteralPath $currentFile) {
            $active = Get-ActiveProfile
            if ($active -eq $profile) {
                Remove-Item -LiteralPath $currentFile -Force
                Write-Host 'Active Tailscale profile cleared.'
            }
        }
        Write-Host "Tailscale logged out of: $profile"
    }
    default {
        Show-Usage
    }
}
