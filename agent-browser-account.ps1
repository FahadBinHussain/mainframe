$ErrorActionPreference = 'Stop'

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\agent-browser'
$currentFile = Join-Path $accountRoot 'current.json'

function Show-Usage {
    @'
agent-browser account profile helper

Profiles are keyed by email and stored in:
  %APPDATA%\mainframe\accounts\agent-browser\<email>

Uses agent-browser (Chrome via CDP) with auto-save/restore for session
persistence. Extensions are loaded from ~/.agent-browser/config.json by default,
or passed via -Extension.

Every `run`/`login`/`exec` spawn first mirrors the real Edge User Data dir
into the mainframe profile dir via the Sync-EdgeProfileToMainframe helper,
then launches Edge (msedge.exe) against that throwaway copy. Real Edge is
NEVER modified; CDP-induced extension pruning stays in the copy and is
replaced by a fresh copy on the next spawn.

The mirror is VSS-only (Volume Shadow Copy of C:\) and silently fails
without an elevated shell and working VSS. There is no kill-Edge fallback;
the spawn aborts on VSS failure rather than copying an inconsistent profile.

Usage:
  .\agent-browser-account.ps1 login <email> [-Url <url>] [-Extension <path>...] [-Headless]
  .\agent-browser-account.ps1 run [email] [-Url <url>] [-Extension <path>...] [-Headless] [agent-browser args...]
  .\agent-browser-account.ps1 exec [email] <agent-browser command> [args...]
  .\agent-browser-account.ps1 use <email>
  .\agent-browser-account.ps1 current
  .\agent-browser-account.ps1 list
  .\agent-browser-account.ps1 status [email]
  .\agent-browser-account.ps1 status-all
  .\agent-browser-account.ps1 path [email]
  .\agent-browser-account.ps1 env [email]
  .\agent-browser-account.ps1 close [email]
  .\agent-browser-account.ps1 logout [email]
  .\agent-browser-account.ps1 cookies save <email> [-Domains facebook.com,messenger.com]
  .\agent-browser-account.ps1 cookies run <email> [-Url <url>] [-Headless]
  .\agent-browser-account.ps1 cookies verify <email> [-Url <url>]
  .\agent-browser-account.ps1 cookies status <email>

Commands:
  login    Open a headed browser session for manual login. State is auto-saved.
  run      Open a browser session. With no -Url, defaults to https://example.com
           (do NOT pass about:blank — that triggers agent-browser's "relaunched browser" bug).
           The mainframe profile is refreshed from real Edge before spawn.
           Extra args pass through.
  exec     Run any agent-browser command against the refreshed profile. Example:
                    exec eval "document.title"
                    exec snapshot -i
                    exec get url
  use      Set the active profile.
  current  Print the active profile email.
  list     List all profiles.
  status   Show details for one (or all) profile.
  status-all  Show table of all profiles.
  path     Print the profile directory path.
  env      Print env vars for the profile.
  close    Close the active or named session.
  logout   Delete the profile and saved state.

  cookies save    LIGHTWEIGHT MODE: sync profile from real Edge once, export ONLY the
                  cookies for the given domains to a small JSON file, close. Reuses the
                  VSS sync (needs an elevated shell) but stores only a few KB per email.
  cookies run     LIGHTWEIGHT MODE: spawn a fresh throwaway minimal profile with NO VSS
                  sync (works non-elevated), inject the saved domain cookies, open the
                  target URL. Headed by default; -Headless for scripted use.
  cookies verify  LIGHTWEIGHT MODE: like run but headless — navigates and prints URL +
                  title + verdict (logged-in vs login page) WITHOUT staying open.
  cookies status  Print cookie export info: path, size, count, domains covered, and the
                  earliest expiry among session cookies (re-login when near).

Options:
  -Url <url>          Target URL. Omit to default to https://example.com (avoid about:blank).
  -Extension <path>   Extension path to load (repeatable; omit to use config.json)
  -Headless           Run without visible window
  -Domains <csv>      Comma-separated domain list for cookies save (default facebook.com,messenger.com)
  -FromSession        cookies save: capture from the RUNNING agent-browser session instead
                      of re-syncing real Edge (use after logging in inside a `login` window)

Examples:
  .\agent-browser-account.ps1 login user@example.com -Url https://web.telegram.org
  .\agent-browser-account.ps1 run                              # vanilla — about:blank
  .\agent-browser-account.ps1 run -Url https://discord.com
  .\agent-browser-account.ps1 use user@example.com
  .\agent-browser-account.ps1 status-all
  .\agent-browser-account.ps1 cookies save user@example.com
  .\agent-browser-account.ps1 cookies run user@example.com -Url https://www.messenger.com
  .\agent-browser-account.ps1 cookies verify user@example.com -Url https://www.messenger.com
'@ | Write-Host
}

function Normalize-Email {
    param([string]$Email)

    if ([string]::IsNullOrWhiteSpace($Email)) {
        throw 'Email is required.'
    }

    $normalized = $Email.Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw "agent-browser profile must be an account email, not a username, project, or label: $Email"
    }

    foreach ($char in [IO.Path]::GetInvalidFileNameChars()) {
        $invalidChar = [string]$char
        if ([string]::IsNullOrEmpty($invalidChar)) {
            continue
        }

        if ($normalized.IndexOf($invalidChar, [StringComparison]::Ordinal) -ge 0) {
            throw "Email contains a character that cannot be used in a Windows folder name: $Email"
        }
    }

    return $normalized
}

function Test-LooksLikeEmail {
    param([AllowNull()][string]$Value)

    return (-not [string]::IsNullOrWhiteSpace($Value)) -and ($Value -match '^[^\s@]+@[^\s@]+\.[^\s@]+$')
}

function Get-ProfilePath {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    return Join-Path $accountRoot $normalized
}

function Ensure-ProfileDirectory {
    param([string]$ProfilePath)

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
}

function Set-ActiveEmail {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    [ordered]@{
        tool = 'agent-browser'
        email = $normalized
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $currentFile -Encoding UTF8
}

function Get-ActiveEmail {
    if (-not (Test-Path -LiteralPath $currentFile)) {
        return $null
    }

    try {
        $current = Get-Content -LiteralPath $currentFile -Raw | ConvertFrom-Json
        return Normalize-Email -Email ([string]$current.email)
    } catch {
        return $null
    }
}

function Get-EmailOrActive {
    param([AllowNull()][string]$Email)

    if (-not [string]::IsNullOrWhiteSpace($Email)) {
        return Normalize-Email -Email $Email
    }

    $active = Get-ActiveEmail
    if (-not $active) {
        throw 'No email was provided and no active agent-browser profile is set. Run .\agent-browser-account.ps1 use <email>.'
    }

    return $active
}

function Get-ProfileDirectories {
    if (-not (Test-Path -LiteralPath $accountRoot)) {
        return @()
    }

    Get-ChildItem -LiteralPath $accountRoot -Directory -Force |
        Where-Object { Test-LooksLikeEmail -Value $_.Name } |
        Sort-Object Name
}

function Sync-EdgeProfileToMainframe {
    # Copy the user's real Edge User Data dir into a mainframe agent-browser profile dir,
    # using the same exclude list as backup.ps1 (caches, telemetry, edge component dirs,
    # indexeddb blobs, history, db temps). Gives a fresh throwaway copy per session so
    # CDP-induced extension pruning stays in the copy, never touching the real Edge profile.
    # mainframe-profile.json (extensions list) and session state dirs are preserved across
    # the /MIR robocopy.
    param(
        [Parameter(Mandatory)] [string]$Email
    )

    $edgeUserData = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
    if (-not (Test-Path -LiteralPath $edgeUserData -PathType Container)) {
        throw "Edge User Data not found: $edgeUserData"
    }
    $profilePath = Get-ProfilePath -Email $Email

    # close the agent-browser daemon FIRST, before we wipe the user-data-dir it's
    # holding open. if we wipe while the daemon is alive, the next `open` sees the
    # daemon's profile is gone, prints "relaunched browser", and leaves inconsistent
    # state that breaks the run AFTER that. closing here avoids the relaunch entirely.
    try {
        $agentBrowserExe = Resolve-AgentBrowserCommand
        & $agentBrowserExe close --all 2>$null | Out-Null
    } catch {}

    # === VSS snapshot path: copy Edge User Data from a Volume Shadow Copy so we
    # DO NOT need to close real Edge and we DO NOT skip any locked files (Local State,
    # Cookies, Preferences, Session Storage, etc.). this is the only way to get a
    # 100% byte-consistent copy while Edge is alive — robocopy alone can't read files
    # that Edge holds with exclusive write handles (ERROR 32 / sharing violation).
    #
    # VSS is the only supported path. there is NO fallback — if the shadow cannot be
    # created or mounted, the sync aborts. closing the user's real Edge as a fallback
    # is intentionally removed; running with a non-VSS robocopy silently skips locked
    # files (Cookies, Local State, Preferences, Session Storage) and produces a
    # corrupt profile.
    $shadowDevice = $null
    $vssLink = $null
    try {
        $mc = New-Object System.Management.ManagementClass(
            [System.Management.ManagementScope]::new('\\.\root\cimv2'),
            [System.Management.ManagementPath]::new('Win32_ShadowCopy'),
            $null)
        $inParams = $mc.GetMethodParameters('Create')
        $inParams['Volume']  = 'C:\'
        $inParams['Context'] = 'ClientAccessible'
        $outParams = $mc.InvokeMethod('Create', $inParams, $null)
        if ($outParams.ReturnValue -ne 0) {
            throw "Win32_ShadowCopy.Create returned error code $($outParams.ReturnValue) (7=not supported, 8=volume not found, 12=max snapshots exceeded) — usually means this shell is not elevated"
        }
        $shadowId = $outParams.ShadowID
        $shadow = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.Id -eq $shadowId } | Select-Object -First 1
        if (-not $shadow) { throw "shadow created (ID=$shadowId) but not returned by Win32_ShadowCopy query" }
        $shadowDevice = $shadow.DeviceObject
        Write-Host "[edge-cdp-sync] VSS shadow created: $shadowDevice" -ForegroundColor Cyan
    } catch {
        throw "[edge-cdp-sync] VSS snapshot unavailable ($($_.Exception.Message)) — needs admin + VSS enabled (ClientAccessible shadow copy). no fallback."
    }

    # device path is \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopyN
    # robocopy can NOT read \\?\GLOBALROOT\... device paths directly — those are
    # kernel-object namespace paths only. the workaround that works on every Win10+:
    # create a directory symlink with `cmd /c mklink /d` pointing at the shadow root
    # (the trailing backslash on the target is what makes mklink accept it), then use
    # that normal Win32 symlink path as the robocopy source.
    $vssLink = Join-Path $env:TEMP "edge-cdp-vss-$([Guid]::NewGuid().ToString('N'))"
    try {
        $mkOut = cmd /c mklink /d "$vssLink" "$shadowDevice\" 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $vssLink -PathType Container)) {
            throw "mklink /d failed (exit=$LASTEXITCODE, output=$mkOut)"
        }
        $pathAfterDrive = $edgeUserData -replace '^[A-Za-z]:\\',''
        $edgeUserDataShadow = Join-Path $vssLink $pathAfterDrive
        if (-not (Test-Path -LiteralPath $edgeUserDataShadow -PathType Container)) {
            throw "VSS symlink created but couldn't resolve $edgeUserDataShadow"
        }
        $edgeUserData = $edgeUserDataShadow
        Write-Host "[edge-cdp-sync] using VSS shadow: $shadowDevice (real Edge left running)" -ForegroundColor Cyan
    } catch {
        # drop the shadow before aborting so we don't leak it
        try {
            $shadows = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.DeviceObject -eq $shadowDevice }
            $shadows | Remove-CimInstance -ErrorAction SilentlyContinue
        } catch {}
        if (Test-Path -LiteralPath $vssLink) { Remove-Item -LiteralPath $vssLink -Force -Recurse -ErrorAction SilentlyContinue }
        throw "[edge-cdp-sync] VSS shadow mounted but mklink/resolution failed: $($_.Exception.Message). no fallback."
    }

    # stage mainframe-profile.json + session state dirs to temp BEFORE the wipe
    $preservedFiles = @('mainframe-profile.json')
    $preservedDirs  = @('mainframe-sessions', 'sessions')
    $stagingDir = Join-Path $env:TEMP "edge-cdp-sync-staging-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
    foreach ($f in $preservedFiles) {
        $src = Join-Path $profilePath $f
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $stagingDir $f) -Force }
    }
    foreach ($d in $preservedDirs) {
        $src = Join-Path $profilePath $d
        if (Test-Path -LiteralPath $src -PathType Container) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $stagingDir $d) -Recurse -Force
        }
    }

    # DO NOT wipe the destination — let robocopy /MIR delta-sync against the existing
    # copy so subsequent syncs only re-copy changed files (Cookies, Local State,
    # Preferences, etc.) instead of re-copying ~370 MB every time. /MIR already
    # deletes dest files that aren't in source (pruned extensions, session leftover
    # state), so the wipe was redundant and only defeated the delta optimization.
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null

    # robocopy exclude list — mirrors backup.ps1's Edge profile workflow
    $excludeDirs = @(
        'Cache', 'Code Cache', 'GPUCache', 'Service Worker',
        'DawnGraphiteCache', 'DawnWebGPUCache', 'GrShaderCache', 'ShaderCache', 'GraphiteDawnCache',
        'blob_storage', 'Crashpad', 'component_crx_cache', 'ProvenanceData', 'Subresource Filter',
        'BrowserMetrics', 'Safe Browsing', 'Shared Dictionary', 'File System', 'logs', '*.blob',
        'Edge Entity Extraction', 'Edge Shopping', 'Edge Wallet', 'EdgeCoupons',
        'EdgeLanguageDetectionModel', 'Edge Sidebar', 'EdgeTravel', 'EdgeCDSScheduler',
        'EdgePushNotificationClient', 'EdgeDrop', 'EdgeCollections', 'EdgeTrackingPrevention',
        'EdgeFavoritesBackup',
        'https_photos.google.com_0.indexeddb.leveldb',
        'https_www.messenger.com_0.indexeddb.leveldb',
        'https_www.facebook.com_0.indexeddb.leveldb',
        'https_www.reddit.com_0.indexeddb.leveldb',
        'edge-cdp-sync-staging-*'
    )
    $excludeFiles = @('History', 'load_statistics.db', '*.db-journal', '*.db-wal', '*.db-shm')

    $roboLog = Join-Path $env:TEMP "edge-cdp-sync-robocopy-$(Get-Random).log"
    $roboArgs = @(
        $edgeUserData, $profilePath,
        '/E', '/COPYALL', '/R:1', '/W:1', '/NP', '/NDL', '/NFL', '/XJ', '/MIR',
        '/XD') + $excludeDirs + @('/XF') + $excludeFiles + @("/LOG:$roboLog")

    Write-Host "[edge-cdp-sync] robocopy $edgeUserData -> $profilePath" -ForegroundColor Cyan
    $null = robocopy @roboArgs
    $rcExit = $LASTEXITCODE

    $skipped = @()
    if (Test-Path -LiteralPath $roboLog) {
        $logContent = Get-Content -LiteralPath $roboLog -Raw -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $roboLog -Force -ErrorAction SilentlyContinue
        if ($logContent) {
            foreach ($m in [regex]::Matches($logContent, 'ERROR \d+ \(0x[0-9A-Fa-f]+\) Copying File\s+([^\r\n]+)')) {
                $skipped += $m.Groups[1].Value.Trim()
            }
        }
    }
    if ($rcExit -ge 16) {
        # drop shadow before throwing so we don't leak it
        if ($shadowDevice) {
            try {
                $shadows = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.DeviceObject -eq $shadowDevice }
                $shadows | Remove-CimInstance -ErrorAction SilentlyContinue
                Write-Host "[edge-cdp-sync] VSS shadow dropped (post-failure)" -ForegroundColor DarkGray
            } catch {}
        }
        if ($vssLink -and (Test-Path -LiteralPath $vssLink)) {
            Remove-Item -LiteralPath $vssLink -Force -Recurse -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        throw "[edge-cdp-sync] robocopy failed (exit $rcExit)."
    }

    # restore preserved items
    foreach ($f in $preservedFiles) {
        $src = Join-Path $stagingDir $f
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $profilePath $f) -Force }
    }
    foreach ($d in $preservedDirs) {
        $src = Join-Path $stagingDir $d
        if (Test-Path -LiteralPath $src -PathType Container) {
            Remove-Item -LiteralPath (Join-Path $profilePath $d) -Recurse -Force -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $src -Destination (Join-Path $profilePath $d) -Recurse -Force
        }
    }
    Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue

    # === repair extension install-signature state in the copy ===
    # Edge, when launched with --remote-debugging-port, runs in "dev mode" and re-verifies
    # every extension's install signature. extensions installed from the Edge Add-ons
    # store or sideloaded (from_webstore=false / location=1 in real Edge) don't pass that
    # check, and Edge disables them with disable_reasons=1024 (DISABLE_NOT_VERIFIED),
    # shown in the UI as "corrupted". over successive runs, Edge also writes partial
    # stubs for those IDs into Default\Secure Preferences (an entry with only
    # disable_reasons=[1024]+needs_sync and no manifest/path/version), which then look
    # even more broken on the next launch.
    #
    # fix: while the VSS shadow of real Edge is still mounted, copy real Edge's
    # Default\Preferences and Default\Secure Preferences verbatim over the copy (these
    # are exactly what Edge signed at install time). then re-apply the post-robocopy
    # invariants: drop corrupted_disable_count, drop the install_signature ID lists
    # (so Edge's signature verifier has nothing to compare against — equivalent to a
    # freshly-installed profile where every extension was added by the user), and
    # strip any extensions.settings.<id> stub in Secure Preferences that lacks the
    # full manifest/path/version fields a real install has.
    #
    # this MUST run before the VSS shadow is dropped, since we read the original files
    # from the shadow path.
    $repairErrors = @()
    foreach ($file in 'Default\Preferences','Default\Secure Preferences') {
        $realFile = Join-Path $edgeUserData $file
        $copyFile = Join-Path $profilePath $file
        if (Test-Path -LiteralPath $realFile) {
            try {
                Copy-Item -LiteralPath $realFile -Destination $copyFile -Force
            } catch {
                $repairErrors += "copy $file : $($_.Exception.Message)"
            }
        }
    }

    # patch the copied Preferences: clear corruption flags + install_signature ID lists.
    # net effect: Edge sees "fresh user install" state for every extension rather than a
    # signature claim it can't re-verify under --remote-debugging-port.
    try {
        $prefPath = Join-Path $profilePath 'Default\Preferences'
        if (Test-Path -LiteralPath $prefPath) {
            $pref = Get-Content -LiteralPath $prefPath -Raw | ConvertFrom-Json -AsHashtable
            if ($pref.extensions -is [hashtable]) {
                $pref.extensions.Remove('corrupted_disable_count') | Out-Null
                if ($pref.extensions.ContainsKey('install_signature') -and $pref.extensions.install_signature -is [hashtable]) {
                    $pref.extensions.install_signature['ids'] = @()
                    $pref.extensions.install_signature['invalid_ids'] = @()
                }
                if ($pref.extensions.ContainsKey('microsoft_install_signature') -and $pref.extensions.microsoft_install_signature -is [hashtable]) {
                    $pref.extensions.microsoft_install_signature['ids'] = @()
                    $pref.extensions.microsoft_install_signature['invalid_ids'] = @()
                }
            }
            ($pref | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $prefPath -Encoding UTF8
        }
    } catch {
        $repairErrors += "patch Preferences: $($_.Exception.Message)"
    }

    # patch the copied Secure Preferences: drop any extensions.settings.<id> stub that
    # was written by a previous CDP session and lacks the full real-installed shape
    # (manifest + path + location + from_webstore + non-empty disable_reasons). stubs
    # with disable_reasons=[1024] and no other fields are exactly the "corrupted" rows
    # we want to remove; real install entries have manifest/path/location set, so we keep
    # those and only delete the broken ones.
    try {
        $secPath = Join-Path $profilePath 'Default\Secure Preferences'
        if (Test-Path -LiteralPath $secPath) {
            $sec = Get-Content -LiteralPath $secPath -Raw | ConvertFrom-Json -AsHashtable
            if ($sec.ContainsKey('extensions') -and $sec.extensions.ContainsKey('settings') -and $sec.extensions.settings -is [hashtable]) {
                $settings = $sec.extensions.settings
                $removed = @()
                foreach ($id in @($settings.Keys)) {
                    $entry = $settings[$id]
                    if (-not ($entry -is [hashtable])) { continue }
                    $hasManifest = $entry.ContainsKey('manifest') -and $entry.manifest
                    $hasPath    = $entry.ContainsKey('path')    -and $entry.path
                    $hasLocation = $entry.ContainsKey('location') -and $null -ne $entry.location
                    if (-not $hasManifest -and -not $hasPath -and -not $hasLocation) {
                        # pure stub (only disable_reasons / needs_sync / preferences etc.)
                        $settings.Remove($id) | Out-Null
                        $removed += $id
                    } elseif ($entry.ContainsKey('disable_reasons') -and $entry.disable_reasons) {
                        # real install entry that was disabled by a previous CDP run —
                        # clear the disable flag so Edge re-evaluates it as enabled.
                        $entry['disable_reasons'] = @()
                    }
                }
                if ($removed.Count -gt 0) {
                    Write-Host "[edge-cdp-sync] dropped $($removed.Count) extension stub(s) from Secure Preferences" -ForegroundColor Cyan
                }
                ($sec | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $secPath -Encoding UTF8
            }
        }
    } catch {
        $repairErrors += "patch Secure Preferences: $($_.Exception.Message)"
    }

    if ($repairErrors.Count -gt 0) {
        Write-Warning "[edge-cdp-sync] extension-signature repair partial: $($repairErrors -join '; ')"
    }

    $extCount = if (Test-Path -LiteralPath (Join-Path $profilePath 'Default\Extensions')) {
        (Get-ChildItem -LiteralPath (Join-Path $profilePath 'Default\Extensions') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Temp' } | Measure-Object).Count
    } else { 0 }
    Write-Host "[edge-cdp-sync] sync complete — ext=$extCount, LocalState=$(Test-Path -LiteralPath (Join-Path $profilePath 'Local State')), skipped=$($skipped.Count)" -ForegroundColor Green

    if ($shadowDevice) {
        try {
            $shadows = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.DeviceObject -eq $shadowDevice }
            $shadows | Remove-CimInstance -ErrorAction SilentlyContinue
            Write-Host "[edge-cdp-sync] VSS shadow dropped (post-success)" -ForegroundColor DarkGray
        } catch {}
    }
    if ($vssLink -and (Test-Path -LiteralPath $vssLink)) {
        Remove-Item -LiteralPath $vssLink -Force -Recurse -ErrorAction SilentlyContinue
    }
}

function Write-ProfileMetadata {
    param(
        [string]$Email,
        [string]$ProfilePath,
        [string[]]$Extensions = @()
    )

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    $metaPath = Join-Path $ProfilePath 'mainframe-profile.json'
    $existing = @{}
    if (Test-Path -LiteralPath $metaPath) {
        try {
            $existing = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json -AsHashtable
        } catch {}
    }

    $extensions = @($Extensions | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($extensions.Count -eq 0 -and $existing.extensions) {
        $extensions = @($existing.extensions | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    }

    [ordered]@{
        tool = 'agent-browser'
        email = $Email
        profilePath = $ProfilePath
        extensions = $extensions
        note = 'agent-browser session state. Treat this profile as secret.'
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $metaPath -Encoding UTF8
}

function Get-ProfileExtensions {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    $metaPath = Join-Path $profilePath 'mainframe-profile.json'
    if (-not (Test-Path -LiteralPath $metaPath)) {
        return @()
    }

    try {
        $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
        return @($meta.extensions | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    } catch {
        return @()
    }
}

function Get-DirectorySizeBytes {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return 0
    }

    $sum = 0L
    Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
        ForEach-Object { $sum += $_.Length }
    return $sum
}

function Format-SizeMB {
    param([Int64]$Bytes)

    return [math]::Round(($Bytes / 1MB), 2)
}

function Get-RestoreKey {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    return 'mainframe-' + ($normalized -replace '[^a-zA-Z0-9-]', '-')
}

function Get-ProfileStatus {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    $exists = Test-Path -LiteralPath $profilePath -PathType Container
    $lastWrite = $null
    if ($exists) {
        $lastWrite = (Get-Item -LiteralPath $profilePath).LastWriteTime
    }

    $active = Get-ActiveEmail
    $sizeBytes = if ($exists) { Get-DirectorySizeBytes -Path $profilePath } else { 0L }
    $hasMetadata = Test-Path -LiteralPath (Join-Path $profilePath 'mainframe-profile.json') -PathType Leaf

    [pscustomobject]@{
        Email = $normalized
        Active = ($active -eq $normalized)
        Exists = $exists
        SizeMB = Format-SizeMB -Bytes $sizeBytes
        RestoreKey = Get-RestoreKey -Email $normalized
        HasMetadata = $hasMetadata
        LastWriteTime = $lastWrite
        Path = $profilePath
    }
}

function Resolve-AgentBrowserCommand {
    $cmd = Get-Command agent-browser -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $npmGlobal = Join-Path $env:APPDATA 'npm\agent-browser.cmd'
    if (Test-Path -LiteralPath $npmGlobal) {
        return $npmGlobal
    }

    $pnpmGlobal = Join-Path $env:LOCALAPPDATA 'pnpm\agent-browser.cmd'
    if (Test-Path -LiteralPath $pnpmGlobal) {
        return $pnpmGlobal
    }

    throw 'agent-browser was not found. Install it with: npm i -g agent-browser && agent-browser install'
}

function Clear-StaleAgentBrowserState {
    # agent-browser's daemon state lives in ~/.agent-browser/:
    #   - default.{pid,port,engine,stream,version}: short-lived per-spawn runtime files.
    #     `agent-browser close --all` (called by Sync-EdgeProfileToMainframe upstream) invalidates
    #     the daemon but leaves these files behind. agent-browser's `open` then reads a stale pid,
    #     tries to attach, fails, prints "relaunched browser", and on next spawn fails outright.
    #   - default.config: opaque hex session-id pointer for the "default" namespace. PERSISTS across
    #     sessions — and the "default" namespace is GLOBAL (shared across every --profile invocation
    #     that does not pass --session/--namespace). so a leftover default.config from a previous run
    #     against a DIFFERENT profile email (e.g. mainframe-...-gmail-com-default.json) is what makes
    #     `open` decide it should "relaunch" instead of "launch".
    #   - sessions/mainframe-<email-slug>-default.json: per-profile saved session state (cookies,
    #     localStorage). these are NOT scoped — they coexist in the same sessions/ dir. only the one
    #     matching the CURRENT email should survive cleanup; stale files from other emails trip the
    #     relaunch path on the next `open`.
    #
    # fix: after `close --all` already ran upstream in the sync step, also drop:
    #   - default.* runtime files (agent-browser recreates them clean on `open`)
    #   - default.config (same — recreated)
    #   - sessions/mainframe-<other-email>-default.json files for any email that is NOT the current one
    # we keep the current email's session file so within-profile session state survives across runs.
    param(
        [string]$ProfilePath,
        [string]$Email
    )

    # 1) drop agent-browser's stale daemon runtime files + the persistent default.config pointer.
    #    agent-browser will recreate them on `open`. do NOT skip this — leaving these is the bug.
    $abState = Join-Path $env:USERPROFILE '.agent-browser'
    foreach ($f in 'default.pid','default.port','default.engine','default.stream','default.version','default.config') {
        $p = Join-Path $abState $f
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        }
    }

    # 2) purge orphaned session files belonging to OTHER email profiles. keep only the session
    #    for the email we are about to launch, so `open` sees a clean "default" namespace for THIS
    #    profile and never tries to relaunch a browser that belonged to a different account.
    $sessionsDir = Join-Path $abState 'sessions'
    if (Test-Path -LiteralPath $sessionsDir -PathType Container) {
        $currentSlug = 'mainframe-' + (([string]$Email) -replace '[^a-zA-Z0-9-]', '-') + '-default.json'
        Get-ChildItem -LiteralPath $sessionsDir -File -Filter 'mainframe-*-default.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $currentSlug } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    }

    # 3) drop chromium leftover lockfiles in the profile dir (these block a fresh launch).
    foreach ($f in 'DevToolsActivePort','SingletonLock','SingletonCookie','SingletonSocket','lockfile') {
        $p = Join-Path $ProfilePath $f
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-OptionValue {
    param(
        [string[]]$Items,
        [string]$Name,
        [AllowNull()][string]$Default = $null
    )

    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Items[$i] -ieq $Name) {
            if ($i + 1 -ge $Items.Count) {
                throw "Missing value for $Name"
            }

            return [string]$Items[$i + 1]
        }
    }

    return $Default
}

function Test-Flag {
    param(
        [string[]]$Items,
        [string]$Name
    )

    foreach ($item in $Items) {
        if ($item -ieq $Name) {
            return $true
        }
    }

    return $false
}

function Get-ExtensionPaths {
    param([string[]]$Items)

    $extensions = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Items[$i] -ieq '-Extension') {
            if ($i + 1 -ge $Items.Count) {
                throw 'Missing value for -Extension'
            }
            $extensions.Add([string]$Items[$i + 1])
            $i++
        }
    }

    return $extensions.ToArray()
}

function Get-PassthroughArgs {
    param([string[]]$Items)

    $skipNext = $false
    $result = [System.Collections.Generic.List[string]]::new()
    $optionsWithValues = @('-url', '-extension')

    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($skipNext) {
            $skipNext = $false
            continue
        }

        $item = [string]$Items[$i]
        if ($optionsWithValues -contains $item.ToLowerInvariant()) {
            $skipNext = $true
            continue
        }

        if ($item -ieq '-Headless') {
            continue
        }

        if ($item.StartsWith('-', [StringComparison]::Ordinal)) {
            continue
        }

        if (Test-LooksLikeEmail -Value $item) {
            continue
        }

        $result.Add($item)
    }

    return $result.ToArray()
}

function Invoke-AgentBrowser {
    param(
        [string]$Email,
        [string]$Url,
        [string[]]$Extensions,
        [bool]$Headless,
        [bool]$IsLogin,
        [string[]]$ExtraArgs
    )

    $normalized = Normalize-Email -Email $Email

    $agentBrowser = Resolve-AgentBrowserCommand
    $profilePath = Get-ProfilePath -Email $normalized
    # the email-keyed dir IS the chromium user-data-dir (contains Default/ + sibling state files like Local State)
    $chromeProfileDir = $profilePath
    Ensure-ProfileDirectory -ProfilePath $profilePath

    if ($IsLogin) {
        Write-ProfileMetadata -Email $normalized -ProfilePath $profilePath -Extensions $Extensions
    } else {
        if ($Extensions.Count -eq 0) {
            $Extensions = Get-ProfileExtensions -Email $normalized
        }
        Write-ProfileMetadata -Email $normalized -ProfilePath $profilePath -Extensions $Extensions
    }

    # sync-then-spawn: refresh the mainframe profile from the real Edge User Data dir
    # so every agent-browser session starts with a clean throwaway copy (CDP will
    # prune some extensions inside the copy during the session; real Edge is untouched).
    try {
        Sync-EdgeProfileToMainframe -Email $normalized
    } catch {
        Write-Warning "[edge-cdp-sync] sync failed, spawning against existing profile: $($_.Exception.Message)"
    }

    # drop stale agent-browser daemon state (default.* runtime files, default.config pointer,
    # orphaned session files from OTHER profiles) + chromium lockfiles so the spawn doesn't
    # "relaunched browser" (which leaves inconsistent state that breaks the NEXT run).
    Clear-StaleAgentBrowserState -ProfilePath $chromeProfileDir -Email $normalized

    # global flags (--executable-path, --profile, --extension) MUST come BEFORE the
    # subcommand name; agent-browser parses them as top-level options. putting them
    # after `open <url>` makes agent-browser treat them as `open`-subcommand args and
    # silently fall back to its bundled chrome — which is what was happening before.
    $args = [System.Collections.Generic.List[string]]::new()

    $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
    if (Test-Path -LiteralPath $edgePath) {
        $args.Add('--executable-path')
        $args.Add($edgePath)
    }

    $args.Add('--profile')
    $args.Add($chromeProfileDir)

    foreach ($ext in $Extensions) {
        if (Test-Path -LiteralPath $ext) {
            $args.Add('--extension')
            $args.Add($ext)
        }
    }

    # now the subcommand + its own args.
    # CAUTION: never pass vanilla (no URL) to `agent-browser open` — an empty URL makes
    # agent-browser internally navigate to about:blank, which for some reason reliably triggers
    # its "relaunched browser" path (kills + respawns Edge, leaving inconsistent state that
    # breaks the NEXT run). pinning https://example.com as a harmless default avoids the bug.
    # if you truly need a blank page, navigate AFTER open via `agent-browser navigate about:blank`.
    $args.Add('open')
    $effectiveUrl = if ([string]::IsNullOrWhiteSpace($Url)) { 'https://example.com' } else { $Url }
    $args.Add($effectiveUrl)

    if (-not $Headless) {
        $args.Add('--headed')
    }

    foreach ($extra in $ExtraArgs) {
        $args.Add($extra)
    }

    Set-ActiveEmail -Email $normalized

    Write-Host "agent-browser profile: $normalized"
    Write-Host "Spawn mode: profile dir = $chromeProfileDir"
    Write-Host "URL: $effectiveUrl"
    if ($Extensions.Count -gt 0) {
        Write-Host "Extensions: $($Extensions -join ', ')"
    }
    Write-Host "Headless: $Headless"

    # tell Chromium to auto-restore the last session on launch. the synced profile
    # carries real Edge's `Default/Sessions/Session_*` (and `Tabs_*`) files which hold
    # the open-tab state — without this flag Edge starts fresh and only opens the
    # example.com tab agent-browser navigated to, leaving your real-Edge tabs locked
    # behind a manual "Restore" button. with `--restore-last-session`, Edge re-opens
    # those tabs automatically on launch (alongside the example.com tab).
    #
    # stealth flags: agent-browser's default launch flags set `--remote-debugging-port`,
    # `--password-store=basic`, `--use-mock-keychain`, etc., all of which expose
    # `navigator.webdriver=true` and other CDP artifacts to the page. Google sign-in
    # fingerprints these and blocks login with "This browser or app may not be secure".
    # `--disable-blink-features=AutomationControlled` flips `navigator.webdriver` to
    # undefined and clears the runtime-enabled automation flag. `--disable-features=AutomationControlled`
    # covers the same on the features side. these two together let Google sign-in work
    # inside the synced real-Edge profile clone.
    #
    # injected via AGENT_BROWSER_ARGS env (agent-browser's documented passthrough for
    # Chromium launch args) rather than `--args` CLI flag to avoid any CLI parsing
    # ambiguity. preserved + restored around the spawn so we don't leak it into the
    # parent shell.
    $oldArgs = $env:AGENT_BROWSER_ARGS
    try {
        $restoreFlag = '--restore-last-session'
        $stealthFlags = '--disable-blink-features=AutomationControlled','--disable-features=AutomationControlled'
        $extra = @($restoreFlag) + $stealthFlags
        if ($oldArgs) {
            $env:AGENT_BROWSER_ARGS = $oldArgs.Trim().TrimEnd(',') + ',' + ($extra -join ',')
        } else {
            $env:AGENT_BROWSER_ARGS = $extra -join ','
        }
        & $agentBrowser @args
    } finally {
        if ([string]::IsNullOrWhiteSpace($oldArgs)) {
            Remove-Item Env:\AGENT_BROWSER_ARGS -ErrorAction SilentlyContinue
        } else {
            $env:AGENT_BROWSER_ARGS = $oldArgs
        }
    }
}

function Close-Session {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $restoreKey = Get-RestoreKey -Email $normalized

    $agentBrowser = Resolve-AgentBrowserCommand
    & $agentBrowser close --all

    Write-Host "Closed agent-browser session for: $normalized"
}

function Remove-Profile {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    $restoreKey = Get-RestoreKey -Email $normalized

    if (Test-Path -LiteralPath $profilePath) {
        Remove-Item -LiteralPath $profilePath -Recurse -Force
    }

    $agentBrowser = Resolve-AgentBrowserCommand
    & $agentBrowser state delete $restoreKey 2>$null

    $active = Get-ActiveEmail
    if ($active -eq $normalized -and (Test-Path -LiteralPath $currentFile)) {
        Remove-Item -LiteralPath $currentFile -Force
    }

    Write-Host "Removed agent-browser profile: $normalized"
}

# === lightweight cookies mode (no VSS sync, tiny per-email export) ===
# the full `run`/`login`/`exec` path VSS-syncs the entire real Edge User Data dir
# (~370 MB) into the email-keyed profile on every spawn. for jobs that ONLY need a
# logged-in session for a handful of sites (e.g. messenger.com refresher), that's
# heavy. this mode instead stores a small JSON of cookies for selected domains
# (a few KB) and spawns a throwaway minimal profile that injects them — no VSS,
# no /MIR, works non-elevated.

function Get-CookieExportPath {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    return Join-Path $accountRoot "cookies\$normalized.cookies.json"
}

function Get-CookieMetaPath {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    return Join-Path $accountRoot "cookies\$normalized.meta.json"
}

function Get-CookieLiteProfilePath {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    return Join-Path $accountRoot "cookies-lite\$normalized"
}

function Test-CookieDomainMatch {
    param([string]$CookieDomain, [string[]]$Domains)

    $cd = ([string]$CookieDomain).TrimStart('.').ToLowerInvariant()
    foreach ($d in $Domains) {
        $d = ([string]$d).Trim().TrimStart('.').ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        if ($cd -eq $d) { return $true }
        if ($cd.EndsWith('.' + $d, [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Expand-CoDomains {
    # facebook family: messenger.com and facebook.com sessions are cross-validated —
    # importing only .messenger.com cookies gets the auth trio (c_user/xs/sb) deleted
    # by FB's JS on page load (login form shows). expand so both domains are matched.
    param([string[]]$Domains)

    $out = @()
    foreach ($d in $Domains) {
        $d = ([string]$d).Trim().TrimStart('.').ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        $out += $d
        if ($d -eq 'messenger.com' -or $d.EndsWith('.messenger.com')) { $out += 'facebook.com' }
        elseif ($d -eq 'facebook.com' -or $d.EndsWith('.facebook.com')) { $out += 'messenger.com' }
    }
    return @($out | Sort-Object -Unique)
}

function Invoke-AgentBrowserDetachedOutput {
    # run one agent-browser command in a hidden detached pwsh, wait for its
    # output file, return the captured text. never call agent-browser in-process —
    # its spawn keeps the pipe open and the caller hangs.
    param(
        [string]$ProfileDir,
        [string[]]$Command,
        [int]$WaitSeconds = 40
    )

    $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
    $outFile = Join-Path $env:TEMP "ab-cmd-$([Guid]::NewGuid().ToString('N')).out"
    $globals = @()
    if (Test-Path -LiteralPath $edgePath) {
        $globals += @('--executable-path', $edgePath)
    }
    $globals += @('--profile', $ProfileDir)

    $cmdLine = ('agent-browser ' + (($globals + $Command) | ForEach-Object { "'$_'" }) -join ' ')
    Start-Process pwsh -WindowStyle Hidden -ArgumentList '-Command', "$cmdLine 2>&1 | Out-File '$outFile' -Encoding utf8"

    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $outFile) {
            return Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500
    }

    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    throw "detached agent-browser command timed out after ${WaitSeconds}s: $($Command -join ' ')"
}

function Save-SiteCookies {
    param(
        [Parameter(Mandatory)] [string]$Email,
        [string[]]$Domains = @('facebook.com', 'messenger.com'),
        [switch]$FromSession,
        [string]$Session = $null
    )

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    $exportPath = Get-CookieExportPath -Email $normalized
    $metaPath = Get-CookieMetaPath -Email $normalized

    if ($FromSession) {
        # capture from the LIVE daemon session (e.g. a `login` window where the user just
        # signed in inside agent-browser). NO sync — a re-sync would /MIR-overwrite the
        # login the user just did in the throwaway copy. skip daemon-state cleanup too;
        # the running session must stay untouched while we read its cookies.
        # note: agent-browser's default namespace is GLOBAL, but the read is scoped by
        # --profile (Invoke-AgentBrowserDetachedOutput always passes it), so it hits THIS
        # profile's daemon. pass -Session <name> only when the login window was spawned
        # with an explicit --session.
        if ([string]::IsNullOrWhiteSpace($Session)) {
            Write-Host "[cookies save] no -Session given — reading the default namespace scoped by profile (works for helper `login` windows; pass -Session if the window used --session)" -ForegroundColor Yellow
        }
        Write-Host "[cookies save] capturing from the running agent-browser session (no sync)...$($(if ($Session) { " session='$Session'" } else { '' }))" -ForegroundColor Cyan
    } else {
        # step 1: fresh sync from real Edge (VSS — needs elevated shell). this is the
        # ONE heavy step of the whole mode; it hands the copy the user's real logged-in
        # cookies (Facebook/Messenger etc. from real Edge).
        Sync-EdgeProfileToMainframe -Email $normalized
        Clear-StaleAgentBrowserState -ProfilePath $profilePath -Email $normalized
    }

    # step 2: dump the session's cookies and filter to the requested domains.
    # -Session scopes the read to the login window's own daemon; without it the
    # global default namespace is used (shared by every other agent on the machine).
    $getArgs = @('cookies', 'get', '--json')
    if ($FromSession -and -not [string]::IsNullOrWhiteSpace($Session)) {
        $getArgs += @('--session', $Session)
    }
    $out = Invoke-AgentBrowserDetachedOutput -ProfileDir $profilePath -Command $getArgs -WaitSeconds 90

    $cookies = @()
    try {
        $parsed = $out | ConvertFrom-Json
        $cookies = @($parsed.data.cookies)
    } catch {
        throw "cookies get failed to parse: $out"
    }
    if ($cookies.Count -eq 0) {
        throw 'cookies get returned no cookies — profile sync produced an empty cookie store'
    }

    # expand facebook-family co-domains so messenger.com saves also capture
    # facebook.com cookies (and vice versa) — FB cross-validates both domains
    $matchDomains = Expand-CoDomains -Domains $Domains
    $matched = @($cookies | Where-Object { Test-CookieDomainMatch -CookieDomain $_.domain -Domains $matchDomains })
    if ($matched.Count -eq 0) {
        $listed = $Domains -join ', '
        throw "no cookies found for domains: $listed (is the account logged into these sites in real Edge?)"
    }

    # step 3: write the export as a bare CDP cookie array (the format
    # `cookies set --curl` accepts) + a meta sidecar for status reporting.
    # -AsArray is required: ConvertTo-Json unwraps a single-element array to a
    # bare object, and the importer rejects non-array input ("no cookies found").
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $exportPath) | Out-Null
    ($matched | ConvertTo-Json -Depth 6 -AsArray) | Set-Content -LiteralPath $exportPath -Encoding UTF8

    $earliestExpiry = $null
    foreach ($c in $matched) {
        $exp = [double]$c.expires
        if ($exp -gt 0 -and ($null -eq $earliestExpiry -or $exp -lt $earliestExpiry)) {
            $earliestExpiry = $exp
        }
    }

    [ordered]@{
        email = $normalized
        domains = @($Domains)
        cookieCount = $matched.Count
        earliestCookieExpiry = $earliestExpiry
        earliestCookieExpiryUtc = if ($earliestExpiry) { ([DateTimeOffset]::FromUnixTimeSeconds([int64]$earliestExpiry).UtcDateTime).ToString('o') } else { $null }
        savedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        sizeBytes = (Get-Item -LiteralPath $exportPath).Length
        source = $(if ($FromSession) { 'live agent-browser session (no sync)' } else { 'real-Edge VSS sync (single heavy step; subsequent run/verify are sync-free)' })
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $metaPath -Encoding UTF8

    # clean up: drop the spawned browser + the big synced profile can stay (it's reused
    # by future full-mode runs). do NOT delete the synced profile — other modes use it.
    $agentBrowser = Resolve-AgentBrowserCommand
    & $agentBrowser close --all 2>$null

    Write-Host "cookie export saved: $exportPath"
    Write-Host "domains: $($matched.Count) cookies for: $($Domains -join ', ')"
    Write-Host "size: $([math]::Round((Get-Item -LiteralPath $exportPath).Length / 1KB, 1)) KB"
    if ($earliestExpiry) {
        Write-Host "earliest cookie expiry: $([DateTimeOffset]::FromUnixTimeSeconds([int64]$earliestExpiry).UtcDateTime)"
    }
    Write-Host "next `cookies run`/`cookies verify` use this export — no VSS sync needed."
}

function Start-LiteBrowser {
    # spawn a throwaway minimal profile with only the domain cookies injected.
    # NO VSS sync — works from a non-elevated shell. headed by default.
    param(
        [Parameter(Mandatory)] [string]$Email,
        [string]$Url = 'https://www.messenger.com',
        [bool]$Headless = $false,
        [switch]$Return
    )

    $normalized = Normalize-Email -Email $Email
    $exportPath = Get-CookieExportPath -Email $normalized
    if (-not (Test-Path -LiteralPath $exportPath)) {
        throw "no cookie export for $normalized — run `.\\agent-browser-account.ps1 cookies save $normalized` first (needs elevated shell once)"
    }

    $liteDir = Get-CookieLiteProfilePath -Email $normalized
    New-Item -ItemType Directory -Force -Path $liteDir | Out-Null

    # build the import file: duplicate facebook-family cookies on the co-domain
    # (.facebook.com <-> .messenger.com). verified 2026-08-12: importing only the
    # .messenger.com set leaves c_user/xs/sb deleted by FB's JS on page load
    # (login form); adding .facebook.com copies makes the session stick.
    $importPath = $exportPath
    try {
        $exportData = @(Get-Content -LiteralPath $exportPath -Raw | ConvertFrom-Json)
        $needsDual = @($exportData | Where-Object { $_.domain -match '(^|\.)(messenger|facebook)\.com$' })
        if ($needsDual.Count -gt 0) {
            $dual = @()
            foreach ($ck in $exportData) {
                $dual += $ck
                $co = $null
                if ($ck.domain -match '(^|\.)messenger\.com$') { $co = '.facebook.com' }
                elseif ($ck.domain -match '(^|\.)facebook\.com$') { $co = '.messenger.com' }
                if ($co) {
                    $copy = $ck.PSObject.Copy()
                    $copy.domain = $co
                    $dual += $copy
                }
            }
            $importPath = Join-Path $env:TEMP "ab-import-$([Guid]::NewGuid().ToString('N')).json"
            ($dual | ConvertTo-Json -Depth 6 -AsArray) | Set-Content -LiteralPath $importPath -Encoding UTF8
        }
    } catch {
        $importPath = $exportPath
    }

    # dedicated session name so this lite run never shares agent-browser's GLOBAL default
    # namespace (which every other agent on the machine uses — shared-namespace daemon
    # churn is what killed earlier login windows mid-checkpoint).
    $sessionName = 'mainframe-cookies-' + ($normalized -replace '[^a-zA-Z0-9-]', '-')
    $sessionFlag = @('--session', $sessionName)

    $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
    if (Test-Path -LiteralPath $edgePath) {
        $globals = @('--executable-path', $edgePath)
    } else {
        $globals = @()
    }
    $globals += @('--profile', $liteDir)

    # build a single pre-quoted arg string. NEVER join raw values with spaces:
    # `C:\Program Files (x86)\...` unquoted becomes a PowerShell expression
    # (`(x86)` → "x86 not recognized") and the whole spawned script dies with a
    # parse error, producing NO output files — verify would time out with no clue.
    $argList = @()
    foreach ($a in @($globals + $sessionFlag)) {
        if ($a -like '-*') { $argList += $a } else { $argList += "'$a'" }
    }
    $globalArgs = $argList -join ' '

    $headed = if ($Headless) { '' } else { ' --headed' }
    $stealth = $env:AGENT_BROWSER_ARGS
    if (!$stealth) {
        $stealth = '--disable-blink-features=AutomationControlled,--disable-features=AutomationControlled'
    }

    if ($Return) {
        # verify mode: fully scripted — cookies get first (spawns the browser AND
        # warms the cookie backend; a cold daemon rejects the first Network.setCookies
        # batch with "Invalid cookie fields"), then import, then navigate. `open`
        # BLOCKS FOREVER (agent-browser poll bug) so it is never used here; `cookies
        # get`/`navigate` both return cleanly. report, then close.
        # each command redirects to its OWN file with `*>` — a trailing
        # `2>&1 | Out-File` over the multi-line script silently drops lines and
        # can block forever; per-command redirects always capture reliably.
        $diagDir = Join-Path $env:TEMP "ab-verify-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Force -Path $diagDir | Out-Null
        $cmd = { param($i) "agent-browser $globalArgs $i" }
        $script = @"
`$env:AGENT_BROWSER_ARGS = '$stealth'
$(& $cmd 'cookies get --json') *> '$diagDir\1-warmup.out'
$(& $cmd "cookies set --curl '$importPath'") *> '$diagDir\2-set.out'
$(& $cmd "navigate '$Url'") *> '$diagDir\3-nav.out'
Start-Sleep -Seconds 8
$(& $cmd 'get url') *> '$diagDir\4-url.out'
$(& $cmd 'get title') *> '$diagDir\5-title.out'
$(& $cmd 'snapshot -i -c') *> '$diagDir\6-snap.out'
$(& $cmd 'close --all') *> '$diagDir\7-close.out'
"@
        Start-Process pwsh -WindowStyle Hidden -ArgumentList '-Command', $script

        $deadline = [DateTime]::UtcNow.AddSeconds(120)
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath "$diagDir\7-close.out") {
                Start-Sleep -Seconds 1
                $out = @()
                foreach ($n in 1..7) {
                    $f = Join-Path $diagDir "$n-*.out"
                    $p = Get-ChildItem -LiteralPath $diagDir -Filter "$n-*.out" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($p) { $out += "[$($p.Name)]"; $out += Get-Content -LiteralPath $p.FullName -Raw -ErrorAction SilentlyContinue }
                }
                Remove-Item -LiteralPath $diagDir -Recurse -Force -ErrorAction SilentlyContinue
                return ($out -join "`n")
            }
            Start-Sleep -Milliseconds 500
        }

        Remove-Item -LiteralPath $diagDir -Recurse -Force -ErrorAction SilentlyContinue
        throw "cookies verify timed out after 120s — diag dir was $diagDir (kept: $(Test-Path -LiteralPath $diagDir))"
    }

    # run mode: spawn a persistent window that injects cookies then shows the target.
    # warmup via `cookies get` first — it spawns the browser and returns cleanly;
    # `open` BLOCKS FOREVER, so it must be the LAST command (it keeps the window alive).
    $script = @"
`$env:AGENT_BROWSER_ARGS = '$stealth'
agent-browser $globalArgs cookies get --json
agent-browser $globalArgs cookies set --curl '$importPath'
agent-browser $globalArgs open '$Url'$headed
"@
    Start-Process pwsh -ArgumentList '-NoExit', '-Command', $script -WindowStyle Normal

    Write-Host "lite browser spawned for: $normalized"
    Write-Host "profile dir (throwaway, ~20 MB): $liteDir"
    Write-Host "cookies injected from: $exportPath"
    Write-Host "session: $sessionName"
    Write-Host "URL: $Url"
}

function Show-CookieStatus {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $exportPath = Get-CookieExportPath -Email $normalized
    $metaPath = Get-CookieMetaPath -Email $normalized

    if (-not (Test-Path -LiteralPath $exportPath)) {
        Write-Host "no cookie export for $normalized. run: .\agent-browser-account.ps1 cookies save $normalized (needs elevated shell once)"
        return
    }

    $meta = $null
    if (Test-Path -LiteralPath $metaPath) {
        try {
            $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
        } catch {}
    }

    $cookies = @()
    try {
        $cookies = @(Get-Content -LiteralPath $exportPath -Raw | ConvertFrom-Json)
    } catch {}

    Write-Host "email: $normalized"
    Write-Host "export: $exportPath"
    Write-Host "size: $([math]::Round((Get-Item -LiteralPath $exportPath).Length / 1KB, 1)) KB"
    if ($meta) {
        Write-Host "domains: $(@($meta.domains) -join ', ')"
        Write-Host "saved: $($meta.savedAtUtc) (UTC)"
        if ($meta.earliestCookieExpiryUtc) {
            Write-Host "earliest cookie expiry: $($meta.earliestCookieExpiryUtc) (UTC)"
        }
    }
    Write-Host "cookie count: $($cookies.Count)"
    if ($cookies.Count -gt 0) {
        Write-Host "sample names: $((@($cookies | Select-Object -First 8).name) -join ', ')"
    }
}

$action = if ($args.Count -gt 0) { [string]$args[0] } else { 'help' }
$remaining = @()
if ($args.Count -gt 1) {
    $remaining = @($args[1..($args.Count - 1)])
}

switch ($action.ToLowerInvariant()) {
    'help' {
        Show-Usage
    }

    { $_ -in @('login', 'run') } {
        $email = $null
        if ($remaining.Count -gt 0 -and (Test-LooksLikeEmail -Value $remaining[0])) {
            $email = Normalize-Email -Email $remaining[0]
        } else {
            $email = Get-EmailOrActive -Email $null
        }

        $url = Get-OptionValue -Items $remaining -Name '-Url' -Default $null
        $extensions = Get-ExtensionPaths -Items $remaining
        $headless = Test-Flag -Items $remaining -Name '-Headless'
        $passthrough = Get-PassthroughArgs -Items $remaining

        $autoSave = ($action -ieq 'login')
        $isLogin = ($action -ieq 'login')

        Invoke-AgentBrowser -Email $email -Url $url -Extensions $extensions -Headless $headless -IsLogin $isLogin -ExtraArgs $passthrough
    }

    'exec' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\agent-browser-account.ps1 exec [email] <command> [args...]'
        }

        $email = $null
        $cmdArgs = @()

        if (Test-LooksLikeEmail -Value $remaining[0]) {
            $email = Normalize-Email -Email $remaining[0]
            if ($remaining.Count -lt 2) {
                throw 'Usage: .\agent-browser-account.ps1 exec [email] <command> [args...]'
            }
            $cmdArgs = @($remaining[1..($remaining.Count - 1)])
        } else {
            $email = Get-EmailOrActive -Email $null
            $cmdArgs = @($remaining)
        }

        $normalized = Normalize-Email -Email $email
        $profilePath = Get-ProfilePath -Email $normalized
        # the email-keyed dir IS the chromium user-data-dir (contains Default/ + sibling state files like Local State)
        $chromeProfileDir = $profilePath

        $agentBrowser = Resolve-AgentBrowserCommand

        # sync-then-spawn: refresh the mainframe profile from the real Edge User Data dir
        # so every agent-browser session starts with a clean throwaway copy.
        try {
            Sync-EdgeProfileToMainframe -Email $normalized
        } catch {
            Write-Warning "[edge-cdp-sync] sync failed, spawning against existing profile: $($_.Exception.Message)"
        }

        # drop stale agent-browser daemon state + chromium lockfiles so the spawn doesn't "relaunch".
        Clear-StaleAgentBrowserState -ProfilePath $chromeProfileDir -Email $normalized

        # globals (--profile, --executable-path) must come BEFORE the subcommand in cmdArgs;
        # agent-browser parses them as top-level options, not as subcommand flags.
        $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
        $globals = @()
        if (Test-Path -LiteralPath $edgePath) {
            $globals += @('--executable-path', $edgePath)
        }
        $globals += @('--profile', $chromeProfileDir)
        $fullArgs = $globals + $cmdArgs

        & $agentBrowser @fullArgs
    }

    'cookies' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\agent-browser-account.ps1 cookies <save|run|verify|status> [email] [options]'
        }

        $sub = [string]$remaining[0]
        $subArgs = @()
        if ($remaining.Count -gt 1) {
            $subArgs = @($remaining[1..($remaining.Count - 1)])
        }

        $email = $null
        if ($subArgs.Count -gt 0 -and (Test-LooksLikeEmail -Value $subArgs[0])) {
            $email = Normalize-Email -Email $subArgs[0]
        } else {
            $email = Get-EmailOrActive -Email $null
        }

        switch ($sub.ToLowerInvariant()) {
            'save' {
                $domainsCsv = Get-OptionValue -Items $subArgs -Name '-Domains' -Default 'facebook.com,messenger.com'
                $domains = @($domainsCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $fromSession = Test-Flag -Items $subArgs -Name '-FromSession'
                Save-SiteCookies -Email $email -Domains $domains -FromSession:$fromSession
            }

            'run' {
                $url = Get-OptionValue -Items $subArgs -Name '-Url' -Default 'https://www.messenger.com'
                $headless = Test-Flag -Items $subArgs -Name '-Headless'
                Start-LiteBrowser -Email $email -Url $url -Headless $headless
            }

            'verify' {
                $url = Get-OptionValue -Items $subArgs -Name '-Url' -Default 'https://www.messenger.com'
                $out = Start-LiteBrowser -Email $email -Url $url -Headless $true -Return
                Write-Host $out
                # classify from the page snapshot: login forms show a "Log In" button +
                # "Email address or phone number" textbox; logged-in chat shows the
                # message list ("Chats", "Search", "unread" markers).
                $snapStart = $out.IndexOf('[6-snap.out]')
                $snap = if ($snapStart -ge 0) { $out.Substring($snapStart) } else { $out }
                $loginMarkers = '(?i)(log in to facebook|log in|sign in to facebook|email address or phone number|checkpoint|two.factor|two_factor|login\.php|enter your password)'
                $loggedIn = $snap -notmatch $loginMarkers -or $snap -match '(?i)(chats|unread|new message|search messenger)'
                $verdict = if ($loggedIn) { 'LOGGED IN (chat UI present)' } else { 'LOGIN REQUIRED or checkpointed - cookies expired or invalid' }
                Write-Host ""
                Write-Host "VERDICT: $verdict"
            }

            'status' {
                Show-CookieStatus -Email $email
            }

            default {
                throw "Unknown cookies subcommand: $sub"
            }
        }
    }

    'use' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\agent-browser-account.ps1 use <email>'
        }

        $email = Normalize-Email -Email $remaining[0]
        $profilePath = Get-ProfilePath -Email $email
        if (-not (Test-Path -LiteralPath $profilePath -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
            Write-ProfileMetadata -Email $email -ProfilePath $profilePath
        }

        Set-ActiveEmail -Email $email
        Write-Host "Active agent-browser profile: $email"
    }

    'status' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\agent-browser-account.ps1 status [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Get-ProfileStatus -Email $email | Format-List
    }

    'status-all' {
        $profiles = @(Get-ProfileDirectories)
        if ($profiles.Count -eq 0) {
            Write-Host 'No agent-browser profiles found.'
            return
        }

        $profiles |
            ForEach-Object { Get-ProfileStatus -Email $_.Name } |
            Format-Table -AutoSize
    }

    'list' {
        $profiles = @(Get-ProfileDirectories)
        if ($profiles.Count -eq 0) {
            Write-Host 'No agent-browser profiles found.'
            return
        }

        $active = Get-ActiveEmail
        foreach ($profile in $profiles) {
            $email = $profile.Name
            $marker = if ($email -eq $active) { '*' } else { ' ' }
            Write-Host "$marker $email"
        }
    }

    'current' {
        $active = Get-ActiveEmail
        if ($active) {
            Write-Host $active
        } else {
            Write-Host 'No active agent-browser profile set.'
        }
    }

    'path' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Write-Host (Get-ProfilePath -Email $email)
    }

    'env' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        $restoreKey = Get-RestoreKey -Email $email
        $profilePath = Get-ProfilePath -Email $email
        # the email-keyed dir IS the chromium user-data-dir (contains Default/ + sibling state files like Local State)
        $chromeProfileDir = $profilePath
        $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
        Write-Host "`$env:AGENT_BROWSER_PROFILE = '$chromeProfileDir'"
        Write-Host "`$env:AGENT_BROWSER_EXECUTABLE_PATH = '$edgePath'"
        Write-Host "`$env:MAINFRAME_AGENT_BROWSER_EMAIL = '$email'"
        Write-Host "`$env:MAINFRAME_AGENT_BROWSER_RESTORE = '$restoreKey'"
        Write-Host "`$env:AGENT_BROWSER_RESTORE = '$restoreKey'"
        Write-Host "Profile path: $profilePath"
        Write-Host "Mode: sync-then-spawn (every run refreshes this dir from real Edge User Data)"
        Write-Host "Browser engine: Edge (msedge.exe) is injected by run/login/exec automatically; set AGENT_BROWSER_EXECUTABLE_PATH only when calling raw agent-browser."
    }

    'close' {
        # `close --all` skips email validation and just runs `agent-browser close --all`
        if ($remaining.Count -gt 0 -and $remaining[0] -eq '--all') {
            $agentBrowser = Resolve-AgentBrowserCommand
            & $agentBrowser close --all
            Write-Host "Closed all agent-browser sessions."
        } else {
            $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
            Close-Session -Email $email
        }
    }

    { $_ -in @('logout', 'remove') } {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Remove-Profile -Email $email
    }

    default {
        Show-Usage
        throw "Unknown action: $action"
    }
}


